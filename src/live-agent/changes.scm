;; The change ledger: every file the session observed or mutated, with SHA-256
;; hashes and content-addressed pre/post images. It is append-only JSON lines
;; plus a blob directory, replayed into memory on open. Undo, receipts, stale
;; detection, and interrupted-mutation recovery are all projections of it.
(define-module (live-agent changes)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 threads)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (live-agent json)
  #:use-module (live-agent sha256)
  #:export (open-ledger
            ledger?
            ledger-directory
            file-hash
            ledger-observe!
            ledger-seen
            ledger-check-stale!
            ledger-begin!
            ledger-commit!
            ledger-abort!
            ledger-entries
            ledger-turn-entries
            ledger-open-entry
            ledger-open-entries
            ledger-resolve-open!
            ledger-undoable-turns
            ledger-last-undo
            ledger-turn-groups
            ledger-undo!
            ledger-seen-paths
            ledger-record-run!
            ledger-runs
            ledger-store-blob!
            ledger-read-blob
            ledger-blob-path))

(define-record-type <ledger>
  (%make-ledger directory path blobs entries seen next-seq lock runs undone)
  ledger?
  (directory ledger-directory)
  (path ledger-path)
  (blobs ledger-blobs)
  (entries ledger-entry-table)
  (seen ledger-seen-table)
  (next-seq ledger-next-seq set-ledger-next-seq!)
  (lock ledger-lock)
  (runs ledger-run-list set-ledger-run-list!)
  (undone ledger-undone set-ledger-undone!))

(define (timestamp)
  (strftime "%Y-%m-%dT%H:%M:%SZ" (gmtime (current-time))))

(define (ensure-directory! path)
  (unless (file-exists? path)
    (let ((parent (dirname path)))
      (unless (or (string=? parent path) (file-exists? parent))
        (ensure-directory! parent)))
    (mkdir path)))

(define (file-hash path)
  (and (file-exists? path)
       (not (eq? 'directory (stat:type (stat path))))
       (sha256-file path)))

(define (json-or-null value) (if value value json-null))
(define (null->false value) (if (eq? value json-null) #f value))

(define (entry-from-json object)
  `((seq . ,(json-object-ref object "seq"))
    (turn . ,(json-object-ref object "turn"))
    (call_id . ,(null->false (json-object-ref object "call_id" json-null)))
    (tool . ,(json-object-ref object "tool"))
    (path . ,(json-object-ref object "path"))
    (before . ,(null->false (json-object-ref object "before" json-null)))
    (after . ,(null->false (json-object-ref object "after" json-null)))
    (state . ,(string->symbol (json-object-ref object "state")))
    (at . ,(json-object-ref object "at" ""))))

(define (entry->json entry)
  (json-object
   (cons "kind" "change")
   (cons "seq" (assq-ref entry 'seq))
   (cons "turn" (assq-ref entry 'turn))
   (cons "call_id" (json-or-null (assq-ref entry 'call_id)))
   (cons "tool" (assq-ref entry 'tool))
   (cons "path" (assq-ref entry 'path))
   (cons "before" (json-or-null (assq-ref entry 'before)))
   (cons "after" (json-or-null (assq-ref entry 'after)))
   (cons "state" (symbol->string (assq-ref entry 'state)))
   (cons "at" (assq-ref entry 'at))))

(define (replay! ledger)
  (when (file-exists? (ledger-path ledger))
    (call-with-input-file (ledger-path ledger)
      (lambda (port)
        (let loop ((line (get-line port)))
          (unless (eof-object? line)
            (catch #t
              (lambda ()
                (let* ((object (json-read line))
                       (kind (json-object-ref object "kind" "")))
                  (cond
                   ((string=? kind "seen")
                    (hash-set! (ledger-seen-table ledger)
                               (json-object-ref object "path")
                               (cons (json-object-ref object "hash")
                                     (json-object-ref object "turn"))))
                   ((string=? kind "run")
                    (set-ledger-run-list! ledger (cons object (ledger-run-list ledger))))
                   ((string=? kind "undo")
                    (set-ledger-undone! ledger (cons (json-object-ref object "turn")
                                                     (ledger-undone ledger))))
                   ((string=? kind "change")
                    (let ((entry (entry-from-json object)))
                      (hash-set! (ledger-entry-table ledger) (assq-ref entry 'seq) entry)
                      (set-ledger-next-seq! ledger (max (ledger-next-seq ledger)
                                                        (+ 1 (assq-ref entry 'seq))))
                      (when (and (eq? (assq-ref entry 'state) 'committed)
                                 (assq-ref entry 'after))
                        (hash-set! (ledger-seen-table ledger) (assq-ref entry 'path)
                                   (cons (assq-ref entry 'after) (assq-ref entry 'turn)))))))))
              ;; A torn final line from a crash is skipped, never fatal.
              (lambda _ #f))
            (loop (get-line port))))))))

(define (open-ledger directory)
  (ensure-directory! directory)
  (let ((ledger (%make-ledger directory
                              (string-append directory "/changes.jsonl")
                              (string-append directory "/blobs")
                              (make-hash-table)
                              (make-hash-table)
                              1
                              (make-mutex)
                              '()
                              '())))
    (replay! ledger)
    ledger))

(define (atomic-write-text! path text)
  (let* ((port (mkstemp (string-append (dirname path) "/.shift-restore-XXXXXX")))
         (temporary (port-filename port)))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (display text port)
        (force-output port)
        (close-port port)
        (rename-file temporary path))
      (lambda ()
        (unless (port-closed? port) (close-port port))
        (when (file-exists? temporary) (delete-file temporary))))))

;; Put a path back to a recorded image: #f removes the file.
(define (restore-path! ledger root path hash)
  (let ((absolute (string-append root "/" path)))
    (if hash
        (let ((text (ledger-read-blob ledger hash)))
          (unless text (error "pre-image is missing from the blob store" path hash))
          (atomic-write-text! absolute text))
        (when (file-exists? absolute) (delete-file absolute)))
    (unless (equal? (file-hash absolute) hash)
      (error "restore verification failed" path))))

;; Committed entries of one turn, one group per path:
;; (path earliest-before latest-after).
(define (ledger-turn-groups ledger turn)
  (let loop ((entries (ledger-turn-entries ledger turn)) (groups '()))
    (if (null? entries)
        (reverse groups)
        (let* ((entry (car entries))
               (path (assq-ref entry 'path))
               (existing (assoc path groups)))
          (loop (cdr entries)
                (if existing
                    (map (lambda (group)
                           (if (eq? group existing)
                               (list path (cadr group) (assq-ref entry 'after))
                               group))
                         groups)
                    (cons (list path (assq-ref entry 'before) (assq-ref entry 'after)) groups)))))))

;; Newest first, skipping turns already undone.
(define (ledger-undoable-turns ledger)
  (let ((turns (delete-duplicates
                (map (lambda (entry) (assq-ref entry 'turn))
                     (filter (lambda (entry) (eq? (assq-ref entry 'state) 'committed))
                             (ledger-entries ledger))))))
    (sort (filter (lambda (turn) (not (memv turn (ledger-undone ledger)))) turns) >)))

;; The most recently successful undo, newest first: ledger-undo! prepends each
;; turn, so the head is the last one that actually reverted. A refused undo is
;; never recorded, and later edits leave the recorded turn untouched.
(define (ledger-last-undo ledger)
  (let ((undone (ledger-undone ledger)))
    (and (pair? undone) (car undone))))

(define (short hash) (if (string? hash) (substring hash 0 12) "absent"))

;; Restores every file the turn changed, only if all of them still match the
;; recorded post-images. There is no force: a diverged file is the user's call.
(define (ledger-undo! ledger root turn)
  (let ((groups (ledger-turn-groups ledger turn)))
    (when (null? groups) (error "turn has no committed changes to undo" turn))
    (when (memv turn (ledger-undone ledger)) (error "turn is already undone" turn))
    (let ((diverged
           (filter (lambda (group)
                     (not (equal? (file-hash (string-append root "/" (car group))) (caddr group))))
                   groups)))
      (unless (null? diverged)
        (error (format #f "cannot undo turn ~a: ~a changed since then; resolve by hand or undo nothing"
                       turn
                       (string-join
                        (map (lambda (group)
                               (format #f "~a (expected ~a…, now ~a…)" (car group) (short (caddr group))
                                       (short (file-hash (string-append root "/" (car group))))))
                             diverged)
                        ", ")))))
    (for-each (lambda (group) (restore-path! ledger root (car group) (cadr group))) groups)
    (with-mutex (ledger-lock ledger)
      (for-each (lambda (group)
                  (hash-set! (ledger-seen-table ledger) (car group) (cons (cadr group) turn)))
                groups)
      (set-ledger-undone! ledger (cons turn (ledger-undone ledger)))
      (append-line! ledger
                    (json-object (cons "kind" "undo")
                                 (cons "turn" turn)
                                 (cons "paths" (apply json-array (map car groups)))
                                 (cons "at" (timestamp)))))
    groups))

(define (ledger-open-entries ledger)
  (filter (lambda (entry) (eq? (assq-ref entry 'state) 'started))
          (ledger-entries ledger)))

;; After a crash or cancellation, settle each in-flight mutation from its
;; hashes: untouched files close the entry, completed writes are put back to
;; the pre-image, and anything else is left for the user. Returns
;; (path . unchanged|restored|diverged) pairs.
(define (ledger-resolve-open! ledger root)
  (map (lambda (entry)
         (let* ((path (assq-ref entry 'path))
                (seq (assq-ref entry 'seq))
                (current (file-hash (string-append root "/" path))))
           (cond
            ((equal? current (assq-ref entry 'before))
             (transition! ledger seq 'aborted)
             (cons path 'unchanged))
            ((equal? current (assq-ref entry 'after))
             (restore-path! ledger root path (assq-ref entry 'before))
             (transition! ledger seq 'aborted)
             (cons path 'restored))
            (else (cons path 'diverged)))))
       (ledger-open-entries ledger)))

;; Command runs share the journal so receipts and status see one timeline.
;; `record` is a JSON object without kind, turn, or at.
(define (ledger-record-run! ledger turn record)
  (with-mutex (ledger-lock ledger)
    (let ((object (apply json-object
                         (cons "kind" "run")
                         (cons "turn" turn)
                         (cons "at" (timestamp))
                         (json-object-entries record))))
      (set-ledger-run-list! ledger (cons object (ledger-run-list ledger)))
      (append-line! ledger object)
      object)))

;; Oldest first.
(define (ledger-runs ledger)
  (reverse (ledger-run-list ledger)))

(define (ledger-seen-paths ledger)
  (sort (hash-map->list (lambda (path entry) path) (ledger-seen-table ledger)) string<?))

(define (append-line! ledger value)
  (let ((port (open-file (ledger-path ledger) "a")))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (display (json-write value) port)
        (newline port)
        (force-output port))
      (lambda () (close-port port)))))

;; Blobs are written atomically and deduplicated by hash.
(define (ledger-blob-path ledger hash)
  (string-append (ledger-blobs ledger) "/" hash))

(define (ledger-store-blob! ledger text)
  (let* ((hash (sha256-string text))
         (path (ledger-blob-path ledger hash)))
    (unless (file-exists? path)
      (ensure-directory! (ledger-blobs ledger))
      (let* ((port (mkstemp (string-append (ledger-blobs ledger) "/.blob-XXXXXX")))
             (temporary (port-filename port)))
        (dynamic-wind
          (lambda () #t)
          (lambda ()
            (display text port)
            (force-output port)
            (close-port port)
            (rename-file temporary path))
          (lambda ()
            (unless (port-closed? port) (close-port port))
            (when (file-exists? temporary) (delete-file temporary))))))
    hash))

(define (ledger-read-blob ledger hash)
  (let ((path (ledger-blob-path ledger hash)))
    (and (file-exists? path)
         (call-with-input-file path get-string-all))))

;; Observation: the session saw this exact content. Unchanged hashes are not
;; re-appended, so repeated reads stay cheap on disk.
(define (ledger-observe! ledger turn path hash)
  (with-mutex (ledger-lock ledger)
    (let ((current (hash-ref (ledger-seen-table ledger) path #f)))
      (unless (and current (equal? (car current) hash))
        (hash-set! (ledger-seen-table ledger) path (cons hash turn))
        (append-line! ledger
                      (json-object (cons "kind" "seen")
                                   (cons "path" path)
                                   (cons "hash" (json-or-null hash))
                                   (cons "turn" turn)
                                   (cons "at" (timestamp))))))))

;; (hash . turn) or #f.
(define (ledger-seen ledger path)
  (hash-ref (ledger-seen-table ledger) path #f))

(define (short-hash hash)
  (if (string? hash) (string-append (substring hash 0 12) "…") "absent"))

(define (ledger-check-stale! ledger path current-hash)
  (let ((seen (ledger-seen ledger path)))
    (when (and seen (not (equal? (car seen) current-hash)))
      (error
       (format #f "~a changed on disk since turn ~a (~a → ~a); read it again before editing"
               path (cdr seen) (short-hash (car seen)) (short-hash current-hash))))
    #t))

;; Write-ahead: the pre-image and the prepared post-image are stored and the
;; entry is journaled as started before any project file is touched.
(define (ledger-begin! ledger turn call-id tool path before-text after-text)
  (with-mutex (ledger-lock ledger)
    (let* ((seq (ledger-next-seq ledger))
           (entry `((seq . ,seq)
                    (turn . ,turn)
                    (call_id . ,call-id)
                    (tool . ,tool)
                    (path . ,path)
                    (before . ,(and before-text (ledger-store-blob! ledger before-text)))
                    (after . ,(and after-text (ledger-store-blob! ledger after-text)))
                    (state . started)
                    (at . ,(timestamp)))))
      (set-ledger-next-seq! ledger (+ seq 1))
      (hash-set! (ledger-entry-table ledger) seq entry)
      (append-line! ledger (entry->json entry))
      seq)))

(define (transition! ledger seq state)
  (with-mutex (ledger-lock ledger)
    (let ((entry (hash-ref (ledger-entry-table ledger) seq #f)))
      (unless entry (error "unknown ledger entry" seq))
      (unless (eq? (assq-ref entry 'state) 'started)
        (error "ledger entry is not in progress" seq (assq-ref entry 'state)))
      (let ((updated (map (lambda (pair)
                            (cond ((eq? (car pair) 'state) (cons 'state state))
                                  ((eq? (car pair) 'at) (cons 'at (timestamp)))
                                  (else pair)))
                          entry)))
        (hash-set! (ledger-entry-table ledger) seq updated)
        (append-line! ledger (entry->json updated))
        (when (eq? state 'committed)
          (hash-set! (ledger-seen-table ledger) (assq-ref updated 'path)
                     (cons (assq-ref updated 'after) (assq-ref updated 'turn))))
        updated))))

(define (ledger-commit! ledger seq) (transition! ledger seq 'committed))
(define (ledger-abort! ledger seq) (transition! ledger seq 'aborted))

(define (ledger-entries ledger)
  (sort (hash-map->list (lambda (seq entry) entry) (ledger-entry-table ledger))
        (lambda (a b) (< (assq-ref a 'seq) (assq-ref b 'seq)))))

(define (ledger-turn-entries ledger turn)
  (filter (lambda (entry)
            (and (= (assq-ref entry 'turn) turn)
                 (eq? (assq-ref entry 'state) 'committed)))
          (ledger-entries ledger)))

;; The newest entry still marked started, which after a crash is the
;; mutation whose outcome must be inspected.
(define (ledger-open-entry ledger)
  (let ((open (filter (lambda (entry) (eq? (assq-ref entry 'state) 'started))
                      (ledger-entries ledger))))
    (and (pair? open) (last open))))
