"""Round-trip tmux metadata as bytes over the asynchronous process lane."""

import os
from pathlib import Path
import shutil
import subprocess
import unittest

from tests.support.tmux_fixture import TmuxFixture

ROOT = Path(__file__).resolve().parents[2]


class CodecTests(unittest.TestCase):
    def test_metadata_round_trips_every_non_nul_byte(self):
        with TmuxFixture() as fixture:
            env = dict(fixture.env, TMUX_BIN=fixture.binary,
                       TMUX_SOCKET=str(fixture.socket))
            lua = os.environ.get("LIBTMUX_TEST_LUA") or shutil.which("lua")
            self.assertIsNotNone(lua, "missing selected Lua executable")
            result = subprocess.run(
                [lua, "tests/integration/codec.lua"], cwd=ROOT, env=env,
                capture_output=True, timeout=0.8,
            )
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
            self.assertIn(b"metadata codec PASS", result.stdout)
            self.assertIn(b"typed pane metadata PASS", result.stdout)
