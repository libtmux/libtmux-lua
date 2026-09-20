"""Typed Pane operations against owned tmux servers with event barriers."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

from tests.support.tmux_fixture import TmuxFixture

ROOT = Path(__file__).resolve().parents[2]
TEXT = "literal;#{pane_id}\\λ雪"


class PaneTests(unittest.TestCase):
    def run_case(self, case):
        for host in ("luv", "nvim"):
            with self.subTest(host=host), TmuxFixture() as fixture:
                report = fixture.path / "pane.json"
                script = fixture.path / "pane.py"
                script.write_text(
                    "import json,os,subprocess,sys,tty\n"
                    "tty.setraw(sys.stdin.fileno())\n"
                    f"def signal(name): subprocess.run({[fixture.binary, '-N', '-S', str(fixture.socket), 'wait-for', '-S']!r}+[name],check=True,timeout=0.8)\n"
                    "if os.environ.get('PANE_RESPAWN') == 'yes':\n"
                    " with open(sys.argv[1],'w') as out: json.dump({'cwd':os.getcwd(),'value':os.environ['VALUE']},out)\n"
                    " signal('pane-respawn-ready')\n"
                    " sys.stdin.buffer.read()\n"
                    "else:\n"
                    " signal('pane-input-ready')\n"
                    f" text=sys.stdin.buffer.read({len(TEXT.encode())})\n"
                    " os.write(1,b'TEXT_OK\\r\\n')\n"
                    " key=sys.stdin.buffer.read(1)\n"
                    " with open(sys.argv[1],'w') as out: json.dump({'text':text.decode(),'key':key.hex()},out)\n"
                    " for index in range(40): os.write(1,('line-%02d trailing  \\r\\n'%index).encode())\n"
                    " os.write(1,b'RENDER_DONE\\r\\n')\n"
                    " sys.stdin.buffer.read()\n"
                )
                env = dict(fixture.env, TMUX_BIN=shutil.which(fixture.binary),
                           TMUX_SOCKET=str(fixture.socket), LIBTMUX_PANE_CASE=case,
                           LIBTMUX_PANE_SCRIPT=str(script), LIBTMUX_PANE_REPORT=str(report),
                           LIBTMUX_PANE_CWD=str(fixture.path), LIBTMUX_TEST_PYTHON=sys.executable)
                if host == "luv":
                    command = [os.environ.get("LIBTMUX_TEST_LUA") or shutil.which("lua"),
                               "tests/integration/pane.lua"]
                else:
                    env.pop("LUA_CPATH", None)
                    command = [os.environ.get("LIBTMUX_TEST_NVIM") or shutil.which("nvim"),
                               "--headless", "-u", "NONE", "-i", "NONE", "-c",
                               "lua dofile('tests/integration/pane.lua')"]
                result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True,
                                        timeout=0.8)
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
                self.assertIn(b"public Pane operations PASS", result.stdout)
                expected = ({"text": TEXT, "key": "0d"} if case == "io" else
                            {"cwd": str(fixture.path), "value": "literal#{pid};"})
                self.assertEqual(json.loads(report.read_text()), expected)
                self.assertEqual(fixture.run("list-clients").stdout, "")
                self.assertEqual(list(fixture.path.glob("libtmux-lua-pin-*")), [])
                self.assertEqual(fixture.run("has-session", "-t", "$0").returncode, 0)

    def test_capture_text_keys_and_explicit_copy_mode(self):
        self.run_case("io")

    def test_resize_kill_and_respawn_preserve_target_identity(self):
        self.run_case("mutations")
