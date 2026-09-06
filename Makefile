.PHONY: run dogfood sessions run-traced demo-context demo-context-scripted phoenix phoenix-check phoenix-down phoenix-logs test check

run:
	./bin/shift

dogfood:
	./bin/shift --session dogfood

sessions:
	./bin/shift --list-sessions

run-traced: phoenix-check
	SHIFT_OTEL_ENDPOINT=http://127.0.0.1:6006 ./bin/shift

demo-context: phoenix-check
	SHIFT_OTEL_ENDPOINT=http://127.0.0.1:6006 ./bin/shift --agent demo/context-selection/agent.scm --state-dir .shift/context-demo

demo-context-scripted: phoenix-check
	SHIFT_OTEL_ENDPOINT=http://127.0.0.1:6006 ./bin/shift --agent demo/context-selection/agent.scm --state-dir .shift/context-demo < demo/context-selection/session.txt

phoenix:
	@curl --fail --silent --max-time 2 http://127.0.0.1:6006/healthz >/dev/null || docker compose up -d --wait phoenix

phoenix-check:
	curl --fail --silent --show-error --max-time 2 http://127.0.0.1:6006/healthz >/dev/null

phoenix-down:
	docker compose down

phoenix-logs:
	docker compose logs -f phoenix

test:
	@set -e; for suite in default-agent json provider tools extensions runtime session trace prompt compaction recovery context daily; do \
	  GUILE_AUTO_COMPILE=0 guile -L src -L extensions test/run.scm test/$$suite.scm; \
	done
	python3 test/session_bridge_test.py
	python3 test/regressions.py
	python3 test/daily_driver_test.py
	python3 test/claude_test.py

check: test
	@set -e; for module in src/live-agent/*.scm extensions/shift/*.scm; do \
	  GUILE_AUTO_COMPILE=0 guild compile -L src -L extensions -o /tmp/shift-$$(basename "$$module" .scm).go "$$module"; \
	done
