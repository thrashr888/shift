(use-modules (srfi srfi-64) (srfi srfi-1)
             (live-agent json)
             (live-agent declared))

(test-begin "declared")

(define (parse form) (parse-declared-tool form "kanban"))

(define move
  (parse '(tool "kanban_move"
            (description "Move one card to another column.")
            (parameter "card" string "Card id as the board lists it")
            (parameter "column" string "Target column")
            (run "kanban" "move" "{card}" "{column}"))))

(test-equal "the tool keeps its name" "kanban_move" (assq-ref move 'name))
(test-equal "and the plugin that declared it" "kanban" (assq-ref move 'plugin))
(test-assert "a tool is not resident unless it says so" (not (assq-ref move 'resident)))

(declared-tools-set! (list move))

(test-assert "a declared name is recognised" (declared-tool? "kanban_move"))
(test-assert "an undeclared one is not" (not (declared-tool? "kanban_delete")))
(test-equal "the catalog is name and one line"
  '(("kanban_move" . "Move one card to another column."))
  (declared-catalog))

;; The schema is what the model is offered, so it has to be a well-formed
;; function tool with every parameter required.
(define schema (declared-schema "kanban_move"))
(test-equal "schema is a function tool" "function" (json-object-ref schema "type"))
(test-equal "named for the tool" "kanban_move"
  (json-object-ref (json-object-ref schema "function") "name"))
(test-equal "every parameter is required" '("card" "column")
  (json-array-items
   (json-object-ref (json-object-ref (json-object-ref schema "function") "parameters") "required")))

;; Rendering. The point of the whole design is that a value fills exactly one
;; argv element and cannot become a second command.
(test-equal "a call renders to argv"
  '("kanban" "move" "c-12" "done")
  (declared-argv "kanban_move" (json-object (cons "card" "c-12") (cons "column" "done"))))

(test-equal "shell metacharacters stay inside one element"
  '("kanban" "move" "c-12; rm -rf /" "done")
  (declared-argv "kanban_move"
                 (json-object (cons "card" "c-12; rm -rf /") (cons "column" "done"))))

(test-equal "a pipe is an awkward argument, not a pipeline"
  '("kanban" "move" "a | tee /etc/passwd" "done")
  (declared-argv "kanban_move"
                 (json-object (cons "card" "a | tee /etc/passwd") (cons "column" "done"))))

(test-assert "a missing parameter fails the call, not the render"
  (not (false-if-exception
        (declared-argv "kanban_move" (json-object (cons "card" "c-12"))))))

(test-assert "a structured value is a misunderstanding of the schema"
  (not (false-if-exception
        (declared-argv "kanban_move"
                       (json-object (cons "card" (json-array "c-12")) (cons "column" "done"))))))

;; Embedded substitution keeps one element, which is what makes --flag=value
;; safe to template.
(define embedded
  (parse '(tool "kanban_show"
            (description "Show one card.")
            (parameter "card" string "Card id")
            (run "kanban" "show" "--id={card}"))))
(declared-tools-set! (list embedded))
(test-equal "a placeholder inside an element stays one element"
  '("kanban" "show" "--id=c 12")
  (declared-argv "kanban_show" (json-object (cons "card" "c 12"))))

;; Integers render without becoming a second element either.
(define limited
  (parse '(tool "kanban_recent"
            (description "Recent cards.")
            (parameter "count" integer "How many")
            (run "kanban" "list" "--limit" "{count}"))))
(declared-tools-set! (list limited))
(test-equal "an integer parameter renders as one element"
  '("kanban" "list" "--limit" "5")
  (declared-argv "kanban_recent" (json-object (cons "count" 5))))
(test-assert "a non-integer is refused for an integer parameter"
  (not (false-if-exception
        (declared-argv "kanban_recent" (json-object (cons "count" "lots"))))))

;; Lint rules. Each of these would break a guarantee the design rests on.
(test-assert "the command itself cannot be a parameter"
  (not (false-if-exception
        (parse '(tool "anything"
                  (description "d")
                  (parameter "cmd" string "c")
                  (run "{cmd}" "go"))))))

(test-assert "a placeholder must name a declared parameter"
  (not (false-if-exception
        (parse '(tool "kanban_move"
                  (description "d")
                  (parameter "card" string "c")
                  (run "kanban" "move" "{column}"))))))

(test-assert "a tool needs a run template"
  (not (false-if-exception
        (parse '(tool "kanban_move" (description "d"))))))

(test-assert "a tool needs a description"
  (not (false-if-exception
        (parse '(tool "kanban_move" (run "kanban" "move"))))))

(test-assert "an MCP-shaped name is refused"
  (not (false-if-exception
        (parse '(tool "kanban__move" (description "d") (run "kanban" "move"))))))

(test-assert "a name that is not a tool name is refused"
  (not (false-if-exception
        (parse '(tool "Kanban Move" (description "d") (run "kanban" "move"))))))

(test-assert "duplicate parameters are refused"
  (not (false-if-exception
        (parse '(tool "kanban_move" (description "d")
                  (parameter "card" string "a") (parameter "card" string "b")
                  (run "kanban" "move" "{card}"))))))

;; Residency is what a tool costs on every request, so it is explicit.
(define resident
  (parse '(tool "kanban_board"
            (description "The whole board.")
            (resident)
            (run "kanban" "board"))))
(declared-tools-set! (list move resident))
(test-equal "only tools that ask are resident" '("kanban_board") (declared-resident-names))

;; Two plugins cannot both own a name; the first registered keeps it.
(declared-tools-set! (list move (parse-declared-tool
                                 '(tool "kanban_move" (description "other")
                                    (run "other" "move"))
                                 "impostor")))
(test-equal "a duplicate tool name does not displace the first" "kanban"
  (assq-ref (declared-tool "kanban_move") 'plugin))
(test-equal "and there is only one of it" 1 (length (declared-tools)))


;; A read binding: the `read` tool with its path fixed. No binary, no
;; allowlist entry, and the project boundary is read's own.
(define board
  (parse '(tool "kanban_board"
            (description "Read the board.")
            (read ".shift/kanban.md"))))
(declared-tools-set! (list board))
(test-equal "a read binding says so" 'read (declared-binding "kanban_board"))
(test-equal "and becomes a read call with its path fixed"
  '("read" . ".shift/kanban.md")
  (let ((pair (declared-arguments "kanban_board" (json-object))))
    (cons (car pair) (json-object-ref (cdr pair) "path"))))
(test-equal "a run binding still becomes a run call" "run"
  (begin (declared-tools-set! (list move))
         (car (declared-arguments "kanban_move"
                                  (json-object (cons "card" "c-1") (cons "column" "done"))))))
(test-equal "and carries its argv" '("kanban" "move" "c-1" "done")
  (json-array-items (json-object-ref (cdr (declared-arguments "kanban_move"
                                            (json-object (cons "card" "c-1") (cons "column" "done"))))
                                     "argv")))

;; A read path may be parameterised; read resolves it inside the project the
;; way it resolves any other path, so a traversal fails there rather than here.
(define note
  (parse '(tool "note_read"
            (description "Read one note.")
            (parameter "name" string "Note name")
            (read "notes/{name}.md"))))
(declared-tools-set! (list note))
(test-equal "a read path substitutes like any template" "notes/alpha.md"
  (json-object-ref (cdr (declared-arguments "note_read" (json-object (cons "name" "alpha")))) "path"))

(test-assert "a read binding takes exactly one path"
  (not (false-if-exception
        (parse '(tool "two" (description "d") (read "a.md" "b.md"))))))

(test-end "declared")
