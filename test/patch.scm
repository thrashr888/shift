(use-modules (srfi srfi-64) (srfi srfi-1) (live-agent patch))

(test-begin "patch")

(define (apply-text old patch)
  (apply-file-patch old (car (parse-patch patch))))

(define simple "--- a/x.txt\n+++ b/x.txt\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n")
(test-equal "single hunk replaces a line" "a\nB\nc\n" (apply-text "a\nb\nc\n" simple))
(test-equal "paths lose their a/ and b/ prefixes" "x.txt" (file-patch-old-path (car (parse-patch simple))))

(define two-hunks
  (string-append "--- a/x\n+++ b/x\n"
                 "@@ -1,2 +1,3 @@\n a\n+a2\n b\n"
                 "@@ -9,2 +10,2 @@\n i\n-j\n+J\n"))
(define ten (string-join (map string (string->list "abcdefghij")) "\n" 'suffix))
(test-equal "later hunks account for earlier insertions"
  "a\na2\nb\nc\nd\ne\nf\ng\nh\ni\nJ\n" (apply-text ten two-hunks))

(test-equal "hunks are found at an offset when lines moved"
  "x\ny\na\nB\nc\n" (apply-text "x\ny\na\nb\nc\n" simple))

(test-equal "create from /dev/null"
  "new\nfile\n" (apply-text #f "--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1,2 @@\n+new\n+file\n"))
(test-assert "delete to /dev/null leaves nothing"
  (let ((file (car (parse-patch "--- a/n.txt\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-new\n-file\n"))))
    (and (not (file-patch-new-path file))
         (string=? "" (apply-file-patch "new\nfile\n" file)))))

(test-equal "missing trailing newline is preserved"
  "a\nB" (apply-text "a\nb" "--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n a\n-b\n+B\n\\ No newline at end of file\n"))
(test-equal "a patch can add the trailing newline"
  "a\nb\n" (apply-text "a\nb" "--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n a\n-b\n\\ No newline at end of file\n+b\n"))
(test-equal "carriage returns are literal content"
  "a\r\nB\r\n" (apply-text "a\r\nb\r\n" "--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n a\r\n-b\r\n+B\r\n"))
(test-equal "blank context lines may be empty strings"
  "a\n\nC\n" (apply-text "a\n\nc\n" "--- a/x\n+++ b/x\n@@ -1,3 +1,3 @@\n a\n\n-c\n+C\n"))

(define git-style
  (string-append "diff --git a/x b/x\nindex 111..222 100644\n--- a/x\t2026-09-06\n+++ b/x\t2026-09-07\n"
                 "@@ -1 +1 @@\n-old\n+new\n"))
(test-equal "git headers and timestamps are tolerated" "new\n" (apply-text "old\n" git-style))

(define multi
  (string-append "--- a/one\n+++ b/one\n@@ -1 +1 @@\n-1\n+one\n"
                 "--- a/two\n+++ b/two\n@@ -1 +1 @@\n-2\n+two\n"))
(test-equal "multi-file patches parse every section" '("one" "two")
  (map file-patch-old-path (parse-patch multi)))

(test-error "context mismatch is rejected without fuzz" #t
  (apply-text "a\nX\nc\n" simple))
(test-assert "the mismatch names the hunk, line, and content"
  (catch #t
    (lambda () (apply-text "a\nX\nc\n" simple) #f)
    (lambda (key . args)
      (let ((message (apply format #f (cadr args) (caddr args))))
        (and (string-contains message "hunk 1 does not match x.txt")
             (string-contains message "expected \"b\", found \"X\""))))))
(test-error "short hunk bodies are rejected" #t
  (parse-patch "--- a/x\n+++ b/x\n@@ -1,3 +1,3 @@\n a\n-b\n"))
(test-error "hunk headers must be well formed" #t
  (parse-patch "--- a/x\n+++ b/x\n@@ nonsense @@\n a\n"))
(test-error "a missing +++ line is rejected" #t
  (parse-patch "--- a/x\n@@ -1 +1 @@\n-a\n+b\n"))
(test-error "prose without sections is rejected" #t (parse-patch "just some text\n"))
(test-error "a section without hunks is rejected" #t (parse-patch "--- a/x\n+++ b/x\n"))

(test-end "patch")
