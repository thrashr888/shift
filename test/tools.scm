(use-modules (srfi srfi-64)
             (live-agent json)
             (live-agent tools))

(test-begin "tools")

(define root (getcwd))

(define read-result
  (execute-tool
   "read"
   (json-object (cons "path" "README.md"))
   root
   'deny
   (lambda _ #f)))

(test-assert "read stays inside project"
  (and (tool-result-success? read-result)
       (string-contains (tool-result-output read-result)
                    "# shift")))

(define escaped-read
  (execute-tool
   "read"
   (json-object (cons "path" "/etc/hosts"))
   root
   'deny
   (lambda _ #f)))

(test-assert "read rejects paths outside project"
  (and (not (tool-result-success? escaped-read))
       (string-contains (tool-result-output escaped-read)
                        "escapes the project root")))

(define confirm-called? #f)
(define denied-shell
  (execute-tool
   "shell"
   (json-object (cons "command" "echo should-not-run"))
   root
   'deny
   (lambda _ (set! confirm-called? #t) #t)))

(test-assert "deny policy blocks shell"
  (and (not (tool-result-success? denied-shell))
       (string-contains (tool-result-output denied-shell)
                        "denied by the live image")))
(test-assert "deny policy never prompts" (not confirm-called?))

(define tool-root
  (string-append "/tmp/lisp-agent-tools-test-" (number->string (getpid))))
(system* "mkdir" "-p" tool-root)

(define write-result
  (execute-tool
   "write"
   (json-object (cons "path" "notes.txt")
                (cons "content" "alpha port 8080\nalpha port 8080\n"))
   tool-root 'deny (lambda _ #f)))

(test-assert "write atomically creates a project file"
  (and (tool-result-success? write-result)
       (file-exists? (string-append tool-root "/notes.txt"))))

(define ambiguous-edit
  (execute-tool
   "edit"
   (json-object (cons "path" "notes.txt")
                (cons "old_text" "8080")
                (cons "new_text" "9443"))
   tool-root 'deny (lambda _ #f)))

(test-assert "edit rejects ambiguous replacements by default"
  (and (not (tool-result-success? ambiguous-edit))
       (string-contains (tool-result-output ambiguous-edit) "ambiguous")))

(define all-edit
  (execute-tool
   "edit"
   (json-object (cons "path" "notes.txt")
                (cons "old_text" "8080")
                (cons "new_text" "9443")
                (cons "replace_all" #t))
   tool-root 'deny (lambda _ #f)))

(test-assert "edit can replace every exact occurrence explicitly"
  (and (tool-result-success? all-edit)
       (string-contains (tool-result-output all-edit) "2 occurrences")
       (string-contains (tool-result-output all-edit) "(+2 −2)")))

(define edit-change (car (tool-result-changes all-edit)))
(test-equal "mutations report the project-relative path" "notes.txt" (assq-ref edit-change 'path))
(test-assert "mutations carry before and after hashes"
  (and (string? (assq-ref edit-change 'before)) (string? (assq-ref edit-change 'after))
       (not (string=? (assq-ref edit-change 'before) (assq-ref edit-change 'after)))))
(test-assert "mutations carry a unified diff"
  (string-contains (assq-ref edit-change 'diff) "+alpha port 9443"))

(define hashed-read
  (execute-tool "read" (json-object (cons "path" "notes.txt")) tool-root 'deny (lambda _ #f)))
(test-assert "read output starts with a hash header"
  (string-prefix? "# notes.txt · " (tool-result-output hashed-read)))
(test-equal "read observation hash matches the last mutation"
  (assq-ref edit-change 'after)
  (assq-ref (car (tool-result-changes hashed-read)) 'hash))

(define prepared
  (prepare-change "edit"
                  (json-object (cons "path" "notes.txt")
                               (cons "old_text" "9443") (cons "new_text" "1")
                               (cons "replace_all" #t))
                  tool-root))
(test-assert "prepare does not touch the file"
  (string-contains (tool-result-output
                    (execute-tool "read" (json-object (cons "path" "notes.txt")) tool-root 'deny (lambda _ #f)))
                   "9443"))
(test-assert "prepared diff previews the replacement"
  (and (string-contains (prepared-change-diff prepared) "--- a/notes.txt")
       (string-contains (prepared-change-diff prepared) "+alpha port 1")))

(execute-tool "write" (json-object (cons "path" "stale.txt") (cons "content" "one\n"))
              tool-root 'deny (lambda _ #f))
(define stale-prepared
  (prepare-change "edit"
                  (json-object (cons "path" "stale.txt") (cons "old_text" "one") (cons "new_text" "two"))
                  tool-root))
(call-with-output-file (string-append tool-root "/stale.txt")
  (lambda (port) (display "changed elsewhere\n" port)))
(test-error "commit refuses a file that changed after preparation" #t (commit-change! stale-prepared))
(test-assert "a refused commit leaves the file alone"
  (string-contains (tool-result-output
                    (execute-tool "read" (json-object (cons "path" "stale.txt")) tool-root 'deny (lambda _ #f)))
                   "changed elsewhere"))

(define create-prepared
  (prepare-change "write" (json-object (cons "path" "fresh.txt") (cons "content" "new\n")) tool-root))
(test-assert "creates prepare against /dev/null"
  (and (not (prepared-change-before-hash create-prepared))
       (string-contains (prepared-change-diff create-prepared) "--- /dev/null")))
(test-assert "creates commit" (tool-result-success? (commit-change! create-prepared)))

(define rg-result
  (execute-tool
   "rg"
   (json-object (cons "query" "9443") (cons "path" "."))
   tool-root 'deny (lambda _ #f)))

(test-assert "rg searches without shell authority"
  (and (tool-result-success? rg-result)
       (string-contains (tool-result-output rg-result) "notes.txt:1")
       (string-contains (tool-result-output rg-result) "notes.txt:2")))

(define literal-rg-result
  (execute-tool
   "rg"
   (json-object (cons "query" "alpha port 9443 (") (cons "path" "."))
   tool-root 'deny (lambda _ #f)))

(test-equal "rg treats punctuation as literal by default"
  "No matches."
  (tool-result-output literal-rg-result))

(define regex-rg-result
  (execute-tool
   "rg"
   (json-object (cons "query" "port [0-9]+")
                (cons "path" ".")
                (cons "regex" #t))
   tool-root 'deny (lambda _ #f)))

(test-assert "rg supports explicit regular expressions"
  (and (tool-result-success? regex-rg-result)
       (string-contains (tool-result-output regex-rg-result) "notes.txt:1")))

(define invalid-regex-result
  (execute-tool
   "rg"
   (json-object (cons "query" "(unclosed")
                (cons "path" ".")
                (cons "regex" #t))
   tool-root 'deny (lambda _ #f)))

(test-assert "rg labels invalid explicit regular expressions"
  (and (not (tool-result-success? invalid-regex-result))
       (string-contains (tool-result-output invalid-regex-result)
                        "regular expression is invalid")))

(define escaped-write
  (execute-tool
   "write"
   (json-object (cons "path" "../escape.txt") (cons "content" "no"))
   tool-root 'deny (lambda _ #f)))

(test-assert "write rejects paths outside the project"
  (and (not (tool-result-success? escaped-write))
       (string-contains (tool-result-output escaped-write)
                        "escapes the project root")))

(test-end "tools")
