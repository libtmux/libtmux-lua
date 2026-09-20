"""Capture native byte modes and clear history on isolated pane processes."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

from tests.support.tmux_fixture import TmuxFixture

ROOT = Path(__file__).resolve().parents[2]


class CaptureTests(unittest.TestCase):
    def run_case(self, case):
        for host in ("luv", "nvim"):
            with self.subTest(host=host), TmuxFixture() as fixture:
                script = fixture.path / "capture.py"
                script.write_text(
                    "import os,subprocess,sys,tty\n"
                    "tty.setraw(0)\n"
                    f"subprocess.run({[fixture.binary, '-N', '-S', str(fixture.socket), 'wait-for', '-S', 'capture-input-ready']!r}, check=True, timeout=0.8)\n"
                    "os.read(0,1)\n"
                    "if sys.argv[1] == 'pending':\n"
                    " os.write(1,b'PENDING_READY\\x1b[')\n"
                    "else:\n"
                    " for index in range(40): os.write(1,('line-%02d\\r\\n'%index).encode())\n"
                    " os.write(1,b'\\x1b]8;;https://example.invalid/\\x1b\\\\link\\x1b]8;;\\x1b\\\\\\r\\nCAPTURE_READY\\r\\n')\n"
                    "sys.stdin.buffer.read()\n"
                )
                untouched = fixture.run("capture-pane", "-p", "-t", "%0").stdout
                env = dict(fixture.env, TMUX_BIN=shutil.which(fixture.binary),
                           TMUX_SOCKET=str(fixture.socket), LIBTMUX_CAPTURE_CASE=case,
                           LIBTMUX_CAPTURE_SCRIPT=str(script), LIBTMUX_TEST_PYTHON=sys.executable)
                if host == "luv":
                    command = [os.environ.get("LIBTMUX_TEST_LUA") or shutil.which("lua"),
                               "tests/integration/capture.lua"]
                else:
                    env.pop("LUA_CPATH", None)
                    command = [os.environ.get("LIBTMUX_TEST_NVIM") or shutil.which("nvim"),
                               "--headless", "-u", "NONE", "-i", "NONE", "-c",
                               "lua dofile('tests/integration/capture.lua')"]
                result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True,
                                        timeout=0.8)
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
                self.assertIn(b"public capture/history PASS", result.stdout)
                self.assertEqual(fixture.run("capture-pane", "-p", "-t", "%0").stdout, untouched)
                self.assertEqual(fixture.run("list-clients").stdout, "")
                self.assertEqual(list(fixture.path.glob("libtmux-lua-pin-*")), [])
                self.assertEqual(fixture.run("has-session", "-t", "$0").returncode, 0)

    def test_pending_escape_sequence_bytes(self):
        self.run_case("pending")

    def test_history_metadata_and_explicit_clearing(self):
        self.run_case("history")
