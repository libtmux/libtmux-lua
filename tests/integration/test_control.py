"""Persistent observations against an explicitly owned tmux session."""

import os
from pathlib import Path
import shutil
import subprocess
import unittest

from tests.support.tmux_fixture import TmuxFixture

ROOT = Path(__file__).resolve().parents[2]


class ControlTests(unittest.TestCase):
    def run_case(self, case, timeout=0.8):
        for host in ("luv", "nvim"):
            with self.subTest(host=host), TmuxFixture() as fixture:
                fixture.run("resize-window", "-t", "fixture:0", "-x", "121", "-y", "37")
                topology = "#{session_id};#{pane_id};#{window_id};#{window_width};#{window_height}"
                before = fixture.run("display-message", "-p", "-t", "fixture:0.0", topology).stdout
                session, pane, *_ = before.strip().split(";")
                env = dict(fixture.env, TMUX_BIN=fixture.binary, TMUX_SOCKET=str(fixture.socket),
                           TMUX_TEST_SESSION=session, TMUX_TEST_PANE=pane, LIBTMUX_CONTROL_CASE=case)
                if case == "unlink":
                    window = before.strip().split(";")[2]
                    fixture.run("new-window", "-d", "-t", session, "exec /bin/cat")
                    unrelated = fixture.run("new-session", "-d", "-s", "survivor", "-P", "-F",
                                            "#{window_id}", "exec /bin/cat").stdout.strip()
                    fixture.run("link-window", "-d", "-s", window, "-t", "survivor:1")
                    env.update(TMUX_TEST_WINDOW=window, TMUX_TEST_UNRELATED_WINDOW=unrelated)
                if case == "missing":
                    fixture.run("set-option", "-s", "exit-empty", "off")
                    fixture.run("kill-session", "-t", session)
                if host == "luv":
                    command = [os.environ.get("LIBTMUX_TEST_LUA") or shutil.which("lua"),
                               "tests/integration/control.lua"]
                else:
                    env.pop("LUA_CPATH", None)
                    command = [os.environ.get("LIBTMUX_TEST_NVIM") or shutil.which("nvim"),
                               "--headless", "-u", "NONE", "-i", "NONE",
                               "-c", "lua dofile('tests/integration/control.lua')"]
                self.assertIsNotNone(command[0], f"missing {host} executable")
                result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, timeout=timeout)
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
                self.assertIn(b"control observation passed", result.stdout)
                if case == "missing":
                    self.assertEqual(fixture.run("list-sessions").stdout, "")
                elif case == "unlink":
                    remaining = fixture.run("list-panes", "-s", "-t", session,
                                            "-F", "#{pane_id}").stdout.splitlines()
                    self.assertNotIn(pane, remaining)
                    after = fixture.run("display-message", "-p", "-t", pane, topology).stdout
                    self.assertEqual(after.split(";")[1:], before.split(";")[1:])
                    self.assertEqual(fixture.run("list-clients").stdout, "")
                else:
                    after = fixture.run("display-message", "-p", "-t", "fixture:0.0", topology).stdout
                    self.assertEqual(after, before)
                    self.assertEqual(fixture.run("list-clients").stdout, "")

    def test_ready_observation_bytes_overflow_and_explicit_teardown(self):
        self.run_case("stream")

    def test_missing_session_does_not_create_a_scratch_session(self):
        self.run_case("missing")

    def test_unlinked_window_reports_loss_without_unrelated_window_false_gap(self):
        self.run_case("unlink")

    def test_slow_native_format_subscription_delivers_typed_context(self):
        """slow: tmux samples native format subscriptions once per second."""
        self.run_case("format", timeout=1.8)
