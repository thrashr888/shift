(define-module (live-agent settings)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (live-agent json)
  #:use-module (live-agent redact)
  #:use-module (live-agent generation)
  #:export (settings-init! setting-ref setting-set! setting-set-json! settings-set! settings-save!
            settings-show settings-object setting-source load-dotenv! read-dotenv
            allow-run! deny-run! run-allow-entries allow-mcp! deny-mcp! mcp-allow-entries
            allow-plugin-set! plugin-enabled? set-plugin-state! plugin-states))

;; Data only: never evaluate persisted preferences as Scheme. Live image code
;; cannot access this module or change the process-owned execution mode.
(define (assq-delete-all key entries) (filter (lambda (p) (not (eq? (car p) key))) entries))
(define preferences '())
(define sources '())
;; The run allowlist is the one setting that unions across scopes instead of
;; the nearest scope replacing the rest: a prefix allowed for the user, the
;; project (committable .shift/settings.json) or this session all count.
(define project-file #f)
(define session-file #f)
(define user-file #f)
(define allow-keys '(run-allow mcp-allow))
(define (empty-allow-lists) (map (lambda (key) (cons key '((user . ()) (project . ()) (session . ()) (plugin . ())))) allow-keys))
;; plugins: {"name": true|false} per scope; session over user over project;
;; a plugin nobody mentioned is on.
(define plugin-states '((user . ()) (project . ()) (session . ())))
(define (plugin-enabled? name)
  (let loop ((scopes '(session user project)))
    (if (null? scopes)
        #t
        (let ((entry (assoc name (or (assq-ref plugin-states (car scopes)) '()))))
          (if entry (cdr entry) (loop (cdr scopes)))))))
(define (set-plugin-state! name on? scope)
  (unless (memq scope '(user project session)) (error "scope must be user, project or session" scope))
  (let* ((current (or (assq-ref plugin-states scope) '()))
         (next (acons name on? (filter (lambda (e) (not (equal? (car e) name))) current)))
         (path (scope-file scope))
         (encoded (apply json-object (map (lambda (e) (cons (car e) (cdr e))) next))))
    (when path (write-settings path (acons 'plugins encoded (assq-delete-all 'plugins (file-entries path)))))
    (set! plugin-states (acons scope next (assq-delete-all scope plugin-states)))
    next))
(define allow-lists (empty-allow-lists))
(define (allow-list key scope) (or (assq-ref (assq-ref allow-lists key) scope) '()))
(define* (allow-scope-set! scope prefixes #:optional (key 'run-allow))
  (let ((scopes (acons scope prefixes (assq-delete-all scope (assq-ref allow-lists key)))))
    (set! allow-lists (acons key scopes (assq-delete-all key allow-lists)))))
;; The plugin scope is in memory only: enabled plugins' proposals, refreshed
;; whenever plugins are applied, never written to a file.
(define (union-allow-lists key)
  (fold (lambda (scope acc)
          (fold (lambda (prefix acc) (if (member prefix acc) acc (append acc (list prefix))))
                acc (allow-list key scope)))
        '() '(user project session plugin)))
(define (allow-plugin-set! key entries)
  (allow-scope-set! 'plugin entries key)
  (refresh-run-allow! key))
(define* (refresh-run-allow! #:optional (key 'run-allow))
  (set! preferences (acons key (union-allow-lists key) (assq-delete-all key preferences))))
(define (scope-file scope)
  (case scope ((user) user-file) ((project) project-file) ((session) session-file) (else #f)))
(define (file-entries path)
  (if (and path (file-exists? path))
      (let ((value (call-with-input-file path (lambda (p) (json-read (get-string-all p))))))
        (map (lambda (entry) (cons (string->symbol (car entry)) (decode (string->symbol (car entry)) (cdr entry))))
             (json-object-entries value)))
      '()))
;; (allow-run! prefix scope) persists an argv prefix at that scope and makes
;; it effective at once; session prefixes go to the session file like every
;; other preference, project and user ones touch only run-allow in their file.
(define (allow-entry! key prefix scope)
  (unless (valid? key (list prefix))
    (error (if (eq? key 'run-allow) "an allowlist prefix is a non-empty argv" "an MCP allowlist entry is SERVER__TOOL") prefix))
  (unless (memq scope '(user project session)) (error "scope must be user, project or session" scope))
  (let ((current (allow-list key scope)))
    (unless (member prefix current)
      (let ((next (append current (list prefix))) (path (scope-file scope)))
        (cond
         ((eq? scope 'session)
          (when path (write-settings path (acons key next (assq-delete-all key (file-entries path))))))
         (else
          (unless path (error "no settings file for scope" scope))
          (write-settings path (acons key next (assq-delete-all key (file-entries path))))))
        (allow-scope-set! scope next key)
        (refresh-run-allow! key)))
    (allow-list key scope)))
(define (allow-run! prefix scope) (allow-entry! 'run-allow prefix scope))
(define (allow-mcp! name scope) (allow-entry! 'mcp-allow name scope))
;; (deny-run! prefix) removes a prefix from every scope that holds it,
;; rewriting those files, and reports the scopes it left.
(define (deny-entry! key prefix)
  (let ((removed (filter (lambda (scope) (member prefix (allow-list key scope))) '(user project session))))
    (when (null? removed) (error "that entry is not in the allowlist" prefix))
    (for-each (lambda (scope)
                (let ((next (delete prefix (allow-list key scope))) (path (scope-file scope)))
                  (when path (write-settings path (acons key next (assq-delete-all key (file-entries path)))))
                  (allow-scope-set! scope next key)))
              removed)
    (refresh-run-allow! key)
    removed))
(define (deny-run! prefix) (deny-entry! 'run-allow prefix))
(define (deny-mcp! name) (deny-entry! 'mcp-allow name))
;; Oldest scope first: ((entry . scope) ...) for listings.
(define* (allow-entries #:optional (key 'run-allow))
  (append-map (lambda (scope) (map (lambda (prefix) (cons prefix scope)) (allow-list key scope)))
              '(user project session plugin)))
(define (run-allow-entries) (allow-entries 'run-allow))
(define (mcp-allow-entries) (allow-entries 'mcp-allow))
;; SHIFT_PROVIDER_RETRIES sets the process-wide default so test harnesses can
;; make planned provider errors fail fast; the setting still wins.
(define default-provider-retries
  (let ((value (getenv "SHIFT_PROVIDER_RETRIES")))
    (or (and value (string->number value)) 3)))
(define defaults `((mode . manual) (effort . default) (fast . #f)
                   (context-limit . #f) (output-reserve . 8192)
                   (run-allow . ()) (mcp-allow . ()) (skill-dirs . ()) (plugin-dirs . ()) (run-backend . local) (run-sandbox . #f)
                   ;; Prefixes that stay on the host when runs go to the sandbox: macOS
                   ;; toolchains, signing, and git with the user's own keys.
                   (run-host . (("git") ("cargo" "tauri") ("codesign") ("xcodebuild") ("xcrun") ("notarytool")
                                ("open") ("swift") ("swiftc") ("brew")))
                   (judge . shadow) (judge-model . #f) (judge-ask-below . 0.5) (trace-content . full)
                   (turn-token-budget . #f) (show-work . #t) (token-prices . ())
                   ;; The self-improvement loop (docs/workflows-rfc.md): field notes the
                   ;; harness appends after a turn, and reflection after a hard one.
                   (field-notes . #t) (reflection . #t) (distillation . #t)
                   (provider-retries . ,default-provider-retries)))
(define bindings '(agent-provider agent-model agent-base-url agent-api-key-environment
                  agent-stream? agent-thinking agent-keep-alive agent-max-tool-rounds))
(define (valid? key value)
  (case key
    ((agent-max-tool-rounds) (and (integer? value) (>= value 0) (<= value 64)))
    ;; Retries of a provider request that failed with 429, 5xx, or a connection
    ;; error before any of the response was consumed.
    ((provider-retries) (and (integer? value) (>= value 0) (<= value 10)))
    ;; Cumulative uncached prompt plus completion tokens one turn may spend
    ;; before it is ended with a recorded reason.
    ((turn-token-budget) (or (not value) (and (integer? value) (>= value 1024))))
    ((agent-provider) (memq value '(ollama openai claude)))
    ((agent-model agent-base-url) (and (string? value) (not (string-null? value))))
    ((agent-api-key-environment) (or (not value) (string? value)))
    ;; show-work covers the per-call tool echo and the end-of-turn receipt text.
    ((agent-stream? fast show-work) (boolean? value))
    ((agent-thinking) (or (boolean? value) (memq value '(low medium high))))
    ((agent-keep-alive) (or (string? value) (number? value)))
    ((mode) (memq value '(manual plan autopilot)))
    ((effort) (memq value '(default low medium high max)))
    ((context-limit) (or (not value) (and (integer? value) (>= value 1024))))
    ((output-reserve) (and (integer? value) (>= value 1024) (<= value 65536)))
    ;; Exact argv prefixes the process may run without asking in accept/auto.
    ((run-allow run-host) (and (list? value)
                      (every (lambda (prefix)
                               (and (pair? prefix) (every (lambda (s) (and (string? s) (not (string-null? s)))) prefix)))
                             value)))
    ;; MCP tools a session may call without asking, as SERVER__TOOL names.
    ((mcp-allow) (and (list? value)
                      (every (lambda (name) (and (string? name) (string-contains name "__")
                                                 (string-every (lambda (c) (or (char-lower-case? c) (char-numeric? c) (memv c '(#\- #\_)))) name)))
                             value)))
    ;; Per-model rates in dollars per million tokens, as rows of
    ;; (PROVIDER MODEL-PREFIX input cache-read cache-write output). These
    ;; correct or extend the rates listed in (live-agent pricing), whose
    ;; built-in table goes stale as providers change their prices.
    ((token-prices)
     (and (list? value)
          (every (lambda (row)
                   (and (list? row) (= (length row) 6)
                        (memq (car row) '(ollama openai claude))
                        (string? (cadr row))
                        (every (lambda (rate) (and (real? rate) (>= rate 0))) (cddr row))))
                 value)))
    ;; Extra folders of skills, absolute paths, such as a checked-out skills kit.
    ((skill-dirs plugin-dirs) (and (list? value) (every (lambda (d) (and (string? d) (string-prefix? "/" d))) value)))
    ((plugins) (and (json-object? value) (every (lambda (e) (boolean? (cdr e))) (json-object-entries value))))
    ;; judge: off (autopilot asks for anything the rules leave), on (the judge decides in
    ;; autopilot), shadow (on, and manual records the judge's verdict beside yours).
    ((judge) (memq value '(off shadow on)))
    ;; trace-content: full, bounded (content clipped to 200 chars), off (names and timings only).
    ((trace-content) (memq value '(full bounded off)))
    ;; judge-model: PROVIDER/MODEL; typesafe/jev-1.13.0 is the typed judge (docs/jev-rfc.md).
    ((judge-model) (or (not value) (and (string? value) (string-index value #\/))))
    ;; judge-ask-below: in autopilot, an allow whose confidence is under this asks
    ;; you instead (blocks in print mode); #f never asks. Only typed judges report confidence.
    ((judge-ask-below) (or (not value) (and (real? value) (>= value 0) (<= value 1))))
    ((run-backend) (memq value '(local agentkernel)))
    ((field-notes reflection distillation) (boolean? value))
    ((run-sandbox) (or (not value) (and (string? value) (not (string-null? value)))))
    (else #f)))
(define (decode key value)
  (cond
   ((and (string? value) (memq key '(mode agent-provider agent-thinking effort run-backend judge trace-content)))
    (string->symbol value))
   ((and (memq key '(run-allow run-host)) (json-array? value))
    (map (lambda (prefix) (if (json-array? prefix) (json-array-items prefix) prefix))
         (json-array-items value)))
   ((and (memq key '(mcp-allow skill-dirs plugin-dirs)) (json-array? value)) (json-array-items value))
   (else value)))
(define (encoded value)
  (cond ((symbol? value) (symbol->string value))
        ((list? value) (apply json-array (map encoded value)))
        (else value)))
(define (ensure-directory path)
  (unless (file-exists? path)
    (ensure-directory (dirname path)) (mkdir path #o700)))
(define (write-settings path entries)
  (ensure-directory (dirname path))
  (let* ((port (mkstemp (string-append path ".XXXXXX")))
         (temporary (port-filename port)))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (display (json-write (apply json-object
                        (map (lambda (entry) (cons (symbol->string (car entry))
                                                   (encoded (cdr entry)))) entries))) port)
        (newline port) (close-port port) (rename-file temporary path))
      (lambda ()
        (unless (port-closed? port) (close-port port))
        (when (file-exists? temporary) (delete-file temporary))))))
(define (load-settings! path source)
  (when (file-exists? path)
    (when (> (stat:size (stat path)) 32768) (error "settings file too large" path))
    (let ((value (call-with-input-file path (lambda (p) (json-read (get-string-all p))))))
      (unless (json-object? value) (error "settings must be an object" path))
      (for-each
       (lambda (entry)
         (let* ((key (string->symbol (car entry))) (value (decode key (cdr entry))))
           (unless (valid? key value) (error "invalid setting" path key))
           (cond
            ((memq key allow-keys) (allow-scope-set! source value key) (refresh-run-allow! key)
             (set! sources (acons key source (assq-delete-all key sources))))
            ((eq? key 'plugins)
             (set! plugin-states (acons source (map (lambda (e) (cons (car e) (cdr e))) (json-object-entries value))
                                        (assq-delete-all source plugin-states))))
            (else
             (set! preferences (acons key value (assq-delete-all key preferences)))
             (set! sources (acons key source (assq-delete-all key sources)))))))
       (json-object-entries value)))))
(define (settings-init! project-state session-state)
  (set! preferences '()) (set! sources '())
  (set! allow-lists (empty-allow-lists))
  (set! plugin-states '((user . ()) (project . ()) (session . ())))
  (set! project-file (string-append project-state "/settings.json"))
  (set! session-file (and session-state (string-append session-state "/settings.json")))
  (set! user-file (string-append (or (getenv "XDG_CONFIG_HOME")
                                   (string-append (getenv "HOME") "/.config"))
                               "/shift/settings.json"))
  (load-settings! user-file 'user)
  (load-settings! project-file 'project)
  (when session-file (load-settings! session-file 'session)))
(define (setting-ref generation key)
  (let ((entry (assq key preferences)))
    (cond (entry (cdr entry))
          ((assq key defaults) => cdr)
          (else (generation-ref generation key)))))
(define (settings-object generation)
  (apply json-object
    (map (lambda (key) (cons (symbol->string key) (encoded (setting-ref generation key))))
         (append bindings (map car defaults)))))
(define (settings-set! entries)
  (for-each (lambda (entry)
              (unless (valid? (car entry) (cdr entry)) (error "invalid setting" (car entry)))) entries)
  (let* ((allow (assq-ref entries 'run-allow))
         (session-allow (if allow
                            ;; Prefixes already allowed at another scope are not copied into the session.
                            (filter (lambda (prefix) (not (or (member prefix (allow-list 'run-allow 'user))
                                                              (member prefix (allow-list 'run-allow 'project)))))
                                    allow)
                            (allow-list 'run-allow 'session)))
         (next (fold (lambda (entry acc)
                       (acons (car entry) (cdr entry) (assq-delete-all (car entry) acc)))
                     preferences entries)))
    ;; Only publish changes after durable storage succeeds.
    (when session-file
      (write-settings session-file (acons 'mcp-allow (allow-list 'mcp-allow 'session)
                                          (acons 'run-allow session-allow (assq-delete-all 'mcp-allow (assq-delete-all 'run-allow next))))))
    (when allow (allow-scope-set! 'session session-allow))
    (set! preferences next)
    (when allow (refresh-run-allow!))
    (for-each (lambda (entry)
                (set! sources (acons (car entry) 'session (assq-delete-all (car entry) sources)))) entries)))
(define (setting-set! key value) (settings-set! (list (cons key value))))
;; For --set KEY=JSON: the value is parsed as JSON and decoded like a file.
(define (setting-set-json! key text)
  (let ((value (catch #t (lambda () (json-read text))
                 (lambda _ (error "setting value must be JSON" key text)))))
    (setting-set! key (decode key value))))
(define (settings-save! generation scope)
  (let ((path (if (eq? scope 'user) user-file project-file)))
    ;; Saving promotes preferences, and the whole effective allowlist, to that scope.
    (write-settings path (map (lambda (entry) (cons (string->symbol (car entry))
                                                   (decode (string->symbol (car entry)) (cdr entry))))
                             (json-object-entries (settings-object generation))))
    (for-each (lambda (key)
                (allow-scope-set! scope (filter (lambda (e) (not (member e (allow-list key 'plugin)))) (setting-ref generation key)) key)
                (allow-scope-set! 'session '() key))
              allow-keys)
    (when session-file
      (write-settings session-file (acons 'mcp-allow '() (acons 'run-allow '() (assq-delete-all 'mcp-allow (assq-delete-all 'run-allow (file-entries session-file)))))))
    path))
(define (setting-source key)
  (or (assq-ref sources key) 'default))
(define (settings-show generation)
  (for-each
   (lambda (key)
     (format #t "~a ~a (~a)~%" key (setting-ref generation key)
             (setting-source key)))
   (append bindings (map car defaults))))

;; A deliberately small dotenv reader; no shell substitution or evaluation.
;; Returns ((NAME . VALUE) ...) in file order; the MCP client reads secrets
;; from here rather than from the process environment.
(define (read-dotenv path)
  (if (file-exists? path)
      (call-with-input-file path
        (lambda (port)
          (let loop ((line (get-line port)) (entries '()))
            (if (eof-object? line)
                (reverse entries)
                (let* ((line (string-trim-both line))
                       (line (if (string-prefix? "export " line) (substring line 7) line))
                       (equal (string-index line #\=)))
                  (if (and equal (not (string-prefix? "#" line)))
                      (let* ((name (string-trim-both (substring line 0 equal)))
                             (value (string-trim-both (substring line (+ equal 1)))))
                        (when (and (>= (string-length value) 2)
                                   (memv (string-ref value 0) '(#\" #\'))
                                   (char=? (string-ref value 0) (string-ref value (- (string-length value) 1))))
                          (set! value (substring value 1 (- (string-length value) 1))))
                        (loop (get-line port)
                              (if (and (not (string-null? name))
                                       (string-every (lambda (c) (or (char-alphabetic? c) (char-numeric? c) (char=? c #\_))) name))
                                  (cons (cons name value) entries)
                                  entries)))
                      (loop (get-line port) entries)))))))
      '()))
(define (load-dotenv! path)
  (for-each (lambda (entry)
              (register-secret! (car entry) (cdr entry))
              (unless (getenv (car entry)) (setenv (car entry) (cdr entry))))
            (read-dotenv path)))
