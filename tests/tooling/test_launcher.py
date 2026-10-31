"""The example launcher keeps a program inside its own tmux directory.

Nothing here starts tmux. A recording script stands in for tmux and for the Lua
interpreter, and writes arguments and the names of the variables that select a
server, never a value. The README tells readers to run the examples this way
"without touching a tmux you use".
"""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tests.support import recorder, sandbox

LAUNCHER = ROOT / "examples/api/run.sh"
DECOYS = {
    "TMUX": "/decoy/server,1,0",
    "TMUX_PANE": "%9",
    "LIBTMUX_SOCKET": "decoy-name",
    "LIBTMUX_SOCKET_PATH": "/decoy/path",
    "LIBTMUX_SOCKET_NAME": "decoy-other",
    "TMUX_TMPDIR": "/decoy/tmpdir",
}
# Starts, as an example might, with a socket where a tmux given none would put its own.
LEAKER = """
import os, socket
folder = os.path.join(os.environ["TMUX_TMPDIR"], "tmux-%d" % os.getuid())
os.mkdir(folder, 0o700)
socket.socket(socket.AF_UNIX).bind(os.path.join(folder, "default"))
"""


class LauncherTests(unittest.TestCase):
    def setUp(self):
        # Short and under /tmp so the launcher's directory fits a socket path wherever TMPDIR points.
        self.root = tempfile.mkdtemp(prefix="t-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.bin = Path(self.root) / "bin"
        self.bin.mkdir()
        self.log = Path(self.root) / "calls"
        self.tmux = recorder.install(self.bin)
        self.interpreter = self.bin / "lua"
        shutil.copy(self.tmux, self.interpreter)

    def environment(self, interpreter):
        env = {name: value for name, value in os.environ.items()
               if not sandbox.ambient(name) and name not in ("TMUX_TMPDIR", sandbox.MARKER)}
        env.update(
            DECOYS, TMPDIR=self.root, TMUX_BIN=str(self.tmux), LUA_BIN=str(interpreter),
            FAKE_TMUX_LOG=str(self.log), FAKE_TMUX_ROOT=self.root, FAKE_TMUX_STATUS="0",
        )
        return env

    def launch(self, program, interpreter):
        return subprocess.run(
            ["sh", str(LAUNCHER), str(program)], cwd=self.root, env=self.environment(interpreter),
            capture_output=True, text=True, timeout=30,
        )

    def directories(self):
        return sorted(path.name for path in Path(self.root).glob("libtmux-lua-api.*"))

    def test_the_program_and_every_tmux_call_see_only_the_launchers_directory(self):
        # The control: the same stand-in, run with the same environment and no launcher.
        subprocess.run([self.interpreter, "program.lua"], env=self.environment(self.interpreter), check=True)
        (control,) = recorder.calls(self.log)
        self.assertEqual(sorted(control["set"]), sorted(name for name in DECOYS if sandbox.ambient(name)))
        self.assertEqual(control["tmpdir"], "outside")
        self.log.unlink()

        result = self.launch("program.lua", self.interpreter)
        self.assertEqual(result.returncode, 0, result.stderr)
        started, program, checked = recorder.calls(self.log)
        self.assertIn("new-session", started["argv"])
        self.assertEqual(program["argv"], ["program.lua"])
        self.assertIn("has-session", checked["argv"])
        for call in (started, program, checked):
            self.assertEqual(call["set"], [])
            self.assertEqual(call["tmpdir"], "inside")
        for call in (started, checked):
            self.assertEqual(call["socket"], "inside", "the socket is not in TMUX_TMPDIR")
        self.assertEqual(self.directories(), [])

    def test_a_program_that_starts_tmux_without_a_socket_fails_the_launch_and_is_stopped(self):
        program = Path(self.root) / "leak.py"
        program.write_text(LEAKER)
        result = self.launch(program, sys.executable)
        self.assertEqual(result.returncode, 1)
        self.assertIn("started tmux without -S", result.stderr)
        stopped = [call for call in recorder.calls(self.log) if "kill-server" in call["argv"]]
        self.assertEqual(len(stopped), 1)
        self.assertEqual([stopped[0]["argv"][0], stopped[0]["argv"][2]], ["-S", "kill-server"])
        self.assertTrue(stopped[0]["argv"][1].endswith("/default"), "the stopped socket is not the leaked one")
        self.assertEqual(stopped[0]["socket"], "inside")
        self.assertEqual(self.directories(), [])


if __name__ == "__main__":
    unittest.main()
