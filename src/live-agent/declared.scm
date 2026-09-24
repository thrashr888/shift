;; Declared tools: a plugin gives the model a named, schema'd verb without
;; shipping code. A declared tool is a JSON Schema plus an argv template, and
;; calling one is rewritten into the equivalent `run` call before the policy
;; sees it, so it carries no authority of its own — the same allowlist, the
;; same mode, the same judge, the same run record.
;;
;; Substitution is argv-positional. A parameter fills one whole element, or
;; part of one, and can never introduce a second command: there is no shell
;; between the template and `run`, so a value containing ; or | is an awkward
;; argument and nothing else.
(define-module (live-agent declared)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (live-agent json)
  #:export (parse-declared-tool declared-tools-set! declared-tools
            declared-tool declared-tool? declared-schema declared-argv
            declared-resident-names declared-catalog max-resident-per-plugin))

(define max-resident-per-plugin 2)
(define max-value-length 4096)

(define registry '())

;; A tool name reaches the model, so it looks like the built-ins: lowercase,
;; digits and underscores. MCP names are rejected here because SERVER__TOOL is
;; how the runtime tells an MCP call apart from anything else.
(define (valid-tool-name? name)
  (and (string? name) (<= 1 (string-length name) 48)
       (char-alphabetic? (string-ref name 0))
       (string-every (lambda (c) (or (char-lower-case? c) (char-numeric? c) (char=? c #\_))) name)
       (not (string-contains name "__"))))

(define (valid-parameter-name? name)
  (and (string? name) (<= 1 (string-length name) 32)
       (char-alphabetic? (string-ref name 0))
       (string-every (lambda (c) (or (char-lower-case? c) (char-numeric? c) (char=? c #\_))) name)))

;; Every {placeholder} in one template element, in order.
(define (placeholders-in element)
  (let loop ((index 0) (found '()))
    (let ((open (string-index element #\{ index)))
      (if (not open)
          (reverse found)
          (let ((close (string-index element #\} open)))
            (if (not close)
                (reverse found)
                (loop (+ close 1)
                      (cons (substring element (+ open 1) close) found))))))))

;; (tool "name" (description "...") (parameter "p" string "what it is")
;;              (run "cmd" "sub" "{p}") (resident))
(define (parse-declared-tool form plugin-name)
  (unless (and (list? form) (>= (length form) 3) (eq? (car form) 'tool) (valid-tool-name? (cadr form)))
    (error "a tool is (tool \"name\" (description ...) (parameter ...)... (run ...))" form))
  (let ((name (cadr form)))
    (let loop ((rest (cddr form)) (description #f) (parameters '()) (argv #f) (resident #f))
      (if (null? rest)
          (begin
            (unless (string? description) (error "tool needs a description" name))
            (unless (pair? argv) (error "tool needs a (run ...) template" name))
            ;; Every placeholder must name a declared parameter, or the
            ;; rendered argv would carry a literal brace to the command.
            (for-each
             (lambda (element)
               (for-each
                (lambda (placeholder)
                  (unless (assoc placeholder parameters)
                    (error (format #f "tool ~a: {~a} is not a declared parameter" name placeholder))))
                (placeholders-in element)))
             argv)
            ;; The allowlist matches leading argv elements. A substituted head
            ;; would make the prefix unknowable, so every allow-run entry that
            ;; appeared to cover this tool would be meaningless.
            (when (pair? (placeholders-in (car argv)))
              (error (format #f "tool ~a: the command itself cannot be a parameter" name)))
            `((name . ,name)
              (plugin . ,plugin-name)
              (description . ,description)
              (parameters . ,(reverse parameters))
              (argv . ,argv)
              (resident . ,resident)))
          (let ((section (car rest)))
            (unless (and (pair? section) (symbol? (car section)))
              (error "tool sections are lists headed by a symbol" section))
            (case (car section)
              ((description)
               (unless (and (= (length section) 2) (string? (cadr section))
                            (<= (string-length (cadr section)) 400))
                 (error "description takes one string up to 400 characters" section))
               (loop (cdr rest) (cadr section) parameters argv resident))
              ((parameter)
               (unless (and (= (length section) 4) (valid-parameter-name? (cadr section))
                            (memq (caddr section) '(string integer))
                            (string? (cadddr section))
                            (<= (string-length (cadddr section)) 200))
                 (error "parameter takes NAME string|integer \"description\"" section))
               (when (assoc (cadr section) parameters)
                 (error "duplicate parameter" (cadr section)))
               (loop (cdr rest) description
                     (cons (cons (cadr section) (cons (caddr section) (cadddr section))) parameters)
                     argv resident))
              ((run)
               (unless (and (pair? (cdr section)) (every string? (cdr section))
                            (every (lambda (e) (not (string-null? e))) (cdr section))
                            (<= (length (cdr section)) 24))
                 (error "run takes a non-empty argv template of strings" section))
               (loop (cdr rest) description parameters (cdr section) resident))
              ((resident)
               (unless (= (length section) 1) (error "resident takes no arguments" section))
               (loop (cdr rest) description parameters argv #t))
              (else (error "unknown tool section" (car section)))))))))

;; Plugins are re-read when they change, so the registry is replaced whole.
;; Later plugins do not silently take a name an earlier one already used.
(define (declared-tools-set! tools)
  (set! registry
        (fold (lambda (tool kept)
                (if (assoc (assq-ref tool 'name) (map (lambda (t) (cons (assq-ref t 'name) t)) kept))
                    kept
                    (append kept (list tool))))
              '() tools)))

(define (declared-tools) registry)
(define (declared-tool name)
  (find (lambda (tool) (equal? (assq-ref tool 'name) name)) registry))
(define (declared-tool? name) (and (declared-tool name) #t))

(define (declared-resident-names)
  (map (lambda (tool) (assq-ref tool 'name))
       (filter (lambda (tool) (assq-ref tool 'resident)) registry)))

;; Name and one line each, for a listing that does not pay for full schemas.
(define (declared-catalog)
  (map (lambda (tool) (cons (assq-ref tool 'name) (assq-ref tool 'description))) registry))

(define (declared-schema name)
  (let ((tool (declared-tool name)))
    (and tool
         (let ((parameters (assq-ref tool 'parameters)))
           (json-object
            (cons "type" "function")
            (cons "function"
                  (json-object
                   (cons "name" name)
                   (cons "description" (assq-ref tool 'description))
                   (cons "parameters"
                         (json-object
                          (cons "type" "object")
                          (cons "properties"
                                (apply json-object
                                       (map (lambda (entry)
                                              (cons (car entry)
                                                    (json-object
                                                     (cons "type" (symbol->string (cadr entry)))
                                                     (cons "description" (cddr entry)))))
                                            parameters)))
                          (cons "required" (apply json-array (map car parameters)))
                          (cons "additionalProperties" #f))))))))))

(define (value->string value parameter-name type)
  (cond
   ((and (eq? type 'string) (string? value)) value)
   ((and (eq? type 'integer) (integer? value)) (number->string value))
   ;; A model that sends 3 for a string parameter means "3"; one that sends a
   ;; list or an object has misunderstood the schema and should hear so.
   ((and (eq? type 'string) (number? value)) (number->string value))
   (else (error (format #f "~a must be a ~a" parameter-name type)))))

(define (substitute element bindings)
  (fold (lambda (binding text)
          (let ((needle (string-append "{" (car binding) "}")))
            (let loop ((text text))
              (let ((at (string-contains text needle)))
                (if (not at)
                    text
                    (loop (string-append (substring text 0 at)
                                         (cdr binding)
                                         (substring text (+ at (string-length needle))))))))))
        element bindings))

;; The rendered argv for a call, or an error naming what the call got wrong.
;; Each parameter becomes part of exactly one element: there is no shell, so
;; nothing a value contains can split it into a second command.
(define (declared-argv name arguments)
  (let ((tool (declared-tool name)))
    (unless tool (error "unknown declared tool" name))
    (let* ((parameters (assq-ref tool 'parameters))
           (bindings
            (map (lambda (entry)
                   (let* ((parameter (car entry))
                          (type (cadr entry))
                          (value (json-object-ref arguments parameter #f)))
                     (when (eq? value #f)
                       (error (format #f "~a requires ~a" name parameter)))
                     (let ((text (value->string value parameter type)))
                       (when (> (string-length text) max-value-length)
                         (error (format #f "~a is longer than ~a characters" parameter max-value-length)))
                       (cons parameter text))))
                 parameters)))
      (map (lambda (element) (substitute element bindings)) (assq-ref tool 'argv)))))
