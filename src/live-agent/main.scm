(define-module (live-agent main)
  #:use-module (ice-9 exceptions)
  #:use-module (ice-9 format)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 readline)
  #:use-module (ice-9 threads)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (live-agent settings)
  #:use-module (live-agent input)
  #:use-module (live-agent models)
  #:use-module (live-agent policy)
  #:use-module (live-agent transcript)
  #:use-module (live-agent builtins)
  #:use-module (live-agent changes)
  #:use-module (live-agent diff)
  #:use-module (live-agent compaction)
  #:use-module (live-agent context)
  #:use-module (live-agent json)
  #:use-module (live-agent extensions)
  #:use-module (live-agent generation)
  #:use-module (live-agent provider)
  #:use-module (live-agent prompt)
  #:use-module (live-agent recovery)
  #:use-module (live-agent runtime)
  #:use-module (live-agent session)
  #:use-module (live-agent trace)
  #:use-module (live-agent tools)
  #:export (main))

(define turn-active? #f)
(define turn-thread #f)
;; A private inherited pipe carries lifecycle results to the MCP supervisor.
;; Model output and terminal prompts are never control messages.
(define control-port
  (let ((fd (getenv "SHIFT_CONTROL_FD")))
    (and fd (let ((port (fdopen (string->number fd) "w")))
              (fcntl port F_SETFD FD_CLOEXEC)
              port))))
(define operation-status "ok")
(define operation-error #f)
(define operation-span #f)
(define (emit-control! state)
  (when control-port
    (display (json-write
              (json-object (cons "state" state)
                           (cons "status" operation-status)
                           (cons "error" (or operation-error json-null))
                           (cons "span_id" (or operation-span json-null)))) control-port)
    (newline control-port)
    (force-output control-port)))
(define (operation-failed! detail)
  (set! operation-status "error")
  (set! operation-error detail))

(define supported-tool-names
  '("read" "rg" "write" "edit" "shell" "traces" "live_eval" "extension"))

;; A process-level ceiling is intentionally outside the live image. A child can
;; redefine agent-tools, but it cannot grant itself authority omitted here.
(define process-tool-ceiling
  (let ((raw (getenv "SHIFT_TOOL_CEILING")))
    (if (or (not raw) (string-null? (string-trim-both raw)))
        #f
        (let ((names
               (filter
                (lambda (name) (not (string-null? name)))
                (map string-trim-both (string-split raw #\,)))))
          (unless (every (lambda (name) (member name supported-tool-names)) names)
            (error "SHIFT_TOOL_CEILING contains an unsupported tool" raw))
          (delete-duplicates names string=?)))))

(define (within-process-tool-ceiling? name)
  (or (not process-tool-ceiling) (member name process-tool-ceiling)))

(define (cancelled? key)
  (eq? key 'turn-cancelled))

(define (install-cancellation-handler!)
  (sigaction
   SIGINT
   (lambda _
     (when turn-thread
       (system-async-mark (lambda () (throw 'turn-cancelled "cancelled by user")) turn-thread)))))

(define (usage)
  (display
   (string-append
    "Usage: shift [--agent PATH] [--state-dir PATH] [--watch|--no-watch]\n"
    "                  [--session NAME|--new-session NAME|--resume NAME] [PROMPT]\n"
    "       shift --list-sessions [--state-dir PATH]\n"
    "       shift session-fork PARENT CHILD\n")))

(define (parse-arguments args)
  (let loop ((rest args) (agent #f) (state-dir #f) (watch? (isatty? (current-input-port)))
             (session-name #f) (session-mode #f) (list? #f)
             (initial-prompt #f) (fork-parent #f) (fork-child #f))
    (cond
     ((null? rest)
      (values agent state-dir watch? session-name session-mode list?
              initial-prompt fork-parent fork-child))
     ((and (pair? (cdr rest)) (string=? (car rest) "--agent"))
      (loop (cddr rest) (cadr rest) state-dir watch?
            session-name session-mode list? initial-prompt fork-parent fork-child))
     ((and (pair? (cdr rest)) (string=? (car rest) "--state-dir"))
      (loop (cddr rest) agent (cadr rest) watch?
            session-name session-mode list? initial-prompt fork-parent fork-child))
     ((string=? (car rest) "--watch")
      (loop (cdr rest) agent state-dir #t session-name session-mode list?
            initial-prompt fork-parent fork-child))
     ((string=? (car rest) "--no-watch")
      (loop (cdr rest) agent state-dir #f session-name session-mode list?
            initial-prompt fork-parent fork-child))
     ((and (pair? (cdr rest))
           (member (car rest) '("--session" "--new-session" "--resume")))
      (when session-name
        (format (current-error-port) "Only one session selector may be used.\n")
        (exit 2))
      (loop
       (cddr rest) agent state-dir watch? (cadr rest)
       (cond
        ((string=? (car rest) "--new-session") 'new)
        ((string=? (car rest) "--resume") 'resume)
       (else 'auto))
       list? initial-prompt fork-parent fork-child))
     ((and (pair? (cdr rest)) (pair? (cddr rest))
           (string=? (car rest) "--fork-session"))
      (when (or fork-parent session-name list? initial-prompt)
        (format (current-error-port)
                "session-fork cannot be combined with a session selector, listing, or prompt.\n")
        (exit 2))
      (loop (cdddr rest) agent state-dir watch? session-name session-mode list?
            initial-prompt (cadr rest) (caddr rest)))
     ((string=? (car rest) "--list-sessions")
      (loop (cdr rest) agent state-dir watch?
            session-name session-mode #t initial-prompt fork-parent fork-child))
     ((member (car rest) '("-h" "--help"))
      (usage)
      (exit 0))
     ((not (string-prefix? "-" (car rest)))
      (when initial-prompt
        (format (current-error-port)
                "Only one positional startup prompt may be provided; quote prompts containing spaces.\n")
        (exit 2))
      (loop (cdr rest) agent state-dir watch?
            session-name session-mode list? (car rest) fork-parent fork-child))
     (else
      (format (current-error-port) "Unknown argument: ~a~%" (car rest))
      (usage)
      (exit 2)))))

(define (show-help)
  (display
   (string-append
    "Commands:\n"
    "  /show             inspect the active generation\n"
    "  /settings [save [project|user]]  inspect or save defaults\n"
    "  /model [list|PROVIDER/MODEL]     inspect or switch model\n"
    "  /mode [manual|plan|accept|auto]  execution policy\n"
    "  /effort [default|low|medium|high|max]  model effort\n"
    "  /fast [on|off]                  fast provider service\n"
    "  /context [limit TOKENS]         usage and context budget\n"
    "  /thinking [MODE]  show or set off/on/low/medium/high\n"
    "  /stream [on|off]  show or set streaming output\n"
    "  /eval EXPR        transactionally add a live Scheme definition\n"
    "  /reload           reload the agent file and retain live patches\n"
    "  /reload-clean     reload the file without live patches\n"
    "  /rollback         restore the previous working generation\n"
    "  /generations      list the active and rollback generations\n"
    "  /extensions       list persistent extension artifacts and status\n"
    "  /extension-create NAME EXPR  create a disabled artifact\n"
    "  /extension-load NAME         enable an artifact as a generation\n"
    "  /extension-disable NAME      remove its exact active patch\n"
    "  /extension-export NAME       save all active patches as an artifact\n"
    "  /traces [QUERY]   list recent spans or search all session traces\n"
    "  /trace SPAN_ID    inspect one full span returned by trace search\n"
    "  /compact          summarize older history and retain recent turns\n"
    "  /recover          inspect an interrupted tool record\n"
    "  /recover retry    explicitly retry the recorded tool call\n"
    "  /recover discard  discard the recorded tool call\n"
    "  /session          show the durable session identity and checkpoint\n"
    "  /reset            clear conversation state\n"
    "  /help             show this help\n"
    "  /quit             exit\n")))

(define (show-generation runtime)
  (let ((generation (runtime-current runtime)))
    (format #t
            "generation ~a  fingerprint ~a~%agent ~a  provider ~s  model ~a~%endpoint ~a  api-key-env ~s~%stream ~s  thinking ~s  keep-alive ~s~%tools ~s  shell ~s  patches ~a~%compaction threshold ~a  keep recent ~a~%source ~a~%"
            (generation-id generation)
            (generation-fingerprint generation)
            (generation-ref generation 'agent-name)
            (setting-ref generation 'agent-provider)
            (setting-ref generation 'agent-model)
            (setting-ref generation 'agent-base-url)
            (setting-ref generation 'agent-api-key-environment)
            (setting-ref generation 'agent-stream?)
            (setting-ref generation 'agent-thinking)
            (setting-ref generation 'agent-keep-alive)
            (generation-ref generation 'agent-tools)
            (generation-ref generation 'agent-shell-policy)
            (length (generation-patches generation))
            (generation-ref generation 'agent-compaction-threshold)
            (generation-ref generation 'agent-compaction-keep-recent)
            (generation-source-path generation))))

(define (short-fingerprint value)
  (substring value 0 (min 12 (string-length value))))

(define (enabled-label value)
  (if value "on" "off"))

(define (show-banner runtime watch? session)
  (let ((generation (runtime-current runtime)))
    (format #t
            "~%shift λ~%  ~a · generation ~a · ~a~%  ~a via ~a~%  stream ~a · thinking ~a · watch ~a~%  ~a tools · shell ~a · /help for commands~%~%"
            (generation-ref generation 'agent-name)
            (generation-id generation)
            (short-fingerprint (generation-fingerprint generation))
            (setting-ref generation 'agent-model)
            (setting-ref generation 'agent-provider)
            (enabled-label (setting-ref generation 'agent-stream?))
            (let ((thinking (setting-ref generation 'agent-thinking)))
              (if (boolean? thinking) (enabled-label thinking) thinking))
            (enabled-label watch?)
            (length (generation-ref generation 'agent-tools))
            (generation-ref generation 'agent-shell-policy))
    (when session
      (format #t "  session ~a · ~a · turn ~a~%"
              (session-name session)
              (if (session-resumed? session) "resumed" "new")
              (session-next-turn session)))))

(define (exception-detail exception)
  (catch #t
    (lambda ()
      (apply format
             (append (list #f (exception-message exception))
                     (exception-irritants exception))))
    (lambda _ (format #f "~s" exception))))

(define (caught-error-detail key arguments)
  (catch #t
    (lambda ()
      (if (and (>= (length arguments) 3) (string? (cadr arguments))
               (list? (caddr arguments)))
          (apply format #f (cadr arguments) (caddr arguments))
          (format #f "~a: ~s" key arguments)))
    (lambda _ (format #f "~a: ~s" key arguments))))

(define (stable-runtime-snapshot)
  (let ((root (getenv "SHIFT_INSTALL_ROOT")))
    (and root
         (let* ((directories
                 (map (lambda (relative) (string-append root "/" relative))
                      '("src/live-agent" "extensions/shift")))
                (modules
                 (append-map
                  (lambda (directory)
                    (if (file-exists? directory)
                        (map (lambda (name) (string-append directory "/" name))
                             (scandir directory
                                      (lambda (name)
                                        (string-suffix? ".scm" name))))
                        '()))
                  directories))
                (paths (sort (cons (string-append root "/bin/shift") modules)
                             string<?)))
           (map (lambda (path) (cons path (read-source-file path))) paths)))))

(define* (start-agent-watcher! runtime #:optional (on-reloaded (lambda () #t)))
  (let ((stopped? #f)
        (last-attempt #f)
        (runtime-snapshot (stable-runtime-snapshot)))
    (define (notice-reloaded generation)
      (format #t "~%\u21bb agent image reloaded · generation ~a · ~a~%"
              (generation-id generation)
              (short-fingerprint (generation-fingerprint generation)))
      (force-output))
    (define (notice-rejected detail)
      (runtime-record!
       runtime 'generation-reload-rejected
       `((generation . ,(generation-id (runtime-current runtime)))
         (error . ,detail)))
      (format (current-error-port)
              "~%\u21bb agent image change rejected · generation ~a remains active~%  ~a~%"
              (generation-id (runtime-current runtime))
              detail)
      (force-output (current-error-port)))
    (define (check-once!)
      (catch #t
        (lambda ()
          (let* ((current (runtime-current runtime))
                 (source-path (generation-source-path current))
                 (source-text (read-source-file source-path)))
            (cond
             ((string=? source-text (generation-source-text current))
              (set! last-attempt #f))
             ((and last-attempt (string=? source-text last-attempt)) #f)
             ((and runtime-snapshot
                   (not (equal? runtime-snapshot
                                (stable-runtime-snapshot))))
              (set! last-attempt source-text)
              (notice-rejected
               "stable runtime source changed; restart Shift before loading the new agent image"))
             (else
              ;; Remember rejected content too, so an editor's incomplete save
              ;; does not cause a retry storm. A later distinct save retries.
              (set! last-attempt source-text)
              (catch #t
                (lambda ()
                  (let ((generation (runtime-reload-if-changed! runtime)))
                    (when generation
                      (on-reloaded)
                      (notice-reloaded generation))))
                (lambda (key . arguments)
                  (notice-rejected (format #f "~s: ~s" key arguments))))))))
        ;; Atomic editor renames can briefly make the source unreadable. Treat
        ;; that as a wake-up miss and retry, not as a rejected generation.
        (lambda _ #f)))
    (let ((thread
           (call-with-new-thread
            (lambda ()
              (let loop ()
                (unless stopped?
                  (usleep 250000)
                  (unless stopped?
                    (check-once!)
                    (loop))))))))
      (lambda ()
        (set! stopped? #t)
        (join-thread thread)))))

(define (show-generations runtime)
  (for-each
   (lambda (summary)
     (format #t "~a~a  ~a  patches=~a  loaded=~a~%"
             (if (= (cdr (assq 'id summary))
                    (generation-id (runtime-current runtime)))
                 "* "
                 "  ")
             (cdr (assq 'id summary))
             (cdr (assq 'fingerprint summary))
             (cdr (assq 'patches summary))
             (cdr (assq 'loaded-at summary))))
   (runtime-generation-summaries runtime)))

(define* (show-traces tracer #:optional (query #f) (span-id #f))
  (if (not (builtin-enabled? 'tracing))
      (display "Tracing built-in is disabled.\n")
      (begin
  (format #t "trace file ~a~%session ~a~%" (tracer-path tracer)
          (tracer-session-id tracer))
  (call-with-values
      (lambda ()
        (trace-search tracer #:query query #:span-id span-id
                      #:limit (if span-id 1 12)))
    (lambda (spans matched scanned malformed)
      (when query
        (format #t "query ~s · ~a matches across ~a spans~%"
                query matched scanned))
      (when (> malformed 0)
        (format #t "ignored ~a malformed trace lines~%" malformed))
      (if (null? spans)
          (display "No matching completed spans.\n")
          (for-each
           (lambda (span)
             (if span-id
                 (begin (display (json-write span)) (newline))
                 (format #t "~6,1f ms  gen=~a turn=~a  ~a  ~a  ~a  span=~a~a~a~%"
                         (json-object-ref span "duration_ms")
                         (json-object-ref span "generation" "-")
                         (json-object-ref span "turn" "-")
                         (json-object-ref span "kind")
                         (json-object-ref span "name")
                         (json-object-ref span "status")
                         (json-object-ref span "span_id")
                         (let ((cache
                                (json-object-ref span "cache_status" json-null)))
                           (if (eq? cache json-null)
                               ""
                               (format
                                #f "  cache=~a (~a tokens)" cache
                                (json-object-ref span "cached_tokens" 0))))
                         (let ((preview (json-object-ref span "preview" "")))
                           (if (and (string? preview)
                                    (not (string-null? preview)))
                               (format #f "  ~s" preview)
                               "")))))
           spans)))))))

(define (execute-traces tracer arguments)
  (catch #t
    (lambda ()
      (let* ((limit (json-object-ref arguments "limit" 12))
             (errors-only? (json-object-ref arguments "errors_only" #f))
             (query (json-object-ref arguments "query" #f))
             (span-id (json-object-ref arguments "span_id" #f))
             (name (json-object-ref arguments "name" #f))
             (kind (json-object-ref arguments "kind" #f))
             (status (json-object-ref arguments "status" #f))
             (generation (json-object-ref arguments "generation" #f))
             (turn (json-object-ref arguments "turn" #f)))
        (unless (and (integer? limit) (>= limit 1) (<= limit 50))
          (error "trace limit must be an integer from 1 through 50" limit))
        (unless (boolean? errors-only?)
          (error "errors_only must be a boolean" errors-only?))
        (for-each
         (lambda (entry)
           (let ((value (cdr entry)))
             (unless (or (not value)
                         (and (string? value)
                              (not (string-null? (string-trim-both value)))))
               (error "trace text filters must be non-empty strings" entry))
             (when (and (string? value) (> (string-length value) 256))
               (error "trace text filters are limited to 256 characters" (car entry)))))
         `((query . ,query) (span_id . ,span-id) (name . ,name)
           (kind . ,kind) (status . ,status)))
        (unless (or (not generation) (and (integer? generation) (> generation 0)))
          (error "generation must be a positive integer" generation))
        (unless (or (not turn) (and (integer? turn) (> turn 0)))
          (error "turn must be a positive integer" turn))
        (call-with-values
            (lambda ()
              (trace-search
               tracer #:query query #:span-id span-id #:name name #:kind kind
               #:status status #:generation generation #:turn turn
               #:errors-only? errors-only? #:limit (if span-id 1 limit)))
          (lambda (found matched scanned malformed)
            (let loop ((spans found) (truncated? #f))
              (let*
                  ((response
                    (json-object
                     (cons "session_id" (tracer-session-id tracer))
                     (cons "trace_file" (tracer-path tracer))
                     (cons "mode"
                           (if span-id "get" (if query "search" "list")))
                     (cons "query" (or query json-null))
                     (cons "matched" matched)
                     (cons "scanned" scanned)
                     (cons "malformed" malformed)
                     (cons "truncated" truncated?)
                     (cons "spans" (apply json-array spans))))
                   (encoded (json-write response)))
                (if (or (<= (string-length encoded) (* 64 1024))
                        (null? spans))
                    (make-tool-result #t encoded)
                    (loop (drop-right spans 1) #t))))))))
    (lambda (key . arguments)
      (make-tool-result
       #f (format #f "trace inspection failed (~a): ~s" key arguments)))))

(define (runtime-state-directory tracer)
  (dirname (tracer-path tracer)))

(define (show-recovery tracer)
  (let ((pending (recovery-read (runtime-state-directory tracer))))
    (if pending
        (format #t
                "Interrupted tool may have partially executed.\n  tool ~a\n  generation ~a\n  started ~a\n  arguments ~a\nUse /recover retry only if repeating it is safe, or /recover discard.\n"
                (json-object-ref pending "tool")
                (json-object-ref pending "generation_id")
                (json-object-ref pending "created_at")
                (json-write (json-object-ref pending "arguments")))
        (display "No interrupted tool call is pending.\n"))))

(define (try-transition label thunk)
  (with-exception-handler
      (lambda (exception)
        (let ((detail (exception-detail exception)))
          (operation-failed! detail)
          (format (current-error-port)
                  "~a rejected; the active generation is unchanged: ~a~%"
                  label
                  detail))
        #f)
    thunk
    #:unwind? #t))

(define (extensions-directory)
  (string-append (getcwd) "/extensions"))

(define (extension-active? runtime name)
  (catch #t
    (lambda ()
      (if (member (extension-read (extensions-directory) name)
                  (generation-patches (runtime-current runtime)))
          #t
          #f))
    (lambda _ #f)))

(define (show-extensions runtime)
  (let ((names (extension-list (extensions-directory))))
    (if (null? names)
        (display "No extensions. Create one with /extension-create NAME EXPR.\n")
        (for-each
         (lambda (name)
           (format #t "~a  ~a~%"
                   (if (extension-active? runtime name) "enabled " "disabled")
                   name))
         names))))

(define (trimmed-command-argument line prefix)
  (string-trim-both (substring line (string-length prefix))))

(define (split-name-and-expression value)
  (let ((space (string-index value #\space)))
    (unless space
      (error "expected an extension name followed by a Scheme expression"))
    (let ((name (substring value 0 space))
          (expression (string-trim-both (substring value (+ space 1)))))
      (when (string-null? expression)
        (error "extension expression cannot be empty"))
      (list name expression))))

(define (create-extension! runtime name expression description)
  ;; Validate against the complete active image before persisting the artifact.
  (runtime-validate-patch! runtime expression)
  (extension-create! (extensions-directory) name expression description))

(define (load-extension! runtime name)
  (let ((expression (extension-read (extensions-directory) name)))
    (if (member expression (generation-patches (runtime-current runtime)))
        (runtime-current runtime)
        (runtime-apply-patch!
         runtime expression 'extension-load `((extension . ,name))))))

(define (disable-extension! runtime name)
  (let ((expression (extension-read (extensions-directory) name)))
    (runtime-remove-patch!
     runtime expression 'extension-disable `((extension . ,name)))))

(define (export-extension! runtime name description)
  (extension-export!
   (extensions-directory)
   name
   (generation-patches (runtime-current runtime))
   description))

(define (set-live-setting! runtime label binding source-value display-value)
  (let ((value (call-with-input-string source-value read)))
    (when (and (pair? value) (eq? (car value) 'quote)) (set! value (cadr value)))
    (setting-set! binding value)
    (runtime-record! runtime 'setting-changed `((setting . ,binding) (value . ,value)))
    (format #t "~a ~a · saved for this session~%" label display-value)))

(define last-usage (json-object))
(define last-estimate 0)
(define run-prompt-tokens 0)
(define run-completion-tokens 0)
(define run-usage-reported? #f)

(define (reset-run-usage!)
  (set! run-prompt-tokens 0)
  (set! run-completion-tokens 0)
  (set! run-usage-reported? #f))

(define (record-run-usage! attributes)
  (let ((prompt (assq-ref attributes 'llm.token_count.prompt))
        (completion (assq-ref attributes 'llm.token_count.completion)))
    (when (number? prompt)
      (set! run-prompt-tokens (+ run-prompt-tokens prompt))
      (set! run-usage-reported? #t))
    (when (number? completion)
      (set! run-completion-tokens (+ run-completion-tokens completion))
      (set! run-usage-reported? #t))))

(define (show-close-message session)
  (if run-usage-reported?
      (format #t "~%Session closed · ~a input + ~a output = ~a tokens~%"
              run-prompt-tokens run-completion-tokens
              (+ run-prompt-tokens run-completion-tokens))
      (display "\nSession closed · token usage unavailable\n"))
  (when session
    (format #t "Resume ./bin/shift --resume ~a~%ID ~a~%"
            (session-name session) (session-id session)))
  (force-output))

(define (show-context generation)
  (format #t "Context: ~a estimated input tokens; limit ~a; output reserve ~a.~%"
    last-estimate (or (model-context-limit generation) 'unknown)
    (setting-ref generation 'output-reserve))
  (format #t "Last reported usage: ~a~%" (json-write last-usage)))

(define (handle-preference-command runtime line)
  (let* ((generation (runtime-current runtime)) (parts (string-tokenize line))
         (command (car parts)) (value (and (pair? (cdr parts)) (cadr parts))))
    (cond
      ((string=? command "/settings")
       (if (equal? value "save")
           (let ((scope (if (= (length parts) 3) (string->symbol (caddr parts)) 'project)))
             (unless (memq scope '(user project)) (error "save scope must be project or user"))
             (format #t "Saved defaults: ~a~%" (settings-save! generation scope)))
           (settings-show generation)))
      ((string=? command "/model")
       (cond ((not value) (show-model generation) (display "Use /model list or /model PROVIDER/MODEL.\n"))
             ((string=? value "list") (model-list! generation))
             (else (model-select! value) (show-model generation))))
      ((string=? command "/context")
       (when value
         (unless (and (string=? value "limit") (= (length parts) 3)) (error "use /context limit TOKENS"))
         (setting-set! 'context-limit (string->number (caddr parts))))
       (show-context generation))
      ((string=? command "/mode")
       (when value (setting-set! 'mode (string->symbol value)))
       (format #t "Mode: ~a~%" (setting-ref generation 'mode))
       (when (eq? (setting-ref generation 'mode) 'auto)
         (display "Auto is conservative: read-only tools run; other tools require approval until model approval evaluation is complete.\n")))
      ((string=? command "/effort")
       (when value (setting-set! 'effort (string->symbol value))) (show-model generation))
      ((string=? command "/fast")
       (when value
         (unless (member value '("on" "off")) (error "use /fast on|off"))
         (setting-set! 'fast (string=? value "on")))
       (show-model generation)))))

(define (handle-thinking-command runtime line)
  (let* ((generation (runtime-current runtime))
         (current (setting-ref generation 'agent-thinking))
         (value
          (if (string=? line "/thinking")
              ""
              (trimmed-command-argument line "/thinking "))))
    (cond
     ((string-null? value)
      (format #t "thinking ~a~%"
              (if (boolean? current) (enabled-label current) current)))
     ((string=? value "off")
      (set-live-setting! runtime "thinking" 'agent-thinking "#f" "off"))
     ((string=? value "on")
      (set-live-setting! runtime "thinking" 'agent-thinking "#t" "on"))
     ((member value '("low" "medium" "high"))
      (set-live-setting!
       runtime "thinking" 'agent-thinking
       (string-append "'" value) value))
     (else
      (format (current-error-port)
              "thinking mode must be off, on, low, medium, or high~%")))))

(define (handle-stream-command runtime line)
  (let* ((generation (runtime-current runtime))
         (current (setting-ref generation 'agent-stream?))
         (value
          (if (string=? line "/stream")
              ""
              (trimmed-command-argument line "/stream "))))
    (cond
     ((string-null? value) (format #t "stream ~a~%" (enabled-label current)))
     ((string=? value "off")
      (set-live-setting! runtime "stream" 'agent-stream? "#f" "off"))
     ((string=? value "on")
      (set-live-setting! runtime "stream" 'agent-stream? "#t" "on"))
     (else
      (format (current-error-port) "stream mode must be off or on~%")))))

(define (show-session session)
  (if session
      (format #t "session ~a~%id ~a~%checkpoint ~a/session.json~%"
              (session-name session)
              (session-id session)
              (session-directory session))
      (display "This is an ephemeral session. Start with --session NAME to persist it.\n")))

(define (handle-command runtime tracer session line)
  (cond
   ((member (car (string-tokenize line)) '("/settings" "/model" "/context" "/mode" "/effort" "/fast"))
    (try-transition "settings" (lambda () (handle-preference-command runtime line)))
    'continue)
   ((string=? line "/help") (show-help) 'continue)
   ((string=? line "/show") (show-generation runtime) 'continue)
   ((or (string=? line "/thinking") (string-prefix? "/thinking " line))
    (handle-thinking-command runtime line)
    'continue)
   ((or (string=? line "/stream") (string-prefix? "/stream " line))
    (handle-stream-command runtime line)
    'continue)
   ((string=? line "/generations") (show-generations runtime) 'continue)
   ((string=? line "/extensions") (show-extensions runtime) 'continue)
   ((string=? line "/traces") (show-traces tracer) 'continue)
   ((string-prefix? "/traces " line)
    (show-traces tracer (trimmed-command-argument line "/traces "))
    'continue)
   ((string-prefix? "/trace " line)
    (show-traces tracer #f (trimmed-command-argument line "/trace "))
    'continue)
   ((string=? line "/compact") 'compact)
   ((string=? line "/recover") (show-recovery tracer) 'continue)
   ((string=? line "/recover retry") 'recover-retry)
   ((string=? line "/recover discard")
    (recovery-clear! (runtime-state-directory tracer))
    (display "Interrupted tool record discarded; no tool was executed.\n")
    'continue)
   ((string=? line "/session") (show-session session) 'continue)
   ((string=? line "/reload")
    (when (try-transition "reload" (lambda () (runtime-reload! runtime #t)))
      (show-generation runtime))
    'continue)
   ((string=? line "/reload-clean")
    (when (try-transition "clean reload" (lambda () (runtime-reload! runtime #f)))
      (show-generation runtime))
    'continue)
   ((string=? line "/rollback")
    (let ((generation (runtime-rollback! runtime)))
      (if generation
          (show-generation runtime)
          (display "No previous generation is available.\n")))
    'continue)
   ((string-prefix? "/eval " line)
    (let ((expression (substring line 6)))
      (when (try-transition "evaluation"
                            (lambda () (runtime-eval! runtime expression)))
        (show-generation runtime)))
    'continue)
   ((string-prefix? "/extension-create " line)
    (when
        (try-transition
         "extension creation"
         (lambda ()
           (let* ((parts
                   (split-name-and-expression
                    (trimmed-command-argument line "/extension-create ")))
                  (path
                   (create-extension!
                    runtime (car parts) (cadr parts)
                    "Created explicitly from the interactive session.")))
             (format #t "Created disabled extension ~a.\n" path)
             #t)))
      (show-extensions runtime))
    'continue)
   ((or (string-prefix? "/extension-load " line)
        (string-prefix? "/extension-enable " line))
    (let* ((prefix (if (string-prefix? "/extension-load " line)
                       "/extension-load "
                       "/extension-enable "))
           (name (trimmed-command-argument line prefix)))
      (when (try-transition "extension load"
                            (lambda () (load-extension! runtime name)))
        (show-generation runtime)))
    'continue)
   ((string-prefix? "/extension-disable " line)
    (let ((name
           (trimmed-command-argument line "/extension-disable ")))
      (when (try-transition "extension disable"
                            (lambda () (disable-extension! runtime name)))
        (show-generation runtime)))
    'continue)
   ((string-prefix? "/extension-export " line)
    (let ((name
           (trimmed-command-argument line "/extension-export ")))
      (when
          (try-transition
           "extension export"
           (lambda ()
             (let ((path
                    (export-extension!
                     runtime name "Exported explicitly from the active generation.")))
               (format #t "Exported active patches to ~a.\n" path)
               #t)))
        (show-extensions runtime)))
    'continue)
   ((string=? line "/reset") 'reset)
   ((or (string=? line "/quit") (string=? line "/exit")) 'quit)
   (else
    (format (current-error-port) "Unknown command. Enter /help.~%")
    'continue)))

(define (tool-name value)
  (if (symbol? value) (symbol->string value) value))

(define (read-user-line prompt)
  (if (and control-port (string=? prompt "shift> "))
      (begin
        (display prompt)
        (force-output)
        (emit-control! "ready")
        (let ((line (get-line (current-input-port))))
          (set! operation-status "ok")
          (set! operation-error #f)
          (set! operation-span #f)
          line))
      (if (isatty? (current-input-port))
          (let ((line (readline prompt)))
            (when (string=? prompt "shift> ") (input-remember! line))
            line)
          (get-line (current-input-port)))))

(define (terminal-settings)
  (catch #t
    (lambda ()
      (let* ((port (open-pipe* OPEN_READ "/bin/stty" "-g"))
             (value (string-trim-both (get-string-all port)))
             (status (close-pipe port)))
        (and (= (status:exit-val status) 0)
             (not (string-null? value))
             value)))
    (lambda _ #f)))

(define (read-approval-key prompt)
  (display prompt)
  (force-output)
  (emit-control! "needs_approval")
  (if (not (isatty? (current-input-port)))
      (read-user-line "")
      (let ((saved (terminal-settings)))
        (if (not saved)
            (read-user-line "")
            (let ((status
                   (system* "/bin/stty" "-icanon" "min" "1" "time" "0"
                            "-echo")))
              (if (not (= (status:exit-val status) 0))
                  (read-user-line "")
                  (let ((answer
                         (dynamic-wind
                           (lambda () #t)
                           (lambda () (read-char (current-input-port)))
                           (lambda () (system* "/bin/stty" saved)))))
                    (unless (eof-object? answer) (write-char answer))
                    (newline)
                    answer)))))))

(define (confirm-shell command)
  (format #t "\nShell requests:\n  ~a~%" command)
  (force-output)
  (let ((answer (read-approval-key "Approve this command? [y/N] ")))
    (cond
     ((char? answer) (char-ci=? answer #\y))
     ((string? answer)
      (member (string-downcase (string-trim-both answer)) '("y" "yes")))
     (else #f))))

(define (retry-interrupted-tool! runtime tracer)
  (let* ((state-directory (runtime-state-directory tracer))
         (pending (recovery-read state-directory)))
    (if (not pending)
        (begin
          (display "No interrupted tool call is pending.\n")
          #f)
        (let* ((generation (runtime-current runtime))
               (name (json-object-ref pending "tool"))
               (arguments (json-object-ref pending "arguments"))
               (enabled
                (filter
                 within-process-tool-ceiling?
                 (map tool-name (generation-ref generation 'agent-tools)))))
          (unless (member name enabled)
            (error "the interrupted tool is no longer enabled" name))
          (unless (or (member name '("write" "edit"))
                      (authorize-tool runtime generation name arguments))
            (error "recovery tool denied by current mode or approval"))
          (when (member name '("live_eval" "extension"))
            (error
             "live mutations cannot be replayed because their outcome is ambiguous; inspect the generation, then discard this record"
             name))
          (format #t
                  "Retrying interrupted ~a call explicitly. It may have partially executed before interruption.\n"
                  name)
          (let* ((span
                  (trace-start!
                   tracer (string-append "tool." name ".recovery") "TOOL"
                   `((generation.id . ,(generation-id generation))
                     (tool.name . ,name)
                     (recovery.retry . #t)
                     (input.value . ,(json-write arguments)))))
                 (outcome
                  (cond
                   ((string=? name "traces") (execute-traces tracer arguments))
                   ((member name '("write" "edit"))
                    (execute-change! runtime generation tracer name arguments #f))
                   (else
                    (execute-tool
                     name arguments (getcwd)
                     (generation-ref generation 'agent-shell-policy)
                     (lambda _ #t)))))
                 (output (tool-result-output outcome)))
            (when (tool-result-success? outcome) (record-observations! outcome))
            (trace-end!
             span (if (tool-result-success? outcome) "OK" "ERROR")
             `((output.value . ,output)))
            (runtime-record!
             runtime 'tool-recovery-retried
             `((generation . ,(generation-id generation))
               (tool . ,name)
               (success . ,(tool-result-success? outcome))
               (output . ,output)))
            (recovery-clear! state-directory)
            (format #t "Recovery result: ~a\n" output)
            (make-message
             "system"
             (format #f
                     "An interrupted ~a tool call was explicitly retried. Result: ~a. The original model continuation was lost; verify before relying on it."
                     name output)))))))

(define (record-input! runtime generation turn-count line)
  (runtime-record!
   runtime 'user-input
   `((generation . ,(generation-id generation))
     (turn . ,turn-count)
     (text . ,line))))

(define (record-output! runtime generation turn-count reply)
  (runtime-record!
   runtime 'assistant-output
   `((generation . ,(generation-id generation))
     (turn . ,turn-count)
     (text . ,reply))))

(define (demo-turn! runtime generation history line turn-count)
  (let ((reply (generation-call generation 'agent-demo-response line)))
    (record-output! runtime generation turn-count reply)
    (display reply)
    (newline)
    (list
     (append history
             (list (make-message "user" line)
                   (make-message "assistant" reply)))
     reply)))

(define (non-empty-tool-text arguments key)
  (let ((value (json-object-ref arguments key #f)))
    (unless (and (string? value) (not (string-null? (string-trim-both value))))
      (error "tool argument must be a non-empty string" key))
    value))

(define (last-item items)
  (if (null? (cdr items)) (car items) (last-item (cdr items))))

(define (assistant-explained-change? messages)
  (and (pair? messages)
       (let* ((message (last-item messages))
              (content (json-object-ref message "content" #f)))
         (and (string? content)
              (>= (string-length (string-trim-both content)) 12)))))

(define (execute-live-eval runtime generation arguments explained?)
  (catch #t
    (lambda ()
      (unless explained?
        (error
         "explain the exact live change and expected effect to the user before calling live_eval"))
      (let ((expression (non-empty-tool-text arguments "expression"))
            (summary (non-empty-tool-text arguments "summary"))
            (expected (non-empty-tool-text arguments "expected_behavior")))
        (let ((activated
               (runtime-apply-patch!
                runtime expression 'eval
                `((summary . ,summary) (expected-behavior . ,expected)))))
          (make-tool-result
           #t
           (format #f
                   "Live change applied: ~a\nBefore: generation ~a, fingerprint ~a\nAfter: generation ~a, fingerprint ~a\nExpected on the next user turn: ~a\nRequired follow-up: explain this before/after result to the user now. The current turn remains pinned to generation ~a; /rollback undoes it."
                   summary
                   (generation-id generation)
                   (generation-fingerprint generation)
                   (generation-id activated)
                   (generation-fingerprint activated)
                   expected
                   (generation-id generation))))))
    (lambda (key . arguments)
      (make-tool-result
       #f
       (string-append "live evaluation rejected: " (caught-error-detail key arguments))))))

(define (execute-extension runtime generation arguments)
  (catch #t
    (lambda ()
      (let ((action (non-empty-tool-text arguments "action")))
        (cond
         ((string=? action "list")
          (let ((names (extension-list (extensions-directory))))
            (make-tool-result
             #t
             (if (null? names)
                 "No extensions."
                 (string-join
                  (map (lambda (name)
                         (string-append
                          (if (extension-active? runtime name)
                              "enabled  " "disabled ")
                          name))
                       names)
                  "\n")))))
         ((string=? action "create")
          (let* ((name (non-empty-tool-text arguments "name"))
                 (expression (non-empty-tool-text arguments "expression"))
                 (description
                  (json-object-ref arguments "description"
                                   "Created by the agent from a live session."))
                 (path (create-extension! runtime name expression description)))
            (make-tool-result
             #t (format #f "Created disabled extension ~a." path))))
         ((string=? action "load")
          (let* ((name (non-empty-tool-text arguments "name"))
                 (before (runtime-current runtime))
                 (activated (load-extension! runtime name)))
            (make-tool-result
             #t
             (if (= (generation-id before) (generation-id activated))
                 (format #f "Extension ~a is already enabled in generation ~a."
                         name (generation-id before))
                 (format #f
                         "Enabled extension ~a: generation ~a (~a) -> generation ~a (~a). It applies on the next user turn."
                         name
                         (generation-id before) (generation-fingerprint before)
                         (generation-id activated)
                         (generation-fingerprint activated))))))
         ((string=? action "disable")
          (let* ((name (non-empty-tool-text arguments "name"))
                 (activated (disable-extension! runtime name)))
            (make-tool-result
             #t
             (format #f "Disabled extension ~a in generation ~a (~a)."
                     name (generation-id activated)
                     (generation-fingerprint activated)))))
         ((string=? action "export")
          (let* ((name (non-empty-tool-text arguments "name"))
                 (description
                  (json-object-ref arguments "description"
                                   "Exported by the agent from the active generation."))
                 (path (export-extension! runtime name description)))
            (make-tool-result
             #t (format #f "Exported active live patches to ~a." path))))
         (else (error "unknown extension action" action)))))
    (lambda (key . arguments)
      (make-tool-result
       #f
       (format #f "extension action rejected (~a): ~s" key arguments)))))

(define (valid-context-paths? paths)
  (and (list? paths)
       (<= (length paths) 8)
       (let loop ((remaining paths))
         (or (null? remaining)
             (and (string? (car remaining))
                  (not (string-null? (car remaining)))
                  (loop (cdr remaining)))))))

(define (join-context sections)
  (if (null? sections)
      ""
      (let loop ((remaining (cdr sections)) (result (car sections)))
        (if (null? remaining)
            result
            (loop (cdr remaining)
                  (string-append result "\n\n" (car remaining)))))))

(define (select-context-with-trace runtime tracer parent generation line)
  (let ((span
         (trace-start!
          tracer "context.select" "RETRIEVER"
          `((generation.id . ,(generation-id generation))
            (input.value . ,line))
          parent)))
    (catch #t
      (lambda ()
        (let ((paths
               (generation-call generation 'agent-select-context line)))
          (unless (valid-context-paths? paths)
            (error
             "agent-select-context must return at most eight non-empty paths"
             paths))
          (when (and (pair? paths)
                     (not (within-process-tool-ceiling? "read")))
            (error
             "context selection requires read authority, which this process ceiling omits"
             paths))
          (let* ((sections
                  (map
                   (lambda (path)
                     (unless (authorize-tool runtime generation "read" (json-object (cons "path" path)))
                       (error "context read denied" path))
                     (let ((result
                            (execute-tool
                             "read"
                             (json-object (cons "path" path))
                             (getcwd)
                             'deny
                             (lambda _ #f))))
                       (unless (tool-result-success? result)
                         (error "selected context could not be read"
                                path (tool-result-output result)))
                       (record-observations! result)
                       (format #f "## ~a\n\n~a"
                               path (tool-result-output result))))
                   paths))
                 (content (join-context sections))
                 (encoded-paths (json-write (apply json-array paths))))
            (trace-end!
             span "OK"
             `((context.paths . ,encoded-paths)
               (output.value . ,content)))
            (list paths content))))
      (lambda (key . arguments)
        (trace-end!
         span "ERROR"
         `((error.type . ,(symbol->string key))
           (error.message . ,(format #f "~s" arguments))))
        (apply throw key arguments)))))

(define interactive-approval? (make-parameter #t))
(define current-turn (make-parameter 0))
;; The change ledger is process-owned state beside the recovery record.
(define ledger #f)
(define* (authorize-tool runtime generation name arguments #:optional (preview #f))
  (let* ((decision (tool-decision (setting-ref generation 'mode) name arguments))
         (allowed? (case decision
                     ((allow) #t)
                     ((ask) (and (interactive-approval?)
                       (begin
                         (if preview
                             (format #t "\n~a" preview)
                             (format #t "\nTool requests: ~a\n~a\n" name (json-write arguments)))
                         (let ((answer (read-approval-key "Approve tool? [y/N] ")))
                           (or (and (char? answer) (char-ci=? answer #\y))
                               (and (string? answer) (member (string-downcase (string-trim-both answer)) '("y" "yes"))))))))
                     (else #f))))
    (runtime-record! runtime 'tool-approval
      `((tool . ,name) (mode . ,(setting-ref generation 'mode)) (decision . ,decision) (approved . ,(if allowed? #t #f))))
    allowed?))

(define (unavailable-result name)
  (make-tool-result
   #f
   (format #f
           "tool unavailable in this turn: ~a. The active image, execution mode, or approval denied it. Continue without it."
           name)))

(define (change-preview name prepared)
  (format #f "~a ~a ~a~%~a"
          name (prepared-change-path prepared)
          (format-diffstat (prepared-change-diffstat prepared))
          (diff-preview (prepared-change-diff prepared) 120)))

(define (record-observations! result)
  (when ledger
    (for-each
     (lambda (change)
       (when (eq? (assq-ref change 'kind) 'seen)
         (ledger-observe! ledger (current-turn)
                          (assq-ref change 'path) (assq-ref change 'hash))))
     (tool-result-changes result))))

(define (change-attributes result)
  (let ((mutations (filter (lambda (change) (eq? (assq-ref change 'kind) 'mutation))
                           (tool-result-changes result))))
    (if (null? mutations)
        '()
        `((tool.changes
           . ,(json-write
               (apply json-array
                      (map (lambda (change)
                             (json-object
                              (cons "path" (assq-ref change 'path))
                              (cons "before" (or (assq-ref change 'before) json-null))
                              (cons "after" (assq-ref change 'after))
                              (cons "added" (assq-ref change 'added))
                              (cons "removed" (assq-ref change 'removed))))
                           mutations))))))))

;; A mutation is prepared without touching the project, checked against the
;; ledger's last-seen hash, shown as a diff for approval, journaled as a
;; write-ahead ledger entry, and only then committed atomically.
(define (execute-change! runtime generation tracer name arguments call-id)
  (catch #t
    (lambda ()
      (let* ((prepared (prepare-change name arguments (getcwd)))
             (path (prepared-change-path prepared)))
        (when ledger
          (ledger-check-stale! ledger path (prepared-change-before-hash prepared)))
        (if (not (authorize-tool runtime generation name arguments
                                 (change-preview name prepared)))
            (unavailable-result name)
            (let ((seq (and ledger
                            (ledger-begin! ledger (current-turn) call-id name path
                                           (prepared-change-before-text prepared)
                                           (prepared-change-after-text prepared)))))
              (recovery-write! (runtime-state-directory tracer) name arguments
                               (generation-id generation))
              (catch #t
                (lambda ()
                  (let ((result (commit-change! prepared)))
                    (when seq (ledger-commit! ledger seq))
                    result))
                (lambda (key . detail)
                  (if (cancelled? key)
                      (apply throw key detail)
                      (begin
                        (when seq (ledger-abort! ledger seq))
                        (make-tool-result
                         #f (string-append "tool failed: "
                                           (caught-error-detail key detail)))))))))))
    (lambda (key . detail)
      (if (cancelled? key)
          (apply throw key detail)
          (make-tool-result
           #f (string-append "tool error: " (caught-error-detail key detail)))))))

(define (execute-tool-calls runtime tracer parent generation provider calls
                            messages enabled-tools)
  (let loop ((remaining calls) (result messages))
    (if (null? remaining)
        result
        (let* ((call (car remaining))
               (name (tool-call-name call))
               (enabled? (if (member name enabled-tools) #t #f)))
          (runtime-record!
           runtime 'tool-call
           `((generation . ,(generation-id generation))
             (tool . ,name)
             (arguments . ,(json-write (tool-call-arguments call)))))
          (let* ((span
                  (trace-start!
                   tracer (string-append "tool." name) "TOOL"
                   `((generation.id . ,(generation-id generation))
                     (tool.name . ,name)
                     (input.value . ,(json-write (tool-call-arguments call))))
                   parent))
                 (outcome
                  (catch 'turn-cancelled
                    (lambda ()
                      (cond
                       ((not enabled?) (unavailable-result name))
                       ((member name '("write" "edit"))
                        (execute-change! runtime generation tracer name
                                         (tool-call-arguments call) (tool-call-id call)))
                       ((not (authorize-tool runtime generation name (tool-call-arguments call)))
                        (unavailable-result name))
                       (else
                        ;; This write-ahead record is deliberately retained if
                        ;; cancellation or process death interrupts execution.
                        (recovery-write!
                         (runtime-state-directory tracer)
                         name (tool-call-arguments call)
                         (generation-id generation))
                        (catch #t
                          (lambda ()
                            (cond
                             ((string=? name "live_eval")
                              (execute-live-eval
                               runtime generation (tool-call-arguments call)
                               (assistant-explained-change? messages)))
                             ((string=? name "extension")
                              (execute-extension
                               runtime generation (tool-call-arguments call)))
                             ((string=? name "traces")
                              (execute-traces tracer (tool-call-arguments call)))
                             (else
                              (execute-tool
                               name
                               (tool-call-arguments call)
                               (getcwd)
                               (generation-ref generation 'agent-shell-policy)
                               (lambda _ #t)))))
                          (lambda (key . arguments)
                            (if (cancelled? key)
                                (apply throw key arguments)
                                (make-tool-result
                                 #f (format #f "tool failed (~a): ~s" key arguments))))))))
                    (lambda (key . arguments)
                      (trace-end!
                       span "CANCELLED"
                       `((error.message . "tool interrupted; recovery record retained")))
                      (apply throw key arguments))))
                 (ok? (tool-result-success? outcome))
                 (output (tool-result-output outcome)))
            (when ok? (record-observations! outcome))
            (trace-end! span (if ok? "OK" "ERROR")
                        `((output.value . ,output)
                          ,@(change-attributes outcome)))
            (runtime-record!
             runtime 'tool-result
             `((generation . ,(generation-id generation))
               (tool . ,name)
               (output . ,output)))
            (when enabled?
              (recovery-clear! (runtime-state-directory tracer)))
            (loop (cdr remaining)
                  (append result
                          (list
                           (make-tool-result-message
                            provider
                            (tool-call-id call)
                            name
                            output)))))))))

(define (messages-character-count messages)
  (fold (lambda (message total)
          (+ total (string-length (json-write message))))
        0 messages))

(define (complete-with-trace tracer parent generation-id provider model base-url
                             api-key messages enabled-tools stream? thinking
                             keep-alive prompt-cache-key round
                             prompt-attributes effort fast? reserve)
  (let ((span
         (trace-start!
          tracer (string-append (symbol->string provider) ".chat") "LLM"
          (append
           `((generation.id . ,generation-id)
             (llm.model_name . ,model)
             (llm.provider . ,(symbol->string provider))
             (llm.round . ,round)
             (input.value . ,(json-write (apply json-array messages))))
           prompt-attributes)
          parent))
        (thinking-started? #f)
        (content-started? #f))
    (define (on-thinking chunk)
      (unless thinking-started?
        (set! thinking-started? #t)
        (display "thinking> "))
      (display chunk)
      (force-output))
    (define (on-content chunk)
      (unless content-started?
        (set! content-started? #t)
        (when thinking-started? (newline))
        (display "assistant> "))
      (display chunk)
      (force-output))
    (catch #t
      (lambda ()
        (let ((completion
               (provider-complete
                provider model base-url api-key messages enabled-tools
                stream? thinking keep-alive prompt-cache-key
                on-content on-thinking
                effort fast? reserve)))
          (when (or thinking-started? content-started?)
            (newline)
            (force-output))
          (set! last-usage
            (let ((raw (completion-usage completion)))
              (let ((value (json-object-ref raw "usage"
                (apply json-object (filter (lambda (entry)
                  (member (car entry) '("prompt_eval_count" "eval_count" "total_duration")))
                  (json-object-entries raw))))))
                (if (json-object-ref raw "service_tier" #f)
                    (apply json-object (acons "service_tier" (json-object-ref raw "service_tier") (json-object-entries value))) value))))
          (let ((attributes (usage-attributes completion)))
            (record-run-usage! attributes)
            (trace-end!
             span "OK"
             (append
              `((output.value . ,(or (completion-content completion) ""))
                (llm.thinking . ,(or (completion-thinking completion) "")))
              attributes)))
          (cons completion content-started?)))
      (lambda (key . arguments)
        (when (or thinking-started? content-started?)
          (newline)
          (force-output))
        (trace-end! span (if (cancelled? key) "CANCELLED" "ERROR")
                    `((error.type . ,(symbol->string key))
                      (error.message . ,(format #f "~s" arguments))))
        (apply throw key arguments)))))

(define (provider-turn! runtime tracer parent generation history line turn-count)
  (let* ((provider (setting-ref generation 'agent-provider))
         (model (setting-ref generation 'agent-model))
         (base-url (setting-ref generation 'agent-base-url))
         (key-environment
          (setting-ref generation 'agent-api-key-environment))
         (api-key (and key-environment (getenv key-environment)))
         (configured-tools
          (map tool-name (generation-ref generation 'agent-tools)))
         (enabled-tools
          (filter (lambda (name)
                    (and (within-process-tool-ceiling? name)
                         (or (not (string=? name "traces")) (builtin-enabled? 'tracing))))
                  configured-tools))
         (max-rounds
          (generation-ref generation 'agent-max-tool-rounds))
         (stream? (setting-ref generation 'agent-stream?))
         (thinking (setting-ref generation 'agent-thinking))
         (keep-alive (setting-ref generation 'agent-keep-alive))
         (system
          (make-message
           "system" (generation-ref generation 'agent-system-prompt)))
         (transformed-line
          (generation-call generation 'agent-transform-user line))
         (selected
          (select-context-with-trace
           runtime tracer parent generation transformed-line))
         (context-paths (car selected))
         (context-text (cadr selected))
         (context-messages
          (if (null? context-paths)
              '()
              (list
               (make-message
                "system"
                (string-append
                 "Authoritative project context selected by agent-select-context "
                 "for this turn. Prefer it over earlier answers when they conflict.\n\n"
                 context-text)))))
         (user-message (make-message "user" transformed-line))
         (cache-prefix (append (list system) history))
         (cache-cohort
          "session")
         (prompt-cache-key
          (string-append
           "shift-" (generation-fingerprint generation) "-" cache-cohort))
         (prompt-attributes
          `((turn.number . ,turn-count)
            (prompt.cache.cohort
             . ,cache-cohort)
            (prompt.cache.key . ,prompt-cache-key)
            (prompt.cache.prefix_messages
             . ,(prompt-cache-prefix-count history))
            (prompt.cache.prefix_chars
             . ,(messages-character-count cache-prefix))
            (prompt.cache.dynamic_context_chars
             . ,(messages-character-count context-messages))
            (prompt.cache.tool_count . ,(length enabled-tools))))
         (working
          (build-provider-messages
           system history context-messages user-message)))
    (let loop ((messages working) (round 0))
      (set! last-estimate (estimate-input-tokens messages enabled-tools))
      (when (context-over-budget? last-estimate (model-context-limit generation)
                                  (setting-ref generation 'output-reserve))
        (let* ((prefix (compaction-prefix history 4))
               (tail (drop messages (+ 1 (length history) (length context-messages)))))
          (when (null? prefix)
            (error "Context budget exceeded; current turn is too large to compact safely. Use /compact, /reset, or a larger /context limit."))
          (let* ((summary (summarize-compaction generation prefix))
                 (compacted (compact-history-with-summary history summary 4)))
            (set! history compacted)
            (set! messages (append (list system) history context-messages tail))
            (set! last-estimate (estimate-input-tokens messages enabled-tools))
            (runtime-record! runtime 'session-compacted
              `((reason . token-budget) (estimated-tokens . ,last-estimate)))
            (display "Compacted earlier turns before the request.\n")))
        (when (context-over-budget? last-estimate (model-context-limit generation)
                                    (setting-ref generation 'output-reserve))
          (error "Context still exceeds the budget; original checkpoint retained. Reduce input or increase /context limit.")))
      (let* ((outcome
              (complete-with-trace
               tracer parent (generation-id generation)
               provider model base-url api-key messages
               enabled-tools stream? thinking keep-alive prompt-cache-key round
               prompt-attributes (effective-effort generation) (effective-fast? generation)
               (setting-ref generation 'output-reserve)))
             (completion (car outcome))
             (content-streamed? (cdr outcome))
             (calls (completion-tool-calls completion))
             (with-assistant
              (append messages (list (completion-assistant-message completion)))))
        (if (null? calls)
            (let ((reply (or (completion-content completion) "")))
              (record-output! runtime generation turn-count reply)
              (unless content-streamed?
                (unless (string-null? (or (completion-thinking completion) ""))
                  (format #t "thinking> ~a~%" (completion-thinking completion)))
                (format #t "assistant> ~a~%" reply))
              ;; Drop the runtime-owned system prompt and this turn's selected
              ;; context while retaining the prior history and new turn tail.
              (list
               (persist-provider-turn
                history (length context-messages) with-assistant)
               reply))
            (begin
              (when (>= round max-rounds)
                (error "tool round limit reached" max-rounds))
              (loop
               (execute-tool-calls
                runtime tracer parent generation provider calls with-assistant
                enabled-tools)
               (+ round 1))))))))

(define (summarize-compaction generation prefix)
  (when (context-over-budget? (+ 256 (estimate-input-tokens prefix '()))
                              (model-context-limit generation)
                              (setting-ref generation 'output-reserve))
    (error "Earlier context exceeds the summarizer budget; original history retained. Select a larger-context model."))
  (if (string=? (setting-ref generation 'agent-model) "demo")
      (format #f "Compacted ~a earlier messages from the demo session."
              (length prefix))
      (let* ((provider (setting-ref generation 'agent-provider))
             (key-environment
              (setting-ref generation 'agent-api-key-environment))
             (api-key (and key-environment (getenv key-environment)))
             (keep-alive (setting-ref generation 'agent-keep-alive))
             (completion
              (provider-complete
               provider
               (setting-ref generation 'agent-model)
               (setting-ref generation 'agent-base-url)
               api-key
               (list
                (make-message
                 "system"
                 (string-append
                  "Summarize the earlier agent conversation for safe continuation. "
                  "Preserve user intent, decisions, exact file paths, generation changes, "
                  "tool outcomes, unresolved work, and safety constraints. Do not claim "
                  "success without a recorded tool result. Return only the compact summary."))
                (make-message
                 "user" (json-write (apply json-array prefix))))
               '() #f #f keep-alive
               (string-append
                "shift-" (generation-fingerprint generation) "-compaction")
               (lambda _ #t) (lambda _ #t))))
        (record-run-usage! (usage-attributes completion))
        (let ((summary (or (completion-content completion) "")))
          (when (string-null? (string-trim-both summary))
            (error "compaction model returned an empty summary"))
          summary))))

(define (compact-history! runtime tracer history force?)
  (let* ((generation (runtime-current runtime))
         (threshold
          (generation-ref generation 'agent-compaction-threshold))
         (keep-recent
          (generation-ref generation 'agent-compaction-keep-recent)))
    (if (not (or force? (history-needs-compaction? history threshold)))
        (begin
          (when force?
            (format #t "History has ~a messages; nothing is old enough to compact.\n"
                    (length history)))
          history)
        (let ((prefix (compaction-prefix history keep-recent)))
          (if (null? prefix)
              history
              (let ((span
                     (trace-start!
                      tracer "session.compact" "AGENT"
                      `((generation.id . ,(generation-id generation))
                        (compaction.before_messages . ,(length history))
                        (compaction.prefix_messages . ,(length prefix))
                        (compaction.keep_recent . ,keep-recent)))))
                (dynamic-wind
                  (lambda () (set! turn-active? #t) (set! turn-thread (current-thread)))
                  (lambda ()
                    (catch #t
                      (lambda ()
                        (let* ((summary (summarize-compaction generation prefix))
                               (compacted
                                (compact-history-with-summary
                                 history summary keep-recent)))
                          (trace-end!
                           span "OK"
                           `((generation.id . ,(generation-id generation))
                             (compaction.after_messages . ,(length compacted))
                             (output.value . ,summary)))
                          (runtime-record!
                           runtime 'session-compacted
                           `((generation . ,(generation-id generation))
                             (before-messages . ,(length history))
                             (after-messages . ,(length compacted))))
                          (format #t "compacted ~a messages to ~a · generation ~a\n"
                                  (length history) (length compacted)
                                  (generation-id generation))
                          compacted))
                      (lambda (key . arguments)
                        (trace-end!
                         span (if (cancelled? key) "CANCELLED" "ERROR")
                         `((error.message . ,(format #f "~s" arguments))))
                        (operation-failed! (format #f "~s" arguments))
                        (when (cancelled? key) (set! operation-status "cancelled"))
                        (format (current-error-port)
                                "compaction failed; original history retained: ~s~%"
                                arguments)
                        history)))
                  (lambda () (set! turn-active? #f) (set! turn-thread #f)))))))))

(define (perform-turn! runtime tracer history line turn-count)
  (let* ((generation (runtime-current runtime))
         (span
          (trace-start!
           tracer "agent.turn" "AGENT"
           `((generation.id . ,(generation-id generation))
             (turn.number . ,turn-count)
             (input.value . ,line)))))
    (set! operation-span (trace-span-id span))
    (record-input! runtime generation turn-count line)
    (dynamic-wind
      (lambda () (set! turn-active? #t) (set! turn-thread (current-thread)))
      (lambda ()
        (catch #t
          (lambda ()
            (let ((new-history
                   (if (string=? (setting-ref generation 'agent-model) "demo")
                       (demo-turn! runtime generation history line turn-count)
                       (provider-turn!
                        runtime tracer span generation history line turn-count))))
              (trace-end! span "OK" `((output.value . ,(cadr new-history))))
              (list 'ok (car new-history))))
          (lambda (key . arguments)
            (if (cancelled? key)
                (begin
                  (trace-end! span "CANCELLED"
                              '((error.message . "cancelled by user")))
                  (runtime-record!
                   runtime 'turn-cancelled
                   `((generation . ,(generation-id generation))
                     (turn . ,turn-count)))
                  (set! operation-status "cancelled")
                  (display "turn cancelled; conversation state is unchanged.\n")
                  #f)
                (let ((detail (format #f "~s: ~s" key arguments)))
                  (operation-failed! detail)
                  (trace-end! span "ERROR" `((error.message . ,detail)))
                  (format (current-error-port) "turn failed: ~a~%" detail)
                  #f)))))
      (lambda () (set! turn-active? #f) (set! turn-thread #f)))))

(define mcp-stdio? #f)
(define mcp-http? (and (isatty? (current-input-port)) (not control-port)))
(define mcp-port 7331)
(define (transport-arguments args)
  (let loop ((remaining args) (out '()))
    (cond
      ((null? remaining) (reverse out))
      ((string=? (car remaining) "--mcp")
       (set! mcp-stdio? #t) (set! mcp-http? #f) (loop (cdr remaining) out))
      ((string=? (car remaining) "--no-mcp")
       (set! mcp-http? #f) (loop (cdr remaining) out))
      ((string=? (car remaining) "--mcp-port")
       (unless (pair? (cdr remaining)) (error "--mcp-port requires a port"))
       (let ((port (string->number (cadr remaining))))
         (unless (and (integer? port) (> port 0) (< port 65536)) (error "invalid MCP port"))
         (set! mcp-port port) (set! mcp-http? #t))
       (loop (cddr remaining) out))
      (else (loop (cdr remaining) (cons (car remaining) out))))))

;; Both transports call this one controller; only it advances conversation
;; state. Read-only status stays available while a turn owns the mutation lock.
(define (repl runtime tracer watch? session checkpoint! initial-prompt)
  (let ((history (if session (normalize-messages (session-history session)) '()))
        (turn-count (if session (session-next-turn session) 1))
        (lock (make-mutex)))
    (define (process! line)
      (set! operation-status "ok") (set! operation-error #f) (set! operation-span #f)
      (parameterize ((current-turn turn-count))
      (let ((action
             (cond
               ((string-null? (string-trim-both line)) 'continue)
               ((string-prefix? "/" line) (handle-command runtime tracer session line))
               (else
                 (let ((result (perform-turn! runtime tracer history line turn-count)))
                   (when result
                     (set! history (compact-history! runtime tracer (cadr result) #f))
                     (set! turn-count (+ turn-count 1)))) 'continue))))
        (case action
          ((reset) (set! history '()) (set! turn-count 1) (display "Conversation state cleared.\n"))
          ((compact) (set! history (compact-history! runtime tracer history #t)))
          ((recover-retry)
           (let ((message (try-transition "tool recovery" (lambda () (retry-interrupted-tool! runtime tracer)))))
             (when message (set! history (append history (list message)))))))
        (checkpoint! history turn-count)
        action)))
    (define (dispatch method argument)
      (if (eq? method 'cancel)
          (begin
            (when turn-thread
              (system-async-mark (lambda () (throw 'turn-cancelled "cancelled by MCP client")) turn-thread))
            "Cancellation requested.")
      (if (eq? method 'status)
          (json-object (cons "pid" (getpid)) (cons "project" (getcwd))
            (cons "session" (if session (session-name session) json-null))
            (cons "generation" (generation-id (runtime-current runtime)))
            (cons "turn" turn-count) (cons "messages" (length history))
            (cons "busy" turn-active?) (cons "settings" (settings-object (runtime-current runtime))))
          (begin
            (unless (and (string? argument) (<= (string-length argument) 262144)) (error "invalid input"))
            (when (and (eq? method 'prompt) (string-prefix? "/" argument))
              (error "shift_prompt accepts prompts; use shift_inspect for read-only commands"))
            (when (and (eq? method 'inspect)
                       (not (or (member argument '("/show" "/settings" "/context" "/session" "/generations" "/traces" "/extensions"))
                                (string-prefix? "/trace " argument) (string-prefix? "/traces " argument))))
              (error "command is not read-only; change settings in the terminal"))
            (unless (try-mutex lock) (error "session busy; retry after the active operation finishes"))
            (dynamic-wind
              (lambda () #t)
              (lambda ()
                (let ((output (open-output-string)))
                  (parameterize ((current-output-port output) (current-error-port output) (interactive-approval? #f))
                    (process! argument))
                  (when (not (string=? operation-status "ok")) (error "session operation failed" (get-output-string output)))
                  (get-output-string output)))
              (lambda () (unlock-mutex lock)))))))
    (let ((stop-mcp!
            (if (and mcp-http? (builtin-enabled? 'mcp))
                (catch #t
                  (lambda () ((builtin-ref 'mcp 'start-mcp!) mcp-port dispatch))
                  (lambda _ (error "MCP port unavailable; choose --mcp-port PORT or --no-mcp" mcp-port)))
                (lambda () #t))))
      (dynamic-wind
        (lambda () #t)
        (lambda ()
          (if mcp-stdio?
              ((builtin-ref 'mcp 'run-mcp-stdio) dispatch)
              (begin
                (show-banner runtime watch? session)
                (show-model (runtime-current runtime))
                (when (and mcp-http? (builtin-enabled? 'mcp))
                  (format #t "MCP http://127.0.0.1:~a/mcp · live process ~a~%" mcp-port (getpid)))
                (force-output)
                (when initial-prompt (with-mutex lock (process! initial-prompt)))
                (let loop ()
                  (let ((line (read-user-line "shift> ")))
                    (cond
                      ((eof-object? line) (newline))
                      ((try-mutex lock)
                       (let ((action (dynamic-wind
                                       (lambda () #t)
                                       (lambda () (process! line))
                                       (lambda () (unlock-mutex lock)))))
                         (unless (eq? action 'quit) (loop))))
                      (else (display "Session busy with an MCP operation.\n") (loop))))))))
        (lambda () (stop-mcp!))))))

(define (main args)
  (reset-run-usage!)
  (call-with-values
      (lambda () (parse-arguments (transport-arguments args)))
    (lambda (agent-path state-directory watch? requested-session-name session-mode
             list? initial-prompt fork-parent fork-child)
      (when mcp-stdio? (set! watch? #f))
      (when (and mcp-stdio? (not (builtin-enabled? 'mcp))) (error "MCP built-in is disabled"))
      (unless (and agent-path state-directory)
        (usage)
        (exit 2))
      (when fork-parent
        (let ((forked
               (try-transition
                "session fork"
                (lambda ()
                  (fork-session!
                   state-directory fork-parent fork-child)))))
          (unless forked (exit 1))
          (format #t
                  "forked session ~a -> ~a · generation ~a · ~a · turn ~a~%"
                  fork-parent fork-child
                  (json-object-ref forked "generation_id")
                  (json-object-ref forked "fingerprint")
                  (json-object-ref forked "next_turn")))
        (exit 0))
      (when list?
        (let ((names (list-session-names state-directory)))
          (if (null? names)
              (display "No durable sessions.\n")
              (for-each (lambda (name) (display name) (newline)) names)))
        (exit 0))
      (when (and (not requested-session-name) (isatty? (current-input-port)) (not control-port) (not mcp-stdio?))
        (set! requested-session-name "default") (set! session-mode 'auto))
      (let* ((session
              (and requested-session-name
                   (try-transition
                    "session open"
                    (lambda ()
                      (open-session!
                       state-directory requested-session-name session-mode)))))
             (runtime-state-directory
              (if session (session-directory session) state-directory))
             (runtime
              (and
               (or (not requested-session-name) session)
               (try-transition
                "startup"
                (lambda ()
                  (make-runtime
                   agent-path runtime-state-directory
                   (if session (session-patches session) '())
                   (if session (session-generation-id session) 1)
                   (and session (session-fingerprint session)))))))
             (tracer
              (and runtime
                   (make-tracer
                    runtime-state-directory
                    (or (getenv "SHIFT_OTEL_ENDPOINT")
                        (getenv "LISP_AGENT_OTEL_ENDPOINT")
                        (getenv "PHOENIX_COLLECTOR_ENDPOINT"))
                    (and session (session-id session))
                    (and session (session-name session))))))
        (unless runtime (exit 1))
        (set! ledger (open-ledger runtime-state-directory))
        (settings-init! state-directory (and session runtime-state-directory))
        (load-dotenv! (string-append (getcwd) "/.env"))
        (input-init! state-directory)
        (install-cancellation-handler!)
        (let ((checkpoint-history
               (if session (normalize-messages (session-history session)) '()))
              (checkpoint-turn
               (if session (session-next-turn session) 1)))
          (define (checkpoint! history next-turn)
            (set! checkpoint-history history)
            (set! checkpoint-turn next-turn)
            (when session
              (save-session! session runtime history next-turn)))
          (when session
            (runtime-record!
             runtime
             (if (session-resumed? session) 'session-resumed 'session-created)
             `((session . ,(session-name session))
               (session-id . ,(session-id session))
               (turn . ,checkpoint-turn)))
            (checkpoint! checkpoint-history checkpoint-turn))
          (let ((stop-watcher!
                 (if watch?
                     (start-agent-watcher!
                      runtime
                      (lambda ()
                        (checkpoint! checkpoint-history checkpoint-turn)))
                     (lambda () #t))))
          (dynamic-wind
            (lambda () #t)
            (lambda ()
              (when (recovery-read runtime-state-directory)
                (display
                 "\n! interrupted tool record found; use /recover before continuing.\n"))
              (repl runtime tracer watch? session checkpoint! initial-prompt))
            (lambda ()
              (stop-watcher!)
              (trace-close! tracer)
              (unless (or mcp-stdio? control-port)
                (show-close-message session))
              (when session (close-session! session))))))))))
