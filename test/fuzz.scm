;; Parsers of untrusted or user-authored text must reject or accept, never
;; crash the process or hang. Seeded, so a failure reproduces.
(use-modules (srfi srfi-64) (srfi srfi-1) (rnrs bytevectors)
             (live-agent json) (live-agent patch) (live-agent diff) (live-agent ui)
             (live-agent plugins) (live-agent mcp-client) (live-agent skills))

(test-begin "fuzz")

(define seed 20260916)
(define (rand n) (set! seed (modulo (+ (* seed 1103515245) 12345) 2147483648)) (modulo (quotient seed 65536) n))
(define specials (list->vector (string->list "()[]{}\"'`\\#;:.,-_ \n\t\r|*/+0123456789aZ~éλ")))
(define (random-text length)
  (list->string (list-tabulate length (lambda (_) (vector-ref specials (rand (vector-length specials)))))))
(define (mutate text)
  (let* ((n (string-length text)) (kind (rand 5)))
    (cond
     ((zero? n) (random-text 8))
     ((= kind 0) (substring text 0 (rand n)))                         ; truncate
     ((= kind 1) (let ((at (rand n))) (string-append (substring text 0 at) (random-text (+ 1 (rand 6))) (substring text at))))
     ((= kind 2) (let ((at (rand n))) (string-append (substring text 0 at) (substring text (min n (+ at 1 (rand 4)))))))
     ((= kind 3) (string-append text (random-text (rand 12))))
     (else (let ((at (rand n))) (string-append (substring text 0 at) (string (vector-ref specials (rand (vector-length specials)))) (substring text (min n (+ at 1)))))))))
(define (survives? thunk)
  ;; #t when the call returned or raised a Scheme condition; anything else
  ;; (a hang, a crash) never gets here.
  (catch #t (lambda () (thunk) #t) (lambda _ #t)))
(define (fuzz label seeds thunk-for)
  (let loop ((i 0) (text (car seeds)) (ok #t))
    (if (= i 400)
        (test-assert label ok)
        (let ((next (if (zero? (rand 4)) (list-ref seeds (rand (length seeds))) (mutate text))))
          (loop (+ i 1) next (and ok (survives? (lambda () (thunk-for next)))))))))

(fuzz "json-read never crashes"
      '("{\"a\":[1,2,{\"b\":null}],\"c\":\"x\\ny\"}" "[]" "\"\\u00e9\"" "12.5e3")
      (lambda (t) (json-read t)))
(fuzz "unified diffs never crash" '("one\ntwo\nthree\n" "")
      (lambda (t) (unified-diff t (mutate t) "a" "b")))
(define patch-seed "--- a/x.txt\n+++ b/x.txt\n@@ -1,2 +1,2 @@\n one\n-two\n+2\n")
(fuzz "patches parse or are refused" (list patch-seed)
      (lambda (t) (let ((patches (parse-patch t)))
                    (for-each (lambda (p) (apply-file-patch "one\ntwo\n" p)) patches))))
(fuzz "pane packs never crash" '("(pane \"shift\" \"Shift\" (text \"hi\") (command \"ls\" \"ls\" \"-la\"))")
      (lambda (t) (panes-pack->json t)))
(fuzz "plugin manifests never crash"
      '("(plugin \"demo\" (description \"d\") (requires \"ls\") (skills \"skills\") (allow-run \"git status\"))")
      (lambda (t) (parse-plugin-manifest t "/nonexistent" "test")))
(fuzz "mcp packs never crash"
      '("(server \"demo\" (command \"python3\" \"x.py\") (env \"TOKEN\"))" "(server \"h\" (url \"http://127.0.0.1:1/mcp\") (header \"A\" \"B\"))")
      (lambda (t) (parse-mcp-pack t "test")))
(fuzz "skill files never crash"
      '("---\nname: demo\ndescription: does things\n---\n# Demo\nsteps\n")
      (lambda (t) (parse-skill-file t)))

(test-end "fuzz")
