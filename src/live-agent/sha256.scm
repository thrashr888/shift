;; SHA-256 (FIPS 180-4) in pure Scheme. Guile ships no digest module, and the
;; change ledger needs a collision-resistant, user-visible hash that matches
;; what `shasum -a 256`, Git tooling, and agentkernel receipts print.
(define-module (live-agent sha256)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 binary-ports)
  #:export (sha256-bytevector sha256-string sha256-file))

(define k
  #(#x428a2f98 #x71374491 #xb5c0fbcf #xe9b5dba5 #x3956c25b #x59f111f1 #x923f82a4 #xab1c5ed5
    #xd807aa98 #x12835b01 #x243185be #x550c7dc3 #x72be5d74 #x80deb1fe #x9bdc06a7 #xc19bf174
    #xe49b69c1 #xefbe4786 #x0fc19dc6 #x240ca1cc #x2de92c6f #x4a7484aa #x5cb0a9dc #x76f988da
    #x983e5152 #xa831c66d #xb00327c8 #xbf597fc7 #xc6e00bf3 #xd5a79147 #x06ca6351 #x14292967
    #x27b70a85 #x2e1b2138 #x4d2c6dfc #x53380d13 #x650a7354 #x766a0abb #x81c2c92e #x92722c85
    #xa2bfe8a1 #xa81a664b #xc24b8b70 #xc76c51a3 #xd192e819 #xd6990624 #xf40e3585 #x106aa070
    #x19a4c116 #x1e376c08 #x2748774c #x34b0bcb5 #x391c0cb3 #x4ed8aa4a #x5b9cca4f #x682e6ff3
    #x748f82ee #x78a5636f #x84c87814 #x8cc70208 #x90befffa #xa4506ceb #xbef9a3f7 #xc67178f2))

(define mask #xffffffff)

(define (rotr x n)
  (logand mask (logior (ash x (- n)) (ash x (- 32 n)))))

(define (add32 . values)
  (logand mask (apply + values)))

(define (pad message)
  (let* ((length (bytevector-length message))
         (bit-length (* 8 length))
         (padded-length (* 64 (quotient (+ length 9 63) 64)))
         (padded (make-bytevector padded-length 0)))
    (bytevector-copy! message 0 padded 0 length)
    (bytevector-u8-set! padded length #x80)
    (bytevector-u64-set! padded (- padded-length 8) bit-length (endianness big))
    padded))

(define (sha256-bytevector message)
  (let ((padded (pad message))
        (w (make-vector 64 0))
        (h0 #x6a09e667) (h1 #xbb67ae85) (h2 #x3c6ef372) (h3 #xa54ff53a)
        (h4 #x510e527f) (h5 #x9b05688c) (h6 #x1f83d9ab) (h7 #x5be0cd19))
    (let block-loop ((offset 0))
      (when (< offset (bytevector-length padded))
        (do ((i 0 (+ i 1))) ((= i 16))
          (vector-set! w i (bytevector-u32-ref padded (+ offset (* 4 i)) (endianness big))))
        (do ((i 16 (+ i 1))) ((= i 64))
          (let* ((w15 (vector-ref w (- i 15)))
                 (w2 (vector-ref w (- i 2)))
                 (s0 (logxor (rotr w15 7) (rotr w15 18) (ash w15 -3)))
                 (s1 (logxor (rotr w2 17) (rotr w2 19) (ash w2 -10))))
            (vector-set! w i (add32 (vector-ref w (- i 16)) s0 (vector-ref w (- i 7)) s1))))
        (let round-loop ((i 0) (a h0) (b h1) (c h2) (d h3) (e h4) (f h5) (g h6) (h h7))
          (if (= i 64)
              (begin
                (set! h0 (add32 h0 a)) (set! h1 (add32 h1 b))
                (set! h2 (add32 h2 c)) (set! h3 (add32 h3 d))
                (set! h4 (add32 h4 e)) (set! h5 (add32 h5 f))
                (set! h6 (add32 h6 g)) (set! h7 (add32 h7 h)))
              (let* ((s1 (logxor (rotr e 6) (rotr e 11) (rotr e 25)))
                     (ch (logxor (logand e f) (logand (logxor e mask) g)))
                     (t1 (add32 h s1 ch (vector-ref k i) (vector-ref w i)))
                     (s0 (logxor (rotr a 2) (rotr a 13) (rotr a 22)))
                     (maj (logxor (logand a b) (logand a c) (logand b c)))
                     (t2 (add32 s0 maj)))
                (round-loop (+ i 1) (add32 t1 t2) a b c (add32 d t1) e f g))))
        (block-loop (+ offset 64))))
    (let ((digest (make-bytevector 32 0)))
      (for-each (lambda (index word)
                  (bytevector-u32-set! digest (* 4 index) word (endianness big)))
                '(0 1 2 3 4 5 6 7)
                (list h0 h1 h2 h3 h4 h5 h6 h7))
      (let loop ((index 0) (chars '()))
        (if (= index 32)
            (list->string (reverse chars))
            (let ((byte (bytevector-u8-ref digest index)))
              (loop (+ index 1)
                    (cons (string-ref "0123456789abcdef" (logand byte 15))
                          (cons (string-ref "0123456789abcdef" (ash byte -4)) chars)))))))))

(define (sha256-string text)
  (sha256-bytevector (string->utf8 text)))

(define (sha256-file path)
  (sha256-bytevector
   (call-with-input-file path
     (lambda (port)
       (let ((bytes (get-bytevector-all port)))
         (if (eof-object? bytes) (make-bytevector 0) bytes)))
     #:binary #t)))
