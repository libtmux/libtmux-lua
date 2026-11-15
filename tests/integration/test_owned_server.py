"""A server the library starts is private, answers, and is gone after stop.

The Lua program reports its directory and socket; this side checks them with
its own connection, so a library that believed it had stopped cannot vouch for
itself.
"""

import os
from pathlib import Path
import shutil
import socket
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
DECOYS = {
    "TMUX": "/decoy/server,1,0",
    "TMUX_PANE": "%9",
    "LIBTMUX_SOCKET": "decoy-name",
    "LIBTMUX_SOCKET_PATH": "/decoy/path",
    "LIBTMUX_SOCKET_NAME": "decoy-other",
}
# Passes every command through except kill-server, while the flag file exists.
STUCK = """#!/bin/sh
for argument in "$@"; do
    if [ "$argument" = kill-server ] && [ -e "$OWNED_STUCK_FLAG" ]; then
        exit 0
    fi
done
exec "$OWNED_REAL_TMUX" "$@"
"""


def answers(path):
    """Whether something accepts a connection on the socket path."""
    with socket.socket(socket.AF_UNIX) as probe:
        probe.settimeout(1)
        try:
            probe.connect(str(path))
        except (ConnectionRefusedError, FileNotFoundError, NotADirectoryError):
            return False
        return True


class OwnedServerTests(unittest.TestCase):
    def setUp(self):
        # Short and under /tmp: the directory and its socket alias must fit sun_path.
        self.root = Path(tempfile.mkdtemp(prefix="t-", dir="/tmp"))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.binary = shutil.which(os.environ.get("TMUX_BIN") or "tmux")
        self.assertIsNotNone(self.binary)

    def launch(self, case, host="luv", **extra):
        env = dict(os.environ, TMUX_BIN=self.binary, OWNED_ROOT=str(self.root),
                   LIBTMUX_OWNED_CASE=case, **extra)
        if host == "luv":
            command = [env.get("LIBTMUX_TEST_LUA") or shutil.which("lua"),
                       "tests/integration/owned_server.lua"]
        else:
            env.pop("LUA_CPATH", None)
            command = [env.get("LIBTMUX_TEST_NVIM") or shutil.which("nvim"), "--headless",
                       "-u", "NONE", "-i", "NONE",
                       "-c", "lua dofile('tests/integration/owned_server.lua')"]
        result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True,
                                timeout=20)
        reported = dict(line.split(" ", 1) for line in result.stdout.splitlines()
                        if line.startswith(("DIR ", "SOCKET ", "RUN ")))
        return result, reported

    def assert_stopped(self, reported):
        self.assertFalse(Path(reported["DIR"]).exists(), "the directory survived")
        self.assertFalse(answers(reported["SOCKET"]), "a server answers on the socket")
        self.assertEqual(list(self.root.iterdir()), [], "something was left under the root")

    def passes(self, case, host="luv", **extra):
        result, reported = self.launch(case, host, **extra)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS", result.stdout)
        return reported

    def test_a_started_server_answers_and_is_gone_after_stop(self):
        for host in ("luv", "nvim"):
            with self.subTest(host=host):
                reported = self.passes("round_trip", host)
                self.assert_stopped(reported)

    def test_the_private_directory_belongs_to_the_caller_alone(self):
        result, reported = self.launch("round_trip")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(Path(reported["DIR"]).name.startswith("libtmux-"))
        self.assertEqual(Path(reported["DIR"]).parent, self.root)
        self.assertEqual(Path(reported["SOCKET"]).name, "tmux.sock")

    def test_the_daemon_stays_up_with_no_session(self):
        self.assert_stopped(self.passes("zero_sessions"))

    def test_the_daemon_inherits_no_selector_and_a_private_tmpdir(self):
        reported = self.passes("environment", **DECOYS, TMUX_TMPDIR="/decoy/tmpdir")
        self.assert_stopped(reported)

    def test_leaving_the_scope_stops_the_server_however_the_body_ends(self):
        self.assert_stopped(self.passes("scope"))
        self.assertEqual(list(self.root.iterdir()), [])

    def test_leaving_the_runtime_stops_a_server_nobody_stopped(self):
        for failing, expected in ((None, "RUN OK "), ("error", "RUN ERROR ")):
            with self.subTest(failing=failing):
                extra = {"OWNED_EXIT": failing} if failing else {}
                result, reported = self.launch("exit", **extra)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(result.stdout.splitlines()[-1].startswith(expected), result.stdout)
                self.assert_stopped(reported)

    def test_a_daemon_that_survives_kill_server_keeps_the_directory_and_stop_can_retry(self):
        wrapper = self.root.parent / (self.root.name + ".tmux")
        wrapper.write_text(STUCK)
        wrapper.chmod(stat.S_IRWXU)
        self.addCleanup(wrapper.unlink, missing_ok=True)
        flag = self.root.parent / (self.root.name + ".flag")
        flag.write_text("")
        self.addCleanup(flag.unlink, missing_ok=True)
        extra = dict(OWNED_STUCK_BIN=str(wrapper), OWNED_STUCK_FLAG=str(flag),
                     OWNED_REAL_TMUX=self.binary)
        result, reported = self.launch("stuck", **extra)
        if answers(reported.get("SOCKET", "/nonexistent")):
            subprocess.run([self.binary, "-N", "-S", reported["SOCKET"], "kill-server"],
                           capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_stopped(reported)

    def test_a_server_the_program_left_under_the_directory_is_stopped_and_reported(self):
        reported = self.passes("leak")
        self.assert_stopped(reported)

    def test_a_root_too_long_for_a_socket_path_creates_nothing(self):
        self.passes("overflow")
        self.assertEqual(list(self.root.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
