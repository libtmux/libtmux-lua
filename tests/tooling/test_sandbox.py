"""The test sandbox removes what selects a tmux server and fails a run that leaks.

Nothing here starts tmux. Children run a recording script named tmux that
writes its arguments and the names of selector variables, never a value, so a
failure message cannot print an environment.
"""

import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tests.support import recorder, sandbox

DECOYS = {
    "TMUX": "/decoy/server,1,0",
    "TMUX_PANE": "%9",
    "LIBTMUX_SOCKET": "decoy-name",
    "LIBTMUX_SOCKET_PATH": "/decoy/path",
    "LIBTMUX_SOCKET_NAME": "decoy-other",
}
SELECTORS = sorted(DECOYS)
# Enters the sandbox when asked, then runs the recorder as a bare tmux client.
PROBE = """
import subprocess, sys
sys.path.insert(0, sys.argv[1])
from tests.support import sandbox
if sys.argv[2] == "enter":
    sandbox.enter()
subprocess.run(["tmux", "list-sessions"], check=False)
"""
# Enters the sandbox, records its directory in a file, and optionally leaves
# a socket where a tmux client that named none would have bound one.
LEAKER = """
import os, socket, sys
sys.path.insert(0, sys.argv[1])
from tests.support import sandbox
directory = sandbox.enter()
open(sys.argv[2], "w").write(directory)
if sys.argv[3] == "leak":
    folder = os.path.join(directory, "tmux-%d" % os.getuid())
    os.mkdir(folder, 0o700)
    socket.socket(socket.AF_UNIX).bind(os.path.join(folder, "default"))
"""


def fresh_environment():
    """A developer shell: no sandbox, and nothing that selects a server."""
    return {
        name: value for name, value in os.environ.items()
        if not sandbox.ambient(name) and name not in ("TMUX_TMPDIR", sandbox.MARKER)
    }


class SandboxTests(unittest.TestCase):
    def setUp(self):
        # Short and under /tmp so the sandbox fits a socket path wherever TMPDIR points.
        self.root = tempfile.mkdtemp(prefix="t-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.bin = Path(self.root) / "bin"
        self.bin.mkdir()
        self.log = Path(self.root) / "calls"
        self.fake = recorder.install(self.bin)

    def child_environment(self, **extra):
        env = fresh_environment()
        env.update(
            PATH=f"{self.bin}{os.pathsep}{env.get('PATH', '')}", TMPDIR=self.root, TMUX_BIN=str(self.fake),
            FAKE_TMUX_LOG=str(self.log), FAKE_TMUX_ROOT=self.root, **extra,
        )
        return env

    def run_child(self, source, *arguments, env):
        return subprocess.run(
            [sys.executable, "-c", source, str(ROOT), *arguments], env=env, cwd=ROOT,
            capture_output=True, text=True, timeout=10,
        )

    def sandbox_of(self, **extra):
        env = {**DECOYS, "TMUX_TMPDIR": "/decoy/tmpdir", **extra}
        directory, created = sandbox.prepare(env, roots=[self.root])
        self.assertTrue(created)
        return directory, env

    def test_every_selector_is_named_without_its_value(self):
        found = sandbox.violations(DECOYS)
        for name in SELECTORS:
            self.assertIn(f"{name} is set", found)
        self.assertFalse(any("decoy" in finding or "server" in finding for finding in found),
                         "a finding repeated an environment value")
        with self.assertRaises(sandbox.Refused) as raised:
            sandbox.check(DECOYS)
        self.assertFalse("decoy" in str(raised.exception), "the refusal repeated an environment value")

    def test_unrelated_variables_and_unset_selectors_stay_quiet(self):
        directory, env = self.sandbox_of()
        env.update(LIBTMUX_TEST_LUA="lua", LIBTMUX_RELEASE_DIR="dist", TMUX_VERSION="3.8", TMUX_BIN="tmux")
        self.addCleanup(sandbox.release, directory)
        self.assertEqual(sandbox.violations(env), [])
        sandbox.check(env)

    def test_tmux_tmpdir_must_be_the_sandbox_of_this_run(self):
        directory, env = self.sandbox_of()
        self.addCleanup(sandbox.release, directory)
        marked = {**env, sandbox.MARKER: "/tmp/other"}
        long = os.path.join(directory, "x" * sandbox.MAX_BYTES)
        cases = (
            ("TMUX_TMPDIR is unset", {name: value for name, value in env.items() if name != "TMUX_TMPDIR"}),
            ("TMUX_TMPDIR is unset", {**env, "TMUX_TMPDIR": ""}),
            ("TMUX_TMPDIR is not an absolute path", {**env, "TMUX_TMPDIR": "relative/dir"}),
            (f"TMUX_TMPDIR is longer than {sandbox.MAX_BYTES} bytes", {**env, "TMUX_TMPDIR": long, sandbox.MARKER: long}),
            ("TMUX_TMPDIR is not the sandbox directory of this run", {**env, "TMUX_TMPDIR": "/tmp"}),
            ("TMUX_TMPDIR is not the sandbox directory of this run", marked),
            ("TMUX_TMPDIR is not the sandbox directory of this run",
             {name: value for name, value in env.items() if name != sandbox.MARKER}),
        )
        for expected, case in cases:
            with self.subTest(expected=expected):
                self.assertEqual(sandbox.violations(case), [expected])
        gone = {**env, "TMUX_TMPDIR": directory + "x", sandbox.MARKER: directory + "x"}
        self.assertEqual(sandbox.violations(gone), [])
        with self.assertRaises(sandbox.Refused) as raised:
            sandbox.check(gone)
        self.assertIn("missing", str(raised.exception))

    def test_prepare_clears_selectors_and_makes_a_short_private_directory(self):
        directory, env = self.sandbox_of(LIBTMUX_RELEASE_DIR="kept")
        try:
            self.assertEqual(sandbox.violations(env), [])
            self.assertEqual(sorted(env), sorted(["LIBTMUX_RELEASE_DIR", "TMUX_TMPDIR", sandbox.MARKER]))
            self.assertTrue(env["TMUX_TMPDIR"] == env[sandbox.MARKER] == directory, "the marker differs")
            self.assertLessEqual(len(os.fsencode(directory)), sandbox.MAX_BYTES)
            self.assertTrue(os.path.basename(directory).startswith(sandbox.PREFIX))
            self.assertEqual(os.stat(directory).st_mode & 0o777, 0o700)
        finally:
            self.assertEqual(sandbox.release(directory), [])
        self.assertFalse(os.path.exists(directory))

    def test_prepare_joins_the_sandbox_a_parent_entered(self):
        directory, env = self.sandbox_of()
        self.addCleanup(sandbox.release, directory)
        env.update(DECOYS)
        again, created = sandbox.prepare(env, roots=[self.root])
        self.assertFalse(created)
        self.assertTrue(again == directory, "joining made another directory")
        self.assertEqual(sandbox.violations(env), [])

    def test_prepare_refuses_when_no_directory_is_short_enough(self):
        env = dict(DECOYS)
        with self.assertRaises(sandbox.Refused) as raised:
            sandbox.prepare(env, roots=["/" + "x" * 80])
        self.assertIn("short enough", str(raised.exception))

    def test_the_default_socket_follows_tmux_tmpdir(self):
        real = os.path.realpath(self.root)
        moved = sandbox.default_socket({"TMUX_TMPDIR": self.root}, uid=7)
        self.assertTrue(moved == os.path.join(real, "tmux-7", "default"), "TMUX_TMPDIR did not move the socket")
        fallback = os.path.join(os.path.realpath("/tmp"), "tmux-7", "default")
        for env in ({}, {"TMUX_TMPDIR": ""}):
            self.assertTrue(sandbox.default_socket(env, uid=7) == fallback, "an unset TMUX_TMPDIR must mean /tmp")
        self.assertTrue(moved != fallback, "the control cannot tell the two apart")

    def test_a_socket_under_tmux_uid_is_a_leak_and_is_stopped_with_the_sandbox_gone(self):
        directory, _ = self.sandbox_of()
        self.assertEqual(sandbox.leaks(directory), [])
        folder = Path(directory) / "tmux-7"
        folder.mkdir()
        listener = socket.socket(socket.AF_UNIX)
        self.addCleanup(listener.close)
        listener.bind(str(folder / "default"))
        (folder / "libtmux-lua-pin-test").mkdir()
        with patch.dict(os.environ, {"TMUX_BIN": str(self.fake), "FAKE_TMUX_LOG": str(self.log),
                                     "FAKE_TMUX_ROOT": self.root}):
            found = sandbox.release(directory)
        self.assertEqual(found, ["tmux-7/default", "tmux-7/libtmux-lua-pin-test"])
        self.assertFalse(os.path.exists(directory))
        stopped = [call["argv"][:3] + [call["argv"][-1]] for call in recorder.calls(self.log)]
        self.assertEqual(stopped, [["-N", "-S", str(folder / "default"), "kill-server"]])

    def test_the_process_that_made_the_sandbox_fails_the_run_that_leaks(self):
        record = Path(self.root) / "directory"
        quiet = self.run_child(LEAKER, str(record), "quiet", env=self.child_environment())
        self.assertEqual(quiet.returncode, 0, quiet.stderr)
        self.assertFalse(os.path.exists(record.read_text()), "a clean run left its sandbox behind")
        leaked = self.run_child(LEAKER, str(record), "leak", env=self.child_environment())
        self.assertEqual(leaked.returncode, 1)
        self.assertIn("started tmux without -S", leaked.stderr)
        self.assertIn("default", leaked.stderr)
        self.assertFalse(os.path.exists(record.read_text()), "a leaking run left its sandbox behind")
        self.assertEqual(len(recorder.calls(self.log)), 1, "the leaked server was not stopped")

    def test_a_client_that_names_no_socket_is_handed_nothing_that_selects_a_server(self):
        control = self.run_child(PROBE, "bare", env=self.child_environment(**DECOYS, TMUX_TMPDIR="/decoy/tmpdir"))
        self.assertEqual(control.returncode, 0, control.stderr)
        (call,) = recorder.calls(self.log)
        self.assertEqual(sorted(call["set"]), SELECTORS, "the control must see every decoy")
        self.assertEqual(call["tmpdir"], "outside")
        self.log.unlink()
        guarded = self.run_child(PROBE, "enter", env=self.child_environment(**DECOYS, TMUX_TMPDIR="/decoy/tmpdir"))
        self.assertEqual(guarded.returncode, 0, guarded.stderr)
        (call,) = recorder.calls(self.log)
        self.assertEqual(call["argv"], ["list-sessions"])
        self.assertEqual(call["set"], [])
        self.assertEqual(call["tmpdir"], "inside")
        self.assertEqual(call["marker"], "matches")


if __name__ == "__main__":
    unittest.main()
