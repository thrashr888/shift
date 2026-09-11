"""External CLI grader; run with the candidate checkout as cwd."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path.cwd()


class RunListSource(unittest.TestCase):
    def invoke(self, project, commands):
        result = subprocess.run(
            [str(ROOT / "bin/shift"), "--agent", str(ROOT / "test/session-agent.scm"),
             "--no-watch", "--no-mcp", "--session", "check"],
            cwd=project, input=commands + "\n/quit\n", capture_output=True, text=True, timeout=20,
            env={**os.environ, "XDG_CONFIG_HOME": str(project / "config"), "GUILE_AUTO_COMPILE": "0"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def seed(self, path, prefixes):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"run-allow": prefixes}))

    def test_precedence_and_empty_sources(self):
        for source in ("default", "user", "project", "session"):
            for empty in (False, True):
                with self.subTest(source=source, empty=empty), tempfile.TemporaryDirectory() as tmp:
                    project = Path(tmp)
                    files = [project / "config/shift/settings.json", project / ".shift/settings.json",
                             project / ".shift/sessions/check/settings.json"]
                    rank = ["default", "user", "project", "session"].index(source)
                    for index in range(rank):
                        self.seed(files[index], [["shadowed", str(index)]])
                    if rank:
                        self.seed(files[rank - 1], [] if empty else [["make", "test"]])
                    output = self.invoke(project, "/run list")
                    if empty or source == "default":
                        self.assertIn(f"Run allowlist is empty ({source})", output)
                        self.assertIn("/run allow", output)
                    else:
                        rows = [line for line in output.splitlines() if line.startswith("allow ")]
                        self.assertEqual(rows, [f"allow make test ({source})"])

    def test_terminal_changes_and_resume_are_session_sourced(self):
        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp)
            self.seed(project / ".shift/settings.json", [["make", "test"]])
            output = self.invoke(project, "/run allow cargo test\n/run list")
            self.assertIn("allow make test (session)", output)
            self.assertIn("allow cargo test (session)", output)
            output = self.invoke(project, "/run deny make test\n/run list")
            rows = [line for line in output.splitlines() if line.startswith("allow ")]
            self.assertEqual(rows, ["allow cargo test (session)"])
            output = self.invoke(project, "/run list")
            self.assertIn("allow cargo test (session)", output)
            saved = json.loads((project / ".shift/sessions/check/settings.json").read_text())
            self.assertEqual(saved["run-allow"], [["cargo", "test"]])


if __name__ == "__main__":
    unittest.main()
