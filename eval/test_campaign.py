"""Campaign runner and report over fixture jobs; no Docker, no Harbor, no network."""

import hashlib
import json
import os
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

    def __init__(self, root: Path, variable="trim", repeats=1):
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
        self.harbor = executable(root / "harbor", STUB_HARBOR)
        self.scorer = executable(root / "scorer", STUB_SCORER)
        self.control = root / "control.json"
        self.set_control()
        base = {"name": "baseline", "trim": "on", "build": {"git_sha": self.sha_a, "binary_sha256": self.bin_a}}
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
               "STUB_CONTROL": str(self.control)}
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


class ReportContract(unittest.TestCase):
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
