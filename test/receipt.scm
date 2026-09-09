(use-modules (srfi srfi-64) (srfi srfi-1) (ice-9 textual-ports)
             (live-agent receipt) (live-agent changes) (live-agent json) (live-agent sha256))

(test-begin "receipt")

(define root (string-append "/tmp/shift-receipt-test-" (number->string (getpid))))
(system* "mkdir" "-p" root)
(define ledger (open-ledger root))

;; Turn 4 edits one file, creates another, and runs two commands.
(define seq-edit (ledger-begin! ledger 4 "c1" "edit" "a.txt" "one\ntwo\n" "one\n2\nthree\n"))
(ledger-commit! ledger seq-edit)
(define seq-new (ledger-begin! ledger 4 "c2" "write" "new.txt" #f "fresh\n"))
(ledger-commit! ledger seq-new)
(define seq-aborted (ledger-begin! ledger 4 "c3" "edit" "b.txt" "x\n" "y\n"))
(ledger-abort! ledger seq-aborted)
(ledger-record-run! ledger 4
  (json-object (cons "invocation" (json-object (cons "mode" "local")
                                               (cons "input" (json-object (cons "command" (json-array "make" "check"))
                                                                          (cons "workdir" ".")))))
               (cons "outcome" (json-object (cons "exit_code" 0) (cons "success" #t)))
               (cons "status" "exit") (cons "duration_ms" 4800) (cons "log" "runs/run-4-1.log")))
(ledger-record-run! ledger 4
  (json-object (cons "invocation" (json-object (cons "mode" "agentkernel_exec")
                                               (cons "input" (json-object (cons "command" (json-array "pytest" "-x"))
                                                                          (cons "workdir" ".")))))
               (cons "outcome" (json-object (cons "exit_code" -1) (cons "success" #f)))
               (cons "status" "timeout") (cons "duration_ms" 120000) (cons "log" "runs/run-4-2.log")))
;; Another turn's run must not leak into turn 4.
(ledger-record-run! ledger 5
  (json-object (cons "invocation" (json-object (cons "mode" "local")
                                               (cons "input" (json-object (cons "command" (json-array "ls"))))))
               (cons "outcome" (json-object (cons "exit_code" 0) (cons "success" #t)))
               (cons "status" "exit") (cons "duration_ms" 10) (cons "log" "runs/run-5-1.log")))

(define receipt
  (build-receipt #:turn 4 #:status "ok" #:error #f #:model "claude-sonnet-5" #:provider "claude"
                 #:generation 3 #:duration-ms 6100
                 #:usage '((prompt . 2445) (cached . 1900) (uncached . 545) (completion . 611) (rounds . 4))
                 #:tool-calls '(("read" . 2) ("edit" . 1) ("write" . 1) ("run" . 2))
                 #:ledger ledger #:trace-id "3f9a1b2c3d4e5f60" #:span-id "8c21aa00bb11cc22"
                 #:session-name "dogfood" #:session-id "sess-1"))

(test-equal "committed changes of the turn, aborted ones excluded"
  '("a.txt" "new.txt") (map (lambda (c) (assq-ref c 'path)) (assq-ref receipt 'changed)))
(test-equal "diffstat comes from the stored images" '(2 . 1)
  (let ((change (car (assq-ref receipt 'changed))))
    (cons (assq-ref change 'added) (assq-ref change 'removed))))
(test-assert "a created file is marked" (assq-ref (cadr (assq-ref receipt 'changed)) 'created))
(test-equal "only this turn's runs" '(("make" "check") ("pytest" "-x"))
  (map (lambda (run) (assq-ref run 'command)) (assq-ref receipt 'runs)))
(test-assert "undo is available while the turn is undoable" (assq-ref receipt 'undo))
(test-equal "resume command names the session" "./bin/shift --resume dogfood" (assq-ref receipt 'resume))

(define text (receipt->text receipt))
(test-assert "text leads with turn, model, generation, rounds, and tokens"
  (string-prefix? "turn 4 · claude-sonnet-5 · generation 3 · 4 rounds · 2,445 in (1,900 cached) + 611 out · 6.1s" text))
(test-assert "text lists changed files with diffstat"
  (string-contains text "changed  a.txt (+2 −1)  new.txt (+1 −0) new"))
(test-assert "text lists each run with its outcome"
  (and (string-contains text "ran      make check  exit 0  4.8s")
       (string-contains text "ran      pytest -x  timeout  120.0s")))
(test-assert "text offers undo" (string-contains text "undo     available (/undo)"))
(test-assert "text ends with trace, span, and resume"
  (string-contains text "trace    3f9a1b2c… span 8c21aa00…   resume ./bin/shift --resume dogfood"))
(test-assert "a completed turn has no status line" (not (string-contains text "status   ")))

(define failed
  (build-receipt #:turn 5 #:status "failed" #:error "tool round limit reached" #:model "fake" #:provider "openai"
                 #:generation 1 #:duration-ms 0 #:usage '() #:tool-calls '() #:ledger ledger
                 #:trace-id #f #:span-id #f #:session-name #f #:session-id #f))
(define failed-text (receipt->text failed))
(test-assert "a failed turn carries its status and reason"
  (string-contains failed-text "status   failed · tool round limit reached"))
(test-assert "no changes reads as none" (string-contains failed-text "changed  none"))
(test-assert "untraced turns say so without a resume command"
  (string-contains failed-text "trace    none span none\n"))
(test-assert "nothing to undo without changes" (not (assq-ref failed 'undo)))

(define object (receipt->json receipt))
(test-equal "JSON tokens" 1900 (json-object-ref (json-object-ref object "tokens") "cached"))
(test-equal "JSON tool calls" 2 (json-object-ref (json-object-ref object "tool_calls") "run"))
(test-equal "JSON runs carry the agentkernel fields" -1
  (json-object-ref (cadr (json-array-items (json-object-ref object "runs"))) "exit_code"))
(test-equal "JSON round-trips" (json-write object)
  (json-write (receipt->json (receipt-from-json (json-read (json-write object))))))
(test-equal "failed JSON has a null trace" json-null (json-object-ref (receipt->json failed) "trace_id"))

(define attributes (receipt-attributes receipt))
(test-equal "span attributes count files" 2 (assq-ref attributes 'receipt.changed))
(test-equal "span attributes name files" "a.txt,new.txt" (assq-ref attributes 'receipt.files))
(test-equal "span attributes count failed runs" 1 (assq-ref attributes 'receipt.runs_failed))
(test-equal "span attributes total tool calls" 6 (assq-ref attributes 'receipt.tool_calls))

(define path (string-append root "/receipts.jsonl"))
(receipt-append! path receipt)
(receipt-append! path failed)
(test-equal "receipts.jsonl gains one line per turn" 2
  (length (filter (lambda (l) (not (string-null? l)))
                  (string-split (call-with-input-file path get-string-all) #\newline))))
(receipt-write! (string-append root "/one.json") failed)
(test-equal "--receipt FILE holds one whole record" 5
  (json-object-ref (json-read (call-with-input-file (string-append root "/one.json") get-string-all)) "turn"))

(test-end "receipt")
