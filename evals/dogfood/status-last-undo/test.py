"""External behavioral grader; run with the candidate checkout as cwd."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path.cwd()


class LastUndo(unittest.TestCase):
    def test_chronological_successful_undo_survives_replay(self):
        with tempfile.TemporaryDirectory(prefix="shift-grade-undo-") as tmp:
            code = r'''
(use-modules (live-agent changes) (live-agent tools) (live-agent json) (shift coding))
(define root ROOT)
(define state (string-append root "/state"))
(define ledger (open-ledger state))
(define (put text)
  (call-with-output-file (string-append root "/x.txt") (lambda (p) (display text p))))
(define (change turn before after)
  (put after)
  (ledger-commit! ledger (ledger-begin! ledger turn "c" "edit" "x.txt" before after)))
(define reports '())
(define (report)
  (set! reports (append reports (list (tool-result-output
    (coding-execute "status" (json-object) root ledger 12))))))
(put "one")
(change 10 "one" "two")
(change 11 "two" "three")
(report)
(ledger-undo! ledger root 11)
(report)
(put "user change")
(catch #t (lambda () (ledger-undo! ledger root 10)) (lambda _ #f))
(report)
(put "two")
(ledger-undo! ledger root 10)
(report)
(set! ledger (open-ledger state))
(report)
(change 12 "one" "four")
(report)
(display (json-write (apply json-array reports)))
'''.replace("ROOT", json.dumps(tmp))
            result = subprocess.run(
                ["guile", "--no-auto-compile", "-L", str(ROOT / "src"), "-L", str(ROOT / "extensions"),
                 "-C", str(ROOT / "build"), "-c", code],
                capture_output=True, text=True, timeout=20,
                env={**os.environ, "GUILE_AUTO_COMPILE": "0"},
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            reports = json.loads(result.stdout)
            for report, expected in zip(reports, ["none", "turn 11", "turn 11", "turn 10", "turn 10", "turn 10"]):
                self.assertIn("last undo: " + expected, report.splitlines())
                self.assertIn("not a git repository", report)
                self.assertIn("undoable turns:", report)
            self.assertEqual(len(reports), 6)
            self.assertIn("undoable turns: 12", reports[-1])
            self.assertEqual((Path(tmp) / "x.txt").read_text(), "four")


if __name__ == "__main__":
    unittest.main()
