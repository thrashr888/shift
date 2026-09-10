"""Failure-path contracts from the September review; local deterministic providers."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "extensions/shift"))
from shift_mcp import McpServer  # noqa: E402


class Provider(BaseHTTPRequestHandler):
    mode = "ok"
    calls = 0
    release = threading.Event()

    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        type(self).calls += 1
        if self.mode == "slow":
            self.release.wait(10)
        self.send_response(503 if self.mode == "error" else 200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        try:
            if self.mode == "error":
                self.wfile.write(b'{"error":{"message":"unavailable"}}')
                return
            if self.mode == "truncated-tool":
                self.wfile.write(
                    b'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"read","arguments":"{}"}}]}}]}\n\n'
                )
                return
            if self.mode == "ollama-length":
                self.wfile.write(
                    b'{"message":{"role":"assistant","content":"partial"},"done":true,"done_reason":"length"}\n'
                )
                return
            if self.mode == "ollama-truncated":
                self.wfile.write(
                    b'{"message":{"role":"assistant","content":"partial"}}\n'
                )
                return
            self.wfile.write(
                b'data: {"choices":[{"index":0,"delta":{"content":"answer"}}]}\n\n'
            )
            if self.mode != "truncated":
                reason = "length" if self.mode == "length" else "stop"
                event = {
                    "choices": [{"index": 0, "delta": {}, "finish_reason": reason}]
                }
                self.wfile.write(
                    ("data: " + json.dumps(event) + "\n\ndata: [DONE]\n\n").encode()
                )
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *args):
        pass


class ReviewRegressions(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="shift-regressions-")
        self.root = Path(self.temp.name)
        for name in ("bin", "agent", "extensions"):
            (self.root / name).mkdir()
        (self.root / "src").symlink_to(ROOT / "src", target_is_directory=True)
        (self.root / "extensions/shift").symlink_to(
            ROOT / "extensions/shift", target_is_directory=True
        )
        shutil.copy2(ROOT / "bin/shift", self.root / "bin/shift")
        Provider.mode = "ok"
        Provider.calls = 0
        Provider.release.clear()
        os.environ["SHIFT_PROVIDER_RETRIES"] = "0"
        self.provider = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
        threading.Thread(target=self.provider.serve_forever, daemon=True).start()
        image = (ROOT / "test/session-agent.scm").read_text()
        image = image.replace(
            "(define agent-provider 'ollama)", "(define agent-provider 'openai)"
        )
        image = image.replace(
            '(define agent-model "demo")', '(define agent-model "fake")'
        )
        image = image.replace(
            "http://127.0.0.1:11434", f"http://127.0.0.1:{self.provider.server_port}"
        )
        (self.root / "agent/default.scm").write_text(image)
        self.bridge = McpServer(self.root, self.root / ".shift")

    def tearDown(self):
        Provider.release.set()
        self.bridge.close()
        self.provider.shutdown()
        self.provider.server_close()
        self.temp.cleanup()

    def session(self, name="parent"):
        session = self.bridge._session({"session": name})
        self.assertEqual(session.start()["state"], "ready")
        return session

    def checkpoint(self, name):
        return json.loads(
            (self.root / ".shift/sessions" / name / "session.json").read_text()
        )

    def child(self, **kwargs):
        args = dict(
            parent_session="parent",
            child_session="child",
            tools=["read"],
            task="answer",
            timeout_seconds=5,
        )
        args.update(kwargs)
        return self.bridge._run_subagent(args)

    def test_timeout_remains_cancellable_and_does_not_checkpoint(self):
        session = self.session()
        Provider.mode = "slow"
        before = self.checkpoint("parent")
        self.assertEqual(session.send("wait", 0.2)["state"], "timeout")
        self.assertTrue(session.status()["busy"])
        with self.assertRaisesRegex(RuntimeError, "busy"):
            session.send("do not queue this")
        cancelled = session.cancel(5)
        self.assertEqual(cancelled["status"], "cancelled", cancelled)
        self.assertFalse(session.status()["busy"])
        self.assertEqual(self.checkpoint("parent")["history"], before["history"])

    def test_failed_child_is_not_a_successful_join(self):
        self.session()
        Provider.mode = "error"
        result = self.child()
        self.assertEqual(result["status"], "error", result)
        self.assertEqual(result["state"], "ready")
        for name in ("parent", "child"):
            spans = [
                json.loads(line)
                for line in (self.root / ".shift/sessions" / name / "traces.jsonl")
                .read_text()
                .splitlines()
            ]
            supervised = [
                span for span in spans if span["name"].startswith("subagent.")
            ]
            self.assertTrue(supervised)
            self.assertTrue(all(span["status"] == "ERROR" for span in supervised))

    def test_missing_or_invalid_extension_never_calls_provider(self):
        self.session()
        (self.root / "extensions/broken.scm").write_text("(set! missing-name 1)")
        for name in ("missing", "broken"):
            with self.assertRaisesRegex(RuntimeError, "extension failed"):
                self.child(child_session=name, extension=name)
            self.assertFalse(
                self.bridge._session({"session": name}).status()["running"]
            )
        self.assertEqual(Provider.calls, 0)

    def test_fork_lineage_survives_turn_reset_and_resume(self):
        self.session()
        fork = self.bridge._fork_session("parent", "child")["fork"]
        child = self.session("child")
        self.assertEqual(child.send("answer", 5)["status"], "ok")
        child.send("/reset")
        child.stop()
        child.start(mode="resume")
        self.assertEqual(self.checkpoint("child")["fork"], fork)

    def test_unfinished_streams_never_enter_history(self):
        session = self.session()
        for mode in (
            "truncated",
            "truncated-tool",
            "length",
            "ollama-truncated",
            "ollama-length",
        ):
            if mode.startswith("ollama"):
                session.send("/eval (define agent-provider 'ollama)")
            Provider.mode = mode
            with self.subTest(mode=mode):
                result = session.send("answer", 5)
                self.assertEqual(result["status"], "error", result)
                self.assertEqual(self.checkpoint("parent")["history"], [])
                self.assertEqual(self.checkpoint("parent")["next_turn"], 1)
                spans = (self.root / ".shift/sessions/parent/traces.jsonl").read_text()
                self.assertNotIn('"name":"tool.read"', spans)

    def test_disabled_builtins_and_test_exit_status(self):
        source = self.root / "failure.scm"
        source.write_text(
            '(use-modules (srfi srfi-64)) (test-begin "failure") (test-assert #f) (test-end "failure")'
        )
        result = subprocess.run(
            ["guile", "--no-auto-compile", str(ROOT / "test/run.scm"), str(source)],
            capture_output=True,
        )
        self.assertEqual(result.returncode, 1)
        env = {**os.environ, "SHIFT_BUILTINS": ""}
        result = subprocess.run(
            [
                str(ROOT / "bin/shift"),
                "--no-watch",
                "--agent",
                str(ROOT / "test/session-agent.scm"),
                "--state-dir",
                str(self.root / "minimal"),
                "hello",
            ],
            input="",
            text=True,
            capture_output=True,
            env=env,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[mcp-test] hello", result.stdout)
        self.assertFalse((self.root / "minimal/traces.jsonl").exists())
        result = subprocess.run(
            [str(ROOT / "bin/shift-mcp")],
            input="",
            text=True,
            capture_output=True,
            env=env,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("disabled", result.stderr)


if __name__ == "__main__":
    unittest.main()
