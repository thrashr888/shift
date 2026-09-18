((plugin "ripwire" "0.1")
 (description "Call-graph context for a repo: who calls what, blast radius, which tests to run")
 (requires (command "ripwire"))
 (mcp (server "ripwire" (command "ripwire" "--mcp")))
 (skills "skills")
 (allow-run ("ripwire"))
 ;; Read-only verbs never ask; the editing verbs (replace_symbol_body,
 ;; insert_*_symbol, quality_baseline) go through approval or the judge.
 (allow-mcp "ripwire__explore" "ripwire__for" "ripwire__analyze" "ripwire__find_symbol"
            "ripwire__find_referencing_symbols" "ripwire__impact" "ripwire__uses" "ripwire__grep"
            "ripwire__fetch_body" "ripwire__path_between" "ripwire__connect" "ripwire__cochange"
            "ripwire__situational_awareness" "ripwire__from_trace" "ripwire__edit_check"
            "ripwire__exemplar" "ripwire__quality_delta" "ripwire__memory_recall" "ripwire__mentions"
            "ripwire__lego" "ripwire__owners" "ripwire__whereis" "ripwire__stray_content" "ripwire__flags"))
