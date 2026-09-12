"""Default curses dispatch and backend lifecycle, with no model or user state."""

import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import struct
import subprocess
import tempfile
import termios
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
BIN = str(ROOT / "bin/shift")
AGENT = str(ROOT / "test/session-agent.scm")


class LaunchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix=".tui-launch-", dir=ROOT)
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name)
        self.env = {
            **os.environ,
            "XDG_CONFIG_HOME": str(self.project / "config"),
            "HOME": str(self.project),
            "SHIFT_BUILTINS": "",
            "TERM": "xterm-256color",
            "GUILE_AUTO_COMPILE": "0",
        }
        for key in ("SHIFT_CONTROL_FD", "SHIFT_UI_EVENT_FD", "SHIFT_UI_COMMAND_FD"):
            self.env.pop(key, None)

    def cli(self, *args, text=""):
        return subprocess.run(
            [BIN, "--agent", AGENT, "--no-watch", "--no-mcp", *args],
            input=text, text=True, capture_output=True, cwd=self.project,
            env=self.env, timeout=30,
        )

    def test_option_aware_dispatch_matrix(self):
        install = self.project / "install"
        for directory in ("bin", "scripts", "fakebin"):
            (install / directory).mkdir(parents=True)
        shutil.copy2(BIN, install / "bin/shift")
        stub = (
            "#!/usr/bin/env python3\n"
            "import json, sys\n"
            "print(json.dumps({'route': ROUTE, 'args': sys.argv[1:]}))\n"
        )
        for path, route in (("fakebin/guile", "backend"), ("scripts/tui.py", "tui")):
            target = install / path
            target.write_text(stub.replace("ROUTE", repr(route)))
            target.chmod(0o755)
        make = install / "fakebin/make"
        make.write_text("#!/bin/sh\nexit 0\n")
        make.chmod(0o755)
        env = {**self.env, "PATH": str(install / "fakebin") + ":" + os.environ["PATH"]}
        cases = [
            ([], True, True, "tui"),
            (["hello there"], True, True, "tui"),
            (["--tui"], True, True, "tui"),
            (["--resume", "saved", "continue"], True, True, "tui"),
            (["--new-session", "new"], True, True, "tui"),
            (["--watch", "--no-watch", "--no-mcp"], True, True, "tui"),
            (["--mcp-port", "7332"], True, True, "tui"),
            ([], False, False, "backend"),
            ([], False, True, "backend"),
            ([], True, False, "backend"),
            (["--print", "hello"], True, True, "backend"),
            (["-p", "hello"], True, True, "backend"),
            (["--mcp"], True, True, "backend"),
            (["--mcp-stdio"], True, True, "backend"),
            (["--list-sessions"], True, True, "backend"),
            (["--fork-session", "parent", "child"], True, True, "backend"),
            (["session-fork", "parent", "child"], True, True, "backend"),
            (["--help"], True, True, "backend"),
            (["-h"], True, True, "backend"),
            (["--tui", "--help"], True, True, "backend"),
            (["--repl"], True, True, "backend"),
            (["--unknown"], True, True, "backend"),
            (["--agent"], True, True, "backend"),
        ]
        # Every value-taking option must consume the value, even a mode-like one.
        for option in (
            "--agent", "--state-dir", "--session", "--new-session", "--resume",
            "--mode", "--model", "--allow-run", "--set", "--receipt", "--mcp-port",
        ):
            cases.append(([option, "--help"], True, True, "tui"))
            cases.append(([option, "--tui"], False, False, "backend"))
        for args, tty_in, tty_out, expected in cases:
            with self.subTest(args=args, stdin=tty_in, stdout=tty_out):
                master, slave = pty.openpty()
                try:
                    process = subprocess.Popen(
                        [str(install / "bin/shift"), *args], cwd=self.project, env=env,
                        stdin=slave if tty_in else subprocess.DEVNULL,
                        stdout=slave if tty_out else subprocess.PIPE,
                        stderr=subprocess.PIPE,
                    )
                    output, errors = process.communicate(timeout=10)
                    self.assertEqual(process.returncode, 0, errors)
                    if tty_out:
                        self.assertTrue(select.select([master], [], [], 2)[0])
                        output = os.read(master, 65536)
                    result = json.loads(output)
                    self.assertEqual(result["route"], expected)
                    if expected == "tui":
                        self.assertEqual(result["args"], args)
                finally:
                    os.close(master)
                    os.close(slave)
        for fd_name in ("SHIFT_CONTROL_FD", "SHIFT_UI_EVENT_FD", "SHIFT_UI_COMMAND_FD"):
            with self.subTest(bridge=fd_name):
                master, slave = pty.openpty()
                try:
                    process = subprocess.Popen(
                        [str(install / "bin/shift")], cwd=self.project,
                        env={**env, fd_name: "99"}, stdin=slave, stdout=slave,
                        stderr=subprocess.PIPE,
                    )
                    _, errors = process.communicate(timeout=10)
                    self.assertEqual(process.returncode, 0, errors)
                    self.assertEqual(json.loads(os.read(master, 65536))["route"], "backend")
                finally:
                    os.close(master)
                    os.close(slave)

    def test_real_script_print_help_and_session_utilities(self):
        for flag in ("--print", "-p"):
            result = self.cli(flag, "hello")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "[mcp-test] hello")
        result = self.cli("--session", "one", "initial", text="second\n/quit\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[mcp-test] initial", result.stdout)
        self.assertIn("[mcp-test] second", result.stdout)
        self.assertNotIn("\x1b[", result.stdout)
        result = self.cli("--fork-session", "one", "child")
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.cli("--list-sessions")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(set(result.stdout.splitlines()), {"one", "child"})
        result = self.cli("--resume", "child", text="/quit\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.cli("--tui", "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Interactive terminals open curses", result.stdout)
        for flag in ("--repl", "--mcp-stdio"):
            result = self.cli(flag)
            self.assertEqual(result.returncode, 2)
            self.assertIn(f"Unknown argument: {flag}", result.stderr)

    def test_real_default_curses_positional_prompt_and_resume(self):
        for options in (
            ["--session", "terminal", "startup prompt"],
            ["--tui", "--resume", "terminal"],
        ):
            with self.subTest(options=options):
                master, slave = pty.openpty()
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
                process = subprocess.Popen(
                    [BIN, "--agent", AGENT, "--no-watch", *options],
                    stdin=slave, stdout=slave, stderr=slave,
                    cwd=self.project, env=self.env,
                )
                os.close(slave)
                output = b""
                try:
                    deadline = time.monotonic() + 30
                    while b"[mcp-test] startup prompt" not in output:
                        self.assertLess(time.monotonic(), deadline, output.decode(errors="replace"))
                        self.assertIsNone(process.poll(), output.decode(errors="replace"))
                        if select.select([master], [], [], 0.1)[0]:
                            output += os.read(master, 65536)
                    self.assertIn(b"\x1b[", output)
                    os.write(master, b"/quit\n")
                    while process.poll() is None:
                        self.assertLess(time.monotonic(), deadline, output.decode(errors="replace"))
                        if select.select([master], [], [], 0.1)[0]:
                            try:
                                output += os.read(master, 65536)
                            except OSError as error:
                                if error.errno != errno.EIO:
                                    raise
                    self.assertEqual(process.returncode, 0, output.decode(errors="replace"))
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.wait(timeout=5)
                    os.close(master)
        saved = json.loads((self.project / ".shift/sessions/terminal/session.json").read_text())
        self.assertEqual(saved["next_turn"], 2)

    def test_working_events_cover_initial_turn_commands_errors_and_not_blank_input(self):
        for ui in (False, True):
            with self.subTest(ui=ui):
                control_path = self.project / "control.jsonl"
                with control_path.open("w") as control, (self.project / "ui.jsonl").open("w") as events:
                    env = {**self.env, "SHIFT_CONTROL_FD": str(control.fileno())}
                    if ui:
                        env["SHIFT_UI_EVENT_FD"] = str(events.fileno())
                    result = subprocess.run(
                        [BIN, "--agent", AGENT, "--no-watch", "--no-mcp", "initial"],
                        input="\n/show\n/eval invalid\nhello\n/quit\n",
                        text=True, capture_output=True, cwd=self.project, env=env,
                        pass_fds=(control.fileno(), events.fileno()), timeout=30,
                    )
                self.assertEqual(result.returncode, 0, result.stderr)
                controls = [json.loads(line) for line in control_path.read_text().splitlines()]
                states = [event["state"] for event in controls]
                if ui:
                    self.assertEqual(states, [
                        "working", "ready", "ready", "working", "ready",
                        "working", "ready", "working", "ready", "working",
                    ])
                else:
                    self.assertEqual(states, ["ready"] * 5)
                self.assertTrue(any(e["state"] == "ready" and e["status"] == "error" for e in controls))
                self.assertTrue(all(e["status"] == "ok" for e in controls if e["state"] == "working"))


if __name__ == "__main__":
    unittest.main()
