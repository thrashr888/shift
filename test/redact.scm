(use-modules (srfi srfi-64) (live-agent redact))

(test-begin "redact")
(forget-secrets!)
(test-equal "nothing registered, nothing changes" "token abcdef" (redact "token abcdef"))
(register-secret! "API_KEY" "sk-live-1234567890")
(register-secret! "SHORT" "abc")
(register-secret! "NESTED" "1234567890")
(test-equal "short values are not secrets" 1 (- (secret-count) 1))
(test-equal "values are replaced by their name"
  "key=[redacted API_KEY] and [redacted API_KEY] again"
  (redact "key=sk-live-1234567890 and sk-live-1234567890 again"))
(test-equal "the longest value wins when one contains another"
  "[redacted API_KEY] / [redacted NESTED]"
  (redact "sk-live-1234567890 / 1234567890"))
(test-equal "non-strings pass through" 42 (redact 42))
(forget-secrets!)
(test-equal "forgotten secrets are plain again" "sk-live-1234567890" (redact "sk-live-1234567890"))
(test-end "redact")
