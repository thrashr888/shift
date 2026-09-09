#!/usr/bin/env python3
"""Evaluation driver for docs/evals-rfc.md.

    scripts/evals.py fetch                      cache SWE-bench Verified locally
    scripts/evals.py slice                      write the seeded 25-instance slice
    scripts/evals.py run [--instances A,B] ...  run Shift in print mode per instance
    scripts/evals.py grade RUN_ID               grade a run with the official harness

Every instance gets its own checkout, virtualenv, and Shift session. Results
land in evals/results/RUN_ID/ as predictions.jsonl (what the harness grades)
and results.jsonl (one metrics record per instance, from Shift's own ledger
and traces, never from the transcript).
"""

import argparse
import os
import collections
import json
import random
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


def collect(state):
    """Metrics from Shift's traces and ledger for one session."""
    metrics = {"rounds": 0, "tool_calls": collections.Counter(), "tokens": collections.Counter(),
               "files_changed": [], "runs": []}
    traces = state / "traces.jsonl"
    if traces.exists():
        for line in traces.read_text().splitlines():
            try:
                span = json.loads(line)
            except json.JSONDecodeError:
                continue
            attributes = span.get("attributes", {})
            if span.get("kind") == "LLM":
                metrics["rounds"] += 1
                for key, name in (("llm.token_count.prompt", "prompt"), ("llm.token_count.prompt_cached", "cached"),
                                  ("llm.token_count.prompt_uncached", "uncached"), ("llm.token_count.completion", "completion")):
                    metrics["tokens"][name] += attributes.get(key, 0) or 0
            elif span.get("kind") == "TOOL":
                metrics["tool_calls"][span["name"].removeprefix("tool.")] += 1
    ledger = state / "changes.jsonl"
    files = set()
    if ledger.exists():
        for line in ledger.read_text().splitlines():
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if entry.get("kind") == "change" and entry.get("state") == "committed":
                files.add(entry["path"])
            elif entry.get("kind") == "run":
                metrics["runs"].append({"command": entry["invocation"]["input"]["command"][:4],
                                        "exit_code": entry["outcome"]["exit_code"],
                                        "status": entry.get("status")})
    metrics["files_changed"] = sorted(files)
    metrics["tool_calls"] = dict(metrics["tool_calls"])
    metrics["tokens"] = dict(metrics["tokens"])
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
    sandbox = None
    if sandboxed:
        sandbox = agentkernel_sandbox(instance, repo)
        venv = Path(AGENTKERNEL_PYTHON).parent.parent
        settings += ["--set", 'run-backend="agentkernel"', "--set", f'run-sandbox="{sandbox}"']
        env["PATH"] = str(Path(agentkernel_binary()).parent) + ":" + env.get("PATH", "")
    prompt = PROMPT.format(repo=instance["repo"], base=instance["base_commit"][:12], venv=venv,
                           problem=instance["problem_statement"].strip())
    command = [str(ROOT / "bin/shift"), "--print", prompt, "--mode", "accept", "--model", args.model,
               "--allow-run", f"{venv}/bin/python", *settings, "--session", "swe", "--no-watch", "--no-mcp"]
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
        **collect(repo / ".shift" / "sessions" / "swe"),
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


def run(args):
    rows = {row["instance_id"]: row for row in load_rows()}
    if args.instances:
        ids = args.instances.split(",")
    else:
        if not SLICE.exists():
            make_slice()
        ids = SLICE.read_text().split()
    ids = ids[: args.limit] if args.limit else ids
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
    runner.add_argument("--budget", type=int, default=300000,
                        help="uncached prompt plus completion tokens per turn")
    runner.add_argument("--timeout", type=int, default=1500, help="wall-clock seconds per instance")
    runner.add_argument("--python", default="3.11", help="interpreter for each instance's virtualenv")
    runner.add_argument("--output-reserve", type=int, default=32768, help="max output tokens per model response")
    runner.add_argument("--backend", choices=["local", "agentkernel"], default="local",
                        help="where the model's test commands run")
    runner.add_argument("--keep-sandbox", action="store_true", help="leave agentkernel sandboxes for inspection")
    runner.add_argument("--run-id")
    grader = commands.add_parser("grade")
    grader.add_argument("run_id")
    grader.add_argument("--workers", type=int, default=2)
    grader.add_argument("--instances", help="comma-separated subset of the run's instances to grade again")
    args = parser.parse_args()
    {"fetch": lambda a: fetch(), "slice": lambda a: make_slice(), "run": run, "grade": grade}[args.command](args)


if __name__ == "__main__":
    main()
