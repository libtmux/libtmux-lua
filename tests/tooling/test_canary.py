"""The integration runner hands the sandbox canary's clients nothing that selects a server.

The canary runs through tests/run_integration.py, and through a direct unittest
run, with a recording script named tmux first on PATH and as TMUX_BIN, and
decoys in the environment. The recorder cannot name a socket, so the canary
fails; what matters is what it was called with. Assertions compare names and
words, never environment values.
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

DECOYS = {
    "TMUX": "/decoy/server,1,0",
    "TMUX_PANE": "%9",
    "LIBTMUX_SOCKET": "decoy-name",
    "LIBTMUX_SOCKET_PATH": "/decoy/path",
    "LIBTMUX_SOCKET_NAME": "decoy-other",
    "TMUX_TMPDIR": "/decoy/tmpdir",
}
# Names the canary as a direct unittest run would, after the sandbox cannot be made.
REFUSER = """
import sys, unittest
sys.path.insert(0, sys.argv[1])
from tests.support import sandbox
def refuse(*args, **kwargs):
    raise sandbox.Refused("no temporary directory is short enough for a tmux socket path")
sandbox.prepare = refuse
unittest.main(module=None, argv=["unittest", "tests.integration.test_sandbox"])
"""


class CanaryUnderRecorderTests(unittest.TestCase):
    def setUp(self):
        # Short and under /tmp so the sandbox fits a socket path wherever TMPDIR points.
        self.root = tempfile.mkdtemp(prefix="t-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.bin = Path(self.root) / "bin"
        self.bin.mkdir()
        self.log = Path(self.root) / "calls"
        self.fake = recorder.install(self.bin)

    def canary(self, **extra):
        env = {name: value for name, value in os.environ.items()
               if not sandbox.ambient(name) and name not in ("TMUX_TMPDIR", sandbox.MARKER)}
        env.update(
            PATH=f"{self.bin}{os.pathsep}{env.get('PATH', '')}", TMPDIR=self.root, TMUX_BIN=str(self.fake),
            FAKE_TMUX_LOG=str(self.log), FAKE_TMUX_ROOT=self.root, **DECOYS, **extra,
        )
        return subprocess.run(
            [sys.executable, "tests/run_integration.py", "--pattern", "test_sandbox.py"],
            cwd=ROOT, env=env, capture_output=True, text=True, timeout=30,
        )

    def assert_clients_saw_only_the_sandbox(self):
        calls = recorder.calls(self.log)
        self.assertGreaterEqual(len(calls), 1, "the canary started no client")
        for call in calls:
            self.assertEqual(call["argv"], ["-N", "-f", "/dev/null", "list-sessions"])
            self.assertEqual(call["set"], [])
            self.assertEqual(call["tmpdir"], "inside")
        # One case moves TMUX_TMPDIR to a directory of its own, which the marker does not name.
        self.assertIn("matches", [call["marker"] for call in calls])

    def direct(self, *arguments):
        """A unittest run of the canary that does not go through the runner."""
        env = {**os.environ, **DECOYS, "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
               "TMUX_BIN": str(self.fake), "FAKE_TMUX_LOG": str(self.log), "FAKE_TMUX_ROOT": self.root,
               "TMPDIR": self.root}
        env.pop(sandbox.MARKER, None)
        return subprocess.run(
            [sys.executable, *arguments], cwd=ROOT, env=env, capture_output=True, text=True, timeout=30,
        )

    def test_the_runner_gives_the_canary_a_sandbox_and_no_selector(self):
        result = self.canary()
        # The recorder names no socket, so the cases that read tmux's answer fail.
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("refusing to start a client", result.stderr)
        self.assertNotIn("started tmux without -S", result.stderr)
        self.assert_clients_saw_only_the_sandbox()

    def test_a_direct_unittest_run_of_the_canary_is_sandboxed_too(self):
        result = self.direct("-m", "unittest", "tests.integration.test_sandbox")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("refusing to start a client", result.stderr)
        self.assertNotIn("left sockets in the sandbox", result.stderr)
        self.assert_clients_saw_only_the_sandbox()

    def test_a_direct_unittest_run_that_cannot_make_a_sandbox_exits_before_any_client(self):
        result = self.direct("-c", REFUSER, str(ROOT))
        self.assertEqual(result.returncode, 2)
        self.assertIn("integration tests refused to run: no temporary directory is short enough", result.stderr)
        self.assertNotIn("decoy", result.stderr)
        self.assertEqual(recorder.calls(self.log), [], "a client started without a sandbox")

    def test_a_run_that_bypasses_the_package_stops_the_canary_before_it_starts_a_client(self):
        # The control: discover the module by path, so neither the runner nor the package enters the sandbox.
        result = self.direct("-m", "unittest", "discover", "-s", "tests/integration", "-p", "test_sandbox.py")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to start a client outside the sandbox", result.stderr)
        self.assertEqual(recorder.calls(self.log), [], "a client started outside the sandbox")


if __name__ == "__main__":
    unittest.main()
