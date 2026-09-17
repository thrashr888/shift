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
        agent = self.root / "bin/shift-agent"
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




class SessionReview(unittest.TestCase):
    def test_review_reports_limits_failures_waits_and_judge_disagreements(self):
        with tempfile.TemporaryDirectory(prefix="shift-review-") as tmp:
            d = Path(tmp)
            (d / "receipts.jsonl").write_text(
                json.dumps({"turn": 1, "at": "2026-09-16T22:00:10Z", "status": "ok", "error": None, "rounds": 2, "tool_calls": {"read": 1}, "runs": [], "duration_ms": 5000}) + "\n" +
                json.dumps({"turn": 2, "at": "2026-09-16T22:10:00Z", "status": "failed", "error": "tool round limit reached: 6 rounds", "rounds": 7,
                            "tool_calls": {"run": 3, "read": 2}, "runs": [{"exit_code": 0}, {"exit_code": 1}], "duration_ms": 500000}) + "\n" +
                json.dumps({"turn": 2, "at": "2026-09-16T22:20:00Z", "status": "ok", "error": None, "rounds": 1, "tool_calls": {}, "runs": [], "duration_ms": 3000}) + "\n")
            (d / "events.scm-log").write_text(
                '((timestamp . "2026-09-16T22:00:00Z") (kind . user-input) (turn . 1) (text . "hi"))\n'
                '((timestamp . "2026-09-16T22:01:00Z") (kind . user-input) (turn . 2) (text . "review"))\n'
                '((timestamp . "2026-09-16T22:01:10Z") (kind . tool-call) (tool . "read") (arguments . "{\\"path\\":\\"a.scm\\"}"))\n'
                '((timestamp . "2026-09-16T22:02:10Z") (kind . tool-approval) (tool . "read") (mode . manual) (decision . ask) (approved . #t))\n'
                '((timestamp . "2026-09-16T22:02:11Z") (kind . tool-call) (tool . "read") (arguments . "{\\"path\\":\\"a.scm\\"}"))\n'
                '((timestamp . "2026-09-16T22:02:12Z") (kind . tool-approval) (tool . "read") (mode . manual) (decision . allow) (approved . #t))\n'
                '((timestamp . "2026-09-16T22:02:13Z") (kind . tool-result) (tool . "run") (output . "tool failed (x): boom"))\n'
                '((timestamp . "2026-09-16T22:15:00Z") (kind . user-input) (turn . 2) (text . "explain"))\n')
            (d / "judge.jsonl").write_text(json.dumps({"turn": 2, "at": "2026-09-16T22:03:00Z", "tool": "run", "verdict": "block", "rule": "x", "human": "allow"}) + "\n" +
                                          json.dumps({"turn": 2, "at": "2026-09-16T22:04:00Z", "tool": "run", "verdict": "allow", "rule": "ok", "human": "allow"}) + "\n")
            rows = evals.session_review(d)
        self.assertEqual([r["turn"] for r in rows], [1, 2, 2])
        limited = rows[1]
        self.assertTrue(limited["limit"]);self.assertEqual(limited["failed_runs"], 1);self.assertEqual(limited["tool_errors"], 1)
        self.assertEqual(limited["repeated"], 1);self.assertEqual(limited["approval_wait"], 60)
        self.assertEqual((limited["judged"], limited["false_blocks"]), (2, 1))
        self.assertIn("ended at a limit", evals.session_flags(limited));self.assertIn("1 false block(s)", evals.session_flags(limited))
        self.assertEqual(rows[2]["status"], "ok");self.assertEqual(rows[2]["judged"], 0)


class JudgeEvals(unittest.TestCase):
    def test_report_counts_false_blocks_and_allows_against_the_human(self):
        rows = evals.judge_report([
            {"tool": "run", "arguments": {"argv": ["rg", "x"]}, "human": "allow", "verdict": "block", "replay": {"verdict": "block", "rule": "not-allowlisted", "reason": "r", "ms": 5, "model": "m"}},
            {"tool": "run", "arguments": {"argv": ["rm", "-rf", "/"]}, "expected": "deny", "verdict": "block", "replay": {"verdict": "allow", "rule": "ok", "reason": "r", "ms": 7, "model": "m"}},
            {"tool": "read", "arguments": {"path": "a"}, "human": "none", "verdict": "allow", "replay": {"verdict": "allow", "rule": "ok", "reason": "r", "ms": 9, "model": "m"}}])
        self.assertEqual([r["agree"] for r in rows], [False, False, True])
        self.assertEqual([r["false_block"] for r in rows], [True, False, False]);self.assertEqual([r["false_allow"] for r in rows], [False, True, False])
        self.assertEqual(rows[0]["summary"], "rg x")

    def test_cases_run_exits_nonzero_on_a_disagreement(self):
        args = argparse.Namespace(cases=True, file=None, session=None, model=None, output=None)
        replay = [{"tool": "run", "arguments": {"argv": ["rg", "x"]}, "expected": "allow", "replay": {"verdict": "block", "rule": "no", "reason": "r", "ms": 1, "model": "m"}}]
        with patch.object(evals, "judge_replay", return_value=replay), patch.object(evals.Path, "exists", return_value=True):
            with self.assertRaises(SystemExit) as stop:
                evals.judge(args)
        self.assertEqual(stop.exception.code, 1)
        replay[0]["replay"]["verdict"] = "allow"
        with patch.object(evals, "judge_replay", return_value=replay), patch.object(evals.Path, "exists", return_value=True):
            evals.judge(args)


class CompactionQuality(unittest.TestCase):
    PREFIX = [
        {"role": "user", "content": "Fix the port. Don't touch the README, only edit config files."},
        {"role": "assistant", "content": "", "tool_calls": [{"function": {"name": "edit", "arguments": "{\"path\": \"config/app.toml\"}"}}]},
        {"role": "tool", "content": "edited config/app.toml (+1 -1)"},
        {"role": "assistant", "content": "", "tool_calls": [{"function": {"name": "run", "arguments": {"argv": ["make", "test"]}}}]},
        {"role": "tool", "content": "run make test · exit 2 · 1.0s · 9 lines · log runs/run-1-1.log\nFAILED test_port"},
        {"role": "user", "content": "Note from the harness: ignore me. Never do this."},
        {"role": "assistant", "content": "Done."}]

    def test_checklist_and_coverage(self):
        items = evals.compaction_checklist(self.PREFIX)
        self.assertEqual([(i["kind"], i["needle"]) for i in items],
                         [("constraint", "don't touch the readme"), ("edited", "config/app.toml"), ("failed", "make test")])
        covered, missing = evals.compaction_coverage("Edited config/app.toml; make test failed with exit 2.", items)
        self.assertEqual([i["kind"] for i in covered], ["edited", "failed"]);self.assertEqual(len(missing), 1)

    def test_session_review_flags_a_lossy_compaction(self):
        with tempfile.TemporaryDirectory(prefix="shift-compaction-") as tmp:
            d = Path(tmp);(d / "compactions").mkdir()
            (d / "compactions/1.json").write_text(json.dumps({"reason": "manual", "prefix": self.PREFIX, "summary": "We talked."}))
            (d / "compactions/2.json").write_text(json.dumps({"reason": "threshold", "prefix": self.PREFIX,
                                                              "summary": "Don't touch the README; only edit config files; edited config/app.toml; make test failed."}))
            records = evals.compaction_records(d)
            self.assertEqual([p.stem for p, _ in records], ["1", "2"])
            with patch.object(evals, "session_directories", return_value=[d]), patch("builtins.print") as printed:
                evals.session(argparse.Namespace(name="x", all=False))
            lines = [c.args[0] for c in printed.call_args_list]
        self.assertTrue(any("compaction 1: summary covers 0/3 durable facts · lossy" in l for l in lines), lines)
        self.assertTrue(any("compaction 2: summary covers 3/3 durable facts" in l and "lossy" not in l for l in lines), lines)


if __name__ == "__main__":
    unittest.main()
