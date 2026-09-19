"""Owned-client PROCESS integration against real luv, Neovim and tmux."""

import os
from pathlib import Path
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest

from tests.support.tmux_fixture import TmuxFixture

ROOT = Path(__file__).resolve().parents[2]


class ProcessTests(unittest.TestCase):
    def run_case(self, case, host="luv", env=None):
        child_env = dict(os.environ if env is None else env)
        child_env.update(LIBTMUX_PROCESS_CASE=case, LIBTMUX_PYTHON=sys.executable)
        if host == "luv":
            command = [os.environ.get("LIBTMUX_TEST_LUA") or shutil.which("lua"), "tests/integration/process.lua"]
        else:
            child_env.pop("LUA_CPATH", None)
            command = [os.environ.get("LIBTMUX_TEST_NVIM") or shutil.which("nvim"), "--headless", "-u", "NONE", "-i", "NONE",
                       "-c", "lua dofile('tests/integration/process.lua')"]
        self.assertIsNotNone(command[0], f"missing {host} integration executable")
        result = subprocess.run(command, cwd=ROOT, env=child_env,
                                capture_output=True, timeout=0.8)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        return result.stdout.decode()

    def test_literal_bytes_exit_and_spawn_errors(self):
        for host in ("luv", "nvim"):
            with self.subTest(host=host):
                self.assertIn("bytes passed", self.run_case("bytes", host))

    def test_live_tmux_cancellation_preserves_server_and_other_progress(self):
        with TmuxFixture() as fixture:
            env = dict(fixture.env, TMUX_BIN=fixture.binary, TMUX_SOCKET=str(fixture.socket))
            for host in ("luv", "nvim"):
                with self.subTest(host=host):
                    self.assertIn("tmux passed", self.run_case("tmux", host, env))
                    self.assertEqual(fixture.run("has-session", "-t", "fixture").returncode, 0)

    @unittest.skipUnless(hasattr(os, "pidfd_open"), "descendant ownership proof uses Linux pidfds")
    def test_post_exit_drain_leaves_descendant_for_its_owner(self):
        code = """
import os
pid = os.fork()
if pid:
    os._exit(0)
with open(os.environ['LIBTMUX_DESCENDANT_PID'], 'w') as record:
    record.write(str(os.getpid()))
os.write(1, str(os.getpid()).encode() + b'\\n')
with open(os.environ['LIBTMUX_RELEASE_FIFO'], 'rb', buffering=0) as release:
    release.read(1)
os._exit(0)
"""
        with tempfile.TemporaryDirectory(prefix="libtmux-lua-process-") as directory:
            fifo = Path(directory) / "release"
            os.mkfifo(fifo)
            pidfile = Path(directory) / "descendant.pid"
            env = dict(os.environ, LIBTMUX_RELEASE_FIFO=str(fifo),
                       LIBTMUX_DESCENDANT_PID=str(pidfile), LIBTMUX_DESCENDANT_CODE=code)
            process_fd = None
            try:
                result = self.run_case("drain", env=env)
                match = re.search(r"descendant (\d+)", result)
                self.assertIsNotNone(match, result)
                self.assertEqual(int(match.group(1)), int(pidfile.read_text()))
                process_fd = os.pidfd_open(int(match.group(1)))
                self.assertFalse(select.select([process_fd], [], [], 0)[0])
            finally:
                release_fd = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
                try:
                    os.write(release_fd, b"x")
                    if process_fd is None and pidfile.exists():
                        process_fd = os.pidfd_open(int(pidfile.read_text()))
                    if process_fd is not None:
                        if not select.select([process_fd], [], [], 0.8)[0]:
                            signal.pidfd_send_signal(process_fd, signal.SIGKILL)
                            self.fail("owned descendant failed to exit after FIFO release")
                finally:
                    os.close(release_fd)
                    if process_fd is not None:
                        os.close(process_fd)
