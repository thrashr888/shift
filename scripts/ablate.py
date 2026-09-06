#!/usr/bin/env python3
"""Measure actual Shift CLI round trips and physically absent built-ins."""

import argparse
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--baseline", type=Path, required=True)
parser.add_argument("--samples", type=int, default=7)
args = parser.parse_args()
rows = []
variants = [
    ("baseline", args.baseline.resolve(), None, True),
    ("default", ROOT, None, True),
    ("piped-default", ROOT, None, None),
    ("no-providers", ROOT, "tracing,mcp", True),
    ("no-tracing", ROOT, "ollama,openai,mcp", True),
    ("no-builtins", ROOT, "", True),
    ("default-no-watch", ROOT, None, False),
    ("minimal-no-watch", ROOT, "", False),
]
# Interleave configurations so cache warmup and other machine load are shared.
timings = {name: [] for name, *_ in variants}
with tempfile.TemporaryDirectory(prefix="shift-ablation-") as temporary:
    state = Path(temporary)
    for iteration in range(args.samples + 1):
        for name, root, enabled, watch in variants:
            env = os.environ.copy()
            env.pop("SHIFT_OTEL_ENDPOINT", None)
            env.pop("PHOENIX_COLLECTOR_ENDPOINT", None)
            env.pop("SHIFT_BUILTINS", None)
            if enabled is not None:
                env["SHIFT_BUILTINS"] = enabled
            command = [
                str(root / "bin/shift"),
                "--agent",
                str(root / "test/session-agent.scm"),
                "--state-dir",
                str(state / name),
                "hello",
            ]
            if watch is not None:
                command.insert(1, "--watch" if watch else "--no-watch")
            start = time.perf_counter()
            result = subprocess.run(
                command,
                cwd=root,
                env=env,
                input="",
                text=True,
                capture_output=True,
                timeout=15,
            )
            elapsed = (time.perf_counter() - start) * 1000
            if result.returncode or "[mcp-test] hello" not in result.stdout:
                raise RuntimeError(f"{name}: {result.stderr} {result.stdout}")
            if iteration:  # Discard one warmup for every configuration.
                timings[name].append(round(elapsed, 3))
    for name, values in timings.items():
        rows.append(
            dict(
                variant=name,
                median_ms=round(statistics.median(values), 3),
                min_ms=min(values),
                max_ms=max(values),
                samples_ms=values,
            )
        )
    bare = state / "bare"
    for directory in ("bin", "agent", "extensions"):
        (bare / directory).mkdir(parents=True)
    shutil.copy2(ROOT / "bin/shift", bare / "bin/shift")
    shutil.copy2(ROOT / "test/session-agent.scm", bare / "agent/default.scm")
    (bare / "src").symlink_to(ROOT / "src", target_is_directory=True)
    result = subprocess.run(
        [str(bare / "bin/shift"), "--no-watch", "hello"],
        cwd=bare,
        env={**os.environ, "SHIFT_BUILTINS": ""},
        input="",
        text=True,
        capture_output=True,
        timeout=15,
    )
    assert result.returncode == 0 and "[mcp-test] hello" in result.stdout, result.stderr
    absent_pass = not (bare / ".shift/traces.jsonl").exists()
    loaded = {}
    expression = """(use-modules (live-agent provider) (live-agent trace))
(make-tracer "/tmp/shift-module-inspection" #f)
(for-each (lambda (name) (format #t "~a=~s\\n" name
 (if (resolve-module (list 'shift name) #f #:ensure #f) #t #f)))
 '(ollama openai tracing))"""
    for name, setting in [("default", "ollama,openai,tracing,mcp"), ("minimal", "")]:
        result = subprocess.run(
            [
                "guile",
                "--no-auto-compile",
                "-L",
                "src",
                "-L",
                "extensions",
                "-c",
                expression,
            ],
            cwd=ROOT,
            env={**os.environ, "SHIFT_BUILTINS": setting},
            text=True,
            capture_output=True,
            check=True,
        )
        loaded[name] = result.stdout.splitlines()


def count(root, patterns):
    paths = {p for pattern in patterns for p in root.glob(pattern)}
    return sum(len(p.read_text().splitlines()) for p in paths)


print(
    json.dumps(
        dict(
            samples=args.samples,
            warmups_per_variant=1,
            rows=rows,
            builtin_files_absent_pass=absent_pass,
            loaded_modules=loaded,
            lines=dict(
                baseline_core=count(args.baseline, ["src/**/*.scm", "scripts/*.py"]),
                baseline_scheme=count(args.baseline, ["src/**/*.scm"]),
                candidate_core=count(ROOT, ["src/**/*.scm"]),
                candidate_builtins=count(
                    ROOT, ["extensions/shift/*.scm", "extensions/shift/*.py"]
                ),
            ),
        ),
        indent=2,
    )
)
