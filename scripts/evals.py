#!/usr/bin/env python3
"""Evaluation driver for docs/evals-rfc.md.

    scripts/evals.py fetch                      cache SWE-bench Verified locally
    scripts/evals.py slice                      write the seeded 25-instance slice
    scripts/evals.py run [--instances A,B] ...  run Shift in print mode per instance
    scripts/evals.py grade RUN_ID               grade a run with the official harness
    scripts/evals.py dogfood [--tasks A,B]       attempt current-tree tickets and run hidden local tests

Every instance gets its own checkout, virtualenv, and Shift session. Results
land in evals/results/RUN_ID/ as predictions.jsonl (what the harness grades)
and results.jsonl (one metrics record per instance, from the receipt Shift
writes with --receipt, never from the transcript). The receipts themselves are
kept under receipts/.
"""

import argparse
import os
import collections
import json
import random
import signal
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EVALS = ROOT / "evals"
CACHE = EVALS / "cache" / "swebench-verified.jsonl"
WORK = EVALS / "work"
RESULTS = EVALS / "results"
SLICE = EVALS / "swebench-verified-25.txt"
# The SWE-bench org copy carries the per-instance image names the 5.x harness needs.
DATASET = "SWE-bench/SWE-bench_Verified"
GRADE_DATASET = DATASET
ROWS_URL = ("https://datasets-server.huggingface.co/rows?dataset=" + DATASET
            + "&config=default&split=test&offset={offset}&length=100")
SEED = 20260908

PROMPT = """You are working in a checkout of {repo} at commit {base}. Fix the issue below so the project's own tests for it pass. Make the minimal correct change to the library code; do not modify or add tests unless the fix requires it, and do not commit.

A virtualenv with the project installed in editable mode is at {venv}. Run tests with "{venv}/bin/python -m pytest PATH::test" or the project's runner (for Django, "{venv}/bin/python tests/runtests.py APP_LABEL" from cwd "tests"). Reproduce the failure first when a test path is obvious, keep test runs narrow, and finish with status and diff, then a short summary of the change.

<issue>
{problem}
</issue>"""


def log(message):
    print(message, file=sys.stderr, flush=True)


def environment():
    """Shift reads .env from the working directory, which for an instance is
    the checkout; provider keys therefore come from the Shift root's .env or
    the caller's environment. Values are data, never evaluated."""
    env = dict(os.environ)
    dotenv = ROOT / ".env"
    if dotenv.exists():
        for line in dotenv.read_text().splitlines():
            line = line.strip().removeprefix("export ")
            if "=" in line and not line.startswith("#"):
                key, value = line.split("=", 1)
                key, value = key.strip(), value.strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                    value = value[1:-1]
                env.setdefault(key, value)
    env.setdefault("GUILE_AUTO_COMPILE", "0")
    # No one can approve a shell command in print mode, so keep it out of the
    # tool list rather than let the model burn rounds on denials.
    env.setdefault("SHIFT_TOOL_CEILING", "read,rg,write,edit,apply_patch,status,diff,run,traces")
    return env


def fetch():
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    rows = []
    offset = 0
    while True:
        with urllib.request.urlopen(ROWS_URL.format(offset=offset), timeout=60) as response:
            page = json.load(response)
        rows.extend(item["row"] for item in page["rows"])
        offset += 100
        if offset >= page["num_rows_total"]:
            break
    with CACHE.open("w") as handle:
        for row in rows:
            handle.write(json.dumps(row) + "\n")
    log(f"cached {len(rows)} instances at {CACHE}")
    return rows


def load_rows():
    if not CACHE.exists():
        return fetch()
    return [json.loads(line) for line in CACHE.read_text().splitlines() if line.strip()]


def make_slice(size=25):
    ids = sorted(row["instance_id"] for row in load_rows())
    random.Random(SEED).shuffle(ids)
    chosen = sorted(ids[:size])
    SLICE.write_text("\n".join(chosen) + "\n")
    log(f"wrote {len(chosen)} instance ids to {SLICE}")
    return chosen


def sh(argv, cwd=None, timeout=600, check=True, env=None):
    result = subprocess.run(argv, cwd=cwd, text=True, capture_output=True, timeout=timeout, env=env)
    if check and result.returncode != 0:
        raise RuntimeError(f"{' '.join(map(str, argv))} failed ({result.returncode}): {result.stderr[-2000:]}")
    return result


def setup(instance, python_version, venv=True):
    """Checkout at the base commit plus a virtualenv with the project installed."""
    folder = WORK / instance["instance_id"]
    repo = folder / "repo"
    folder.mkdir(parents=True, exist_ok=True)
    if not (repo / ".git").exists():
        log(f"cloning {instance['repo']}")
        sh(["git", "clone", "--quiet", "--filter=blob:none", f"https://github.com/{instance['repo']}.git", str(repo)],
           timeout=1800)
    sh(["git", "checkout", "--quiet", "--force", instance["base_commit"]], cwd=repo, timeout=600)
    sh(["git", "clean", "-fdq", "-e", ".shift"], cwd=repo)
    shutil.rmtree(repo / ".shift", ignore_errors=True)
    exclude = repo / ".git" / "info" / "exclude"
    if ".shift/" not in exclude.read_text().split():
        with exclude.open("a") as handle:
            handle.write(".shift/\n.shift-adopted.txt\n")
    installed = True
    if not venv:
        return repo, None, installed
    venv = folder / "venv"
    if not (venv / "bin" / "python").exists():
        sh(["uv", "venv", "--quiet", "--python", python_version, str(venv)], timeout=600)
        install = subprocess.run(
            ["uv", "pip", "install", "--quiet", "--python", str(venv / "bin" / "python"), "-e", ".", "pytest"],
            cwd=repo, text=True, capture_output=True, timeout=1200,
        )
        installed = install.returncode == 0
        if not installed:
            log(f"editable install failed for {instance['instance_id']}: {install.stderr[-500:]}")
    return repo, venv, installed


AGENTKERNEL_PYTHON = "/opt/miniconda3/envs/testbed/bin/python"
SANDBOX_CONFIG = """[sandbox]
name = "{name}"
base_image = "{image}"

[resources]
vcpus = 4
memory_mb = 4096

[security]
profile = "moderate"
network = false
mount_cwd = true
"""


def agentkernel_binary():
    """Homebrew's agentkernel is current; a stale cargo install may shadow it."""
    for candidate in ("/opt/homebrew/opt/agentkernel/bin/agentkernel", shutil.which("agentkernel")):
        if candidate and Path(candidate).exists():
            return candidate
    raise RuntimeError("agentkernel is not installed")


def sandbox_name(instance_id):
    """agentkernel allows alphanumerics, hyphens, and underscores, never
    consecutively; instance ids use a double underscore."""
    name = "swe-"
    for character in instance_id:
        if character.isalnum():
            name += character
        elif not name.endswith("-"):
            name += "-"
    return name.rstrip("-")


def agentkernel_sandbox(instance, repo):
    """Run the instance's tests inside the SWE-bench harness image, where C
    extensions are already built. The host checkout is mounted at /workspace;
    the image's build artifacts are copied into it once and /testbed becomes
    a symlink, so the model's edits are live and no per-run sync exists."""
    ak = agentkernel_binary()
    name = sandbox_name(instance["instance_id"])
    image = instance["image"]
    pull_images([instance["instance_id"]])
    config = repo.parent / "sandbox.toml"
    config.write_text(SANDBOX_CONFIG.format(name=name, image=image))
    subprocess.run([ak, "sandbox", "remove", name], capture_output=True)
    sh([ak, "sandbox", "create", name, "--config", str(config), "--dir", str(repo), "-B", "docker"], timeout=900)
    adopt = (
        "cd /testbed && find . -path ./.git -prune -o -type f -print | "
        "while read f; do [ -e \"/workspace/$f\" ] || echo \"${f#./}\"; done > /workspace/.shift-adopted.txt && "
        "if [ -s /workspace/.shift-adopted.txt ]; then "
        "tar -C /testbed --exclude=./.git -cf - $(sed 's|^|./|' /workspace/.shift-adopted.txt) | tar -C /workspace -xf -; fi && "
        "mv /testbed /testbed.image && ln -s /workspace /testbed"
    )
    sh([ak, "exec", name, "--", "sh", "-c", adopt], timeout=900)
    exclude = repo / ".git" / "info" / "exclude"
    adopted = (repo / ".shift-adopted.txt").read_text().splitlines()
    with exclude.open("a") as handle:
        handle.write("\n".join(adopted) + "\n")
    log(f"sandbox {name} ready: {len(adopted)} build artifacts adopted from {image}")
    return name


def remove_sandbox(name):
    subprocess.run([agentkernel_binary(), "sandbox", "remove", name], capture_output=True)


def model_patch(repo):
    sh(["git", "add", "-A", "--", "."], cwd=repo)
    patch = sh(["git", "diff", "--cached", "--binary"], cwd=repo).stdout
    sh(["git", "reset", "-q"], cwd=repo)
    return patch


def collect(receipt_path):
    """Per-instance metrics from the receipt Shift wrote with --receipt, so the
    driver never reconstructs a turn from traces or the ledger."""
    metrics = {"receipt_status": None, "receipt_error": None, "rounds": 0, "tool_calls": {}, "tokens": {},
               "files_changed": [], "runs": []}
    if not receipt_path.exists():
        return metrics
    receipt = json.loads(receipt_path.read_text())
    metrics.update(
        receipt_status=receipt["status"], receipt_error=receipt.get("error"), rounds=receipt["rounds"],
        tool_calls=receipt["tool_calls"], tokens=receipt["tokens"],
        files_changed=[change["path"] for change in receipt["changed"]],
        runs=[{"command": run["command"][:4], "exit_code": run["exit_code"], "status": run["status"]}
              for run in receipt["runs"]],
    )
    return metrics


def classify(exit_code, stderr, patch):
    if exit_code == 0 and patch.strip():
        return "completed"
    if "tool round limit" in stderr:
        return "round_limit"
    if "token budget" in stderr:
        return "token_budget"
    if exit_code != 0:
        return "turn_failed"
    return "no_patch"


def run_instance(instance, args, run_dir):
    started = time.time()
    sandboxed = args.backend == "agentkernel"
    repo, venv, installed = setup(instance, args.python, venv=not sandboxed)
    env = environment()
    # Large edits exceed the default 8192-token output reserve, and a response
    # cut off at max_tokens fails the turn rather than executing a partial call.
    settings = ["--set", f"agent-max-tool-rounds={args.rounds}", "--set", f"turn-token-budget={args.budget}",
                "--set", f"output-reserve={args.output_reserve}"]
    if args.context_limit:
        settings += ["--set", f"context-limit={args.context_limit}"]
    sandbox = None
    if sandboxed:
        sandbox = agentkernel_sandbox(instance, repo)
        venv = Path(AGENTKERNEL_PYTHON).parent.parent
        settings += ["--set", 'run-backend="agentkernel"', "--set", f'run-sandbox="{sandbox}"']
        env["PATH"] = str(Path(agentkernel_binary()).parent) + ":" + env.get("PATH", "")
    prompt = PROMPT.format(repo=instance["repo"], base=instance["base_commit"][:12], venv=venv,
                           problem=instance["problem_statement"].strip())
    (run_dir / "receipts").mkdir(exist_ok=True)
    receipt_path = run_dir / "receipts" / f"{instance['instance_id']}.json"
    command = [str(ROOT / "bin/shift"), "--print", prompt, "--mode", "accept", "--model", args.model,
               "--allow-run", f"{venv}/bin/python", *settings, "--session", "swe", "--no-watch", "--no-mcp",
               "--receipt", str(receipt_path)]
    log(f"running {instance['instance_id']} ({instance.get('difficulty', '?')}, {args.backend})")
    try:
        result = subprocess.run(command, cwd=repo, text=True, capture_output=True, timeout=args.timeout,
                                stdin=subprocess.DEVNULL, env=env)
        exit_code, stdout, stderr = result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired as expired:
        exit_code, stdout, stderr = 124, expired.stdout or "", (expired.stderr or "") + "\nwall-clock timeout"
    finally:
        if sandbox and not args.keep_sandbox:
            remove_sandbox(sandbox)
    patch = model_patch(repo)
    record = {
        "instance_id": instance["instance_id"], "repo": instance["repo"], "difficulty": instance.get("difficulty"),
        "model": args.model, "backend": args.backend, "exit_code": exit_code, "wall_s": round(time.time() - started, 1),
        "editable_install": installed, "patch_bytes": len(patch.encode()),
        "failure_class": classify(exit_code, stderr, patch),
        "answer_tail": stdout[-600:], "stderr_tail": stderr[-600:],
        **collect(receipt_path),
    }
    (run_dir / "patches").mkdir(exist_ok=True)
    (run_dir / "patches" / f"{instance['instance_id']}.diff").write_text(patch)
    with (run_dir / "predictions.jsonl").open("a") as handle:
        handle.write(json.dumps({"instance_id": instance["instance_id"], "model_name_or_path": "shift-" + args.model,
                                 "model_patch": patch}) + "\n")
    with (run_dir / "results.jsonl").open("a") as handle:
        handle.write(json.dumps(record) + "\n")
    log(f"  {record['failure_class']} · {record['rounds']} rounds · {record['tokens']} · {record['wall_s']}s")
    return record


# A local model reports no cache reads, so every round costs its whole prompt
# against the budget; it is slower per round; and Ollama truncates silently
# past num_ctx, so the window is pinned to what Shift budgets for. Shift's
# byte-based estimate overshoots real token counts on code by 15-20% and
# compaction cannot shrink a single turn, so the window is the model's full
# 262k: at 131k a Django task hit the guard after 11 rounds at 73k real tokens.
PROVIDER_DEFAULTS = {
    "ollama": {"budget": 4_000_000, "timeout": 5400, "output_reserve": 8192, "context_limit": 262144},
    "default": {"budget": 300_000, "timeout": 1500, "output_reserve": 32768, "context_limit": None},
}


def apply_provider_defaults(args):
    provider = args.model.split("/", 1)[0]
    defaults = PROVIDER_DEFAULTS.get(provider, PROVIDER_DEFAULTS["default"])
    for key, value in defaults.items():
        if getattr(args, key) is None:
            setattr(args, key, value)


def run(args):
    rows = {row["instance_id"]: row for row in load_rows()}
    if args.instances:
        ids = args.instances.split(",")
    else:
        if not SLICE.exists():
            make_slice()
        ids = SLICE.read_text().split()
    ids = ids[: args.limit] if args.limit else ids
    apply_provider_defaults(args)
    run_id = args.run_id or time.strftime("%Y%m%d-%H%M%S") + "-" + args.model.replace("/", "-")
    run_dir = RESULTS / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "config.json").write_text(json.dumps(vars(args), indent=1))
    records = [run_instance(rows[instance_id], args, run_dir) for instance_id in ids]
    summary = collections.Counter(record["failure_class"] for record in records)
    log(f"run {run_id}: {dict(summary)}")
    log(f"grade with: scripts/evals.py grade {run_id}")


def pull_images(ids):
    """The harness images are amd64 only; on arm64 hosts Docker refuses the
    implicit pull, so fetch them explicitly and let the harness find them."""
    rows = {row["instance_id"]: row for row in load_rows()}
    arch = subprocess.run(["docker", "version", "--format", "{{.Server.Arch}}"], text=True,
                          capture_output=True).stdout.strip()
    if arch == "amd64":
        return
    for instance_id in ids:
        image = rows[instance_id].get("image")
        if not image:
            continue
        present = subprocess.run(["docker", "image", "inspect", image], capture_output=True).returncode == 0
        if not present:
            log(f"pulling {image} for linux/amd64")
            sh(["docker", "pull", "--quiet", "--platform", "linux/amd64", image], timeout=3600)


def grade(args):
    run_dir = RESULTS / args.run_id
    predictions = run_dir / "predictions.jsonl"
    ids = [json.loads(line)["instance_id"] for line in predictions.read_text().splitlines() if line.strip()]
    if args.instances:
        ids = [i for i in ids if i in args.instances.split(",")]
    pull_images(ids)
    command = ["uv", "run", "--python", "3.12", "--with", "swebench", "python", "-m",
               "swebench.harness.run_evaluation", "--dataset_name", GRADE_DATASET, "--predictions_path", str(predictions),
               "--max_workers", str(args.workers), "--run_id", args.run_id, "--instance_ids", *ids]
    log(" ".join(command))
    subprocess.run(command, cwd=run_dir, check=False)
    for report in run_dir.glob("*.json"):
        if report.name.endswith(f"{args.run_id}.json"):
            data = json.loads(report.read_text())
            log(f"resolved {data.get('resolved_instances', '?')}/{data.get('total_instances', '?')}: "
                f"{data.get('resolved_ids', [])}")


def dogfood_snapshot(destination):
    """Copy the current working tree, without evals, .env, or Git history.
    The fresh Git baseline is only a fixture for collecting the model patch."""
    destination.mkdir(parents=True)
    paths = sh(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT).stdout
    for name in dict.fromkeys(paths.split("\0")):
        if not name or name.split("/", 1)[0] in {"evals", ".git", ".shift", ".env"}:
            continue
        source, target = ROOT / name, destination / name
        if not source.exists() and not source.is_symlink():
            continue  # Preserve working-tree deletions.
        if source.is_symlink() and not source.resolve().is_relative_to(ROOT):
            raise RuntimeError(f"snapshot symlink escapes the project: {name}")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target, follow_symlinks=False)
    sh(["git", "init", "-q"], cwd=destination)
    sh(["git", "add", "-A"], cwd=destination)
    sh(["git", "-c", "user.name=Shift eval fixture", "-c", "user.email=eval@localhost",
        "-c", "commit.gpgsign=false", "commit", "-qm", "Snapshot evaluation input"], cwd=destination)


def logged_run(command, repo, env, timeout, prefix):
    """Keep output on disk and reap this workload's process group on timeout."""
    with Path(str(prefix) + ".stdout.log").open("w") as out, Path(str(prefix) + ".stderr.log").open("w") as err:
        process = subprocess.Popen(command, cwd=repo, env=env, stdin=subprocess.DEVNULL,
                                   stdout=out, stderr=err, start_new_session=True)
        def stop_group():
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
            # A child may outlive the group leader or ignore SIGTERM.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            stop_group()
            return 124
        except BaseException:
            stop_group()
            raise


def log_tail(path, size=2000):
    with path.open("rb") as handle:
        handle.seek(0, 2)
        handle.seek(max(0, handle.tell() - size))
        return handle.read().decode(errors="replace")


def memory_snapshot():
    sample = {"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    if sys.platform == "darwin":
        pressure = sh(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"], timeout=5)
        sample["pressure"] = int(pressure.stdout.strip())
        sample["swap"] = sh(["sysctl", "-n", "vm.swapusage"], timeout=5).stdout.strip()
    ollama = shutil.which("ollama")
    if ollama:
        sample["ollama"] = sh([ollama, "ps"], timeout=10, check=False).stdout.strip()
    return sample


def dogfood(args):
    tasks_root = EVALS / "dogfood"
    names = args.tasks.split(",") if args.tasks else sorted(p.name for p in tasks_root.iterdir() if p.is_dir())
    if not names or len(names) != len(set(names)):
        raise ValueError("select at least one task, without duplicates")
    for name in names:
        if not name or any(c not in "abcdefghijklmnopqrstuvwxyz0123456789-_" for c in name):
            raise ValueError(f"invalid task name: {name}")
        for file in ("task.md", "test.py"):
            if not (tasks_root / name / file).is_file():
                raise ValueError(f"missing {name}/{file}")
    run_id = args.run_id or time.strftime("%Y%m%d-%H%M%S") + "-dogfood"
    if not run_id or Path(run_id).name != run_id or run_id in {".", ".."}:
        raise ValueError("run-id must be a directory name")
    run_dir = RESULTS / run_id
    run_dir.mkdir(parents=True, exist_ok=False)
    config = {**vars(args), "base_commit": sh(["git", "rev-parse", "HEAD"], cwd=ROOT).stdout.strip(),
              "source_status": sh(["git", "status", "--porcelain"], cwd=ROOT).stdout}
    (run_dir / "config.json").write_text(json.dumps(config, indent=2))
    for subdir in ("receipts", "patches", "logs"):
        (run_dir / subdir).mkdir()
    env = environment()
    # Personal preferences must not change the eval's settings or allowlist.
    env["XDG_CONFIG_HOME"] = str(run_dir / "empty-config")
    env["SHIFT_TOOL_CEILING"] = "read,rg,write,edit,apply_patch,status,diff,run"
    records = []
    for name in names:
        resource = memory_snapshot()
        with (run_dir / "resources.jsonl").open("a") as handle:
            handle.write(json.dumps({"task": name, "phase": "before", **resource}) + "\n")
        if resource.get("pressure", 1) != 1:
            raise RuntimeError("macOS memory pressure is elevated; no new task started")
        repo = WORK / "dogfood" / run_id / name / "repo"
        dogfood_snapshot(repo)
        logs = run_dir / "logs" / name
        logs.mkdir()
        grader = [sys.executable, str(tasks_root / name / "test.py")]
        if logged_run(["make", "build"], repo, env, 300, logs / "baseline-build"):
            raise RuntimeError(f"{name}: baseline build failed; see {logs}")
        baseline = logged_run(grader, repo, env, 120, logs / "baseline")
        if baseline != 1:
            raise RuntimeError(f"{name}: expected a failing baseline test (exit 1), got {baseline}; see {logs}")
        resource = memory_snapshot()
        with (run_dir / "resources.jsonl").open("a") as handle:
            handle.write(json.dumps({"task": name, "phase": "before-model", **resource}) + "\n")
        if resource.get("pressure", 1) != 1:
            raise RuntimeError("macOS memory pressure is elevated; model attempt not started")
        prompt = (tasks_root / name / "task.md").read_text() + (
            "\n\nWork in this checkout. Implement the ticket, run focused existing tests, "
            "then inspect status and diff and summarize. Do not commit. "
            "The external grading tests are intentionally not in this checkout; do not look for them."
        )
        receipt = run_dir / "receipts" / f"{name}.json"
        command = [str(ROOT / "bin/shift"), "--print", prompt, "--mode", "accept",
                   "--model", args.model, "--session", name, "--no-watch", "--no-mcp",
                   "--receipt", str(receipt), "--allow-run", "make build", "--allow-run", "make test",
                   "--allow-run", "make check", "--allow-run", "guile",
                   "--allow-run", "python3", "--set", f"agent-max-tool-rounds={args.rounds}",
                   "--set", f"turn-token-budget={args.budget}", "--set", f"context-limit={args.context_limit}",
                   "--set", "output-reserve=8192", "--set", 'agent-keep-alive="1m"']
        log(f"dogfood {name}: baseline fails; running {args.model}")
        started = time.monotonic()
        interrupted = False
        try:
            exit_code = logged_run(command, repo, env, args.timeout, logs / "model")
        except KeyboardInterrupt:
            # logged_run has reaped the attempt. Preserve evidence without
            # launching a build, grader, or another model after a user stop.
            interrupted, exit_code = True, 130
        wall = round(time.monotonic() - started, 1)
        patch = model_patch(repo)
        (run_dir / "patches" / f"{name}.diff").write_text(patch)
        build_code = None if interrupted else logged_run(["make", "build"], repo, env, 300, logs / "grade-build")
        grade_code = logged_run(grader, repo, env, 120, logs / "grade") if build_code == 0 else None
        regression_code = logged_run(["make", "test"], repo, env, 600, logs / "regression") if grade_code == 0 else None
        stderr = log_tail(logs / "model.stderr.log")
        record = {"instance_id": name, "model": args.model, "backend": "local", "exit_code": exit_code,
                  "wall_s": wall, "baseline_exit_code": baseline, "build_exit_code": build_code,
                  "grade_exit_code": grade_code, "regression_exit_code": regression_code,
                  "resolved": None if interrupted else grade_code == 0 and regression_code == 0,
                  "patch_bytes": len(patch.encode()),
                  "failure_class": "user_stop" if interrupted else "wall_timeout" if exit_code == 124 else classify(exit_code, stderr, patch),
                  "answer_tail": log_tail(logs / "model.stdout.log", 600), "stderr_tail": stderr,
                  **collect(receipt)}
        with (run_dir / "results.jsonl").open("a") as handle:
            handle.write(json.dumps(record) + "\n")
        with (run_dir / "resources.jsonl").open("a") as handle:
            handle.write(json.dumps({"task": name, "phase": "after", **memory_snapshot()}) + "\n")
        records.append(record)
        if interrupted:
            log(f"{name}: stopped; partial patch and result saved to {run_dir}")
            raise SystemExit(130)
        log(f"  resolved={record['resolved']} · {record['failure_class']} · {record['rounds']} rounds · {wall}s")
    log(f"resolved {sum(r['resolved'] for r in records)}/{len(records)}; results: {run_dir}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("fetch")
    commands.add_parser("slice")
    runner = commands.add_parser("run")
    runner.add_argument("--instances", help="comma-separated instance ids instead of the slice")
    runner.add_argument("--limit", type=int, default=0)
    runner.add_argument("--model", default="claude/claude-sonnet-5")
    runner.add_argument("--rounds", type=int, default=40)
    runner.add_argument("--budget", type=int, default=None,
                        help="uncached prompt plus completion tokens per turn")
    runner.add_argument("--timeout", type=int, default=None, help="wall-clock seconds per instance (1500; 5400 for ollama)")
    runner.add_argument("--python", default="3.11", help="interpreter for each instance's virtualenv")
    runner.add_argument("--output-reserve", type=int, default=None, help="max output tokens per model response (32768; 8192 for ollama)")
    runner.add_argument("--context-limit", type=int, default=None, help="context window to budget for and, on ollama, request (262144 for ollama)")
    runner.add_argument("--backend", choices=["local", "agentkernel"], default="local",
                        help="where the model's test commands run")
    runner.add_argument("--keep-sandbox", action="store_true", help="leave agentkernel sandboxes for inspection")
    runner.add_argument("--run-id")
    grader = commands.add_parser("grade")
    grader.add_argument("run_id")
    grader.add_argument("--workers", type=int, default=2)
    grader.add_argument("--instances", help="comma-separated subset of the run's instances to grade again")
    dogfooder = commands.add_parser("dogfood", help="run hidden local tests against fresh current-tree snapshots")
    dogfooder.add_argument("--tasks", help="comma-separated task directory names")
    dogfooder.add_argument("--model", default="ollama/qwen3.8:27b-mlx")
    dogfooder.add_argument("--rounds", type=int, default=40)
    dogfooder.add_argument("--budget", type=int, default=2000000)
    dogfooder.add_argument("--context-limit", type=int, default=131072)
    dogfooder.add_argument("--timeout", type=int, default=1800)
    dogfooder.add_argument("--run-id")
    args = parser.parse_args()
    {"fetch": lambda a: fetch(), "slice": lambda a: make_slice(), "run": run, "grade": grade,
     "dogfood": dogfood}[args.command](args)


if __name__ == "__main__":
    main()
