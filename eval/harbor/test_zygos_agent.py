"""Offline adapter contract checks; run with Harbor's uv Python."""

import os
import shlex
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from eval.harbor.zygos_agent import ZygosAgent, mission_brief, terminal_reply


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
    async def setup_with_certificates(self, probe_code, bundle=None, mkdir_code=0):
        class CertificateEnvironment(Environment):
            def __init__(self):
                super().__init__()
                self.uploads = {}

            async def upload_file(self, **kwargs):
                self.uploads[kwargs["target_path"]] = Path(kwargs["source_path"]).read_bytes()

            async def exec(self, **kwargs):
                self.calls.append(kwargs)
                command = kwargs["command"]
                code = probe_code if command.startswith("for bundle in ") else 0
                if command == "mkdir -p /etc/ssl/certs":
                    code = mkdir_code
                return SimpleNamespace(return_code=code)

        with tempfile.TemporaryDirectory() as directory:
            logs = Path(directory)
            binary = logs / "binary"
            binary.write_bytes(b"offline-binary")
            values = {"ZYGOS_LINUX_BIN": str(binary)}
            if bundle is not None:
                path = logs / "roots.pem"
                path.write_bytes(bundle)
                values["ZYGOS_CA_BUNDLE"] = str(path)
            with patch.dict(os.environ, values, clear=True):
                environment = CertificateEnvironment()
                agent = ZygosAgent(logs_dir=logs, model_name="deepseek/deepseek-v4.1-flash")
                await agent.setup(environment)
            return environment

    async def test_missing_certificate_bundle_is_provisioned_from_explicit_fixture(self):
        bundle = b"-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----\n"
        environment = await self.setup_with_certificates(1, bundle)
        self.assertEqual(environment.uploads["/etc/ssl/certs/ca-certificates.crt"], bundle)
        self.assertTrue(any(call["command"] == "mkdir -p /etc/ssl/certs" and call["user"] == "root" for call in environment.calls))

    async def test_existing_certificate_bundle_is_preserved_without_host_lookup(self):
        environment = await self.setup_with_certificates(0)
        self.assertTrue(any(call["command"].startswith("for bundle in ") for call in environment.calls))
        self.assertNotIn("/etc/ssl/certs/ca-certificates.crt", environment.uploads)

    async def test_missing_or_invalid_host_bundle_stops_setup(self):
        for bundle in (None, b"", b"not a certificate"):
            with self.subTest(bundle=bundle):
                with self.assertRaisesRegex(RuntimeError, "CA bundle"):
                    await self.setup_with_certificates(1, bundle)

    async def test_certificate_probe_and_directory_errors_stop_setup(self):
        bundle = b"-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----\n"
        with self.assertRaisesRegex(RuntimeError, "certificate probe"):
            await self.setup_with_certificates(2, bundle)
        with self.assertRaisesRegex(RuntimeError, "certificate directory"):
            await self.setup_with_certificates(1, bundle, mkdir_code=1)

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

    async def invoke(self, trim, model="glm-5.3-flash", config=None):
        with tempfile.TemporaryDirectory() as directory:
            environment = Environment()
            key_env = "DEEPSEEK_API_KEY" if model == "deepseek/deepseek-v4.1-flash" else "Z_AI_API_KEY"
            values = {key_env: "offline-fixture", "ZYGOS_TASK_ID": "fixture"}
            if trim is not None:
                values["ZYGOS_TRIM"] = trim
            if config is not None:
                path = Path(directory) / "arm.zon"
                path.write_text(config)
                values["ZYGOS_CONFIG"] = str(path)
            with patch.dict(os.environ, values, clear=True):
                agent = ZygosAgent(logs_dir=Path(directory), model_name=model)
                await agent.run("fixture instruction", environment, None)
            return environment.calls

    async def test_config_arms_differ_only_in_the_uploaded_route_table(self):
        model = "deepseek/deepseek-v4.1-flash"
        zon = '.{ .default = .{ .{ .provider_function = "zygos::providers::deepseek-flash", .model = "deepseek/deepseek-v4.1-flash" } } }\n'

        class UploadEnvironment(Environment):
            def __init__(self):
                super().__init__()
                self.uploads = {}

            async def upload_file(self, **kwargs):
                self.uploads[kwargs["target_path"]] = Path(kwargs["source_path"]).read_text()

        with tempfile.TemporaryDirectory() as directory:
            environment = UploadEnvironment()
            path = Path(directory) / "arm.zon"
            path.write_text(zon)
            values = {"DEEPSEEK_API_KEY": "offline-fixture", "ZYGOS_TASK_ID": "fixture", "ZYGOS_CONFIG": str(path)}
            with patch.dict(os.environ, values, clear=True):
                agent = ZygosAgent(logs_dir=Path(directory), model_name=model)
                await agent.run("fixture instruction", environment, None)
            self.assertEqual(environment.uploads["/logs/agent/zygos.zon"], zon)
            self.assertEqual((Path(directory) / "zygos.zon").read_text(), zon)
            with_config = shlex.split(environment.calls[-1]["command"])
        without = shlex.split((await self.invoke("on", model))[0]["command"])
        position = with_config.index("--config")
        self.assertEqual(with_config[position + 1], "/logs/agent/zygos.zon")
        self.assertNotIn("--config", without)
        self.assertEqual(with_config[:position] + with_config[position + 2 :], without)

    async def test_missing_config_file_stops_before_exec(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = Environment()
            values = {"DEEPSEEK_API_KEY": "offline-fixture", "ZYGOS_TASK_ID": "fixture", "ZYGOS_CONFIG": str(Path(directory) / "absent.zon")}
            with patch.dict(os.environ, values, clear=True):
                agent = ZygosAgent(logs_dir=Path(directory), model_name="deepseek/deepseek-v4.1-flash")
                with self.assertRaisesRegex(RuntimeError, "ZYGOS_CONFIG"):
                    await agent.run("fixture instruction", environment, None)
            self.assertEqual(environment.calls, [])

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

    async def test_turn_wall_clock_sits_under_the_exec_ceiling(self):
        call = (await self.invoke("on"))[0]
        command = shlex.split(call["command"])
        self.assertEqual(call["timeout_sec"], 570)
        self.assertEqual(command[command.index("--timeout-ms") + 1], "540000")
        with tempfile.TemporaryDirectory() as directory:
            environment = Environment()
            with patch.dict(os.environ, {"Z_AI_API_KEY": "offline-fixture", "ZYGOS_TASK_ID": "fixture"}, clear=True):
                agent = ZygosAgent(logs_dir=Path(directory), model_name="glm-5.3-flash", agent_timeout_sec=900)
                await agent.run("fixture instruction", environment, None)
            call = environment.calls[0]
            command = shlex.split(call["command"])
            self.assertEqual(call["timeout_sec"], 870)
            self.assertEqual(command[command.index("--timeout-ms") + 1], "840000")

    async def test_mission_mode_runs_the_mission_loop_with_the_uploaded_route_table(self):
        class MissionEnvironment(Environment):
            def __init__(self):
                super().__init__()
                self.uploads = {}

            async def upload_file(self, **kwargs):
                self.uploads[kwargs["target_path"]] = Path(kwargs["source_path"]).read_text()

            async def exec(self, **kwargs):
                self.calls.append(kwargs)
                if "mission start" not in kwargs["command"]:
                    return SimpleNamespace(return_code=0)
                return SimpleNamespace(
                    return_code=1,
                    stdout='log line\n{"state":"gating","stop":"none","paused":true,"role_turns":4,"tasks_done":2}\n',
                    stderr="mission: deepseek-fixture\n",
                )

        zon = '.{ .default = .{ .{ .provider_function = "zygos::providers::deepseek-flash", .model = "deepseek/deepseek-v4.1-flash" } } }\n'
        with tempfile.TemporaryDirectory() as directory:
            logs = Path(directory)
            (logs / "arm.zon").write_text(zon)
            binary = logs / "binary"
            binary.write_bytes(b"offline-binary")
            values = {
                "DEEPSEEK_API_KEY": "deepseek-fixture", "Z_AI_API_KEY": "glm-fixture", "ZYGOS_TASK_ID": "fix-git",
                "ZYGOS_MODE": "mission", "ZYGOS_CONFIG": str(logs / "arm.zon"), "ZYGOS_LINUX_BIN": str(binary),
            }
            with patch.dict(os.environ, values, clear=True):
                environment = MissionEnvironment()
                agent = ZygosAgent(logs_dir=logs, model_name="deepseek/deepseek-v4.1-flash")
                await agent.setup(environment)
                await agent.run("Fix the repo.\n\n## Details\n\nRun the tests.", environment, None)
            import tomllib
            catalog = tomllib.loads(environment.uploads["/logs/agent/providers.toml"])
            self.assertEqual([p["model"] for p in catalog["providers"]], ["deepseek/deepseek-v4.1-flash", "glm-5.3-flash"])
            self.assertTrue(all("key" not in p for p in catalog["providers"]))
            self.assertEqual(environment.uploads["/logs/agent/zygos.zon"], zon)
            brief = environment.uploads["/logs/agent/brief.md"]
            self.assertTrue(brief.startswith("---\nmission: fix-git\nbudget:\n"))
            self.assertIn("## Success criteria", brief)
            self.assertIn("| Verified by |", brief)
            self.assertIn("## Non-goals", brief)
            self.assertTrue(brief.rstrip().endswith("Fix the repo.\n\n### Details\n\nRun the tests."))
            call = environment.calls[-1]
            self.assertEqual(call["command"], "cd /app && /logs/agent/zygos mission start /logs/agent/brief.md --planning /logs/agent/planning --no-tui")
            self.assertEqual(call["env"]["ZYGOS_CONFIG"], "/logs/agent/zygos.zon")
            self.assertEqual(call["env"]["ZYGOS_APPROVAL_TIMEOUT_MS"], "1000")
            self.assertEqual(call["env"]["ZYGOS_ROLE_MAX_STEPS"], "24")
            self.assertEqual(call["env"]["ZYGOS_MISSION_TIMEOUT_MS"], str((570 - 45) * 1000))
            self.assertEqual(call["env"]["DEEPSEEK_API_KEY"], "deepseek-fixture")
            self.assertEqual(call["env"]["Z_AI_API_KEY"], "glm-fixture")
            self.assertEqual(call["timeout_sec"], 570)
            import json
            reply = json.loads((logs / "mission.json").read_text())
            self.assertEqual(reply["state"], "gating")
            self.assertTrue(reply["paused"])
            run = json.loads((logs / "mission-run.json").read_text())
            self.assertEqual(run["mode"], "mission")
            self.assertEqual(run["exit_code"], 1)
            self.assertEqual(run["config_sha256"], __import__("hashlib").sha256(zon.encode()).hexdigest())
            for path in logs.iterdir():
                if path.is_file():
                    self.assertNotIn("deepseek-fixture", path.read_text(errors="ignore"), path)
                    self.assertNotIn("glm-fixture", path.read_text(errors="ignore"), path)
            self.assertEqual((logs / "exit-code.txt").read_text(), "1")

    async def test_mission_mode_without_config_or_terminal_reply(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = Environment()
            values = {"DEEPSEEK_API_KEY": "k", "ZYGOS_TASK_ID": "fixture", "ZYGOS_MODE": "mission"}
            with patch.dict(os.environ, values, clear=True):
                agent = ZygosAgent(logs_dir=Path(directory), model_name="deepseek/deepseek-v4.1-flash")
                with self.assertRaisesRegex(RuntimeError, "ZYGOS_CONFIG"):
                    await agent.run("x", environment, None)
            self.assertEqual(environment.calls, [])
        self.assertIsNone(terminal_reply("mission: errored: timeout\n"))
        self.assertEqual(terminal_reply('{"state":"done","stop":"completed"}\n')["stop"], "completed")

    def test_mission_brief_demotes_level_two_headings_only(self):
        brief = mission_brief("t", "# Title\n## Part\n### Sub\ntext")
        self.assertIn("\n# Title\n### Part\n### Sub\ntext\n", brief)
        self.assertEqual(brief.count("\n## "), 3)  # success criteria, non-goals, objective

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
