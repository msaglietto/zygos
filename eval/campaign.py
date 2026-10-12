#!/usr/bin/env python3
"""Matched benchmark campaigns: build an arm, run an experiment, report it.

One experiment file freezes everything two arms share (tasks and checksums,
model, prices, step cap, repeats) and names the single variable they differ
in: `trim`, `config` (a `zygos.zon` route table), or `build` (a git sha).
`run` launches one Harbor task per invocation, interleaving arms so matched
pairs are close in time, and records every attempt in `campaign.json`.
`report` re-reads the raw job directories and writes a durable comparison
that either shows the measured change or says why it is inconclusive.

Run with Harbor's Python (it needs no Harbor import itself):

    eval/campaign.py build  --git-ref HEAD
    eval/campaign.py run    --experiment eval/experiments/trim-ablation.json \\
                            --jobs-dir /tmp/zygos-trim-ablation --tasks-dir DIR
    eval/campaign.py report --experiment ... --jobs-dir ... --out reports/benchmarks/NAME

Credentials enter only through the environment and are never written to a
job directory, a log, or a report. The contract is docs/specs/campaign.md.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
from collections import Counter
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path, PurePosixPath

REPO = Path(__file__).resolve().parents[1]
DATASET = "terminal-bench/terminal-bench-2-1"
APPROVED_MODELS = ("glm-5.3-flash", "deepseek/deepseek-v4.1-flash")
VARIABLES = ("trim", "config", "build")
MODES = ("task", "mission")
# Catalog slug -> the key the adapter's keyless mission catalog expects.
MISSION_SLUG_KEYS = {"deepseek-flash": "DEEPSEEK_API_KEY", "glm-flash": "Z_AI_API_KEY"}
LINUX_TARGET = "x86_64-linux-gnu"
OPTIMIZE = "ReleaseSafe"
DEFAULT_BUILDS_DIR = REPO / "zig-out" / "bench"
SCORER_IMAGE = "debian:bullseye-slim"
MILLION = Decimal(1_000_000)


class CampaignError(RuntimeError):
    """A refusal before or during a campaign. The message is safe to print."""


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path: Path, value) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=False) + "\n", encoding="utf-8")
    tmp.replace(path)


# ---------------------------------------------------------------------------
# Mission pipeline (`.steps` in a zygos.zon)
# ---------------------------------------------------------------------------

DEFAULT_STEP_IDS = ("product-owner", "planner", "executor", "verifier")
STEP_KEYS = ("id", "definition", "tools")
MAX_DEFINITION_BYTES = 64 * 1024

_ZON_TOKEN = re.compile(
    r'(?P<space>\s+)|(?P<comment>//[^\n]*)|(?P<string>"(?:[^"\\\n]|\\.)*")'
    r"|(?P<word>[A-Za-z_][A-Za-z0-9_]*)|(?P<number>-?[0-9][A-Za-z0-9_.]*)|(?P<punct>[{}=,.])"
)


def default_pipeline() -> list[dict]:
    """The pipeline a zygos.zon without `.steps` runs: built-in prompts, tools on the executor."""
    return [{"id": i, "definition": None, "definition_sha256": None, "tools": i == "executor"} for i in DEFAULT_STEP_IDS]


def pipeline_identity(steps: list[dict]) -> list[dict]:
    """What an arm's identity and the trace's `pipeline` event carry per step."""
    return [{"id": s["id"], "definition_sha256": s["definition_sha256"], "tools": s["tools"]} for s in steps]


def _zon_tokens(text: str) -> list[tuple[str, str]] | None:
    """Tokens of a zon file, comments dropped; None when something is not one of
    the few shapes the pipeline parser knows (so the caller can decide)."""
    tokens: list[tuple[str, str]] = []
    position = 0
    while position < len(text):
        match = _ZON_TOKEN.match(text, position)
        if match is None:
            return None
        position = match.end()
        if match.lastgroup not in ("space", "comment"):
            tokens.append((match.lastgroup, match.group()))
    return tokens


class _StepsParser:
    """Strict reader for the one value shape `.steps` may take: a tuple of
    structs whose fields are strings or bools. Anything else refuses."""

    def __init__(self, tokens: list[tuple[str, str]], where: str):
        self.tokens = tokens
        self.where = where

    def fail(self, why: str):
        raise CampaignError(f"{self.where}: .steps {why}")

    def peek(self, at: int, kind: str, text: str | None = None) -> bool:
        return at < len(self.tokens) and self.tokens[at][0] == kind and (text is None or self.tokens[at][1] == text)

    def value(self, at: int):
        """-> (value, next). Struct elements come back as [(name | None, value)]."""
        if at >= len(self.tokens):
            self.fail("ends inside a value")
        kind, text = self.tokens[at]
        if kind == "string":
            body = text[1:-1]
            if "\\" in body:
                body = re.sub(r"\\(.)", lambda m: m.group(1) if m.group(1) in '\\"' else self.fail("has an unsupported string escape"), body)
            return body, at + 1
        if kind == "word" and text in ("true", "false"):
            return text == "true", at + 1
        if self.peek(at, "punct", ".") and self.peek(at + 1, "punct", "{"):
            return self.struct(at)
        self.fail(f"has an unreadable value near {text!r}")

    def struct(self, at: int):
        at += 2  # `.{`
        items: list[tuple[str | None, object]] = []
        while not self.peek(at, "punct", "}"):
            name = None
            if self.peek(at, "punct", ".") and self.peek(at + 1, "word") and self.peek(at + 2, "punct", "="):
                name = self.tokens[at + 1][1]
                at += 3
            value, at = self.value(at)
            items.append((name, value))
            if self.peek(at, "punct", ","):
                at += 1
            elif not self.peek(at, "punct", "}"):
                self.fail("is missing a comma or a closing brace")
        return items, at + 1


def _steps_entries(tokens: list[tuple[str, str]], where: str) -> list[dict] | None:
    """The raw `.steps` entries (id/definition/tools as written), or None when
    the root struct has no `.steps` field. Only a top-level field counts."""
    if len(tokens) < 2 or tokens[0][1] != "." or tokens[1][1] != "{":
        return None
    depth, at, found = 0, 0, None
    while at < len(tokens):
        text = tokens[at][1]
        if tokens[at][0] == "punct" and text == "{":
            depth += 1
        elif tokens[at][0] == "punct" and text == "}":
            depth -= 1
        elif (depth == 1 and text == "." and at + 2 < len(tokens)
              and tokens[at + 1] == ("word", "steps") and tokens[at + 2][1] == "="):
            if found is not None:
                raise CampaignError(f"{where}: .steps appears twice")
            found = at + 3
        at += 1
    if depth != 0:
        raise CampaignError(f"{where}: unbalanced braces, so .steps cannot be trusted")
    if found is None:
        return None
    parser = _StepsParser(tokens, where)
    value, _ = parser.value(found)
    if not isinstance(value, list):
        parser.fail("must be a list of step entries")
    if not value:
        parser.fail("is empty")
    entries = []
    for index, (name, entry) in enumerate(value):
        if name is not None or not isinstance(entry, list):
            parser.fail(f"entry {index} must be a struct")
        fields: dict = {}
        for key, field in entry:
            if key not in STEP_KEYS:
                parser.fail(f"entry {index} has unknown key {key!r}")
            if key in fields:
                parser.fail(f"entry {index} repeats key {key!r}")
            wanted = bool if key == "tools" else str
            if not isinstance(field, wanted):
                parser.fail(f"entry {index}: .{key} must be a {'bool' if key == 'tools' else 'string'}")
            fields[key] = field
        if not fields.get("id"):
            parser.fail(f"entry {index} has no .id")
        entries.append(fields)
    return entries


def read_pipeline(zon_path: Path) -> list[dict]:
    """The pipeline a zygos.zon pins: `[{"id","definition","definition_sha256","tools"}]`.

    Absent `.steps` is the default pipeline. A `.steps` block this reader cannot
    parse, or a definition that is unreadable, empty, over 64 KiB, absolute,
    holds a `..` component, or resolves outside the file's directory, refuses
    the experiment. It does not repeat the binary's other boot checks (reserved
    ids, an executor, a verifier without tools); the mission refuses those.
    """
    zon_path = Path(zon_path)
    text = zon_path.read_text(encoding="utf-8")
    where = str(zon_path)
    tokens = _zon_tokens(text)
    if tokens is None:
        if re.search(r"\bsteps\b", text):
            raise CampaignError(f"{where}: cannot tokenize the file, so its .steps cannot be read")
        return default_pipeline()
    entries = _steps_entries(tokens, where)
    if entries is None:
        return default_pipeline()
    base = zon_path.resolve().parent
    steps = []
    for index, entry in enumerate(entries):
        relative = entry.get("definition")
        digest = None
        if relative is not None:
            parts = PurePosixPath(relative).parts
            if not relative or relative.startswith("/") or ".." in parts:
                raise CampaignError(f"{where}: steps[{index}]: definition path {relative!r} must be relative with no '..'")
            target = (base / relative).resolve()
            if not target.is_relative_to(base):
                raise CampaignError(f"{where}: steps[{index}]: definition {relative!r} resolves outside the config directory")
            try:
                data = target.read_bytes()
            except OSError as exc:
                raise CampaignError(f"{where}: steps[{index}]: definition {relative!r} is unreadable: {exc.strerror}") from exc
            if not data.strip() or len(data) > MAX_DEFINITION_BYTES:
                raise CampaignError(f"{where}: steps[{index}]: definition {relative!r} is empty or over {MAX_DEFINITION_BYTES} bytes")
            digest = hashlib.sha256(data).hexdigest()
        steps.append({
            "id": entry["id"],
            "definition": relative,
            "definition_sha256": digest,
            "tools": entry.get("tools", entry["id"] == "executor"),
        })
    return steps


# ---------------------------------------------------------------------------
# Experiment definition
# ---------------------------------------------------------------------------


class Arm:
    def __init__(self, raw: dict, experiment_dir: Path):
        self.name = str(raw.get("name", ""))
        if not self.name or any(c in self.name for c in "/ \t"):
            raise CampaignError("arm name must be a non-empty token without '/' or spaces")
        self.trim = str(raw.get("trim", "on"))
        if self.trim not in ("on", "off"):
            raise CampaignError(f"arm {self.name}: trim must be on or off")
        build = raw.get("build") or {}
        self.git_sha = str(build.get("git_sha", ""))
        self.binary_sha256 = str(build.get("binary_sha256", ""))
        if len(self.git_sha) not in (40, 64) or len(self.binary_sha256) != 64:
            raise CampaignError(f"arm {self.name}: build needs git_sha and binary_sha256")
        config = raw.get("config")
        self.config_path: Path | None = None
        self.config_sha256: str | None = None
        if config is not None:
            path = (experiment_dir / str(config)).resolve()
            if not path.is_file():
                raise CampaignError(f"arm {self.name}: config {config} is not a file")
            self.config_path = path
            self.config_sha256 = sha256_file(path)
        # The pipeline the config pins. Definition files are part of the arm:
        # the zon bytes name them, but only their own bytes say what ran.
        self.pipeline: list[dict] = read_pipeline(self.config_path) if self.config_path else default_pipeline()
        # Set by `Experiment.locate_builds`.
        self.binary: Path | None = None

    def identity(self) -> dict:
        return {
            "name": self.name,
            "trim": self.trim,
            "git_sha": self.git_sha,
            "binary_sha256": self.binary_sha256,
            "config": str(self.config_path) if self.config_path else None,
            "config_sha256": self.config_sha256,
            "pipeline": pipeline_identity(self.pipeline),
        }

    def definition_hashes(self) -> list[str | None]:
        return [s["definition_sha256"] for s in self.pipeline]

    def variable_value(self, variable: str) -> str:
        if variable == "trim":
            return self.trim
        if variable == "config":
            hashes = [h for h in self.definition_hashes() if h]
            if not hashes:
                return self.config_sha256 or "none"
            return f"{self.config_sha256}+{hashlib.sha256(' '.join(hashes).encode()).hexdigest()[:12]}"
        return self.git_sha


class Experiment:
    def __init__(self, path: Path):
        self.path = path.resolve()
        raw = json.loads(self.path.read_text(encoding="utf-8"))
        self.raw = raw
        self.name = str(raw.get("name", ""))
        if not self.name or any(c in self.name for c in "/ \t"):
            raise CampaignError("experiment name must be a non-empty token")
        self.variable = str(raw.get("variable", ""))
        if self.variable not in VARIABLES:
            raise CampaignError(f"variable must be one of {', '.join(VARIABLES)}")
        self.mode = str(raw.get("mode", "task"))
        if self.mode not in MODES:
            raise CampaignError(f"mode must be one of {', '.join(MODES)}")
        if self.mode == "mission" and self.variable == "trim":
            raise CampaignError("trim is a task-mode variable; a mission run always compresses output")
        dataset = raw.get("dataset") or {}
        if dataset.get("id") != DATASET:
            raise CampaignError(f"dataset id must be {DATASET}")
        self.dataset_source_sha = str(dataset.get("source_sha", ""))
        self.tasks: list[dict] = list(dataset.get("tasks") or [])
        if not self.tasks:
            raise CampaignError("dataset.tasks is empty")
        for task in self.tasks:
            task_id = str(task.get("id", ""))
            if not task_id or "/" in task_id or ".." in task_id:
                raise CampaignError(f"bad task id {task_id!r}")
            if len(str(task.get("checksum", ""))) != 64:
                raise CampaignError(f"task {task_id}: checksum must be 64 hex characters")
        model = raw.get("model") or {}
        self.model_id = str(model.get("id", ""))
        if self.model_id not in APPROVED_MODELS:
            raise CampaignError("model.id is not an approved live model")
        self.key_env = str(model.get("key_env", ""))
        self.key_from_env = model.get("key_from_env")
        if not self.key_env:
            raise CampaignError("model.key_env is required")
        prices = raw.get("prices") or {}
        rates = prices.get("usd_per_million_tokens") or {}
        try:
            self.rate_input = Decimal(str(rates["input"]))
            self.rate_cached = Decimal(str(rates["cached_input"]))
            self.rate_output = Decimal(str(rates["output"]))
        except (KeyError, ArithmeticError) as exc:
            raise CampaignError("prices.usd_per_million_tokens needs input, cached_input, output") from exc
        self.scorer_cents = int(prices.get("scorer_cents_per_mtok", 0))
        self.price_source = prices.get("source")
        self.price_retrieved = prices.get("retrieved_utc")
        self.step_cap = int(raw.get("step_cap", 24))
        if not 1 <= self.step_cap <= 32:
            raise CampaignError("step_cap must be 1..32")
        self.repeats = int(raw.get("repeats", 1))
        if self.repeats < 1:
            raise CampaignError("repeats must be at least 1")
        self.workspace = str(raw.get("workspace", "/app"))
        self.host_concurrency = int(raw.get("host_concurrency", 2))
        if not 1 <= self.host_concurrency <= 2:
            raise CampaignError("host_concurrency must be 1 or 2 (benchmark policy)")
        self.ca_bundle_sha256 = raw.get("ca_bundle_sha256")
        arms = raw.get("arms") or []
        if len(arms) != 2:
            raise CampaignError("exactly two arms: baseline first, candidate second")
        self.arms = [Arm(a, self.path.parent) for a in arms]
        self.baseline, self.candidate = self.arms
        if self.baseline.name == self.candidate.name:
            raise CampaignError("arm names must differ")
        if self.mode == "mission":
            for arm in self.arms:
                if arm.config_path is None:
                    raise CampaignError(f"arm {arm.name}: a mission arm needs a config (its route table)")
        self.check_single_variable()

    def config_slugs(self) -> set[str]:
        """Catalog slugs named by any arm's route table (mission mode boots them)."""
        import re

        slugs: set[str] = set()
        for arm in self.arms:
            if arm.config_path is not None:
                slugs |= set(re.findall(r"zygos::providers::([a-z0-9-]+)", arm.config_path.read_text(encoding="utf-8")))
        return slugs

    def check_single_variable(self) -> None:
        """Matched arms differ in the named variable and nothing else."""
        a, b = self.baseline, self.candidate
        same = {
            "trim": a.trim == b.trim,
            # Part of the config axis: the zon and the definition files it names.
            "config": a.config_sha256 == b.config_sha256 and pipeline_identity(a.pipeline) == pipeline_identity(b.pipeline),
            "build": a.git_sha == b.git_sha and a.binary_sha256 == b.binary_sha256,
        }
        if same[self.variable]:
            raise CampaignError(f"arms do not differ in {self.variable}")
        for axis, equal in same.items():
            if axis != self.variable and not equal:
                raise CampaignError(f"arms differ in {axis}, but the variable is {self.variable}")

    def task_ids(self) -> list[str]:
        return [str(t["id"]) for t in self.tasks]

    def checksum(self, task_id: str) -> str:
        for task in self.tasks:
            if task["id"] == task_id:
                return str(task["checksum"])
        raise KeyError(task_id)

    def job_name(self, arm: Arm, repeat: int, task_id: str) -> str:
        return f"{arm.name}-r{repeat}-{task_id}"

    def jobs(self) -> list[tuple[Arm, int, str]]:
        """Matched order: both arms of a (repeat, task) pair run adjacently."""
        out = []
        for repeat in range(1, self.repeats + 1):
            for task_id in self.task_ids():
                for arm in self.arms:
                    out.append((arm, repeat, task_id))
        return out

    def locate_builds(self, builds_dir: Path) -> None:
        for arm in self.arms:
            build_dir = builds_dir / arm.git_sha
            meta_path = build_dir / "build.json"
            binary = build_dir / "zygos"
            if not meta_path.is_file() or not binary.is_file():
                raise CampaignError(f"arm {arm.name}: no build for {arm.git_sha} under {builds_dir} (run `campaign.py build`)")
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            if meta.get("git_sha") != arm.git_sha:
                raise CampaignError(f"arm {arm.name}: build.json git_sha does not match")
            actual = sha256_file(binary)
            if actual != arm.binary_sha256 or meta.get("binary_sha256") != arm.binary_sha256:
                raise CampaignError(f"arm {arm.name}: binary sha256 {actual} does not match {arm.binary_sha256}")
            arm.binary = binary

    def cost_usd(self, trial: dict) -> Decimal:
        """Three-rate snapshot estimate; not a provider invoice."""
        input_tokens = Decimal(int(trial.get("input_tokens", 0)))
        output_tokens = Decimal(int(trial.get("output_tokens", 0)))
        cached = Decimal(int(trial.get("cache_read_tokens", 0) or 0))
        ordinary = max(input_tokens - cached, Decimal(0))
        return (ordinary * self.rate_input + cached * self.rate_cached + output_tokens * self.rate_output) / MILLION

    def summary(self) -> dict:
        return {
            "name": self.name,
            "variable": self.variable,
            "mode": self.mode,
            "dataset": DATASET,
            "dataset_source_sha": self.dataset_source_sha,
            "tasks": self.tasks,
            "model_id": self.model_id,
            "step_cap": self.step_cap,
            "repeats": self.repeats,
            "workspace": self.workspace,
            "host_concurrency": self.host_concurrency,
            "usd_per_million_tokens": {
                "input": str(self.rate_input),
                "cached_input": str(self.rate_cached),
                "output": str(self.rate_output),
            },
            "price_source": self.price_source,
            "price_retrieved_utc": self.price_retrieved,
            "scorer_cents_per_mtok": self.scorer_cents,
            "arms": [arm.identity() for arm in self.arms],
        }


# ---------------------------------------------------------------------------
# build: a clean-worktree Linux artifact with its identity
# ---------------------------------------------------------------------------


def zig_version(zig: str) -> str:
    result = subprocess.run([zig, "version"], capture_output=True, text=True)
    if result.returncode != 0:
        raise CampaignError(f"{zig} version failed")
    version = result.stdout.strip()
    if not version.startswith("0.16."):
        raise CampaignError(f"zig {version} selected; this project needs 0.16.x (pass --zig)")
    return version


def build_arm(git_ref: str, builds_dir: Path, zig: str, repo: Path) -> dict:
    """Build the Linux ReleaseSafe artifact from a detached, clean worktree.

    The embedded git sha is the worktree's HEAD; a dirty tree stamps
    `unknown`, which the task command refuses, so the artifact and the
    recorded sha always agree.
    """
    version = zig_version(zig)
    sha = subprocess.run(["git", "-C", str(repo), "rev-parse", "--verify", f"{git_ref}^{{commit}}"], capture_output=True, text=True)
    if sha.returncode != 0:
        raise CampaignError(f"unknown git ref {git_ref}")
    git_sha = sha.stdout.strip()
    out_dir = builds_dir / git_sha
    out_dir.mkdir(parents=True, exist_ok=True)
    worktree = Path(tempfile.mkdtemp(prefix="zygos-build-"))
    try:
        subprocess.run(["git", "-C", str(repo), "worktree", "add", "--detach", str(worktree), git_sha], check=True, capture_output=True)
        status = subprocess.run(["git", "-C", str(worktree), "status", "--porcelain"], capture_output=True, text=True, check=True)
        if status.stdout.strip():
            raise CampaignError("fresh worktree is not clean; refusing to build an unidentifiable binary")
        prefix = worktree / "out"
        build = subprocess.run(
            [zig, "build", f"-Dtarget={LINUX_TARGET}", f"-Doptimize={OPTIMIZE}", "--prefix", str(prefix)],
            cwd=worktree,
            capture_output=True,
            text=True,
        )
        (out_dir / "build.log").write_text(build.stdout + build.stderr, encoding="utf-8")
        if build.returncode != 0:
            raise CampaignError(f"zig build failed for {git_sha}; see {out_dir / 'build.log'}")
        binary = prefix / "bin" / "zygos"
        if not binary.is_file():
            raise CampaignError("zig build produced no bin/zygos")
        shutil.copyfile(binary, out_dir / "zygos")
        (out_dir / "zygos").chmod(0o755)
    finally:
        subprocess.run(["git", "-C", str(repo), "worktree", "remove", "--force", str(worktree)], capture_output=True)
        shutil.rmtree(worktree, ignore_errors=True)
    meta = {
        "git_sha": git_sha,
        "binary": "zygos",
        "binary_sha256": sha256_file(out_dir / "zygos"),
        "target": LINUX_TARGET,
        "optimize": OPTIMIZE,
        "zig_version": version,
        "built_utc": utc_now(),
    }
    write_json(out_dir / "build.json", meta)
    return meta


# ---------------------------------------------------------------------------
# Inspection of one Harbor job (pure reads; no network, no Docker)
# ---------------------------------------------------------------------------


def read_events(path: Path) -> list[dict]:
    events = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line:
            events.append(json.loads(line))
    return events


def inspect_job(exp: Experiment, jobs_dir: Path, arm: Arm, repeat: int, task_id: str) -> dict:
    """Everything the report needs from one job, with every identity check.

    Problems are recorded under `problems`, never raised: a report over a
    broken job must still show the job.
    """
    name = exp.job_name(arm, repeat, task_id)
    record: dict = {
        "job": name,
        "arm": arm.name,
        "repeat": repeat,
        "task_id": task_id,
        "problems": [],
        "reward": None,
        "scorer_exit": None,
        "scorer_result": None,
    }
    job_dir = jobs_dir / name
    exit_file = jobs_dir / f"{name}.harbor-exit.txt"
    if exit_file.is_file():
        try:
            record["harbor_exit"] = int(exit_file.read_text().strip())
        except ValueError:
            record["problems"].append("harbor exit code unreadable")
    if not job_dir.is_dir():
        record["problems"].append("job directory missing")
        return record
    trial_dirs = sorted(p for p in job_dir.glob(f"{task_id}__*") if p.is_dir())
    if len(trial_dirs) != 1:
        record["problems"].append(f"expected one trial directory, found {len(trial_dirs)}")
        return record
    trial_dir = trial_dirs[0]
    record["trial_path"] = str(trial_dir)
    result_path = trial_dir / "result.json"
    if not result_path.is_file():
        record["problems"].append("result.json missing")
        return record
    result = json.loads(result_path.read_text(encoding="utf-8"))
    info = result.get("exception_info") or {}
    if info:
        record["exception_type"] = info.get("exception_type")
        record["problems"].append(f"harbor exception {info.get('exception_type')}")
    rewards = (result.get("verifier_result") or {}).get("rewards") or {}
    record["reward"] = rewards.get("reward")
    if record["reward"] is None:
        record["problems"].append("verifier reward missing")
    checksum = result.get("task_checksum")
    record["task_checksum"] = checksum
    if checksum != exp.checksum(task_id):
        record["problems"].append("task checksum differs from the experiment")
    started, finished = result.get("started_at"), result.get("finished_at")
    if started and finished:
        try:
            delta = datetime.fromisoformat(finished) - datetime.fromisoformat(started)
            record["elapsed_seconds"] = round(delta.total_seconds(), 2)
        except ValueError:
            pass

    agent_dir = trial_dir / "agent"
    binary = agent_dir / "zygos"
    if binary.is_file():
        actual = sha256_file(binary)
        record["binary_sha256"] = actual
        if actual != arm.binary_sha256:
            record["problems"].append("uploaded binary sha256 differs from the arm")
    else:
        record["problems"].append("uploaded binary missing")
    catalog = agent_dir / "providers.toml"
    if catalog.is_file() and "key =" in catalog.read_text(encoding="utf-8"):
        record["problems"].append("container catalog carries an inline key")

    if exp.mode == "mission":
        return inspect_mission(exp, jobs_dir, arm, record, agent_dir)

    trial_path = agent_dir / "trial.json"
    if not trial_path.is_file():
        record["problems"].append("trial.json missing")
        return record
    trial = json.loads(trial_path.read_text(encoding="utf-8"))
    record["trial"] = trial
    expected = {
        "task_id": task_id,
        "dataset": DATASET,
        "model_id": exp.model_id,
        "variable": f"trim-{arm.trim}",
        "step_cap": exp.step_cap,
        "git_sha": arm.git_sha,
    }
    for key, value in expected.items():
        if trial.get(key) != value:
            record["problems"].append(f"trial {key} is {trial.get(key)!r}, expected {value!r}")
    if trial.get("config_sha256") != arm.config_sha256:
        record["problems"].append(f"trial config_sha256 is {trial.get('config_sha256')!r}, expected {arm.config_sha256!r}")
    cached = int(trial.get("cache_read_tokens", 0) or 0)
    if not 0 <= cached <= int(trial.get("input_tokens", 0)):
        record["problems"].append("cache_read_tokens exceeds input_tokens")
    record["cost_usd"] = str(exp.cost_usd(trial))

    events_path = agent_dir / "events.jsonl"
    if events_path.is_file():
        events = read_events(events_path)
        usage = [e for e in events if e.get("event") == "usage"]
        for key in ("input_tokens", "output_tokens"):
            if sum(int(e.get(key, 0)) for e in usage) != int(trial.get(key, 0)):
                record["problems"].append(f"events {key} do not sum to the trial")
        if any("cache" in k for e in usage for k in e):
            record["problems"].append("usage trace carries a cache field")
        tool_calls = [e for e in events if e.get("event") == "tool_call"]
        results = [e for e in events if e.get("event") == "tool_result"]
        end = next((e for e in reversed(events) if e.get("event") == "turn_end"), {})
        record.update(
            provider_steps=sum(e.get("event") == "step" for e in events),
            tool_calls=len(tool_calls),
            empty_tool_inputs=sum(e.get("input") == "{}" for e in tool_calls),
            handler_failures=sum(e.get("output") == "handler_failed" for e in results),
            successful_tools=sum(not e.get("is_error") for e in results),
            turn_stop=end.get("stop"),
            turn_error=end.get("err", end.get("error")),
        )
        if tool_calls and record["empty_tool_inputs"] == len(tool_calls):
            record["problems"].append("every tool call had empty input")
        if record["turn_stop"] is None:
            record["problems"].append("turn never ended (no turn_end event)")
        elif record["turn_stop"] == "failed" and record["turn_error"] != "unknown_provider_stop":
            record["problems"].append(f"turn failed: {record['turn_error']}")
            record["transport_failure"] = True
    else:
        record["problems"].append("events.jsonl missing")

    score_file = jobs_dir / f"{name}.score.txt"
    exit_score = jobs_dir / f"{name}.score-exit.txt"
    if score_file.is_file() and exit_score.is_file():
        record["scorer_result"] = score_file.read_text(encoding="utf-8").strip()
        try:
            record["scorer_exit"] = int(exit_score.read_text().strip())
        except ValueError:
            record["problems"].append("scorer exit unreadable")
    return record


def terminal_reply(stdout: str) -> dict | None:
    """The mission CLI's terminal reply: the last `{"state":...}` object on
    stdout. It can share a line with the console gate prompt, which has no
    trailing newline, so the object is searched for inside each line."""
    import json

    for line in reversed(stdout.splitlines()):
        start = line.rfind('{"state"')
        if start < 0:
            continue
        try:
            value = json.loads(line[start:])
        except ValueError:
            continue
        if isinstance(value, dict):
            return value
    return None


def inspect_mission(exp: Experiment, jobs_dir: Path, arm: Arm, record: dict, agent_dir: Path) -> dict:
    """Mission-mode evidence: the uploaded route table, the terminal reply,
    and the planning trace. Usage comes from the trace's usage lines, which
    carry no cache counts, so every input token is priced at the ordinary
    rate and the record says so.
    """
    run_path = agent_dir / "mission-run.json"
    if not run_path.is_file():
        record["problems"].append("mission-run.json missing")
        return record
    run = json.loads(run_path.read_text(encoding="utf-8"))
    record["exit_code"] = run.get("exit_code")
    uploaded = agent_dir / "zygos.zon"
    if uploaded.is_file():
        actual = sha256_file(uploaded)
        if actual != arm.config_sha256 or run.get("config_sha256") != arm.config_sha256:
            record["problems"].append(f"uploaded route table sha256 {actual} differs from the arm")
    else:
        record["problems"].append("uploaded route table missing")
    uploaded_pipeline = run.get("pipeline")
    if uploaded_pipeline is not None:
        try:
            uploaded_matches = pipeline_identity(uploaded_pipeline) == pipeline_identity(arm.pipeline)
        except (KeyError, TypeError):
            uploaded_matches = False
        if not uploaded_matches:
            record["problems"].append("uploaded pipeline in mission-run.json differs from the arm")
    if run.get("role_max_steps") != exp.step_cap:
        record["problems"].append(f"role_max_steps is {run.get('role_max_steps')!r}, expected {exp.step_cap}")

    # The raw stdout is the evidence; mission.json is the adapter's reading
    # of it and only stands in when stdout is absent.
    reply = None
    stdout_path = agent_dir / "stdout.txt"
    if stdout_path.is_file():
        reply = terminal_reply(stdout_path.read_text(encoding="utf-8", errors="replace"))
    reply_path = agent_dir / "mission.json"
    if reply is None and reply_path.is_file():
        reply = json.loads(reply_path.read_text(encoding="utf-8"))
    if reply is None and not reply_path.is_file():
        record["problems"].append("mission.json missing")
    if reply is None:
        reply = {"state": "lost", "stop": "no_terminal_reply"}
    record["mission_state"] = reply.get("state")
    if reply.get("state") == "lost":
        record["turn_stop"] = "no_terminal_reply"
    elif reply.get("paused"):
        record["turn_stop"] = "parked"
    else:
        record["turn_stop"] = reply.get("stop")
    record["role_turns"] = reply.get("role_turns")
    record["tasks_done"] = reply.get("tasks_done")
    record["mission_step"] = reply.get("step")
    record["mission_step_index"] = reply.get("step_index")

    events_path = agent_dir / "planning" / "events.jsonl"
    if not events_path.is_file():
        record["problems"].append("planning/events.jsonl missing")
        return record
    events = read_events(events_path)
    # The mission pins its pipeline and says so in its first trace event, so
    # the run that was measured is the one the arm names. Presence and
    # content are checked, not position.
    pipeline = next((e for e in events if e.get("event") == "pipeline"), None)
    if pipeline is None:
        record["problems"].append("pipeline event missing")
    elif pipeline.get("steps") != pipeline_identity(arm.pipeline):
        record["problems"].append(
            f"pipeline event differs from the arm: trace {json.dumps(pipeline.get('steps'), separators=(',', ':'))}"
            f", expected {json.dumps(pipeline_identity(arm.pipeline), separators=(',', ':'))}"
        )
    usage = [e for e in events if e.get("event") == "usage"]
    trial = {
        "input_tokens": sum(int(e.get("input_tokens", 0)) for e in usage),
        "output_tokens": sum(int(e.get("output_tokens", 0)) for e in usage),
        "cache_read_tokens": 0,
        "trim": None,
    }
    record["trial"] = trial
    record["cache_unreported"] = True
    record["cost_usd"] = str(exp.cost_usd(trial))
    tool_calls = [e for e in events if e.get("event") == "tool_call"]
    results = [e for e in events if e.get("event") == "tool_result"]
    record.update(
        provider_steps=sum(e.get("event") == "step" for e in events),
        tool_calls=len(tool_calls),
        empty_tool_inputs=sum(e.get("input") == "{}" for e in tool_calls),
        handler_failures=sum(e.get("output") == "handler_failed" for e in results),
        successful_tools=sum(not e.get("is_error") for e in results),
        role_starts=sum(e.get("event") == "role_start" for e in events),
        role_failures=sum(e.get("event") == "role_end" and e.get("outcome") == "failed" for e in events),
    )
    if record.get("role_turns") is None:
        record["role_turns"] = record["role_starts"]
    if tool_calls and record["empty_tool_inputs"] == len(tool_calls):
        record["problems"].append("every tool call had empty input")
    if not usage:
        record["problems"].append("no usage recorded; the mission never reached a provider")
    return record


def job_failed(record: dict) -> bool:
    """Stop condition from the benchmark policy: a broken path, not a zero reward."""
    return bool(record["problems"])


# ---------------------------------------------------------------------------
# run: launch jobs, score, record
# ---------------------------------------------------------------------------


class Scorer:
    """`zygos task score` over a trial: Docker with the Linux artifact, or a native binary."""

    def __init__(self, kind: str, native_bin: Path | None, prices: Path):
        if kind not in ("docker", "native"):
            raise CampaignError("scorer must be docker or native")
        if kind == "native" and (native_bin is None or not native_bin.is_file()):
            raise CampaignError("--native-bin must name a zygos binary for the native scorer")
        self.kind = kind
        self.native_bin = native_bin
        self.prices = prices

    def identity(self) -> dict:
        if self.kind == "native":
            return {"kind": "native", "binary_sha256": sha256_file(self.native_bin)}
        return {"kind": "docker", "image": SCORER_IMAGE}

    def score(self, linux_bin: Path, trial: Path) -> tuple[int, str]:
        if self.kind == "native":
            argv = [str(self.native_bin), "task", "score", "--trial", str(trial), "--prices", str(self.prices)]
        else:
            argv = [
                "docker", "run", "--rm", "--pull=never", "--platform", "linux/amd64", "--network", "none", "--read-only",
                "--mount", f"type=bind,src={linux_bin},dst=/zygos,readonly",
                "--mount", f"type=bind,src={trial},dst=/trial.json,readonly",
                "--mount", f"type=bind,src={self.prices},dst=/prices.txt,readonly",
                SCORER_IMAGE, "/zygos", "task", "score", "--trial", "/trial.json", "--prices", "/prices.txt",
            ]
        result = subprocess.run(argv, capture_output=True, text=True)
        return result.returncode, (result.stdout + result.stderr).strip()


class Runner:
    def __init__(self, exp: Experiment, jobs_dir: Path, tasks_dir: Path, harbor: str, scorer: Scorer, env: dict):
        self.exp = exp
        self.jobs_dir = jobs_dir
        self.tasks_dir = tasks_dir
        self.harbor = harbor
        self.scorer = scorer
        self.env = env
        self.lock = threading.Lock()
        self.campaign_path = jobs_dir / "campaign.json"
        self.campaign = self.load_or_start()

    def load_or_start(self) -> dict:
        if self.campaign_path.is_file():
            campaign = json.loads(self.campaign_path.read_text(encoding="utf-8"))
            if campaign.get("experiment", {}).get("arms") != self.exp.summary()["arms"]:
                raise CampaignError("campaign.json in the jobs directory belongs to different arms; use a fresh --jobs-dir")
            return campaign
        return {
            "experiment": self.exp.summary(),
            "experiment_file": str(self.exp.path),
            "experiment_sha256": sha256_file(self.exp.path),
            "jobs_dir": str(self.jobs_dir),
            "harbor": self.harbor,
            "harbor_version": harbor_version(self.harbor),
            "scorer": self.scorer.identity(),
            "started_utc": utc_now(),
            "status": "running",
            "trials": [],
        }

    def save(self, status: str) -> None:
        with self.lock:
            self.campaign["status"] = status
            self.campaign["updated_utc"] = utc_now()
            self.campaign["task_runs_recorded"] = len(self.campaign["trials"])
            write_json(self.campaign_path, self.campaign)

    def recorded(self, name: str) -> bool:
        return any(t["job"] == name for t in self.campaign["trials"])

    def launch(self, arm: Arm, repeat: int, task_id: str) -> dict:
        name = self.exp.job_name(arm, repeat, task_id)
        job_dir = self.jobs_dir / name
        if not job_dir.exists():
            env = dict(self.env)
            env.update(
                ZYGOS_LINUX_BIN=str(arm.binary),
                ZYGOS_TASK_ID=task_id,
                ZYGOS_TRIM=arm.trim,
                ZYGOS_STEP_CAP=str(self.exp.step_cap),
                ZYGOS_WORKSPACE=self.exp.workspace,
                ZYGOS_MODE=self.exp.mode,
            )
            if arm.config_path is not None:
                env["ZYGOS_CONFIG"] = str(arm.config_path)
            else:
                env.pop("ZYGOS_CONFIG", None)
            argv = [
                self.harbor, "run",
                "-p", str(self.tasks_dir / task_id),
                "-a", "eval.harbor.zygos_agent:ZygosAgent",
                "-m", self.exp.model_id,
                "-k", "1",
                "--n-concurrent", "1",
                "--n-concurrent-agents", "1",
                "--max-retries", "0",
                "--yes",
                "--job-name", name,
                "-o", str(self.jobs_dir),
            ]
            print(f"RUN {name}", flush=True)
            with (self.jobs_dir / f"{name}.harbor.log").open("w") as log:
                proc = subprocess.run(argv, cwd=REPO, env=env, stdout=log, stderr=subprocess.STDOUT)
            (self.jobs_dir / f"{name}.harbor-exit.txt").write_text(f"{proc.returncode}\n")
        record = inspect_job(self.exp, self.jobs_dir, arm, repeat, task_id)
        trial_path = record.get("trial_path")
        if self.exp.mode == "task" and trial_path and record.get("trial") is not None and record["scorer_exit"] is None:
            code, text = self.scorer.score(arm.binary, Path(trial_path) / "agent" / "trial.json")
            (self.jobs_dir / f"{name}.score.txt").write_text(text + "\n", encoding="utf-8")
            (self.jobs_dir / f"{name}.score-exit.txt").write_text(f"{code}\n")
            record["scorer_exit"], record["scorer_result"] = code, text
        return record

    def record(self, record: dict) -> None:
        with self.lock:
            self.campaign["trials"] = [t for t in self.campaign["trials"] if t["job"] != record["job"]] + [record]
        self.save("running")
        print(json.dumps({k: record.get(k) for k in ("job", "reward", "scorer_exit", "turn_stop", "cost_usd", "problems")}), flush=True)

    def run(self, only_arm: str | None, concurrency: int) -> str:
        pending = [(arm, repeat, task) for arm, repeat, task in self.exp.jobs()
                   if (only_arm is None or arm.name == only_arm)
                   and not self.recorded(self.exp.job_name(arm, repeat, task))]
        self.save("running")
        stop_reason = None
        errors: list[str] = []
        queue = iter(pending)
        with ThreadPoolExecutor(max_workers=concurrency) as pool:
            active = {}
            for _ in range(concurrency):
                item = next(queue, None)
                if item:
                    active[pool.submit(self.launch, *item)] = item
            while active:
                done, _ = wait(active, return_when=FIRST_COMPLETED)
                for future in done:
                    active.pop(future)
                    try:
                        record = future.result()
                        self.record(record)
                        if job_failed(record):
                            stop_reason = stop_reason or f"{record['job']}: {'; '.join(record['problems'])}"
                    except Exception as exc:  # the runner itself broke; keep the campaign file honest
                        errors.append(f"{type(exc).__name__}: {exc}")
                        stop_reason = stop_reason or errors[-1]
                    if stop_reason is None:
                        item = next(queue, None)
                        if item:
                            active[pool.submit(self.launch, *item)] = item
        if errors:
            self.campaign["runner_errors"] = errors
        if stop_reason:
            status = f"stopped: {stop_reason}"
        else:
            total = len(self.exp.jobs()) if only_arm is None else len(self.exp.jobs()) // 2
            status = "finished" if len(self.campaign["trials"]) >= total else "partial"
        self.save(status)
        return status


def harbor_version(harbor: str) -> str | None:
    try:
        result = subprocess.run([harbor, "--version"], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return (result.stdout or result.stderr).strip().splitlines()[0] if (result.stdout or result.stderr).strip() else None


def preflight(exp: Experiment, args, env: dict) -> dict:
    """Refuse before any paid launch. Returns what was checked, for the campaign file."""
    checks: dict = {}
    inventory = json.loads((REPO / "eval" / "image-platforms.json").read_text(encoding="utf-8"))
    if inventory.get("status") != "ready":
        raise CampaignError("eval/image-platforms.json is not ready")
    checks["image_platforms"] = inventory.get("chosen_triple")
    tasks_dir = Path(args.tasks_dir).resolve()
    for task_id in exp.task_ids():
        if not (tasks_dir / task_id / "task.toml").is_file():
            raise CampaignError(f"task {task_id} has no task.toml under {tasks_dir}")
    checks["tasks_dir"] = str(tasks_dir)
    if exp.dataset_source_sha:
        head = subprocess.run(["git", "-C", str(tasks_dir), "rev-parse", "HEAD"], capture_output=True, text=True)
        actual = head.stdout.strip() if head.returncode == 0 else None
        if actual != exp.dataset_source_sha:
            raise CampaignError(f"tasks dir HEAD is {actual}, experiment pins {exp.dataset_source_sha}")
        checks["dataset_source_sha"] = actual
    exp.locate_builds(Path(args.builds_dir).resolve())
    # `key_from_env` is an override, not a fallback: the experiment pins the
    # endpoint, and a host may hold a different vendor's key under
    # `key_env` (a direct DeepSeek key does not authenticate at OpenRouter).
    if exp.key_from_env:
        if not env.get(exp.key_from_env):
            raise CampaignError(f"{exp.key_from_env} is not set")
        env[exp.key_env] = env[exp.key_from_env]
        checks["credential"] = f"{exp.key_env} bound from {exp.key_from_env}"
    elif env.get(exp.key_env):
        checks["credential"] = f"{exp.key_env} from environment"
    else:
        raise CampaignError(f"{exp.key_env} is not set")
    if exp.mode == "mission":
        # Every slug a route table names must have its key, or a step would
        # boot keyless and fail mid-mission after money was spent.
        needed = []
        for slug in sorted(exp.config_slugs()):
            key_name = MISSION_SLUG_KEYS.get(slug)
            if key_name is None:
                raise CampaignError(f"route table names unknown catalog slug {slug}")
            if not env.get(key_name):
                raise CampaignError(f"route table names {slug} but {key_name} is not set")
            needed.append(f"{slug}:{key_name}")
        checks["mission_keys"] = needed
    bundle = env.get("ZYGOS_CA_BUNDLE")
    if exp.ca_bundle_sha256:
        if not bundle or not Path(bundle).is_file():
            raise CampaignError("experiment pins ca_bundle_sha256 but ZYGOS_CA_BUNDLE is not a file")
        actual = sha256_file(Path(bundle))
        if actual != exp.ca_bundle_sha256:
            raise CampaignError(f"ZYGOS_CA_BUNDLE sha256 {actual} does not match the experiment")
        checks["ca_bundle_sha256"] = actual
    harbor = args.harbor or shutil.which("harbor")
    if not harbor:
        raise CampaignError("harbor is not on PATH (pass --harbor)")
    checks["harbor"] = harbor
    if not args.skip_docker_check:
        docker = subprocess.run(["docker", "info", "--format", "{{.ServerVersion}}"], capture_output=True, text=True)
        if docker.returncode != 0:
            raise CampaignError("docker daemon is not reachable")
        checks["docker_server"] = docker.stdout.strip()
    return checks


def cmd_run(args) -> int:
    exp = Experiment(Path(args.experiment))
    jobs_dir = Path(args.jobs_dir).resolve()
    jobs_dir.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    checks = preflight(exp, args, env)
    env.update(
        DOCKER_DEFAULT_PLATFORM="linux/amd64",
        PYTHONDONTWRITEBYTECODE="1",
        PYTHONPATH=str(REPO),
    )
    prices = jobs_dir / "prices.txt"
    prices.write_text(f"{exp.model_id} {exp.scorer_cents}\n", encoding="utf-8")
    scorer = Scorer(args.scorer, Path(args.native_bin).resolve() if args.native_bin else None, prices)
    if args.dry_run:
        plan = [exp.job_name(arm, repeat, task) for arm, repeat, task in exp.jobs()]
        print(json.dumps({"experiment": exp.summary(), "checks": checks, "jobs": plan, "scorer": scorer.identity()}, indent=2))
        return 0
    runner = Runner(exp, jobs_dir, Path(args.tasks_dir).resolve(), checks["harbor"], scorer, env)
    runner.campaign["preflight"] = checks
    status = runner.run(args.arm, min(args.concurrency, exp.host_concurrency))
    print(json.dumps({"status": status, "campaign": str(runner.campaign_path)}), flush=True)
    return 0 if status == "finished" else 4


# ---------------------------------------------------------------------------
# report: aggregate, match, decide
# ---------------------------------------------------------------------------


def mean(values: list) -> float | None:
    values = [v for v in values if v is not None]
    return round(sum(values) / len(values), 2) if values else None


def arm_summary(exp: Experiment, arm: Arm, records: list[dict]) -> dict:
    expected = exp.repeats * len(exp.tasks)
    with_trial = [r for r in records if r.get("trial")]
    passes = sum(1 for r in records if r.get("reward") == 1)
    cost = sum((Decimal(r["cost_usd"]) for r in with_trial), Decimal(0))
    accepted = [r for r in records if r.get("scorer_exit") == 0]
    reductions = []
    for r in accepted:
        text = r.get("scorer_result") or ""
        for part in text.split():
            if part.startswith("reduction="):
                reductions.append(int(part.split("=", 1)[1]))
    scorer_refusals = Counter(r.get("scorer_result") for r in records if r.get("scorer_exit") not in (None, 0))
    summary = {
        "arm": arm.identity(),
        "expected_task_runs": expected,
        "recorded_task_runs": len(records),
        "trials_written": len(with_trial),
        "verifier_passes": passes,
        "pass_rate": round(passes / expected, 4) if expected else None,
        "input_tokens": sum(int(r["trial"].get("input_tokens", 0)) for r in with_trial),
        "output_tokens": sum(int(r["trial"].get("output_tokens", 0)) for r in with_trial),
        "cache_read_tokens": sum(int(r["trial"].get("cache_read_tokens", 0) or 0) for r in with_trial),
        "cost_usd": str(cost),
        "cost_per_resolved_usd": str((cost / passes).quantize(Decimal("0.000001"))) if passes else None,
        "mean_provider_steps": mean([r.get("provider_steps") for r in with_trial]),
        "mean_elapsed_seconds": mean([r.get("elapsed_seconds") for r in records]),
        "turn_stops": dict(Counter(r.get("turn_stop") for r in with_trial)),
        "scorer_accepted": len(accepted),
        "scorer_refused": dict(scorer_refusals),
        "unscored": sum(1 for r in with_trial if r.get("scorer_exit") is None),
        "mean_accepted_reduction": mean(reductions),
        "trim_calls": sum(int((r["trial"].get("trim") or {}).get("calls", 0)) for r in with_trial),
        "mean_role_turns": mean([r.get("role_turns") for r in with_trial]) if exp.mode == "mission" else None,
        "mission_states": dict(Counter(r.get("mission_state") for r in records if r.get("mission_state"))) if exp.mode == "mission" else None,
        "role_failures": sum(int(r.get("role_failures", 0)) for r in with_trial) if exp.mode == "mission" else None,
        "cache_unreported": sum(1 for r in with_trial if r.get("cache_unreported")),
        "transport_failures": sum(1 for r in records if r.get("transport_failure")),
        "harbor_exceptions": sum(1 for r in records if r.get("exception_type")),
        "problems": sum(1 for r in records if r["problems"]),
    }
    return summary


def matched_pairs(exp: Experiment, by_job: dict) -> list[dict]:
    pairs = []
    for repeat in range(1, exp.repeats + 1):
        for task_id in exp.task_ids():
            pair = {"task_id": task_id, "repeat": repeat}
            for arm in exp.arms:
                r = by_job.get(exp.job_name(arm, repeat, task_id)) or {"problems": ["not recorded"]}
                pair[arm.name] = {
                    "reward": r.get("reward"),
                    "cost_usd": r.get("cost_usd"),
                    "steps": r.get("provider_steps"),
                    "stop": r.get("turn_stop"),
                    "scorer_exit": r.get("scorer_exit"),
                    "problems": r.get("problems", []),
                }
            a, b = pair[exp.baseline.name], pair[exp.candidate.name]
            pair["pass_delta"] = (None if a["reward"] is None or b["reward"] is None
                                  else int(b["reward"] == 1) - int(a["reward"] == 1))
            pair["cost_delta_usd"] = (None if a["cost_usd"] is None or b["cost_usd"] is None
                                      else str(Decimal(b["cost_usd"]) - Decimal(a["cost_usd"])))
            pairs.append(pair)
    return pairs


def within_arm_flips(exp: Experiment, records: list[dict], arm: Arm) -> int:
    """Tasks whose verifier outcome differed between repeats of the same arm.

    That is the repeat-to-repeat noise floor: a pass delta no larger than
    it cannot be attributed to the variable.
    """
    flips = 0
    for task_id in exp.task_ids():
        rewards = {r.get("reward") for r in records if r["arm"] == arm.name and r["task_id"] == task_id}
        if len(rewards - {None}) > 1:
            flips += 1
    return flips


def verdict(exp: Experiment, base: dict, cand: dict, noise: int = 0) -> tuple[str, list[str]]:
    """Observed difference or an explicit reason it cannot be read."""
    reasons = []
    for label, s in (("baseline", base), ("candidate", cand)):
        if s["recorded_task_runs"] < s["expected_task_runs"]:
            reasons.append(f"{label}: {s['recorded_task_runs']}/{s['expected_task_runs']} task-runs recorded")
        if s["problems"]:
            reasons.append(f"{label}: {s['problems']} task-run(s) with identity, transport, or evidence problems")
    if reasons:
        return "inconclusive", reasons
    caveats = []
    dp = cand["verifier_passes"] - base["verifier_passes"]
    dc = Decimal(cand["cost_usd"]) - Decimal(base["cost_usd"])
    base_cost = Decimal(base["cost_usd"])
    rel = (dc / base_cost) if base_cost else None
    if abs(dp) > noise:
        outcome = "candidate_better" if dp > 0 else "candidate_worse"
    elif rel is not None and abs(rel) > Decimal("0.05"):
        outcome = "candidate_better" if dc < 0 else "candidate_worse"
    else:
        outcome = "no_observed_difference"
    caveats.append(f"pass delta {dp:+d} on {base['expected_task_runs']} matched task-runs; cost delta {dc:+f} USD"
                   + (f" ({rel * 100:+.1f}%)" if rel is not None else ""))
    if dp != 0 and abs(dp) <= noise:
        caveats.append(f"pass delta is within repeat noise: {noise} task(s) flipped outcome between repeats of one arm; "
                       f"the verdict rests on cost")
    if base["expected_task_runs"] < 24:
        caveats.append("fewer than 24 matched task-runs: treat the direction as a hint, not a measurement")
    if exp.variable == "trim":
        caveats.append(f"trim metric: candidate scorer accepted {cand['scorer_accepted']}, refused {sum(cand['scorer_refused'].values())}; "
                       f"baseline accepted {base['scorer_accepted']}, refused {sum(base['scorer_refused'].values())}")
    if exp.mode == "mission":
        caveats.append("mission traces carry no cache counts: every input token is priced at the ordinary rate, "
                       "so costs are an upper bound and comparable only between these arms")
    return outcome, caveats


def render_markdown(exp: Experiment, report: dict) -> str:
    base, cand = report["arms"][exp.baseline.name], report["arms"][exp.candidate.name]
    lines = [
        f"# Benchmark report: {exp.name}",
        "",
        f"Generated {report['generated_utc']}. Mode: **{exp.mode}**. Variable: **{exp.variable}**. "
        f"Verdict: **{report['verdict']}**.",
        "",
    ]
    for reason in report["verdict_reasons"]:
        lines.append(f"- {reason}")
    lines += ["", "## Arms", "", "| | " + exp.baseline.name + " | " + exp.candidate.name + " |", "|---|---|---|"]
    rows = [
        ("git sha", "git_sha"), ("binary sha256", "binary_sha256"), ("config sha256", "config_sha256"), ("trim", "trim"),
    ]
    for label, key in rows:
        lines.append(f"| {label} | `{base['arm'][key] or 'none'}` | `{cand['arm'][key] or 'none'}` |")
    if exp.mode == "mission":
        def pipeline_cell(arm_report: dict) -> str:
            return " > ".join(
                s["id"] + (f":{s['definition_sha256'][:8]}" if s["definition_sha256"] else "")
                for s in arm_report["arm"]["pipeline"]
            )
        lines.append(f"| pipeline | `{pipeline_cell(base)}` | `{pipeline_cell(cand)}` |")
    lines += ["", "## Results", "", f"| Metric | {exp.baseline.name} | {exp.candidate.name} |", "|---|---:|---:|"]
    metrics = [
        ("Task-runs recorded / expected", lambda s: f"{s['recorded_task_runs']} / {s['expected_task_runs']}"),
        ("Verifier passes", lambda s: s["verifier_passes"]),
        ("Pass rate", lambda s: s["pass_rate"]),
        ("Input tokens", lambda s: s["input_tokens"]),
        ("Cache-read tokens (in input)", lambda s: s["cache_read_tokens"]),
        ("Output tokens", lambda s: s["output_tokens"]),
        ("Snapshot cost USD", lambda s: s["cost_usd"]),
        ("Cost per resolved task USD", lambda s: s["cost_per_resolved_usd"]),
        ("Mean provider steps", lambda s: s["mean_provider_steps"]),
        ("Mean role turns", lambda s: s["mean_role_turns"]),
        ("Mission states", lambda s: json.dumps(s["mission_states"], sort_keys=True) if s["mission_states"] is not None else None),
        ("Role failures", lambda s: s["role_failures"]),
        ("Mean elapsed seconds", lambda s: s["mean_elapsed_seconds"]),
        ("Turn stops", lambda s: json.dumps(s["turn_stops"], sort_keys=True)),
        ("Trim compress calls", lambda s: s["trim_calls"]),
        ("Scorer accepted", lambda s: s["scorer_accepted"]),
        ("Scorer refused", lambda s: json.dumps(s["scorer_refused"], sort_keys=True)),
        ("Unscored trials", lambda s: s["unscored"]),
        ("Mean accepted reduction %", lambda s: s["mean_accepted_reduction"]),
        ("Transport failures", lambda s: s["transport_failures"]),
        ("Harbor exceptions", lambda s: s["harbor_exceptions"]),
        ("Task-runs with problems", lambda s: s["problems"]),
    ]
    for label, get in metrics:
        lines.append(f"| {label} | {get(base)} | {get(cand)} |")
    lines += ["", "## Matched task-runs", "",
              f"| Task | Repeat | {exp.baseline.name} reward | {exp.candidate.name} reward | Pass delta | Cost delta USD | Problems |",
              "|---|---:|---:|---:|---:|---:|---|"]
    for pair in report["matched"]:
        a, b = pair[exp.baseline.name], pair[exp.candidate.name]
        problems = "; ".join(a["problems"] + b["problems"]) or ""
        lines.append(f"| {pair['task_id']} | {pair['repeat']} | {a['reward']} | {b['reward']} | {pair['pass_delta']} | {pair['cost_delta_usd']} | {problems} |")
    lines += ["", "## Provenance", "",
              f"- Model `{exp.model_id}`, dataset `{DATASET}` at `{exp.dataset_source_sha}`, step cap {exp.step_cap}, repeats {exp.repeats}.",
              f"- Prices per million tokens: input {exp.rate_input}, cached input {exp.rate_cached}, output {exp.rate_output}"
              f" (source {exp.price_source}, retrieved {exp.price_retrieved}). Snapshot estimates, not an invoice.",
              f"- Jobs directory: `{report['jobs_dir']}` (raw traces stay there; this report carries numbers and identities only).",
              "- Zero rewards, step or output limits, and scorer refusals are recorded outcomes, not reruns.",
              ""]
    return "\n".join(lines)


def cmd_report(args) -> int:
    exp = Experiment(Path(args.experiment))
    jobs_dir = Path(args.jobs_dir).resolve()
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    records = [inspect_job(exp, jobs_dir, arm, repeat, task) for arm, repeat, task in exp.jobs()]
    by_job = {r["job"]: r for r in records}
    arms = {arm.name: arm_summary(exp, arm, [r for r in records if r["arm"] == arm.name]) for arm in exp.arms}
    noise = max(within_arm_flips(exp, records, arm) for arm in exp.arms)
    outcome, reasons = verdict(exp, arms[exp.baseline.name], arms[exp.candidate.name], noise)
    campaign_path = jobs_dir / "campaign.json"
    campaign = json.loads(campaign_path.read_text(encoding="utf-8")) if campaign_path.is_file() else {}
    report = {
        "experiment": exp.summary(),
        "experiment_sha256": sha256_file(exp.path),
        "generated_utc": utc_now(),
        "jobs_dir": str(jobs_dir),
        "campaign_status": campaign.get("status"),
        "harbor_version": campaign.get("harbor_version"),
        "scorer": campaign.get("scorer"),
        "verdict": outcome,
        "verdict_reasons": reasons,
        "repeat_noise_tasks": noise,
        "arms": arms,
        "matched": matched_pairs(exp, by_job),
        "task_runs": [
            {k: v for k, v in r.items() if k != "trial"} | {"trial": r.get("trial")}
            for r in records
        ],
    }
    write_json(out / "report.json", report)
    (out / "report.md").write_text(render_markdown(exp, report), encoding="utf-8")
    shutil.copyfile(exp.path, out / "experiment.json")
    for arm in exp.arms:
        if arm.config_path is not None:
            shutil.copyfile(arm.config_path, out / f"{arm.name}.zon")
    print(json.dumps({"verdict": outcome, "reasons": reasons, "out": str(out)}, indent=2))
    return 0


def cmd_build(args) -> int:
    meta = build_arm(args.git_ref, Path(args.builds_dir).resolve(), args.zig, REPO)
    print(json.dumps(meta, indent=2))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="campaign.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    build = sub.add_parser("build", help="build a Linux arm from a clean worktree at a git ref")
    build.add_argument("--git-ref", default="HEAD")
    build.add_argument("--builds-dir", default=str(DEFAULT_BUILDS_DIR))
    build.add_argument("--zig", default=os.environ.get("ZYGOS_ZIG", "zig"), help="zig 0.16 binary (or ZYGOS_ZIG)")
    build.set_defaults(func=cmd_build)

    run = sub.add_parser("run", help="run every matched task-run of an experiment")
    run.add_argument("--experiment", required=True)
    run.add_argument("--jobs-dir", required=True)
    run.add_argument("--tasks-dir", required=True, help="checkout of the dataset tasks (one directory per task)")
    run.add_argument("--builds-dir", default=str(DEFAULT_BUILDS_DIR))
    run.add_argument("--arm", default=None, help="run only this arm")
    run.add_argument("--concurrency", type=int, default=2)
    run.add_argument("--harbor", default=None)
    run.add_argument("--scorer", choices=("docker", "native"), default="docker")
    run.add_argument("--native-bin", default=None)
    run.add_argument("--skip-docker-check", action="store_true")
    run.add_argument("--dry-run", action="store_true")
    run.set_defaults(func=cmd_run)

    report = sub.add_parser("report", help="write report.json and report.md from the raw job directories")
    report.add_argument("--experiment", required=True)
    report.add_argument("--jobs-dir", required=True)
    report.add_argument("--out", required=True)
    report.set_defaults(func=cmd_report)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except CampaignError as exc:
        print(f"campaign: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
