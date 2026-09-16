(define agent-system-prompt
  (string-append agent-system-prompt
    "\n\nMemory: this project keeps cortex memory. Before non-trivial work, find the cortex tools with tool_search and call cortex__cortex_recall with a few words about the task; when you learn a durable pattern, decision or fix, save it with cortex__cortex_save so the next session starts from it."))
