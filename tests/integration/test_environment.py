"""Persistent environment records and ambiguous native output on owned servers."""

import os
from pathlib import Path
import shutil
import subprocess
import unittest

from tests.support.tmux_fixture import TmuxFixture

ROOT = Path(__file__).resolve().parents[2]


class EnvironmentTests(unittest.TestCase):
    def run_case(self, mode):
        for host in ("luv", "nvim"):
            fixture = TmuxFixture()
            fixture.env.update(LC_ALL="C", LANG="C")
            with self.subTest(host=host), fixture:
                env = dict(fixture.env, TMUX_BIN=shutil.which(fixture.binary),
                           TMUX_SOCKET=str(fixture.socket), LIBTMUX_ENVIRONMENT_CASE=mode)
                if host == "luv":
                    command = [os.environ.get("LIBTMUX_TEST_LUA") or shutil.which("lua"),
                               "tests/integration/environment.lua"]
                else:
                    env.pop("LUA_CPATH", None)
                    command = [os.environ.get("LIBTMUX_TEST_NVIM") or shutil.which("nvim"),
                               "--headless", "-u", "NONE", "-i", "NONE", "-c",
                               "lua dofile('tests/integration/environment.lua')"]
                result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, timeout=0.8)
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
                self.assertIn(f"public environment {mode} PASS".encode(), result.stdout)
                self.assertEqual(list(fixture.path.glob("libtmux-lua-pin-*")), [])
                self.assertEqual(fixture.run("list-clients").stdout, "")

    def test_values_visibility_removal_and_global_fallback(self):
        self.run_case("values")

    def test_hidden_listing_and_ambiguous_removed_names(self):
        self.run_case("listing")
