"""The Harbor adapter's pure parts: the container command lines, the staged
tree, receipt metrics, and the driver's job summary. No Harbor, no Docker."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, HERE / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bench = load("bench_agent", "scripts/bench_agent.py")
evals = load("evals", "scripts/evals.py")


class ShiftCommand(unittest.TestCase):
    def test_runs_print_mode_with_every_command_allowed(self):
        line = bench.shift_command("/logs/agent/instruction.md", "ollama/qwen3.8:27b-mlx", "/logs/agent", rounds=12)
        self.assertIn("--print \"$(cat /logs/agent/instruction.md)\"", line)
        self.assertIn("--mode autopilot", line)
        self.assertIn("--allow-run '*'", line)
        self.assertIn("--set agent-max-tool-rounds=12", line)
        self.assertIn("--receipt /logs/agent/receipt.json", line)
        self.assertIn("--no-mcp", line)
        self.assertIn("&& timeout -k 300 3600 /installed-agent/shift/bin/shift-agent --print", line)
        self.assertIn("timeout -k 300 900 ", bench.shift_command("/i", "ollama/x", "/l", timeout=900))
        self.assertIn("; mkdir -p /logs/agent /installed-agent/state && cd /app && ", line)
        self.assertTrue(line.endswith("; echo $? > /logs/agent/exit"))

    def test_ollama_points_at_the_host(self):
        line = bench.shift_command("/i", "ollama/qwen3.8:27b-mlx", "/l")
        self.assertIn("--set 'agent-base-url=\"http://host.docker.internal:11434\"'", line)
        self.assertNotIn("agent-base-url", bench.shift_command("/i", "claude/claude-sonnet-5", "/l"))
        self.assertIn("http://10.0.0.2:8080", bench.shift_command("/i", "ollama/x", "/l", base_url="http://10.0.0.2:8080"))

    def test_environment_carries_keys_and_no_plugins(self):
        env = bench.agent_environment("claude/claude-sonnet-5", {"CLAUDE_API_KEY": "k", "PATH": "/bin"})
        self.assertEqual(env["CLAUDE_API_KEY"], "k")
        self.assertEqual(env["SHIFT_PLUGINS"], "off")
        self.assertNotIn("PATH", env)
        self.assertNotIn("CLAUDE_API_KEY", bench.agent_environment("ollama/x", {}))

    def test_commit_is_harmless_outside_git(self):
        line = bench.commit_command("/work dir")
        self.assertIn("cd '/work dir' && git rev-parse --is-inside-work-tree", line)
        self.assertTrue(line.endswith("|| true"))

    def test_install_pins_the_interpreter_and_builds_last(self):
        line = bench.install_command()
        self.assertIn("./micromamba create", line)
        self.assertIn("guile=3.0.11", line)
        self.assertIn(" curl", line)
        self.assertLess(line.index("micromamba create"), line.index("-C /installed-agent/shift build"))
        self.assertIn('make -s -j"$(nproc)"', line)

    def test_published_digest_reads_either_shape(self):
        self.assertEqual(bench.published_digest("ABC123  micromamba-linux-64\n"), "abc123")
        self.assertEqual(bench.published_digest("abc123"), "abc123")

    def test_turn_runs_with_the_installed_tools_first_on_path(self):
        line = bench.shift_command("/i", "ollama/x", "/l")
        self.assertTrue(line.startswith("export PATH=/installed-agent/tools/bin:$PATH; "))


class StagedTree(unittest.TestCase):
    def test_ships_the_runtime_without_build_cache(self):
        with tempfile.TemporaryDirectory() as temp:
            bench.stage_tree(Path(temp) / "shift")
            names = sorted(os.listdir(Path(temp) / "shift"))
            self.assertEqual(names, ["Makefile", "agent", "bin", "extensions", "src"])
            self.assertTrue((Path(temp) / "shift/bin/shift-agent").exists())
            self.assertFalse(any(path.suffix == ".go" for path in (Path(temp) / "shift").rglob("*")))


class ReceiptMetrics(unittest.TestCase):
    def test_maps_tokens_and_facts(self):
        metrics = bench.receipt_metrics({"tokens": {"prompt": 10, "completion": 3, "cached": 1}, "rounds": 4,
                                         "status": "ok", "tool_calls": {"run": 2}, "changed": []})
        self.assertEqual(metrics["n_input_tokens"], 10)
        self.assertEqual(metrics["n_output_tokens"], 3)
        self.assertEqual(metrics["n_cache_tokens"], 1)
        self.assertEqual(metrics["metadata"], {"status": "ok", "rounds": 4, "tool_calls": {"run": 2}})


class Driver(unittest.TestCase):
    def test_harbor_command_allowlists_each_host(self):
        command = evals.harbor_command("deepswe", ["a", "b"], "ollama/q", Path("/out"), 40, 3600, 1, Path("/tasks"),
                                       hosts=("host.docker.internal", "192.168.65.254"))
        self.assertEqual(command[:4], ["harbor", "run", "-p", "/tasks"])
        self.assertEqual(command[command.index("--agent") + 1], "bench_agent:Shift")
        self.assertEqual(command.count("-i"), 2)
        self.assertEqual(command.count("--allow-agent-host"), 2)
        self.assertIn("192.168.65.254", command)
        self.assertIn("rounds=40", command)
        self.assertIn("--agent-setup-timeout-multiplier", command)
        self.assertNotIn("--allow-agent-host", evals.harbor_command("deepswe", ["a"], "claude/c", Path("/o"), 1, 1, 1, Path("/t")))

    def test_no_network_tasks_get_the_patient_sidecar(self):
        with tempfile.TemporaryDirectory() as temp:
            override = evals.egress_override(Path(temp))
            text = override.read_text()
            self.assertIn("harbor-docker-egress-control-sidecar:", text)
            self.assertIn(f"- {evals.GOST_CONFIG}:/opt/egress-sidecar/gost.yaml:ro", text)
            command = evals.harbor_command("deepswe", ["a"], "ollama/q", Path(temp), 1, 1, 1, Path("/t"), egress=override)
            self.assertEqual(command[-2:], ["--extra-docker-compose", str(override)])
        self.assertIn("readTimeout: 3600s", evals.GOST_CONFIG.read_text())
        self.assertNotIn("--extra-docker-compose", evals.harbor_command("terminal-bench", ["a"], "ollama/q", Path("/o"), 1, 1, 1, Path("/t")))

    def test_oracle_runs_harbors_own_agent(self):
        command = evals.harbor_command("deepswe", ["a"], "ollama/q", Path("/o"), 40, 3600, 1, Path("/t"), oracle=True)
        self.assertIn("oracle", command)
        self.assertNotIn("bench_agent:Shift", command)
        self.assertNotIn("-m", command)

    def test_only_local_models_need_hosts(self):
        self.assertEqual(evals.model_hosts("claude/claude-sonnet-5"), ())
        with patch.object(evals, "host_gateway", return_value="192.168.65.254"):
            self.assertEqual(evals.model_hosts("ollama/q"), ("host.docker.internal", "192.168.65.254"))

    def test_results_come_from_reward_and_receipt(self):
        with tempfile.TemporaryDirectory() as temp:
            trial = Path(temp) / "html-js-filter__abc"
            (trial / "verifier").mkdir(parents=True)
            (trial / "agent").mkdir()
            (trial / "verifier/reward.json").write_text('{"reward": 1}')
            (trial / "agent/exit").write_text("0\n")
            (trial / "result.json").write_text(json.dumps({"task_name": "html-js-filter", "agent_result": {
                "n_input_tokens": 500, "n_output_tokens": 20, "metadata": {"status": "ok", "rounds": 7}}}))
            broken = Path(temp) / "music-harmony__def"
            broken.mkdir()
            (broken / "result.json").write_text(json.dumps({"exception_info": {"exception_type": "AgentTimeoutError",
                                                                             "exception_message": "timed out"}}))
            text_only = Path(temp) / "photonic-waveguide-routing__ghi"
            (text_only / "verifier").mkdir(parents=True)
            (text_only / "verifier/reward.txt").write_text("0\n")
            (text_only / "result.json").write_text(json.dumps({"verifier_result": {"rewards": {"reward": 0.0}}}))
            records = evals.harbor_results(Path(temp))
        self.assertEqual([r["task"] for r in records], ["html-js-filter", "music-harmony", "photonic-waveguide-routing"])
        self.assertEqual(records[0]["reward"], 1)
        self.assertEqual(records[0]["rounds"], 7)
        self.assertEqual(records[0]["exit_code"], 0)
        self.assertIsNone(records[1]["reward"])
        self.assertEqual(records[1]["error"], "timed out")
        self.assertEqual(records[2]["reward"], 0.0)

    def test_slices_name_real_tasks(self):
        for name in ("terminal-bench-5.txt", "deepswe-5.txt"):
            lines = [l for l in (HERE / "evals" / name).read_text().splitlines() if l and not l.startswith("#")]
            self.assertEqual(len(lines), 5, name)


if __name__ == "__main__":
    unittest.main()
