"""Harbor agent sketch for the Zygos task command.

Harbor is not imported. A later `harbor run -a eval.harbor.zygos_agent:ZygosAgent`
can load this once Harbor is installed and a spend approval exists. The dry
run prints the same command `eval/run.sh` prints. It does not start a trial.
"""

ADAPTER_VERSION = "0.1.0"
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
