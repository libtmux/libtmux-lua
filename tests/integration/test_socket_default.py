"""A connection that names no socket reaches the server tmux picks, or the one a variable names.

Three servers run: one on an explicit socket (session "fixture"), one on the
sandbox's default socket (session "bare") and one on a named socket in the
sandbox (session "named"). Each case connects with only the options and
environment it names and reads back the sessions of the server that answered.
No case can reach a server outside the sandbox: its TMUX_TMPDIR is the
sandbox's, and TMUX names the fixture's socket where a case sets it.
"""

import contextlib
import os
from pathlib import Path
import select
import shutil
import subprocess
import tempfile
import unittest

from tests.support import sandbox
from tests.support.tmux_fixture import TmuxFixture, _ProcessExit, require_control

ROOT = Path(__file__).resolve().parents[2]


class SocketDefaultTests(unittest.TestCase):
    def setUp(self):
        self.fixture = TmuxFixture()
        self.fixture.__enter__()
        self.addCleanup(self.fixture.__exit__, None, None, None)
        self.binary = shutil.which(self.fixture.binary)
        self.assertIsNotNone(self.binary)
        self.name = f"libtmux-lua-default-{os.getpid()}"
        base = os.path.join(os.path.realpath(os.environ["TMUX_TMPDIR"]), f"tmux-{os.getuid()}")
        self.default = sandbox.default_socket(os.environ)
        self.named = os.path.join(base, self.name)
        self.start("bare", self.default, [])
        self.start("named", self.named, ["-L", self.name])

    def start(self, session, socket, selector):
        """Start a server with one session, through a client that names its socket as given."""
        started = subprocess.run(
            [self.binary, *selector, "-f", "/dev/null", "new-session", "-d", "-s", session,
             "-P", "-F", "#{pid}", "exec /bin/cat"],
            env=self.fixture.env, stdin=subprocess.DEVNULL, capture_output=True, text=True,
            check=True, timeout=5,
        )
        exit_watch = _ProcessExit(int(started.stdout))
        self.addCleanup(exit_watch.close)
        self.addCleanup(self.stop, socket, exit_watch)
        return exit_watch

    def stop(self, socket, exit_watch):
        """Stop the server, wait until it has gone, and remove the socket tmux leaves behind.

        The sandbox fails a run that leaves any socket in it, a dead one included.
        """
        subprocess.run([self.binary, "-N", "-S", socket, "kill-server"], env=self.fixture.env,
                       stdin=subprocess.DEVNULL, capture_output=True, check=False, timeout=5)
        if exit_watch.fd is not None:
            self.assertTrue(select.select([exit_watch.fd], [], [], 3)[0], "a server did not stop")
        with contextlib.suppress(FileNotFoundError):
            os.unlink(socket)

    def connect(self, host, explicit=None, observe=False, **variables):
        """What the connection reached, as the Lua program reports it."""
        env = dict(self.fixture.env, TMUX_BIN=self.binary, **variables)
        if explicit is not None:
            env["LIBTMUX_TEST_EXPLICIT_SOCKET"] = explicit
        if observe:
            env["LIBTMUX_TEST_OBSERVE"] = "1"
        if host == "luv":
            command = [env.get("LIBTMUX_TEST_LUA") or shutil.which("lua"),
                       "tests/integration/socket_default.lua"]
        else:
            env.pop("LUA_CPATH", None)
            command = [os.environ.get("LIBTMUX_TEST_NVIM") or shutil.which("nvim"), "--headless", "-u", "NONE",
                       "-i", "NONE", "-c", "lua dofile('tests/integration/socket_default.lua')"]
        result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        return dict(line.split(": ", 1) for line in result.stdout.decode().splitlines() if line)

    def reaches(self, session, socket, **case):
        """The connection reached the server with this session, on this socket."""
        for host in ("luv", "nvim"):
            with self.subTest(host=host, case=sorted(case)):
                reached = self.connect(host, **case)
                self.assertEqual(reached["sessions"], session)
                self.assertEqual(os.path.realpath(reached["socket"]), os.path.realpath(socket))

    def test_a_connection_that_names_no_socket_reaches_the_default_server(self):
        self.reaches("bare", self.default)

    def test_socket_path_variable_names_the_server(self):
        self.reaches("fixture", self.fixture.socket, LIBTMUX_SOCKET_PATH=str(self.fixture.socket))

    def test_socket_variable_names_the_server_by_socket_name(self):
        self.reaches("named", self.named, LIBTMUX_SOCKET=self.name)

    def test_the_path_wins_when_both_variables_are_set(self):
        self.reaches("fixture", self.fixture.socket,
                     LIBTMUX_SOCKET_PATH=str(self.fixture.socket), LIBTMUX_SOCKET=self.name)

    def test_an_explicit_socket_comes_before_both_variables(self):
        self.reaches("fixture", self.fixture.socket, explicit=str(self.fixture.socket),
                     LIBTMUX_SOCKET_PATH=self.default, LIBTMUX_SOCKET=self.name)

    def test_inside_tmux_the_server_in_tmux_is_the_one_tmux_picks(self):
        pane = f"{self.fixture.socket},{self.fixture.server_pid},0"
        self.reaches("fixture", self.fixture.socket, TMUX=pane)
        # A name given to tmux is a socket choice, which TMUX no longer overrides.
        self.reaches("named", self.named, TMUX=pane, LIBTMUX_SOCKET=self.name)

    def test_a_control_client_attaches_to_the_server_the_connection_reached(self):
        require_control(self, self.fixture)
        for host in ("luv", "nvim"):
            with self.subTest(host=host):
                self.assertEqual(self.connect(host, observe=True)["control clients"], "1")

    def test_a_socket_path_variable_left_by_a_stopped_server_is_uncertain_not_absent(self):
        stale = os.path.join(os.environ["TMUX_TMPDIR"], f"stale-{os.getpid()}.sock")
        server = self.start("stale", stale, ["-S", stale])
        subprocess.run([self.binary, "-N", "-S", stale, "kill-server"], env=self.fixture.env,
                       stdin=subprocess.DEVNULL, capture_output=True, check=False, timeout=5)
        self.assertTrue(select.select([server.fd], [], [], 3)[0], "the server did not stop")
        if not os.path.exists(stale):
            self.skipTest("this tmux removes its socket when the server exits")
        for host in ("luv", "nvim"):
            with self.subTest(host=host):
                self.assertEqual(self.connect(host, LIBTMUX_SOCKET_PATH=stale),
                                 {"error": "uncertain_generation"})
        missing = os.path.join(os.environ["TMUX_TMPDIR"], f"missing-{os.getpid()}.sock")
        self.assertEqual(self.connect("luv", LIBTMUX_SOCKET_PATH=missing), {"error": "invalid_endpoint"})

    def test_with_no_server_the_connection_fails_and_starts_none(self):
        empty = tempfile.mkdtemp(prefix="empty-", dir=os.environ["TMUX_TMPDIR"])
        self.addCleanup(shutil.rmtree, empty, ignore_errors=True)
        for host in ("luv", "nvim"):
            with self.subTest(host=host):
                self.assertEqual(self.connect(host, TMUX_TMPDIR=empty), {"error": "invalid_endpoint"})
                self.assertEqual(sandbox.leaks(empty), [], "a connection started a server")


if __name__ == "__main__":
    unittest.main()
