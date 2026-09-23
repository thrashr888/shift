;; The Terminal-Bench harness check that proved the adapter: one task, a
;; short bound, and the record read back. About twenty minutes on this Mac.
((workflow "bench-smoke" 1)
 (description "Run one Terminal-Bench task through Harbor and read the record back")
 (budget (rounds 12))
 (step "run"
       "Run python3 scripts/evals.py terminal-bench --tasks html-js-filter --timeout 900 --rounds 12 --run-id bench-smoke as a background job with the job tool, wait for it (it takes about twenty minutes), and report the reward and status it printed."
       (check (file "evals/results/bench-smoke/results.jsonl"))
       (check (judge "the answer reports the task's reward")))
 (step "record"
       "Read evals/results/bench-smoke/results.jsonl and the trial's agent/receipt.json under evals/results/bench-smoke/harbor if it exists. Answer in three sentences: the reward, how many rounds Shift used, and the first thing the receipt or stderr suggests went wrong if the reward was 0."
       (check (contains "reward"))))
