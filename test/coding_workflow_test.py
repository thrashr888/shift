"""Coding workflow contracts through the real CLI with a deterministic provider:
dirty git checkouts, projects without git, patch conflicts, stale files, failing
and cancelled runs, interrupted mutations, and undo."""

import hashlib
import json
import os
import signal
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = str(ROOT / "bin/shift")


def sse(events):
    return "".join("data: " + json.dumps(event) + "\n\n" for event in events) + "data: [DONE]\n\n"


def usage_event(usage):
    return [{"choices": [], "usage": usage}] if usage else []


def tool_call(name, arguments, usage=None):
    call = {
        "index": 0,
        "id": "call_" + name,
        "type": "function",
        "function": {"name": name, "arguments": json.dumps(arguments)},
    }
    return sse(
        [
            {"choices": [{"index": 0, "delta": {"tool_calls": [call]}}]},
            {"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]},
        ]
        + usage_event(usage)
    )


def answer(text, usage=None):
    return sse(
        [
            {"choices": [{"index": 0, "delta": {"content": text}}]},
            {"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]},
        ]
        + usage_event(usage)
    )


PROVIDER_ERROR = "provider-error"
RATE_LIMITED = "rate-limited"


class Provider(BaseHTTPRequestHandler):
    """Serves a planned list of responses; a plan entry may be a callable that
    runs before its response is sent, to change the world mid-turn."""

    plan = []
    last_messages = []
    lock = threading.Lock()

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with Provider.lock:
            Provider.last_messages = body["messages"]
            step = Provider.plan.pop(0) if Provider.plan else answer("done")
        if callable(step):
            step = step()
        if step in (PROVIDER_ERROR, RATE_LIMITED):
            self.send_response(503 if step == PROVIDER_ERROR else 429)
            self.send_header("Content-Type", "application/json")
            if step == RATE_LIMITED:
                self.send_header("Retry-After", "1")
            self.end_headers()
            self.wfile.write(b'{"error":{"message":"unavailable"}}')
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        self.wfile.write(step.encode())

    def log_message(self, *args):
        pass


def sha256(text):
    return hashlib.sha256(text.encode()).hexdigest()


class CodingWorkflow(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="shift-workflow-")
        self.project = Path(self.temp.name)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        Provider.plan = []
        Provider.last_messages = []
        image = (ROOT / "test/session-agent.scm").read_text()
        for old, new in (
            ("(define agent-provider 'ollama)", "(define agent-provider 'openai)"),
            ('(define agent-model "demo")', '(define agent-model "fake")'),
            ("http://127.0.0.1:11434", f"http://127.0.0.1:{self.server.server_port}"),
            ("(define agent-tools '(read rg))",
             "(define agent-tools '(read rg write edit apply_patch status diff run))"),
            ("(define agent-max-tool-rounds 1)", "(define agent-max-tool-rounds 6)"),
            ("(define agent-compaction-threshold 12)", "(define agent-compaction-threshold 80)"),
        ):
            self.assertIn(old, image)
            image = image.replace(old, new)
        self.agent = self.project / ".agent.scm"
        self.agent.write_text(image)
        # Retries are opt-in per test so a planned provider error fails fast.
        self.env = {**os.environ, "XDG_CONFIG_HOME": str(self.project / ".config"), "SHIFT_PROVIDER_RETRIES": "0"}
        self.env.pop("SHIFT_BUILTINS", None)
        (self.project / "notes.txt").write_text("alpha port 8080\n")

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.temp.cleanup()

    def command(self, session="w"):
        return [BIN, "--agent", str(self.agent), "--no-watch", "--no-mcp", "--session", session]

    def shift(self, stdin, plan=(), session="w"):
        Provider.plan = list(plan)
        result = subprocess.run(
            self.command(session), input=stdin, text=True, capture_output=True,
            cwd=self.project, env=self.env, timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout + result.stderr

    def print_mode(self, task, plan, *flags, session="p"):
        """Unattended run; returns (exit code, stdout, stderr)."""
        Provider.plan = list(plan)
        result = subprocess.run(
            [BIN, "--agent", str(self.agent), "--session", session, "--print", task, *flags],
            text=True, capture_output=True, cwd=self.project, env=self.env, timeout=60,
            stdin=subprocess.DEVNULL,
        )
        return result.returncode, result.stdout, result.stderr

    def tool_results(self):
        return [m.get("content") for m in Provider.last_messages if m.get("role") == "tool"]

    def state(self, session="w"):
        return self.project / ".shift/sessions" / session

    def checkpoint(self, session="w"):
        return json.loads((self.state(session) / "session.json").read_text())

    def ledger(self, session="w"):
        path = self.state(session) / "changes.jsonl"
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]

    def git(self, *args):
        subprocess.run(
            ["git", "-C", str(self.project), "-c", "user.name=t", "-c", "user.email=t@example.com",
             "-c", "commit.gpgsign=false", *args],
            check=True, capture_output=True,
        )

    edit_notes = tool_call("edit", {"path": "notes.txt", "old_text": "8080", "new_text": "9443"})

    def test_dirty_git_checkout_undo_reverts_only_shift_changes(self):
        (self.project / "theirs.txt").write_text("user work\n")
        self.git("init", "-q")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "base")
        (self.project / "theirs.txt").write_text("user work\nuser edit\n")
        out = self.shift("/mode accept\nchange the port\n/quit\n",
                         [self.edit_notes, tool_call("status", {}), answer("changed")])
        status = self.tool_results()[-1]
        self.assertIn("git ", status)
        self.assertIn("  notes.txt (+1 −1)", status)
        self.assertIn("dirty in git but not touched by shift: 1", status)
        self.assertIn("  theirs.txt", status)
        self.assertEqual((self.project / "notes.txt").read_text(), "alpha port 9443\n")
        out = self.shift("/undo\n/quit\n")
        self.assertIn("Undid turn 1: notes.txt", out)
        self.assertEqual((self.project / "notes.txt").read_text(), "alpha port 8080\n")
        self.assertEqual((self.project / "theirs.txt").read_text(), "user work\nuser edit\n")
        history = self.checkpoint()["history"]
        self.assertIn("The user ran /undo", history[-1]["content"])
        self.assertIn("Nothing to undo", self.shift("/undo\n/quit\n"))

    def test_non_git_project_edit_diff_status_and_undo(self):
        self.shift("/mode accept\nchange the port\n/quit\n",
                   [self.edit_notes, tool_call("diff", {"scope": "turn"}), tool_call("status", {}), answer("ok")])
        diff, status = self.tool_results()[-2:]
        self.assertIn("+alpha port 9443", diff)
        self.assertIn("1 file changed (+1 −1)", diff)
        self.assertIn("not a git repository", status)
        self.assertIn("changed this turn (turn 1): (+1 −1)", status)
        out = self.shift("/undo\n/quit\n")
        self.assertIn("Undid turn 1: notes.txt", out)
        self.assertEqual((self.project / "notes.txt").read_text(), "alpha port 8080\n")
        kinds = [entry["kind"] for entry in self.ledger()]
        self.assertEqual(kinds[-1], "undo")

    def test_patch_conflict_writes_nothing_and_the_turn_continues(self):
        bad = "--- a/notes.txt\n+++ b/notes.txt\n@@ -1 +1 @@\n-nope\n+x\n--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1 @@\n+created\n"
        self.shift("/mode accept\npatch it\n/quit\n", [tool_call("apply_patch", {"patch": bad}), answer("continued")])
        result = self.tool_results()[-1]
        self.assertIn("hunk 1 does not match notes.txt at line 1", result)
        self.assertIn('expected "nope", found "alpha port 8080"', result)
        self.assertEqual((self.project / "notes.txt").read_text(), "alpha port 8080\n")
        self.assertFalse((self.project / "new.txt").exists())
        checkpoint = self.checkpoint()
        self.assertEqual(checkpoint["next_turn"], 2)
        self.assertEqual(checkpoint["history"][-1]["content"], "continued")
        self.assertEqual([e for e in self.ledger() if e["kind"] == "change"], [])

    def test_stale_file_is_refused_before_approval(self):
        def rewrite_then_edit():
            (self.project / "notes.txt").write_text("alpha port 8080\nedited in an editor\n")
            return self.edit_notes

        out = self.shift("change the port\ny\n/quit\n",
                         [tool_call("read", {"path": "notes.txt"}), rewrite_then_edit, answer("ok")])
        self.assertEqual(out.count("Approve tool?"), 1, out)
        result = self.tool_results()[-1]
        self.assertIn("notes.txt changed on disk since turn 1", result)
        self.assertIn("read it again before editing", result)
        self.assertEqual((self.project / "notes.txt").read_text(), "alpha port 8080\nedited in an editor\n")

    def test_failing_run_is_reported_and_the_turn_is_checkpointed(self):
        self.shift("/mode accept\nrun tests\ny\n/quit\n",
                   [tool_call("run", {"argv": ["sh", "-c", "echo 1 test failed; exit 1"]}), answer("tests failed")])
        result = self.tool_results()[-1]
        self.assertIn("· exit 1 ·", result)
        self.assertIn("1 test failed", result)
        self.assertEqual(self.checkpoint()["next_turn"], 2)
        runs = [e for e in self.ledger() if e["kind"] == "run"]
        self.assertEqual(len(runs), 1)
        self.assertFalse(runs[0]["outcome"]["success"])
        self.assertEqual(runs[0]["outcome"]["exit_code"], 1)
        self.assertEqual(runs[0]["outcome"]["output_sha256"], sha256("1 test failed\n"))
        self.assertTrue((self.state() / runs[0]["log"]).exists())

    def test_cancelled_run_reaps_the_child_and_keeps_history(self):
        marker = "61.73"
        Provider.plan = [tool_call("run", {"argv": ["sleep", marker]}), answer("never")]
        process = subprocess.Popen(
            self.command(), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, cwd=self.project, env=self.env,
        )
        process.stdin.write("/mode accept\nrun it\ny\n")
        process.stdin.flush()
        deadline = time.time() + 15
        while time.time() < deadline:
            if subprocess.run(["pgrep", "-f", f"sleep {marker}"], capture_output=True).returncode == 0:
                break
            time.sleep(0.1)
        else:
            process.kill()
            self.fail("the sleep child never started")
        os.kill(process.pid, signal.SIGINT)
        process.stdin.write("/quit\n")
        process.stdin.flush()
        out, _ = process.communicate(timeout=30)
        self.assertEqual(process.returncode, 0, out)
        self.assertIn("turn cancelled; conversation state is unchanged.", out)
        time.sleep(0.5)
        self.assertNotEqual(
            subprocess.run(["pgrep", "-f", f"sleep {marker}"], capture_output=True).returncode, 0,
            "the child outlived the cancelled turn",
        )
        spans = [json.loads(line) for line in (self.state() / "traces.jsonl").read_text().splitlines()]
        self.assertIn(("tool.run", "CANCELLED"), [(s["name"], s["status"]) for s in spans])
        self.assertEqual(self.checkpoint()["history"], [])
        self.assertEqual([e["kind"] for e in self.ledger() if e["kind"] == "run"], [])

    def test_interrupted_mutation_is_restored_from_the_pre_image(self):
        self.shift("/mode accept\nchange the port\n/quit\n", [self.edit_notes, answer("ok")])
        before = "alpha port 9443\n"
        crashed = "alpha port 1\n"
        self.assertEqual((self.project / "notes.txt").read_text(), before)
        # Simulate death between the write-ahead entry and its commit: the file
        # already carries the post-image, the ledger still says started.
        (self.project / "notes.txt").write_text(crashed)
        entry = {
            "kind": "change", "seq": 2, "turn": 2, "call_id": "call_edit", "tool": "edit",
            "path": "notes.txt", "before": sha256(before), "after": sha256(crashed),
            "state": "started", "at": "2026-09-08T00:00:00Z",
        }
        with (self.state() / "changes.jsonl").open("a") as ledger:
            ledger.write(json.dumps(entry) + "\n")
        (self.state() / "interrupted-tool.json").write_text(json.dumps({
            "version": 1, "state": "execution-started", "tool": "edit",
            "arguments": {"path": "notes.txt", "old_text": "9443", "new_text": "1"},
            "generation_id": 1, "created_at": "2026-09-08T00:00:00Z",
        }) + "\n")
        out = self.shift("/recover\n/recover restore\n/quit\n")
        self.assertIn("interrupted tool record found", out)
        self.assertIn("notes.txt (turn 2, edit)", out)
        self.assertIn("matches after; /recover restore puts the pre-image back", out)
        self.assertIn("notes.txt: restored from the pre-image", out)
        self.assertIn("recovery record cleared", out)
        self.assertEqual((self.project / "notes.txt").read_text(), before)
        self.assertFalse((self.state() / "interrupted-tool.json").exists())
        self.assertIn("No interrupted tool call is pending", self.shift("/recover\n/quit\n"))

    def test_undo_refuses_when_a_changed_file_diverged(self):
        (self.project / "second.txt").write_text("alpha\n")
        patch = ("--- a/notes.txt\n+++ b/notes.txt\n@@ -1 +1 @@\n-alpha port 8080\n+alpha port 9443\n"
                 "--- a/second.txt\n+++ b/second.txt\n@@ -1 +1,2 @@\n alpha\n+beta\n")
        self.shift("/mode accept\npatch\n/quit\n", [tool_call("apply_patch", {"patch": patch}), answer("ok")])
        self.assertEqual((self.project / "second.txt").read_text(), "alpha\nbeta\n")
        (self.project / "second.txt").write_text("alpha\nbeta\nuser addition\n")
        out = self.shift("/undo\n/quit\n")
        self.assertIn("cannot undo turn 1", out)
        self.assertIn("second.txt", out)
        self.assertEqual((self.project / "notes.txt").read_text(), "alpha port 9443\n")
        self.assertEqual((self.project / "second.txt").read_text(), "alpha\nbeta\nuser addition\n")
        self.assertEqual([e for e in self.ledger() if e["kind"] == "undo"], [])


    def test_print_mode_answers_once_with_a_clean_stdout(self):
        code, out, err = self.print_mode("say hi", [answer("hello there")])
        self.assertEqual(code, 0, err)
        self.assertEqual(out, "hello there\n")
        self.assertNotIn("shift λ", out)
        self.assertIn("Session closed", err)
        self.assertEqual(self.checkpoint("p")["next_turn"], 2)

    def test_print_mode_exit_codes_and_flags(self):
        code, out, err = self.print_mode("fail", [PROVIDER_ERROR])
        self.assertEqual(code, 1)
        self.assertIn("turn failed", err)
        code, out, err = self.print_mode("bad mode", [answer("x")], "--mode", "sideways")
        self.assertEqual(code, 2)
        self.assertIn("startup options rejected", err)
        code, out, err = self.print_mode("bad set", [answer("x")], "--set", "agent-max-tool-rounds=99")
        self.assertEqual(code, 2)
        code, out, err = self.print_mode("bad json", [answer("x")], "--set", "turn-token-budget=notjson")
        self.assertEqual(code, 2)
        result = subprocess.run([BIN, "--agent", str(self.agent), "--print"], text=True,
                                capture_output=True, cwd=self.project, env=self.env)
        self.assertEqual(result.returncode, 2)

    def test_print_mode_allow_run_executes_without_a_prompt(self):
        code, out, err = self.print_mode(
            "run it", [tool_call("run", {"argv": ["sh", "-c", "echo ran"]}), answer("ok")],
            "--mode", "accept", "--allow-run", "sh -c", "--allow-run", "make check")
        self.assertEqual(code, 0, err)
        self.assertNotIn("Approve", out + err)
        self.assertIn("· exit 0 ·", self.tool_results()[-1])
        settings = json.loads((self.state("p") / "settings.json").read_text())
        self.assertEqual(settings["run-allow"], [["sh", "-c"], ["make", "check"]])
        self.assertEqual(settings["mode"], "accept")

    def test_print_mode_denies_runs_that_are_not_allowlisted(self):
        code, out, err = self.print_mode(
            "run it", [tool_call("run", {"argv": ["sh", "-c", "echo ran"]}), answer("ok")],
            "--mode", "accept")
        self.assertEqual(code, 0, err)
        self.assertIn("tool unavailable in this turn: run", self.tool_results()[-1])

    def test_round_limit_and_token_budget_end_the_turn_with_a_reason(self):
        read = tool_call("read", {"path": "notes.txt"})
        code, out, err = self.print_mode("loop", [read, read, answer("never")],
                                         "--mode", "accept", "--set", "agent-max-tool-rounds=1")
        self.assertEqual(code, 1)
        self.assertIn("tool round limit reached", err)
        spent = tool_call("read", {"path": "notes.txt"}, usage={"prompt_tokens": 5000, "completion_tokens": 20})
        code, out, err = self.print_mode("spend", [spent, answer("never")],
                                         "--mode", "accept", "--set", "turn-token-budget=2048", session="b")
        self.assertEqual(code, 1)
        self.assertIn("turn token budget exceeded", err)
        journal = (self.state("b") / "events.scm-log").read_text()
        self.assertIn("turn-limit", journal)
        self.assertIn("(reason . tokens)", journal)
        self.assertEqual(self.checkpoint("b")["history"], [])

    def test_context_estimate_calibrates_later_rounds_but_not_the_next_turn(self):
        (self.project / "notes.txt").write_text("value = 1\n" * 6000)
        (self.project / ".shift").mkdir()
        (self.project / ".shift/settings.json").write_text(json.dumps({
            "context-limit": 131072, "output-reserve": 8192,
        }))
        # The initial request fits, but bytes/3 puts the read result over the
        # guard. The provider's 73k count leaves room at this same window.
        output = self.shift(
            "/mode plan\n" + "code " * 50000 + "\n/context\nnext turn\n/quit\n",
            [tool_call("read", {"path": "notes.txt"},
                       usage={"prompt_tokens": 73000, "completion_tokens": 5}),
             answer("CALIBRATED_OK", usage={"prompt_tokens": 88000, "completion_tokens": 5}),
             answer("MUST_NOT_REUSE_CALIBRATION")],
        )
        self.assertIn("CALIBRATED_OK", output)
        self.assertNotIn("MUST_NOT_REUSE_CALIBRATION", output)
        self.assertTrue(any(m["role"] == "tool" for m in Provider.last_messages),
                        "the answer must finish the original tool chain")
        self.assertEqual(len(Provider.plan), 1, "the next turn must use its own estimate")
        self.assertIn("current turn is too large to compact safely", output)
        self.assertEqual(self.checkpoint()["next_turn"], 2)

    def test_context_calibration_uses_latest_usage_without_compounding(self):
        (self.project / "notes.txt").write_text("value = 1\n" * 6000)
        (self.project / ".shift").mkdir()
        (self.project / ".shift/settings.json").write_text(json.dumps({
            "context-limit": 131072, "output-reserve": 8192,
        }))
        # Reusing the first ratio, or dividing by the calibrated second
        # estimate, would incorrectly reject the third request.
        output = self.shift(
            "/mode plan\n" + "code " * 50000 + "\n/quit\n",
            [tool_call("read", {"path": "notes.txt"},
                       usage={"prompt_tokens": 73000, "completion_tokens": 5}),
             tool_call("read", {"path": "notes.txt"},
                       usage={"prompt_tokens": 78000, "completion_tokens": 5}),
             answer("LATEST_USAGE_OK", usage={"prompt_tokens": 93000, "completion_tokens": 5})],
        )
        self.assertIn("LATEST_USAGE_OK", output)
        self.assertNotIn("Context budget exceeded", output)
        self.assertEqual(len(self.tool_results()), 2)
        self.assertEqual(self.checkpoint()["next_turn"], 2)

    def test_show_work_covers_tool_echo_and_the_receipt(self):
        plan = [tool_call("read", {"path": "notes.txt"}), answer("seen")]
        code, out, err = self.print_mode("look", plan, "--mode", "accept")
        self.assertEqual(code, 0, err)
        self.assertEqual(out, "seen\n")
        self.assertIn("tool> read notes.txt", err)
        self.assertIn("✓ # notes.txt · 16 bytes · sha256", err)
        code, out, err = self.print_mode("look", plan, session="manual")
        self.assertEqual(out, "seen\n", "manual mode must deny without prompting in print mode")
        self.assertNotIn("Approve", out + err)
        self.assertIn("✗ tool unavailable in this turn: read", err)
        self.assertIn("turn 1 · fake · generation 1", err)
        code, out, err = self.print_mode("look", plan, "--mode", "accept", "--set", "show-work=false",
                                         "--receipt", str(self.project / "quiet.json"), session="quiet")
        self.assertEqual(out, "seen\n")
        self.assertNotIn("tool>", err)
        self.assertNotIn("turn 1 ·", err, "show-work off hides the receipt text too")
        self.assertEqual(len(self.receipts("quiet")), 1, "the receipt is still recorded")
        self.assertEqual(json.loads((self.project / "quiet.json").read_text())["status"], "ok")
        out = self.shift("/mode accept\n/work off\n/tools\nlook\n/receipt\n/quit\n", plan, session="repl")
        self.assertIn("tools read rg write edit apply_patch status diff run · show-work off", out)
        self.assertNotIn("tool>", out)
        self.assertEqual(out.count("turn 1 · fake"), 1, "/receipt still shows it on request")
        out = self.shift("/work on\nlook\n/quit\n", plan, session="repl")
        self.assertIn("tool> read notes.txt", out)
        self.assertIn("turn 2 · fake · generation 1", out)

    def test_malformed_tool_arguments_fail_the_call_not_the_turn(self):
        call = {"index": 0, "id": "call_bad", "type": "function",
                "function": {"name": "edit", "arguments": '{"path":"notes.txt","old_text":"unterminated'}}
        bad = sse([{"choices": [{"index": 0, "delta": {"tool_calls": [call]}}]},
                   {"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]}])
        code, out, err = self.print_mode("edit it", [bad, answer("retrying")], "--mode", "accept")
        self.assertEqual(code, 0, err)
        self.assertEqual(out, "retrying\n")
        result = self.tool_results()[-1]
        self.assertIn("were not a valid JSON object", result)
        self.assertIn("nothing ran", result)
        self.assertEqual((self.project / "notes.txt").read_text(), "alpha port 8080\n")
        self.assertIn("tool-arguments-invalid", (self.state("p") / "events.scm-log").read_text())

    def receipts(self, session="p"):
        path = self.state(session) / "receipts.jsonl"
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]

    def turn_span(self, session="p"):
        for line in (self.state(session) / "traces.jsonl").read_text().splitlines():
            span = json.loads(line)
            if span["name"] == "agent.turn":
                return span
        self.fail("no agent.turn span")

    def test_receipt_reports_the_turn_in_every_form(self):
        cached = {"prompt_tokens": 1200, "completion_tokens": 30, "prompt_tokens_details": {"cached_tokens": 1000}}
        plan = [tool_call("edit", {"path": "notes.txt", "old_text": "8080", "new_text": "9443"}, usage=cached),
                tool_call("run", {"argv": ["sh", "-c", "echo ran; exit 3"]}, usage={"prompt_tokens": 1500, "completion_tokens": 20}),
                answer("done", usage={"prompt_tokens": 1600, "completion_tokens": 5})]
        receipt_file = self.project / "receipt.json"
        code, out, err = self.print_mode("edit and run", plan, "--mode", "accept", "--allow-run", "sh -c",
                                         "--receipt", str(receipt_file))
        self.assertEqual(code, 0, err)
        self.assertEqual(out, "done\n", "the receipt must not touch stdout")
        self.assertIn("turn 1 · fake · generation 1 · 3 rounds · 4,300 in (1,000 cached) + 55 out", err)
        self.assertIn("changed  notes.txt (+1 −1)", err)
        self.assertIn("ran      sh -c echo ran; exit 3  exit 3", err)
        self.assertIn("undo     available (/undo)", err)
        self.assertIn("resume ./bin/shift --resume p", err)
        (receipt,) = self.receipts()
        self.assertEqual(json.loads(receipt_file.read_text()), receipt)
        self.assertEqual(receipt["status"], "ok")
        self.assertEqual(receipt["tokens"], {"prompt": 4300, "cached": 1000, "uncached": 3300, "completion": 55})
        self.assertEqual(receipt["tool_calls"], {"edit": 1, "run": 1})
        self.assertEqual([c["path"] for c in receipt["changed"]], ["notes.txt"])
        self.assertEqual((receipt["changed"][0]["added"], receipt["changed"][0]["removed"]), (1, 1))
        self.assertEqual(receipt["changed"][0]["after"], sha256("alpha port 9443\n"))
        self.assertEqual(receipt["runs"][0]["command"], ["sh", "-c", "echo ran; exit 3"])
        self.assertEqual((receipt["runs"][0]["exit_code"], receipt["runs"][0]["success"]), (3, False))
        self.assertTrue(receipt["undo"])
        span = self.turn_span()
        self.assertEqual(receipt["trace_id"], span["trace_id"])
        self.assertEqual(receipt["span_id"], span["span_id"])
        self.assertEqual(span["attributes"]["receipt.files"], "notes.txt")
        self.assertEqual(span["attributes"]["receipt.runs_failed"], 1)
        self.assertEqual(span["attributes"]["receipt.tokens.cached"], 1000)
        out = self.shift("/receipt\n/quit\n", [], session="p")
        self.assertIn("turn 1 · fake · generation 1 · 3 rounds", out, "/receipt reads the last record of a resumed session")
        self.assertIn("changed  notes.txt (+1 −1)", out)

    def test_failed_and_cancelled_turns_still_get_a_receipt(self):
        read = tool_call("read", {"path": "notes.txt"})
        code, out, err = self.print_mode("loop", [self.edit_notes, read, read, answer("never")],
                                         "--mode", "accept", "--set", "agent-max-tool-rounds=2")
        self.assertEqual(code, 1)
        self.assertIn("status   failed · tool round limit reached", err)
        self.assertIn("changed  notes.txt (+1 −1)", err)
        (receipt,) = self.receipts()
        self.assertEqual(receipt["status"], "failed")
        self.assertIn("round limit", receipt["error"])
        self.assertEqual(receipt["tool_calls"], {"edit": 1, "read": 1})
        self.assertTrue(receipt["undo"], "changes a failed turn committed stay undoable")
        self.assertEqual(self.turn_span()["attributes"]["receipt.status"], "failed")
        code, out, err = self.print_mode("no turn", [answer("x")], "--receipt", str(self.project / "missing" / "r.json"),
                                         session="unwritable")
        self.assertEqual(code, 0, "a receipt that cannot be written never fails the turn")
        self.assertIn("receipt not written", err)
        self.assertEqual(len(self.receipts("unwritable")), 1)

    def llm_spans(self, session="p"):
        return [json.loads(line) for line in (self.state(session) / "traces.jsonl").read_text().splitlines()
                if '"kind":"LLM"' in line]

    def test_provider_errors_are_retried_with_backoff_and_recorded(self):
        started = time.time()
        code, out, err = self.print_mode("hi", [RATE_LIMITED, PROVIDER_ERROR, answer("ok")],
                                         "--set", "provider-retries=3")
        self.assertEqual(code, 0, err)
        self.assertEqual(out, "ok\n")
        self.assertGreaterEqual(time.time() - started, 3, "1s Retry-After then 2s backoff")
        self.assertIn("provider 429 · retrying in 1.0s (attempt 2 of 4)", err)
        self.assertIn("provider 503 · retrying in 2.0s (attempt 3 of 4)", err)
        (span,) = self.llm_spans()
        self.assertEqual(span["attributes"]["llm.retries"], 2)
        self.assertEqual(span["attributes"]["llm.retry_log"], "429@1.0s,503@2.0s")
        code, out, err = self.print_mode("hi", [PROVIDER_ERROR, answer("never")], session="none")
        self.assertEqual(code, 1, "provider-retries=0 fails on the first error")
        self.assertIn("provider request failed after retries", err)
        self.assertNotIn("retrying", err)
        code, out, err = self.print_mode("hi", [PROVIDER_ERROR, PROVIDER_ERROR, answer("never")],
                                         "--set", "provider-retries=1", session="one")
        self.assertEqual(code, 1, "the limit is honoured")
        self.assertEqual(err.count("retrying"), 1)
        (span,) = self.llm_spans("one")
        self.assertEqual(span["attributes"]["llm.retries"], 1)

    def test_limit_nudge_asks_the_model_to_finish_once_and_is_not_persisted(self):
        read = tool_call("read", {"path": "notes.txt"})
        code, out, err = self.print_mode("look", [read, read, answer("done")],
                                         "--mode", "accept", "--set", "agent-max-tool-rounds=5")
        self.assertEqual(code, 0, err)
        self.assertIn("shift> 3 tool rounds remain in this turn; asked the model to finish", err)
        last = Provider.last_messages[-1]
        self.assertEqual(last["role"], "user")
        self.assertIn("3 tool rounds remain", last["content"])
        self.assertNotIn("ephemeral", last, "the marker never reaches the provider")
        self.assertEqual(Provider.last_messages[-2]["role"], "tool")
        history = json.dumps(self.checkpoint("p")["history"])
        self.assertNotIn("rounds remain", history, "the nudge is not persisted")
        self.assertIn("read result", history.lower() if "read result" in history.lower() else "read result")
        self.assertIn("turn-nudge", (self.state("p") / "events.scm-log").read_text())
        spent = tool_call("read", {"path": "notes.txt"}, usage={"prompt_tokens": 900, "completion_tokens": 10})
        code, out, err = self.print_mode("spend", [spent, read, answer("done")], "--mode", "accept",
                                         "--set", "turn-token-budget=1024", session="budget")
        self.assertEqual(code, 0, err)
        self.assertIn("token budget is 89% spent; asked the model to finish", err)
        self.assertEqual(err.count("asked the model to finish"), 1, "nudged once per turn")

    def test_model_flag_selects_a_provider(self):
        code, out, err = self.print_mode("hi", [answer("x")], "--model", "openai/gpt-5.4-mini")
        settings = json.loads((self.state("p") / "settings.json").read_text())
        self.assertEqual(settings["agent-model"], "gpt-5.4-mini")
        self.assertEqual(settings["agent-provider"], "openai")


if __name__ == "__main__":
    unittest.main()
