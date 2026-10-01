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
    async def invoke(self, trim):
        with tempfile.TemporaryDirectory() as directory:
            environment = Environment()
            values = {"Z_AI_API_KEY": "offline-fixture", "ZYGOS_TASK_ID": "fixture"}
            if trim is not None:
                values["ZYGOS_TRIM"] = trim
            with patch.dict(os.environ, values, clear=True):
                agent = ZygosAgent(logs_dir=Path(directory), model_name="glm-5.3-flash")
                await agent.run("fixture instruction", environment, None)
            return environment.calls

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


if __name__ == "__main__":
    unittest.main()
