"""Public snapshot capture preserves links and sessionless daemon buffers."""

import os
from pathlib import Path
import shutil
import subprocess
import unittest

from tests.support.tmux_fixture import TmuxFixture

ROOT = Path(__file__).resolve().parents[2]


class ServerTests(unittest.TestCase):
    def run_case(self, mode):
        for host in ("luv", "nvim"):
            with self.subTest(host=host), TmuxFixture() as fixture:
                version = fixture.run("display-message", "-p", "#{version}").stdout.strip()
                if mode == "empty":
                    fixture.run("set-option", "-s", "exit-empty", "off")
                    fixture.run("set-buffer", "-b", "retained", "bytes")
                    fixture.run("kill-session", "-t", "$0")
                else:
                    fixture.run("link-window", "-s", "@0", "-t", "$0:9")
                env = dict(fixture.env, TMUX_BIN=shutil.which(fixture.binary),
                           TMUX_SOCKET=str(fixture.socket), TMUX_DAEMON_VERSION=version,
                           LIBTMUX_SNAPSHOT_CASE=mode)
                if host == "luv":
                    command = [os.environ.get("LIBTMUX_TEST_LUA") or shutil.which("lua"),
                               "tests/integration/server.lua"]
                else:
                    env.pop("LUA_CPATH", None)
                    command = [os.environ.get("LIBTMUX_TEST_NVIM") or shutil.which("nvim"), "--headless", "-u", "NONE", "-i", "NONE",
                               "-c", "lua dofile('tests/integration/server.lua')"]
                result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True,
                                        timeout=0.8)
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
                self.assertIn(f"public snapshot {mode} PASS".encode(), result.stdout)
                self.assertEqual(list(fixture.path.glob("libtmux-lua-pin-*")), [])
                self.assertEqual(fixture.run("display-message", "-p", "#{version}").stdout.strip(),
                                 version)

    def test_repeated_window_links_and_explicit_refresh(self):
        self.run_case("linked")

    def test_sessionless_daemon_keeps_named_buffers(self):
        self.run_case("empty")
