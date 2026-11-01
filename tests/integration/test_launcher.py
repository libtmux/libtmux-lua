"""The example launcher keeps a program inside its own tmux directory.

Nothing here starts tmux. A recording script stands in for tmux and for the Lua
interpreter, and writes arguments and the names of the variables that select a
server, never a value. The README tells readers to run the examples this way
"without touching a tmux you use".
"""

import os
from pathlib import Path
import shutil
import signal
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
# Starts, as an example might, with a socket at LEAK_PATH under the launcher's
# directory, which is where a tmux given none would put its own by default. The
# socket only exists, so a connection to it is refused, unless LEAK_LISTEN names
# a file: then a process outlives the program, listens, and writes its pid there.
LEAKER = """
import os, socket, subprocess, sys
path = os.path.join(os.environ["TMUX_TMPDIR"], os.environ.get("LEAK_PATH", "tmux-%d/default" % os.getuid()))
os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
if os.environ.get("LEAK_LISTEN"):
    holder = (
        "import socket, sys, time\\n"
        "server = socket.socket(socket.AF_UNIX)\\n"
        "server.bind(sys.argv[1])\\n"
        "server.listen()\\n"
        "print('ready', flush=True)\\n"
        "time.sleep(60)\\n"
    )
    child = subprocess.Popen([sys.executable, "-c", holder, path], stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
    child.stdout.readline()
    open(os.environ["LEAK_LISTEN"], "w").write(str(child.pid))
else:
    socket.socket(socket.AF_UNIX).bind(path)
"""
# Reports whether the default socket under its directory fits a socket path
# and where the directory is.
REPORTER = """
import os
directory = os.environ["TMUX_TMPDIR"]
default = os.path.join(directory, "tmux-%d" % os.getuid(), "default")
with open(os.environ["REPORT"], "w") as report:
    report.write(("fits" if len(os.fsencode(default)) <= 100 else "too long") + "\\n" + directory + "\\n")
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

    def environment(self, interpreter, **extra):
        env = {name: value for name, value in os.environ.items()
               if not sandbox.ambient(name) and name not in ("TMUX_TMPDIR", sandbox.MARKER)}
        env.update(
            DECOYS, TMPDIR=self.root, TMUX_BIN=str(self.tmux), LUA_BIN=str(interpreter),
            FAKE_TMUX_LOG=str(self.log), FAKE_TMUX_ROOT=self.root, FAKE_TMUX_STATUS="0",
        )
        env.update(extra)
        return env

    def launch(self, program, interpreter, **extra):
        return subprocess.run(
            ["sh", str(LAUNCHER), str(program)], cwd=self.root, env=self.environment(interpreter, **extra),
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

    def leaking_program(self):
        program = Path(self.root) / "leak.py"
        program.write_text(LEAKER)
        return program

    def test_a_program_that_leaves_a_socket_in_the_directory_fails_the_launch_and_is_stopped(self):
        program = self.leaking_program()
        for path in ("tmux-%d/default" % os.getuid(), "custom.sock", "a/b/c.sock"):
            with self.subTest(path=path):
                self.log.unlink(missing_ok=True)
                result = self.launch(program, sys.executable, LEAK_PATH=path, FAKE_TMUX_SERVER="answers")
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"The program left a tmux socket in the run directory: {path}\n", result.stderr)
                self.assertNotIn(self.root, result.stderr)
                stopped = [call for call in recorder.calls(self.log) if "kill-server" in call["argv"]]
                self.assertEqual(len(stopped), 1)
                self.assertEqual([stopped[0]["argv"][0], stopped[0]["argv"][2]], ["-S", "kill-server"])
                self.assertTrue(stopped[0]["argv"][1].endswith("/" + path), "the stopped socket is not the leaked one")
                self.assertEqual(stopped[0]["socket"], "inside")
                self.assertEqual(self.directories(), [])

    def survivor(self):
        """Environment for a program whose server listens on after kill-server, and the pid file it writes."""
        pidfile = Path(self.root) / "holder"

        self.addCleanup(lambda: pidfile.exists() and self.kill(int(pidfile.read_text())))
        return {"LEAK_PATH": "custom.sock", "LEAK_LISTEN": str(pidfile), "FAKE_TMUX_SERVER": "deaf"}

    def test_a_server_that_survives_kill_server_keeps_the_directory_and_fails_the_launch(self):
        # The server accepts connections but never answers its client, so kill-server never returns.
        # The launcher sleeps between its tries; a sleep that returns at once keeps the test short.
        nap = self.bin / "sleep"
        nap.write_text("#!/bin/sh\nexit 0\n")
        nap.chmod(0o755)
        path = f"{self.bin}{os.pathsep}{os.environ['PATH']}"
        result = self.launch(self.leaking_program(), sys.executable, PATH=path, **self.survivor())
        self.assertEqual(result.returncode, 1)
        self.assertIn("tmux still answers at custom.sock\n", result.stderr)
        (kept,) = self.directories()
        self.assertIn(f"Cannot stop tmux; kept {kept}\n", result.stderr)
        self.assertNotIn(self.root, result.stderr)
        self.assertTrue((Path(self.root) / kept / "custom.sock").exists(), "removed the directory of a live server")
        client = int((Path(self.root) / "client").read_text())
        self.addCleanup(self.kill, client)
        with self.assertRaises(ProcessLookupError, msg="left the tmux client that never got an answer running"):
            os.kill(client, 0)

    @staticmethod
    def kill(pid):
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass

    def test_the_stop_is_confirmed_by_a_connection_and_not_by_a_tmux_client(self):
        result = self.launch(self.leaking_program(), sys.executable, LEAK_PATH="custom.sock", FAKE_TMUX_SERVER="answers")
        self.assertEqual(result.returncode, 1)
        calls = [call["argv"] for call in recorder.calls(self.log)]
        self.assertFalse([argv for argv in calls if "show-options" in argv], "asked a tmux client whether the server was gone")
        self.assertEqual(len([argv for argv in calls if "kill-server" in argv]), 1)
        self.assertEqual(self.directories(), [])

    def test_a_launcher_without_perl_refuses_before_it_starts_tmux(self):
        empty = Path(self.root) / "empty"
        empty.mkdir()
        env = self.environment(self.interpreter, PATH=str(empty))
        result = subprocess.run(["/bin/sh", str(LAUNCHER), "program.lua"], cwd=self.root, env=env,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr, "perl is required to confirm that tmux stopped\n")
        self.assertEqual(recorder.calls(self.log), [], "started tmux without a way to confirm that it stopped")
        self.assertEqual(self.directories(), [])

    def test_a_tmpdir_too_long_for_a_socket_path_gives_way_to_tmp(self):
        program = Path(self.root) / "report.py"
        program.write_text(REPORTER)
        report = Path(self.root) / "report"
        long = Path(self.root) / ("x" * 70)
        long.mkdir()
        for tmpdir, expected in ((self.root, self.root), (str(long), "/tmp")):
            with self.subTest(tmpdir=len(tmpdir)):
                result = self.launch(program, sys.executable, TMPDIR=tmpdir, REPORT=str(report))
                self.assertEqual(result.returncode, 0, result.stderr)
                fits, directory = report.read_text().splitlines()
                self.assertEqual(fits, "fits")
                self.assertEqual(os.path.dirname(directory), expected)
                self.assertFalse(os.path.exists(directory))
                self.assertEqual("TMPDIR is too long for a tmux socket path; using /tmp\n" in result.stderr,
                                 expected == "/tmp")
                self.assertNotIn(self.root, result.stderr)


if __name__ == "__main__":
    unittest.main()
