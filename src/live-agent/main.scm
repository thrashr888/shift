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
  #:use-module (live-agent ui)
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
  #:use-module (live-agent provider-metadata)
  #:use-module (live-agent prompt)
  #:use-module (live-agent receipt)
  #:use-module (live-agent recovery)
  #:use-module (live-agent runtime)
  #:use-module (live-agent session)
  #:use-module (live-agent workflow)
  #:use-module (live-agent improve)
  #:use-module (live-agent skills)
  #:use-module ((live-agent mcp-client) #:hide (mcp-tool-hints))
  #:use-module (live-agent judge)
  #:use-module (live-agent typesafe)
  #:use-module (live-agent typed)
  #:use-module (live-agent plugins)
  #:use-module (live-agent trace)
  #:use-module (live-agent tools)
  #:use-module (live-agent redact)
  #:export (main))

(define turn-active? #f)
(define turn-thread #f)
;; A private inherited pipe carries lifecycle results to the MCP supervisor.
;; Model output and terminal prompts are never control messages.
(define control-port
  (let ((fd (getenv "SHIFT_CONTROL_FD")))
    (and fd (let ((port (fdopen (string->number fd) "w")))
              (fcntl port F_SETFD FD_CLOEXEC)
              (set-port-encoding! port "UTF-8")
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
  (append '("ui" "read" "rg" "skill" "tool_search" "write" "edit" "shell" "traces" "recall" "notes" "spawn" "workflow" "live_eval" "extension")
          coding-tool-names))

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
;; A spawned child stores its ceiling beside its checkpoint, so resuming the
;; child by hand keeps the narrower authority its parent gave it.
(define (honor-session-authority! directory)
  (let ((path (string-append directory "/authority.json")))
    (when (and (not process-tool-ceiling) (file-exists? path))
      (let* ((root (catch #t (lambda () (call-with-input-file path (lambda (port) (json-read (get-string-all port))))) (lambda _ #f)))
             (names (and (json-object? root) (json-object-ref root "tool_ceiling" #f))))
        (when (json-array? names)
          (set! process-tool-ceiling
                (filter (lambda (name) (member name supported-tool-names)) (json-array-items names))))))))
(define subagent-depth
  (let ((raw (getenv "SHIFT_SUBAGENT_DEPTH")))
    (or (and raw (string->number raw)) 0)))
(define max-subagent-depth 3)

(define (cancelled? key)
  (eq? key 'turn-cancelled))

;; SIGTERM cancels the same way, so a bounded unattended run (timeout N
;; shift-agent --print ...) still ends its turn and writes its receipt.
(define (install-cancellation-handler!)
  (for-each
   (lambda (signal reason)
     (sigaction
      signal
      (lambda _
        (when turn-thread
          (system-async-mark (lambda () (throw 'turn-cancelled reason)) turn-thread)))))
   (list SIGINT SIGTERM) '("cancelled by user" "terminated")))

;; Unattended runs: --print answers one prompt and exits, and the other flags
;; seed session settings that the REPL would otherwise take as slash commands.
(define print-mode? #f)
(define cli-mode #f)
(define cli-model #f)
(define cli-allow-runs '())
(define cli-settings '())
(define cli-receipt-path #f)
(define cli-judge-replay #f)
(define cli-compaction-replay #f)
(define process-arguments '())
(define upgrade-requested? #f)
;; The install identity: a git label for a checkout, the Cellar version for a
;; brew install, otherwise unknown. Recorded on every span as runtime.version.
(define runtime-version-label "unknown")
(define (install-version root)
  (catch #t
    (lambda ()
      (cond
       ((not root) "unknown")
       ((and (file-exists? (string-append root "/.git")) (builtin-enabled? 'coding))
        (let* ((run (builtin-ref 'coding 'run-argv))
               (head (run (list "git" "-C" root "rev-parse" "--short=8" "HEAD")))
               (dirty (run (list "git" "-C" root "status" "--porcelain"))))
          (if (eqv? 0 (car head))
              (string-append (string-trim-both (cdr head))
                             (if (and (eqv? 0 (car dirty)) (not (string-null? (string-trim-both (cdr dirty))))) " +dirty" ""))
              "unknown")))
       ((string-contains root "/Cellar/shift/")
        (let* ((after (substring root (+ (string-contains root "/Cellar/shift/") 14)))
               (slash (string-index after #\/)))
          (if slash (substring after 0 slash) after)))
       (else "unknown")))
    (lambda _ "unknown")))
;; The same launch again, resuming this session: the arguments this process
;; received minus any session selector or prompt.
(define (upgrade-arguments arguments session-name)
  (let loop ((rest arguments) (out '()))
    (cond
     ((null? rest) (append (reverse out) (list "--resume" session-name)))
     ((member (car rest) '("--session" "--new-session" "--resume" "--print" "-p"))
      (loop (if (pair? (cdr rest)) (cddr rest) '()) out))
     ((and (pair? (cdr rest)) (member (car rest) '("--agent" "--state-dir" "--mode" "--model" "--allow-run" "--set" "--receipt" "--mcp-port")))
      (loop (cddr rest) (cons (cadr rest) (cons (car rest) out))))
     ((string-prefix? "-" (car rest)) (loop (cdr rest) (cons (car rest) out)))
     (else (loop (cdr rest) out)))))
(define turn-tokens 0)
;; Per-turn facts the receipt reports: provider usage, model rounds, and tool
;; calls by name. Reset when a turn starts.
(define turn-prompt-tokens 0)
(define turn-cached-tokens 0)
(define turn-uncached-tokens 0)
(define turn-completion-tokens 0)
(define turn-rounds 0)
(define turn-tool-calls '())
;; (tool arguments-json ok? output) per call this turn, for field notes and reflection.
(define turn-tool-events '())
(define turn-nudged? #f)
(define last-receipt #f)

(define (reset-turn-usage!)
  (set! turn-skills '())
  (set! turn-mcp-tools '())
  (set! turn-judged 0) (set! turn-blocked 0) (set! turn-judge-ms 0) (set! turn-judge-asked 0) (set! judge-consecutive-blocks 0) (set! judge-paused? #f)
  (set! turn-tokens 0)
  (set! turn-prompt-tokens 0)
  (set! turn-cached-tokens 0)
  (set! turn-uncached-tokens 0)
  (set! turn-completion-tokens 0)
  (set! turn-rounds 0)
  (set! turn-nudged? #f)
  (set! turn-tool-calls '())
  (set! turn-tool-events '()))

(define (count-turn-tool-call! name)
  (let ((current (or (assoc-ref turn-tool-calls name) 0)))
    (set! turn-tool-calls
          (append (filter (lambda (entry) (not (string=? (car entry) name))) turn-tool-calls)
                  (list (cons name (+ current 1)))))))

(define (usage)
  (display
   (string-append
    "Usage: shift-agent [--agent PATH] [--state-dir PATH] [--watch|--no-watch]\n"
    "                  [--session NAME|--new-session NAME|--resume NAME] [PROMPT]\n"
    "                  [--print TASK|-p TASK] [--mode MODE] [--model PROVIDER/MODEL]\n"
    "                  [--allow-run \"ARGV PREFIX\"]... [--set KEY=JSON]... [--receipt FILE]\n"
    "       shift-agent --list-sessions [--state-dir PATH]\n"
    "       shift-agent --check-panes [FILE]  lint a pane pack (default .shift/panes.scm)\n"
    "       shift-agent --check-mcp [FILE]    lint an MCP pack (default .shift/mcp.scm)\n"
    "       shift-agent --check-plugin [DIR]  lint a plugin manifest (default .shift-plugin)\n"
    "       shift-agent plugin add PATH|URL | update NAME | list\n"
    "       shift-agent session-fork PARENT CHILD\n"
    "\nInteractive terminals open the curses interface.\n"
    "Use --print/-p for one answer, or pipe/redirect input for scripted commands.\n")))

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
     ((and (pair? (cdr rest)) (member (car rest) '("--print" "-p")))
      (when initial-prompt
        (format (current-error-port) "Only one prompt may be provided.\n")
        (exit 2))
      (set! print-mode? #t)
      (loop (cddr rest) agent state-dir #f session-name session-mode list?
            (cadr rest) fork-parent fork-child))
     ((and (pair? (cdr rest)) (string=? (car rest) "--mode"))
      (set! cli-mode (cadr rest))
      (loop (cddr rest) agent state-dir watch? session-name session-mode list?
            initial-prompt fork-parent fork-child))
     ((and (pair? (cdr rest)) (string=? (car rest) "--model"))
      (set! cli-model (cadr rest))
      (loop (cddr rest) agent state-dir watch? session-name session-mode list?
            initial-prompt fork-parent fork-child))
     ((and (pair? (cdr rest)) (string=? (car rest) "--allow-run"))
      (let ((prefix (string-tokenize (cadr rest))))
        (when (null? prefix)
          (format (current-error-port) "--allow-run needs an argv prefix.\n")
          (exit 2))
        (set! cli-allow-runs (append cli-allow-runs (list prefix))))
      (loop (cddr rest) agent state-dir watch? session-name session-mode list?
            initial-prompt fork-parent fork-child))
     ((and (pair? (cdr rest)) (string=? (car rest) "--judge-replay"))
      ;; Replay judge cases through the configured judge model; JSON lines out.
      (set! cli-judge-replay (cadr rest)) (set! print-mode? #t)
      (loop (cddr rest) agent state-dir #f session-name session-mode list?
            initial-prompt fork-parent fork-child))
     ((and (pair? (cdr rest)) (string=? (car rest) "--summarize-replay"))
      ;; Summarize a stored compaction prefix again with the configured model.
      (set! cli-compaction-replay (cadr rest)) (set! print-mode? #t)
      (loop (cddr rest) agent state-dir #f session-name session-mode list?
            initial-prompt fork-parent fork-child))
     ((and (pair? (cdr rest)) (string=? (car rest) "--receipt"))
      (set! cli-receipt-path (cadr rest))
      (loop (cddr rest) agent state-dir watch? session-name session-mode list?
            initial-prompt fork-parent fork-child))
     ((and (pair? (cdr rest)) (string=? (car rest) "--set"))
      (let ((equals (string-index (cadr rest) #\=)))
        (unless (and equals (> equals 0))
          (format (current-error-port) "--set needs KEY=JSON.\n")
          (exit 2))
        (set! cli-settings
              (append cli-settings
                      (list (cons (string->symbol (substring (cadr rest) 0 equals))
                                  (substring (cadr rest) (+ equals 1)))))))
      (loop (cddr rest) agent state-dir watch? session-name session-mode list?
            initial-prompt fork-parent fork-child))
     ((string=? (car rest) "--check-plugin")
      (let* ((path (if (and (pair? (cdr rest)) (not (string-prefix? "-" (cadr rest)))) (cadr rest) ".shift-plugin"))
             (outcome (catch #t (lambda () (check-plugin-dir path)) (lambda (key . args) (error-text key args)))))
        (cond ((string? outcome) (format (current-error-port) "~a: ~a~%" path outcome) (exit 2))
              (else (format #t "plugin ~a ~a: ok~%" (plugin-field outcome 'name) (plugin-field outcome 'version)) (exit 0)))))
     ((string=? (car rest) "--check-mcp")
      (let* ((path (if (and (pair? (cdr rest)) (not (string-prefix? "-" (cadr rest)))) (cadr rest) ".shift/mcp.scm"))
             (outcome (catch #t (lambda () (check-mcp-file path)) (lambda (key . args) (error-text key args)))))
        (cond ((string? outcome) (format (current-error-port) "~a: ~a~%" path outcome) (exit 2))
              (else (for-each (lambda (s) (format #t "server ~a: ~a ~a~%" (car s) (cadr s) (caddr s))) outcome)
                    (format #t "~a: ok~%" path) (exit 0)))))
     ((string=? (car rest) "--check-panes")
      (let* ((path (if (and (pair? (cdr rest)) (not (string-prefix? "-" (cadr rest)))) (cadr rest) ".shift/panes.scm"))
             (outcome (catch #t (lambda () (check-panes-file path)) (lambda (key . args) (error-text key args)))))
        (cond ((string? outcome)
               (format (current-error-port) "~a: ~a~%" path outcome)
               (exit 2))
              (else
               (for-each (lambda (pane) (format #t "pane ~a: ~a rows~%" (car pane) (cdr pane))) outcome)
               (format #t "~a: ok~%" path)
               (exit 0)))))
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
    "  /run [list|allow ARGV...|deny ARGV...]  commands run without asking\n"
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
    "  /skills           list skills (SKILL.md folders) and which are loaded\n"
    "  /skill NAME       send a skill's instructions with the next prompt\n"
    "  /jobs             list background jobs and subagents; /jobs cancel ID stops one\n"
    "  /upgrade          checkpoint and hand this session to the current install in place\n"
    "  /recall QUERY     search every session's traces in this project, subagents included\n"
    "  /plugins          installed plugins; /plugin enable|disable NAME [project|user] toggles one\n"
    "  /allow-run [\"ARGV PREFIX\" [project|user]]  list or persist run prefixes that never ask\n"
    "  /learn NAME [notes]  ask the model to write this conversation's procedure as a project skill\n"
    "  /workflow [NAME]  list workflows (.shift/workflows/NAME/workflow.scm) or show one's steps and runs\n"
    "  /workflow run NAME  run its steps as turns of this session; checks decide, the record lands in runs/\n"
    "  /workflow improve NAME  propose one change, run baseline and candidate in two subagents, keep the winner\n"
    "  /judge [off|shadow|on|report]  the autopilot judge: setting, model, counts, or shadow agreement\n"
    "  /sandbox [NAME|off]  run commands in an agentkernel sandbox; run-host prefixes stay on the host\n"
    "  /mcp [connect|disconnect|tools NAME]  MCP servers from .shift/mcp.scm and the user config\n"
    "  /allow-mcp SERVER__TOOL [project|user]  let an MCP tool run without asking\n"
    "  /traces [QUERY]   list recent spans or search all session traces\n"
    "  /trace SPAN_ID    inspect one full span returned by trace search\n"
    "  /compact          summarize older history and retain recent turns\n"
    "  /recover          inspect an interrupted tool record\n"
    "  /recover retry    explicitly retry the recorded tool call\n"
    "  /recover restore  put interrupted file mutations back to their pre-images\n"
    "  /recover discard  discard the recorded tool call\n"
    "  /undo             revert the last turn's file changes if they still match\n"
    "  /receipt          show the last turn's receipt: files, runs, tokens, trace, resume\n"
    "  /tools            show the enabled tools\n"
    "  /work [on|off]    show or toggle the work display: tool echo and the receipt\n"
    "  /session          show the durable session identity and checkpoint\n"
    "  /reset            clear conversation state\n"
    "  /help             show this help\n"
    "  /ui               inspect live UI; /ui undo or /ui reload\n"
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
                (paths (sort (cons (string-append root "/bin/shift-agent") modules)
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

;; MCP: tool_search enables matching server tools for the rest of the turn;
;; calls go to the server under the same policy as any other tool.
(define turn-mcp-tools '())
(define (emit-servers!) (when (ui-connected?) (ui-emit! "servers" (mcp-servers-json))))
(define (typed-rerank generation)
  ;; The word ranking's candidates, kept and ordered by Jev; any failure keeps the word order.
  (let ((endpoint (typed-endpoint generation)))
    (and endpoint
         (lambda (query candidates)
           (catch #t
             (lambda () (typed-rank-tools (car endpoint) (cdr endpoint) query candidates))
             (lambda _ (map car candidates)))))))
(define (execute-tool-search generation arguments)
  (let ((query (json-object-ref arguments "query" #f)))
    (unless (string? query) (error "query must be a string"))
    (let ((matches (mcp-search query #:rerank (typed-rerank generation))))
      (emit-servers!)
      (for-each (lambda (m) (unless (member (car m) turn-mcp-tools) (set! turn-mcp-tools (append turn-mcp-tools (list (car m)))))) matches)
      (make-tool-result #t
        (if (null? matches)
            (string-append "No MCP tools match. Servers: "
                           (string-join (map (lambda (o) (string-append (json-object-ref o "name") " (" (json-object-ref o "state")
                                                                        (let ((n (json-object-ref o "tools" #f))) (if (integer? n) (format #f ", ~a tools" n) ""))
                                                                        (let ((r (json-object-ref o "reason" #f))) (if (string? r) (string-append ": " r) "")) ")"))
                                             (json-array-items (mcp-servers-json))) ", ")
                           ". Search with a few words, or a server name to see its tools.")
            (string-append "Enabled for this turn: " (string-join (map car matches) ", ") "\n"
                           (string-join (map (lambda (m) (json-write (cadr m))) matches) "\n")))))))
(define (execute-mcp-call name arguments)
  (call-with-values (lambda () (mcp-call! name arguments))
    (lambda (ok? text) (make-tool-result ok? text))))
(define (show-servers)
  (let ((items (json-array-items (mcp-servers-json))))
    (if (null? items)
        (display "No MCP servers. Declare them in .shift/mcp.scm or ~/.config/shift/mcp.scm.\n")
        (for-each (lambda (o)
                    (format #t "~a  ~a  ~a  ~a tools~a~%" (json-object-ref o "name") (json-object-ref o "state") (json-object-ref o "transport")
                            (json-object-ref o "tools")
                            (let ((r (json-object-ref o "reason" #f))) (if (string? r) (string-append "  " r) ""))))
                  items))))
(define (mcp-command! text)
  (let ((parts (string-tokenize text)))
    (cond
     ((null? parts) (show-servers) "")
     ((and (= (length parts) 2) (string=? (car parts) "connect"))
      (mcp-connect! (cadr parts)) (emit-servers!)
      (format #f "~a connected: ~a tools" (cadr parts) (length (mcp-server-tools (cadr parts)))))
     ((and (= (length parts) 2) (string=? (car parts) "disconnect"))
      (mcp-disconnect! (cadr parts)) (emit-servers!) (format #f "~a disconnected" (cadr parts)))
     ((and (= (length parts) 2) (string=? (car parts) "tools"))
      (let ((tools (mcp-server-tools (cadr parts))))
        (if (null? tools) (format #f "~a has no tools listed; /mcp connect ~a first" (cadr parts) (cadr parts))
            (string-join (map (lambda (t) (string-append (car t) "  " (json-object-ref (json-object-ref (cadr t) "function") "description" ""))) tools) "\n"))))
     (else (error "use /mcp, /mcp connect NAME, /mcp disconnect NAME, or /mcp tools NAME")))))
(define (allow-mcp-command! text)
  (let* ((parts (string-tokenize (string-trim-both text)))
         (scope (and (>= (length parts) 2) (member (car (last-pair parts)) '("session" "project" "user")) (string->symbol (car (last-pair parts)))))
         (name (and (pair? parts) (car parts))))
    (unless (and name (mcp-tool-name? name)) (error "use /allow-mcp SERVER__TOOL [session|project|user]"))
    (allow-mcp! name (or scope 'session))
    (format #f "Allowed ~a: ~a" (or scope 'session) name)))
;; --- plugins ----------------------------------------------------------------
;; Enabled plugins contribute MCP servers, skills, panes, themes, allowlist
;; proposals, secret sources and live-image artifacts. apply-plugins! makes the
;; set of enabled plugins the truth again; artifacts of plugins that went off
;; are removed like /extension-disable would.
(define applied-artifacts '())   ; ((plugin-name . (expression ...)) ...)
(define (emit-plugins!) (when (ui-connected?) (ui-emit! "plugins" (plugins-json plugin-enabled?))))
(define (enabled-plugins)
  (filter (lambda (p) (and (plugin-available? p) (plugin-enabled? (plugin-field p 'name)))) (plugin-index)))
(define (plugin-pane-objects plugin)
  (let ((file (plugin-field plugin 'panes)))
    (if file
        (catch #t
          (lambda () (json-array-items (panes-pack->json (call-with-input-file file get-string-all))))
          (lambda (key . args)
            (format (current-error-port) "plugin ~a: panes skipped: ~a~%" (plugin-field plugin 'name) (error-text key args)) '()))
        '())))
(define (apply-plugins! runtime)
  (let* ((enabled (enabled-plugins)) (names (map (lambda (p) (plugin-field p 'name)) enabled)))
    ;; servers, secrets
    (for-each (lambda (p) (mcp-unregister! (string-append "plugin:" (plugin-field p 'name)))) (plugin-index))
    (for-each (lambda (p) (catch #t (lambda () (mcp-register! (plugin-field p 'mcp) (string-append "plugin:" (plugin-field p 'name))))
                            (lambda (key . args) (format (current-error-port) "plugin ~a: mcp skipped: ~a~%" (plugin-field p 'name) (error-text key args)))))
              enabled)
    (secret-sources! (append-map (lambda (p) (plugin-field p 'secrets)) enabled))
    ;; skills, panes, themes
    (skills-init! (or (getenv "SHIFT_PROJECT_ROOT") (getcwd))
                  (append (setting-ref #f 'skill-dirs) (filter-map (lambda (p) (plugin-field p 'skills)) enabled)))
    (workflows-init! (getcwd)
                     (cons (cons "user" (user-workflows-directory))
                           (filter-map (lambda (p) (let ((d (plugin-field p 'workflows)))
                                                     (and d (cons (string-append "plugin:" (plugin-field p 'name)) d))))
                                       enabled)))
    (extra-panes (append-map plugin-pane-objects enabled))
    (extra-theme-dirs (delete-duplicates (append-map (lambda (p) (map dirname (plugin-field p 'themes))) enabled)))
    (catch #t (lambda () (ui-action! (json-object (cons "action" "reload")))) (lambda _ #f))
    ;; allowlists
    (allow-plugin-set! 'run-allow (append-map (lambda (p) (plugin-field p 'allow-run)) enabled))
    (allow-plugin-set! 'mcp-allow (append-map (lambda (p) (plugin-field p 'allow-mcp)) enabled))
    ;; live-image artifacts
    (when runtime
      (for-each (lambda (entry)
                  (unless (member (car entry) names)
                    (for-each (lambda (expression)
                                (catch #t (lambda () (runtime-remove-patch! runtime expression 'plugin-disable `((plugin . ,(car entry)))))
                                  (lambda _ #f)))
                              (cdr entry))))
                applied-artifacts)
      (set! applied-artifacts (filter (lambda (e) (member (car e) names)) applied-artifacts))
      (for-each (lambda (p)
                  (let ((expressions (map (lambda (file) (call-with-input-file file get-string-all)) (plugin-field p 'agent))))
                    (for-each (lambda (expression)
                                (unless (member expression (generation-patches (runtime-current runtime)))
                                  (catch #t
                                    (lambda () (runtime-apply-patch! runtime expression 'plugin-load `((plugin . ,(plugin-field p 'name)))))
                                    (lambda (key . args)
                                      (format (current-error-port) "plugin ~a: agent artifact rejected: ~a~%" (plugin-field p 'name) (error-text key args))))))
                              expressions)
                    (when (pair? expressions)
                      (set! applied-artifacts (acons (plugin-field p 'name) expressions
                                                     (filter (lambda (e) (not (string=? (car e) (plugin-field p 'name)))) applied-artifacts))))))
                enabled))
    (emit-plugins!) (emit-servers!) (emit-skills!)
    names))
(define (show-plugins)
  (let ((items (json-array-items (plugins-json plugin-enabled?))))
    (if (null? items)
        (display "No plugins. Install one with `shift-agent plugin add PATH|URL` or drop a folder in .shift/plugins.\n")
        (for-each (lambda (o)
                    (format #t "~a ~a ~a  ~a  ~a~a~%"
                            (cond ((not (json-object-ref o "valid")) "invalid ")
                                  ((pair? (json-array-items (json-object-ref o "missing"))) "missing ")
                                  ((json-object-ref o "enabled") "on      ") (else "off     "))
                            (json-object-ref o "name") (json-object-ref o "version") (json-object-ref o "source")
                            (string-join (json-array-items (json-object-ref o "contributes")) ", ")
                            (let ((r (json-object-ref o "error" #f)) (m (json-array-items (json-object-ref o "missing"))))
                              (cond ((string? r) (string-append "  " r))
                                    ((pair? m) (string-append "  needs " (string-join m ", ") " on PATH"))
                                    (else "")))))
                  items))))
(define (plugin-command! runtime text)
  (let* ((parts (string-tokenize text))
         (verb (and (pair? parts) (car parts)))
         (name (and (>= (length parts) 2) (cadr parts)))
         (scope (if (>= (length parts) 3) (string->symbol (caddr parts)) 'project)))
    (cond
     ((member verb '("enable" "disable"))
      (unless (and name (plugin-find name)) (error "no plugin named" name))
      (set-plugin-state! name (string=? verb "enable") scope)
      (apply-plugins! runtime)
      (let ((p (plugin-find name)))
        (format #f "~a ~a (~a scope)~a" name (if (string=? verb "enable") "on" "off") scope
                (if (and (string=? verb "enable") (pair? (plugin-field p 'allow-run)))
                    (string-append "; runs without asking: " (string-join (map (lambda (x) (string-join x " ")) (plugin-field p 'allow-run)) ", "))
                    ""))))
     ((equal? verb "reload") (format #f "plugins applied: ~a" (string-join (apply-plugins! runtime) ", ")))
     (else (error "use /plugins, /plugin enable|disable NAME [project|user|session], or /plugin reload")))))
;; shift-agent plugin add PATH|URL, update NAME, list
(define (user-plugins-directory)
  (string-append (or (getenv "XDG_CONFIG_HOME") (string-append (getenv "HOME") "/.config")) "/shift/plugins"))
(define (plugin-cli! args)
  (define (run . argv) (unless (eqv? 0 (status:exit-val (apply system* argv))) (error "command failed" (string-join argv " "))))
  (cond
   ((and (>= (length args) 2) (string=? (car args) "add"))
    (let* ((source (cadr args)) (dir (user-plugins-directory))
           (staging (string-append dir "/.incoming-" (number->string (getpid)))))
      (run "mkdir" "-p" dir)
      (if (or (string-prefix? "http://" source) (string-prefix? "https://" source) (string-prefix? "git@" source))
          (run "git" "clone" "-q" "--depth" "1" source staging)
          (begin (unless (file-exists? (string-append source "/plugin.scm")) (error "no plugin.scm in" source))
                 (run "cp" "-R" source staging)))
      (let* ((plugin (catch #t (lambda () (check-plugin-dir staging)) (lambda (key . a) (run "rm" "-rf" staging) (apply throw key a))))
             (target (string-append dir "/" (plugin-field plugin 'name))))
        (when (file-exists? target) (run "rm" "-rf" target))
        (run "mv" staging target)
        (format #t "installed ~a ~a into ~a~%" (plugin-field plugin 'name) (plugin-field plugin 'version) target))))
   ((and (= (length args) 2) (string=? (car args) "update"))
    (let ((target (string-append (user-plugins-directory) "/" (cadr args))))
      (unless (file-exists? (string-append target "/.git")) (error "not a git checkout; add it again from its source" target))
      (run "git" "-C" target "pull" "-q" "--ff-only")
      (format #t "updated ~a~%" (cadr args))))
   ((equal? args '("list"))
    (plugins-init! (or (getenv "SHIFT_INSTALL_ROOT") (getcwd)) (getcwd)
                   (string-append (or (getenv "XDG_CONFIG_HOME") (string-append (getenv "HOME") "/.config")) "/shift") '())
    (show-plugins))
   (else (error "use shift-agent plugin add PATH|URL, plugin update NAME, or plugin list"))))
;; Skills: the model loads one through the `skill` tool; the user queues one
;; with /skill NAME and it rides along with the next prompt. Both are recorded
;; on the receipt. Policy never changes because a skill was loaded.
(define turn-skills '())
(define queued-skills '())
(define (emit-skills!) (when (ui-connected?) (ui-emit! "skills" (skills-json))))
(define (execute-skill arguments)
  (let ((name (json-object-ref arguments "name" #f)) (path (json-object-ref arguments "path" #f)))
    (unless (string? name) (error "name must be a string"))
    (let ((body (if (string? path) (skill-file name path) (skill-load! name))))
      (unless (member name turn-skills) (set! turn-skills (cons name turn-skills)))
      (emit-skills!)
      (make-tool-result #t body))))
(define (queue-skill! name)
  (let ((body (skill-load! name #:by-model #f)))
    (set! queued-skills
      (append (filter (lambda (entry) (not (string=? (car entry) name))) queued-skills) (list (cons name body))))
    (emit-skills!)
    (format #f "Skill ~a will be sent with your next prompt" name)))
(define (with-queued-skills text)
  (if (null? queued-skills)
      text
      (let ((queued queued-skills))
        (set! queued-skills '())
        (for-each (lambda (entry) (unless (member (car entry) turn-skills) (set! turn-skills (cons (car entry) turn-skills)))) queued)
        (string-append
         (string-join (map (lambda (entry) (string-append "<skill name=\"" (car entry) "\">\n" (cdr entry) "\n</skill>")) queued) "\n\n")
         "\n\n" text))))
;; /allow-run PREFIX [session|project|user]: persist an argv prefix so runs
;; that start with it never ask. Quotes around the prefix are accepted, since
;; the pane hint prints them; project entries live in the committable
;; .shift/settings.json, user entries in ~/.config/shift/settings.json.
(define (unquote-prefix text)
  (let ((t (string-trim-both text)))
    (if (and (>= (string-length t) 2) (memv (string-ref t 0) '(#\" #\'))
             (char=? (string-ref t 0) (string-ref t (- (string-length t) 1))))
        (substring t 1 (- (string-length t) 1))
        t)))
(define (allow-run-command! text)
  (let* ((parts (string-tokenize (string-trim-both text)))
         (scope (and (pair? parts) (member (car (last-pair parts)) '("session" "project" "user"))
                     (string->symbol (car (last-pair parts)))))
         (prefix-text (if scope (string-trim-both (substring text 0 (- (string-length text) (string-length (symbol->string scope))))) text))
         (prefix (string-tokenize (unquote-prefix prefix-text))))
    (when (null? prefix) (error "use /allow-run \"ARGV PREFIX\" [session|project|user]"))
    (allow-run! prefix (or scope 'session))
    (format #f "Allowed ~a: ~a~a" (or scope 'session) (string-join prefix " ")
            (if (eq? (or scope 'session) 'session) " (this session; add project or user to persist)" ""))))
(define (show-allow-runs)
  (let ((entries (run-allow-entries)))
    (if (null? entries)
        (display "No allowlisted run prefixes. /allow-run \"make test\" [project|user]\n")
        (for-each (lambda (entry) (format #t "~a  ~a~%" (cdr entry) (string-join (car entry) " "))) entries))))
;; /learn NAME [notes]: ask the model to write what it just did as a project
;; skill; the write goes through the normal mutation path and approval.
(define (learn-skill! runtime tracer session text)
  (let* ((parts (string-tokenize text)) (name (and (pair? parts) (car parts)))
         (notes (if (and (pair? parts) (pair? (cdr parts))) (string-join (cdr parts) " ") "")))
    (unless (and name (<= 1 (string-length name) 64)
                 (string-every (lambda (c) (or (char-lower-case? c) (char-numeric? c) (char=? c #\-))) name))
      (error "use /learn NAME [notes]; NAME is 1-64 lowercase letters, digits or hyphens"))
    (list 'prompt (string-append
     "Turn the procedure from this conversation into a reusable skill named \"" name "\". "
     "Write the file .shift/skills/" name "/SKILL.md with YAML frontmatter containing exactly `name: " name "` "
     "and a one-line `description` that says what the skill does and when to use it, then Markdown instructions: "
     "the steps, the commands that worked, the pitfalls, and what to verify. Keep it under 200 lines; put long "
     "reference material in files beside SKILL.md and link to them. Do not include secrets or machine-specific paths."
     (if (string-null? notes) "" (string-append " Notes from the user: " notes))))))
(define (show-jobs)
  (let ((all (if (builtin-enabled? 'coding) ((builtin-ref 'coding 'job-list)) '())))
    (if (null? all)
        (display "No background jobs in this session.\n")
        (for-each (lambda (job) (display (job-line job)) (newline)) all))))
(define (job-line job)
  (let ((event ((builtin-ref 'coding 'job-event) job "running")))
    (format #f "~a  ~a  ~a  ~as  ~a" (json-object-ref event "id") (json-object-ref event "status")
            (let ((agent (json-object-ref event "agent" #f)))
              (if (string? agent) (string-append "subagent " agent)
                  (string-join (json-array-items (json-object-ref event "argv")) " ")))
            (/ (round (/ (json-object-ref event "elapsed_ms") 100.0)) 10.0) (json-object-ref event "log"))))
(define (show-skills)
  (let ((items (skill-index)))
    (if (null? items)
        (display "No skills. Add SKILL.md folders under .shift/skills, .agents/skills or ~/.config/shift/skills.\n")
        (for-each
         (lambda (r)
           (format #t "~a ~a  ~a  ~a~%"
                   (cond ((not (assq-ref r 'valid)) "invalid") ((skill-loaded? (assq-ref r 'name)) "loaded ") (else "       "))
                   (assq-ref r 'name) (assq-ref r 'source)
                   (or (assq-ref r 'description) (assq-ref r 'error))))
         items))))
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

(define spawn-session #f)
(define spawn-state-directory #f)
(define spawn-agent-path #f)
(define child-run-spans '()) ; job id -> open subagent.run span

;; Every session's trace file in the project, subagent folders included.
(define (recall-sources tracer only)
  (let* ((names (if spawn-state-directory (list-session-names spawn-state-directory) '()))
         (chosen (if only
                     (filter (lambda (name) (or (string=? name only) (string-prefix? (string-append only "/") name))) names)
                     names)))
    (if (and (null? names) (not only))
        (list (cons "(no session)" (tracer-path tracer)))
        (map (lambda (name) (cons name (string-append spawn-state-directory "/sessions/" name "/traces.jsonl"))) chosen))))
(define (recall-line hit)
  (define (field key) (let ((value (json-object-ref hit key "-"))) (if (eq? value json-null) "-" value)))
  (format #f "~a  gen=~a turn=~a  ~a ~a ~a  span=~a~a"
          (json-object-ref hit "session" "") (field "generation") (field "turn")
          (json-object-ref hit "kind" "") (json-object-ref hit "name" "") (json-object-ref hit "status" "")
          (json-object-ref hit "span_id" "")
          ;; One hit per line: the preview is flattened and clipped.
          (let ((preview (json-object-ref hit "preview" "")))
            (if (and (string? preview) (not (string-null? preview)))
                (string-append "  " (clip (string-map (lambda (c) (if (char=? c #\newline) #\space c)) preview) 120))
                ""))))
(define (execute-recall tracer arguments)
  (catch #t
    (lambda ()
      (let ((query (json-object-ref arguments "query" #f))
            (only (json-object-ref arguments "session" #f))
            (limit (json-object-ref arguments "limit" 8))
            (errors-only? (json-object-ref arguments "errors_only" #f)))
        (unless (and (string? query) (not (string-null? (string-trim-both query))) (<= (string-length query) 256))
          (error "recall needs a query of at most 256 characters"))
        (unless (and (integer? limit) (<= 1 limit 30)) (error "limit must be an integer from 1 through 30"))
        (unless (or (not only) (safe-session-path? only)) (error "session must be a session name" only))
        (call-with-values
            (lambda ()
              (trace-recall (recall-sources tracer only) #:query query #:limit limit
                            #:name (json-object-ref arguments "name" #f) #:kind (json-object-ref arguments "kind" #f)
                            #:status (json-object-ref arguments "status" #f) #:errors-only? (and errors-only? #t)))
          (lambda (hits matched scanned malformed)
            (make-tool-result #t
              (string-append
               (format #f "query ~s · ~a matches across ~a spans in ~a sessions~a~%" query matched scanned
                       (length (recall-sources tracer only))
                       (if (> malformed 0) (format #f " · ~a malformed lines ignored" malformed) ""))
               (if (null? hits) "No matching spans." (string-join (map recall-line hits) "\n"))))))))
    (lambda (key . arguments)
      (make-tool-result #f (error-text key arguments)))))
(define (show-recall tracer query)
  (let ((result (execute-recall tracer (json-object (cons "query" query) (cons "limit" 6)))))
    (display (tool-result-output result)) (newline)))

(define (child-environment traceparent ceiling)
  (append
   (list (string-append "SHIFT_TOOL_CEILING=" (string-join ceiling ","))
         (string-append "SHIFT_SUBAGENT_DEPTH=" (number->string (+ subagent-depth 1))))
   (if traceparent (list (string-append "TRACEPARENT=" traceparent)) '())
   (filter (lambda (entry)
             (not (any (lambda (prefix) (string-prefix? prefix entry))
                       '("SHIFT_UI_EVENT_FD=" "SHIFT_UI_COMMAND_FD=" "SHIFT_CONTROL_FD=" "TRACEPARENT="
                         "SHIFT_TOOL_CEILING=" "SHIFT_SUBAGENT_DEPTH="))))
           (environ))))
(define (next-agent-name directory)
  (let ((agents (string-append directory "/agents")))
    (let loop ((n (+ 1 (if (file-exists? agents) (length (scandir agents (lambda (name) (not (member name '("." "..")))))) 0))))
      (if (file-exists? (string-append agents "/agent-" (number->string n))) (loop (+ n 1)) (format #f "agent-~a" n)))))
;; The child is a session folder under this one, forked from the live image
;; and run as a background job whose stdout is its answer.
;; --- workflows ----------------------------------------------------------------------
;; Durable procedures under .shift/workflows; the module parses and checks,
;; this runs the steps as turns of the session and keeps the sidebar current.
(define (user-workflows-directory)
  (string-append (or (getenv "XDG_CONFIG_HOME") (string-append (or (getenv "HOME") "") "/.config")) "/shift/workflows"))
(define (emit-workflows!)
  (let ((items (workflows-json (getcwd))))
    (set! workflows-seen (workflows-signature))
    (ui-emit! "workflows" (json-object (cons "items" items)))
    (length (json-array-items items))))
;; The sidebar follows the folders: a workflow added, edited or removed in any
;; source shows within the watcher's half-second tick.
(define workflows-seen #f)
(define (watch-workflows!)
  (ui-on-tick! (lambda ()
                 (let ((now (workflows-signature)))
                   (unless (equal? now workflows-seen) (emit-workflows!))))))
(define (emit-workflow-run! name index total step status rounds)
  (ui-emit! "workflow-run" (json-object (cons "workflow" name) (cons "index" index) (cons "total" total)
                                        (cons "step" step) (cons "status" status) (cons "rounds" rounds))))
(define (workflow-listing-text)
  (let ((items (json-array-items (workflows-json (getcwd)))))
    (if (null? items)
        "No workflows. Write .shift/workflows/NAME/workflow.scm: ((workflow \"NAME\" 1) (description \"...\") (budget (rounds 20)) (step \"first\" \"PROMPT\" (check (run \"make\" \"test\"))))"
        (string-join
         (map (lambda (w)
                (let ((error (json-object-ref w "error" #f)))
                  (if error
                      (format #f "~a  (unreadable: ~a)" (json-object-ref w "name") error)
                      (let ((last (json-object-ref w "last" #f)))
                        (format #f "~a v~a  ~a step~a · ~a run~a~a~a"
                                (json-object-ref w "name") (json-object-ref w "version")
                                (length (json-array-items (json-object-ref w "steps"))) (if (= 1 (length (json-array-items (json-object-ref w "steps")))) "" "s")
                                (json-object-ref w "runs") (if (= 1 (json-object-ref w "runs")) "" "s")
                                (if (json-object? last) (format #f " · last ~a in ~a rounds" (json-object-ref last "status") (json-object-ref last "rounds")) "")
                                (let ((d (json-object-ref w "description" ""))) (if (string-null? d) "" (string-append "\n    " d))))))))
              items)
         "\n"))))
(define (workflow-show-text name)
  (let* ((project (getcwd)) (w (workflow-read project name)) (runs (workflow-runs project name)))
    (string-append
     (format #f "~a v~a · budget ~a rounds~a~%" name (workflow-version w) (workflow-budget w)
             (let ((d (workflow-description w))) (if (string-null? d) "" (string-append "\n  " d))))
     (string-join
      (map (lambda (step index)
             (string-append
              (format #f "  ~a. ~a: ~a" index (step-name step) (clip (step-prompt step) 100))
              (if (null? (step-checks step)) ""
                  (string-append "\n" (string-join (map (lambda (c) (format #f "       check ~a ~a" (check-kind c) (check-text c))) (step-checks step)) "\n")))))
           (workflow-steps w) (iota (length (workflow-steps w)) 1))
      "\n")
     (if (null? runs) "\n  no runs yet"
         (string-append "\n  runs:\n"
                        (string-join
                         (map (lambda (run)
                                (format #f "    ~a ~a · ~a rounds · ~a"
                                        (json-object-ref run "started" "") (json-object-ref run "status" "")
                                        (json-object-ref run "rounds" 0)
                                        (string-join (map (lambda (st) (format #f "~a:~a" (json-object-ref st "name") (json-object-ref st "status")))
                                                          (json-array-items (json-object-ref run "steps" (json-array)))) " ")))
                              (if (> (length runs) 5) (take runs 5) runs))
                         "\n"))))))
(define (last-assistant-text history)
  (let loop ((rest (reverse history)))
    (cond ((null? rest) "")
          ((and (json-object? (car rest)) (equal? (json-object-ref (car rest) "role" "") "assistant")
                (string? (json-object-ref (car rest) "content" #f)))
           (json-object-ref (car rest) "content" ""))
          (else (loop (cdr rest))))))
;; A judge check asks the judge model (Jev when judge-model names it, else the
;; session model) whether the step's answer establishes the criterion; a typed
;; judge that cannot answer falls back to the session model like the tool judge.
(define (workflow-judge runtime)
  (define (ask endpoint criterion answer task)
    ;; An endpoint names the key's environment variable; the request wants its value.
    (let ((key-env (cadddr endpoint)))
      (judge-claim! (car endpoint) (cadr endpoint) (caddr endpoint) (and key-env (getenv key-env)) criterion answer #:task task)))
  (lambda* (criterion answer #:optional (task #f))
    (let* ((generation (runtime-current runtime))
           (endpoint (judge-endpoint generation))
           (verdict (ask endpoint criterion answer task)))
      (if (and (assq-ref verdict 'failure) (eq? (car endpoint) 'typesafe))
          (begin
            (when (assq-ref verdict 'permanent) (set! judge-typed-disabled #t))
            (append (ask (session-judge-endpoint generation) criterion answer task)
                    `((fallback . ,(assq-ref verdict 'reason)))))
          verdict))))
;; run-step!: PROMPT → (turn-status answer receipt). Stops at the first step
;; whose turn or checks fail, or when the round budget is spent; the rest are
;; skipped and the record says which.
(define (run-workflow! runtime tracer name run-step!)
  (let* ((project (getcwd)) (w (workflow-read project name))
         (steps (workflow-steps w)) (total (length steps)) (budget (workflow-budget w))
         (started (strftime "%Y-%m-%dT%H:%M:%SZ" (gmtime (current-time))))
         (echo (tool-echo-port))
         (context-for
          (lambda (answer task)
            `((answer . ,answer) (task . ,task) (root . ,project)
              (run . ,(lambda (argv)
                        (unless (builtin-enabled? 'coding) (error "run checks need the coding built-in"))
                        ((builtin-ref 'coding 'run-argv) argv)))
              (notes-exists? . ,(lambda (n) (file-exists? (notes-path tracer n))))
              (judge . ,(workflow-judge runtime))))))
    (format echo "workflow ~a v~a · ~a step~a · budget ~a rounds~%" name (workflow-version w) total (if (= total 1) "" "s") budget)
    (set! workflow-run-events '())
    (let loop ((remaining steps) (index 1) (rounds 0) (records '()) (status 'resolved))
      (cond
       ((null? remaining)
        (let* ((record `((workflow . ,name) (version . ,(workflow-version w)) (session . ,(or (tracer-session-name tracer) ""))
                         (started . ,started) (status . ,status) (rounds . ,rounds) (error . #f) (steps . ,(reverse records))))
               (path (workflow-record-run! project name record))
               (failed (find (lambda (r) (memq (assq-ref r 'status) '(failed limited))) (reverse records))))
          (set! operation-status (if (eq? status 'resolved) "ok" "failed"))
          (format #t "workflow ~a: ~a~a · ~a rounds · ~a~%" name status
                  (if failed (format #f " at step ~a" (assq-ref failed 'name)) "")
                  rounds (let ((rel (string-append ".shift/workflows/" name "/runs/"))) (string-append rel (basename path))))
          (emit-workflow-run! name total total "" (symbol->string status) rounds)
          (when (ui-connected?) (emit-workflows!))
          (let ((events workflow-run-events))
            (set! workflow-run-events #f)
            (when (and (eq? status 'resolved) (setting-ref (runtime-current runtime) 'distillation) (pair? events))
              (catch #t
                (lambda ()
                  (distill! runtime (runtime-current runtime)
                            (string-append "Workflow " name ": " (workflow-description w) "\n"
                                           (string-join (map (lambda (s) (string-append "- " (step-name s) ": " (step-prompt s))) steps) "\n"))
                            events last-answer
                            (format #f "workflow ~a run, session ~a" name (or (tracer-session-name tracer) "default"))))
                (lambda (key . args) (format echo "distillation skipped: ~a~%" (caught-message key args))))))
          status))
       ((not (eq? status 'resolved))
        (loop (cdr remaining) (+ index 1) rounds
              (cons `((name . ,(step-name (car remaining))) (status . skipped) (rounds . 0) (checks . ())) records) status))
       (else
        (let ((step (car remaining)))
          (emit-workflow-run! name index total (step-name step) "running" rounds)
          (format echo "step ~a/~a ~a~%" index total (step-name step))
          (let* ((outcome (run-step! (format #f "Workflow ~a, step ~a of ~a (~a): ~a" name index total (step-name step) (step-prompt step))))
                 (turn-status (car outcome)) (answer (cadr outcome)) (receipt (caddr outcome))
                 ;; The receipt is the alist deliver-receipt! stored, not its JSON.
                 (step-rounds (or (and (pair? receipt) (assq-ref receipt 'rounds)) 0))
                 (rounds (+ rounds (if (number? step-rounds) step-rounds 0)))
                 (checks (map (lambda (c) (evaluate-check c (context-for answer (step-prompt step)))) (step-checks step)))
                 (ok? (and (eq? turn-status 'ok) (every (lambda (c) (assq-ref c 'ok)) checks)))
                 (over? (> rounds budget))
                 (step-status (cond (ok? 'ok) ((eq? turn-status 'limited) 'limited) (else 'failed))))
            (for-each (lambda (c) (format echo "      ~a ~a ~a · ~a~%" (if (assq-ref c 'ok) "✓" "✗") (assq-ref c 'kind) (assq-ref c 'text) (assq-ref c 'detail))) checks)
            (when over? (format echo "      budget of ~a rounds spent (~a)~%" budget rounds))
            (loop (cdr remaining) (+ index 1) rounds
                  (cons `((name . ,(step-name step)) (status . ,step-status) (rounds . ,step-rounds) (checks . ,checks)) records)
                  (cond ((and ok? (not over?)) 'resolved) (over? 'budget) (else 'failed))))))))))
;; --- the self-improvement loop --------------------------------------------------------
;; After every turn: harness rejections become field notes, and a hard turn
;; (a limit, a repeated call, three rejections) gets one reflection exchange
;; whose proposal is written as a disabled artifact. Never more than one
;; model call, never on an easy turn, and either half can be switched off.
(define (after-turn! runtime tracer request)
  (let* ((generation (runtime-current runtime)) (project (getcwd)) (receipt last-receipt)
         (status (and (pair? receipt) (assq-ref receipt 'status))) (error (and (pair? receipt) (assq-ref receipt 'error)))
         (provenance (format #f "session ~a, turn ~a" (or (tracer-session-name tracer) "default")
                             (or (and (pair? receipt) (assq-ref receipt 'turn)) "?"))))
    (catch #t
      (lambda ()
        (when (setting-ref generation 'field-notes)
          (let ((added (field-notes-append! project (field-note-candidates turn-tool-events) provenance)))
            (when (> added 0)
              (runtime-record! runtime 'field-notes `((added . ,added)))
              (format (tool-echo-port) "field notes: ~a new line~a in .shift/skills/field-notes~%" added (if (= added 1) "" "s")))))
        (let ((flags (turn-flags (if (string? status) status "") (and (string? error) error) turn-tool-events)))
          (cond
           ((and (setting-ref generation 'reflection) (hard-turn? flags))
            (reflect! runtime generation request flags provenance))
           ;; A workflow run distills once at its end, from every step, not per step.
           ((and (setting-ref generation 'distillation) (not workflow-run-events)
                 (clean-tool-heavy? (if (string? status) status "") turn-tool-events))
            (distill! runtime generation request turn-tool-events (last-assistant-text-of receipt) provenance)))))
      (lambda (key . args) (format (tool-echo-port) "improvement loop skipped: ~a~%" (caught-message key args))))))
(define (ask-model! generation messages output-reserve)
  (let* ((endpoint (session-judge-endpoint generation)) (key-env (cadddr endpoint))
         (completion (provider-complete (car endpoint) (cadr endpoint) (caddr endpoint) (and key-env (getenv key-env))
                                        messages '() #t #f "10m" #f (lambda _ #f) (lambda _ #f) 'default #f output-reserve)))
    (completion-content completion)))
;; The answer for a distillation comes from the receipt's turn, which the
;; caller has as the last assistant message; the receipt itself has no text.
(define last-answer "")
(define (last-assistant-text-of receipt) last-answer)
(define (distill! runtime generation request events answer provenance)
  (let* ((reply (ask-model! generation (distillation-messages request events answer) 2048))
         (proposal (distillation-parse reply))
         (line (if proposal (reflection-apply! (getcwd) proposal provenance "distillation")
                   (string-append "distillation: the model did not return a proposal (" (clip (if (string? reply) reply "") 120) ")"))))
    (runtime-record! runtime 'distillation `((calls . ,(length events)) (proposal . ,(if proposal (symbol->string (assq-ref proposal 'kind)) "unparsed")) (outcome . ,line)))
    (format (tool-echo-port) "~a~%" line)))
;; While a workflow runs, every step's tool events accumulate here; #f otherwise.
(define workflow-run-events #f)
(define (reflect! runtime generation request flags provenance)
  (let* ((reply (ask-model! generation (reflection-messages request flags turn-tool-events) 1024))
         (proposal (reflection-parse reply))
         (line (if proposal (reflection-apply! (getcwd) proposal provenance)
                   (string-append "reflection: the model did not return a proposal (" (clip (if (string? reply) reply "") 120) ")"))))
    (runtime-record! runtime 'reflection `((flags . ,(string-join flags "; ")) (proposal . ,(if proposal (symbol->string (assq-ref proposal 'kind)) "unparsed")) (outcome . ,line)))
    (format (tool-echo-port) "~a~%" line)))
;; /workflow improve NAME: one proposed change, measured. Baseline and candidate
;; run in two children pinned to this generation; the candidate stays only when
;; it resolves in no more rounds. Every outcome goes to versions/log.jsonl.
(define (improve-workflow! runtime tracer name)
  (let* ((project (getcwd)) (w (workflow-read project name)) (runs (workflow-runs project name)))
    (when (null? runs) (error "run the workflow first; improvement compares against its runs"))
    (unless (and spawn-session (builtin-enabled? 'coding)) (error "improvement runs two subagents; start shift-agent with --session"))
    (let* ((text (call-with-input-file (workflow-file project name) get-string-all))
           (generation (runtime-current runtime))
           (proposal (improve-parse (ask-model! generation (improve-messages text (if (> (length runs) 5) (take runs 5) runs)) 4096))))
      (cond
       ((not proposal) (display "improve: the model did not return a proposal\n"))
       ((equal? (assq-ref proposal 'change) "none") (display "improve: the model proposes no change\n"))
       (else
        (let* ((candidate-name (string-append name "-candidate"))
               (candidate (candidate-text (assq-ref proposal 'workflow) name candidate-name))
               (folder (string-append (workflow-root project) "/" candidate-name))
               (tag (number->string (+ 1 (length (improve-log project name))))))
          (when (file-exists? folder) (error "a candidate folder is already there; remove it first" folder))
          (mkdir folder)
          (call-with-output-file (workflow-file project candidate-name) (lambda (p) (display candidate p)))
          (catch #t
            (lambda () (workflow-read project candidate-name))
            (lambda (key . args)
              (remove-tree! folder)
              (error (string-append "the proposal does not parse: " (caught-message key args)))))
          (format #t "improve ~a: ~a~%  baseline and candidate run in two subagents; this waits for both~%" name (assq-ref proposal 'change))
          (dynamic-wind
           (lambda () #t)
           (lambda ()
          (let* ((jobs (list (spawn-workflow-run! runtime generation tracer name (string-append "improve-" tag "-baseline"))
                             (spawn-workflow-run! runtime generation tracer candidate-name (string-append "improve-" tag "-candidate"))))
                 (finished? (wait-for-jobs! jobs 3600))
                 (baseline (newest-run-for project name (string-append "improve-" tag "-baseline")))
                 (result (newest-run-for project candidate-name (string-append "improve-" tag "-candidate")))
                 (verdict (cond ((not finished?) (cons 'discard "the runs did not finish within an hour"))
                                ((not (and baseline result)) (cons 'discard "a run left no record"))
                                (else (compare-runs baseline result))))
                 (kept? (eq? (car verdict) 'keep))
                 (version (workflow-version w)))
            (when result
              (let ((dir (string-append (workflow-root project) "/" name "/versions")))
                (unless (file-exists? dir) (mkdir dir))
                (call-with-output-file (string-append dir "/" (number->string (+ version 1)) "-candidate-run.json")
                  (lambda (p) (display (json-write result) p) (newline p)))))
            ;; Both take the candidate-named text and put the workflow's own name back.
            (if kept? (promote-candidate! project name version candidate)
                (reject-candidate! project name version candidate))
            (improve-log! project name
                          (json-object (cons "at" (strftime "%Y-%m-%dT%H:%M:%SZ" (gmtime (current-time))))
                                       (cons "change" (assq-ref proposal 'change)) (cons "kept" kept?) (cons "reason" (cdr verdict))
                                       (cons "baseline" (or baseline json-null)) (cons "candidate" (or result json-null))))
            (format #t "improve ~a: ~a · ~a~%" name (if kept? (format #f "kept as v~a" (+ version 1)) "discarded") (cdr verdict))
            (when (ui-connected?) (emit-workflows!))))
           ;; The candidate folder is scaffolding; the record of it lives under versions/.
           (lambda () (remove-tree! folder)))))))))
(define (spawn-workflow-run! runtime generation tracer workflow child)
  (let ((result (execute-spawn runtime generation tracer
                               (json-object (cons "task" (string-append "/workflow run " workflow)) (cons "name" child)
                                            (cons "timeout_seconds" 3600))
                               #f)))
    (unless (tool-result-success? result) (error (tool-result-output result)))
    (let ((all ((builtin-ref 'coding 'job-list)))) (car (last-pair all)))))
(define (wait-for-jobs! jobs seconds)
  (let ((deadline (+ (get-internal-real-time) (* seconds internal-time-units-per-second))))
    (let loop ()
      (cond ((every (lambda (j) (not (eq? ((builtin-ref 'coding 'job-state) j) 'running))) jobs) #t)
            ((> (get-internal-real-time) deadline) #f)
            (else (usleep 1000000) (loop))))))
(define (newest-run-for project workflow child)
  (find (lambda (run) (string-suffix? (string-append "/agents/" child) (json-object-ref run "session" "")))
        (catch #t (lambda () (workflow-runs project workflow)) (lambda _ '()))))
;; Only ever pointed at a candidate folder under .shift/workflows.
(define (remove-tree! path)
  (unless (string-contains path "/.shift/workflows/") (error "refusing to remove" path))
  (when (file-exists? path)
    (if (eq? (stat:type (stat path)) 'directory)
        (begin (for-each (lambda (n) (remove-tree! (string-append path "/" n)))
                         (scandir path (lambda (n) (not (member n '("." ".."))))))
               (rmdir path))
        (delete-file path))))

(define (execute-workflow runtime generation tracer arguments span)
  (catch #t
    (lambda ()
      (let ((action (json-object-ref arguments "action" "list")) (name (json-object-ref arguments "name" #f)))
        (cond
         ((string=? action "list") (make-tool-result #t (workflow-listing-text)))
         ((string=? action "show")
          (unless (string? name) (error "name is required"))
          (make-tool-result #t (workflow-show-text name)))
         ((string=? action "run")
          (unless (safe-workflow-name? name) (error "name is required: lowercase letters, digits and hyphens"))
          (workflow-read (getcwd) name)
          (execute-spawn runtime generation tracer
                         (json-object (cons "task" (string-append "/workflow run " name)) (cons "name" (string-append "workflow-" name)))
                         span))
         (else (error "action must be list, show or run" action)))))
    (lambda (key . args) (make-tool-result #f (caught-message key args)))))

(define (execute-spawn runtime generation tracer arguments span)
  (catch #t
    (lambda ()
      (unless spawn-session (error "spawn needs a durable session; start shift-agent with --session"))
      (unless (builtin-enabled? 'coding) (error "spawn needs the coding built-in for jobs"))
      (when (>= subagent-depth max-subagent-depth)
        (error (format #f "subagents may nest ~a deep; this one is at depth ~a" max-subagent-depth subagent-depth)))
      (let* ((task (json-object-ref arguments "task" #f))
             (name (or (json-object-ref arguments "name" #f) (next-agent-name (session-directory spawn-session))))
             (requested (json-object-ref arguments "tools" #f))
             (history? (json-object-ref arguments "history" #f))
             (model (json-object-ref arguments "model" #f))
             (timeout (json-object-ref arguments "timeout_seconds" 600))
             (parent-tools (filter within-process-tool-ceiling? (map tool-name (generation-ref generation 'agent-tools))))
             (ceiling (if (json-array? requested)
                          (let ((names (json-array-items requested)))
                            (unless (and (pair? names) (every string? names)) (error "tools must be a non-empty list of tool names"))
                            (for-each (lambda (n) (unless (member n parent-tools) (error "a child cannot get a tool its parent lacks" n))) names)
                            (delete-duplicates names string=?))
                          parent-tools))
             (child-name (string-append (session-name spawn-session) "/agents/" name)))
        (unless (and (string? task) (not (string-null? (string-trim-both task)))) (error "task is required"))
        (unless (safe-session-name? name) (error "name must match [A-Za-z0-9][A-Za-z0-9._-]*" name))
        (unless (and (integer? timeout) (<= 30 timeout 3600)) (error "timeout_seconds must be 30 through 3600"))
        (unless (or (not model) (and (string? model) (string-index model #\/))) (error "model must be PROVIDER/MODEL" model))
        ;; A repeated spawn of the same name is the usual mistake after the
        ;; first one returned: point at the job instead of forking again.
        (let ((running (find (lambda (j) (equal? (assq-ref ((builtin-ref 'coding 'job-tags) j) 'agent) child-name))
                             ((builtin-ref 'coding 'job-list)))))
          (when running
            (error (format #f "~a is already spawned as ~a (~a); use the job tool to wait for it, or pick another name"
                           child-name ((builtin-ref 'coding 'job-identity) running)
                           (if (eq? ((builtin-ref 'coding 'job-state) running) 'running) "running" "finished")))))
        (fork-session! spawn-state-directory (session-name spawn-session) child-name (and history? #t))
        (let* ((child-directory (string-append spawn-state-directory "/sessions/" child-name))
               (launcher (string-append (or (getenv "SHIFT_INSTALL_ROOT") (getcwd)) "/bin/shift-agent"))
               (argv (append (list launcher "--agent" spawn-agent-path "--state-dir" spawn-state-directory
                                   "--resume" child-name "--print" task
                                   "--mode" (symbol->string (setting-ref generation 'mode))
                                   "--receipt" (string-append child-directory "/receipt.json"))
                             (if model (list "--model" model) '())))
               (traceparent (assq-ref (coding-context generation span) 'traceparent))
               (run-span (trace-start! tracer "subagent.run" "AGENT"
                                       `((generation.id . ,(generation-id generation))
                                         (subagent.session . ,child-name)
                                         (subagent.tools . ,(string-join ceiling ","))
                                         (subagent.history . ,(and history? #t))
                                         (input.value . ,task))
                                       span)))
          (call-with-output-file (string-append child-directory "/authority.json")
            (lambda (port) (display (json-write (json-object (cons "tool_ceiling" (apply json-array ceiling)))) port) (newline port)))
          (let ((result ((builtin-ref 'coding 'start-child-job!)
                         argv (getcwd) (child-environment traceparent ceiling) timeout ledger (current-turn)
                         `((agent . ,child-name)) (string-append child-directory "/progress.log"))))
            (let ((job (let ((all ((builtin-ref 'coding 'job-list)))) (and (pair? all) (car (last-pair all))))))
              (when (and job run-span)
                (set! child-run-spans (cons (cons ((builtin-ref 'coding 'job-identity) job) run-span) child-run-spans))))
            (when (ui-connected?) (emit-sessions!))
            (make-tool-result #t
              (string-append (tool-result-output result)
                             (format #f "session ~a · tools ~a · narration ~a/progress.log~%"
                                     child-name (string-join ceiling ",") child-directory)))))))
    (lambda (key . arguments)
      (if (cancelled? key) (apply throw key arguments)
          (make-tool-result #f (error-text key arguments))))))
;; A finished child closes its run span; waiting on it records the join.
(define (finish-child-span! id status ok?)
  (let ((entry (assoc id child-run-spans)))
    (when entry
      (set! child-run-spans (filter (lambda (e) (not (eq? e entry))) child-run-spans))
      (trace-end! (cdr entry) (if ok? "OK" "ERROR") `((subagent.status . ,status))))))
(define (execute-job-call tracer generation span arguments)
  (let* ((result ((builtin-ref 'coding 'coding-execute) "job" arguments (getcwd) ledger (current-turn)
                  (coding-context generation span)))
         (id (json-object-ref arguments "id" #f))
         (job (and (string? id) (find (lambda (j) (string=? ((builtin-ref 'coding 'job-identity) j) id)) ((builtin-ref 'coding 'job-list)))))
         (agent (and job (assq-ref ((builtin-ref 'coding 'job-tags) job) 'agent))))
    (when (and agent (equal? (json-object-ref arguments "action" "list") "wait") (not (eq? ((builtin-ref 'coding 'job-state) job) 'running)))
      (let ((join (trace-start! tracer "subagent.join" "AGENT"
                                `((generation.id . ,(generation-id generation)) (subagent.session . ,agent)
                                  (subagent.job . ,id) (link.job . ,id))
                                span)))
        (trace-end! join (if (tool-result-success? result) "OK" "ERROR") '())))
    result))
(define (emit-sessions!)
  (when spawn-session
    (let ((summaries (session-summaries spawn-state-directory (session-name spawn-session))))
      (ui-emit! "sessions" (json-object (cons "current" (session-name spawn-session))
                                        (cons "sessions" (apply json-array summaries))))
      (length summaries))))

(define (runtime-state-directory tracer)
  (dirname (tracer-path tracer)))

(define (short-hash hash)
  (if (string? hash) (string-append (substring hash 0 12) "…") "absent"))

(define (show-open-mutations)
  (when ledger
    (let ((open (ledger-open-entries ledger)))
      (unless (null? open)
        (display "In-flight file mutations recorded in the ledger:\n")
        (for-each
         (lambda (entry)
           (let* ((path (assq-ref entry 'path))
                  (before (assq-ref entry 'before))
                  (after (assq-ref entry 'after))
                  (current (file-hash (string-append (getcwd) "/" path))))
             (format #t "  ~a (turn ~a, ~a): before ~a · after ~a · now ~a~%    ~a~%"
                     path (assq-ref entry 'turn) (assq-ref entry 'tool)
                     (short-hash before) (short-hash after) (short-hash current)
                     (cond
                      ((equal? current after) "matches after; /recover restore puts the pre-image back")
                      ((equal? current before) "matches before; nothing was written")
                      (else "matches neither; something else changed it, inspect by hand")))))
         open)))))

(define (show-recovery tracer)
  (let ((pending (recovery-read (runtime-state-directory tracer))))
    (if pending
        (format #t
                "Interrupted tool may have partially executed.\n  tool ~a\n  generation ~a\n  started ~a\n  arguments ~a\nUse /recover retry only if repeating it is safe, /recover restore to put files back, or /recover discard.\n"
                (json-object-ref pending "tool")
                (json-object-ref pending "generation_id")
                (json-object-ref pending "created_at")
                (json-write (json-object-ref pending "arguments")))
        (display "No interrupted tool call is pending.\n"))
    (show-open-mutations)))

;; Settle in-flight mutations from their recorded hashes; the recovery record
;; is cleared only when every file is accounted for.
(define (restore-interrupted-mutation! runtime tracer)
  (let ((outcomes (if ledger (ledger-resolve-open! ledger (getcwd)) '())))
    (if (null? outcomes)
        (display "No interrupted file mutation is recorded in the ledger.\n")
        (begin
          (for-each
           (lambda (outcome)
             (format #t "  ~a: ~a~%" (car outcome)
                     (case (cdr outcome)
                       ((unchanged) "already matched the pre-image; nothing to restore")
                       ((restored) "restored from the pre-image")
                       (else "changed by something else; left as it is"))))
           outcomes)
          (runtime-record!
           runtime 'mutation-restored
           `((outcomes . ,(string-join (map (lambda (o) (format #f "~a=~a" (car o) (cdr o))) outcomes) ","))))
          (if (every (lambda (outcome) (not (eq? (cdr outcome) 'diverged))) outcomes)
              (begin
                (recovery-clear! (runtime-state-directory tracer))
                (display "Interrupted mutation resolved; recovery record cleared.\n"))
              (display "Some files diverged; the recovery record is retained for inspection.\n"))))
    #t))

;; Applied once settings are loaded; every value goes through the same
;; validation as a slash command or a settings file.
(define (apply-cli-overrides!)
  (when cli-mode
    (unless (member cli-mode '("manual" "plan" "autopilot"))
      (error "--mode must be manual, plan, or autopilot" cli-mode))
    (setting-set! 'mode (string->symbol cli-mode)))
  ;; On a judge replay --model names the judge (any provider, typesafe included);
  ;; otherwise it is the session model.
  (when cli-model (if cli-judge-replay (setting-set! 'judge-model cli-model) (model-select! cli-model)))
  (for-each (lambda (entry) (setting-set-json! (car entry) (cdr entry))) cli-settings)
  (unless (null? cli-allow-runs)
    ;; run-allow has a process default, so no generation is consulted.
    (let ((current (setting-ref #f 'run-allow)))
      (setting-set! 'run-allow
                    (fold (lambda (prefix acc) (if (member prefix acc) acc (append acc (list prefix))))
                          current cli-allow-runs))))
  #t)

(define (handle-tools-command runtime line)
  (let ((generation (runtime-current runtime)))
    (unless (string=? line "/tools") (error "use /tools to list tools, or /work on|off for the work display"))
    (format #t "tools ~a · show-work ~a~%"
            (string-join (map tool-name (generation-ref generation 'agent-tools)) " ")
            (if (setting-ref generation 'show-work) "on" "off"))
    #t))

;; One switch for everything Shift prints about its own work between the
;; prompt and the answer: the tool echo and the receipt. Off leaves stdout
;; with the answer alone; receipts.jsonl and --receipt FILE are still written.
(define (handle-work-command runtime line)
  (let* ((generation (runtime-current runtime))
         (parts (cdr (string-tokenize line))))
    (cond
     ((null? parts)
      (format #t "show-work ~a~%" (if (setting-ref generation 'show-work) "on" "off")))
     ((member (car parts) '("on" "off"))
      (setting-set! 'show-work (string=? (car parts) "on"))
      (format #t "show-work ~a~%" (car parts)))
     (else (error "use /work, /work on, or /work off")))
    #t))

(define (undo-last-turn! runtime)
  (let ((turns (if ledger (ledger-undoable-turns ledger) '())))
    (if (null? turns)
        (begin (display "Nothing to undo.\n") #f)
        (let* ((turn (car turns))
               (groups (ledger-undo! ledger (getcwd) turn))
               (paths (map car groups)))
          (runtime-record! runtime 'turn-undone
                           `((turn . ,turn) (paths . ,(string-join paths ","))))
          (format #t "Undid turn ~a: ~a~%" turn
                  (string-join
                   (map (lambda (group)
                          (string-append (car group)
                                         (cond ((not (cadr group)) " (removed)")
                                               ((not (caddr group)) " (recreated)")
                                               (else ""))))
                        groups)
                   ", "))
          (let ((remaining (ledger-undoable-turns ledger)))
            (unless (null? remaining)
              (format #t "/undo again reverts turn ~a.~%" (car remaining))))
          (make-message
           "system"
           (format #f "The user ran /undo. Turn ~a's file changes were reverted: ~a now match their state before that turn. Read them again before relying on their contents."
                   turn (string-join paths ", ")))))))

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
(define last-ui-usage #f)
(define last-ui-metadata #f)
(define last-ui-identity #f)
(define (sync-ui-identity! generation)
  (let ((identity (map (lambda (key) (setting-ref generation key))
                      '(agent-provider agent-model agent-base-url))))
    (unless (equal? identity last-ui-identity)
      (set! last-ui-identity identity)
      (set! last-ui-usage #f)
      (set! last-ui-metadata #f))))
(define (session-prompt-estimate generation history)
  (catch #t
    (lambda ()
      (estimate-input-tokens
        (cons (make-message "system" (string-append (generation-ref generation 'agent-system-prompt) (skills-prompt-block) (field-notes-block (getcwd)))) history)
        (filter within-process-tool-ceiling?
                (map tool-name (generation-ref generation 'agent-tools)))))
    (lambda _ #f)))
(define* (emit-usage-snapshot! generation estimate #:optional (raw #f) (round 0))
  (sync-ui-identity! generation)
  (let ((metadata (or last-ui-metadata
                      (provider-configured-metadata
                        (setting-ref generation 'agent-provider)
                        (setting-ref generation 'agent-model)
                        (setting-ref generation 'context-limit))))
        (max-rounds (setting-ref generation 'agent-max-tool-rounds)))
    (set! last-ui-usage
      (if raw (provider-usage-event raw estimate round max-rounds metadata)
          (provider-session-usage-event last-ui-usage estimate max-rounds metadata)))
    (ui-emit! "usage" last-ui-usage)))
(define (emit-provider-metadata! generation)
  (sync-ui-identity! generation)
  (let ((metadata (provider-metadata!
                   (setting-ref generation 'agent-provider)
                   (setting-ref generation 'agent-model)
                   (setting-ref generation 'agent-base-url)
                   (setting-ref generation 'context-limit))))
    (set! last-ui-metadata metadata)
    (ui-emit! "provider-metadata" metadata)
    metadata))
(define last-estimate 0)
(define run-prompt-tokens 0)
(define run-completion-tokens 0)
(define run-usage-reported? #f)

(define (reset-run-usage!)
  (set! last-ui-identity #f)
  (set! last-ui-usage #f)
  (set! last-ui-metadata #f)
  (set! run-prompt-tokens 0)
  (set! run-completion-tokens 0)
  (set! run-usage-reported? #f))

;; The turn budget counts what a turn actually spends: uncached prompt tokens
;; plus completion tokens. Cache reads are near free and, once a turn is
;; deep in a repository, dwarf everything else in the raw prompt count.
(define (record-run-usage! attributes)
  (let ((prompt (assq-ref attributes 'llm.token_count.prompt))
        (uncached (assq-ref attributes 'llm.token_count.prompt_uncached))
        (completion (assq-ref attributes 'llm.token_count.completion)))
    (when (number? prompt)
      (set! run-prompt-tokens (+ run-prompt-tokens prompt))
      (set! turn-prompt-tokens (+ turn-prompt-tokens prompt))
      (set! turn-tokens (+ turn-tokens (if (number? uncached) uncached prompt)))
      (set! turn-uncached-tokens (+ turn-uncached-tokens (if (number? uncached) uncached prompt)))
      (set! run-usage-reported? #t))
    (let ((cached (assq-ref attributes 'llm.token_count.prompt_cached)))
      (when (number? cached)
        (set! turn-cached-tokens (+ turn-cached-tokens cached))))
    (when (number? completion)
      (set! run-completion-tokens (+ run-completion-tokens completion))
      (set! turn-completion-tokens (+ turn-completion-tokens completion))
      (set! turn-tokens (+ turn-tokens completion))
      (set! run-usage-reported? #t))))

(define (show-close-message session)
  (if run-usage-reported?
      (format #t "~%Session closed · ~a input + ~a output = ~a tokens~%"
              run-prompt-tokens run-completion-tokens
              (+ run-prompt-tokens run-completion-tokens))
      (display "\nSession closed · token usage unavailable\n"))
  (when session
    (format #t "Resume ./bin/shift-agent --resume ~a~%ID ~a~%"
            (session-name session) (session-id session)))
  (force-output))

(define (show-context generation)
  (format #t "Context: ~a estimated input tokens; limit ~a; output reserve ~a.~%"
    last-estimate (or (model-context-limit generation) 'unknown)
    (setting-ref generation 'output-reserve))
  (format #t "Last reported usage: ~a~%" (json-write last-usage)))

;; The frontend's Model tab lists what the provider reports; no inference runs.
(define (emit-models! generation ids)
  (ui-emit! "models" (json-object
    (cons "provider" (symbol->string (setting-ref generation 'agent-provider)))
    (cons "models" (apply json-array ids)))))
;; A user-owned pane's commands run only when the session's run allowlist
;; already permits them; output is recorded like any run and bounded for the UI.
(define* (run-pane! runtime name turn #:optional (only #f))
  (let* ((generation (runtime-current runtime))
         (panes (json-array-items (json-object-ref (json-object-ref (ui-state) "config") "panes" (json-array))))
         (pane (find (lambda (pane) (equal? (json-object-ref pane "name" "") name)) panes)))
    (unless pane (error "no pane named" name))
    (let loop ((rows (json-array-items (json-object-ref pane "rows"))) (index 0) (ran 0))
      (if (null? rows)
          (if (and only (= ran 0)) (error "no command row at that index" only)
              (format #f "Pane ~a started ~a job~a" name ran (if (= ran 1) "" "s")))
          (let ((row (car rows)))
            (if (or (not (json-object-ref row "command" #f)) (and only (not (= only index))))
                (loop (cdr rows) (+ index 1) ran)
                (let* ((argv (json-array-items (json-object-ref row "command")))
                       (allowed (run-allowed? argv (setting-ref generation 'run-allow))))
                  (unless allowed
                    (error (format #f "pane command is not allowlisted; /allow-run ~s first" (string-join argv " "))))
                  ;; Pane commands are background jobs: the interface never
                  ;; blocks, and the output lands under the row when it finishes.
                  ((builtin-ref 'coding 'start-job!)
                   (json-object (cons "argv" (apply json-array argv)) (cons "background" #t)
                                (cons "timeout_seconds" 3600))
                   (getcwd) ledger turn (coding-context generation #f)
                   `((pane . ,name) (index . ,index)))
                  (loop (cdr rows) (+ index 1) (+ ran 1)))))))))
(define (host-command-allowed? command)
  (let ((parts (string-tokenize command)))
    (or (member command '("/mode manual" "/mode plan" "/mode autopilot" "/sessions" "/workflow"))
        (and (= (length parts) 3) (string=? (car parts) "/plugin") (member (cadr parts) '("enable" "disable"))
             (string-every (lambda (c) (or (char-lower-case? c) (char-numeric? c) (char=? c #\-))) (caddr parts)))
        (and (= (length parts) 3) (string=? (car parts) "/mcp") (string=? (cadr parts) "connect")
             (string-every (lambda (c) (or (char-lower-case? c) (char-numeric? c) (char=? c #\-))) (caddr parts)))
        (and (= (length parts) 2) (string=? (car parts) "/skill")
             (string-every (lambda (c) (or (char-lower-case? c) (char-numeric? c) (char=? c #\-))) (cadr parts)))
        (and (<= 3 (length parts) 4) (string=? (car parts) "/pane") (string=? (cadr parts) "run")
             (string-every (lambda (c) (or (char-lower-case? c) (char-numeric? c) (char=? c #\-))) (caddr parts))
             (or (= (length parts) 3) (string-every char-numeric? (cadddr parts))))
        (and (= (length parts) 2) (string=? (car parts) "/model")
             (or (string=? (cadr parts) "list")
                 (and (string-index (cadr parts) #\/)
                      (string-every (lambda (c) (or (char-alphabetic? c) (char-numeric? c)
                                                    (memv c '(#\/ #\. #\: #\- #\_))))
                                    (cadr parts))))))))
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
             ((string=? value "list") (emit-models! generation (model-list! generation)))
             (else (model-select! value (setting-ref generation 'agent-provider)) (show-model generation))))
      ((string=? command "/context")
       (when value
         (unless (and (string=? value "limit") (= (length parts) 3)) (error "use /context limit TOKENS"))
         (setting-set! 'context-limit (string->number (caddr parts))))
       (show-context generation))
      ((string=? command "/mode")
       (when value
         (unless (member value '("manual" "plan" "autopilot")) (error "use /mode manual|plan|autopilot"))
         (setting-set! 'mode (string->symbol value)))
       (format #t "Mode: ~a~%" (setting-ref generation 'mode))
       (when (eq? (setting-ref generation 'mode) 'autopilot)
         (display "Autopilot runs every tool without asking, shell runs included; plan is read-only and manual asks each time.\n")))
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
   ((or (string=? line "/ui") (string-prefix? "/ui " line))
    (try-transition "UI" (lambda ()
      (let* ((text (string-trim-both (substring line 3)))
             (args (cond ((or (string-null? text) (string=? text "get")) (json-object))
                         ((member text '("undo" "reload")) (json-object (cons "action" text)))
                         (else (json-read text)))))
        (format #t "~a~%" (json-write (ui-action! args))))))
    'continue)
   ((member (car (string-tokenize line)) '("/settings" "/model" "/context" "/mode" "/effort" "/fast"))
    (try-transition "settings" (lambda () (handle-preference-command runtime line)))
    'continue)
   ((string=? line "/help") (show-help) 'continue)
   ((or (string=? line "/run") (string-prefix? "/run " line))
    (try-transition "run allowlist" (lambda () (handle-run-command runtime line)))
    'continue)
   ((string=? line "/show") (show-generation runtime) 'continue)
   ((or (string=? line "/thinking") (string-prefix? "/thinking " line))
    (handle-thinking-command runtime line)
    'continue)
   ((or (string=? line "/stream") (string-prefix? "/stream " line))
    (handle-stream-command runtime line)
    'continue)
   ((string=? line "/generations") (show-generations runtime) 'continue)
   ((string=? line "/extensions") (show-extensions runtime) 'continue)
   ((string=? line "/allow-run") (show-allow-runs) 'continue)
   ((string-prefix? "/allow-run " line)
    (display (allow-run-command! (trimmed-command-argument line "/allow-run "))) (newline) 'continue)
   ((string-prefix? "/learn " line)
    (learn-skill! runtime tracer session (trimmed-command-argument line "/learn ")))
   ((string=? line "/workflow") (display (workflow-listing-text)) (newline) (emit-workflows!) 'continue)
   ((string-prefix? "/workflow improve " line)
    (improve-workflow! runtime tracer (trimmed-command-argument line "/workflow improve ")) 'continue)
   ((string-prefix? "/workflow run " line)
    (let ((name (trimmed-command-argument line "/workflow run ")))
      (workflow-read (getcwd) name)
      (list 'workflow name)))
   ((string-prefix? "/workflow " line)
    (display (workflow-show-text (trimmed-command-argument line "/workflow "))) (newline) 'continue)
   ((or (string=? line "/sandbox") (string-prefix? "/sandbox " line))
    (let ((generation (runtime-current runtime)) (value (if (string=? line "/sandbox") "" (trimmed-command-argument line "/sandbox "))))
      (cond
       ((string-null? value)
        (format #t "runs: ~a~a~%host prefixes: ~a~%"
                (setting-ref generation 'run-backend)
                (if (eq? (setting-ref generation 'run-backend) 'agentkernel) (format #f " sandbox ~a" (setting-ref generation 'run-sandbox)) "")
                (string-join (map (lambda (p) (string-join p " ")) (setting-ref generation 'run-host)) ", ")))
       ((string=? value "off") (settings-set! (list (cons 'run-backend 'local))) (display "runs: local\n"))
       ((string-every (lambda (c) (or (char-alphabetic? c) (char-numeric? c) (memv c '(#\- #\_)))) value)
        (settings-set! (list (cons 'run-backend 'agentkernel) (cons 'run-sandbox value)))
        (format #t "runs: agentkernel sandbox ~a; host prefixes stay on the host~%" value))
       (else (error "use /sandbox, /sandbox NAME, or /sandbox off"))))
    'continue)
   ((string=? line "/judge")
    (let ((generation (runtime-current runtime)) (endpoint (judge-endpoint (runtime-current runtime))))
      (format #t "judge ~a · model ~a/~a · ask below ~a · this session: ~a judged, ~a blocked, ~a asked~%" (setting-ref generation 'judge) (car endpoint) (cadr endpoint)
              (or (setting-ref generation 'judge-ask-below) "never") turn-judged turn-blocked turn-judge-asked)
      (when judge-typed-disabled
        (format #t "  ~a is off for this session: ~a~%" (setting-ref generation 'judge-model) judge-typed-disabled)))
    'continue)
   ((string=? line "/judge report") (display (judge-report (or (judge-log-path) ""))) (newline) 'continue)
   ((string-prefix? "/judge " line)
    (let ((value (trimmed-command-argument line "/judge ")))
      (unless (member value '("off" "shadow" "on")) (error "use /judge, /judge report, or /judge off|shadow|on"))
      (setting-set! 'judge (string->symbol value))
      (format #t "judge ~a~%" value))
    'continue)
   ((string=? line "/plugins") (show-plugins) 'continue)
   ((string-prefix? "/plugin " line)
    (catch #t
      (lambda () (display (plugin-command! runtime (trimmed-command-argument line "/plugin "))) (newline))
      (lambda (key . args) (format #t "plugin: ~a~%" (error-text key args))))
    'continue)
   ((string=? line "/skills") (show-skills) 'continue)
   ((or (string=? line "/mcp") (string-prefix? "/mcp " line))
    (catch #t
      (lambda ()
        (let ((out (mcp-command! (if (string=? line "/mcp") "" (trimmed-command-argument line "/mcp ")))))
          (unless (string-null? out) (display out) (newline))))
      (lambda (key . args) (format #t "mcp: ~a~%" (error-text key args)) (emit-servers!)))
    'continue)
   ((string-prefix? "/allow-mcp " line)
    (display (allow-mcp-command! (trimmed-command-argument line "/allow-mcp "))) (newline) 'continue)
   ((string=? line "/jobs") (show-jobs) 'continue)
   ((string-prefix? "/jobs cancel " line)
    (display ((builtin-ref 'coding 'cancel-job!) (trimmed-command-argument line "/jobs cancel "))) (newline) 'continue)
   ((string-prefix? "/skill " line)
    (display (queue-skill! (trimmed-command-argument line "/skill "))) (newline) 'continue)
   ((string-prefix? "/recall " line) (show-recall tracer (trimmed-command-argument line "/recall ")) 'continue)
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
   ((string=? line "/recover restore") 'recover-restore)
   ((string=? line "/undo") 'undo)
   ((string=? line "/receipt") (show-receipt tracer) 'continue)
   ((or (string=? line "/tools") (string-prefix? "/tools " line))
    (try-transition "tools" (lambda () (handle-tools-command runtime line)))
    'continue)
   ((or (string=? line "/work") (string-prefix? "/work " line))
    (try-transition "work display" (lambda () (handle-work-command runtime line)))
    'continue)
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
   ((string=? line "/upgrade")
    (cond ((not session) (display "Upgrade needs a durable session.\n") 'continue)
          (else (runtime-record! runtime 'runtime-handoff `((from . ,runtime-version-label) (session . ,(session-name session))))
                (format #t "handing session ~a to the current install (from ~a)~%" (session-name session) runtime-version-label)
                (set! upgrade-requested? #t) 'quit)))
   (else
    (format (current-error-port) "Unknown command. Enter /help.~%")
    'continue)))

(define (tool-name value)
  (if (symbol? value) (symbol->string value) value))

(define (read-user-line prompt)
  (let ((line
         (if (and control-port (string=? prompt "shift> "))
             (begin
               (unless (ui-connected?) (display prompt))
               (force-output)
               (emit-control! "ready")
               (let ((line (get-line (current-input-port))))
                 (set! operation-status "ok")
                 (set! operation-error #f)
                 (set! operation-span #f)
                 line))
             (if (isatty? (current-input-port))
                 (readline prompt)
                 (get-line (current-input-port))))))
    (when (and (string=? prompt "shift> ")
               (or (ui-connected?)
                   (and (not control-port) (isatty? (current-input-port)))))
      (input-remember! line))
    line))

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
  (unless (ui-connected?) (display prompt) (force-output))
  (ui-emit! "approval" prompt)
  (emit-control! "needs_approval")
  (dynamic-wind
    (lambda () #t)
    (lambda ()
     (let ((answer
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
                           answer))))))))
    (when (and (ui-connected?) (not (eof-object? answer)))
      (emit-control! "working"))
       answer))
    (lambda () (ui-emit! "approval-end" #t))))

(define (approval-preview! text)
  (if (ui-connected?)
      (ui-emit! "approval-preview" (if (> (string-length text) 32768)
                                      (string-append (substring text 0 32768) "\nPreview truncated.")
                                      text))
      (begin (display text) (force-output))))

(define (confirm-shell command)
  (approval-preview! (format #f "\nShell requests:\n  ~a~%" command))
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
          (unless (or (member name mutation-tool-names)
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
                   ((string=? name "recall") (execute-recall tracer arguments))
                   ((string=? name "notes") (execute-notes tracer arguments))
                   ((member name mutation-tool-names)
                    (execute-change! runtime generation tracer name arguments #f))
                   ((member name coding-tool-names)
                    ((builtin-ref 'coding 'coding-execute)
                     name arguments (getcwd) ledger (current-turn)
                     (coding-context generation span)))
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

(define* (emit-ui-transcript! role text #:optional (stream? #f) (end? #f))
  (when (ui-connected?)
    (ui-emit! "transcript"
              (json-object (cons "role" role) (cons "text" text)
                           (cons "stream" stream?) (cons "end" end?)))))

(define (record-input! runtime generation turn-count line)
  (runtime-record!
   runtime 'user-input
   `((generation . ,(generation-id generation))
     (turn . ,turn-count)
     (text . ,line)))
  (emit-ui-transcript! "user" line))

(define (record-output! runtime generation turn-count reply)
  (runtime-record!
   runtime 'assistant-output
   `((generation . ,(generation-id generation))
     (turn . ,turn-count)
     (text . ,reply))))

(define (demo-turn! runtime generation history line turn-count)
  (let ((reply (generation-call generation 'agent-demo-response line)))
    (record-output! runtime generation turn-count reply)
    (if (ui-connected?)
        (emit-ui-transcript! "assistant" reply)
        (begin (display reply) (newline)))
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
       (string-append "live evaluation rejected: " (caught-error-detail key arguments)
                      "\n" (live-bindings-hint generation))))))
;; What a rejected live change may target: the generation's agent-* and
;; extension-* bindings with their kinds, so the model stops probing for them.
(define (live-bindings-hint generation)
  (let* ((module (generation-module generation))
         (names (sort (filter (lambda (name)
                                (let ((text (symbol->string name)))
                                  (or (string-prefix? "agent-" text) (string-prefix? "extension-" text))))
                              (module-map (lambda (name variable) name) module))
                      (lambda (a b) (string<? (symbol->string a) (symbol->string b)))))
         (kind (lambda (value)
                 (cond ((procedure? value) "procedure") ((string? value) "string")
                       ((and (list? value) (pair? value) (every symbol? value)) "list of symbols")
                       ((list? value) "list")
                       ((boolean? value) "boolean") ((number? value) "number") ((symbol? value) "symbol") (else "value")))))
    (string-append
     "Live bindings you can define or set! directly (no probing needed): "
     (string-join (map (lambda (name)
                         (string-append (symbol->string name) " (" (kind (module-ref module name)) ")"))
                       names)
                  ", ")
     ". Only define, define*, set! and begin are accepted at top level; the sandbox has no procedure?, bound-identifier? or exception handlers.")))

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
(define (approval-letter answer)
  (cond
   ((char? answer) (char-downcase answer))
   ((string? answer)
    (let ((text (string-downcase (string-trim-both answer))))
      (cond ((member text '("y" "yes")) #\y)
            ((member text '("a" "always")) #\a)
            (else #\n))))
   (else #\n)))

;; `a` on a run prompt approves it and adds the exact argv to this session's
;; allowlist; /settings save promotes it like any other preference.
(define (remember-run! generation arguments)
  (let ((argv (run-argv-of arguments))
        (current (setting-ref generation 'run-allow)))
    (unless (member argv current)
      (settings-set! (list (cons 'run-allow (append current (list argv))))))
    (format #t "Allowed for this session: ~a~%" (string-join argv " "))))

(define (run-preview arguments)
  (format #f "run ~a  (cwd ~a, timeout ~as~a)~%"
          (string-join (run-argv-of arguments) " ")
          (json-object-ref arguments "cwd" ".")
          (json-object-ref arguments "timeout_seconds" 120)
          (if (json-object-ref arguments "background" #f) ", background job" "")))

;; --- the judge in the loop ------------------------------------------------------
;; Autopilot: rules first, then one request to the judge model; a block hands
;; the model the rule. Shadow: manual still asks, the judge also runs and
;; both answers are logged. Three consecutive blocks, or twenty in a turn,
;; pause the judge and manual prompting takes over for the rest of the turn.
(define turn-judged 0) (define turn-blocked 0) (define turn-judge-ms 0) (define turn-judge-asked 0)
(define judge-consecutive-blocks 0) (define judge-paused? #f)
(define recent-user-messages '())
(define session-remotes "")
(define (remember-user-message! text)
  (set! recent-user-messages (let ((next (append recent-user-messages (list text))))
                               (if (> (length next) 4) (list-tail next (- (length next) 4)) next))))
(define (git-dirty?)
  (catch #t
    (lambda ()
      (let ((result ((builtin-ref 'coding 'run-argv) '("git" "status" "--porcelain"))))
        (and (eqv? (car result) 0) (not (string-null? (string-trim-both (cdr result)))))))
    (lambda _ 'unknown)))
(define (session-judge-endpoint generation)
  (list (setting-ref generation 'agent-provider) (setting-ref generation 'agent-model)
        (setting-ref generation 'agent-base-url) (setting-ref generation 'agent-api-key-environment)))
;; Set once a typed judge fails for a reason retrying cannot fix (no key, a
;; rejected key, no credits, a malformed request); the session model judges
;; for the rest of the session and /judge says why.
(define judge-typed-disabled #f)
(define judge-fallbacks-announced '())
(define (judge-endpoint generation)
  ;; judge-model PROVIDER/MODEL, or the session's own provider and model.
  (let ((setting (setting-ref generation 'judge-model)))
    (if (and (string? setting) (not (and judge-typed-disabled (string-prefix? "typesafe/" setting))))
        (let* ((slash (string-index setting #\/))
               (provider (string->symbol (substring setting 0 slash)))
               (model (substring setting (+ slash 1))))
          (if (eq? provider (setting-ref generation 'agent-provider))
              (list provider model (setting-ref generation 'agent-base-url) (setting-ref generation 'agent-api-key-environment))
              (list provider model (car (provider-defaults provider)) (cdr (provider-defaults provider)))))
        (list (setting-ref generation 'agent-provider) (setting-ref generation 'agent-model)
              (setting-ref generation 'agent-base-url) (setting-ref generation 'agent-api-key-environment)))))
;; (base-url . key) when the session's judge is Jev and it has not been switched
;; off; the other typed judgments (tool_search rank, skill hint) follow the judge.
(define (typed-endpoint generation)
  (let ((setting (setting-ref generation 'judge-model)))
    (and (string? setting) (string-prefix? "typesafe/" setting) (not judge-typed-disabled)
         (let ((key (typesafe-api-key (getenv "TYPESAFE_API_KEY"))))
           (and key (cons (car (provider-defaults 'typesafe)) key))))))
(define (judge-log-path)
  (and runtime-state-directory-for-judge (string-append runtime-state-directory-for-judge "/judge.jsonl")))
(define runtime-state-directory-for-judge #f)
;; One judge.jsonl record carries everything a replay needs: the action, the
;; preview and the user messages the judge saw, plus the mode and allowlist.
(define (judge-record generation name arguments preview verdict human)
  (json-object (cons "turn" (current-turn)) (cons "at" (strftime "%Y-%m-%dT%H:%M:%SZ" (gmtime (current-time)))) (cons "tool" name)
               (cons "verdict" (symbol->string (assq-ref verdict 'verdict)))
               (cons "rule" (assq-ref verdict 'rule)) (cons "reason" (assq-ref verdict 'reason))
               (cons "model" (assq-ref verdict 'model)) (cons "ms" (assq-ref verdict 'ms))
               (cons "confidence" (or (assq-ref verdict 'confidence) json-null))
               (cons "fallback" (or (assq-ref verdict 'fallback) json-null))
               (cons "human" human)
               (cons "arguments" (if (json-object? arguments) arguments (json-object)))
               (cons "preview" (or preview ""))
               (cons "user_messages" (apply json-array (map (lambda (m) (clip m 600)) recent-user-messages)))
               (cons "mode" (symbol->string (setting-ref generation 'mode)))
               (cons "run_allow" (apply json-array (map (lambda (p) (apply json-array p)) (setting-ref generation 'run-allow))))))
(define (judge-replay! runtime path)
  (let* ((generation (runtime-current runtime))
         (endpoint (judge-endpoint generation))
         (key-env (cadddr endpoint))
         (lines (filter (lambda (l) (not (string-null? (string-trim-both l))))
                        (string-split (call-with-input-file path get-string-all) #\newline))))
    (for-each
     (lambda (line)
       (let* ((record (json-read line))
              (messages (let ((m (json-object-ref record "user_messages" #f)))
                          (if (json-array? m) (filter string? (json-array-items m)) '())))
              (allow (let ((a (json-object-ref record "run_allow" #f)))
                       (if (json-array? a) (filter-map (lambda (p) (and (json-array? p) (json-array-items p))) (json-array-items a)) '())))
              (context `((user-messages . ,messages) (tool . ,(json-object-ref record "tool" "run"))
                         (arguments . ,(json-object-ref record "arguments" (json-object)))
                         (preview . ,(json-object-ref record "preview" "")) (root . ,(getcwd)) (remotes . "")
                         (dirty . unknown) (mode . ,(string->symbol (json-object-ref record "mode" "autopilot")))
                         (run-allow . ,allow)))
              (verdict (judge-decide! (car endpoint) (cadr endpoint) (caddr endpoint) (and key-env (getenv key-env)) context)))
         (display (json-write
                   (apply json-object
                          (append (json-object-entries record)
                                  (list (cons "replay"
                                              (json-object (cons "verdict" (symbol->string (assq-ref verdict 'verdict)))
                                                           (cons "rule" (assq-ref verdict 'rule)) (cons "reason" (assq-ref verdict 'reason))
                                                           (cons "model" (assq-ref verdict 'model)) (cons "ms" (assq-ref verdict 'ms))
                                                           (cons "confidence" (or (assq-ref verdict 'confidence) json-null)))))))))
         (newline) (force-output)))
     lines)
    0))
(define (judge-fallback! generation endpoint context verdict)
  ;; A typed judge that could not answer hands the decision to the session
  ;; model, which is the judge the session would have had without the setting.
  (let ((class (assq-ref verdict 'failure)))
    (if (and class (eq? (car endpoint) 'typesafe))
        (let* ((permanent? (assq-ref verdict 'permanent))
               (why (assq-ref verdict 'reason))
               (session (session-judge-endpoint generation))
               (session-key (cadddr session)))
          (when permanent? (set! judge-typed-disabled why))
          (unless (memq class judge-fallbacks-announced)
            (set! judge-fallbacks-announced (cons class judge-fallbacks-announced))
            (format (tool-echo-port) "shift> judge: ~a; ~a/~a judges ~a~%" why (car session) (cadr session)
                    (if permanent? "for the rest of this session" "this action"))
            (force-output (tool-echo-port)))
          (append (judge-decide! (car session) (cadr session) (caddr session) (and session-key (getenv session-key)) context)
                  `((fallback . ,(format #f "~a" class)))))
        verdict)))
(define (consult-judge! runtime generation name arguments preview human)
  ;; Returns the verdict alist; records the span, the counters, the log and the UI event.
  (let* ((endpoint (judge-endpoint generation))
         (key-env (cadddr endpoint))
         (context `((user-messages . ,recent-user-messages) (tool . ,name) (arguments . ,arguments)
                    (preview . ,(or preview "")) (root . ,(getcwd)) (remotes . ,session-remotes)
                    (dirty . ,(if (member name '("run" "shell")) (git-dirty?) 'unknown))
                    (mode . ,(setting-ref generation 'mode)) (run-allow . ,(setting-ref generation 'run-allow))))
         (verdict (judge-fallback! generation endpoint context
                                   (judge-decide! (car endpoint) (cadr endpoint) (caddr endpoint) (and key-env (getenv key-env)) context))))
    (set! turn-judged (+ turn-judged 1))
    (set! turn-judge-ms (+ turn-judge-ms (or (assq-ref verdict 'ms) 0)))
    (when (eq? (assq-ref verdict 'verdict) 'block) (set! turn-blocked (+ turn-blocked 1)))
    (runtime-record! runtime 'judge
      `((tool . ,name) (verdict . ,(assq-ref verdict 'verdict)) (rule . ,(assq-ref verdict 'rule))
        (reason . ,(assq-ref verdict 'reason)) (ms . ,(assq-ref verdict 'ms)) (human . ,human)
        (model . ,(assq-ref verdict 'model)) (confidence . ,(assq-ref verdict 'confidence)) (tokens . ,(assq-ref verdict 'tokens))
        (fallback . ,(assq-ref verdict 'fallback))))
    ;; Shadow decisions are logged by the caller once the human has answered.
    (let ((path (judge-log-path)))
      (when (and path (not (string=? human "pending")))
        (judge-log! path (judge-record generation name arguments preview verdict human))))
    (ui-emit! "judge" (json-object (cons "tool" name) (cons "verdict" (symbol->string (assq-ref verdict 'verdict)))
                                   (cons "rule" (assq-ref verdict 'rule)) (cons "reason" (assq-ref verdict 'reason))
                                   (cons "shadow" (not (string=? human "none")))))
    verdict))
(define (judge-blocked-result name verdict)
  (make-tool-result #f (format #f "blocked by autopilot [~a]: ~a Choose a different approach that stays within the request, or ask the user."
                               (assq-ref verdict 'rule) (assq-ref verdict 'reason))))
(define last-judge-block #f)
(define* (authorize-tool runtime generation name arguments #:optional (preview #f))
  (let* ((run? (string=? name "run"))
         (judge-setting (setting-ref generation 'judge))
         (sandboxed? (and run? (run-sandboxed? generation arguments)))
         (preview (if (and sandboxed? preview) (string-append preview "  in agentkernel sandbox " (setting-ref generation 'run-sandbox) "\n") preview))
         (policy (tool-decision (setting-ref generation 'mode) name arguments
                                (setting-ref generation 'run-allow) (setting-ref generation 'mcp-allow) sandboxed?))
         (rule (and (eq? policy 'judge)
                    (judge-rules name arguments (getcwd) (setting-ref generation 'run-allow) (setting-ref generation 'mcp-allow))))
         (decision (cond ((not (eq? policy 'judge)) policy)
                         ((eq? rule 'allow) 'allow)
                         ((pair? rule) 'deny-rule)
                         ((or judge-paused? (eq? judge-setting 'off)) 'ask)
                         (else 'judge)))
         (ask-human
          (lambda (shadow-note)
            (and (interactive-approval?)
                 (begin
                   (approval-preview! (string-append
                                       (if preview (format #f "\n~a" preview) (tool-request-text name arguments))
                                       (or shadow-note "")))
                   (let ((letter (approval-letter
                                  (read-approval-key
                                   (if run? "Approve run? [y/N/a] " "Approve tool? [y/N] ")))))
                     (cond
                      ((char=? letter #\y) #t)
                      ((and run? (char=? letter #\a)) (remember-run! generation arguments) #t)
                      (else #f)))))))
         (allowed?
          (case decision
            ((allow) #t)
            ((deny-rule)
             (set! last-judge-block `((rule . ,(cdr rule)) (reason . "refused by a fixed rule; the judge was not consulted")))
             (set! turn-blocked (+ turn-blocked 1))
             (ui-emit! "judge" (json-object (cons "tool" name) (cons "verdict" "block") (cons "rule" (cdr rule)) (cons "reason" "fixed rule") (cons "shadow" #f)))
             #f)
            ((judge)
             (let ((verdict (consult-judge! runtime generation name arguments preview "none")))
               (cond
                ((eq? (assq-ref verdict 'verdict) 'allow)
                 (set! judge-consecutive-blocks 0) (set! last-judge-block #f)
                 ;; An allow the typed judge is not sure of asks you instead of going
                 ;; through silently; print mode has nobody to ask, so it blocks there.
                 (let ((confidence (assq-ref verdict 'confidence)) (floor (setting-ref generation 'judge-ask-below)))
                   (if (and (number? confidence) (number? floor) (< confidence floor))
                       (begin
                         (set! turn-judge-asked (+ turn-judge-asked 1))
                         (if (interactive-approval?)
                             (ask-human (format #f "\njudge allows at confidence ~,2f, under judge-ask-below ~a\n" confidence floor))
                             (begin
                               (set! last-judge-block `((rule . "judge-uncertain")
                                                        (reason . ,(format #f "the judge allowed at confidence ~,2f, under judge-ask-below ~a, and there is nobody to ask" confidence floor))))
                               (set! turn-blocked (+ turn-blocked 1))
                               #f)))
                       #t)))
                (else
                 (set! last-judge-block verdict)
                 (set! judge-consecutive-blocks (+ judge-consecutive-blocks 1))
                 (when (or (>= judge-consecutive-blocks 3) (>= turn-blocked 20))
                   (set! judge-paused? #t)
                   (format (tool-echo-port) "shift> autopilot paused after repeated blocks; asking for the rest of this turn~%")
                   (force-output (tool-echo-port)))
                 #f))))
            ((ask)
             (if (and (eq? judge-setting 'shadow) (eq? (setting-ref generation 'mode) 'manual) (interactive-approval?)
                      (not (judge-rules name arguments (getcwd) (setting-ref generation 'run-allow) (setting-ref generation 'mcp-allow))))
                 ;; Shadow: the judge answers first, then the human; both go to the log.
                 (let* ((verdict (consult-judge! runtime generation name arguments preview "pending"))
                        (answer (ask-human (format #f "\njudge would ~a [~a]: ~a\n" (assq-ref verdict 'verdict) (assq-ref verdict 'rule) (assq-ref verdict 'reason)))))
                   (let ((path (judge-log-path)))
                     (when path
                       (judge-log! path (judge-record generation name arguments preview verdict (if answer "allow" "deny")))))
                   answer)
                 (ask-human #f)))
            (else #f))))
    (runtime-record! runtime 'tool-approval
      `((tool . ,name) (mode . ,(setting-ref generation 'mode)) (decision . ,decision) (approved . ,(if allowed? #t #f))))
    allowed?))

(define (unavailable-result name)
  (if last-judge-block
      (let ((verdict last-judge-block)) (set! last-judge-block #f) (judge-blocked-result name verdict))
      (unavailable-result* name)))
(define (unavailable-result* name)
  (make-tool-result
   #f
   (format #f
           "tool unavailable in this turn: ~a. The active image, execution mode, or approval denied it. Continue without it."
           name)))

(define (changes-preview name changes)
  (let ((total (fold (lambda (prepared sum)
                       (let ((stat (prepared-change-diffstat prepared)))
                         (cons (+ (car sum) (car stat)) (+ (cdr sum) (cdr stat)))))
                     '(0 . 0) changes)))
    (string-append
     (if (= 1 (length changes))
         (format #f "~a ~a ~a~%" name (prepared-change-path (car changes)) (format-diffstat total))
         (format #f "~a ~a files ~a~%" name (length changes) (format-diffstat total)))
     (diff-preview (string-join (map prepared-change-diff changes) "") 120))))

(define mutation-tool-names '("write" "edit" "apply_patch"))

;; W3C trace context so a child process, local or sandboxed, joins the span.
(define (coding-context generation span)
  `((traceparent . ,(and span (trace-trace-id span) (trace-span-id span)
                         (format #f "00-~a-~a-01" (trace-trace-id span) (trace-span-id span))))
    (backend . ,(setting-ref generation 'run-backend))
    (sandbox . ,(setting-ref generation 'run-sandbox))
    (host . ,(setting-ref generation 'run-host))))
(define (run-sandboxed? generation arguments)
  (and (builtin-enabled? 'coding)
       (eq? 'sandbox ((builtin-ref 'coding 'run-placement) (run-argv-of arguments) (coding-context generation #f)))))

(define (handle-run-command runtime line)
  (let* ((generation (runtime-current runtime))
         (parts (cdr (string-tokenize line)))
         (current (setting-ref generation 'run-allow)))
    (cond
     ((or (null? parts) (equal? parts '("list")))
      (if (null? current)
          (format #t "Run allowlist is empty (default); answer a at a run prompt or use /allow-run \"ARGV...\" [project|user]~%")
          (for-each (lambda (entry)
                      (format #t "allow ~a (~a)~%" (string-join (car entry) " ") (cdr entry)))
                    (run-allow-entries))))
     ((and (string=? (car parts) "allow") (pair? (cdr parts)))
      (allow-run! (cdr parts) 'session)
      (format #t "Allowed without asking in this session: ~a~%" (string-join (cdr parts) " ")))
     ((and (string=? (car parts) "deny") (pair? (cdr parts)))
      (let ((scopes (deny-run! (cdr parts))))
        (format #t "Removed from ~a: ~a~%" (string-join (map symbol->string scopes) ", ") (string-join (cdr parts) " "))))
     (else (error "use /run list, /run allow ARGV..., /run deny ARGV..., or /allow-run \"ARGV...\" [project|user]")))
    #t))

(define (prepare-changes name arguments)
  (if (string=? name "apply_patch")
      ((builtin-ref 'coding 'coding-prepare) arguments (getcwd))
      (list (prepare-change name arguments (getcwd)))))

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
      (let ((changes (prepare-changes name arguments)))
        (when ledger
          (for-each (lambda (prepared)
                      (ledger-check-stale! ledger (prepared-change-path prepared)
                                           (prepared-change-before-hash prepared)))
                    changes))
        (if (not (authorize-tool runtime generation name arguments
                                 (changes-preview name changes)))
            (unavailable-result name)
            (let ((seqs (map (lambda (prepared)
                               (and ledger
                                    (ledger-begin! ledger (current-turn) call-id name
                                                   (prepared-change-path prepared)
                                                   (prepared-change-before-text prepared)
                                                   (prepared-change-after-text prepared))))
                             changes)))
              (recovery-write! (runtime-state-directory tracer) name arguments
                               (generation-id generation))
              (catch #t
                (lambda ()
                  (let ((result (commit-changes! changes)))
                    (for-each (lambda (seq) (when seq (ledger-commit! ledger seq))) seqs)
                    result))
                (lambda (key . detail)
                  (if (cancelled? key)
                      (apply throw key detail)
                      (begin
                        (for-each (lambda (seq) (when seq (ledger-abort! ledger seq))) seqs)
                        (make-tool-result
                         #f (string-append "tool failed: "
                                           (caught-error-detail key detail)))))))))))
    (lambda (key . detail)
      (if (cancelled? key)
          (apply throw key detail)
          (make-tool-result
           #f (string-append "tool error: " (caught-error-detail key detail)))))))

;; One line per tool call and one per result, so a session shows what the
;; model did even when nothing needed approval. Print mode keeps stdout for
;; the answer and echoes to stderr.
(define (clip text limit)
  (let ((line (car (string-split text #\newline))))
    (if (> (string-length line) limit)
        (string-append (substring line 0 limit) "…")
        line)))

;; Argument values as prose, not JSON: strings bare, lists space-joined,
;; nested objects still JSON because nothing better is known about them.
(define (argument-text value)
  (cond ((string? value) (string-map (lambda (c) (if (char=? c #\newline) #\space c)) value))
        ((json-array? value) (string-join (map argument-text (json-array-items value)) " "))
        ((eq? value #t) "yes") ((eq? value #f) "no")
        ((number? value) (number->string value))
        (else (json-write value))))
(define (argument-pairs arguments)
  (if (json-object? arguments)
      (map (lambda (entry) (cons (car entry) (argument-text (cdr entry)))) (json-object-entries arguments))
      '()))
(define (tool-call-summary name arguments)
  (define (field key)
    (let ((value (json-object-ref arguments key #f)))
      (and (string? value) value)))
  (cond
   ((member name '("read" "write" "edit")) (or (field "path") ""))
   ((string=? name "apply_patch")
    (let ((patch (field "patch")))
      (if patch (format #f "~a lines" (length (string-split patch #\newline))) "")))
   ((string=? name "rg") (or (field "query") ""))
   ;; A multi-line argument (python -c SCRIPT) still shows on the one line.
   ((string=? name "run") (string-map (lambda (c) (if (char=? c #\newline) #\space c))
                                      (string-join (run-argv-of arguments) " ")))
   ((string=? name "diff") (or (field "scope") "turn"))
   ((string=? name "status") "")
   ((string=? name "spawn")
    (string-append (or (field "name") "agent") " · " (argument-text (or (field "task") ""))))
   ((string=? name "job") (string-join (filter string? (list (field "action") (field "id"))) " "))
   ((member name '("recall" "traces" "tool_search")) (or (field "query") (field "span_id") ""))
   ((string=? name "skill") (or (field "name") ""))
   (else (clip (string-join (map (lambda (pair) (string-append (car pair) " " (cdr pair)))
                                 (argument-pairs arguments)) " · ") 100))))
;; What a person approves: the tool and its summary, then one line per argument.
(define (tool-request-text name arguments)
  (string-append
   (format #f "Tool requests: ~a ~a~%" name (clip (tool-call-summary name arguments) 100))
   (string-concatenate
    (map (lambda (pair) (format #f "  ~a: ~a~%" (car pair) (clip (cdr pair) 300)))
         (argument-pairs arguments)))))

(define (tool-echo-port)
  (if print-mode? (current-error-port) (current-output-port)))

(define next-ui-tool-id 0)

(define (echo-tool-call! generation id name arguments)
  (ui-emit! "tool"
            (json-object (cons "id" id) (cons "turn" (current-turn))
                         (cons "name" name)
                         (cons "summary" (tool-call-summary name arguments))
                         (cons "at" (strftime "%H:%M" (localtime (current-time))))))
  (when (and (not (ui-connected?)) (setting-ref generation 'show-work))
    (format (tool-echo-port) "tool> ~a ~a~%" name (clip (tool-call-summary name arguments) 120))
    (force-output (tool-echo-port))))

;; The frontend's Log tab shows what a run printed; keep the event bounded and
;; point at the ledger log for the rest rather than replaying whole outputs.
(define ui-output-lines 300)
(define ui-output-chars 16384)
(define (ui-output-excerpt text)
  (let* ((lines (string-split text #\newline))
         (kept (if (> (length lines) ui-output-lines) (take lines ui-output-lines) lines))
         (joined (string-join kept "\n"))
         (bounded (if (> (string-length joined) ui-output-chars) (substring joined 0 ui-output-chars) joined)))
    (cons bounded (not (string=? bounded text)))))
(define (emit-ui-tool-result! id name ok? output)
  (let ((excerpt (and (string=? name "run") (ui-output-excerpt output))))
    (ui-emit! "tool-result"
              (json-object (cons "id" id) (cons "turn" (current-turn))
                           (cons "name" name) (cons "ok" ok?)
                           (cons "summary" (clip output 200))
                           (cons "output" (if excerpt (car excerpt) json-null))
                           (cons "truncated" (if excerpt (cdr excerpt) #f))))))

(define (echo-tool-result! generation id name ok? output)
  (emit-ui-tool-result! id name ok? output)
  (when (and (not (ui-connected?)) (setting-ref generation 'show-work))
    (format (tool-echo-port) "      ~a ~a~%" (if ok? "✓" "✗") (clip output 120))
    (force-output (tool-echo-port))))

;; Only committed ledger images enter this snapshot, never approval previews or
;; a later read of the working tree. Limit the event without splitting UTF-8.
(define (bounded-ui-diff text)
  (let loop ((index 0) (lines 0) (bytes 0))
    (cond
     ((= index (string-length text)) (cons text #f))
     ((>= lines 200) (cons (substring text 0 index) #t))
     (else
      (let* ((character (string-ref text index))
             (code (char->integer character))
             (width (cond ((<= code #x7f) 1) ((<= code #x7ff) 2)
                          ((<= code #xffff) 3) (else 4))))
        (if (> (+ bytes width) 32768)
            (cons (substring text 0 index) #t)
            (loop (+ index 1) (+ lines (if (char=? character #\newline) 1 0))
                  (+ bytes width))))))))

(define (emit-ui-diff! turn)
  (when (and (ui-connected?) ledger)
    (catch #t
      (lambda ()
        (define (image hash)
          (and hash (or (ledger-read-blob ledger hash)
                        (error "committed diff image is unavailable" hash))))
        (define (publish text truncated? files)
          (ui-emit! "diff" (json-object (cons "turn" turn) (cons "text" text)
                                       (cons "truncated" truncated?)
                                       (cons "files" (apply json-array (reverse files))))))
        (let loop ((groups (filter (lambda (group) (not (equal? (cadr group) (caddr group))))
                                   (ledger-turn-groups ledger turn)))
                   (text "") (truncated? #f) (files '()))
          (if (null? groups)
              (publish text truncated? files)
              (let* ((group (car groups))
                     (path (car group))
                     (diff (unified-diff (image (cadr group)) (image (caddr group))
                                         (string-append "a/" path)
                                         (string-append "b/" path)))
                     (stat (diffstat diff))
                     (bounded (if truncated? (cons text #t)
                                  (bounded-ui-diff (string-append text diff)))))
                (loop (cdr groups) (car bounded) (cdr bounded)
                      (cons (json-object (cons "path" path)
                                         (cons "added" (car stat))
                                         (cons "removed" (cdr stat)))
                            files))))))
      (lambda (key . arguments)
        (if (cancelled? key)
            (apply throw key arguments)
            (ui-emit! "ui-error"
                      (string-append "Committed diff unavailable: "
                                     (caught-error-detail key arguments))))))))

;; Read-only calls in the same round run concurrently, at most four at a time,
;; before the sequential pass records, traces and appends their results in
;; the model's order. Only calls the policy already allows without asking are
;; prefetched; mutations, runs and anything that could prompt stay sequential.
(define parallel-tool-names '("read" "rg" "status" "diff" "traces" "recall"))
(define (prefetchable? generation name arguments enabled-tools)
  (and (member name enabled-tools)
       (or (member name parallel-tool-names)
           (and (string=? name "job")
                (member (json-object-ref arguments "action" "list") '("list" "output"))))
       (not (json-object-ref arguments "invalid_json" #f))
       (eq? 'allow (tool-decision (setting-ref generation 'mode) name arguments
                                  (setting-ref generation 'run-allow) (setting-ref generation 'mcp-allow)))))
(define (execute-read-only-call tracer generation name arguments)
  (catch #t
    (lambda ()
      (cond
       ((string=? name "traces") (execute-traces tracer arguments))
       ((string=? name "recall") (execute-recall tracer arguments))
       ((member name coding-tool-names)
        ((builtin-ref 'coding 'coding-execute) name arguments (getcwd) ledger (current-turn)
         (coding-context generation #f)))
       (else (execute-tool name arguments (getcwd) (generation-ref generation 'agent-shell-policy) (lambda _ #t)))))
    (lambda (key . arguments)
      (if (cancelled? key)
          (apply throw key arguments)
          (make-tool-result #f (format #f "tool failed (~a): ~s" key arguments))))))
(define (prefetch-tool-calls tracer generation calls enabled-tools)
  (let ((safe (filter (lambda (call) (prefetchable? generation (tool-call-name call) (tool-call-arguments call) enabled-tools)) calls)))
    (if (< (length safe) 2)
        '()
        (let batch ((remaining safe) (done '()))
          (if (null? remaining)
              done
              (let* ((now (if (> (length remaining) 4) (take remaining 4) remaining))
                     (threads (map (lambda (call)
                                     (call-with-new-thread
                                      (lambda () (execute-read-only-call tracer generation (tool-call-name call) (tool-call-arguments call)))))
                                   now)))
                (batch (drop remaining (length now))
                       (append done (map (lambda (call thread) (cons call (join-thread thread))) now threads)))))))))
(define (execute-tool-calls runtime tracer parent generation provider calls
                            messages enabled-tools)
  (define prefetched (prefetch-tool-calls tracer generation calls enabled-tools))
  (let loop ((remaining calls) (result messages))
    (if (null? remaining)
        result
        (let* ((call (car remaining))
               (name (tool-call-name call))
               (ui-id (begin (set! next-ui-tool-id (+ next-ui-tool-id 1))
                             next-ui-tool-id))
               (enabled? (if (member name enabled-tools) #t #f)))
          (runtime-record!
           runtime 'tool-call
           `((generation . ,(generation-id generation))
             (tool . ,name)
             (arguments . ,(json-write (tool-call-arguments call)))))
          (echo-tool-call! generation ui-id name (tool-call-arguments call))
          (count-turn-tool-call! name)
          (let* ((span
                  (trace-start!
                   tracer (string-append "tool." name) "TOOL"
                   `((generation.id . ,(generation-id generation))
                     (tool.name . ,name)
                     (input.value . ,(json-write (tool-call-arguments call))))
                   parent))
                 (outcome
                  (catch #t
                    (lambda ()
                      (cond
                       ((not enabled?) (unavailable-result name))
                       ((json-object-ref (tool-call-arguments call) "invalid_json" #f)
                        (runtime-record! runtime 'tool-arguments-invalid
                                         `((tool . ,name)
                                           (error . ,(json-object-ref (tool-call-arguments call) "json_error" ""))))
                        (make-tool-result
                         #f
                         (format #f "the arguments for ~a were not a valid JSON object (~a); nothing ran. Resend the call with well-formed JSON, splitting a very large edit into smaller ones if needed. Start of what arrived: ~a"
                                 name
                                 (json-object-ref (tool-call-arguments call) "json_error" "")
                                 (clip (json-object-ref (tool-call-arguments call) "invalid_json" "") 120))))
                       ((member name mutation-tool-names)
                        (execute-change! runtime generation tracer name
                                         (tool-call-arguments call) (tool-call-id call)))
                       ((not (authorize-tool runtime generation name (tool-call-arguments call)
                                             (and (string=? name "run")
                                                  (run-preview (tool-call-arguments call)))))
                        (unavailable-result name))
                       ((assq call prefetched) => cdr)
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
                             ((string=? name "ui")
                              (make-tool-result #t (json-write (ui-action! (tool-call-arguments call)))))
                             ((string=? name "live_eval")
                              (execute-live-eval
                               runtime generation (tool-call-arguments call)
                               (assistant-explained-change? messages)))
                             ((string=? name "extension")
                              (execute-extension
                               runtime generation (tool-call-arguments call)))
                             ((string=? name "skill")
                              (execute-skill (tool-call-arguments call)))
                             ((string=? name "tool_search")
                              (execute-tool-search generation (tool-call-arguments call)))
                             ((mcp-tool-name? name)
                              (execute-mcp-call name (tool-call-arguments call)))
                             ((string=? name "traces")
                              (execute-traces tracer (tool-call-arguments call)))
                             ((string=? name "recall")
                              (execute-recall tracer (tool-call-arguments call)))
                             ((string=? name "notes")
                              (execute-notes tracer (tool-call-arguments call)))
                             ((string=? name "spawn")
                              (execute-spawn runtime generation tracer (tool-call-arguments call) span))
                             ((string=? name "workflow")
                              (execute-workflow runtime generation tracer (tool-call-arguments call) span))
                             ((string=? name "job")
                              (execute-job-call tracer generation span (tool-call-arguments call)))
                             ((member name coding-tool-names)
                              ((builtin-ref 'coding 'coding-execute)
                               name (tool-call-arguments call) (getcwd) ledger (current-turn)
                               (coding-context generation span)))
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
                      (emit-ui-tool-result!
                       ui-id name #f
                       (if (cancelled? key)
                           "Tool interrupted; recovery record retained."
                           (caught-error-detail key arguments)))
                      (trace-end!
                       span (if (cancelled? key) "CANCELLED" "ERROR")
                       `((error.message . ,(if (cancelled? key)
                                             "tool interrupted; recovery record retained"
                                             (caught-error-detail key arguments)))))
                      (apply throw key arguments))))
                 (ok? (tool-result-success? outcome))
                 (output (tool-result-output outcome)))
            (when ok? (record-observations! outcome))
            (set! turn-tool-events (append turn-tool-events (list (list name (json-write (tool-call-arguments call)) ok? output))))
            (echo-tool-result! generation ui-id name ok? output)
            (when (and ok? (member name mutation-tool-names))
              (emit-ui-diff! (current-turn)))
            (trace-end! span (if ok? "OK" "ERROR")
                        `((output.value . ,output)
                          ,@(if (assq call prefetched) '((tool.parallel . #t)) '())
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

(define (complete-with-trace tracer parent generation provider model base-url
                             api-key messages enabled-tools stream? thinking
                             keep-alive prompt-cache-key round
                             prompt-attributes effort fast? reserve)
  (let* ((generation-id (generation-id generation))
        (span
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
        (content-started? #f)
        (ui-stream-role #f)
        (retries '()))
    ;; Each retry is shown as work and recorded on the span; the pause
    ;; itself happens in the transport.
    (define (on-retry attempt reason delay)
      (set! retries (cons (format #f "~a@~as" reason (/ delay 1000.0)) retries))
      (when (setting-ref generation 'show-work)
        (format (tool-echo-port) "provider ~a · retrying in ~as (attempt ~a of ~a)~%"
                reason (/ delay 1000.0) (+ attempt 1) (+ (provider-retry-limit) 1))
        (force-output (tool-echo-port))))
    (define (retry-attributes)
      (if (null? retries) '()
          `((llm.retries . ,(length retries))
            (llm.retry_log . ,(string-join (reverse retries) ",")))))
    (define (finish-ui-stream!)
      (when ui-stream-role
        (emit-ui-transcript! ui-stream-role "" #t #t)
        (set! ui-stream-role #f)))
    (define (ui-chunk! role chunk)
      (unless (equal? ui-stream-role role)
        (finish-ui-stream!)
        (set! ui-stream-role role))
      (emit-ui-transcript! role chunk #t))
    (define (on-thinking chunk)
      (unless print-mode?
        (unless thinking-started?
          (set! thinking-started? #t)
          (unless (ui-connected?) (display "thinking> ")))
        (if (ui-connected?)
            (ui-chunk! "thinking" chunk)
            (begin (display chunk) (force-output)))))
    (define (on-content chunk)
      (unless content-started?
        (set! content-started? #t)
        (unless (ui-connected?)
          (when thinking-started? (newline))
          (unless print-mode? (display "assistant> "))))
      (if (ui-connected?)
          (ui-chunk! "assistant" chunk)
          (begin (display chunk) (force-output))))
    (catch #t
      (lambda ()
        (let ((completion
               (parameterize ((current-retry-observer on-retry)
                              (provider-retry-limit
                               (setting-ref generation 'provider-retries))
                              (provider-context-limit (model-context-limit generation)))
                 (provider-complete
                  provider model base-url api-key messages enabled-tools
                  stream? thinking keep-alive prompt-cache-key
                  on-content on-thinking
                  effort fast? reserve))))
          (if (ui-connected?)
              (begin
                (finish-ui-stream!)
                (unless (or print-mode? thinking-started?
                            (string-null? (or (completion-thinking completion) "")))
                  (emit-ui-transcript! "thinking" (completion-thinking completion)))
                (unless (or content-started?
                            (string-null? (or (completion-content completion) "")))
                  (emit-ui-transcript! "assistant" (completion-content completion))))
              (when (or thinking-started? content-started?)
                (newline)
                (force-output)))
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
            (set! turn-rounds (+ turn-rounds 1))
            (when (ui-connected?)
              (emit-provider-metadata! generation)
              (emit-usage-snapshot! generation last-estimate
                                    (completion-usage completion) turn-rounds))
            (trace-end!
             span "OK"
             (append
              `((output.value . ,(or (completion-content completion) ""))
                (llm.thinking . ,(or (completion-thinking completion) "")))
              (retry-attributes)
              attributes)))
          (cons completion content-started?)))
      (lambda (key . arguments)
        (if (ui-connected?)
            (finish-ui-stream!)
            (when (or thinking-started? content-started?)
              (newline)
              (force-output)))
        (trace-end! span (if (cancelled? key) "CANCELLED" "ERROR")
                    `((error.type . ,(symbol->string key))
                      (error.message . ,(format #f "~s" arguments))
                      ,@(retry-attributes)))
        (apply throw key arguments)))))

;; One typed request per user turn names the skill that fits, if one does; the
;; list itself is unchanged and the model may still ignore the hint.
(define (skill-hint-block runtime generation line)
  (let ((endpoint (typed-endpoint generation))
        (skills (filter-map (lambda (s) (and (json-object-ref s "valid" #f) (json-object-ref s "model" #f)
                                             (cons (json-object-ref s "name" "") (json-object-ref s "description" ""))))
                            (json-array-items (skills-json)))))
    (if (and endpoint (pair? skills) (string? line) (not (string-prefix? "Note from the harness" line)))
        (let* ((started (get-internal-real-time))
               (name (catch #t (lambda () (typed-skill-hint (car endpoint) (cdr endpoint) (clip line 2000) skills)) (lambda _ #f)))
               (ms (quotient (* 1000 (- (get-internal-real-time) started)) internal-time-units-per-second)))
          (runtime-record! runtime 'skill-hint `((skill . ,(or name "none")) (candidates . ,(length skills)) (ms . ,ms)))
          (if name (skill-hint-line name) ""))
        "")))
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
                         (or (not (member name '("traces" "recall"))) (builtin-enabled? 'tracing))
                         (or (not (string=? name "spawn"))
                             (and (builtin-enabled? 'coding) spawn-session (< subagent-depth max-subagent-depth)))
                         (or (not (member name coding-tool-names)) (builtin-enabled? 'coding))))
                  configured-tools))
         (max-rounds
          (setting-ref generation 'agent-max-tool-rounds))
         (stream? (setting-ref generation 'agent-stream?))
         (thinking (setting-ref generation 'agent-thinking))
         (keep-alive (setting-ref generation 'agent-keep-alive))
         (system
          (make-message
           "system" (string-append (generation-ref generation 'agent-system-prompt) (skills-prompt-block) (field-notes-block (getcwd))
                                   (skill-hint-block runtime generation line) (mcp-prompt-block))))
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
         (user-message (make-message "user" (with-queued-skills transformed-line)))
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
    ;; Calibration belongs to this turn and its tool-bearing requests, not to
    ;; another model, a previous turn, or the separate summarizer request.
    (let loop ((messages (with-job-notices working)) (round 0)
               (previous-estimate #f) (previous-prompt #f))
      (define raw-estimate (estimate-input-tokens messages enabled-tools))
      (set! last-estimate
        (calibrate-input-estimate raw-estimate previous-estimate previous-prompt))
      (when (ui-connected?)
        (emit-usage-snapshot! generation last-estimate (json-object) turn-rounds))
      (when (context-over-budget? last-estimate (model-context-limit generation)
                                  (setting-ref generation 'output-reserve))
        (let* ((prefix (compaction-prefix history 4))
               (tail (drop messages (+ 1 (length history) (length context-messages)))))
          (when (null? prefix)
            (error "Context budget exceeded; current turn is too large to compact safely. Use /compact, /reset, or a larger /context limit."))
          (let* ((summary (or (notes-compaction! runtime tracer generation prefix) (summarize-compaction generation prefix)))
                 (compacted (compact-history-with-summary history summary 4)))
            (record-compaction! tracer generation prefix summary 4 "token-budget")
            (set! history compacted)
            (set! messages (append (list system) history context-messages tail))
            (set! raw-estimate (estimate-input-tokens messages enabled-tools))
            (set! last-estimate
              (calibrate-input-estimate raw-estimate previous-estimate previous-prompt))
            (runtime-record! runtime 'session-compacted
              `((reason . token-budget) (estimated-tokens . ,last-estimate)))
            (display "Compacted earlier turns before the request.\n")))
        (when (context-over-budget? last-estimate (model-context-limit generation)
                                    (setting-ref generation 'output-reserve))
          (error "Context still exceeds the budget; original checkpoint retained. Reduce input or increase /context limit.")))
      (let* ((outcome
              (complete-with-trace
               tracer parent generation
               provider model base-url api-key messages
               (append enabled-tools turn-mcp-tools) stream? thinking keep-alive prompt-cache-key round
               prompt-attributes (effective-effort generation) (effective-fast? generation)
               (setting-ref generation 'output-reserve)))
             (completion (car outcome))
             (prompt (assq-ref (usage-attributes completion) 'llm.token_count.prompt))
             (prompt-reported? (and (integer? prompt) (> prompt 0)))
             (content-streamed? (cdr outcome))
             (calls (completion-tool-calls completion))
             (with-assistant
              (append messages (list (completion-assistant-message completion)))))
        (if (null? calls)
            (let ((reply (or (completion-content completion) "")))
              (record-output! runtime generation turn-count reply)
              (unless (or (ui-connected?) content-streamed?)
                (unless (or print-mode? (string-null? (or (completion-thinking completion) "")))
                  (format #t "thinking> ~a~%" (completion-thinking completion)))
                (format #t "~a~a~%" (if print-mode? "" "assistant> ") reply))
              ;; Drop the runtime-owned system prompt and this turn's selected
              ;; context while retaining the prior history and new turn tail.
              (list
               (persist-provider-turn
                history (length context-messages) (without-ephemeral with-assistant))
               reply))
            (begin
              (when (>= round max-rounds)
                (runtime-record! runtime 'turn-limit
                                 `((reason . rounds) (rounds . ,max-rounds) (turn . ,turn-count)))
                ;; The turn fails, but its exchanges are kept so the next turn
                ;; knows what was read and run instead of starting blind.
                (throw 'turn-limit
                       (persist-provider-turn history (length context-messages) (without-ephemeral messages))
                       max-rounds))
              (let ((budget (setting-ref generation 'turn-token-budget)))
                (when (and budget (> turn-tokens budget))
                  (runtime-record! runtime 'turn-limit
                                   `((reason . tokens) (budget . ,budget) (used . ,turn-tokens)
                                     (turn . ,turn-count)))
                  (error "turn token budget exceeded" turn-tokens budget)))
              (loop
               (with-job-notices
                (with-limit-nudge
                runtime generation turn-count (+ round 1) max-rounds
                (execute-tool-calls
                 runtime tracer parent generation provider calls with-assistant
                 (append enabled-tools turn-mcp-tools))))
               (+ round 1)
               (if prompt-reported? raw-estimate previous-estimate)
               (if prompt-reported? prompt previous-prompt))))))))

;; Five of the six model misses on the first SWE-bench slice ended at the
;; round cap still exploring. Once per turn, when three rounds remain or the
;; token budget is 80% spent, a user message tells the model to finish. It
;; is marked ephemeral so it is sent for the rest of this turn but never
;; persisted into the session history.
(define (limit-nudge-reason generation next-round max-rounds)
  (let ((budget (setting-ref generation 'turn-token-budget))
        (rounds-left (- max-rounds next-round)))
    (cond
     ((= rounds-left 3) (format #f "~a tool rounds remain in this turn" rounds-left))
     ((and budget (> turn-tokens (* 0.8 budget)))
      (format #f "the turn's token budget is ~a% spent"
              (inexact->exact (round (* 100 (/ turn-tokens budget))))))
     (else #f))))

;; Finished background jobs reach the model as one ephemeral note at the next
;; provider request, in this turn or the next; the ledger has the record.
(define (with-job-notices messages)
  (let ((notices (if (builtin-enabled? 'coding) ((builtin-ref 'coding 'take-job-notices)) '())))
    (if (null? notices)
        messages
        (append messages
                (list (json-object (cons "role" "user") (cons "ephemeral" #t)
                                   (cons "content" (string-append "Note from the harness: " (string-join notices "; ")
                                                                  ". Use the job tool to read output you still need."))))))))
(define (with-limit-nudge runtime generation turn-count next-round max-rounds messages)
  (let ((reason (and (not turn-nudged?)
                     (limit-nudge-reason generation next-round max-rounds))))
    (if (not reason)
        messages
        (begin
          (set! turn-nudged? #t)
          (runtime-record! runtime 'turn-nudge
                           `((reason . ,reason) (round . ,next-round) (turn . ,turn-count)))
          (when (setting-ref generation 'show-work)
            (format (tool-echo-port) "shift> ~a; asked the model to finish~%" reason)
            (force-output (tool-echo-port)))
          (append messages
                  (list (json-object
                         (cons "role" "user")
                         (cons "ephemeral" #t)
                         (cons "content"
                               (string-append
                                "Note from the harness: " reason
                                ". Stop exploring and finish now. If you have a fix, make sure it is "
                                "written to the files, run the single most relevant test once if you "
                                "have not already, then reply with a summary of what you changed. "
                                "If you cannot finish, reply with what you found and what remains. "
                                "A turn that ends on a tool call is a failure.")))))))))

(define (without-ephemeral messages)
  (filter (lambda (message) (not (json-object-ref message "ephemeral" #f))) messages))

;; --- session notes -----------------------------------------------------------
;; Working notes are session state under notes/, written by the model through
;; the notes tool: during a turn when it wants, and when the window fills.
(define max-note-bytes (* 64 1024))
(define (notes-directory tracer) (string-append (runtime-state-directory tracer) "/notes"))
(define (notes-path tracer requested)
  (unless (and (string? requested) (not (string-null? requested)) (<= (string-length requested) 200)
               (not (string-prefix? "/" requested))
               (not (any (lambda (part) (member part '("" "." ".."))) (string-split requested #\/))))
    (error "notes path must be a relative file name such as plan.md" requested))
  (string-append (notes-directory tracer) "/" requested))
(define (notes-listing tracer)
  (let ((directory (notes-directory tracer)))
    (if (not (file-exists? directory)) '()
        (let walk ((prefix "") (dir directory))
          (append-map
           (lambda (name)
             (let ((path (string-append dir "/" name)))
               (if (eq? 'directory (stat:type (stat path)))
                   (walk (string-append prefix name "/") path)
                   (let ((text (call-with-input-file path get-string-all)))
                     (list (list (string-append prefix name) (length (string-split (string-trim-right text) #\newline)) (string-length text)))))))
           (sort (scandir dir (lambda (n) (not (member n '("." ".."))))) string<?))))))
(define (notes-signature tracer)
  (map (lambda (entry) (cons (car entry) (caddr entry))) (notes-listing tracer)))
(define (execute-notes tracer arguments)
  (catch #t
    (lambda ()
      (let ((action (json-object-ref arguments "action" "list")))
        (cond
         ((string=? action "list")
          (let ((entries (notes-listing tracer)))
            (make-tool-result #t (if (null? entries) "No notes yet."
                                     (string-join (map (lambda (e) (format #f "~a (~a lines, ~a bytes)" (car e) (cadr e) (caddr e))) entries) "\n")))))
         ((string=? action "read")
          (let ((path (notes-path tracer (json-object-ref arguments "path" #f))))
            (unless (file-exists? path) (error "no such note" (json-object-ref arguments "path" "")))
            (make-tool-result #t (call-with-input-file path get-string-all))))
         ((member action '("write" "append"))
          (let* ((path (notes-path tracer (json-object-ref arguments "path" #f)))
                 (text (json-object-ref arguments "text" #f)))
            (unless (string? text) (error "text is required"))
            (let ((existing (if (and (string=? action "append") (file-exists? path)) (stat:size (stat path)) 0)))
              (when (> (+ existing (string-length text)) max-note-bytes) (error "a note is limited to 64 KiB")))
            (ensure-note-folder! path)
            (let ((port (open-file path (if (string=? action "append") "a" "w"))))
              (display text port) (close-port port))
            (make-tool-result #t (format #f "~a ~a" (if (string=? action "write") "wrote" "appended to") (json-object-ref arguments "path" "")))))
         (else (error "action must be list, read, write or append" action)))))
    (lambda (key . arguments) (make-tool-result #f (error-text key arguments)))))
(define (ensure-note-folder! path)
  (let ((parent (dirname path)))
    (unless (file-exists? parent) (ensure-note-folder! parent) (mkdir parent))))
(define (compaction-count tracer)
  (let ((directory (string-append (runtime-state-directory tracer) "/compactions")))
    (if (file-exists? directory)
        (length (filter (lambda (n) (string-suffix? ".json" n)) (scandir directory (lambda (n) (not (member n '("." "..")))))))
        0)))
;; Compaction the agent does itself: before the window resets, one bounded
;; exchange asks it to save what the next window must know with the notes
;; tool. The reset then carries pointers to those files, not a summary.
;; Returns the pointer text, or #f when no note was written so the caller
;; falls back to a summary.
(define (notes-compaction! runtime tracer generation prefix)
  (if (string=? (setting-ref generation 'agent-model) "demo") #f
  (catch #t
    (lambda ()
      (let* ((window (+ 1 (compaction-count tracer)))
             (provider (setting-ref generation 'agent-provider))
             (key-environment (setting-ref generation 'agent-api-key-environment))
             (api-key (and key-environment (getenv key-environment)))
             (before (notes-signature tracer))
             (request (make-message "user"
                        (format #f "Context window ~a is full and will reset now. Save what the next window must know with the notes tool: progress, decisions, unresolved work, exact file paths and commands, and which earlier turns matter (traces and recall can find them later). Write or append files under notes, then reply with one line." window))))
        (let loop ((messages (append (list (make-message "system" (generation-ref generation 'agent-system-prompt))) prefix (list request)))
                   (round 0))
          (let* ((completion (provider-complete provider (setting-ref generation 'agent-model) (setting-ref generation 'agent-base-url) api-key
                                                messages '("notes") #f #f (setting-ref generation 'agent-keep-alive)
                                                (string-append "shift-" (generation-fingerprint generation) "-notes")
                                                (lambda _ #t) (lambda _ #t)))
                 (calls (completion-tool-calls completion)))
            (record-run-usage! (usage-attributes completion))
            (if (or (null? calls) (>= round 4))
                (and (not (equal? before (notes-signature tracer)))
                     (notes-pointer tracer window))
                (loop (append messages (list (completion-assistant-message completion))
                              (map (lambda (call)
                                     (make-tool-result-message provider (tool-call-id call) (tool-call-name call)
                                       (tool-result-output
                                        (if (string=? (tool-call-name call) "notes")
                                            (execute-notes tracer (tool-call-arguments call))
                                            (make-tool-result #f "only the notes tool is available while the window resets")))))
                                   calls))
                      (+ round 1)))))))
    (lambda (key . args)
      (format (current-error-port) "notes compaction skipped; summarizing instead: ~a~%" (error-text key args))
      #f))))
(define (notes-pointer tracer window)
  (string-append
   (format #f "Context window ~a was reset after these notes were saved:~%" window)
   (string-join (map (lambda (e) (format #f "- ~a (~a lines)" (car e) (cadr e))) (notes-listing tracer)) "\n")
   "\nRead them with the notes tool before continuing. Earlier turns are searchable with traces (this session) and recall (every session)."))
(define (notes-snapshot tracer)
  (apply json-object (map (lambda (e) (cons (car e) (call-with-input-file (string-append (notes-directory tracer) "/" (car e)) get-string-all)))
                          (notes-listing tracer))))

;; What a compaction replaced, beside the checkpoint: compactions/N.json holds
;; the prefix and the summary so the summary can be scored and re-summarized.
(define (record-compaction! tracer generation prefix summary keep-recent reason)
  (catch #t
    (lambda ()
      (let* ((directory (string-append (runtime-state-directory tracer) "/compactions"))
             (existing (if (file-exists? directory)
                           (length (filter (lambda (n) (string-suffix? ".json" n))
                                           (scandir directory (lambda (n) (not (member n '("." "..")))))))
                           0))
             (path (format #f "~a/~a.json" directory (+ existing 1))))
        (unless (file-exists? directory) (mkdir directory))
        (call-with-output-file path
          (lambda (port)
            (display (json-write (json-object (cons "at" (strftime "%Y-%m-%dT%H:%M:%SZ" (gmtime (current-time))))
                                              (cons "reason" reason) (cons "generation" (generation-id generation))
                                              (cons "keep_recent" keep-recent)
                                              (cons "prefix" (apply json-array prefix)) (cons "summary" summary)
                                              (cons "notes" (notes-snapshot tracer))))
                     port)
            (newline port)))
        path))
    (lambda (key . args)
      (format (current-error-port) "compaction record not written: ~a~%" (error-text key args)) #f)))
(define (compaction-replay! runtime path)
  (let* ((generation (runtime-current runtime))
         (record (call-with-input-file path (lambda (port) (json-read (get-string-all port)))))
         (prefix (let ((p (json-object-ref record "prefix" #f))) (if (json-array? p) (json-array-items p) '())))
         (summary (summarize-compaction generation prefix)))
    (display (json-write (json-object (cons "summary" summary) (cons "model" (format #f "~a/~a" (setting-ref generation 'agent-provider) (setting-ref generation 'agent-model))))))
    (newline) (force-output) 0))
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
                        (let* ((summary (or (notes-compaction! runtime tracer generation prefix)
                                            (summarize-compaction generation prefix)))
                               (compacted
                                (compact-history-with-summary
                                 history summary keep-recent)))
                          (record-compaction! tracer generation prefix summary keep-recent (if force? "manual" "threshold"))
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

;; The receipt is a projection of what the turn left behind: the ledger's
;; committed changes and run records for this turn, the usage counters, and
;; the span identities. It exists for completed, failed, and cancelled turns.
(define (build-turn-receipt tracer generation turn started status error span)
  (build-receipt
   #:turn turn #:status status #:error error
   #:model (setting-ref generation 'agent-model)
   #:provider (symbol->string (setting-ref generation 'agent-provider))
   #:generation (generation-id generation)
   #:duration-ms (inexact->exact
                  (round (* 1000 (/ (- (get-internal-real-time) started)
                                    internal-time-units-per-second))))
   #:usage `((prompt . ,turn-prompt-tokens) (cached . ,turn-cached-tokens)
             (uncached . ,turn-uncached-tokens) (completion . ,turn-completion-tokens)
             (rounds . ,turn-rounds))
   #:tool-calls turn-tool-calls
   #:ledger ledger
   #:skills (reverse turn-skills)
   #:mcp-tools turn-mcp-tools
   #:judge `((judged . ,turn-judged) (blocked . ,turn-blocked) (ms . ,turn-judge-ms) (asked . ,turn-judge-asked))
   #:trace-id (trace-trace-id span) #:span-id (trace-span-id span)
   #:session-name (tracer-session-name tracer)
   #:session-id (and (tracer-session-name tracer) (tracer-session-id tracer))))

(define (receipts-path tracer)
  (string-append (runtime-state-directory tracer) "/receipts.jsonl"))

;; Text to the terminal (stderr in print mode, so stdout stays the answer),
;; a JSON line in the session's receipts.jsonl, and the whole record to
;; --receipt FILE. A receipt that cannot be written never fails the turn.
(define (deliver-receipt! runtime tracer receipt)
  (set! last-receipt receipt)
  (emit-ui-diff! (assq-ref receipt 'turn))
  (ui-emit! "receipt" (receipt->json receipt))
  (when (and (not (ui-connected?)) (setting-ref (runtime-current runtime) 'show-work))
    (let ((port (if print-mode? (current-error-port) (current-output-port))))
      (display (receipt->text receipt) port)
      (force-output port)))
  (catch #t
    (lambda ()
      (receipt-append! (receipts-path tracer) receipt)
      (when cli-receipt-path (receipt-write! cli-receipt-path receipt)))
    (lambda (key . arguments)
      (format (current-error-port) "receipt not written: ~a~%"
              (caught-error-detail key arguments)))))

;; The last receipt of a resumed session comes from its receipts.jsonl.
(define (last-recorded-receipt tracer)
  (let ((path (receipts-path tracer)))
    (and (file-exists? path)
         (let ((lines (filter (lambda (line) (not (string-null? (string-trim-both line))))
                              (string-split (call-with-input-file path get-string-all) #\newline))))
           (and (pair? lines)
                (catch #t
                  (lambda () (receipt-from-json (json-read (last lines))))
                  (lambda _ #f)))))))

(define (show-receipt tracer)
  (let ((receipt (or last-receipt (last-recorded-receipt tracer))))
    (if receipt
        (display (receipt->text receipt))
        (display "No turn has completed in this session yet.\n"))))

(define (perform-turn! runtime tracer history line turn-count)
  (reset-turn-usage!)
  (ui-emit! "turn-start" (json-object (cons "turn" turn-count)))
  (when (ui-connected?)
    (let ((generation (runtime-current runtime)))
      (emit-usage-snapshot! generation
        (session-prompt-estimate generation (append history (list (make-message "user" line))))
        (json-object) 0)))
  (let* ((generation (runtime-current runtime))
         (started (get-internal-real-time))
         (span
          (trace-start!
           tracer "agent.turn" "AGENT"
           `((generation.id . ,(generation-id generation))
             (turn.number . ,turn-count)
             (input.value . ,line)))))
    (define (finish! status error attributes)
      (let ((receipt (build-turn-receipt tracer generation turn-count started status error span)))
        (trace-end! span
                    (cond ((string=? status "ok") "OK")
                          ((string=? status "cancelled") "CANCELLED")
                          (else "ERROR"))
                    (append attributes (receipt-attributes receipt)))
        (deliver-receipt! runtime tracer receipt)))
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
              (finish! "ok" #f `((output.value . ,(cadr new-history))))
              (list 'ok (car new-history))))
          (lambda (key . arguments)
            (cond
              ((cancelled? key)
                (runtime-record!
                 runtime 'turn-cancelled
                 `((generation . ,(generation-id generation))
                   (turn . ,turn-count)))
                (set! operation-status "cancelled")
                (display "turn cancelled; conversation state is unchanged.\n")
                (let ((reason (if (and (pair? arguments) (string? (car arguments))) (car arguments) "cancelled by user")))
                  (finish! "cancelled" reason `((error.message . ,reason))))
                #f)
              ((eq? key 'turn-limit)
                (let* ((kept (car arguments)) (limit (cadr arguments))
                       (detail (format #f "tool round limit reached: ~a rounds" limit))
                       (note (make-message "user"
                               (format #f "Note from the harness: turn ~a stopped at the tool round limit (~a) before an answer. The reads and runs above did happen; continue from them rather than repeating them."
                                       turn-count limit))))
                  (operation-failed! detail)
                  (format (current-error-port) "turn failed: ~a~%" detail)
                  (finish! "failed" detail `((error.message . ,detail)))
                  (list 'limited (append kept (list note)))))
              (else
                (let ((detail (format #f "~s: ~s" key arguments)))
                  (operation-failed! detail)
                  (format (current-error-port) "turn failed: ~a~%" detail)
                  (finish! "failed" (caught-error-detail key arguments)
                           `((error.message . ,detail)))
                  #f))))))
      (lambda () (set! turn-active? #f) (set! turn-thread #f)))))

(define mcp-running? #f)
(define mcp-http? (and (isatty? (current-input-port)) (not control-port)))
(define mcp-port 7331)
(define default-mcp-port 7331)
;; Read-only requests from MCP peers neither echo into the transcript nor flip
;; the session to WORKING; their output goes back to the peer.
(define peer-request? (make-parameter #f))
(define (transport-arguments args)
  (let loop ((remaining args) (out '()))
    (cond
      ((null? remaining) (reverse out))
      ((member (car remaining)
               '("--agent" "--state-dir" "--session" "--new-session" "--resume"
                 "--mode" "--model" "--allow-run" "--set" "--receipt"
                 "--print" "-p" "--fork-session"))
       (let* ((arity (if (string=? (car remaining) "--fork-session") 2 1))
              (count (min (+ arity 1) (length remaining))))
         (loop (drop remaining count)
               (append (reverse (take remaining count)) out))))
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
    (define (publish-session!)
      (trace-content (setting-ref (runtime-current runtime) 'trace-content))
      (when (ui-connected?)
        (let ((generation (runtime-current runtime)))
          (sync-ui-identity! generation)
          (unless last-ui-usage
            ;; Effective local settings are available before discovery, even
            ;; when the provider is offline or this is a resumed session.
            (emit-usage-snapshot! generation (session-prompt-estimate generation history)))
          (emit-provider-metadata! generation)
          (emit-usage-snapshot! generation #f)))
      (ui-emit! "session" (json-object
        (cons "model" (setting-ref (runtime-current runtime) 'agent-model))
        (cons "provider" (symbol->string (setting-ref (runtime-current runtime) 'agent-provider)))
        (cons "mcp" (if mcp-running? (format #f "http://127.0.0.1:~a/mcp" mcp-port) json-null))
        (cons "mode" (symbol->string (setting-ref (runtime-current runtime) 'mode)))
        (cons "show_work" (setting-ref (runtime-current runtime) 'show-work))
        (cons "turn" turn-count) (cons "name" (if session (session-name session) "ephemeral"))
        (cons "runtime" runtime-version-label)))
      (emit-skills!) (emit-servers!) (emit-plugins!))
    (define (register-host!)
      (ui-host-handler!
        (lambda (command)
          (unless (host-command-allowed? command)
            (error "only /mode manual|plan|autopilot, /model list, /model PROVIDER/MODEL, /sessions, /pane run NAME, /skill NAME, or /mcp connect NAME is supported"))
          (unless (try-mutex lock) (error "Session busy; finish the turn or pending approval before changing mode or model"))
          (dynamic-wind
            (lambda () #t)
            (lambda ()
              (cond
                ((string-prefix? "/pane run " command)
                 (let ((parts (string-tokenize command)))
                   (run-pane! runtime (caddr parts) turn-count
                              (and (= (length parts) 4) (string->number (cadddr parts))))))
                ((string-prefix? "/skill " command)
                 (queue-skill! (trimmed-command-argument command "/skill ")))
                ((string-prefix? "/mcp connect " command)
                 (mcp-command! (trimmed-command-argument command "/mcp ")))
                ((string-prefix? "/plugin " command)
                 (plugin-command! runtime (trimmed-command-argument command "/plugin ")))
                ((string=? command "/sessions")
                 (unless session (error "session list needs a durable session"))
                 (format #f "~a durable sessions" (emit-sessions!)))
                ((string=? command "/workflow")
                 (format #f "~a workflows" (emit-workflows!)))
                ((string=? command "/model list")
                  (let ((ids (model-list! (runtime-current runtime) #f)))
                    (emit-models! (runtime-current runtime) ids)
                    (format #f "~a models available in the Model tab" (length ids))))
                (else
                  (let ((out (open-output-string)))
                    (parameterize ((current-output-port out))
                      (handle-preference-command runtime command))
                    (checkpoint! history turn-count)
                    (publish-session!)
                    (string-trim-both (get-output-string out))))))
            (lambda () (unlock-mutex lock))))))
    ;; One turn: the model, the receipt, then the improvement loop's look at it.
    (define (turn! prompt)
      (let ((result (perform-turn! runtime tracer history prompt turn-count)))
        (when result
          (set! history (compact-history! runtime tracer (cadr result) #f))
          (set! turn-count (+ turn-count 1)))
        (set! last-answer (last-assistant-text history))
        (when workflow-run-events (set! workflow-run-events (append workflow-run-events turn-tool-events)))
        (after-turn! runtime tracer prompt)
        result))
    (define (process! line)
      (publish-session!)
      (set! operation-status "ok") (set! operation-error #f) (set! operation-span #f)
      (when (and (ui-connected?) (not (peer-request?)) (not (string-null? (string-trim-both line))))
        (emit-control! "working"))
      (parameterize ((current-turn turn-count))
      (let ((action
             (cond
               ((string-null? (string-trim-both line)) 'continue)
               ((string-prefix? "/" line)
                (unless (peer-request?) (emit-ui-transcript! "user" line))
                (handle-command runtime tracer session line))
               (else
                 (remember-user-message! line)
                 (turn! line) 'continue))))
        ;; A command may hand back a prompt to run as a turn (/learn does).
        (when (and (pair? action) (eq? (car action) 'prompt))
          (turn! (cadr action)))
        ;; /workflow run hands back a name; each step is one ordinary turn here.
        (when (and (pair? action) (eq? (car action) 'workflow))
          (run-workflow! runtime tracer (cadr action)
            (lambda (prompt)
              (let ((result (turn! prompt)))
                (list (if result (car result) 'failed) (last-assistant-text history) last-receipt)))))
        (case (if (pair? action) 'continue action)
          ((reset) (set! history '()) (set! turn-count 1)
                   (set! last-ui-usage #f)
                   (display "Conversation state cleared.\n"))
          ((compact) (set! history (compact-history! runtime tracer history #t)))
          ((recover-retry)
           (let ((message (try-transition "tool recovery" (lambda () (retry-interrupted-tool! runtime tracer)))))
             (when message (set! history (append history (list message))))))
          ((recover-restore)
           (try-transition "mutation restore" (lambda () (restore-interrupted-mutation! runtime tracer))))
          ((undo)
           (let ((message (try-transition "undo" (lambda () (undo-last-turn! runtime)))))
             (when message (set! history (append history (list message)))))))
        (checkpoint! history turn-count)
        (publish-session!)
        action)))
    (define (dispatch method argument)
      (if (eq? method 'peer)
          (begin (ui-emit! "peer" argument) #t)
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
            (cons "busy" turn-active?) (cons "settings" (settings-object (runtime-current runtime)))
            (cons "servers" (mcp-servers-json)))
          (begin
            (unless (and (string? argument) (<= (string-length argument) 262144)) (error "invalid input"))
            (when (and (eq? method 'prompt) (string-prefix? "/" argument))
              (error "shift_prompt accepts prompts; use shift_inspect for read-only commands"))
            (when (and (eq? method 'inspect)
                       (not (or (member argument '("/show" "/settings" "/context" "/session" "/generations" "/traces" "/extensions" "/receipt"))
                                (string-prefix? "/trace " argument) (string-prefix? "/traces " argument))))
              (error "command is not read-only; change settings in the terminal"))
            (unless (try-mutex lock) (error "session busy; retry after the active operation finishes"))
            (dynamic-wind
              (lambda () #t)
              (lambda ()
                (let ((output (open-output-string)))
                  (parameterize ((current-output-port output) (current-error-port output) (interactive-approval? #f)
                                 (peer-request? (eq? method 'inspect)))
                    (process! argument))
                  (when (not (string=? operation-status "ok")) (error "session operation failed" (get-output-string output)))
                  (get-output-string output)))
              (lambda () (unlock-mutex lock))))))))
    (register-host!)
    (publish-session!)
    (ui-emit! "history" (apply json-array (take-right history (min 50 (length history)))))
    (let ((stop-mcp!
            (if (and mcp-http? (builtin-enabled? 'mcp))
                ;; The default port falls forward so several live sessions can
                ;; coexist; an explicit other port must be exactly available.
                (let try ((port mcp-port) (remaining (if (= mcp-port default-mcp-port) 10 1)))
                  (catch #t
                    (lambda ()
                      (let ((stop ((builtin-ref 'mcp 'start-mcp!) port dispatch)))
                        (set! mcp-port port) (set! mcp-running? #t)
                        (publish-session!)
                        stop))
                    (lambda _
                      (if (> remaining 1)
                          (try (+ port 1) (- remaining 1))
                          (error "MCP port unavailable; choose --mcp-port PORT or --no-mcp" port)))))
                (lambda () #t))))
      (dynamic-wind
        (lambda () #t)
        (lambda ()
          (begin
                (unless (or print-mode? (ui-connected?))
                  (show-banner runtime watch? session)
                  (show-model (runtime-current runtime))
                  (when (and mcp-http? (builtin-enabled? 'mcp))
                    (format #t "MCP http://127.0.0.1:~a/mcp · live process ~a~%" mcp-port (getpid)))
                  (force-output))
                (when (ui-connected?) (catch #t (lambda () (emit-workflows!) (watch-workflows!)) (lambda _ #f)))
                (when cli-judge-replay (exit (judge-replay! runtime cli-judge-replay)))
                (when cli-compaction-replay (exit (compaction-replay! runtime cli-compaction-replay)))
                (when initial-prompt
                  (with-mutex lock
                    ;; Print mode has no one to ask: anything needing approval
                    ;; is denied without a prompt, so stdout stays the answer.
                    (parameterize ((interactive-approval? (not print-mode?)))
                      (process! initial-prompt))))
                (if print-mode?
                    ;; Exit status is the turn outcome: 0 completed, 1 failed
                    ;; or cancelled. Harness errors exit 2 before this point.
                    (if (string=? operation-status "ok") 0 1)
                ;; Piped input is read unbuffered so nothing typed ahead is
                ;; lost in this process's buffer when /upgrade execs the next one.
                (begin
                (unless (isatty? (current-input-port)) (setvbuf (current-input-port) 'none))
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
                      (else (display "Session busy with an MCP operation.\n") (loop)))))))))
        (lambda () (ui-host-handler! #f) (stop-mcp!))))))

(define (main args)
  (reset-run-usage!)
  (set! process-arguments args)
  ;; The launcher prepends --agent and --state-dir; the subcommand follows them.
  (let ((at (list-index (lambda (a) (string=? a "plugin")) args)))
   (when (and at (< (+ at 1) (length args)) (member (list-ref args (+ at 1)) '("add" "update" "list")))
    (catch #t (lambda () (plugin-cli! (drop args (+ at 1))) (exit 0))
      (lambda (key . a) (if (eq? key 'quit) (apply throw key a) (begin (format (current-error-port) "plugin: ~a~%" (error-text key a)) (exit 2)))))))
  (call-with-values
      (lambda () (parse-arguments (transport-arguments args)))
    (lambda (agent-path state-directory watch? requested-session-name session-mode
             list? initial-prompt fork-parent fork-child)
      (when print-mode?
        (unless (or initial-prompt cli-judge-replay cli-compaction-replay) (error "--print needs a task"))
        (set! watch? #f)
        (set! mcp-http? #f))
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
      (when (and (not requested-session-name) (or (getenv "SHIFT_UI_EVENT_FD") (isatty? (current-input-port))) (or (getenv "SHIFT_UI_EVENT_FD") (not control-port)))
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
                        (getenv "PHOENIX_COLLECTOR_ENDPOINT"))
                    (and session (session-id session))
                    (and session (session-name session))))))
        (unless runtime (exit 1))
        (set! ledger (open-ledger runtime-state-directory))
        (settings-init! state-directory (and session runtime-state-directory))
        (trace-content (setting-ref (runtime-current runtime) 'trace-content))
        (set! runtime-version-label (install-version (getenv "SHIFT_INSTALL_ROOT")))
        (trace-runtime-version! runtime-version-label)
        (ui-init! state-directory (and session runtime-state-directory))
        (skills-init! (or (getenv "SHIFT_PROJECT_ROOT") (getcwd)) (setting-ref #f 'skill-dirs))
        (workflows-init! (getcwd) (list (cons "user" (user-workflows-directory))))
        (mcp-init! (or (getenv "SHIFT_PROJECT_ROOT") (getcwd))
                   (string-append (or (getenv "XDG_CONFIG_HOME") (string-append (getenv "HOME") "/.config")) "/shift")
                   supported-tool-names
                   (string-append (or (getenv "SHIFT_PROJECT_ROOT") (getcwd)) "/.env"))
        (external-tool-schema mcp-tool-schema)
        (set! runtime-state-directory-for-judge (and session runtime-state-directory))
        (set! spawn-session session)
        (set! spawn-state-directory state-directory)
        (set! spawn-agent-path agent-path)
        (when session (honor-session-authority! (session-directory session)))
        (set! session-remotes
          (catch #t (lambda () (let ((r ((builtin-ref 'coding 'run-argv) '("git" "remote" "-v"))))
                                 (if (eqv? (car r) 0) (string-trim-both (cdr r)) "")))
                 (lambda _ "")))
        (mcp-tool-hints (@ (live-agent mcp-client) mcp-tool-hints))
        (when (builtin-enabled? 'coding)
          ((builtin-ref 'coding 'job-observer!)
           (lambda (event)
             (ui-emit! "job" event)
             (when (and (equal? (json-object-ref event "event") "finished") (string? (json-object-ref event "agent" #f)))
               (finish-child-span! (json-object-ref event "id") (json-object-ref event "status" "") (json-object-ref event "ok" #f)))
             (let ((pane (json-object-ref event "pane" #f)))
               (when (and (string? pane) (equal? (json-object-ref event "event") "finished"))
                 ;; The pane row and the Log tab parse the same header a foreground run prints.
                 (let* ((tail (json-object-ref event "tail" ""))
                        (status (json-object-ref event "status" "exit")) (code (json-object-ref event "code" 0))
                        (status-text (cond ((equal? status "exit") (format #f "exit ~a" code))
                                           ((equal? status "signal") (format #f "killed by signal ~a" code))
                                           ((equal? status "timeout") (format #f "timeout after ~as (killed)" code))
                                           (else status)))
                        (excerpt (ui-output-excerpt
                                  (format #f "run ~a · ~a · ~as · ~a lines · log ~a~%~a"
                                          (string-join (json-array-items (json-object-ref event "argv" (json-array))) " ")
                                          status-text (/ (round (/ (json-object-ref event "elapsed_ms" 0) 100.0)) 10.0)
                                          (length (filter (lambda (l) (not (string-null? l))) (string-split tail #\newline)))
                                          (json-object-ref event "log" "") tail))))
                   (ui-emit! "pane-output"
                     (json-object (cons "pane" pane) (cons "index" (json-object-ref event "index" 0))
                                  (cons "argv" (json-object-ref event "argv" (json-array)))
                                  (cons "ok" (json-object-ref event "ok" #f))
                                  (cons "output" (car excerpt)) (cons "truncated" (cdr excerpt))
                                  (cons "at" (strftime "%H:%M" (localtime (current-time))))))))))))
        (read-roots skill-directories)
        (load-dotenv! (string-append (getcwd) "/.env"))
        ;; SHIFT_PLUGINS=off runs without any plugin, which fixtures rely on.
        (if (member (getenv "SHIFT_PLUGINS") '("off" ""))
            (plugins-init! #f #f #f '())
            (plugins-init! (or (getenv "SHIFT_INSTALL_ROOT") (getcwd)) (or (getenv "SHIFT_PROJECT_ROOT") (getcwd))
                           (string-append (or (getenv "XDG_CONFIG_HOME") (string-append (getenv "HOME") "/.config")) "/shift")
                           (setting-ref #f 'plugin-dirs)))
        (catch #t (lambda () (apply-plugins! runtime))
          (lambda (key . args) (format (current-error-port) "plugins: ~a~%" (error-text key args))))
        (unless (try-transition "startup options" apply-cli-overrides!)
          (exit 2))
        (input-init! state-directory)
        (when (ui-connected?)
          (ui-emit! "input-history" (apply json-array (input-history))))
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
          (let ((outcome
                 (dynamic-wind
                   (lambda () #t)
                   (lambda ()
                     (when (recovery-read runtime-state-directory)
                       (display
                        "\n! interrupted tool record found; use /recover before continuing.\n"
                        (if print-mode? (current-error-port) (current-output-port))))
                     (repl runtime tracer watch? session checkpoint! initial-prompt))
                   (lambda ()
                     (stop-watcher!)
                     (when (builtin-enabled? 'coding) ((builtin-ref 'coding 'stop-jobs!) "killed by exit"))
                     (mcp-stop-all!)
                     (ui-stop!)
                     (trace-close! tracer)
                     (unless control-port
                       (if print-mode?
                           (with-output-to-port (current-error-port)
                             (lambda () (show-close-message session)))
                           (show-close-message session)))
                     (when session (close-session! session))))))
            (when print-mode?
              (exit (if (integer? outcome) outcome 1)))
            ;; The handoff: the checkpoint is written and every resource is
            ;; released, so the launcher can start the current install on the
            ;; same pipes and session. Nothing survives from this image.
            (when (and upgrade-requested? session)
              (let ((launcher (string-append (or (getenv "SHIFT_INSTALL_ROOT") (getcwd)) "/bin/shift-agent"))
                    (arguments (upgrade-arguments process-arguments (session-name session))))
                (force-output (current-output-port)) (force-output (current-error-port))
                (apply execl launcher launcher arguments))))))))))
