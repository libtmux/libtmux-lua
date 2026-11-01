"""A tmux client that names no socket looks only inside the sandbox.

Each case first requires the sandbox to hold, so a broken one fails before any
client runs. The clients here name no socket; the sandbox decides where they
look, and no server listens there. Failure messages are fixed text: the paths
involved come from environment values.

The library has no default-server resolver: a connection that names no socket
passes tmux none, and tmux chooses. test_socket_default compares the socket
tmux chose with sandbox.default_socket, which these cases pin against tmux
itself.
"""

import os
import shutil
import subprocess
import tempfile
import unittest

from tests.support import sandbox


class SandboxCanaryTests(unittest.TestCase):
    def setUp(self):
        self.assertEqual(sandbox.violations(os.environ), [], "refusing to start a client outside the sandbox")
        sandbox.check(os.environ)
        self.binary = os.environ.get("TMUX_BIN", "tmux")

    def bare_client(self, env):
        """A client that names no socket and may not start a server."""
        result = subprocess.run(
            [self.binary, "-N", "-f", "/dev/null", "list-sessions"], env=env,
            capture_output=True, text=True, timeout=5, stdin=subprocess.DEVNULL,
        )
        return result.returncode, result.stdout + result.stderr

    def test_a_client_that_names_no_socket_looks_only_in_the_sandbox(self):
        status, output = self.bare_client(dict(os.environ))
        self.assertNotEqual(status, 0, "a bare client found a server")
        self.assertTrue(sandbox.default_socket(os.environ) in output,
                        "the bare client did not look in the sandbox's default socket")

    def test_the_default_socket_moves_with_tmux_tmpdir_in_tmux_itself(self):
        elsewhere = tempfile.mkdtemp(prefix="elsewhere-", dir=os.environ["TMUX_TMPDIR"])
        self.addCleanup(shutil.rmtree, elsewhere, ignore_errors=True)
        env = {**os.environ, "TMUX_TMPDIR": elsewhere}
        status, output = self.bare_client(env)
        self.assertNotEqual(status, 0, "a bare client found a server")
        moved = sandbox.default_socket(env)
        self.assertTrue(moved in output, "tmux did not follow TMUX_TMPDIR")
        self.assertTrue(moved != sandbox.default_socket(os.environ), "the control cannot tell two directories apart")
        self.assertFalse(sandbox.default_socket(os.environ) in output,
                         "tmux named the sandbox's default socket for another TMUX_TMPDIR")

    def test_removing_tmux_tmpdir_would_name_the_real_default_socket(self):
        # Computed only: a client run without TMUX_TMPDIR could reach the real server.
        env = {name: value for name, value in os.environ.items() if name != "TMUX_TMPDIR"}
        real = sandbox.default_socket(env)
        self.assertEqual(real, os.path.join(os.path.realpath("/tmp"), f"tmux-{os.getuid()}", "default"))
        self.assertTrue(real != sandbox.default_socket(os.environ), "removing TMUX_TMPDIR changed nothing")
        self.assertFalse(real.startswith(os.environ["TMUX_TMPDIR"]), "the real default lies inside the sandbox")


if __name__ == "__main__":
    unittest.main()
