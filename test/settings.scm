(use-modules (srfi srfi-64) (srfi srfi-1) (ice-9 textual-ports) (live-agent settings) (live-agent json))
(test-begin "settings")
(define root (string-append "/tmp/shift-settings-" (number->string (getpid))))
(system* "mkdir" "-p" (string-append root "/project") (string-append root "/session") (string-append root "/config"))
(setenv "XDG_CONFIG_HOME" (string-append root "/config"))
(define (file-json path) (call-with-input-file path (lambda (p) (json-read (get-string-all p)))))
(settings-init! (string-append root "/project") (string-append root "/session"))
(test-equal "no prefixes to begin with" '() (setting-ref #f 'run-allow))
(allow-run! '("make" "test") 'project)
(test-equal "a project prefix is effective at once" '(("make" "test")) (setting-ref #f 'run-allow))
(test-equal "and lands in the committable project file"
  "[[\"make\",\"test\"]]" (json-write (json-object-ref (file-json (string-append root "/project/settings.json")) "run-allow")))
(allow-run! '("git" "status") 'user)
(allow-run! '("git" "log") 'session)
(test-equal "scopes union, user then project then session"
  '(("git" "status") ("make" "test") ("git" "log")) (setting-ref #f 'run-allow))
(test-equal "entries name their scope" '(user project session) (map cdr (run-allow-entries)))
(test-equal "the session file holds only session prefixes"
  "[[\"git\",\"log\"]]" (json-write (json-object-ref (file-json (string-append root "/session/settings.json")) "run-allow")))
(settings-set! (list (cons 'mode 'plan)))
(test-equal "other session settings do not drag project prefixes into the session file"
  "[[\"git\",\"log\"]]" (json-write (json-object-ref (file-json (string-append root "/session/settings.json")) "run-allow")))
(call-with-output-file (string-append root "/project/settings.json")
  (lambda (p) (display "{\"mode\":\"plan\",\"run-allow\":[[\"make\",\"test\"]]}" p)))
(settings-init! (string-append root "/project") (string-append root "/session"))
(allow-run! '("cargo" "test") 'project)
(test-equal "project files keep their other keys when a prefix is added" "plan"
  (json-object-ref (file-json (string-append root "/project/settings.json")) "mode"))
(test-equal "and the project list grows in order"
  '(("make" "test") ("cargo" "test")) (map (lambda (p) (json-array-items p)) (json-array-items (json-object-ref (file-json (string-append root "/project/settings.json")) "run-allow"))))
(settings-init! (string-append root "/project") (string-append root "/session"))
(test-equal "a fresh load unions the files again"
  '(("git" "status") ("make" "test") ("cargo" "test") ("git" "log")) (setting-ref #f 'run-allow))
(test-error "prefixes must be non-empty argv" #t (allow-run! '() 'project))
(test-error "scopes are user, project or session" #t (allow-run! '("ls") 'global))
(system* "rm" "-rf" root)
(test-end "settings")
