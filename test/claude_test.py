"""Native Claude streaming, tool approval and cross-provider persistence."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import socket
import time
import urllib.request
import urllib.error
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]


class ClaudeFixture(BaseHTTPRequestHandler):
    def do_GET(self):
        payload = json.dumps(
            {"data": [{"id": "claude-haiku-4-5-20251001", "max_input_tokens": 200000}]}
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.requests.append((self.path, request))
        if getattr(self.server, "hold", None) is not None:
            self.server.entered.set()
            self.server.hold.wait(5)
        self.send_response(200)
        self.send_header(
            "Content-Type",
            "text/event-stream" if request.get("stream") else "application/json",
        )
        self.end_headers()
        if not request.get("stream"):
            self.wfile.write(
                json.dumps(
                    {
                        "stop_reason": "end_turn",
                        "content": [
                            {
                                "type": "text",
                                "text": "Preserve the user's task and project constraints.",
                            }
                        ],
                        "usage": {"input_tokens": 20, "output_tokens": 10},
                    }
                ).encode()
            )
            return
        if self.path.endswith("chat/completions"):
            chunks = [
                {"choices": [{"delta": {"content": "OPENAI_OK"}}]},
                {"choices": [{"delta": {}, "finish_reason": "stop"}]},
            ]
            for chunk in chunks:
                self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
            self.wfile.write(b"data: [DONE]\n\n")
            return

        def event(kind, **fields):
            self.wfile.write(
                ("data: " + json.dumps({"type": kind, **fields}) + "\n\n").encode()
            )

        event("message_start", message={"usage": {"input_tokens": 30}})
        tool_reply = any(
            block.get("type") == "tool_result"
            for message in request["messages"]
            for block in message["content"]
        )
        if tool_reply:
            event(
                "content_block_start",
                index=0,
                content_block={"type": "text", "text": ""},
            )
            event(
                "content_block_delta",
                index=0,
                delta={"type": "text_delta", "text": "CLAUDE_TOOL_OK"},
            )
            reason = "end_turn"
        else:
            event(
                "content_block_start",
                index=0,
                content_block={"type": "thinking", "thinking": "", "signature": ""},
            )
            event(
                "content_block_delta",
                index=0,
                delta={"type": "thinking_delta", "thinking": "Inspect the request."},
            )
            event(
                "content_block_delta",
                index=0,
                delta={"type": "signature_delta", "signature": "fixture-signature"},
            )
            event("content_block_stop", index=0)
            name, arguments = self.server.action
            event(
                "content_block_start",
                index=1,
                content_block={
                    "type": "tool_use",
                    "id": "native_call",
                    "name": name,
                    "input": {},
                },
            )
            encoded = json.dumps(arguments)
            event(
                "content_block_delta",
                index=1,
                delta={"type": "input_json_delta", "partial_json": encoded[:5]},
            )
            event(
                "content_block_delta",
                index=1,
                delta={"type": "input_json_delta", "partial_json": encoded[5:]},
            )
            reason = "tool_use"
        event("content_block_stop", index=1 if not tool_reply else 0)
        event(
            "message_delta", delta={"stop_reason": reason}, usage={"output_tokens": 12}
        )
        if not self.server.truncated:
            event("message_stop")

    def log_message(self, *args):
        pass


class ClaudeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="shift-claude-")
        self.project = Path(self.temp.name)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), ClaudeFixture)
        self.server.action = ("read", {"path": "README.md"})
        self.server.truncated = False
        self.server.requests = []
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        image = (ROOT / "test/session-agent.scm").read_text()
        image = image.replace(
            "(define agent-provider 'ollama)", "(define agent-provider 'claude)"
        )
        image = image.replace(
            '(define agent-model "demo")',
            '(define agent-model "claude-haiku-4-5-20251001")',
        )
        image = image.replace(
            "http://127.0.0.1:11434", f"http://127.0.0.1:{self.server.server_port}"
        )
        image = image.replace(
            "(define agent-api-key-environment #f)",
            '(define agent-api-key-environment "CLAUDE_API_KEY")',
        )
        image = image.replace(
            "'(read rg)", "'(read rg write edit shell live_eval extension traces)"
        )
        (self.project / "agent.scm").write_text(image)
        (self.project / "README.md").write_text("fixture content")
        (self.project / ".env").write_text("CLAUDE_API_KEY=fixture-key\n")

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.temp.cleanup()

    def run_cli(self, text):
        result = subprocess.run(
            [
                str(ROOT / "bin/shift"),
                "--agent",
                "agent.scm",
                "--no-watch",
                "--session",
                "native",
            ],
            input=text,
            text=True,
            capture_output=True,
            cwd=self.project,
            env={**os.environ, "XDG_CONFIG_HOME": str(self.project / "config")},
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_streaming_tool_blocks_and_cross_provider_switch(self):
        result = self.run_cli(
            "/mode plan\nread the readme\n/eval (set! agent-provider 'openai)\nnow answer\n/quit\n"
        )
        self.assertIn("CLAUDE_TOOL_OK", result.stdout)
        self.assertIn("OPENAI_OK", result.stdout)
        self.assertEqual(len(self.server.requests), 3)
        second = self.server.requests[1][1]
        self.assertIn("fixture-signature", json.dumps(second))
        result_block = second["messages"][-1]["content"][0]
        self.assertEqual(result_block["tool_use_id"], "native_call")
        self.assertIn("fixture content", result_block["content"])
        third = self.server.requests[2][1]
        self.assertNotIn("fixture-signature", json.dumps(third))
        call = third["messages"][2]["tool_calls"][0]
        self.assertIsInstance(call["function"]["arguments"], str)
        checkpoint = json.loads(
            (self.project / ".shift/sessions/native/session.json").read_text()
        )
        self.assertEqual(checkpoint["next_turn"], 3)

    def test_plan_denies_project_writes(self):
        self.server.action = (
            "write",
            {"path": "forbidden.txt", "content": "unexpected"},
        )
        self.run_cli("/mode plan\nplease write the file\n/quit\n")
        self.assertFalse((self.project / "forbidden.txt").exists())
        self.assertIn("denied", json.dumps(self.server.requests[1][1]))

    def test_accept_edits_and_manual_denial(self):
        self.server.action = ("write", {"path": "allowed.txt", "content": "expected"})
        self.run_cli("/mode manual\nwrite the file\nn\n/quit\n")
        self.assertFalse((self.project / "allowed.txt").exists())
        self.run_cli("/reset\n/mode accept\nwrite the file\n/quit\n")
        self.assertEqual((self.project / "allowed.txt").read_text(), "expected")

    def test_compaction_precedes_request_and_preserves_turn(self):
        self.run_cli("/quit\n")
        path = self.project / ".shift/sessions/native/session.json"
        checkpoint = json.loads(path.read_text())
        checkpoint["history"] = [
            {"role": role, "content": "earlier context " * 80}
            for _ in range(6)
            for role in ("user", "assistant")
        ]
        checkpoint["next_turn"] = 7
        path.write_text(json.dumps(checkpoint))
        (path.parent / "settings.json").write_text(
            json.dumps({"mode": "plan", "context-limit": 8000, "output-reserve": 1024})
        )
        result = self.run_cli("inspect readme now\n/quit\n")
        self.assertIn(
            "Compacted earlier turns before the request", result.stdout + result.stderr
        )
        self.assertFalse(self.server.requests[0][1]["stream"])
        after = json.loads(path.read_text())
        self.assertEqual(after["next_turn"], 8)
        self.assertIn("Earlier session summary", after["history"][0]["content"])
        self.assertTrue(
            any(m.get("content") == "inspect readme now" for m in after["history"])
        )

    def test_mcp_busy_and_cancel_preserve_checkpoint(self):
        self.server.hold = threading.Event()
        self.server.entered = threading.Event()
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        process = subprocess.Popen(
            [
                str(ROOT / "bin/shift"),
                "--agent",
                "agent.scm",
                "--no-watch",
                "--session",
                "http",
                "--mcp-port",
                str(port),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=self.project,
            env={**os.environ, "XDG_CONFIG_HOME": str(self.project / "config")},
            text=True,
        )

        def call(name, arguments=None):
            request = urllib.request.Request(
                f"http://127.0.0.1:{port}/mcp",
                data=json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 1,
                        "method": "tools/call",
                        "params": {"name": name, "arguments": arguments or {}},
                    }
                ).encode(),
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(request, timeout=10) as response:
                return json.load(response)["result"]

        try:
            deadline = time.monotonic() + 5
            while True:
                try:
                    call("shift_status")
                    break
                except urllib.error.URLError:
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.025)
            outcomes = []
            worker = threading.Thread(
                target=lambda: outcomes.append(
                    call("shift_prompt", {"text": "read the file"})
                )
            )
            worker.start()
            self.assertTrue(self.server.entered.wait(5))
            status = json.loads(call("shift_status")["content"][0]["text"])
            self.assertTrue(status["busy"])
            self.assertTrue(
                call("shift_prompt", {"text": "concurrent prompt"})["isError"]
            )
            self.assertFalse(call("shift_cancel")["isError"])
            self.server.hold.set()
            worker.join(10)
            self.assertFalse(worker.is_alive())
            self.assertTrue(outcomes[0]["isError"])
            checkpoint = json.loads(
                (self.project / ".shift/sessions/http/session.json").read_text()
            )
            self.assertEqual(checkpoint["history"], [])
            self.assertEqual(checkpoint["next_turn"], 1)
            process.stdin.write("/quit\n")
            process.stdin.flush()
            output, errors = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, errors + output)
        finally:
            self.server.hold.set()
            if process.poll() is None:
                process.kill()
                process.communicate()

    def test_truncated_stream_never_executes_tool(self):
        self.server.action = (
            "write",
            {"path": "forbidden.txt", "content": "unexpected"},
        )
        self.server.truncated = True
        result = self.run_cli("/mode accept\nwrite the file\n/quit\n")
        self.assertIn("missing message_stop", result.stderr)
        self.assertFalse((self.project / "forbidden.txt").exists())
        checkpoint = json.loads(
            (self.project / ".shift/sessions/native/session.json").read_text()
        )
        self.assertEqual(checkpoint["history"], [])


if __name__ == "__main__":
    unittest.main()
