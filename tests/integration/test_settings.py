"""Typed options and hook programs against owned servers under both runtime hosts."""

import os
from pathlib import Path
import shutil
import subprocess
import unittest

from tests.support.tmux_fixture import TmuxFixture

ROOT = Path(__file__).resolve().parents[2]


class SettingsTests(unittest.TestCase):
    def run_case(self, mode):
        for host in ("luv", "nvim"):
            fixture = TmuxFixture()
            fixture.env.update(LC_ALL="C", LANG="C")
            with self.subTest(host=host), fixture:
                version = fixture.run("display-message", "-p", "#{version}").stdout.strip()
                env = dict(fixture.env, LC_ALL="C", LANG="C",
                           TMUX_BIN=shutil.which(fixture.binary),
                           TMUX_SOCKET=str(fixture.socket), TMUX_DAEMON_VERSION=version,
                           LIBTMUX_SETTINGS_CASE=mode)
                if host == "luv":
                    command = [os.environ.get("LIBTMUX_TEST_LUA") or shutil.which("lua"),
                               "tests/integration/settings.lua"]
                else:
                    env.pop("LUA_CPATH", None)
                    command = [os.environ.get("LIBTMUX_TEST_NVIM") or shutil.which("nvim"),
                               "--headless", "-u", "NONE", "-i", "NONE", "-c",
                               "lua dofile('tests/integration/settings.lua')"]
                result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True,
                                        timeout=0.8)
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
                self.assertIn(f"public settings {mode} PASS".encode(), result.stdout)
                self.assertEqual(list(fixture.path.glob("libtmux-lua-pin-*")), [])
                self.assertEqual(fixture.run("list-clients").stdout, "")
                self.assertEqual(fixture.run("has-session", "-t", "$0").returncode, 0)

    def test_scalar_bytes_absence_and_copied_results(self):
        self.run_case("scalar_bytes")

    def test_scalar_scope_inheritance_and_false(self):
        self.run_case("scalar_scopes")

    def test_sparse_arrays_indexed_append_empty_and_unset(self):
        self.run_case("arrays")

    def test_hook_storage_canonical_reads_and_inheritance(self):
        self.run_case("hook_storage")

    def test_literal_and_custom_hook_execution(self):
        self.run_case("hook_execution")
