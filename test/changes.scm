(use-modules (srfi srfi-64) (srfi srfi-1) (ice-9 textual-ports)
             (live-agent diff) (live-agent changes) (live-agent sha256))

(test-begin "changes")

;; Unified diffs
(define modify (unified-diff "a\nb\nc\n" "a\nB\nc\nd\n" "a/x.txt" "b/x.txt"))
(test-assert "diff carries labels" (and (string-contains modify "--- a/x.txt")
                                         (string-contains modify "+++ b/x.txt")))
(test-equal "diffstat counts hunk lines only" '(2 . 1) (diffstat modify))
(test-equal "identical text yields an empty diff" "" (unified-diff "same\n" "same\n" "a/x" "b/x"))
(define create (unified-diff #f "new\n" "a/n.txt" "b/n.txt"))
(test-assert "create diffs from /dev/null" (string-contains create "--- /dev/null"))
(test-equal "create diffstat" '(1 . 0) (diffstat create))
(test-equal "diffstat formatting" "(+2 −1)" (format-diffstat '(2 . 1)))
(test-assert "content lines starting with dashes are counted, headers are not"
  (equal? '(1 . 1) (diffstat (unified-diff "--- x\n" "+++ y\n" "a/z" "b/z"))))
(define long (unified-diff "" (string-join (map number->string (iota 200)) "\n" 'suffix) "a/l" "b/l"))
(test-assert "preview truncates with a hint"
  (let ((preview (diff-preview long 20)))
    (and (string-contains preview "more lines")
         (< (length (string-split preview #\newline)) 25))))
(test-equal "short diffs preview unchanged" modify (diff-preview modify 100))

;; Ledger
(define root (string-append "/tmp/shift-changes-test-" (number->string (getpid))))
(system* "mkdir" "-p" root)
(define ledger (open-ledger root))
(define original "alpha\n")
(define updated "alpha\nbeta\n")

(test-assert "unseen files are never stale" (ledger-check-stale! ledger "a.txt" #f))
(ledger-observe! ledger 3 "a.txt" (sha256-string original))
(test-equal "observation records the turn" 3 (cdr (ledger-seen ledger "a.txt")))
(test-error "changed content after observation is stale" #t
  (ledger-check-stale! ledger "a.txt" (sha256-string "tampered\n")))
(test-assert "matching content is not stale"
  (ledger-check-stale! ledger "a.txt" (sha256-string original)))

(define seq (ledger-begin! ledger 4 "call_1" "edit" "a.txt" original updated))
(test-equal "begin stores the pre-image" original
  (ledger-read-blob ledger (sha256-string original)))
(test-equal "begin stores the post-image" updated
  (ledger-read-blob ledger (sha256-string updated)))
(test-equal "the started entry is open" seq (assq-ref (ledger-open-entry ledger) 'seq))
(test-equal "started entries are not turn changes" '() (ledger-turn-entries ledger 4))
(ledger-commit! ledger seq)
(test-assert "commit closes the entry" (not (ledger-open-entry ledger)))
(test-equal "commit updates last-seen to the post-image" (sha256-string updated)
  (car (ledger-seen ledger "a.txt")))
(test-equal "committed entry is a turn change" 1 (length (ledger-turn-entries ledger 4)))
(test-error "double commit is rejected" #t (ledger-commit! ledger seq))

(define created (ledger-begin! ledger 4 "call_2" "write" "b.txt" #f "fresh\n"))
(test-assert "creates record no pre-image" (not (assq-ref (ledger-open-entry ledger) 'before)))
(ledger-abort! ledger created)
(test-equal "aborted entries are not turn changes" 1 (length (ledger-turn-entries ledger 4)))

(define pending (ledger-begin! ledger 5 "call_3" "write" "c.txt" #f "half\n"))
(define reopened (open-ledger root))
(test-equal "replay restores entries" 3 (length (ledger-entries reopened)))
(test-equal "replay restores the open entry" pending (assq-ref (ledger-open-entry reopened) 'seq))
(test-equal "replay restores last-seen from commits" (sha256-string updated)
  (car (ledger-seen reopened "a.txt")))
(test-equal "replay continues the sequence" (+ pending 1)
  (ledger-begin! reopened 6 "call_4" "edit" "a.txt" updated original))

(let ((port (open-file (string-append root "/changes.jsonl") "a")))
  (display "{\"kind\":\"change\",\"seq\":" port)
  (close-port port))
(test-assert "a torn final line is skipped on replay" (ledger? (open-ledger root)))

(system* "rm" "-rf" root)
(test-end "changes")
