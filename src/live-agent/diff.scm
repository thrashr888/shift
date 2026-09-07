;; Unified diffs for previews, receipts, and undo displays. Text goes through
;; temporary files to `diff -u`, spawned without a shell, so a preview never
;; touches the project tree.
(define-module (live-agent diff)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:export (unified-diff diffstat format-diffstat diff-preview))

(define (temporary-directory)
  (or (getenv "TMPDIR") "/tmp"))

(define (with-temporary-file text proc)
  (if (not text)
      (proc "/dev/null")
      (let* ((port (mkstemp (string-append (temporary-directory) "/shift-diff-XXXXXX")))
             (path (port-filename port)))
        (dynamic-wind
          (lambda () #t)
          (lambda ()
            (display text port)
            (close-port port)
            (proc path))
          (lambda ()
            (unless (port-closed? port) (close-port port))
            (when (file-exists? path) (delete-file path)))))))

(define (run-diff old-path new-path old-label new-label)
  (let* ((ends (pipe))
         (pid (spawn "diff"
                     (list "diff" "-u" "-L" old-label "-L" new-label old-path new-path)
                     #:output (cdr ends) #:error (cdr ends))))
    (close-port (cdr ends))
    (let* ((output (get-string-all (car ends)))
           (code (status:exit-val (cdr (waitpid pid)))))
      (close-port (car ends))
      (cond
       ((= code 0) "")
       ((= code 1) output)
       (else (error "diff failed" code output))))))

;; #f for old-text means the file is being created; #f for new-text means it
;; is being deleted. Labels normally look like a/PATH and b/PATH.
(define (unified-diff old-text new-text old-label new-label)
  (with-temporary-file old-text
    (lambda (old-path)
      (with-temporary-file new-text
        (lambda (new-path)
          (run-diff old-path new-path
                    (if old-text old-label "/dev/null")
                    (if new-text new-label "/dev/null")))))))

;; Returns (added . removed), counting only hunk lines.
(define (diffstat text)
  (let loop ((lines (string-split text #\newline)) (in-hunk? #f) (added 0) (removed 0))
    (cond
     ((null? lines) (cons added removed))
     ((string-prefix? "@@" (car lines)) (loop (cdr lines) #t added removed))
     ((not in-hunk?) (loop (cdr lines) #f added removed))
     ((string-prefix? "+" (car lines)) (loop (cdr lines) #t (+ added 1) removed))
     ((string-prefix? "-" (car lines)) (loop (cdr lines) #t added (+ removed 1)))
     (else (loop (cdr lines) #t added removed)))))

(define (format-diffstat stat)
  (format #f "(+~a −~a)" (car stat) (cdr stat)))

(define (diff-preview text max-lines)
  (let* ((lines (string-split (string-trim-right text #\newline) #\newline))
         (count (length lines)))
    (if (<= count max-lines)
        text
        (string-append
         (string-join (take lines max-lines) "\n")
         (format #f "\n… ~a more lines; use diff turn after approval for the rest\n"
                 (- count max-lines))))))
