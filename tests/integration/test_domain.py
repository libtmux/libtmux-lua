"""Public creation preserves literal data and uses actual returned identities."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

from tests.support.tmux_fixture import TmuxFixture

ROOT = Path(__file__).resolve().parents[2]


class DomainTests(unittest.TestCase):
    def test_create_window_and_split_with_literal_data(self):
        for host in ("luv", "nvim"):
            with self.subTest(host=host), TmuxFixture() as fixture:
                directory = fixture.path / "literal#{pid}"
                directory.mkdir()
                report = fixture.path / "created.json"
                script = fixture.path / "created.py"
                script.write_text(
                    "import json,os,subprocess,sys\n"
                    "with open(sys.argv[1],'w') as out:\n"
                    " json.dump({'argv':sys.argv[2:],'cwd':os.getcwd(),"
                    "'env':os.environ['LIBTMUX_LITERAL']},out)\n"
                    f"subprocess.run({[fixture.binary, '-S', str(fixture.socket), 'wait-for', '-S', 'libtmux-created-ready']!r},check=True)\n"
                    "sys.stdin.buffer.read()\n"
                )
                env = dict(fixture.env, TMUX_BIN=shutil.which(fixture.binary),
                           TMUX_SOCKET=str(fixture.socket), LIBTMUX_CREATE_CWD=str(directory),
                           LIBTMUX_CREATE_REPORT=str(report), LIBTMUX_CREATE_SCRIPT=str(script),
                           LIBTMUX_TEST_PYTHON=sys.executable)
                if host == "luv":
                    command = [os.environ.get("LIBTMUX_TEST_LUA") or shutil.which("lua"),
                               "tests/integration/domain.lua"]
                else:
                    env.pop("LUA_CPATH", None)
                    command = [os.environ.get("LIBTMUX_TEST_NVIM") or shutil.which("nvim"),
                               "--headless", "-u", "NONE", "-i", "NONE", "-c",
                               "lua dofile('tests/integration/domain.lua')"]
                result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True,
                                        timeout=0.8)
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
                self.assertIn(b"public domain creation PASS", result.stdout)
                self.assertEqual(json.loads(report.read_text()), {
                    "argv": ["literal;$(not-a-shell)\n#{pid}"],
                    "cwd": str(directory), "env": "#{pid};$(not-a-shell)",
                })
                self.assertEqual(list(fixture.path.glob("libtmux-lua-pin-*")), [])
                self.assertEqual(fixture.run("has-session", "-t", "$0").returncode, 0)
