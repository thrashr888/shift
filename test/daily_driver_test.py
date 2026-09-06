"""Daily-driver contracts against the real CLI, PTY and in-process MCP server."""

import json
import os
from pathlib import Path
import pty
import select
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
BIN = str(ROOT / "bin/shift")
AGENT = str(ROOT / "test/session-agent.scm")


class DailyDriver(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="shift-daily-")
        self.project = Path(self.temp.name)
        self.env = {**os.environ, "XDG_CONFIG_HOME": str(self.project / "config")}
        self.env.pop("SHIFT_BUILTINS", None)

    def tearDown(self):
        self.temp.cleanup()

    def cli(self, text, *args):
        result = subprocess.run(
            [BIN, "--agent", AGENT, "--no-watch", *args],
            input=text,
            text=True,
            capture_output=True,
            cwd=self.project,
            env=self.env,
            timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_project_settings_resume_and_fork(self):
        output = self.cli("/thinking on\n/settings save\n/quit\n", "--session", "one")
        self.assertIn("Saved defaults:", output)
        self.assertTrue((self.project / ".shift/settings.json").exists())
        output = self.cli("/thinking off\n/quit\n", "--session", "one")
        self.assertIn("thinking on", output)
        self.assertIn("thinking on", self.cli("/quit\n", "--session", "two"))
        self.assertIn("thinking off", self.cli("/quit\n", "--resume", "one"))
        checkpoint = json.loads(
            (self.project / ".shift/sessions/one/session.json").read_text()
        )
        self.assertEqual(checkpoint["generation_id"], 1)
        self.assertEqual(checkpoint["patches"], [])
        self.cli("", "--fork-session", "one", "child")
        self.assertIn("thinking off", self.cli("/quit\n", "--resume", "child"))

    def test_user_defaults_and_no_patch_limit_for_preferences(self):
        self.cli("/thinking on\n/settings save user\n/quit\n", "--session", "one")
        other = self.project / "other"
        other.mkdir()
        result = subprocess.run(
            [BIN, "--agent", AGENT, "--no-watch"],
            input="/quit\n",
            text=True,
            capture_output=True,
            cwd=other,
            env=self.env,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("thinking on", result.stdout)
        self.cli("/thinking on\n/thinking off\n" * 50 + "/quit\n", "--session", "many")
        data = json.loads(
            (self.project / ".shift/sessions/many/session.json").read_text()
        )
        self.assertEqual(data["patches"], [])

    def test_dotenv_is_data_and_credentials_are_not_saved(self):
        (self.project / ".env").write_text(
            'CLAUDE_API_KEY="fixture_secret"\nDONT_RUN=$(touch should-not-exist)\n'
        )
        self.cli("/settings save\n/quit\n", "--session", "one")
        self.assertFalse((self.project / "should-not-exist").exists())
        for path in (self.project / ".shift").rglob("*"):
            if path.is_file():
                self.assertNotIn("fixture_secret", path.read_text())

    def test_mcp_stdio_is_only_json(self):
        requests = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": {"name": "shift_status"},
            },
        ]
        output = self.cli("\n".join(map(json.dumps, requests)) + "\n", "--mcp")
        results = list(map(json.loads, output.splitlines()))
        self.assertEqual(len(results), 2)
        self.assertEqual(results[0]["result"]["serverInfo"]["name"], "shift")
        status = json.loads(results[1]["result"]["content"][0]["text"])
        self.assertEqual(status["project"], str(self.project.resolve()))

    def test_http_mcp_shares_live_process_and_closes(self):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        process = subprocess.Popen(
            [
                BIN,
                "--agent",
                AGENT,
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
            env=self.env,
            text=True,
        )

        def call(name, args=None, headers=None):
            request = urllib.request.Request(
                f"http://127.0.0.1:{port}/mcp",
                data=json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 1,
                        "method": "tools/call",
                        "params": {"name": name, "arguments": args or {}},
                    }
                ).encode(),
                headers={
                    "Content-Type": "application/json",
                    "Accept": "application/json, text/event-stream",
                    **(headers or {}),
                },
            )
            with urllib.request.urlopen(request, timeout=5) as response:
                return json.load(response)["result"]

        try:
            deadline = time.monotonic() + 5
            while True:
                try:
                    status = json.loads(call("shift_status")["content"][0]["text"])
                    break
                except urllib.error.URLError:
                    if time.monotonic() > deadline:
                        raise
                    time.sleep(0.025)
            self.assertEqual(status["pid"], process.pid)
            self.assertIn(
                "hello", call("shift_prompt", {"text": "hello"})["content"][0]["text"]
            )
            process.stdin.write("/thinking on\n")
            process.stdin.flush()
            deadline = time.monotonic() + 5
            while True:
                status = json.loads(call("shift_status")["content"][0]["text"])
                if status["settings"]["agent-thinking"]:
                    break
                self.assertLess(time.monotonic(), deadline)
            self.assertEqual(status["turn"], 2)
            rejected = call(
                "shift_inspect", {"command": "/eval (set! agent-tools '(shell))"}
            )
            self.assertTrue(rejected["isError"])
            with self.assertRaises(urllib.error.HTTPError) as error:
                call("shift_status", headers={"Origin": "https://hostile.example"})
            self.assertEqual(error.exception.code, 403)
            error.exception.close()
            with self.assertRaises(urllib.error.HTTPError) as error:
                call("shift_status", headers={"Host": "hostile.example"})
            self.assertEqual(error.exception.code, 403)
            error.exception.close()
            process.stdin.write("/quit\n")
            process.stdin.flush()
            output, errors = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, errors + output)
            with socket.socket() as sock:
                self.assertNotEqual(sock.connect_ex(("127.0.0.1", port)), 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    def test_up_down_history_survives_restart(self):
        def run(keys):
            master, slave = pty.openpty()
            process = subprocess.Popen(
                [
                    BIN,
                    "--agent",
                    AGENT,
                    "--no-watch",
                    "--no-mcp",
                    "--session",
                    "terminal",
                ],
                stdin=slave,
                stdout=slave,
                stderr=slave,
                cwd=self.project,
                env=self.env,
            )
            os.close(slave)
            output = b""

            def until_prompt():
                nonlocal output
                chunk = b""
                deadline = time.monotonic() + 5
                while b"shift> " not in chunk:
                    self.assertLess(
                        time.monotonic(), deadline, output.decode(errors="replace")
                    )
                    if select.select([master], [], [], 0.1)[0]:
                        data = os.read(master, 65536)
                        output += data
                        chunk += data

            try:
                until_prompt()
                for key in keys:
                    os.write(master, key)
                    until_prompt()
                os.write(master, b"/quit\n")
                deadline = time.monotonic() + 5
                while process.poll() is None:
                    self.assertLess(
                        time.monotonic(), deadline, output.decode(errors="replace")
                    )
                    if select.select([master], [], [], 0.05)[0]:
                        data = os.read(master, 65536)
                        output += data
                self.assertEqual(process.returncode, 0, output.decode(errors="replace"))
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                os.close(master)
            return output.decode(errors="replace")

        output = run([b"first prompt\n", b"second prompt\n", b"draft\x1b[A\x1b[B\n"])
        self.assertIn("[mcp-test] draft", output)
        # The last submitted command was /quit; two up arrows select draft.
        output = run([b"\x1b[A\x1b[A\n"])
        self.assertIn("[mcp-test] draft", output)
        saved = list(
            map(
                json.loads,
                (self.project / ".shift/input-history.jsonl").read_text().splitlines(),
            )
        )
        self.assertIn("first prompt", saved)


if __name__ == "__main__":
    unittest.main()
