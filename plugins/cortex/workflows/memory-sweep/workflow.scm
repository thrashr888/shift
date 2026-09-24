((workflow "memory-sweep" 1)
 (description "Close a session by saving what it established and consolidating the store")
 (requires (skill "cortex"))
 (budget (rounds 14))
 (step "review"
   "Read back over this session with the traces tool and list what it established that a later session would want: patterns that held, decisions taken with their reasons, and fixes whose cause was found. Leave out anything specific to one file's current contents, which will be stale by the next session."
   (check (run "cortex" "stats")))
 (step "save"
   "Save each durable item with cortex__cortex_save, choosing pattern, bugfix or decision, and mark global only for a preference that applies to every project. Report what you saved and what you decided not to."
   (check (judge "The answer names the items saved, and each one is a durable pattern, decision or fix rather than a restatement of this session's file edits.")))
 (step "consolidate"
   "Run cortex__cortex_sleep to merge the new observations into the long-term store, then report what the consolidated store gained."
   (check (run "cortex" "stats"))))
