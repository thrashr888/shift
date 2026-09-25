(use-modules (srfi srfi-64) (ice-9 textual-ports) (live-agent skills) (live-agent json))
(test-begin "skills")
(define root (string-append "/tmp/shift-skills-" (number->string (getpid))))
(define (write-skill dir name text)
  (system* "mkdir" "-p" (string-append dir "/" name))
  (call-with-output-file (string-append dir "/" name "/SKILL.md") (lambda (p) (display text p))))
(setenv "HOME" (string-append root "/home"))
(setenv "XDG_CONFIG_HOME" (string-append root "/config"))
(system* "mkdir" "-p" (string-append root "/project") (string-append root "/home"))
(write-skill (string-append root "/project/.shift/skills") "release"
  "---\nname: release\ndescription: Cut a release: bump, changelog, tag.\n---\n# Release\n\nRun make release.\n")
(write-skill (string-append root "/project/.agents/skills") "review"
  "---\nname: review\ndescription: >\n  Review a diff for\n  correctness.\ndisable-model-invocation: true\n---\nBody\n")
(write-skill (string-append root "/config/shift/skills") "release"
  "---\nname: release\ndescription: user copy, shadowed\n---\nuser body\n")
(write-skill (string-append root "/home/.agents/skills") "notes"
  "---\nname: notes\ndescription: \"Write notes\"\n---\nnotes body\n")
(write-skill (string-append root "/project/.shift/skills") "Bad_Name"
  "---\nname: Bad_Name\ndescription: x\n---\n")
(write-skill (string-append root "/project/.shift/skills") "renamed"
  "---\nname: other\ndescription: x\n---\n")
(skills-init! (string-append root "/project"))
(define (names) (map (lambda (r) (assq-ref r 'name)) (skill-index)))
(test-equal "project skills come first, then .agents, user and global .agents"
  '("Bad_Name" "release" "renamed" "review" "notes") (names))
(test-equal "a project skill shadows the user copy of the same name" "project"
  (assq-ref (skill-find "release") 'source))
(test-equal "folded descriptions join into one line" "Review a diff for correctness."
  (assq-ref (skill-find "review") 'description))
(test-equal "quoted descriptions lose their quotes" "Write notes" (assq-ref (skill-find "notes") 'description))
(test-assert "folder names must be lowercase" (not (assq-ref (skill-find "Bad_Name") 'valid)))
(test-assert "frontmatter name must match the folder" (string-prefix? "frontmatter name other" (assq-ref (skill-find "renamed") 'error)))
;; Names only. A description in the prompt block is charged on every request
;; of every session; here it is one `skill` search away instead.
(test-assert "the prompt block names valid model-invocable skills only"
  (let ((block (skills-prompt-block)))
    (and (string-contains block "release") (string-contains block "notes")
         (not (string-contains block "review")) (not (string-contains block "Bad_Name")))))
(test-assert "the prompt block carries no descriptions"
  (not (string-contains (skills-prompt-block) "Cut a release")))

;; Search is where the descriptions live, and it ranks by them.
(test-equal "a search finds a skill by words from its description" "release"
  (car (car (skill-search "cut a release"))))
(test-assert "a search returns the description the prompt block dropped"
  (string-contains (cdr (car (skill-search "cut a release"))) "Cut a release"))
(test-assert "a skill the model may not invoke is not searchable"
  (not (assoc "review" (skill-search "diff correctness"))))
(test-assert "an invalid skill is not searchable"
  (not (assoc "Bad_Name" (skill-search "bad"))))
(test-equal "select: takes exact names" '("release")
  (map car (skill-search "select:release")))
(test-assert "a query matching nothing returns nothing"
  (null? (skill-search "quantum chromodynamics")))
(test-assert "loading returns the body with the directory" 
  (string-contains (skill-load! "release") "Run make release."))
(test-assert "loaded state is tracked" (skill-loaded? "release"))
(test-error "user-only skills refuse model loads" #t (skill-load! "review"))
(test-assert "a missing skill names the ones that exist"
  (catch #t (lambda () (skill-load! "relaese") #f)
    (lambda (key . args) (let ((text (format #f "~s" args))) (and (string-contains text "no skill named") (string-contains text "release"))))))
(test-assert "the user can load a user-only skill" (string-contains (skill-load! "review" #:by-model #f) "Body"))
(test-error "invalid skills cannot load" #t (skill-load! "renamed"))
(test-equal "valid directories are the read roots" 3 (length (skill-directories)))
(test-equal "json carries loaded and validity" #t
  (json-object-ref (car (filter (lambda (o) (equal? (json-object-ref o "name") "release")) (json-array-items (skills-json)))) "loaded"))
(write-skill (string-append root "/project/.shift/skills") "fresh" "---\nname: fresh\ndescription: new\n---\n")
(test-assert "the index notices a new skill without a restart" (skill-find "fresh"))
(system* "mkdir" "-p" (string-append root "/kit/skills/kit-skill"))
(call-with-output-file (string-append root "/kit/skills/kit-skill/SKILL.md")
  (lambda (p) (display "---\nname: kit-skill\ndescription: From a checked-out kit\nallowed-tools: Read, Bash\n---\nkit body\n" p)))
(system* "mkdir" "-p" (string-append root "/project/.cortex/skills"))
(call-with-output-file (string-append root "/project/.cortex/skills/error-handling.md")
  (lambda (p) (display "---\nname: error-handling\ndescription: Learned patterns for error-handling\n---\n\nReturn exit codes, not prose.\n" p)))
(call-with-output-file (string-append root "/project/.cortex/skills/mismatch.md")
  (lambda (p) (display "---\nname: other\ndescription: x\n---\nbody\n" p)))
(skills-init! (string-append root "/project") (list (string-append root "/kit/skills")))
(test-equal "cortex's flat NAME.md files are skills from source cortex" "cortex" (assq-ref (skill-find "error-handling") 'source))
(test-assert "flat skills load their body" (string-contains (skill-load! "error-handling") "Return exit codes"))
(test-assert "a flat file whose name disagrees with its frontmatter is invalid" (not (assq-ref (skill-find "mismatch") 'valid)))
(test-equal "skill-dirs folders join the index as source dir" "dir" (assq-ref (skill-find "kit-skill") 'source))
(test-assert "extra frontmatter such as allowed-tools is ignored, not rejected" (assq-ref (skill-find "kit-skill") 'valid))
(system* "rm" "-rf" root)
(test-end "skills")
