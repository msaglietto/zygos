"""Campaign runner and report over fixture jobs; no Docker, no Harbor, no network."""

import hashlib
import json
import os
from decimal import Decimal
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from eval import campaign

HERE = Path(__file__).resolve().parent

# A Harbor stand-in: one job directory per invocation, shaped like a real
# trial, with the reward and failure mode taken from STUB_CONTROL.
STUB_HARBOR = r'''#!/usr/bin/env python3
import hashlib, json, os, shutil, sys
from pathlib import Path
args = sys.argv[1:]
name = args[args.index("--job-name") + 1]
out = Path(args[args.index("-o") + 1])
task = Path(args[args.index("-p") + 1]).name
control = json.loads(Path(os.environ["STUB_CONTROL"]).read_text())
binary = Path(os.environ["ZYGOS_LINUX_BIN"])
build = json.loads((binary.parent / "build.json").read_text())
trial_dir = out / name / f"{task}__stub"
agent = trial_dir / "agent"
agent.mkdir(parents=True)
shutil.copyfile(binary, agent / "zygos")
(agent / "providers.toml").write_text('[[providers]]\nname = "Deepseek Flash"\nkey_env = "DEEPSEEK_API_KEY"\n')
config = os.environ.get("ZYGOS_CONFIG")
if os.environ.get("ZYGOS_MODE") == "mission":
    assert config, "mission mode needs ZYGOS_CONFIG"
    (agent / "zygos.zon").write_bytes(Path(config).read_bytes())
    reply = control.get("mission", {}).get(name, {"state": "gating", "step": None, "step_index": 4, "stop": "none", "paused": True, "role_turns": 4, "tasks_done": 1})
    (agent / "mission.json").write_text(json.dumps(reply))
    (agent / "stdout.txt").write_text("approve mission::complete: x? [y/N] " + json.dumps(reply) + "\n")
    (agent / "mission-run.json").write_text(json.dumps({
        "mode": "mission", "task_id": task, "config_sha256": hashlib.sha256(Path(config).read_bytes()).hexdigest(),
        "role_max_steps": int(os.environ["ZYGOS_ROLE_MAX_STEPS"]) if os.environ.get("ZYGOS_ROLE_MAX_STEPS") else int(os.environ["ZYGOS_STEP_CAP"]),
        "exec_timeout_sec": 570, "exit_code": 1,
    }))
    tokens = control.get("tokens", {}).get(name, [1000, 100, 0])
    (agent / "planning").mkdir()
    pipeline = control.get("pipelines", {}).get(name) or [
        {"id": i, "definition_sha256": None, "tools": i == "executor"}
        for i in ("product-owner", "planner", "executor", "verifier")]
    events = [
        {"ts": 1, "event": "pipeline", "steps": pipeline},
        {"event": "mission", "from": "running", "to": "running", "step": "product-owner", "step_index": 0},
        {"event": "role_start", "role": "product-owner", "role_turn": 1},
        {"event": "step", "step": 1}, {"event": "usage", "step": 1, "input_tokens": tokens[0] - 1, "output_tokens": tokens[1]},
        {"event": "turn_end", "stop": "end_turn", "steps": 1},
        {"event": "role_end", "role": "product-owner", "outcome": "ok"},
        {"event": "role_start", "role": "executor", "role_turn": 2, "tools": True},
        {"event": "step", "step": 1}, {"event": "usage", "step": 1, "input_tokens": 1, "output_tokens": 0},
        {"event": "tool_call", "step": 1, "tool": "bash", "input": "{\"command\":\"ls\"}"},
        {"event": "tool_result", "step": 1, "tool": "bash", "is_error": False},
        {"event": "turn_end", "stop": "end_turn", "steps": 1},
        {"event": "role_end", "role": "executor", "outcome": "ok"},
    ]
    (agent / "planning" / "events.jsonl").write_text("".join(json.dumps(e) + "\n" for e in events))
    reward = control.get("rewards", {}).get(name, 0.0)
    (trial_dir / "result.json").write_text(json.dumps({
        "task_checksum": control["checksums"][task], "exception_info": None,
        "verifier_result": {"rewards": {"reward": reward}},
        "started_at": "2026-10-08T10:00:00+00:00", "finished_at": "2026-10-08T10:04:00+00:00",
    }))
    (out / f"{name}.stub.json").write_text(json.dumps({"argv": args, "mode": "mission", "config": config,
        "keys": sorted(k for k in ("DEEPSEEK_API_KEY", "Z_AI_API_KEY") if os.environ.get(k))}))
    sys.exit(0)
trial = {
    "task_id": task, "dataset": "terminal-bench/terminal-bench-2-1",
    "model_id": args[args.index("-m") + 1], "variable": "trim-" + os.environ["ZYGOS_TRIM"],
    "step_cap": int(os.environ["ZYGOS_STEP_CAP"]), "git_sha": build["git_sha"],
    "target_triple": "x86_64-linux.5.10...6.19-gnu.2.31", "optimize": "ReleaseSafe", "adapter_version": "0.2.0",
}
if config:
    trial["config_sha256"] = hashlib.sha256(Path(config).read_bytes()).hexdigest()
tokens = control.get("tokens", {}).get(name, [1000, 100, 400])
trial.update(source_lines_read=0, input_tokens=tokens[0], output_tokens=tokens[1], cache_read_tokens=tokens[2],
             cache_creation_tokens=0,
             trim={"calls": 3, "filtered": 0, "deduped": 0, "raw_bytes": 100, "sent_bytes": 72, "reduction": 28}
             if os.environ["ZYGOS_TRIM"] == "on" else
             {"calls": 0, "filtered": 0, "deduped": 0, "raw_bytes": 0, "sent_bytes": 0, "reduction": 0})
(agent / "trial.json").write_text(json.dumps(trial))
stop = "failed" if name in control.get("transport_failures", []) else "end_turn"
events = [
    {"event": "step", "step": 1}, {"event": "usage", "step": 1, "input_tokens": tokens[0] - 1, "output_tokens": tokens[1]},
    {"event": "tool_call", "step": 1, "tool": "bash", "input": "{\"command\":\"ls\"}"},
    {"event": "tool_result", "step": 1, "tool": "bash", "is_error": False},
    {"event": "step", "step": 2}, {"event": "usage", "step": 2, "input_tokens": 1, "output_tokens": 0},
    {"event": "turn_end", "stop": stop, "steps": 2} | ({"err": "provider_error"} if stop == "failed" else {}),
]
(agent / "events.jsonl").write_text("".join(json.dumps(e) + "\n" for e in events))
reward = control.get("rewards", {}).get(name, 0.0)
result = {
    "task_checksum": control["checksums"][task], "exception_info": None,
    "verifier_result": {"rewards": {"reward": reward}},
    "started_at": "2026-10-08T10:00:00+00:00", "finished_at": "2026-10-08T10:01:30+00:00",
}
(trial_dir / "result.json").write_text(json.dumps(result))
# What the runner handed us, without any secret value.
(out / f"{name}.stub.json").write_text(json.dumps({
    "argv": args, "key_set": bool(os.environ.get("DEEPSEEK_API_KEY")),
    "key_is_openrouter_value": os.environ.get("DEEPSEEK_API_KEY") == os.environ.get("OPENROUTER_API_KEY"),
    "key_value_in_argv": any(os.environ.get("DEEPSEEK_API_KEY", "\0") in a for a in args),
    "config": config, "platform": os.environ.get("DOCKER_DEFAULT_PLATFORM"),
}))
'''

STUB_SCORER = r'''#!/usr/bin/env python3
import json, sys
args = sys.argv[1:]
trial = json.loads(open(args[args.index("--trial") + 1]).read())
if trial["variable"] == "trim-on":
    print("cents=1 source_lines_read=0 reduction=28", file=sys.stderr); sys.exit(0)
print("cents=1 source_lines_read=0 reduction=0", file=sys.stderr); sys.exit(0)
'''

STUB_ZIG = r'''#!/usr/bin/env python3
import sys
from pathlib import Path
if sys.argv[1:] == ["version"]:
    print("0.16.0"); sys.exit(0)
prefix = Path(sys.argv[sys.argv.index("--prefix") + 1])
(prefix / "bin").mkdir(parents=True)
(prefix / "bin" / "zygos").write_bytes(b"stub-linux-binary " + " ".join(sys.argv[1:]).encode())
'''


def executable(path: Path, text: str) -> Path:
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)
    return path


class Fixture:
    """An experiment on disk with two builds, four tasks, stubs, and no secrets."""

    def __init__(self, root: Path, variable="trim", repeats=1, mode="task"):
        self.root = root
        self.builds = root / "builds"
        self.tasks = ["alpha", "beta"]
        self.tasks_dir = root / "tasks"
        for task in self.tasks:
            (self.tasks_dir / task).mkdir(parents=True)
            (self.tasks_dir / task / "task.toml").write_text("# fixture")
        self.checksums = {t: hashlib.sha256(t.encode()).hexdigest() for t in self.tasks}
        self.sha_a = "a" * 40
        self.sha_b = "b" * 40
        self.bin_a = self.make_build(self.sha_a, b"binary-a")
        self.bin_b = self.make_build(self.sha_b, b"binary-b")
        self.config = root / "candidate.zon"
        self.config.write_text('.{ .default = .{ .{ .provider_function = "zygos::providers::deepseek-flash", .model = "deepseek/deepseek-v4.1-flash" } } }\n')
        self.baseline_config = root / "baseline.zon"
        self.baseline_config.write_text('.{ .default = .{ .{ .provider_function = "zygos::providers::glm-flash", .model = "glm-5.3-flash" } } }\n')
        self.mode = mode
        self.harbor = executable(root / "harbor", STUB_HARBOR)
        self.scorer = executable(root / "scorer", STUB_SCORER)
        self.control = root / "control.json"
        self.set_control()
        base = {"name": "baseline", "trim": "on", "build": {"git_sha": self.sha_a, "binary_sha256": self.bin_a}}
        if mode == "mission":
            base["config"] = "baseline.zon"
        cand = dict(base, name="candidate")
        if variable == "trim":
            cand["trim"] = "off"
        elif variable == "config":
            cand["config"] = "candidate.zon"
        else:
            cand["build"] = {"git_sha": self.sha_b, "binary_sha256": self.bin_b}
        self.experiment = root / "experiment.json"
        self.write_experiment(variable, repeats, [base, cand])

    def write_experiment(self, variable, repeats, arms):
        self.experiment.write_text(json.dumps({
            "name": "fixture",
            "variable": variable,
            "mode": self.mode,
            "dataset": {"id": "terminal-bench/terminal-bench-2-1", "source_sha": "",
                        "tasks": [{"id": t, "checksum": self.checksums[t]} for t in self.tasks]},
            "model": {"id": "deepseek/deepseek-v4.1-flash", "key_env": "DEEPSEEK_API_KEY", "key_from_env": "OPENROUTER_API_KEY"},
            "prices": {"usd_per_million_tokens": {"input": "0.003", "cached_input": "0.003", "output": "2.40"}, "scorer_cents_per_mtok": 30},
            "step_cap": 24, "repeats": repeats, "host_concurrency": 2,
            "arms": arms,
        }))

    def make_build(self, sha, content):
        d = self.builds / sha
        d.mkdir(parents=True)
        (d / "zygos").write_bytes(content)
        digest = hashlib.sha256(content).hexdigest()
        (d / "build.json").write_text(json.dumps({"git_sha": sha, "binary_sha256": digest}))
        return digest

    def set_control(self, rewards=None, transport_failures=None, tokens=None):
        self.control.write_text(json.dumps({
            "checksums": self.checksums, "rewards": rewards or {},
            "transport_failures": transport_failures or [], "tokens": tokens or {},
        }))

    def run(self, extra=(), env_extra=None):
        jobs = self.root / "jobs"
        env = {"PATH": os.environ["PATH"], "OPENROUTER_API_KEY": "secret-fixture-key", "DEEPSEEK_API_KEY": "stale-direct-key",
               "Z_AI_API_KEY": "glm-fixture-key", "STUB_CONTROL": str(self.control)}
        env.update(env_extra or {})
        argv = [sys.executable, str(HERE / "campaign.py"), "run", "--experiment", str(self.experiment),
                "--jobs-dir", str(jobs), "--tasks-dir", str(self.tasks_dir), "--builds-dir", str(self.builds),
                "--harbor", str(self.harbor), "--scorer", "native", "--native-bin", str(self.scorer),
                "--skip-docker-check", *extra]
        result = subprocess.run(argv, env=env, capture_output=True, text=True, cwd=HERE.parent)
        return result, jobs

    def report(self, jobs):
        out = self.root / "report"
        argv = [sys.executable, str(HERE / "campaign.py"), "report", "--experiment", str(self.experiment),
                "--jobs-dir", str(jobs), "--out", str(out)]
        result = subprocess.run(argv, capture_output=True, text=True, cwd=HERE.parent)
        return result, out


class ExperimentContract(unittest.TestCase):
    def test_arms_must_differ_in_exactly_the_named_variable(self):
        with tempfile.TemporaryDirectory() as d:
            fx = Fixture(Path(d), variable="trim")
            campaign.Experiment(fx.experiment)
            same = {"name": "a", "trim": "on", "build": {"git_sha": fx.sha_a, "binary_sha256": fx.bin_a}}
            fx.write_experiment("trim", 1, [same, dict(same, name="b")])
            with self.assertRaisesRegex(campaign.CampaignError, "do not differ in trim"):
                campaign.Experiment(fx.experiment)
            fx.write_experiment("trim", 1, [same, dict(same, name="b", trim="off", config="candidate.zon")])
            with self.assertRaisesRegex(campaign.CampaignError, "differ in config"):
                campaign.Experiment(fx.experiment)
            fx.write_experiment("build", 1, [same, dict(same, name="b", build={"git_sha": fx.sha_b, "binary_sha256": fx.bin_b})])
            exp = campaign.Experiment(fx.experiment)
            self.assertEqual([a.variable_value("build") for a in exp.arms], [fx.sha_a, fx.sha_b])
            fx.write_experiment("trim", 1, [dict(same, trim="on"), dict(same, name="b", trim="off")])
            fx.experiment.write_text(fx.experiment.read_text().replace("deepseek/deepseek-v4.1-flash", "gpt-x"))
            with self.assertRaisesRegex(campaign.CampaignError, "approved"):
                campaign.Experiment(fx.experiment)

    def test_jobs_interleave_arms_per_matched_pair(self):
        with tempfile.TemporaryDirectory() as d:
            fx = Fixture(Path(d), repeats=2)
            exp = campaign.Experiment(fx.experiment)
            names = [exp.job_name(a, r, t) for a, r, t in exp.jobs()]
            self.assertEqual(names[:4], ["baseline-r1-alpha", "candidate-r1-alpha", "baseline-r1-beta", "candidate-r1-beta"])
            self.assertEqual(len(names), 8)


class RunContract(unittest.TestCase):
    def test_dry_run_plans_without_launching(self):
        with tempfile.TemporaryDirectory() as d:
            fx = Fixture(Path(d))
            result, jobs = fx.run(["--dry-run"])
            self.assertEqual(result.returncode, 0, result.stderr)
            plan = json.loads(result.stdout)
            self.assertEqual(plan["jobs"][0], "baseline-r1-alpha")
            self.assertEqual(plan["checks"]["credential"], "DEEPSEEK_API_KEY bound from OPENROUTER_API_KEY")
            self.assertFalse((jobs / "baseline-r1-alpha").exists())
            self.assertNotIn("secret-fixture-key", result.stdout)

    def test_missing_credential_or_build_refuses_before_launch(self):
        with tempfile.TemporaryDirectory() as d:
            fx = Fixture(Path(d))
            result, jobs = fx.run(env_extra={"OPENROUTER_API_KEY": ""})
            self.assertEqual(result.returncode, 2)
            self.assertIn("OPENROUTER_API_KEY is not set", result.stderr)
            # A different vendor's key already under key_env must not win over the pinned source.
            result, _ = fx.run(env_extra={"OPENROUTER_API_KEY": "", "DEEPSEEK_API_KEY": "direct-vendor-key"})
            self.assertEqual(result.returncode, 2)
            self.assertIn("OPENROUTER_API_KEY is not set", result.stderr)
            (fx.builds / fx.sha_a / "zygos").write_bytes(b"tampered")
            result, _ = fx.run()
            self.assertEqual(result.returncode, 2)
            self.assertIn("sha256", result.stderr)
            self.assertFalse(jobs.exists() and any(jobs.glob("*-r1-*")))

    def test_config_variable_runs_both_arms_and_reports_the_measured_change(self):
        with tempfile.TemporaryDirectory() as d:
            fx = Fixture(Path(d), variable="config")
            fx.set_control(rewards={"candidate-r1-alpha": 1.0, "candidate-r1-beta": 1.0, "baseline-r1-alpha": 1.0})
            result, jobs = fx.run()
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            base = json.loads((jobs / "baseline-r1-alpha.stub.json").read_text())
            cand = json.loads((jobs / "candidate-r1-alpha.stub.json").read_text())
            self.assertIsNone(base["config"])
            self.assertEqual(Path(cand["config"]).resolve(), fx.config.resolve())
            self.assertTrue(base["key_set"] and cand["key_set"])
            self.assertTrue(base["key_is_openrouter_value"])
            self.assertFalse(base["key_value_in_argv"])
            self.assertEqual(base["platform"], "linux/amd64")
            argv = base["argv"]
            self.assertEqual(argv[argv.index("-k") + 1], "1")
            self.assertEqual(argv[argv.index("--max-retries") + 1], "0")
            self.assertEqual(argv[argv.index("-a") + 1], "eval.harbor.zygos_agent:ZygosAgent")
            for path in jobs.rglob("*"):
                if path.is_file():
                    self.assertNotIn(b"secret-fixture-key", path.read_bytes(), path)
            saved = json.loads((jobs / "campaign.json").read_text())
            self.assertEqual(saved["status"], "finished")
            self.assertEqual(len(saved["trials"]), 4)
            self.assertEqual((jobs / "baseline-r1-alpha.score-exit.txt").read_text().strip(), "0")

            result, out = fx.report(jobs)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads((out / "report.json").read_text())
            self.assertEqual(report["verdict"], "candidate_better")
            self.assertEqual(report["arms"]["baseline"]["verifier_passes"], 1)
            self.assertEqual(report["arms"]["candidate"]["verifier_passes"], 2)
            self.assertEqual(report["arms"]["candidate"]["arm"]["config_sha256"], hashlib.sha256(fx.config.read_bytes()).hexdigest())
            self.assertEqual(report["arms"]["baseline"]["cost_usd"], "0.000486")  # ((1000-400)*0.003 + 400*0.003 + 100*2.40)/1e6 per trial, two trials
            self.assertEqual(report["matched"][1]["pass_delta"], 1)
            self.assertEqual(report["arms"]["candidate"]["problems"], 0)
            markdown = (out / "report.md").read_text()
            self.assertIn("| Verifier passes | 1 | 2 |", markdown)
            self.assertIn("candidate_better", markdown)
            self.assertTrue((out / "candidate.zon").is_file())
            self.assertTrue((out / "experiment.json").is_file())

    def test_resume_skips_recorded_jobs_and_a_transport_failure_stops_new_launches(self):
        with tempfile.TemporaryDirectory() as d:
            fx = Fixture(Path(d), repeats=2)
            fx.set_control(transport_failures=["baseline-r1-beta"])
            result, jobs = fx.run(["--concurrency", "1"])
            self.assertEqual(result.returncode, 4, result.stderr + result.stdout)
            saved = json.loads((jobs / "campaign.json").read_text())
            self.assertTrue(saved["status"].startswith("stopped: baseline-r1-beta"))
            launched = sorted(p.name for p in jobs.iterdir() if p.is_dir())
            self.assertEqual(launched, ["baseline-r1-alpha", "baseline-r1-beta", "candidate-r1-alpha"])

            # The failed job is recorded, not retried; a second invocation resumes the rest.
            fx.set_control()
            result, _ = fx.run(["--concurrency", "1"])
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            saved = json.loads((jobs / "campaign.json").read_text())
            self.assertEqual(saved["status"], "finished")
            self.assertEqual(len(saved["trials"]), 8)
            failed = next(t for t in saved["trials"] if t["job"] == "baseline-r1-beta")
            self.assertTrue(failed.get("transport_failure"))

            result, out = fx.report(jobs)
            report = json.loads((out / "report.json").read_text())
            self.assertEqual(report["verdict"], "inconclusive")
            self.assertTrue(any("baseline: 1 task-run" in r for r in report["verdict_reasons"]), report["verdict_reasons"])


class MissionContract(unittest.TestCase):
    def test_mission_mode_compares_two_route_tables_from_the_planning_trace(self):
        with tempfile.TemporaryDirectory() as d:
            fx = Fixture(Path(d), variable="config", mode="mission")
            fx.set_control(rewards={"candidate-r1-alpha": 1.0, "candidate-r1-beta": 1.0},
                           tokens={"baseline-r1-alpha": [4000, 300, 0]})
            result, jobs = fx.run(["--dry-run"])
            self.assertEqual(result.returncode, 0, result.stderr)
            plan = json.loads(result.stdout)
            self.assertEqual(plan["checks"]["mission_keys"], ["deepseek-flash:DEEPSEEK_API_KEY", "glm-flash:Z_AI_API_KEY"])
            result, jobs = fx.run()
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            stub = json.loads((jobs / "baseline-r1-alpha.stub.json").read_text())
            self.assertEqual(stub["mode"], "mission")
            self.assertEqual(Path(stub["config"]).resolve(), fx.baseline_config.resolve())
            self.assertEqual(stub["keys"], ["DEEPSEEK_API_KEY", "Z_AI_API_KEY"])
            self.assertFalse((jobs / "baseline-r1-alpha.score.txt").exists())
            result, out = fx.report(jobs)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads((out / "report.json").read_text())
            self.assertEqual(report["verdict"], "candidate_better")
            base, cand = report["arms"]["baseline"], report["arms"]["candidate"]
            self.assertEqual(base["problems"], 0)
            self.assertEqual(base["mean_role_turns"], 4)
            self.assertEqual(base["mission_states"], {"gating": 2})
            self.assertEqual(base["input_tokens"], 4000 + 1000)
            self.assertEqual(base["cost_usd"], str((Decimal(5000) * Decimal("0.003") + Decimal(400) * Decimal("2.40")) / Decimal(1_000_000)))
            self.assertEqual(base["cache_unreported"], 2)
            self.assertTrue(any("cache counts" in r for r in report["verdict_reasons"]))
            self.assertEqual(report["matched"][0]["baseline"]["stop"], "parked")
            markdown = (out / "report.md").read_text()
            self.assertIn("Mode: **mission**", markdown)
            self.assertIn("| Mean role turns | 4.0 | 4.0 |", markdown)
            self.assertTrue((out / "baseline.zon").is_file() and (out / "candidate.zon").is_file())

    def test_mission_mode_refuses_trim_variable_missing_config_and_missing_keys(self):
        with tempfile.TemporaryDirectory() as d:
            fx = Fixture(Path(d), variable="config", mode="mission")
            result, _ = fx.run(["--dry-run"], env_extra={"Z_AI_API_KEY": ""})
            self.assertEqual(result.returncode, 2)
            self.assertIn("glm-flash but Z_AI_API_KEY is not set", result.stderr)
            text = json.loads(fx.experiment.read_text())
            text["variable"] = "trim"
            text["arms"][1]["trim"] = "off"
            text["arms"][1]["config"] = "baseline.zon"
            fx.experiment.write_text(json.dumps(text))
            with self.assertRaisesRegex(campaign.CampaignError, "task-mode variable"):
                campaign.Experiment(fx.experiment)
            text["variable"] = "config"
            text["arms"][1]["trim"] = "on"
            del text["arms"][1]["config"]
            fx.experiment.write_text(json.dumps(text))
            with self.assertRaisesRegex(campaign.CampaignError, "mission arm needs a config"):
                campaign.Experiment(fx.experiment)

    def test_a_lost_mission_reply_is_recorded_not_a_problem(self):
        with tempfile.TemporaryDirectory() as d:
            fx = Fixture(Path(d), variable="config", mode="mission")
            fx.set_control()
            fx.control.write_text(json.dumps(json.loads(fx.control.read_text()) | {
                "mission": {"baseline-r1-alpha": {"state": "lost", "stop": "no_terminal_reply", "exit_code": 1}}}))
            result, jobs = fx.run()
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            result, out = fx.report(jobs)
            report = json.loads((out / "report.json").read_text())
            self.assertEqual(report["matched"][0]["baseline"]["stop"], "no_terminal_reply")
            self.assertEqual(report["arms"]["baseline"]["problems"], 0)
            # stdout is the evidence: a reply there beats a stale mission.json.
            job = jobs / "candidate-r1-alpha" / "alpha__stub" / "agent"
            (job / "mission.json").write_text(json.dumps({"state": "lost", "stop": "no_terminal_reply"}))
            result, out = fx.report(jobs)
            report = json.loads((out / "report.json").read_text())
            self.assertEqual(report["matched"][0]["candidate"]["stop"], "parked")
            self.assertEqual(report["arms"]["baseline"]["turn_stops"].get("no_terminal_reply"), 1)


STEPS_ZON = (
    '.{\n'
    '    .default = .{ .{ .provider_function = "zygos::providers::deepseek-flash", .model = "deepseek/deepseek-v4.1-flash" } },\n'
    '    // the architect replaces the product owner and the planner\n'
    '    .steps = .{\n'
    '        .{ .id = "architect", .definition = "agents/architect.md", .tools = true },\n'
    '        .{ .id = "executor" },\n'
    '        .{ .id = "verifier" },\n'
    '    },\n'
    '}\n'
)


def write_arm_dir(root: Path, name: str, zon: str, definitions: dict[str, bytes]) -> Path:
    directory = root / name
    directory.mkdir()
    (directory / "zygos.zon").write_text(zon)
    for relative, content in definitions.items():
        target = directory / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
    return directory


def digest(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


class PipelineContract(unittest.TestCase):
    def test_absent_steps_is_the_default_pipeline(self):
        with tempfile.TemporaryDirectory() as d:
            directory = write_arm_dir(Path(d), "a", '.{ .default = .{ .{ .model = "m" } } }\n', {})
            steps = campaign.read_pipeline(directory / "zygos.zon")
            self.assertEqual([s["id"] for s in steps], ["product-owner", "planner", "executor", "verifier"])
            self.assertEqual([s["tools"] for s in steps], [False, False, True, False])
            self.assertTrue(all(s["definition"] is None and s["definition_sha256"] is None for s in steps))

    def test_steps_block_is_parsed_with_definition_hashes_and_tool_defaults(self):
        with tempfile.TemporaryDirectory() as d:
            directory = write_arm_dir(Path(d), "a", STEPS_ZON, {"agents/architect.md": b"design it\n"})
            steps = campaign.read_pipeline(directory / "zygos.zon")
            self.assertEqual(steps, [
                {"id": "architect", "definition": "agents/architect.md", "definition_sha256": digest(b"design it\n"), "tools": True},
                {"id": "executor", "definition": None, "definition_sha256": None, "tools": True},
                {"id": "verifier", "definition": None, "definition_sha256": None, "tools": False},
            ])
            # Explicit .tools = false beats the executor default.
            off = write_arm_dir(Path(d), "b", '.{ .steps = .{ .{ .id = "executor", .tools = false } } }\n', {})
            self.assertFalse(campaign.read_pipeline(off / "zygos.zon")[0]["tools"])

    def test_a_steps_block_that_cannot_be_read_refuses(self):
        bad = {
            "unknown key": '.{ .steps = .{ .{ .id = "executor", .color = "red" } } }\n',
            "missing id": '.{ .steps = .{ .{ .tools = true } } }\n',
            "unterminated": '.{ .steps = .{ .{ .id = "executor" } }\n',
            "tools not a bool": '.{ .steps = .{ .{ .id = "executor", .tools = "yes" } } }\n',
            "empty list": '.{ .steps = .{} }\n',
            "not a struct": '.{ .steps = "executor" }\n',
            "duplicate key": '.{ .steps = .{ .{ .id = "executor", .id = "verifier" } } }\n',
            "no definition file": '.{ .steps = .{ .{ .id = "architect", .definition = "agents/missing.md" } } }\n',
            "absolute definition": '.{ .steps = .{ .{ .id = "architect", .definition = "/etc/passwd" } } }\n',
            "parent component": '.{ .steps = .{ .{ .id = "architect", .definition = "../outside.md" } } }\n',
        }
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "outside.md").write_text("outside")
            for index, (label, zon) in enumerate(bad.items()):
                directory = write_arm_dir(root, f"arm{index}", zon, {})
                with self.assertRaises(campaign.CampaignError, msg=label):
                    campaign.read_pipeline(directory / "zygos.zon")

    def test_a_definition_that_resolves_outside_the_zon_directory_refuses(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "outside.md").write_text("outside")
            directory = write_arm_dir(root, "arm", '.{ .steps = .{ .{ .id = "architect", .definition = "link.md" }, .{ .id = "executor" } } }\n', {})
            (directory / "link.md").symlink_to(root / "outside.md")
            with self.assertRaisesRegex(campaign.CampaignError, "outside"):
                campaign.read_pipeline(directory / "zygos.zon")

    def experiment_over(self, fx: "Fixture", baseline: str, candidate: str, variable="config"):
        arm = {"trim": "on", "build": {"git_sha": fx.sha_a, "binary_sha256": fx.bin_a}}
        newer = {"git_sha": fx.sha_b, "binary_sha256": fx.bin_b} if variable == "build" else arm["build"]
        fx.write_experiment(variable, 1, [
            dict(arm, name="baseline", config=f"{baseline}/zygos.zon"),
            dict(arm, name="candidate", config=f"{candidate}/zygos.zon", build=newer),
        ])
        return fx

    def test_definition_hash_changes_arm_identity(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            write_arm_dir(root, "a", STEPS_ZON, {"agents/architect.md": b"design it\n"})
            write_arm_dir(root, "b", STEPS_ZON, {"agents/architect.md": b"design it differently\n"})
            write_arm_dir(root, "c", STEPS_ZON, {"agents/architect.md": b"design it\n"})
            fx = Fixture(root, variable="config", mode="mission")
            self.experiment_over(fx, "a", "b")
            exp = campaign.Experiment(fx.experiment)
            base, cand = exp.arms
            # Byte-identical zon files; the definitions alone tell the arms apart.
            self.assertEqual(base.config_sha256, cand.config_sha256)
            self.assertNotEqual(base.identity()["pipeline"], cand.identity()["pipeline"])
            self.assertEqual(base.identity()["pipeline"][0], {
                "id": "architect", "definition_sha256": digest(b"design it\n"), "tools": True})
            self.assertNotEqual(base.variable_value("config"), cand.variable_value("config"))
            # Identical bytes everywhere: no difference, so no experiment.
            self.experiment_over(fx, "a", "c")
            with self.assertRaisesRegex(campaign.CampaignError, "do not differ in config"):
                campaign.Experiment(fx.experiment)
            # A differing definition is not allowed to ride along with another variable.
            self.experiment_over(fx, "a", "b", variable="build")
            with self.assertRaisesRegex(campaign.CampaignError, "differ in config"):
                campaign.Experiment(fx.experiment)

    def run_with_pipelines(self, root: Path):
        write_arm_dir(root, "a", STEPS_ZON, {"agents/architect.md": b"design it\n"})
        write_arm_dir(root, "b", STEPS_ZON, {"agents/architect.md": b"design it differently\n"})
        fx = Fixture(root, variable="config", mode="mission")
        self.experiment_over(fx, "a", "b")
        exp = campaign.Experiment(fx.experiment)
        fx.set_control()
        control = json.loads(fx.control.read_text())
        control["pipelines"] = {
            f"{arm.name}-r1-{task}": [{k: s[k] for k in ("id", "definition_sha256", "tools")} for s in arm.pipeline]
            for arm in exp.arms for task in fx.tasks
        }
        fx.control.write_text(json.dumps(control))
        result, jobs = fx.run()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return fx, jobs

    def events_of(self, jobs: Path, job: str, task: str) -> Path:
        return jobs / job / f"{task}__stub" / "agent" / "planning" / "events.jsonl"

    def test_a_matching_pipeline_event_is_not_a_problem(self):
        with tempfile.TemporaryDirectory() as d:
            fx, jobs = self.run_with_pipelines(Path(d))
            result, out = fx.report(jobs)
            report = json.loads((out / "report.json").read_text())
            self.assertEqual(report["arms"]["baseline"]["problems"], 0)
            self.assertEqual(report["arms"]["candidate"]["problems"], 0)
            self.assertEqual(report["arms"]["baseline"]["mission_states"], {"gating": 2})

    def test_a_pipeline_event_that_differs_from_the_arm_is_a_problem(self):
        with tempfile.TemporaryDirectory() as d:
            fx, jobs = self.run_with_pipelines(Path(d))
            path = self.events_of(jobs, "candidate-r1-alpha", "alpha")
            lines = [json.loads(line) for line in path.read_text().splitlines()]
            pipeline = next(e for e in lines if e["event"] == "pipeline")
            pipeline["steps"][0]["definition_sha256"] = digest(b"design it\n")  # the baseline's definition ran
            path.write_text("".join(json.dumps(e) + "\n" for e in lines))
            # A reordered pipeline is a different pipeline too.
            other = self.events_of(jobs, "baseline-r1-beta", "beta")
            lines = [json.loads(line) for line in other.read_text().splitlines()]
            next(e for e in lines if e["event"] == "pipeline")["steps"].reverse()
            other.write_text("".join(json.dumps(e) + "\n" for e in lines))
            result, out = fx.report(jobs)
            report = json.loads((out / "report.json").read_text())
            self.assertEqual(report["verdict"], "inconclusive")
            self.assertTrue(any("pipeline event differs" in p for p in report["matched"][0]["candidate"]["problems"]),
                            report["matched"][0]["candidate"]["problems"])
            self.assertTrue(any("pipeline event differs" in p for p in report["matched"][1]["baseline"]["problems"]))
            self.assertEqual(report["matched"][0]["baseline"]["problems"], [])

    def test_a_missing_pipeline_event_is_a_problem(self):
        with tempfile.TemporaryDirectory() as d:
            fx, jobs = self.run_with_pipelines(Path(d))
            path = self.events_of(jobs, "baseline-r1-alpha", "alpha")
            path.write_text("".join(l + "\n" for l in path.read_text().splitlines() if '"pipeline"' not in l))
            result, out = fx.report(jobs)
            report = json.loads((out / "report.json").read_text())
            self.assertEqual(report["verdict"], "inconclusive")
            self.assertIn("pipeline event missing", report["matched"][0]["baseline"]["problems"])

    def test_an_uploaded_pipeline_that_differs_from_the_arm_is_a_problem(self):
        with tempfile.TemporaryDirectory() as d:
            fx, jobs = self.run_with_pipelines(Path(d))
            run_path = jobs / "candidate-r1-beta" / "beta__stub" / "agent" / "mission-run.json"
            run = json.loads(run_path.read_text())
            run["pipeline"] = [{"id": "executor", "definition": None, "definition_sha256": None, "tools": True}]
            run_path.write_text(json.dumps(run))
            result, out = fx.report(jobs)
            report = json.loads((out / "report.json").read_text())
            self.assertIn("uploaded pipeline in mission-run.json differs from the arm", report["matched"][1]["candidate"]["problems"])

    def test_the_mission_states_metric_counts_the_new_state_names(self):
        with tempfile.TemporaryDirectory() as d:
            fx = Fixture(Path(d), variable="config", mode="mission")
            failed = {"state": "failed", "step": "executor", "step_index": 2, "stop": "role_failed", "role_turns": 3, "tasks_done": 0}
            done = {"state": "done", "step": None, "step_index": 4, "stop": "completed", "role_turns": 5, "tasks_done": 2}
            fx.set_control()
            fx.control.write_text(json.dumps(json.loads(fx.control.read_text()) | {
                "mission": {"baseline-r1-alpha": failed, "baseline-r1-beta": done}}))
            result, jobs = fx.run()
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            result, out = fx.report(jobs)
            report = json.loads((out / "report.json").read_text())
            self.assertEqual(report["arms"]["baseline"]["mission_states"], {"failed": 1, "done": 1})
            self.assertEqual(report["arms"]["candidate"]["mission_states"], {"gating": 2})
            self.assertIn('{"done": 1, "failed": 1}', (out / "report.md").read_text())


class ReportContract(unittest.TestCase):
    def test_a_pass_delta_within_repeat_noise_does_not_decide_the_verdict(self):
        with tempfile.TemporaryDirectory() as d:
            fx = Fixture(Path(d), repeats=2)
            # alpha flips between repeats inside the baseline arm; the candidate wins by exactly one.
            fx.set_control(rewards={"baseline-r1-alpha": 1.0, "candidate-r1-alpha": 1.0, "candidate-r2-alpha": 1.0})
            result, jobs = fx.run()
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            result, out = fx.report(jobs)
            report = json.loads((out / "report.json").read_text())
            self.assertEqual(report["repeat_noise_tasks"], 1)
            self.assertEqual(report["verdict"], "no_observed_difference")
            self.assertTrue(any("within repeat noise" in r for r in report["verdict_reasons"]), report["verdict_reasons"])

    def test_report_over_missing_jobs_is_inconclusive_and_still_lists_every_pair(self):
        with tempfile.TemporaryDirectory() as d:
            fx = Fixture(Path(d))
            jobs = fx.root / "jobs"
            jobs.mkdir()
            result, out = fx.report(jobs)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads((out / "report.json").read_text())
            self.assertEqual(report["verdict"], "inconclusive")
            self.assertEqual(len(report["matched"]), 2)
            self.assertIn("job directory missing", report["matched"][0]["baseline"]["problems"])

    def test_identity_drift_in_a_trial_is_a_problem_not_a_result(self):
        with tempfile.TemporaryDirectory() as d:
            fx = Fixture(Path(d))
            result, jobs = fx.run()
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            trial = jobs / "candidate-r1-alpha" / "alpha__stub" / "agent" / "trial.json"
            data = json.loads(trial.read_text())
            data["git_sha"] = "c" * 40
            trial.write_text(json.dumps(data))
            result, out = fx.report(jobs)
            report = json.loads((out / "report.json").read_text())
            self.assertEqual(report["verdict"], "inconclusive")
            pair = report["matched"][0]["candidate"]
            self.assertTrue(any("git_sha" in p for p in pair["problems"]), pair["problems"])

            # A trace without turn_end means the harness lost the turn; that is a problem, not a stop.
            events = jobs / "baseline-r1-beta" / "beta__stub" / "agent" / "events.jsonl"
            events.write_text("".join(l + "\n" for l in events.read_text().splitlines() if '"turn_end"' not in l))
            result, out = fx.report(jobs)
            report = json.loads((out / "report.json").read_text())
            self.assertIn("turn never ended (no turn_end event)", report["matched"][1]["baseline"]["problems"])


class BuildContract(unittest.TestCase):
    def test_build_from_a_clean_worktree_records_the_identity(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            repo = root / "repo"
            repo.mkdir()
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            (repo / "build.zig").write_text("// fixture")
            env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@x", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@x")
            subprocess.run(["git", "-C", str(repo), "add", "."], check=True, env=env)
            subprocess.run(["git", "-C", str(repo), "commit", "-q", "-m", "fixture"], check=True, env=env)
            sha = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
            zig = executable(root / "zig", STUB_ZIG)
            meta = campaign.build_arm("HEAD", root / "builds", str(zig), repo)
            self.assertEqual(meta["git_sha"], sha)
            binary = root / "builds" / sha / "zygos"
            self.assertEqual(meta["binary_sha256"], hashlib.sha256(binary.read_bytes()).hexdigest())
            self.assertIn(b"-Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe", binary.read_bytes())
            self.assertEqual(json.loads((root / "builds" / sha / "build.json").read_text())["zig_version"], "0.16.0")
            worktrees = subprocess.run(["git", "-C", str(repo), "worktree", "list"], capture_output=True, text=True).stdout
            self.assertEqual(len(worktrees.strip().splitlines()), 1)

    def test_wrong_zig_version_refuses(self):
        with tempfile.TemporaryDirectory() as d:
            zig = executable(Path(d) / "zig", "#!/bin/sh\necho 0.17.0\n")
            with self.assertRaisesRegex(campaign.CampaignError, "0.16"):
                campaign.build_arm("HEAD", Path(d) / "builds", str(zig), HERE.parent)


if __name__ == "__main__":
    unittest.main()
