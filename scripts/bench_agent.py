#!/usr/bin/env python3
"""Shift as a Harbor installed agent, for Terminal-Bench and DeepSWE.

Harbor (harborframework.com) runs each benchmark task in its own container:
it installs the agent there, hands it the task's instruction, then grades the
container with the task's verifier. This module is what

    PYTHONPATH=scripts harbor run --agent bench_agent:Shift -m PROVIDER/MODEL ...

imports; scripts/evals.py terminal-bench and deepswe build that command line.

The interpreter is conda-forge's Guile, pinned, because task images ship
Debian 12's 3.0.8, which predates spawn. Inside the container Shift runs in print mode, autopilot, with every command
allowed (--allow-run '*'): the container is the boundary. A local Ollama on
the host is reached as host.docker.internal, which the driver allowlists for
tasks that run without a network. Everything Shift writes lands in Harbor's
agent log directory, which Harbor copies out beside the trial's result.
"""
import hashlib
import json
import os
import shlex
import shutil
import subprocess
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALL_DIR = "/installed-agent/shift"
STATE_DIR = "/installed-agent/state"
# The runtime and nothing else: no host build cache, sessions, plugins or docs.
SHIPPED = ("bin", "src", "extensions", "agent", "Makefile")
# Task images run Debian 12 (Guile 3.0.8, no spawn) as often as Debian 13, so
# the interpreter comes from conda-forge, pinned, the same in every container.
MICROMAMBA = "https://github.com/mamba-org/micromamba-releases/releases/download/2.9.0-0/micromamba-linux-{arch}"
TOOLS_DIR = "/installed-agent/tools"
PACKAGES = "guile=3.0.11 ripgrep make git curl"
CACHE = ROOT / "evals" / "cache" / "bench"
# Print mode has no one to approve anything, and no MCP servers; keep the
# tool list to what the benchmarks exercise.
CEILING = "read,rg,write,edit,apply_patch,status,diff,run"
OLLAMA_URL = "http://host.docker.internal:11434"
KEY_VARIABLES = ("CLAUDE_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_API_KEY")


def version():
    try:
        return subprocess.run(["git", "describe", "--always", "--dirty"], cwd=ROOT, text=True,
                              capture_output=True, timeout=10).stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


def micromamba_binary(arch="64"):
    """The micromamba binary for the container's architecture, downloaded once
    on the host (task images have neither curl nor wget for certain) and
    checked against the release's published digest."""
    path = CACHE / f"micromamba-linux-{arch}"
    if path.exists():
        return path
    url = MICROMAMBA.format(arch=arch)
    with urllib.request.urlopen(url, timeout=300) as response:
        data = response.read()
    with urllib.request.urlopen(url + ".sha256", timeout=60) as response:
        expected = published_digest(response.read().decode())
    digest = hashlib.sha256(data).hexdigest()
    if digest != expected:
        raise RuntimeError(f"micromamba download digest {digest} is not the published {expected}")
    CACHE.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    path.chmod(0o755)
    return path


def published_digest(text):
    """The digest from a release's .sha256 file: 'HEX  filename' or just HEX."""
    return text.split()[0].strip().lower()


def install_command():
    """Create the tool prefix with the uploaded micromamba, then compile the runtime."""
    return (f"set -e; mkdir -p {TOOLS_DIR}; cd /installed-agent; chmod +x micromamba; "
            f"MAMBA_ROOT_PREFIX=/installed-agent/mamba ./micromamba create -y -q --no-rc -p {TOOLS_DIR} "
            f"--override-channels -c conda-forge {PACKAGES} >/dev/null; "
            f"PATH={TOOLS_DIR}/bin:$PATH make -s -j\"$(nproc)\" -C {INSTALL_DIR} build")


def stage_tree(destination):
    """Copy the shipped runtime into DESTINATION (a fresh directory)."""
    for name in SHIPPED:
        source = ROOT / name
        if source.is_dir():
            shutil.copytree(source, Path(destination) / name,
                            ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "*.go"))
        else:
            shutil.copy2(source, Path(destination) / name)


def shift_command(instruction_path, model, logs_dir, rounds=40, workdir="/app", base_url=None, timeout=3600):
    """The shell line that runs one print-mode turn and leaves its outputs in
    LOGS_DIR. The turn is bounded inside the container so that a slow model
    still leaves a receipt, a commit and a gradable tree behind (exit 124)."""
    provider = model.split("/", 1)[0]
    settings = ["--set", f"agent-max-tool-rounds={rounds}"]
    url = base_url or (OLLAMA_URL if provider == "ollama" else None)
    if url:
        settings += ["--set", "agent-base-url=" + json.dumps(url)]
    # SIGTERM cancels the turn once the model call in flight returns, and the
    # receipt follows; the kill after that is for a call that never returns.
    argv = ["timeout", "-k", "300", str(int(timeout)), f"{INSTALL_DIR}/bin/shift-agent",
            "--print", f'"$(cat {shlex.quote(instruction_path)})"',
            "--mode", "autopilot", "--model", model, "--allow-run", "*",
            "--state-dir", STATE_DIR, "--session", "bench", "--no-watch", "--no-mcp",
            "--receipt", f"{logs_dir}/receipt.json", *settings]
    quoted = " ".join(a if a.startswith('"$(') else shlex.quote(a) for a in argv)
    return (f"export PATH={TOOLS_DIR}/bin:$PATH; mkdir -p {shlex.quote(logs_dir)} {STATE_DIR} && cd {shlex.quote(workdir)} && {quoted}"
            f" > {logs_dir}/shift.stdout 2> {logs_dir}/shift.stderr; echo $? > {logs_dir}/exit")


def commit_command(workdir="/app"):
    """DeepSWE grades commits (git diff BASE HEAD), so commit whatever the turn left."""
    return (f"cd {shlex.quote(workdir)} && git rev-parse --is-inside-work-tree >/dev/null 2>&1 && "
            "git add -A && git -c user.name=shift -c user.email=shift@localhost commit -qm 'shift: benchmark turn'"
            " || true")


def agent_environment(model, host=os.environ):
    """What the Shift process needs: no plugins, no compile attempts, provider keys."""
    env = {"SHIFT_PLUGINS": "off", "GUILE_AUTO_COMPILE": "0", "SHIFT_TOOL_CEILING": CEILING,
           "TERM": "dumb", "HOME": "/root"}
    for name in KEY_VARIABLES:
        if host.get(name):
            env[name] = host[name]
    return env


def receipt_metrics(receipt):
    """Token and round counts for Harbor's context, from Shift's own receipt."""
    tokens = receipt.get("tokens") or {}
    return {"n_input_tokens": tokens.get("prompt"), "n_output_tokens": tokens.get("completion"),
            "n_cache_tokens": tokens.get("cached"),
            "metadata": {key: receipt.get(key) for key in ("status", "error", "rounds", "tool_calls", "duration_ms")
                         if receipt.get(key) is not None}}


try:
    from harbor.agents.installed.base import BaseInstalledAgent
except ImportError:  # the pure functions above are testable without Harbor
    BaseInstalledAgent = object


class Shift(BaseInstalledAgent):
    """Harbor agent: --ak rounds=N, --ak timeout=SECONDS, --ak workdir=/app, --ak base_url=URL."""

    def __init__(self, logs_dir, *args, rounds=40, timeout=3600, workdir="/app", base_url=None, **kwargs):
        super().__init__(logs_dir, *args, **kwargs)
        self.rounds, self.timeout, self.workdir, self.base_url = int(rounds), int(timeout), workdir, base_url

    @staticmethod
    def name():
        return "shift"

    def version(self):
        return version()

    async def install(self, environment):
        with tempfile.TemporaryDirectory(prefix="shift-bench-") as staging:
            tree = Path(staging) / "shift"
            stage_tree(tree)
            await environment.upload_dir(tree, INSTALL_DIR)
        machine = (await environment.exec("uname -m")).stdout.strip()
        arch = "aarch64" if machine in ("aarch64", "arm64") else "64"
        await environment.upload_file(micromamba_binary(arch), "/installed-agent/micromamba")
        await self.exec_as_root(environment, install_command(), timeout_sec=1800)

    async def run(self, instruction, environment, context):
        logs = str(self.environment_logs_dir)
        instruction_path = self.logs_dir / "instruction.md"
        instruction_path.write_text(self.render_instruction(instruction))
        await environment.upload_file(instruction_path, f"{logs}/instruction.md")
        command = shift_command(f"{logs}/instruction.md", self.model_name or "", logs, self.rounds,
                                self.workdir, self.base_url, self.timeout)
        self.logger.info("Running Shift: %s", command)
        await environment.exec(command, env=agent_environment(self.model_name or ""), timeout_sec=self.timeout + 600)
        await environment.exec(commit_command(self.workdir))
        # The session (transcript, traces, compactions) rides along for later review.
        await environment.exec(f"cp -r {STATE_DIR}/sessions {logs}/sessions 2>/dev/null || true")

    def populate_context_post_run(self, context):
        receipt = self.logs_dir / "receipt.json"
        if not receipt.exists():
            context.metadata = {"status": "no-receipt"}
            return
        metrics = receipt_metrics(json.loads(receipt.read_text()))
        context.metadata = metrics.pop("metadata")
        for key, value in metrics.items():
            if value is not None:
                setattr(context, key, value)
