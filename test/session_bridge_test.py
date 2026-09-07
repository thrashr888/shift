#!/usr/bin/env python3

import json
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer, ThreadingHTTPServer
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "extensions/shift"))

from shift_mcp import LiveSession, McpServer  # noqa: E402


class FakeOllamaHandler(BaseHTTPRequestHandler):
    calls = 0

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        self.rfile.read(length)
        type(self).calls += 1
        if type(self).calls == 1:
            payload = {
                "message": {
                    "role": "assistant",
                    "content": "",
                    "tool_calls": [
                        {
                            "id": "call_shell",
                            "function": {
                                "name": "shell",
                                "arguments": {"command": "printf approved"},
                            },
                        }
                    ],
                },
                "done": True,
            }
        else:
            payload = {
                "message": {"role": "assistant", "content": "shell approved"},
                "done": True,
            }
        body = (json.dumps(payload) + "\n").encode()
        self.send_response(200)
        self.send_header("content-type", "application/x-ndjson")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


class SlowOllamaHandler(BaseHTTPRequestHandler):
    started = threading.Event()
    release = threading.Event()

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        self.rfile.read(length)
        type(self).started.set()
        type(self).release.wait(10)
        body = (
            json.dumps(
                {"message": {"role": "assistant", "content": "late"}, "done": True}
            )
            + "\n"
        ).encode()
        try:
            self.send_response(200)
            self.send_header("content-type", "application/x-ndjson")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, format, *args):
        pass


class TraceOllamaHandler(BaseHTTPRequestHandler):
    calls = 0

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        self.rfile.read(length)
        type(self).calls += 1
        if type(self).calls == 1:
            message = {
                "role": "assistant",
                "content": "",
                "tool_calls": [
                    {
                        "id": "call_traces",
                        "function": {"name": "traces", "arguments": {"limit": 10}},
                    }
                ],
            }
        else:
            message = {"role": "assistant", "content": "trace inspected"}
        body = (json.dumps({"message": message, "done": True}) + "\n").encode()
        self.send_response(200)
        self.send_header("content-type", "application/x-ndjson")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


class OpenAIStreamingHandler(BaseHTTPRequestHandler):
    calls = 0
    requests = []

    def _event(self, value):
        self.wfile.write(f"data: {json.dumps(value)}\n\n".encode())
        self.wfile.flush()

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        request = json.loads(self.rfile.read(length))
        type(self).requests.append(request)
        type(self).calls += 1
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        if type(self).calls % 2 == 1:
            self._event(
                {
                    "choices": [
                        {
                            "index": 0,
                            "delta": {
                                "role": "assistant",
                                "tool_calls": [
                                    {
                                        "index": 0,
                                        "id": "call_read",
                                        "type": "function",
                                        "function": {
                                            "name": "read",
                                            "arguments": '{"path":"',
                                        },
                                    }
                                ],
                            },
                        }
                    ]
                }
            )
            self._event(
                {
                    "choices": [
                        {
                            "index": 0,
                            "delta": {
                                "tool_calls": [
                                    {
                                        "index": 0,
                                        "function": {"arguments": 'README.md"}'},
                                    }
                                ]
                            },
                            "finish_reason": "tool_calls",
                        }
                    ]
                }
            )
        else:
            self._event({"choices": [{"index": 0, "delta": {"content": "streamed "}}]})
            self._event(
                {
                    "choices": [
                        {
                            "index": 0,
                            "delta": {"content": "tool ok"},
                            "finish_reason": "stop",
                        }
                    ]
                }
            )
        self._event(
            {
                "choices": [],
                "usage": {
                    "prompt_tokens": 6000,
                    "completion_tokens": 8,
                    "prompt_tokens_details": {
                        "cached_tokens": 5120,
                        "cache_write_tokens": 0,
                    },
                    "completion_tokens_details": {"reasoning_tokens": 3},
                },
            }
        )
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def log_message(self, format, *args):
        pass


class McpBridgeTest(unittest.TestCase):
    def setUp(self):
        FakeOllamaHandler.calls = 0
        self.ollama = HTTPServer(("127.0.0.1", 0), FakeOllamaHandler)
        self.ollama_thread = threading.Thread(
            target=self.ollama.serve_forever, daemon=True
        )
        self.ollama_thread.start()
        self.state_dir = Path(tempfile.mkdtemp(prefix="lisp-agent-mcp-test-"))
        self.process = subprocess.Popen(
            [
                "python3",
                str(ROOT / "extensions/shift/shift_mcp.py"),
                "--state-dir",
                str(self.state_dir),
            ],
            cwd=ROOT,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.next_id = 1
        initialized = self.rpc(
            "initialize",
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "test", "version": "1"},
            },
        )
        self.assertEqual(initialized["protocolVersion"], "2025-06-18")

    def tearDown(self):
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=5)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            if stream is not None:
                stream.close()
        self.ollama.shutdown()
        self.ollama.server_close()
        shutil.rmtree(self.state_dir, ignore_errors=True)

    def rpc(self, method, params=None):
        request_id = self.next_id
        self.next_id += 1
        request = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            request["params"] = params
        assert self.process.stdin is not None
        assert self.process.stdout is not None
        self.process.stdin.write(json.dumps(request) + "\n")
        self.process.stdin.flush()
        response = json.loads(self.process.stdout.readline())
        self.assertEqual(response["id"], request_id)
        self.assertNotIn("error", response)
        return response["result"]

    def call(self, name, arguments=None):
        result = self.rpc("tools/call", {"name": name, "arguments": arguments or {}})
        self.assertFalse(result.get("isError"), result)
        return json.loads(result["content"][0]["text"])

    def test_codex_can_operate_one_live_session(self):
        tools = self.rpc("tools/list")["tools"]
        self.assertIn("live_session_send", {tool["name"] for tool in tools})
        self.assertIn("live_session_cancel", {tool["name"] for tool in tools})
        self.assertIn("live_session_recovery", {tool["name"] for tool in tools})
        self.assertIn("live_session_fork", {tool["name"] for tool in tools})
        self.assertIn("live_subagent_run", {tool["name"] for tool in tools})

        started = self.call("live_session_start", {"agent": "test/session-agent.scm"})
        self.assertTrue(started["running"])
        self.assertEqual(started["state"], "ready")
        self.assertIn("thinking off", started["output"])

        no_request = self.rpc(
            "tools/call",
            {"name": "live_session_approve", "arguments": {"approved": True}},
        )
        self.assertTrue(no_request.get("isError"))
        self.assertIn("not waiting", no_request["content"][0]["text"])

        response = self.call("live_session_send", {"text": "hello"})
        self.assertEqual(response["state"], "ready")
        self.assertIn("[mcp-test] hello", response["output"])

        recovery_path = self.state_dir / "sessions/default/interrupted-tool.json"
        recovery_path.write_text(
            json.dumps(
                {
                    "version": 1,
                    "state": "execution-started",
                    "tool": "read",
                    "arguments": {"path": "README.md"},
                    "generation_id": 1,
                    "created_at": "2026-09-04T00:00:00Z",
                }
            )
            + "\n"
        )
        recovery = self.call("live_session_recovery", {"action": "status"})
        self.assertIn("may have partially executed", recovery["output"])
        retried = self.call("live_session_recovery", {"action": "retry"})
        self.assertEqual(retried["state"], "needs_approval")
        retried = self.call("live_session_approve", {"approved": True})
        self.assertIn("Recovery result:", retried["output"])
        self.assertFalse(recovery_path.exists())

        self.call("live_session_send", {"text": "second"})
        self.call("live_session_send", {"text": "third"})
        compacted = self.call("live_session_compact")
        self.assertIn("compacted", compacted["output"])
        traces = self.call("live_session_traces", {"query": "session.compact"})
        self.assertIn("session.compact", traces["output"])
        self.assertIn("matches across", traces["output"])
        span_match = re.search(r"span=([0-9a-f]+)", traces["output"])
        self.assertIsNotNone(span_match)
        exact_trace = self.call("live_session_traces", {"span_id": span_match.group(1)})
        self.assertIn('"name":"session.compact"', exact_trace["output"])

        setting = self.call("live_session_set", {"name": "thinking", "value": "on"})
        self.assertIn("thinking on", setting["output"])

        prompt = self.call("live_session_add_prompt", {"text": "Call me Paul."})
        self.assertIn("generation 2", prompt["output"])

        extensions = self.call("live_extension", {"action": "list"})
        self.assertEqual(extensions["state"], "ready")

        transcript = self.call("live_session_read", {"cursor": 0})
        self.assertIn("[mcp-test] hello", transcript["output"])

        port = self.ollama.server_address[1]
        shell_settings = self.call(
            "live_session_eval",
            {
                "expression": (
                    f'(begin (set! agent-model "fake") '
                    f'(set! agent-base-url "http://127.0.0.1:{port}") '
                    "(set! agent-tools '(shell)) "
                    "(set! agent-shell-policy 'ask))"
                )
            },
        )
        self.assertIn("generation 3", shell_settings["output"])

        approval_boundary = self.call(
            "live_session_send",
            {"text": "run the requested shell", "timeout_seconds": 10},
        )
        self.assertEqual(approval_boundary["state"], "needs_approval")
        self.assertIn("printf approved", approval_boundary["output"])

        # The bridge sends only this one byte. If the terminal still required
        # Enter, this call would time out instead of reaching the next prompt.
        approved = self.call(
            "live_session_approve", {"approved": True, "timeout_seconds": 10}
        )
        self.assertEqual(approved["state"], "ready", approved)
        self.assertIn("shell approved", approved["output"])

        stopped = self.call("live_session_stop")
        self.assertFalse(stopped["running"])

    def test_named_sessions_run_independently_and_resume(self):
        alpha = self.call(
            "live_session_start",
            {
                "session": "alpha",
                "mode": "new",
                "agent": "test/session-agent.scm",
                "prompt": "alpha opening",
            },
        )
        beta = self.call(
            "live_session_start",
            {"session": "beta", "mode": "new", "agent": "test/session-agent.scm"},
        )
        self.assertNotEqual(alpha["pid"], beta["pid"])
        self.assertIn("[mcp-test] alpha opening", alpha["output"])
        self.assertEqual(alpha["next_turn"], 2)

        self.assertIn(
            "[mcp-test] alpha message",
            self.call(
                "live_session_send",
                {"session": "alpha", "text": "alpha message"},
            )["output"],
        )
        self.assertIn(
            "[mcp-test] beta message",
            self.call(
                "live_session_send",
                {"session": "beta", "text": "beta message"},
            )["output"],
        )
        self.call(
            "live_session_set",
            {"session": "alpha", "name": "thinking", "value": "on"},
        )

        sessions = self.call("live_sessions_list")["sessions"]
        self.assertEqual([entry["session"] for entry in sessions], ["alpha", "beta"])
        self.assertTrue(all(entry["running"] for entry in sessions))

        self.call("live_session_stop", {"session": "alpha"})
        resumed = self.call(
            "live_session_start",
            {"session": "alpha", "mode": "resume", "agent": "test/session-agent.scm"},
        )
        self.assertIn("session alpha · resumed · turn 3", resumed["output"])
        self.assertIn("generation 1", resumed["output"])
        self.assertIn("thinking on", resumed["output"])
        self.assertEqual(resumed["next_turn"], 3)
        self.assertEqual(resumed["generation"], 1)
        self.assertTrue(
            self.call("live_session_status", {"session": "beta"})["running"]
        )

        self.call("live_session_stop", {"session": "alpha"})
        existing = self.rpc(
            "tools/call",
            {
                "name": "live_session_start",
                "arguments": {
                    "session": "alpha",
                    "mode": "new",
                    "agent": "test/session-agent.scm",
                },
            },
        )
        self.assertTrue(existing.get("isError"))
        self.assertIn("already exists", existing["content"][0]["text"])

        missing = self.rpc(
            "tools/call",
            {
                "name": "live_session_start",
                "arguments": {
                    "session": "missing",
                    "mode": "resume",
                    "agent": "test/session-agent.scm",
                },
            },
        )
        self.assertTrue(missing.get("isError"))
        self.assertIn("does not exist", missing["content"][0]["text"])


class ExtensionToolMappingTest(unittest.TestCase):
    def test_every_extension_action_maps_to_the_live_repl(self):
        class RecordingSession:
            def __init__(self):
                self.commands = []

            def send(self, command, timeout):
                self.commands.append(command)
                return {"state": "ready", "output": command, "cursor": 1}

        session = RecordingSession()
        state_root = Path(tempfile.mkdtemp(prefix="lisp-agent-recording-test-"))
        server = McpServer(
            ROOT, state_root, lambda project_root, state_dir, name: session
        )
        server.call_tool("live_extension", {"action": "list"})
        server.call_tool(
            "live_extension",
            {
                "action": "create",
                "name": "terse",
                "expression": '(set! agent-system-prompt "Terse")',
            },
        )
        server.call_tool("live_extension", {"action": "load", "name": "terse"})
        server.call_tool("live_extension", {"action": "disable", "name": "terse"})
        server.call_tool("live_extension", {"action": "export", "name": "snapshot"})
        server.call_tool("live_session_traces", {})
        server.call_tool("live_session_compact", {})
        server.call_tool("live_session_recovery", {"action": "status"})
        server.call_tool("live_session_recovery", {"action": "discard"})
        self.assertEqual(
            session.commands,
            [
                "/extensions",
                '/extension-create terse (set! agent-system-prompt "Terse")',
                "/extension-load terse",
                "/extension-disable terse",
                "/extension-export snapshot",
                "/traces",
                "/compact",
                "/recover",
                "/recover discard",
            ],
        )
        shutil.rmtree(state_root, ignore_errors=True)


class HotReloadTest(unittest.TestCase):
    def test_running_process_activates_valid_saves_and_rejects_invalid_ones(self):
        project_root = Path(tempfile.mkdtemp(prefix="lisp-agent-watch-test-"))
        session = None
        try:
            (project_root / "bin").mkdir()
            (project_root / "agent").mkdir()
            (project_root / "extensions").mkdir()
            (project_root / "extensions/shift").symlink_to(
                ROOT / "extensions/shift", target_is_directory=True
            )
            (project_root / "src").symlink_to(ROOT / "src", target_is_directory=True)
            shutil.copy2(ROOT / "bin/shift", project_root / "bin/shift")
            agent_path = project_root / "agent/default.scm"
            source = (ROOT / "test/session-agent.scm").read_text()
            agent_path.write_text(source)

            session = LiveSession(project_root, project_root / ".shift")
            started = session.start()
            self.assertEqual(started["state"], "ready")
            cursor = started["cursor"]

            updated = source.replace("[mcp-test] ", "[hot-reloaded] ")
            agent_path.write_text(updated)
            valid_notice = self.wait_for_text(session, cursor, "agent image reloaded")
            self.assertIn("generation 2", valid_notice)

            response = session.send("hello", 5)
            self.assertIn("[hot-reloaded] hello", response["output"])

            cursor = response["cursor"]
            invalid = updated.replace(
                "(define agent-name", "(define missing-agent-name"
            )
            agent_path.write_text(invalid)
            rejected_notice = self.wait_for_text(session, cursor, "change rejected")
            self.assertIn("generation 2 remains active", rejected_notice)
            time.sleep(0.6)
            self.assertEqual(session.read(cursor)["output"].count("change rejected"), 1)

            response = session.send("still there", 5)
            self.assertIn("[hot-reloaded] still there", response["output"])

            cursor = response["cursor"]
            launcher = project_root / "bin/shift"
            launcher.write_text(launcher.read_text() + "\n# stable runtime drift\n")
            agent_path.write_text(
                updated.replace("[hot-reloaded] ", "[requires-restart] ")
            )
            restart_notice = self.wait_for_text(session, cursor, "restart Shift")
            self.assertIn("generation 2 remains active", restart_notice)
            response = session.send("old runtime stays live", 5)
            self.assertIn("[hot-reloaded] old runtime stays live", response["output"])
        finally:
            if session is not None:
                session.stop()
            shutil.rmtree(project_root, ignore_errors=True)

    @staticmethod
    def wait_for_text(session, cursor, expected):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            output = session.read(cursor)["output"]
            if expected in output:
                return output
            time.sleep(0.05)
        raise AssertionError(f"timed out waiting for {expected!r}; output={output!r}")


class OpenAIStreamingTest(unittest.TestCase):
    def test_sse_streams_tool_calls_and_marks_cache_hits(self):
        OpenAIStreamingHandler.calls = 0
        OpenAIStreamingHandler.requests = []
        server = HTTPServer(("127.0.0.1", 0), OpenAIStreamingHandler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        project_root = Path(tempfile.mkdtemp(prefix="shift-openai-sse-test-"))
        session = None
        try:
            (project_root / "bin").mkdir()
            (project_root / "agent").mkdir()
            (project_root / "extensions").mkdir()
            (project_root / "extensions/shift").symlink_to(
                ROOT / "extensions/shift", target_is_directory=True
            )
            (project_root / "src").symlink_to(ROOT / "src", target_is_directory=True)
            shutil.copy2(ROOT / "bin/shift", project_root / "bin/shift")
            (project_root / "README.md").write_text("# deterministic SSE fixture\n")
            image = (ROOT / "test/session-agent.scm").read_text()
            image = image.replace(
                "(define agent-provider 'ollama)", "(define agent-provider 'openai)"
            )
            image = image.replace(
                '(define agent-model "demo")', '(define agent-model "fake")'
            )
            image = image.replace(
                '(define agent-base-url "http://127.0.0.1:11434")',
                f'(define agent-base-url "http://127.0.0.1:{server.server_address[1]}")',
            )
            (project_root / "agent/default.scm").write_text(image)
            session = LiveSession(project_root, project_root / ".shift")
            self.assertEqual(session.start()["state"], "ready")

            session.send("/mode plan")
            response = session.send("read the readme", 10)
            self.assertEqual(response["state"], "ready")
            self.assertIn("assistant> streamed tool ok", response["output"])
            self.assertEqual(OpenAIStreamingHandler.calls, 2)
            self.assertTrue(
                all(request["stream"] for request in OpenAIStreamingHandler.requests)
            )
            self.assertTrue(
                all(
                    request["stream_options"]["include_usage"]
                    for request in OpenAIStreamingHandler.requests
                )
            )

            trace_output = session.send("/traces llm.prompt_cache.status", 5)["output"]
            self.assertIn("cache=hit (5120 tokens)", trace_output)
            traces = (project_root / ".shift/sessions/default/traces.jsonl").read_text()
            self.assertIn('"llm.prompt_cache.hit":true', traces)
            self.assertIn('"llm.token_count.prompt_uncached":880', traces)
        finally:
            if session is not None:
                session.stop()
            server.shutdown()
            server.server_close()
            shutil.rmtree(project_root, ignore_errors=True)


class SubagentMilestoneTest(unittest.TestCase):
    def test_forked_children_compare_from_one_checkpoint_with_linked_traces(self):
        OpenAIStreamingHandler.calls = 0
        OpenAIStreamingHandler.requests = []
        provider = HTTPServer(("127.0.0.1", 0), OpenAIStreamingHandler)
        threading.Thread(target=provider.serve_forever, daemon=True).start()
        project_root = Path(tempfile.mkdtemp(prefix="shift-subagent-test-"))
        bridge = None
        resumed_child = None
        try:
            (project_root / "bin").mkdir()
            (project_root / "agent").mkdir()
            (project_root / "extensions").mkdir()
            (project_root / "extensions/shift").symlink_to(
                ROOT / "extensions/shift", target_is_directory=True
            )
            (project_root / "src").symlink_to(ROOT / "src", target_is_directory=True)
            shutil.copy2(ROOT / "bin/shift", project_root / "bin/shift")
            (project_root / "README.md").write_text(
                "# deterministic subagent evidence\n"
            )
            (project_root / "extensions/candidate.scm").write_text(
                '(set! agent-system-prompt "candidate generation")\n'
            )
            image = (ROOT / "test/session-agent.scm").read_text()
            image = image.replace(
                "(define agent-provider 'ollama)", "(define agent-provider 'openai)"
            )
            image = image.replace(
                '(define agent-model "demo")', '(define agent-model "fake")'
            )
            image = image.replace(
                '(define agent-base-url "http://127.0.0.1:11434")',
                f'(define agent-base-url "http://127.0.0.1:{provider.server_address[1]}")',
            )
            (project_root / "agent/default.scm").write_text(image)
            state_root = project_root / ".shift"
            bridge = McpServer(project_root, state_root)
            started = json.loads(
                bridge.call_tool(
                    "live_session_start",
                    {
                        "session": "parent",
                        "mode": "new",
                        "agent": "agent/default.scm",
                    },
                )["content"][0]["text"]
            )
            self.assertEqual(started["state"], "ready")
            bridge.call_tool("live_session_send", {"session": "parent", "text": "/mode plan"})

            with self.assertRaisesRegex(ValueError, "read, rg, traces, or live_eval"):
                bridge.call_tool(
                    "live_subagent_run",
                    {
                        "parent_session": "parent",
                        "child_session": "too-wide",
                        "task": "try shell",
                        "tools": ["shell"],
                    },
                )

            with self.assertRaisesRegex(ValueError, "subset"):
                bridge.call_tool(
                    "live_subagent_run",
                    {
                        "parent_session": "parent",
                        "child_session": "not-in-parent",
                        "task": "inspect traces",
                        "tools": ["traces"],
                    },
                )

            def run_child(name, extension=None):
                arguments = {
                    "parent_session": "parent",
                    "child_session": name,
                    "task": "read the readme and report success",
                    "tools": ["read"],
                    "agent": "agent/default.scm",
                    "assert_tool": "read",
                    "assert_output_contains": "deterministic subagent evidence",
                }
                if extension:
                    arguments["extension"] = extension
                    arguments["proposal_name"] = "candidate-proposal"
                result = bridge.call_tool("live_subagent_run", arguments)
                return json.loads(result["content"][0]["text"])

            baseline = run_child("baseline")
            candidate = run_child("candidate", "candidate")
            self.assertTrue(baseline["assertion"]["passed"])
            self.assertTrue(candidate["assertion"]["passed"])
            self.assertEqual(
                baseline["generation_ref"]["parent_fingerprint"],
                candidate["generation_ref"]["parent_fingerprint"],
            )
            self.assertEqual(
                baseline["generation_ref"]["parent_fingerprint"],
                baseline["generation_ref"]["child_fingerprint"],
            )
            self.assertNotEqual(
                candidate["generation_ref"]["parent_fingerprint"],
                candidate["generation_ref"]["child_fingerprint"],
            )
            self.assertEqual(candidate["extension_proposal"]["status"], "exported")
            self.assertFalse(candidate["extension_proposal"]["loaded"])
            self.assertTrue(
                (
                    state_root / "sessions/candidate/proposals/candidate-proposal.scm"
                ).is_file()
            )
            self.assertFalse(
                (project_root / "extensions/candidate-proposal.scm").exists()
            )
            self.assertEqual(
                json.loads(
                    (state_root / "sessions/candidate/authority.json").read_text()
                )["tool_ceiling"],
                ["read"],
            )
            parent_traces = (state_root / "sessions/parent/traces.jsonl").read_text()
            child_traces = (state_root / "sessions/candidate/traces.jsonl").read_text()
            self.assertIn('"name":"subagent.fanout"', parent_traces)
            self.assertIn('"name":"subagent.join"', parent_traces)
            self.assertIn('"name":"subagent.run"', child_traces)
            self.assertIn('"links":[', child_traces)

            resumed_child = LiveSession(project_root, state_root, "candidate")
            resumed = resumed_child.start("agent/default.scm", "resume")
            self.assertEqual(resumed["tool_ceiling"], ["read"])
            resumed_child.send("/eval (set! agent-tools '(shell))", 5)
            request_start = len(OpenAIStreamingHandler.requests)
            widened = resumed_child.send("try the newly configured tool", 10)
            self.assertEqual(widened["state"], "ready")
            self.assertTrue(
                all(
                    "tools" not in request
                    for request in OpenAIStreamingHandler.requests[request_start:]
                )
            )
        finally:
            if resumed_child is not None:
                resumed_child.stop()
            if bridge is not None:
                bridge.close()
            provider.shutdown()
            provider.server_close()
            shutil.rmtree(project_root, ignore_errors=True)


class CancellationTest(unittest.TestCase):
    def test_cancellation_interrupts_provider_and_preserves_the_prompt(self):
        SlowOllamaHandler.started.clear()
        SlowOllamaHandler.release.clear()
        server = ThreadingHTTPServer(("127.0.0.1", 0), SlowOllamaHandler)
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        project_root = Path(tempfile.mkdtemp(prefix="shift-cancel-test-"))
        session = None
        try:
            (project_root / "bin").mkdir()
            (project_root / "agent").mkdir()
            (project_root / "extensions").mkdir()
            (project_root / "extensions/shift").symlink_to(
                ROOT / "extensions/shift", target_is_directory=True
            )
            (project_root / "src").symlink_to(ROOT / "src", target_is_directory=True)
            shutil.copy2(ROOT / "bin/shift", project_root / "bin/shift")
            image = (ROOT / "test/session-agent.scm").read_text()
            image = image.replace(
                '(define agent-model "demo")', '(define agent-model "fake")'
            )
            image = image.replace(
                '(define agent-base-url "http://127.0.0.1:11434")',
                f'(define agent-base-url "http://127.0.0.1:{server.server_address[1]}")',
            )
            image = image.replace(
                "(define agent-tools '(read rg))", "(define agent-tools '())"
            )
            (project_root / "agent/default.scm").write_text(image)
            session = LiveSession(project_root, project_root / ".shift")
            self.assertEqual(session.start()["state"], "ready")

            result: dict[str, Any] = {}

            def run_turn():
                result.update(session.send("cancel me", 15))

            turn = threading.Thread(target=run_turn)
            turn.start()
            self.assertTrue(SlowOllamaHandler.started.wait(5))
            cancelled = session.cancel(5)
            self.assertEqual(cancelled["state"], "ready", cancelled)
            self.assertIn("turn cancelled", cancelled["output"])
            turn.join(5)
            self.assertFalse(turn.is_alive())
            self.assertEqual(result["state"], "ready")
        finally:
            SlowOllamaHandler.release.set()
            if session is not None:
                session.stop()
            server.shutdown()
            server.server_close()
            shutil.rmtree(project_root, ignore_errors=True)


class TraceToolTest(unittest.TestCase):
    def test_agent_can_inspect_its_session_scoped_traces(self):
        TraceOllamaHandler.calls = 0
        server = HTTPServer(("127.0.0.1", 0), TraceOllamaHandler)
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        project_root = Path(tempfile.mkdtemp(prefix="shift-trace-tool-test-"))
        session = None
        try:
            (project_root / "bin").mkdir()
            (project_root / "agent").mkdir()
            (project_root / "extensions").mkdir()
            (project_root / "extensions/shift").symlink_to(
                ROOT / "extensions/shift", target_is_directory=True
            )
            (project_root / "src").symlink_to(ROOT / "src", target_is_directory=True)
            shutil.copy2(ROOT / "bin/shift", project_root / "bin/shift")
            image = (ROOT / "test/session-agent.scm").read_text()
            image = image.replace(
                '(define agent-model "demo")', '(define agent-model "fake")'
            )
            image = image.replace(
                '(define agent-base-url "http://127.0.0.1:11434")',
                f'(define agent-base-url "http://127.0.0.1:{server.server_address[1]}")',
            )
            image = image.replace(
                "(define agent-tools '(read rg))", "(define agent-tools '(traces))"
            )
            (project_root / "agent/default.scm").write_text(image)
            session = LiveSession(project_root, project_root / ".shift")
            self.assertEqual(session.start()["state"], "ready")
            session.send("/mode plan")
            response = session.send("inspect your trace", 10)
            self.assertEqual(response["state"], "ready")
            self.assertIn("trace inspected", response["output"])
            checkpoint = json.loads(
                (project_root / ".shift/sessions/default/session.json").read_text()
            )
            tool_messages = [
                message
                for message in checkpoint["history"]
                if message.get("role") == "tool"
            ]
            self.assertTrue(tool_messages)
            self.assertIn('"session_id"', tool_messages[0]["content"])
            self.assertIn(
                '"name":"tool.traces"',
                (project_root / ".shift/sessions/default/traces.jsonl").read_text(),
            )
        finally:
            if session is not None:
                session.stop()
            server.shutdown()
            server.server_close()
            shutil.rmtree(project_root, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
