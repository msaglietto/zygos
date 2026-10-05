"""Runner checks against fixture files and a local Harbor stub; no Docker or API."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class RunnerContract(unittest.TestCase):
    def test_deepseek_runner_uses_selected_model_and_separate_jobs_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / "eval" / "run.sh"
            script.parent.mkdir()
            shutil.copyfile(Path(__file__).parent / "run.sh", script)
            (script.parent / "image-platforms.json").write_text(json.dumps({
                "status": "ready", "chosen_triple": "x86_64-linux.5.10...6.19-gnu.2.31",
            }))
            binary = root / "zig-out/linux-x86_64/bin/zygos"
            binary.parent.mkdir(parents=True)
            binary.write_text("offline-binary")
            task = root / "tasks/fixture"
            task.mkdir(parents=True)
            (task / "task.toml").write_text("# fixture")
            stub = root / "bin/harbor"
            stub.parent.mkdir()
            stub.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$ZYGOS_HARBOR_CAPTURE"\n')
            stub.chmod(0o755)
            capture = root / "arguments"
            jobs = root / "deepseek-jobs"
            env = {
                "PATH": str(stub.parent) + os.pathsep + "/usr/bin:/bin",
                "ZYGOS_HARBOR_CAPTURE": str(capture), "ZYGOS_JOBS_DIR": str(jobs),
            }
            result = subprocess.run([
                "sh", str(script), "--task", "fixture",
                "--model", "deepseek/deepseek-v4.1-flash", "--task-dir", str(task),
            ], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            args = capture.read_text().splitlines()
            self.assertEqual(args[args.index("-m") + 1], "deepseek/deepseek-v4.1-flash")
            self.assertEqual(args[args.index("-o") + 1], str(jobs))
            self.assertEqual(args[args.index("-k") + 1], "1")
            self.assertEqual(args[args.index("--max-retries") + 1], "0")
            self.assertNotIn("--upload", args)
            self.assertNotIn("--public", args)


if __name__ == "__main__":
    unittest.main()
