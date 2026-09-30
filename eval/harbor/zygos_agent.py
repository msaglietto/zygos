"""Harbor agent sketch for the Zygos task command.

Harbor is not imported. A later `harbor run -a eval.harbor.zygos_agent:ZygosAgent`
can load this once Harbor is installed and a spend approval exists. The dry
run prints the same command `eval/run.sh` prints. It does not start a trial.

The adapter version is the `adapter_version` const in src/worker/trial.zig.
"""

from pathlib import Path


def _adapter_version() -> str:
    root = Path(__file__).resolve().parents[2]
    text = (root / "src" / "worker" / "trial.zig").read_text(encoding="utf-8")
    marker = 'pub const adapter_version = "'
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith(marker) and stripped.endswith('";'):
            return stripped[len(marker) : -2]
    return "unknown"


ADAPTER_VERSION = _adapter_version()
DATASET = "terminal-bench/terminal-bench-2-1"
TASK_COMMAND = (
    "zygos task run --offline --workspace <workspace> "
    "--out trial.json --events events.jsonl"
)


class ZygosAgent:
    def dry_run(self) -> str:
        return (
            f"dataset: {DATASET}\n"
            f"command: {TASK_COMMAND}\n"
            f"adapter_version: {ADAPTER_VERSION}\n"
        )
