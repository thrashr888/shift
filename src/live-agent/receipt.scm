;; The end-of-turn receipt: one record saying what a turn did, projected from
;; the change ledger, the run records, and the turn's provider usage. It is
;; not a store of its own; traces and the ledger stay the source of truth.
;; The same record renders as REPL text, as a JSON line in receipts.jsonl,
;; and as receipt.* attributes on the agent.turn span.
(define-module (live-agent receipt)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (live-agent changes)
  #:use-module (live-agent diff)
  #:use-module (live-agent json)
  #:export (build-receipt receipt->json receipt->text receipt-attributes
            receipt-append! receipt-write! receipt-from-json))

(define (timestamp)
  (strftime "%Y-%m-%dT%H:%M:%SZ" (gmtime (current-time))))

(define (json-or-null value) (if value value json-null))

;; Committed changes of one turn with a diffstat from the stored pre and post
;; images, so the receipt reports what the ledger can prove.
(define (changed-files ledger turn)
  (if (not ledger)
      '()
      (map (lambda (group)
             (let* ((path (car group))
                    (before-hash (cadr group))
                    (after-hash (caddr group))
                    (before (and before-hash (ledger-read-blob ledger before-hash)))
                    (after (and after-hash (ledger-read-blob ledger after-hash)))
                    (stat (if (or before after)
                              (diffstat (unified-diff before after
                                                      (string-append "a/" path)
                                                      (string-append "b/" path)))
                              '(0 . 0))))
               `((path . ,path)
                 (added . ,(car stat))
                 (removed . ,(cdr stat))
                 (created . ,(not before-hash))
                 (deleted . ,(not after-hash))
                 (before . ,before-hash)
                 (after . ,after-hash))))
           (ledger-turn-groups ledger turn))))

(define (turn-runs ledger turn)
  (if (not ledger)
      '()
      (filter-map
       (lambda (record)
         (and (equal? (json-object-ref record "turn" #f) turn)
              (let ((invocation (json-object-ref record "invocation" (json-object)))
                    (outcome (json-object-ref record "outcome" (json-object))))
                `((command . ,(json-array-items
                               (json-object-ref (json-object-ref invocation "input" (json-object))
                                                "command" (json-array))))
                  (mode . ,(json-object-ref invocation "mode" "local"))
                  (exit_code . ,(json-object-ref outcome "exit_code" -1))
                  (success . ,(eq? #t (json-object-ref outcome "success" #f)))
                  (status . ,(json-object-ref record "status" "exit"))
                  (duration_ms . ,(json-object-ref record "duration_ms" 0))
                  (log . ,(json-object-ref record "log" #f))))))
       (ledger-runs ledger))))

;; `usage` is an alist with prompt, cached, uncached, completion, and rounds;
;; `tool-calls` is an alist of tool name to count. `status` is ok, failed, or
;; cancelled, and `error` is the failure detail or #f.
(define* (build-receipt #:key turn status error model provider generation
                        duration-ms usage tool-calls ledger
                        trace-id span-id session-name session-id)
  (let ((changed (changed-files ledger turn)))
    `((turn . ,turn)
      (at . ,(timestamp))
      (status . ,status)
      (error . ,error)
      (model . ,model)
      (provider . ,provider)
      (generation . ,generation)
      (duration_ms . ,duration-ms)
      (rounds . ,(or (assq-ref usage 'rounds) 0))
      (tokens . ((prompt . ,(or (assq-ref usage 'prompt) 0))
                 (cached . ,(or (assq-ref usage 'cached) 0))
                 (uncached . ,(or (assq-ref usage 'uncached) 0))
                 (completion . ,(or (assq-ref usage 'completion) 0))))
      (tool_calls . ,(or tool-calls '()))
      (changed . ,changed)
      (runs . ,(turn-runs ledger turn))
      (undo . ,(and ledger (pair? changed)
                    (if (memv turn (ledger-undoable-turns ledger)) #t #f)))
      (trace_id . ,trace-id)
      (span_id . ,span-id)
      (session . ,session-name)
      (session_id . ,session-id)
      (resume . ,(and session-name (string-append "./bin/shift --resume " session-name))))))

(define (receipt->json receipt)
  (define (get key) (assq-ref receipt key))
  (json-object
   (cons "turn" (get 'turn))
   (cons "at" (get 'at))
   (cons "status" (get 'status))
   (cons "error" (json-or-null (get 'error)))
   (cons "model" (json-or-null (get 'model)))
   (cons "provider" (json-or-null (get 'provider)))
   (cons "generation" (json-or-null (get 'generation)))
   (cons "duration_ms" (get 'duration_ms))
   (cons "rounds" (get 'rounds))
   (cons "tokens" (apply json-object
                         (map (lambda (entry) (cons (symbol->string (car entry)) (cdr entry)))
                              (get 'tokens))))
   (cons "tool_calls" (apply json-object
                             (map (lambda (entry) (cons (car entry) (cdr entry)))
                                  (get 'tool_calls))))
   (cons "changed" (apply json-array
                          (map (lambda (change)
                                 (json-object
                                  (cons "path" (assq-ref change 'path))
                                  (cons "added" (assq-ref change 'added))
                                  (cons "removed" (assq-ref change 'removed))
                                  (cons "created" (assq-ref change 'created))
                                  (cons "deleted" (assq-ref change 'deleted))
                                  (cons "before" (json-or-null (assq-ref change 'before)))
                                  (cons "after" (json-or-null (assq-ref change 'after)))))
                               (get 'changed))))
   (cons "runs" (apply json-array
                       (map (lambda (run)
                              (json-object
                               (cons "command" (apply json-array (assq-ref run 'command)))
                               (cons "mode" (assq-ref run 'mode))
                               (cons "exit_code" (assq-ref run 'exit_code))
                               (cons "success" (assq-ref run 'success))
                               (cons "status" (assq-ref run 'status))
                               (cons "duration_ms" (assq-ref run 'duration_ms))
                               (cons "log" (json-or-null (assq-ref run 'log)))))
                            (get 'runs))))
   (cons "undo" (get 'undo))
   (cons "trace_id" (json-or-null (get 'trace_id)))
   (cons "span_id" (json-or-null (get 'span_id)))
   (cons "session" (json-or-null (get 'session)))
   (cons "session_id" (json-or-null (get 'session_id)))
   (cons "resume" (json-or-null (get 'resume)))))

(define (null->false value) (if (eq? value json-null) #f value))

;; Inverse of receipt->json for readers of receipts.jsonl inside Shift.
(define (receipt-from-json object)
  (define (get key . default) (null->false (json-object-ref object key (if (pair? default) (car default) json-null))))
  `((turn . ,(get "turn"))
    (at . ,(get "at" ""))
    (status . ,(get "status" "ok"))
    (error . ,(get "error"))
    (model . ,(get "model"))
    (provider . ,(get "provider"))
    (generation . ,(get "generation"))
    (duration_ms . ,(get "duration_ms" 0))
    (rounds . ,(get "rounds" 0))
    (tokens . ,(map (lambda (entry) (cons (string->symbol (car entry)) (cdr entry)))
                    (json-object-entries (get "tokens" (json-object)))))
    (tool_calls . ,(json-object-entries (get "tool_calls" (json-object))))
    (changed . ,(map (lambda (change)
                       `((path . ,(json-object-ref change "path"))
                         (added . ,(json-object-ref change "added" 0))
                         (removed . ,(json-object-ref change "removed" 0))
                         (created . ,(json-object-ref change "created" #f))
                         (deleted . ,(json-object-ref change "deleted" #f))
                         (before . ,(null->false (json-object-ref change "before" json-null)))
                         (after . ,(null->false (json-object-ref change "after" json-null)))))
                     (json-array-items (get "changed" (json-array)))))
    (runs . ,(map (lambda (run)
                    `((command . ,(json-array-items (json-object-ref run "command" (json-array))))
                      (mode . ,(json-object-ref run "mode" "local"))
                      (exit_code . ,(json-object-ref run "exit_code" -1))
                      (success . ,(json-object-ref run "success" #f))
                      (status . ,(json-object-ref run "status" "exit"))
                      (duration_ms . ,(json-object-ref run "duration_ms" 0))
                      (log . ,(null->false (json-object-ref run "log" json-null)))))
                  (json-array-items (get "runs" (json-array)))))
    (undo . ,(get "undo" #f))
    (trace_id . ,(get "trace_id"))
    (span_id . ,(get "span_id"))
    (session . ,(get "session"))
    (session_id . ,(get "session_id"))
    (resume . ,(get "resume"))))

;; Flat attributes for the agent.turn span, so /traces and an OTel viewer show
;; the same facts without reading receipts.jsonl.
(define (receipt-attributes receipt)
  (let ((tokens (assq-ref receipt 'tokens))
        (changed (assq-ref receipt 'changed))
        (runs (assq-ref receipt 'runs)))
    `((receipt.status . ,(assq-ref receipt 'status))
      (receipt.rounds . ,(assq-ref receipt 'rounds))
      (receipt.tokens.prompt . ,(assq-ref tokens 'prompt))
      (receipt.tokens.cached . ,(assq-ref tokens 'cached))
      (receipt.tokens.completion . ,(assq-ref tokens 'completion))
      (receipt.tool_calls . ,(fold + 0 (map cdr (assq-ref receipt 'tool_calls))))
      (receipt.changed . ,(length changed))
      (receipt.files . ,(string-join (map (lambda (change) (assq-ref change 'path)) changed) ","))
      (receipt.runs . ,(length runs))
      (receipt.runs_failed . ,(count (lambda (run) (not (assq-ref run 'success))) runs))
      (receipt.undo . ,(if (assq-ref receipt 'undo) #t #f)))))

(define (short-id value)
  (if (and (string? value) (> (string-length value) 8))
      (string-append (substring value 0 8) "…")
      (or value "none")))

(define (seconds ms)
  (format #f "~as" (/ (round (/ (or ms 0) 100.0)) 10.0)))

(define (receipt->text receipt)
  (define (get key) (assq-ref receipt key))
  (let* ((tokens (get 'tokens))
         (cached (assq-ref tokens 'cached))
         (changed (get 'changed))
         (runs (get 'runs))
         (status (get 'status))
         (lines
          (append
           (list
            (format #f "turn ~a · ~a · generation ~a · ~a round~:p · ~:d in~a + ~:d out · ~a"
                    (get 'turn) (or (get 'model) "no model") (or (get 'generation) "?")
                    (get 'rounds) (assq-ref tokens 'prompt)
                    (if (and (number? cached) (> cached 0)) (format #f " (~:d cached)" cached) "")
                    (assq-ref tokens 'completion) (seconds (get 'duration_ms))))
           (if (string=? status "ok")
               '()
               (list (format #f "status   ~a~a" status
                             (if (get 'error) (string-append " · " (get 'error)) ""))))
           (list
            (if (null? changed)
                "changed  none"
                (string-append
                 "changed  "
                 (string-join
                  (map (lambda (change)
                         (format #f "~a ~a~a" (assq-ref change 'path)
                                 (format-diffstat (cons (assq-ref change 'added) (assq-ref change 'removed)))
                                 (cond ((assq-ref change 'created) " new")
                                       ((assq-ref change 'deleted) " deleted")
                                       (else ""))))
                       changed)
                  "  "))))
           (map (lambda (run)
                  (format #f "ran      ~a  ~a  ~a"
                          (string-join (assq-ref run 'command) " ")
                          (let ((run-status (assq-ref run 'status)))
                            (if (string=? run-status "exit")
                                (format #f "exit ~a" (assq-ref run 'exit_code))
                                run-status))
                          (seconds (assq-ref run 'duration_ms))))
                runs)
           (if (get 'undo) (list "undo     available (/undo)") '())
           (list
            (string-append
             (format #f "trace    ~a span ~a" (short-id (get 'trace_id)) (short-id (get 'span_id)))
             (if (get 'resume) (string-append "   resume " (get 'resume)) ""))))))
    (string-join lines "\n" 'suffix)))

(define (receipt-append! path receipt)
  (let ((port (open-file path "a")))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (display (json-write (receipt->json receipt)) port)
        (newline port)
        (force-output port))
      (lambda () (close-port port)))))

;; One receipt as a whole file, for --receipt FILE in print mode.
(define (receipt-write! path receipt)
  (call-with-output-file path
    (lambda (port)
      (display (json-write (receipt->json receipt)) port)
      (newline port))))
