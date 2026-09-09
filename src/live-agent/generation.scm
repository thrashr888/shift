(define-module (live-agent generation)
  #:use-module (ice-9 exceptions)
  #:use-module (ice-9 format)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (generation?
            generation-id
            generation-module
            generation-source-path
            generation-source-text
            generation-patches
            generation-fingerprint
            generation-loaded-at
            build-generation
            generation-ref
            generation-call
            validate-live-patch!
            read-source-file))

(define max-live-patch-chars (* 16 1024))

(define required-bindings
  '(agent-name
    agent-provider
    agent-model
    agent-base-url
    agent-api-key-environment
    agent-stream?
    agent-thinking
    agent-keep-alive
    agent-max-tool-rounds
    agent-compaction-threshold
    agent-compaction-keep-recent
    agent-system-prompt
    agent-tools
    agent-shell-policy
    agent-select-context
    agent-transform-user
    agent-demo-response))

;; The live image receives language and data primitives, not Guile's process,
;; filesystem, networking, module-resolution, dynamic-loading, or eval APIs.
;; Authority-bearing work must cross a stable tool boundary.
(define safe-bindings
  '(define define* define-values define-syntax syntax-rules
    lambda quote quasiquote unquote unquote-splicing begin
    if cond case else => and or when unless let let* letrec letrec* set!
    values call-with-values apply
    boolean? not eq? eqv? equal?
    number? integer? exact? inexact? zero? positive? negative?
    + - * / = < > <= >= max min abs modulo remainder quotient
    string? string string-length string-ref substring
    string-append string=? string-ci=? string-upcase string-downcase
    string-contains
    string-trim string-trim-right string-trim-both
    symbol? symbol->string string->symbol keyword?
    char? char=? char-ci=? char-alphabetic? char-numeric? char-whitespace?
    pair? null? list? list cons car cdr caar cadr cdar cddr
    length append reverse list-ref list-tail member memq memv assq assoc
    map for-each filter
    vector? vector make-vector vector-length vector-ref vector-set!
    error format object->string))

(define-record-type <generation>
  (make-generation id module source-path source-text patches fingerprint loaded-at)
  generation?
  (id generation-id)
  (module generation-module)
  (source-path generation-source-path)
  (source-text generation-source-text)
  (patches generation-patches)
  (fingerprint generation-fingerprint)
  (loaded-at generation-loaded-at))

(define (read-source-file path)
  (call-with-input-file path get-string-all))

(define (timestamp)
  (strftime "%Y-%m-%dT%H:%M:%SZ" (gmtime (current-time))))

;; Stable, deterministic FNV-1a identifier. This is a change identifier, not a
;; cryptographic signature. A signed provenance layer belongs below this spike.
(define (fingerprint-text text)
  (let loop ((chars (string->list text))
             (hash #xcbf29ce484222325))
    (if (null? chars)
        (format #f "~16,'0x" hash)
        (loop (cdr chars)
              (modulo (* (logxor hash (char->integer (car chars)))
                         #x100000001b3)
                      #x10000000000000000)))))

(define (fresh-module)
  (let ((module (make-module)))
    (module-use!
     module
     (resolve-interface '(guile) #:select safe-bindings))
    ;; A boolean spelling is easier for models to generate than Guile's
    ;; index-or-#f string-contains primitive. Keep both available.
    (module-define!
     module 'string-contains?
     (lambda (text fragment)
       (if (string-contains text fragment) #t #f)))
    module))

(define (eval-all! text module)
  (call-with-input-string
      text
    (lambda (port)
      (let loop ()
        (let ((form (read port)))
          (unless (eof-object? form)
            (eval form module)
            (loop)))))))

(define (live-binding? value)
  (and (symbol? value)
       (let ((name (symbol->string value)))
         (or (string-prefix? "agent-" name)
             (string-prefix? "extension-" name)))))

(define (definition-target form)
  (and (pair? (cdr form))
       (let ((head (cadr form)))
         (cond
          ((symbol? head) head)
          ((and (pair? head) (symbol? (car head))) (car head))
          (else #f)))))

(define (validate-live-form! form)
  (unless (pair? form)
    (error "live patch must contain definitions, assignments, or begin" form))
  (case (car form)
    ((define define*)
     (let ((target (definition-target form)))
       (unless (live-binding? target)
         (error "live patch definitions must target agent-* or extension-* bindings"
                target))))
    ((set!)
     (unless (and (pair? (cdr form)) (live-binding? (cadr form)))
       (error "live patch assignments must target agent-* or extension-* bindings"
              form)))
    ((begin)
     (when (null? (cdr form))
       (error "live patch begin must contain at least one form"))
     (for-each validate-live-form! (cdr form)))
    (else
     (error "live patch top-level form must be define, define*, set!, or begin"
            (car form)))))

(define (validate-live-patch! text)
  (unless (string? text)
    (error "live patch must be a string" text))
  (when (string-null? (string-trim-both text))
    (error "live patch cannot be empty"))
  (when (> (string-length text) max-live-patch-chars)
    (error "live patch exceeds the 16 KiB limit" (string-length text)))
  (call-with-input-string
      text
    (lambda (port)
      (let loop ((count 0))
        (let ((form (read port)))
          (if (eof-object? form)
              (begin
                (when (= count 0) (error "live patch contains no forms"))
                #t)
              (begin
                (validate-live-form! form)
                (loop (+ count 1)))))))))

(define (validate-module! module)
  (for-each
   (lambda (name)
     (unless (module-variable module name)
       (error "agent image is missing required binding" name)))
   required-bindings)
  (let ((policy (module-ref module 'agent-shell-policy)))
    (unless (memq policy '(deny ask))
      (error "agent-shell-policy must be deny or ask" policy)))
  (let ((provider (module-ref module 'agent-provider))
        (model (module-ref module 'agent-model))
        (base-url (module-ref module 'agent-base-url))
        (key-environment
         (module-ref module 'agent-api-key-environment))
        (stream? (module-ref module 'agent-stream?))
        (thinking (module-ref module 'agent-thinking))
        (keep-alive (module-ref module 'agent-keep-alive))
        (tools (module-ref module 'agent-tools)))
    (unless (memq provider '(ollama openai claude))
      (error "agent-provider must be ollama, openai, or claude" provider))
    (unless (and (string? model) (not (string-null? model)))
      (error "agent-model must be a non-empty string" model))
    (unless (and (string? base-url) (not (string-null? base-url)))
      (error "agent-base-url must be a non-empty string" base-url))
    (unless (or (not key-environment) (string? key-environment))
      (error "agent-api-key-environment must be a string or #f"
             key-environment))
    (unless (boolean? stream?)
      (error "agent-stream? must be a boolean" stream?))
    (unless (or (boolean? thinking)
                (memq thinking '(low medium high)))
      (error "agent-thinking must be #t, #f, low, medium, or high" thinking))
    (unless (or (and (string? keep-alive)
                     (not (string-null? keep-alive)))
                (number? keep-alive))
      (error "agent-keep-alive must be a non-empty duration string or number"
             keep-alive))
    (unless (and (list? tools)
                 (every (lambda (tool)
                          (memq tool '(read rg write edit shell traces live_eval extension
                                       status diff apply_patch run)))
                        tools))
      (error "agent-tools contains an unsupported tool" tools)))
  (let ((rounds (module-ref module 'agent-max-tool-rounds)))
    (unless (and (integer? rounds) (>= rounds 0) (<= rounds 64))
      (error "agent-max-tool-rounds must be an integer from 0 through 64" rounds)))
  (let ((threshold (module-ref module 'agent-compaction-threshold))
        (keep-recent (module-ref module 'agent-compaction-keep-recent)))
    (unless (and (integer? threshold) (>= threshold 8) (<= threshold 2000))
      (error "agent-compaction-threshold must be an integer from 8 through 2000"
             threshold))
    (unless (and (integer? keep-recent) (>= keep-recent 4)
                 (< keep-recent threshold))
      (error "agent-compaction-keep-recent must be at least 4 and below the threshold"
             keep-recent)))
  (let ((selector (module-ref module 'agent-select-context)))
    (unless (procedure? selector)
      (error "agent-select-context must be a procedure"))
    ;; Exercise both the empty and demo-shaped branches before activation so a
    ;; generated function with a latent unbound helper is rejected atomically.
    (for-each
     (lambda (probe)
       (let ((paths (selector probe)))
         (unless (and (list? paths)
                      (<= (length paths) 8)
                      (every (lambda (path)
                               (and (string? path)
                                    (not (string-null? path))))
                             paths))
           (error
            "agent-select-context must return at most eight non-empty paths"
            paths))))
     '("" "atlas production deployment port")))
  #t)

(define (build-generation id source-path source-text patches)
  (let ((module (fresh-module)))
    (eval-all! source-text module)
    (for-each (lambda (patch) (eval-all! patch module)) patches)
    (validate-module! module)
    ;; Optional behavior cases belong to the agent image. The unpatched image
    ;; may intentionally be a failing baseline; every patched candidate must pass.
    (when (and (pair? patches) (module-defined? module 'agent-context-cases))
      (let ((cases (module-ref module 'agent-context-cases))
            (selector (module-ref module 'agent-select-context)))
        (unless (and (list? cases) (<= (length cases) 32))
          (error "agent-context-cases must be a list of at most 32 cases"))
        (for-each
         (lambda (entry)
           (unless (and (list? entry) (= (length entry) 2)
                        (string? (car entry)) (list? (cadr entry)))
             (error "context case must contain a query and expected paths" entry))
           (let ((actual (selector (car entry))))
             (unless (equal? actual (cadr entry))
               (error (format #f "candidate context check failed for query ~s: expected ~s, got ~s"
                              (car entry) (cadr entry) actual)))))
         cases)))
    (make-generation
     id
     module
     source-path
     source-text
     patches
     (fingerprint-text
      (string-append source-text "\n" (string-join patches "\n")))
     (timestamp))))

(define (generation-ref generation name)
  (module-ref (generation-module generation) name))

(define (generation-call generation name . args)
  (apply (generation-ref generation name) args))
