"""Offline adapter contract checks; run with Harbor's uv Python."""

import os
import shlex
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from eval.harbor.zygos_agent import ZygosAgent


class Environment:
    os = "linux"
    capabilities = SimpleNamespace(mounted=True)

    def __init__(self):
        self.calls = []

    async def upload_file(self, **kwargs):
        pass

    async def exec(self, **kwargs):
        self.calls.append(kwargs)
        return SimpleNamespace(return_code=0)


class TrimContract(unittest.IsolatedAsyncioTestCase):
    async def test_deepseek_setup_and_run_use_keyless_catalog_and_exec_environment(self):
        class UploadEnvironment(Environment):
            def __init__(self):
                super().__init__()
                self.uploads = {}

            async def upload_file(self, **kwargs):
                self.uploads[kwargs["target_path"]] = Path(kwargs["source_path"]).read_bytes()

            async def exec(self, **kwargs):
                self.calls.append(kwargs)
                return SimpleNamespace(return_code=0, stdout="deepseek-fixture", stderr="")

        with tempfile.TemporaryDirectory() as directory:
            logs = Path(directory)
            binary = logs / "binary"
            binary.write_bytes(b"offline-binary")
            values = {
                "DEEPSEEK_API_KEY": "deepseek-fixture",
                "ZYGOS_TASK_ID": "fixture",
                "ZYGOS_LINUX_BIN": str(binary),
            }
            with patch.dict(os.environ, values, clear=True):
                environment = UploadEnvironment()
                agent = ZygosAgent(logs_dir=logs, model_name="deepseek/deepseek-v4.1-flash")
                await agent.setup(environment)
                await agent.run("fixture instruction", environment, None)
            import tomllib
            catalog = tomllib.loads((logs / "providers.toml").read_text())
            provider = catalog["providers"][0]
            self.assertEqual(provider["model"], "deepseek/deepseek-v4.1-flash")
            self.assertEqual(provider["type"], "openai_compatible")
            self.assertEqual(provider["endpoint"], "https://openrouter.ai/api/v1")
            self.assertEqual(provider["max_tokens"], 8192)
            self.assertEqual(provider["temperature"], 0.7)
            self.assertEqual(provider["key_env"], "DEEPSEEK_API_KEY")
            self.assertNotIn("key", provider)
            call = environment.calls[-1]
            command = shlex.split(call["command"])
            self.assertEqual(command[command.index("--model") + 1], provider["model"])
            self.assertEqual(call["env"]["DEEPSEEK_API_KEY"], "deepseek-fixture")
            self.assertNotIn("Z_AI_API_KEY", call["env"])
            self.assertNotIn("deepseek-fixture", call["command"])
            for path in (logs / "providers.toml", logs / "stdout.txt", logs / "stderr.txt"):
                self.assertNotIn("deepseek-fixture", path.read_text())

    async def invoke(self, trim, model="glm-5.3-flash"):
        with tempfile.TemporaryDirectory() as directory:
            environment = Environment()
            key_env = "DEEPSEEK_API_KEY" if model == "deepseek/deepseek-v4.1-flash" else "Z_AI_API_KEY"
            values = {key_env: "offline-fixture", "ZYGOS_TASK_ID": "fixture"}
            if trim is not None:
                values["ZYGOS_TRIM"] = trim
            with patch.dict(os.environ, values, clear=True):
                agent = ZygosAgent(logs_dir=Path(directory), model_name=model)
                await agent.run("fixture instruction", environment, None)
            return environment.calls

    async def test_deepseek_arms_differ_only_in_trim(self):
        model = "deepseek/deepseek-v4.1-flash"
        on, off = (await self.invoke("on", model))[0], (await self.invoke("off", model))[0]
        a, b = shlex.split(on["command"]), shlex.split(off["command"])
        position = a.index("--trim") + 1
        self.assertEqual(a[position], "on")
        self.assertEqual(b[position], "off")
        b[position] = "on"
        self.assertEqual(a, b)
        self.assertEqual(on["env"], off["env"])
        self.assertEqual(on["timeout_sec"], off["timeout_sec"])

    async def test_unknown_model_is_refused(self):
        with self.assertRaisesRegex(RuntimeError, "unapproved"):
            await self.invoke("on", "deepseek/unknown")

    async def test_arms_differ_only_in_trim_argument(self):
        on, off = (await self.invoke("on"))[0], (await self.invoke("off"))[0]
        a, b = shlex.split(on["command"]), shlex.split(off["command"])
        position = a.index("--trim") + 1
        self.assertEqual(a[position], "on")
        self.assertEqual(b[position], "off")
        b[position] = "on"
        self.assertEqual(a, b)
        self.assertEqual(on["env"], off["env"])
        self.assertNotIn("offline-fixture", on["command"])
        self.assertEqual(on["timeout_sec"], off["timeout_sec"])

    async def test_default_is_on(self):
        command = shlex.split((await self.invoke(None))[0]["command"])
        self.assertEqual(command[command.index("--trim") + 1], "on")

    async def test_invalid_trim_stops_before_exec(self):
        with self.assertRaisesRegex(RuntimeError, "trim"):
            await self.invoke("maybe")

    async def test_successful_process_preserves_diagnostics_without_key(self):
        class DiagnosticEnvironment(Environment):
            async def exec(self, **kwargs):
                self.calls.append(kwargs)
                return SimpleNamespace(
                    return_code=0,
                    stdout="task: healthy exit=0\noffline-fixture\n",
                    stderr="anthropic answered 429\noffline-fixture\n",
                )

        with tempfile.TemporaryDirectory() as directory:
            logs = Path(directory)
            environment = DiagnosticEnvironment()
            with patch.dict(os.environ, {"Z_AI_API_KEY": "offline-fixture", "ZYGOS_TASK_ID": "fixture"}, clear=True):
                agent = ZygosAgent(logs_dir=logs, model_name="glm-5.3-flash")
                await agent.run("fixture instruction", environment, None)
            stdout = (logs / "stdout.txt").read_text()
            stderr = (logs / "stderr.txt").read_text()
            self.assertIn("healthy exit=0", stdout)
            self.assertIn("anthropic answered 429", stderr)
            self.assertNotIn("offline-fixture", stdout + stderr)


if __name__ == "__main__":
    unittest.main()
