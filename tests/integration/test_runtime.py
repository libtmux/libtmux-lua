"""Real host-loop ownership and callback scheduling regressions."""

import os
from pathlib import Path
import shutil
import subprocess
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
