"""Dogfood snapshots and grading through a tiny deterministic fake agent."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("evals", Path(__file__).resolve().parents[1] / "scripts/evals.py")
evals = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(evals)


class DogfoodDriver(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="shift-eval-driver-")
        self.root = Path(self.temp.name)
        (self.root / "bin").mkdir()
        agent = self.root / "bin/shift"
        agent.write_text('''#!/usr/bin/env python3
import json,sys
from pathlib import Path
assert not Path('evals').exists(), 'hidden fixtures leaked'
assert Path('value.txt').read_text() == 'working tree'
assert Path('untracked.txt').read_text() == 'included'
Path('value.txt').write_text('fixed')
receipt = Path(sys.argv[sys.argv.index('--receipt') + 1])
receipt.write_text(json.dumps({'status':'ok','rounds':1,'tool_calls':{'edit':1},
 'tokens':{'prompt':100,'completion':10},'changed':[{'path':'value.txt'}],'runs':[]}))
print('fixed')
''')
        agent.chmod(0o755)
        (self.root / "Makefile").write_text("build test:\n\t@true\n")
        (self.root / ".gitignore").write_text("evals/work/\nevals/results/\n.env\n")
        (self.root / "value.txt").write_text("committed")
        task = self.root / "evals/dogfood/example"
        task.mkdir(parents=True)
        (task / "task.md").write_text("Set value.txt to fixed.")
        (task / "test.py").write_text("from pathlib import Path\nimport sys\nsys.exit(0 if Path('value.txt').read_text() == 'fixed' else 1)\n")
        for command in (["git", "init", "-q"], ["git", "add", "-A"],
                        ["git", "-c", "user.name=fixture", "-c", "user.email=fixture@localhost",
                         "-c", "commit.gpgsign=false", "commit", "-qm", "fixture"]):
            subprocess.run(command, cwd=self.root, check=True, capture_output=True)
        (self.root / "value.txt").write_text("working tree")
        (self.root / "untracked.txt").write_text("included")
        self.patches = patch.multiple(evals, ROOT=self.root, EVALS=self.root / "evals",
                                      WORK=self.root / "evals/work", RESULTS=self.root / "evals/results")
        self.patches.start()
        self.args = argparse.Namespace(tasks="example", model="fake", rounds=4, budget=2000,
                                       context_limit=8192, timeout=10, run_id="trial")

    def tearDown(self):
        self.patches.stop()
        self.temp.cleanup()

    def test_current_tree_isolated_from_hidden_tests_and_results_graded(self):
        with patch.object(evals, "memory_snapshot", return_value={"pressure": 1}):
            evals.dogfood(self.args)
        output = self.root / "evals/results/trial"
        record = json.loads((output / "results.jsonl").read_text())
        self.assertTrue(record["resolved"])
        self.assertEqual(record["baseline_exit_code"], 1)
        self.assertEqual(record["grade_exit_code"], 0)
        self.assertEqual(record["rounds"], 1)
        self.assertEqual(record["tokens"]["prompt"], 100)
        self.assertIn("+fixed", (output / "patches/example.diff").read_text())
        self.assertEqual((self.root / "value.txt").read_text(), "working tree")
        repo = self.root / "evals/work/dogfood/trial/example/repo"
        tracked = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", "HEAD"], cwd=repo, text=True)
        self.assertNotIn("evals/", tracked)
        self.assertIn("untracked.txt", tracked)
        with self.assertRaises(FileExistsError):
            evals.dogfood(self.args)

    def test_hidden_pass_with_regression_failure_is_not_resolved(self):
        (self.root / "Makefile").write_text("build:\n\t@true\ntest:\n\t@false\n")
        with patch.object(evals, "memory_snapshot", return_value={"pressure": 1}):
            evals.dogfood(self.args)
        record = json.loads((self.root / "evals/results/trial/results.jsonl").read_text())
        self.assertEqual(record["grade_exit_code"], 0)
        self.assertNotEqual(record["regression_exit_code"], 0)
        self.assertFalse(record["resolved"])

    def test_interrupt_preserves_patch_without_grading_or_next_task(self):
        original = evals.logged_run
        calls = []
        def interrupt_model(command, repo, env, timeout, prefix):
            calls.append(prefix.name)
            if prefix.name == "model":
                (repo / "value.txt").write_text("partial")
                Path(str(prefix) + ".stdout.log").write_text("")
                Path(str(prefix) + ".stderr.log").write_text("")
                raise KeyboardInterrupt
            return original(command, repo, env, timeout, prefix)
        self.args.tasks = "example,second"
        import shutil
        shutil.copytree(self.root / "evals/dogfood/example", self.root / "evals/dogfood/second")
        with patch.object(evals, "memory_snapshot", return_value={"pressure": 1}), \
             patch.object(evals, "logged_run", side_effect=interrupt_model):
            with self.assertRaises(SystemExit) as stopped:
                evals.dogfood(self.args)
        self.assertEqual(stopped.exception.code, 130)
        output = self.root / "evals/results/trial"
        record = json.loads((output / "results.jsonl").read_text())
        self.assertEqual(record["failure_class"], "user_stop")
        self.assertIsNone(record["resolved"])
        self.assertIsNone(record["grade_exit_code"])
        self.assertIn("+partial", (output / "patches/example.diff").read_text())
        self.assertEqual(calls, ["baseline-build", "baseline", "model"])
        self.assertFalse((self.root / "evals/work/dogfood/trial/second").exists())

    def test_pressure_prevents_starting_a_task(self):
        with patch.object(evals, "memory_snapshot", return_value={"pressure": 2}):
            with self.assertRaisesRegex(RuntimeError, "memory pressure"):
                evals.dogfood(self.args)
        self.assertFalse((self.root / "evals/work").exists())

    def test_timeout_is_recorded_and_output_stays_on_disk(self):
        code = "import time; print('started', flush=True); time.sleep(30)"
        prefix = self.root / "timed"
        result = evals.logged_run([sys.executable, "-c", code], self.root, dict(os.environ), .2, prefix)
        self.assertEqual(result, 124)
        self.assertEqual(evals.log_tail(self.root / "timed.stdout.log").strip(), "started")


if __name__ == "__main__":
    unittest.main()
