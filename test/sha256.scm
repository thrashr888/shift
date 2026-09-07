(use-modules (srfi srfi-64) (rnrs bytevectors) (live-agent sha256))

(test-begin "sha256")

(test-equal "empty input"
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  (sha256-string ""))
(test-equal "abc"
  "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  (sha256-string "abc"))
(test-equal "two-block message"
  "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
  (sha256-string "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))
(test-equal "55 bytes pads into one block"
  (sha256-bytevector (string->utf8 (make-string 55 #\a)))
  (sha256-string (make-string 55 #\a)))
(test-equal "64 bytes pads into a second block"
  "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"
  (sha256-string (make-string 64 #\a)))
(test-equal "multibyte text hashes its UTF-8 bytes"
  (sha256-bytevector (string->utf8 "λ shift"))
  (sha256-string "λ shift"))

(define path (string-append "/tmp/shift-sha256-" (number->string (getpid))))
(call-with-output-file path (lambda (port) (display "abc" port)))
(test-equal "file hash matches string hash" (sha256-string "abc") (sha256-file path))
(delete-file path)

(test-end "sha256")
