"""Public session leases share a native client and preserve borrowed topology."""

import os
from pathlib import Path
import shutil
import subprocess
import unittest

from tests.support.tmux_fixture import TmuxFixture

ROOT = Path(__file__).resolve().parents[2]


class ObservationTests(unittest.TestCase):
    def test_shared_client_streams_and_reopen_after_native_cleanup(self):
        for host in ("luv", "nvim"):
            with self.subTest(host=host), TmuxFixture() as fixture:
                fixture.run("resize-window", "-t", "fixture:0", "-x", "121", "-y", "37")
                topology = "#{session_id};#{pane_id};#{window_id};#{window_width};#{window_height}"
                before = fixture.run("display-message", "-p", "-t", "fixture:0.0", topology).stdout
                env = dict(fixture.env, TMUX_BIN=fixture.binary, TMUX_SOCKET=str(fixture.socket))
                if host == "luv":
                    command = [os.environ.get("LIBTMUX_TEST_LUA") or shutil.which("lua"),
                               "tests/integration/observation.lua"]
                else:
                    env.pop("LUA_CPATH", None)
                    command = [os.environ.get("LIBTMUX_TEST_NVIM") or shutil.which("nvim"),
                               "--headless", "-u", "NONE", "-i", "NONE",
                               "-c", "lua dofile('tests/integration/observation.lua')"]
                self.assertIsNotNone(command[0], f"missing {host} executable")
                result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, timeout=0.8)
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
                self.assertIn(b"shared observation passed", result.stdout)
                after = fixture.run("display-message", "-p", "-t", "fixture:0.0", topology).stdout
                self.assertEqual(after, before)
                self.assertEqual(fixture.run("list-clients").stdout, "")
