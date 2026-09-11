.PHONY: run dogfood sessions run-traced demo-context demo-context-scripted phoenix phoenix-check phoenix-down phoenix-logs build test check

# Compiled modules make the SHA-256 ledger and tool loop fast; bin/shift and the
# tests load them from build/ and fall back to source when a .go is stale.
LOAD_PATHS = -L src -L extensions
GUILE_PATHS = $(LOAD_PATHS) -C build
CORE_SOURCES = $(wildcard src/live-agent/*.scm)
BUILTIN_SOURCES = $(wildcard extensions/shift/*.scm)
COMPILED = $(patsubst src/live-agent/%.scm,build/live-agent/%.go,$(CORE_SOURCES)) \
           $(patsubst extensions/shift/%.scm,build/shift/%.go,$(BUILTIN_SOURCES))

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

build: $(COMPILED)

build/live-agent/%.go: src/live-agent/%.scm
	@mkdir -p $(dir $@)
	@GUILE_AUTO_COMPILE=0 guild compile $(LOAD_PATHS) -o $@ $< >/dev/null

build/shift/%.go: extensions/shift/%.scm
	@mkdir -p $(dir $@)
	@GUILE_AUTO_COMPILE=0 guild compile $(LOAD_PATHS) -o $@ $< >/dev/null

test: build
	@set -e; for suite in sha256 changes patch receipt coding default-agent json provider tools extensions runtime session trace prompt compaction recovery context daily; do \
	  GUILE_AUTO_COMPILE=0 guile $(GUILE_PATHS) test/run.scm test/$$suite.scm; \
	done
	python3 test/session_bridge_test.py
	python3 test/regressions.py
	python3 test/daily_driver_test.py
	python3 test/claude_test.py
	python3 test/coding_workflow_test.py
	python3 test/evals_driver_test.py

check: test
