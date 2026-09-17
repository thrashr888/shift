;; Grade a live-repair attempt: build the generation from the agent file plus
;; the session's live patches, then run the task's check against it.
;;   guile -L src -L extensions scripts/live_repair_check.scm AGENT STATE-DIR SESSION-JSON CHECK.SCM
(use-modules (ice-9 textual-ports) (live-agent json) (live-agent runtime) (live-agent generation))
(define (main args)
  (let* ((agent (list-ref args 1)) (state (list-ref args 2)) (session (list-ref args 3)) (check (list-ref args 4))
         (patches (if (file-exists? session)
                      (let ((root (call-with-input-file session (lambda (p) (json-read (get-string-all p))))))
                        (json-array-items (json-object-ref root "patches" (json-array))))
                      '()))
         (runtime (make-runtime agent state patches))
         (module (resolve-module '(live-repair-check-scratch)))
         (verdict (lambda (label g) (let ((ok (catch #t (lambda () ((module-ref module 'check) g)) (lambda _ #f))))
                                       (format #t "~a ~a~%" label (if ok "resolved" "unresolved")) ok))))
    (module-use! module (resolve-interface '(guile)))
    (module-use! module (resolve-interface '(live-agent generation)))
    (save-module-excursion (lambda () (set-current-module module) (load (canonicalize-path check))))
    (let ((first (verdict "check" (runtime-current runtime))))
      ;; Live patches must survive a reload of the same source file.
      (runtime-reload! runtime #t)
      (let ((second (verdict "after-reload" (runtime-current runtime))))
        (exit (if (and first second) 0 1))))))
(main (command-line))
