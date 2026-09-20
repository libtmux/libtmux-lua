"""Real tmux argv encoding, command-group boundaries and WAIT completion."""

import os
from pathlib import Path
import select
import shlex
import shutil
import subprocess
import time
import unittest

from tests.support.tmux_fixture import TmuxFixture

ROOT = Path(__file__).resolve().parents[2]


class CommandTests(unittest.TestCase):
    def run_case(self, case):
        with TmuxFixture() as fixture:
            base = [fixture.binary, "-S", str(fixture.socket), "wait-for"]
            shell = "; ".join((shlex.join([*base, "-S", "libtmux-command-ready"]),
                               shlex.join([*base, "libtmux-command-release"]),
                               "printf 'late output\\n'", "exit 7"))
            env = dict(fixture.env, TMUX_BIN=fixture.binary, TMUX_SOCKET=str(fixture.socket),
                       LIBTMUX_COMMAND_CASE=case, LIBTMUX_WAIT_SHELL=shell)
            for host in ("luv", "nvim"):
                with self.subTest(host=host):
                    child_env = dict(env)
                    if host == "luv":
                        command = [child_env.get("LIBTMUX_TEST_LUA") or shutil.which("lua"),
                                   "tests/integration/command.lua"]
                    else:
                        child_env.pop("LUA_CPATH", None)
                        command = [os.environ.get("LIBTMUX_TEST_NVIM") or shutil.which("nvim"), "--headless", "-u", "NONE", "-i", "NONE",
                                   "-c", "lua dofile('tests/integration/command.lua')"]
                    self.assertIsNotNone(command[0], f"missing {host} executable")
                    result = subprocess.run(command, cwd=ROOT, env=child_env,
                                            capture_output=True, timeout=0.8)
                    self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
                    self.assertIn(f"{case} passed", result.stdout.decode())

    def test_literal_argv_roundtrip(self):
        self.run_case("literal")

    def test_group_parse_and_runtime_errors(self):
        self.run_case("group")

    def test_wait_finishes_after_release_and_failure(self):
        self.run_case("wait")

    def test_control_guard_precedes_wait_completion(self):
        with TmuxFixture() as fixture:
            wait = shlex.join([fixture.binary, "-S", str(fixture.socket),
                               "wait-for", "libtmux-control-release"])
            shell = f"{wait}; printf 'guard-late-output\\n'; exit 7"
            client = subprocess.Popen(
                [fixture.binary, "-f", "/dev/null", "-S", str(fixture.socket),
                 "-C", "run-shell", "-t", "fixture:0.0", shell, ";", "display-message", "-p",
                 "GUARD_WAIT_CONTINUED"], env=fixture.env, stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            captured = b""
            try:
                deadline = time.monotonic() + 0.8
                while b"\n%end " not in captured:
                    self.assertTrue(select.select([client.stdout], [], [],
                                                  max(0, deadline - time.monotonic()))[0])
                    data = os.read(client.stdout.fileno(), 65536)
                    self.assertTrue(data, captured.decode(errors="replace"))
                    captured += data
                self.assertNotIn(b"GUARD_WAIT_CONTINUED", captured)
                self.assertIsNone(client.poll())
                fixture.run("wait-for", "-S", "libtmux-control-release")
                deadline = time.monotonic() + 0.8
                while True:
                    self.assertTrue(select.select([client.stdout], [], [],
                                                  max(0, deadline - time.monotonic()))[0])
                    data = os.read(client.stdout.fileno(), 65536)
                    if not data:
                        break
                    captured += data
                client.wait(timeout=0.8)
                self.assertEqual(client.returncode, 7, client.stderr.read().decode(errors="replace"))
                self.assertIn(b"GUARD_WAIT_CONTINUED\n%end ", captured)
            finally:
                if client.poll() is None:
                    client.kill()
                client.communicate(timeout=0.8)
