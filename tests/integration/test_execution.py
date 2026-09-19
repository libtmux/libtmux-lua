"""Public command wiring preserves raw exits and indexed batch failures."""

import os
from pathlib import Path
import shutil
import subprocess
import unittest

from tests.support.tmux_fixture import TmuxFixture

ROOT = Path(__file__).resolve().parents[2]


class ExecutionTests(unittest.TestCase):
    def test_raw_failures_groups_and_independent_batch(self):
        for host in ("luv", "nvim"):
            with self.subTest(host=host), TmuxFixture() as fixture:
                env = dict(fixture.env, TMUX_BIN=shutil.which(fixture.binary),
                           TMUX_SOCKET=str(fixture.socket))
                if host == "luv":
                    command = [env.get("LIBTMUX_TEST_LUA") or shutil.which("lua"),
                               "tests/integration/execution.lua"]
                else:
                    env.pop("LUA_CPATH", None)
                    command = [os.environ.get("LIBTMUX_TEST_NVIM") or shutil.which("nvim"), "--headless", "-u", "NONE", "-i", "NONE",
                               "-c", "lua dofile('tests/integration/execution.lua')"]
                result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, timeout=0.8)
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
                self.assertIn(b"public execution passed", result.stdout)
                self.assertEqual(list(fixture.path.glob("libtmux-lua-pin-*")), [])
