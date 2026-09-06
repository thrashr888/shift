(define-module (live-agent transcript)
  #:use-module (srfi srfi-1)
  #:use-module (live-agent json)
  #:export (normalize-messages messages-for-provider))

;; Stable transcript shape: roles/content, tool_calls with object arguments,
;; and tool results with both call ID and name. Provider-only data is explicit.
(define (normalize-messages messages)
  (let ((pending '()) (sequence 0))
    (map
     (lambda (message)
       (set! sequence (+ sequence 1))
       (let* ((role (json-object-ref message "role"))
              (calls (json-array-items (json-object-ref message "tool_calls" (json-array)))))
         (cond
          ((pair? calls)
           (let ((normalized
                  (map (lambda (call index)
                         (let* ((function (json-object-ref call "function"))
                                (args (json-object-ref function "arguments" (json-object)))
                                (id (json-object-ref call "id" (format #f "call_legacy_~a_~a" sequence index)))
                                (name (json-object-ref function "name")))
                           (set! pending (append pending (list (cons id name))))
                           (json-object (cons "id" id) (cons "type" "function")
                             (cons "function" (json-object (cons "name" name)
                               (cons "arguments" (if (string? args) (json-read args) args)))))))
                       calls (iota (length calls)))))
             (apply json-object (acons "tool_calls" (apply json-array normalized)
               (filter (lambda (p) (not (string=? (car p) "tool_calls"))) (json-object-entries message))))))
          ((string=? role "tool")
           (let* ((id (json-object-ref message "tool_call_id" #f))
                  (name (json-object-ref message "tool_name" #f))
                  (match (find (lambda (p) (if id (equal? (car p) id) (equal? (cdr p) name))) pending)))
             (unless match (error "orphan tool result in conversation; reset or compact the session"))
             (set! pending (delete match pending))
             (json-object (cons "role" "tool") (cons "content" (json-object-ref message "content" ""))
                          (cons "tool_call_id" (car match)) (cons "tool_name" (cdr match)))))
          (else message)))) messages)))

(define (messages-for-provider provider messages)
  (map
   (lambda (message)
     (let* ((role (json-object-ref message "role"))
            (calls (json-array-items (json-object-ref message "tool_calls" (json-array))))
            (base (list (cons "role" role) (cons "content" (json-object-ref message "content" "")))))
       (apply json-object
        (append base
          (if (string=? role "tool")
              (if (eq? provider 'ollama)
                  (list (cons "tool_name" (json-object-ref message "tool_name")))
                  (list (cons "tool_call_id" (json-object-ref message "tool_call_id")))) '())
          (if (null? calls) '()
              (list (cons "tool_calls"
                (apply json-array
                  (map (lambda (call)
                    (let ((function (json-object-ref call "function")))
                      (json-object (cons "id" (json-object-ref call "id")) (cons "type" "function")
                        (cons "function" (json-object (cons "name" (json-object-ref function "name"))
                          (cons "arguments" (if (eq? provider 'ollama)
                            (json-object-ref function "arguments")
                            (json-write (json-object-ref function "arguments"))))))))) calls)))))))))
   (normalize-messages messages)))
