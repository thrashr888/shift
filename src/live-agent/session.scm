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
            session-summaries
            session-name
            session-id
            session-directory
            session-history
            session-next-turn
            session-generation-id
            session-fingerprint
            session-patches
            session-resumed?
            session-fork
            safe-session-name?
            safe-session-path?
            session-id-like?
            resolve-session-reference
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


;; Subagents live in agents/ folders under their parent, so a session name is
;; a path whose odd segments are all "agents": default/agents/tests/agents/x.
(define (safe-session-path? value)
  (and (string? value)
       (let ((parts (string-split value #\/)))
         (and (odd? (length parts))
              (let loop ((parts parts) (index 0))
                (or (null? parts)
                    (and (if (even? index)
                             (safe-session-name? (car parts))
                             (string=? (car parts) "agents"))
                         (loop (cdr parts) (+ index 1)))))))))

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
  (unless (safe-session-path? name)
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
      (error (if (session-id-like? name)
                 "no session has that name or id"
                 "session does not exist")
             name))
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

;; A session id is the 32 hex digits `fresh-session-id` makes. Recognising the
;; shape keeps the id lookup off the path of an ordinary mistyped name, which
;; would otherwise read every checkpoint under the root to fail.
(define (session-id-like? value)
  (and (string? value) (= (string-length value) 32)
       (string-every (lambda (c) (or (char-numeric? c) (memv c '(#\a #\b #\c #\d #\e #\f)))) value)))

;; The exit line and every receipt print a session's id, so pasting one back
;; into --resume is the obvious thing to try. A name that exists always wins:
;; resolving only when no session goes by that name means an id can never
;; shadow a session someone named.
(define (resolve-session-reference state-directory reference)
  (if (or (not (session-id-like? reference))
          (and (safe-session-path? reference)
               (file-exists? (checkpoint-path
                              (string-append (session-root state-directory) "/" reference)))))
      reference
      (or (find (lambda (name)
                  (catch #t
                    (lambda ()
                      (let ((root (call-with-input-file
                                      (checkpoint-path (string-append (session-root state-directory) "/" name))
                                    (lambda (port) (json-read (get-string-all port))))))
                        (and (json-object? root)
                             (equal? (json-object-ref root "id" #f) reference))))
                    (lambda _ #f)))
                (list-session-names state-directory))
          reference)))

(define (list-session-names state-directory)
  (let ((root (session-root state-directory)))
    (define (children-of prefix directory)
      (if (not (file-exists? directory))
          '()
          (append-map
           (lambda (name)
             (let ((path (string-append directory "/" name)))
               (if (and (safe-session-name? name)
                        (file-exists? (string-append path "/session.json")))
                   (cons (string-append prefix name)
                         (children-of (string-append prefix name "/agents/")
                                      (string-append path "/agents")))
                   '())))
           (sort (scandir directory (lambda (name) (not (member name '("." "..")))))
                 string<?))))
    (children-of "" root)))

;; What the frontend's session list shows: durable sessions with their turn
;; count, last checkpoint, and whether another live process holds the lock.
;; Probing never creates a lock file or blocks.
(define (session-status directory current?)
  (cond
   (current? "current")
   ((not (file-exists? (string-append directory "/owner.lock"))) "idle")
   (else
    (let ((port (open-file (string-append directory "/owner.lock") "r")))
      (catch 'system-error
        (lambda () (flock port (logior LOCK_EX LOCK_NB)) (flock port LOCK_UN) (close-port port) "idle")
        (lambda _ (close-port port) "running"))))))
(define (session-summaries state-directory current-name)
  (map (lambda (name)
         (let* ((directory (string-append (session-root state-directory) "/" name))
                (path (checkpoint-path directory))
                (root (catch #t
                        (lambda ()
                          (and (<= (stat:size (stat path)) max-checkpoint-bytes)
                               (call-with-input-file path (lambda (port) (json-read (get-string-all port))))))
                        (lambda _ #f)))
                (field (lambda (key default) (if (json-object? root) (json-object-ref root key default) default))))
           (json-object (cons "name" name)
                        (cons "turns" (let ((next (field "next_turn" 1))) (if (number? next) (max 0 (- next 1)) 0)))
                        (cons "updated" (field "updated_at" json-null))
                        (cons "fork" (field "fork" json-null))
                        (cons "status" (session-status directory (equal? name current-name))))))
       (list-session-names state-directory)))

(define* (fork-session! state-directory parent-name child-name #:optional (history? #t))
  (unless (and (safe-session-path? parent-name)
               (safe-session-path? child-name))
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
               (cons "next_turn" (if history? next-turn 1))
               (cons "generation_id" generation-id)
               (cons "fingerprint" fingerprint)
               (cons "tools"
                     (json-object-ref parent "tools" (json-array)))
               (cons "patches" (apply json-array patches))
               (cons "history" (apply json-array (if history? history '())))
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
