"""Binary buffer storage and native paste semantics through the public API."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

from tests.support.tmux_fixture import TmuxFixture

ROOT = Path(__file__).resolve().parents[2]
PAYLOAD = b"A\x00\x01\x1b\x7f\xff\nBENDMARK"


class BufferTests(unittest.TestCase):
    def run_case(self, mode):
        for host in ("luv", "nvim"):
            fixture = TmuxFixture()
            fixture.env.update(LC_ALL="C", LANG="C")
            with self.subTest(host=host), fixture:
                version = fixture.run("display-message", "-p", "#{version}").stdout.strip()
                report = fixture.path / "paste.bin"
                script = fixture.path / "paste.py"
                script.write_text(
                    "import os,subprocess,sys,tty\n"
                    "from pathlib import Path\n"
                    "binary,socket,report,mode=sys.argv[1:]\n"
                    "tty.setraw(0)\n"
                    "if mode == 'bracket': os.write(1,b'\\x1b[?2004h')\n"
                    "os.write(1,b'BUFFER_READY')\n"
                    "suffix=b'ENDMARK'+(b'\\x1b[201~' if mode == 'bracket' else b'')\n"
                    "value=b''\n"
                    "while not value.endswith(suffix): value += os.read(0,1024)\n"
                    "Path(report).write_bytes(value)\n"
                    "subprocess.run([binary,'-N','-S',socket,'wait-for','-S','buffer-read'],check=True,timeout=.8)\n"
                    "os.execl('/bin/cat','cat')\n"
                )
                env = dict(fixture.env, TMUX_BIN=shutil.which(fixture.binary),
                           TMUX_SOCKET=str(fixture.socket), LIBTMUX_BUFFER_CASE=mode,
                           LIBTMUX_BUFFER_SCRIPT=str(script), LIBTMUX_BUFFER_REPORT=str(report),
                           LIBTMUX_TEST_PYTHON=sys.executable)
                if host == "luv":
                    command = [os.environ.get("LIBTMUX_TEST_LUA") or shutil.which("lua"),
                               "tests/integration/buffer.lua"]
                else:
                    env.pop("LUA_CPATH", None)
                    command = [os.environ.get("LIBTMUX_TEST_NVIM") or shutil.which("nvim"),
                               "--headless", "-u", "NONE", "-i", "NONE", "-c",
                               "lua dofile('tests/integration/buffer.lua')"]
                result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True,
                                        timeout=.8)
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
                self.assertIn(f"public buffer {mode} PASS".encode(), result.stdout)
                if mode in ("raw", "bracket", "native", "separator"):
                    expected = PAYLOAD
                    if mode == "bracket":
                        expected = b"\x1b[200~" + PAYLOAD + b"\x1b[201~"
                    elif mode in ("native", "separator"):
                        if version.startswith("3.7"):
                            expected = b"A^@^A^[^?M^?\nBENDMARK"
                        expected = expected.replace(b"\n", b"|" if mode == "separator" else b"\r")
                    self.assertEqual(report.read_bytes(), expected)
                self.assertEqual(list(fixture.path.glob("libtmux-lua-pin-*")), [])
                self.assertEqual(fixture.run("list-clients").stdout, "")
                self.assertEqual(fixture.run("has-session", "-t", "$0").returncode, 0)

    def test_binary_storage_names_empty_refusal_and_output_limit(self):
        self.run_case("storage")

    def test_raw_paste_preserves_binary_and_line_feeds(self):
        self.run_case("raw")

    def test_native_paste_preserves_release_sanitization(self):
        self.run_case("native")

    def test_separator_replaces_line_feeds_without_enter(self):
        self.run_case("separator")

    def test_bracketed_paste_uses_native_mode(self):
        self.run_case("bracket")

    def test_delete_after_paste_even_when_input_is_disabled(self):
        self.run_case("disabled")
