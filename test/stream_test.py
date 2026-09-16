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


class StreamRegressions(unittest.TestCase):
    """Unfinished provider streams never become history; suite failures fail the build."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="shift-regressions-")
        self.root = Path(self.temp.name)
        for name in ("bin", "agent", "extensions"):
            (self.root / name).mkdir()
        (self.root / "src").symlink_to(ROOT / "src", target_is_directory=True)
        (self.root / "extensions/shift").symlink_to(
            ROOT / "extensions/shift", target_is_directory=True
        )
        shutil.copy2(ROOT / "bin/shift-agent", self.root / "bin/shift-agent")
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

    def tearDown(self):
        Provider.release.set()
        self.provider.shutdown()
        self.provider.server_close()
        self.temp.cleanup()

    def cli(self, stdin, *flags):
        return subprocess.run(
            [str(self.root / "bin/shift-agent"), "--no-watch", "--no-mcp", "--agent", str(self.root / "agent/default.scm"),
             "--state-dir", str(self.root / ".shift"), "--session", "parent", *flags],
            input=stdin, text=True, capture_output=True, timeout=60, cwd=self.root,
            env={**os.environ, "XDG_CONFIG_HOME": str(self.root / "config"), "SHIFT_PROVIDER_RETRIES": "0"},
        )

    def checkpoint(self, name):
        return json.loads((self.root / ".shift/sessions" / name / "session.json").read_text())

    def test_unfinished_streams_never_enter_history(self):
        self.cli("/quit\n")
        for mode in ("truncated", "truncated-tool", "length", "ollama-truncated", "ollama-length"):
            Provider.mode = mode
            with self.subTest(mode=mode):
                flags = ["--set", 'agent-provider="ollama"'] if mode.startswith("ollama") else ["--set", 'agent-provider="openai"']
                result = self.cli("answer\n/quit\n", *flags)
                self.assertEqual(result.returncode, 0, result.stderr)
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
                str(ROOT / "bin/shift-agent"),
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


if __name__ == "__main__":
    unittest.main()
