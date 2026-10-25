"""Pane:wait_for_text polls the visible screen on every tmux release."""

import os
from pathlib import Path
import shutil
import signal
import subprocess
import time
import unittest

from tests.support.tmux_fixture import TmuxFixture

ROOT = Path(__file__).resolve().parents[2]
LIMIT = 30


def at_least(version, major, minor, suffix=""):
    parts = version.removeprefix("next-").split(".")
    digits = "".join(ch for ch in parts[1] if ch.isdigit())
    found = (int(parts[0]), int(digits), parts[1][len(digits):])
    return found >= (major, minor, suffix)


class WaitTextTests(unittest.TestCase):
    def start(self, fixture, host, case):
        env = dict(fixture.env, TMUX_BIN=shutil.which(fixture.binary),
                   TMUX_SOCKET=str(fixture.socket), LIBTMUX_WAIT_CASE=case,
                   LIBTMUX_WAIT_DIR=str(fixture.path))
        if host == "luv":
            command = [os.environ.get("LIBTMUX_TEST_LUA") or shutil.which("lua"),
                       "tests/integration/wait_text.lua"]
        else:
            env.pop("LUA_CPATH", None)
            command = [os.environ.get("LIBTMUX_TEST_NVIM") or shutil.which("nvim"),
                       "--headless", "-u", "NONE", "-i", "NONE", "-c",
                       "lua dofile('tests/integration/wait_text.lua')"]
        return subprocess.Popen(command, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE)

    def finish(self, process, case, limit=LIMIT):
        started = time.monotonic()
        try:
            stdout, stderr = process.communicate(timeout=limit)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
            self.fail(f"{case} did not finish within {limit} s")
        elapsed = time.monotonic() - started
        self.assertEqual(process.returncode, 0, stderr.decode(errors="replace"))
        self.assertIn(f"wait text PASS {case}".encode(), stdout)
        return elapsed

    def run_case(self, case, check=None, setup=None, limit=LIMIT):
        for host in ("luv", "nvim"):
            with self.subTest(host=host), TmuxFixture() as fixture:
                if setup:
                    setup(fixture)
                version = fixture.run("display-message", "-p", "#{version}").stdout.strip()
                process = self.start(fixture, host, case)
                self.finish(process, case, limit)
                self.assertEqual(list(fixture.path.glob("libtmux-lua-pin-*")), [])
                if check:
                    check(fixture, version)

    def counter(self, fixture, name, expected=None):
        path = fixture.path / name
        deadline = time.monotonic() + 3
        size = -1
        while time.monotonic() < deadline:
            current = path.stat().st_size if path.exists() else 0
            if current == size and (expected is None or current >= expected):
                break
            size = current
            time.sleep(0.2)
        return path.stat().st_size if path.exists() else 0

    def test_text_printed_after_entry_matches_with_matched_at_entry_false(self):
        self.run_case("late")

    def test_text_on_screen_matches_on_one_read_before_the_first_sleep(self):
        def check(fixture, version):
            self.assertEqual(self.counter(fixture, "capture-pane", 1), 1)
        self.run_case("entry", check)

    def test_line_wider_than_the_pane_matches_across_the_wrap(self):
        self.run_case("wrapped")

    def test_killed_pane_ends_the_wait_with_the_text_seen(self):
        self.run_case("pane_killed")

    def test_exited_pane_with_remain_on_exit_ends_as_pane_exited(self):
        self.run_case("remain_on_exit")

    def test_killed_server_ends_the_wait_from_the_stale_generation(self):
        self.run_case("server_killed")

    def test_killed_server_behind_a_stopped_client_ends_from_stderr(self):
        for host in ("luv", "nvim"):
            with self.subTest(host=host), TmuxFixture() as fixture:
                process = self.start(fixture, host, "server_killed_stopped")
                client = subprocess.Popen(
                    [fixture.binary, "-f", "/dev/null", "-S", str(fixture.socket), "-C", "attach"],
                    env=fixture.env, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL)
                try:
                    self.assertEqual(process.stdout.readline(), b"READY\n")
                    attached = time.monotonic() + 5
                    while time.monotonic() < attached:
                        if fixture.run("list-clients", check=False).stdout.strip():
                            break
                        time.sleep(0.05)
                    client.send_signal(signal.SIGSTOP)
                    fixture.spawn("kill-server").communicate(timeout=10)
                    (fixture.path / "killed").write_text("")
                    self.finish(process, "server_killed_stopped")
                finally:
                    client.send_signal(signal.SIGCONT)
                    client.kill()
                    client.wait()
                    client.stdin.close()

    def test_cancel_during_the_pause_returns_before_the_interval(self):
        self.run_case("cancel", limit=3)

    def test_cancel_during_an_in_flight_read_ends_the_request(self):
        self.run_case("cancel_inflight", limit=4)

    def test_deadline_during_an_in_flight_read_carries_the_text(self):
        self.run_case("deadline_inflight", limit=4)

    def test_history_beyond_the_read_limit_does_not_fail_the_wait(self):
        self.run_case("history")

    def test_history_under_the_read_limit_is_the_control(self):
        self.run_case("history_under")

    def test_reads_fire_only_the_capture_hook(self):
        def check(fixture, version):
            self.assertGreaterEqual(self.counter(fixture, "capture-pane", 2), 2)
            for name in ("display-message", "list-panes", "show-options"):
                self.assertEqual(self.counter(fixture, name), 0, name)
        self.run_case("hooks", check)

    def test_match_wins_over_a_pane_the_hook_killed(self):
        def setup(fixture):
            version = fixture.run("display-message", "-p", "#{version}").stdout.strip()
            if not at_least(version, 3, 8):
                self.skipTest(f"the hook runs after the marker before tmux 3.8; daemon is {version}")
        self.run_case("matcher_first", setup=setup)

    def test_options_are_validated(self):
        self.run_case("validation")

    def test_runtime_close_leaves_no_timer_or_pin_directory(self):
        self.run_case("close", limit=3)

    def test_printing_hook_output_joins_the_text(self):
        def setup(fixture):
            version = fixture.run("display-message", "-p", "#{version}").stdout.strip()
            if not at_least(version, 3, 5, "a"):
                self.skipTest(f"tmux drops a hook's printed output before 3.5a; daemon is {version}")
        self.run_case("hook_output", setup=setup)

    def test_typed_command_echo_matches_the_needle(self):
        self.run_case("typed_echo")
