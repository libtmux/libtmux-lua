"""Real host-loop ownership and callback scheduling regressions."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class RuntimeHostTests(unittest.TestCase):
    def test_foreign_luv_callback_cannot_drive_nested_loop(self):
        lua = os.environ.get("LIBTMUX_TEST_LUA") or shutil.which("lua")
        self.assertIsNotNone(lua, "missing selected Lua executable")
        result = subprocess.run(
            [lua, "tests/support/luv_reentry.lua"], cwd=ROOT,
            capture_output=True, timeout=0.8,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertIn(b"Foreign luv callback rejection PASS", result.stdout)

    def test_nvim_borrows_loop_and_preserves_unrelated_handle(self):
        nvim = os.environ.get("LIBTMUX_TEST_NVIM") or shutil.which("nvim")
        self.assertIsNotNone(nvim, "missing Neovim integration executable")
        env = dict(os.environ)
        env.pop("LUA_CPATH", None)
        result = subprocess.run(
            [nvim, "--headless", "-u", "NONE", "-i", "NONE", "-c",
             "lua dofile('tests/support/nvim_runtime.lua')"],
            cwd=ROOT, env=env, capture_output=True, timeout=0.8,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertIn(b"Neovim runtime smoke PASS", result.stdout + result.stderr)

    def test_neovim_example_starts_its_own_server_and_reports_the_pane_count(self):
        nvim = os.environ.get("LIBTMUX_TEST_NVIM") or shutil.which("nvim")
        self.assertIsNotNone(nvim, "missing Neovim integration executable")
        binary = shutil.which(os.environ.get("TMUX_BIN") or "tmux")
        self.assertIsNotNone(binary)
        # Short and under /tmp: the example's private directory must fit a socket path.
        root = tempfile.mkdtemp(prefix="t-", dir="/tmp")
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        with tempfile.TemporaryDirectory(prefix="libtmux-lua-") as bin_dir:
            # The example finds tmux with exepath, so name the selected build "tmux" on PATH.
            os.symlink(binary, os.path.join(bin_dir, "tmux"))
            env = dict(os.environ, TMPDIR=root, PATH=bin_dir + os.pathsep + os.environ.get("PATH", ""))
            env.pop("LUA_CPATH", None)
            result = subprocess.run(
                [nvim, "--headless", "-u", "NONE", "-i", "NONE", "--cmd", "set runtimepath+=.",
                 "-c", "luafile tests/support/nvim_example.lua"],
                cwd=ROOT, env=env, capture_output=True, timeout=0.8,
            )
        output = (result.stdout + result.stderr).decode(errors="replace")
        self.assertEqual(result.returncode, 0, output)
        self.assertEqual(result.stdout.decode(), "Panes: 1\n")
        self.assertEqual(os.listdir(root), [], "the example left its server directory")
