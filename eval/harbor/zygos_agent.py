"""Harbor agent for one Zygos task command.

The adapter version is the `adapter_version` const in src/worker/trial.zig.
Harbor loads this class as `eval.harbor.zygos_agent:ZygosAgent`. The live
command is the phase-8 pilot: model glm-5.3-flash, the Linux binary in
ZYGOS_LINUX_BIN, and Z_AI_API_KEY passed only in the container exec env.
"""

from __future__ import annotations

import os
import shlex
import tempfile
from pathlib import Path

from harbor.agents.base import BaseAgent
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext
from harbor.models.trial.paths import EnvironmentPaths

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
APPROVED_MODEL = "glm-5.3-flash"
TASK_COMMAND = (
    "zygos task run --offline --workspace <workspace> "
    "--out trial.json --events events.jsonl"
)
# The operator catalog row, without a key. The container reads this file.
PILOT_CATALOG = """[[providers]]
name = "GLM Flash"
type = "anthropic_compatible"
model = "glm-5.3-flash"
endpoint = "https://api.z.ai/api/anthropic"
key_env = "Z_AI_API_KEY"
"""


class ZygosAgent(BaseAgent):
    def __init__(
        self,
        logs_dir: Path,
        model_name: str | None = None,
        agent_timeout_sec: float | None = None,
        **kwargs,
    ):
        super().__init__(logs_dir=logs_dir, model_name=model_name, **kwargs)
        self._agent_timeout_sec = agent_timeout_sec

    @staticmethod
    def name() -> str:
        return "zygos"

    def version(self) -> str:
        return ADAPTER_VERSION

    def dry_run(self) -> str:
        return (
            f"dataset: {DATASET}\n"
            f"command: {TASK_COMMAND}\n"
            f"adapter_version: {ADAPTER_VERSION}\n"
        )

    async def setup(self, environment: BaseEnvironment) -> None:
        binary = os.environ.get("ZYGOS_LINUX_BIN", "")
        path = Path(binary)
        if not path.is_file():
            raise RuntimeError("ZYGOS_LINUX_BIN is not a file")
        env_paths = EnvironmentPaths.for_os(environment.os)
        target = str(env_paths.agent_dir / "zygos")
        await environment.upload_file(source_path=path, target_path=target)
        await environment.exec(
            command=f"chmod +x {shlex.quote(target)}",
            user="root",
        )
        catalog = Path(self.logs_dir) / "providers.toml"
        catalog.write_text(PILOT_CATALOG, encoding="utf-8")
        await environment.upload_file(
            source_path=catalog,
            target_path=str(env_paths.agent_dir / "providers.toml"),
        )

    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        del context
        if self.model_name not in (None, APPROVED_MODEL):
            raise RuntimeError("refusing a live model other than glm-5.3-flash")
        if not os.environ.get("Z_AI_API_KEY"):
            raise RuntimeError("Z_AI_API_KEY is not set")
        task_id = os.environ.get("ZYGOS_TASK_ID", "")
        if not task_id or "/" in task_id or ".." in task_id:
            raise RuntimeError("ZYGOS_TASK_ID is missing")
        step_cap = int(os.environ.get("ZYGOS_STEP_CAP", "24"))
        if step_cap < 1 or step_cap > 32:
            raise RuntimeError("step cap is outside 1..32")
        workspace = os.environ.get("ZYGOS_WORKSPACE", "/app")
        if not workspace.startswith("/"):
            raise RuntimeError("ZYGOS_WORKSPACE is not absolute")

        env_paths = EnvironmentPaths.for_os(environment.os)
        instruction_path = env_paths.agent_dir / "instruction.txt"
        host_instruction = Path(self.logs_dir) / "instruction.txt"
        host_instruction.write_text(instruction, encoding="utf-8")
        await environment.upload_file(
            source_path=host_instruction,
            target_path=str(instruction_path),
        )

        binary = str(env_paths.agent_dir / "zygos")
        trial_path = str(env_paths.agent_dir / "trial.json")
        events_path = str(env_paths.agent_dir / "events.jsonl")
        command = " ".join(
            shlex.quote(part)
            for part in (
                binary,
                "task",
                "run",
                "--model",
                APPROVED_MODEL,
                "--workspace",
                workspace,
                "--out",
                trial_path,
                "--events",
                events_path,
                "--step-cap",
                str(step_cap),
                "--task-id",
                task_id,
                "--dataset",
                DATASET,
                "--instruction-file",
                str(instruction_path),
                "--trim",
                "on",
            )
        )
        timeout = 570
        if self._agent_timeout_sec:
            timeout = max(1, int(self._agent_timeout_sec) - 30)
        # The key stays in the exec env. It is not part of the command.
        result = await environment.exec(
            command=command,
            env={
                "Z_AI_API_KEY": os.environ["Z_AI_API_KEY"],
                "AI_PROVIDERS_CONFIG": str(env_paths.agent_dir / "providers.toml"),
            },
            timeout_sec=timeout,
        )
        if not environment.capabilities.mounted:
            try:
                await environment.download_file(
                    source_path=trial_path,
                    target_path=Path(self.logs_dir) / "trial.json",
                )
            except Exception as exc:
                self.logger.error("failed to download trial.json: %s", exc)
        if result.return_code != 0:
            (Path(self.logs_dir) / "exit-code.txt").write_text(
                str(result.return_code), encoding="utf-8"
            )
