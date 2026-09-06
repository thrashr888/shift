(define-module (live-agent session)
  #:use-module (ice-9 format)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 threads)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-13)
  #:use-module (srfi srfi-14)
  #:use-module (live-agent generation)
  #:use-module (live-agent json)
  #:use-module (live-agent runtime)
  #:export (session-state?
            open-session!
            fork-session!
            list-session-names
            session-name
            session-id
            session-directory
            session-history
            session-next-turn
            session-generation-id
            session-fingerprint
            session-patches
            session-resumed?
            close-session!
            save-session!))

(define max-checkpoint-bytes (* 8 1024 1024))
(define max-history-messages 2000)
(define max-persisted-patches 64)

(define-record-type <session-state>
  (%make-session-state name id directory history next-turn generation-id
                       fingerprint patches created-at resumed? fork lock lock-port)
  session-state?
  (name session-name)
  (id session-id)
  (directory session-directory)
  (history session-history)
  (next-turn session-next-turn)
  (generation-id session-generation-id)
  (fingerprint session-fingerprint)
  (patches session-patches)
  (created-at session-created-at)
  (resumed? session-resumed?)
  (fork session-fork)
  (lock session-lock)
  (lock-port session-lock-port))

(define (timestamp)
  (strftime "%Y-%m-%dT%H:%M:%SZ" (gmtime (current-time))))

(define session-id-counter 0)

(define (fresh-session-id)
  (set! session-id-counter (+ session-id-counter 1))
  (let* ((now (gettimeofday))
         (left (+ (* (car now) 1000003) (cdr now)))
         (right (+ (* (getpid) 7919) session-id-counter left)))
    (format #f "~16,'0x~16,'0x"
            (modulo left (expt 16 16))
            (modulo right (expt 16 16)))))

(define (safe-session-name? value)
  (and (string? value)
       (> (string-length value) 0)
       (<= (string-length value) 80)
       (char-set-contains? char-set:letter+digit (string-ref value 0))
       (string-every
        (lambda (character)
          (or (char-set-contains? char-set:letter+digit character)
              (memv character '(#\. #\_ #\-))))
        value)))

(define (ensure-directory! path)
  (unless (file-exists? path)
    (let ((parent (dirname path)))
      (unless (or (string=? parent path)
                  (string=? parent ".")
                  (file-exists? parent))
        (ensure-directory! parent)))
    (mkdir path #o700)))

(define (checkpoint-path directory)
  (string-append directory "/session.json"))

(define (acquire-session-lock directory name)
  (let ((port (open-file (string-append directory "/owner.lock") "a")))
    (catch 'system-error
      (lambda ()
        (flock port (logior LOCK_EX LOCK_NB))
        port)
      (lambda arguments
        (close-port port)
        (error "session is already open in another process" name arguments)))))

(define (close-session! state)
  (let ((port (session-lock-port state)))
    (unless (port-closed? port)
      (flock port LOCK_UN)
      (close-port port))))

(define (session-root state-directory)
  (string-append state-directory "/sessions"))

(define (atomic-write! path content)
  (when (> (string-length content) max-checkpoint-bytes)
    (error "session checkpoint exceeds the 8 MiB limit"
           (string-length content)))
  (let* ((template
          (string-append (dirname path) "/.session-"
                         (number->string (getpid)) "-XXXXXX"))
         (port (mkstemp template))
         (actual (port-filename port)))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (display content port)
        (force-output port)
        (close-port port)
        (rename-file actual path))
      (lambda ()
        (unless (port-closed? port) (close-port port))
        (when (file-exists? actual) (delete-file actual))))))

(define (require-array object key predicate description maximum)
  (let ((value (json-object-ref object key)))
    (unless (json-array? value)
      (error "session checkpoint field must be an array" key))
    (let ((items (json-array-items value)))
      (when (> (length items) maximum)
        (error "session checkpoint field is too large" key maximum))
      (unless (every predicate items)
        (error "session checkpoint contains invalid entries" key description))
      items)))

(define (read-session directory expected-name lock-port)
  (let ((path (checkpoint-path directory)))
    (when (> (stat:size (stat path)) max-checkpoint-bytes)
      (error "session checkpoint exceeds the 8 MiB limit" path))
    (let* ((root (call-with-input-file path
                   (lambda (port) (json-read (get-string-all port)))))
           (version (and (json-object? root)
                         (json-object-ref root "version" #f)))
           (name (and (json-object? root)
                      (json-object-ref root "name" #f)))
           (id (and (json-object? root)
                    (json-object-ref root "id" #f)))
           (next-turn (and (json-object? root)
                           (json-object-ref root "next_turn" #f)))
           (generation-id
            (and (json-object? root)
                 (json-object-ref root "generation_id" #f)))
           (fingerprint
            (and (json-object? root)
                 (json-object-ref root "fingerprint" #f))))
      (unless (and (equal? version 1)
                   (string? name) (string=? name expected-name)
                   (string? id) (not (string-null? id))
                   (integer? next-turn) (> next-turn 0)
                   (integer? generation-id) (> generation-id 0)
                   (string? fingerprint) (not (string-null? fingerprint)))
        (error "invalid or mismatched session checkpoint" path))
      (%make-session-state
       name id directory
       (require-array root "history" json-object? "message objects"
                      max-history-messages)
       next-turn generation-id fingerprint
       (require-array root "patches" string? "Scheme source strings"
                      max-persisted-patches)
       (json-object-ref root "created_at" (timestamp))
       #t (json-object-ref root "fork" json-null) (make-mutex) lock-port))))

(define (open-session! state-directory name mode)
  (unless (safe-session-name? name)
    (error "session names must match [A-Za-z0-9][A-Za-z0-9._-]*" name))
  (unless (memq mode '(auto new resume))
    (error "unknown session open mode" mode))
  (let* ((root (session-root state-directory))
         (directory (string-append root "/" name))
         (path (checkpoint-path directory))
         (exists? (file-exists? path)))
    (when (and (eq? mode 'new) exists?)
      (error "session already exists" name))
    (when (and (eq? mode 'resume) (not exists?))
      (error "session does not exist" name))
    (ensure-directory! directory)
    (let ((lock-port (acquire-session-lock directory name)))
      (catch #t
        (lambda ()
          (if exists?
              (read-session directory name lock-port)
              (%make-session-state
               name (fresh-session-id) directory '() 1 1 #f '()
               (timestamp) #f json-null (make-mutex) lock-port)))
        (lambda (key . arguments)
          (unless (port-closed? lock-port) (close-port lock-port))
          (apply throw key arguments))))))

(define (list-session-names state-directory)
  (let ((root (session-root state-directory)))
    (if (not (file-exists? root))
        '()
        (sort
         (filter
          (lambda (name)
            (and (safe-session-name? name)
                 (file-exists?
                  (string-append root "/" name "/session.json"))))
          (scandir root (lambda (name) (not (member name '("." ".."))))))
         string<?))))

(define (fork-session! state-directory parent-name child-name)
  (unless (and (safe-session-name? parent-name)
               (safe-session-name? child-name))
    (error "session names must match [A-Za-z0-9][A-Za-z0-9._-]*"))
  (when (string=? parent-name child-name)
    (error "child session name must differ from parent" child-name))
  (let* ((root (session-root state-directory))
         (parent-directory (string-append root "/" parent-name))
         (child-directory (string-append root "/" child-name))
         (parent-path (checkpoint-path parent-directory))
         (child-path (checkpoint-path child-directory)))
    (unless (file-exists? parent-path)
      (error "parent session does not exist" parent-name))
    (when (file-exists? child-path)
      (error "child session already exists" child-name))
    (when (> (stat:size (stat parent-path)) max-checkpoint-bytes)
      (error "parent session checkpoint exceeds the 8 MiB limit" parent-path))
    (let* ((parent
            (call-with-input-file
                parent-path
              (lambda (port) (json-read (get-string-all port)))))
           (version (and (json-object? parent)
                         (json-object-ref parent "version" #f)))
           (stored-name (and (json-object? parent)
                             (json-object-ref parent "name" #f)))
           (parent-id (and (json-object? parent)
                           (json-object-ref parent "id" #f)))
           (next-turn (and (json-object? parent)
                           (json-object-ref parent "next_turn" #f)))
           (generation-id
            (and (json-object? parent)
                 (json-object-ref parent "generation_id" #f)))
           (fingerprint
            (and (json-object? parent)
                 (json-object-ref parent "fingerprint" #f)))
           (history
            (and (json-object? parent)
                 (require-array parent "history" json-object? "message objects"
                                max-history-messages)))
           (patches
            (and (json-object? parent)
                 (require-array parent "patches" string? "Scheme source strings"
                                max-persisted-patches))))
      (unless (and (equal? version 1)
                   (string? stored-name) (string=? stored-name parent-name)
                   (string? parent-id) (not (string-null? parent-id))
                   (integer? next-turn) (> next-turn 0)
                   (integer? generation-id) (> generation-id 0)
                   (string? fingerprint) (not (string-null? fingerprint)))
        (error "invalid or mismatched parent session checkpoint" parent-path))
      (ensure-directory! child-directory)
      (let* ((forked-at (timestamp))
             (parent-authority
              (string-append parent-directory "/authority.json"))
             (child-authority
              (string-append child-directory "/authority.json"))
             (authority-content
              (and
               (file-exists? parent-authority)
               (begin
                 (when (> (stat:size (stat parent-authority)) (* 64 1024))
                   (error "session authority record is too large"
                          parent-authority))
                 (call-with-input-file parent-authority get-string-all))))
             (child
              (json-object
               (cons "version" 1)
               (cons "name" child-name)
               (cons "id" (fresh-session-id))
               (cons "created_at" forked-at)
               (cons "updated_at" forked-at)
               (cons "source" (json-object-ref parent "source" ""))
               (cons "next_turn" next-turn)
               (cons "generation_id" generation-id)
               (cons "fingerprint" fingerprint)
               (cons "tools"
                     (json-object-ref parent "tools" (json-array)))
               (cons "patches" (apply json-array patches))
               (cons "history" (apply json-array history))
               (cons
                "fork"
                (json-object
                 (cons "parent_name" parent-name)
                 (cons "parent_id" parent-id)
                 (cons "parent_turn" next-turn)
                 (cons "generation_id" generation-id)
                 (cons "fingerprint" fingerprint)
                 (cons "created_at" forked-at))))))
        (when authority-content
          (atomic-write! child-authority authority-content))
        (let ((parent-settings (string-append (dirname parent-path) "/settings.json"))
              (child-settings (string-append (dirname child-path) "/settings.json")))
          (when (file-exists? parent-settings)
            (when (> (stat:size (stat parent-settings)) 32768) (error "parent settings too large"))
            (atomic-write! child-settings (call-with-input-file parent-settings get-string-all))))
        (atomic-write! child-path (string-append (json-write child) "\n"))
        child))))

(define (save-session! state runtime history next-turn)
  (unless (and (list? history)
               (every json-object? history)
               (<= (length history) max-history-messages))
    (error "conversation history cannot be checkpointed"
           (length history)))
  (with-mutex (session-lock state)
    (let* ((generation (runtime-current runtime))
           (patches (generation-patches generation))
           (value
            (json-object
             (cons "version" 1)
             (cons "name" (session-name state))
             (cons "fork" (session-fork state))
             (cons "id" (session-id state))
             (cons "created_at" (session-created-at state))
             (cons "updated_at" (timestamp))
             (cons "source" (generation-source-path generation))
             (cons "next_turn" next-turn)
             (cons "generation_id" (generation-id generation))
             (cons "fingerprint" (generation-fingerprint generation))
             (cons "tools"
                   (apply
                    json-array
                    (map
                     symbol->string
                     (generation-ref generation 'agent-tools))))
             (cons "patches" (apply json-array patches))
             (cons "history" (apply json-array history)))))
      (atomic-write!
       (checkpoint-path (session-directory state))
       (string-append (json-write value) "\n")))))
