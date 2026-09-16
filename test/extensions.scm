(use-modules (srfi srfi-64)
             (live-agent extensions)
             (live-agent generation)
             (live-agent runtime))

(test-begin "extensions")

(define test-root
  (string-append "/tmp/shift-extensions-test-" (number->string (getpid))))
(define extension-root (string-append test-root "/extensions"))
(define state-root (string-append test-root "/state"))
(system* "mkdir" "-p" test-root)

(define runtime (make-runtime "agent/default.scm" state-root))
(define expression "(set! agent-system-prompt \"Persisted extension prompt.\")")

(runtime-validate-patch! runtime expression)
(extension-create! extension-root "persisted-prompt" expression "Test artifact.")

(test-equal "lists named Scheme artifacts"
  '("persisted-prompt")
  (extension-list extension-root))

(test-assert "new artifacts are readable but not implicitly enabled"
  (and (string-contains (extension-read extension-root "persisted-prompt")
                        "Persisted extension prompt")
       (not (member (extension-read extension-root "persisted-prompt")
                    (generation-patches (runtime-current runtime))))))

(define loaded
  (runtime-apply-patch!
   runtime
   (extension-read extension-root "persisted-prompt")
   'extension-load))

(test-equal "loading activates an atomic generation"
  2
  (generation-id loaded))
(test-equal "loaded behavior is live"
  "Persisted extension prompt."
  (generation-ref loaded 'agent-system-prompt))

(runtime-remove-patch!
 runtime
 (extension-read extension-root "persisted-prompt")
 'extension-disable)

(test-equal "disabling removes the exact artifact patch"
  0
  (length (generation-patches (runtime-current runtime))))

(runtime-eval! runtime "(define extension-tone \"brief\")")
(extension-export!
 extension-root "session-export"
 (generation-patches (runtime-current runtime)))

(test-assert "exports active live state as a reloadable artifact"
  (string-contains (extension-read extension-root "session-export")
                   "extension-tone"))

(test-error "artifact creation refuses overwrite" #t
  (extension-create! extension-root "persisted-prompt" expression))
(test-error "artifact names cannot escape the extension directory" #t
  (extension-create! extension-root "../escape" expression))

(test-end "extensions")
