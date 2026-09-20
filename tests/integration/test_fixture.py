"""Real tmux ownership and cleanup checks."""

import importlib
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import unittest
from unittest.mock import patch


try:
    TmuxFixture = importlib.import_module("tests.support.tmux_fixture").TmuxFixture
except ModuleNotFoundError:
    TmuxFixture = None


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(TmuxFixture, "owned tmux fixture is not implemented")

    def observe_exit(self, pid):
        if hasattr(os, "pidfd_open"):
            fd = os.pidfd_open(pid)
            self.addCleanup(os.close, fd)
            return lambda: bool(select.select([fd], [], [], 0)[0])
        queue = select.kqueue()
        self.addCleanup(queue.close)
        queue.control(
            [select.kevent(pid, filter=select.KQ_FILTER_PROC,
                           flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                           fflags=select.KQ_NOTE_EXIT)], 0, 0,
        )
        return lambda: bool(queue.control([], 1, 0))

    def assert_removed(self, fixture, exited):
        self.assertFalse(fixture.socket.exists())
        self.assertFalse(fixture.path.exists())
        for name, observed in exited.items():
            self.assertTrue(observed(), f"owned {name} process did not exit")

    def test_success_cleanup_preserves_another_owned_server(self):
        with TmuxFixture() as borrowed:
            with patch.dict(os.environ, {"TMUX": str(borrowed.socket),
                                         "TMUX_PANE": "%999"}):
                with TmuxFixture() as owned:
                    self.assertNotEqual(owned.socket, borrowed.socket)
                    self.assertTrue(owned.path.name.startswith("libtmux-lua-"))
                    self.assertLess(len(os.fsencode(owned.socket)), 100)
                    self.assertNotIn("TMUX", owned.env)
                    self.assertNotIn("TMUX_PANE", owned.env)
                    self.assertEqual(owned.path.stat().st_mode & 0o777, 0o700)
                    self.assertEqual(
                        owned.run("display-message", "-p", "#{socket_path}").stdout.strip(),
                        str(owned.socket),
                    )
                    client = owned.spawn("wait-for", "never-signalled")
                    exited = {
                        "server": self.observe_exit(owned.server_pid),
                        "pane": self.observe_exit(owned.pane_pids[0]),
                        "client": self.observe_exit(client.pid),
                    }
                self.assert_removed(owned, exited)
                self.assertIsNotNone(client.returncode)
            self.assertEqual(borrowed.run("has-session", "-t", "fixture").returncode, 0)
        self.assertFalse(borrowed.path.exists())

    def test_exception_and_cancellation_cleanup(self):
        for failure in (RuntimeError, KeyboardInterrupt):
            with self.subTest(failure=failure.__name__):
                with self.assertRaises(failure):
                    with TmuxFixture() as owned:
                        exited = {
                            "server": self.observe_exit(owned.server_pid),
                            "pane": self.observe_exit(owned.pane_pids[0]),
                        }
                        raise failure("injected fixture exit")
                self.assert_removed(owned, exited)

    def test_import_does_not_start_processes_or_create_fixture(self):
        probe = """
import sys
import signal
def audit(event, args):
    if event in ('subprocess.Popen', 'tempfile.mkdtemp'):
        raise AssertionError('import created a process or temporary directory')
sys.addaudithook(audit)
handlers = {s: signal.getsignal(s) for s in (signal.SIGINT, signal.SIGTERM)}
import tests.support.tmux_fixture
import tests.run_integration
assert handlers == {s: signal.getsignal(s) for s in handlers}
"""
        result = subprocess.run(
            [sys.executable, "-c", probe], capture_output=True, text=True,
            timeout=0.8, cwd=Path(__file__).resolve().parents[2],
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_cleanup_failures_still_release_owned_resources(self):
        operations = [("list-panes",), ("list-panes", "kill-server")]
        with TmuxFixture() as borrowed:
            for failed in operations:
                with self.subTest(failed=failed):
                    if len(failed) > 1 and not hasattr(signal, "pidfd_send_signal"):
                        self.skipTest("forced server release requires Linux pidfd signals")
                    owned = TmuxFixture().__enter__()
                    self.addCleanup(owned.close)
                    client = owned.spawn("wait-for", "never-signalled")
                    exited = {"server": self.observe_exit(owned.server_pid),
                              "pane": self.observe_exit(owned.pane_pids[0]),
                              "client": self.observe_exit(client.pid)}
                    run = owned.run

                    def fail_cleanup(*args, **kwargs):
                        if args[0] in failed:
                            raise subprocess.TimeoutExpired(args[0], 0.8)
                        return run(*args, **kwargs)

                    with patch.object(owned, "run", side_effect=fail_cleanup):
                        with self.assertRaisesRegex(Exception, "list-panes") as failure:
                            owned.close()
                    self.assert_removed(owned, exited)
                    self.assertIsInstance(failure.exception, RuntimeError)
                    for operation in failed:
                        self.assertIn(operation, str(failure.exception))
                    self.assertTrue(client.stdout.closed)
                    self.assertTrue(client.stderr.closed)
                    self.assertEqual(borrowed.run("has-session", "-t", "fixture").returncode, 0)

    def test_reaped_client_pipes_close(self):
        with TmuxFixture() as owned:
            client = owned.spawn("display-message", "-p", "ready")
            self.addCleanup(client.stdout.close)
            self.addCleanup(client.stderr.close)
            self.assertTrue(select.select([client.stdout], [], [], 0.8)[0])
            self.assertEqual(client.stdout.readline(), "ready\n")
            client.wait()
        self.assertTrue(client.stdout.closed)
        self.assertTrue(client.stderr.closed)

    def test_sigterm_unwinds_fixture_in_worker(self):
        probe = """
import contextlib
import json
import signal
import sys
from tests.support.tmux_fixture import TmuxFixture
try:
    from tests.run_integration import cancellation_signals
except ImportError:
    cancellation_signals = contextlib.nullcontext
try:
    with cancellation_signals():
        with TmuxFixture() as owned:
            print(json.dumps([str(owned.path), str(owned.socket),
                              owned.server_pid, owned.pane_pids[0]]), flush=True)
            signal.pause()
except KeyboardInterrupt:
    sys.exit(143)
"""
        worker = subprocess.Popen(
            [sys.executable, "-c", probe], stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True,
            cwd=Path(__file__).resolve().parents[2],
        )
        path = socket = None
        try:
            self.assertTrue(select.select([worker.stdout], [], [], 0.8)[0])
            path, socket, server, pane = json.loads(worker.stdout.readline())
            exited = {"server": self.observe_exit(server),
                      "pane": self.observe_exit(pane)}
            worker.send_signal(signal.SIGTERM)
            _, stderr = worker.communicate(timeout=0.8)
            self.assertEqual(worker.returncode, 143, stderr)
            self.assertFalse(Path(path).exists())
            for name, observed in exited.items():
                self.assertTrue(observed(), f"owned {name} survived SIGTERM")
        finally:
            if worker.poll() is None:
                worker.kill()
            worker.communicate(timeout=0.8)
            if socket and Path(socket).exists():
                subprocess.run(
                    [os.environ.get("TMUX_BIN", "tmux"), "-f", "/dev/null",
                     "-S", socket, "kill-server"], capture_output=True, timeout=0.8,
                )
            if path and Path(path).exists():
                shutil.rmtree(path)


if __name__ == "__main__":
    unittest.main()
