"""Pinned daemon generations use owned aliases and never silently reconnect."""

import os
from pathlib import Path
import select
import shutil
import subprocess
import unittest

from tests.support.tmux_fixture import TmuxFixture

ROOT = Path(__file__).resolve().parents[2]


class EndpointTests(unittest.TestCase):
    def run_case(self, mode):
        for host in ("luv", "nvim"):
            with self.subTest(host=host), TmuxFixture() as fixture:
                binary = shutil.which(fixture.binary)
                self.assertIsNotNone(binary)
                version = fixture.run("display-message", "-p", "#{version}").stdout.strip()
                env = dict(fixture.env, TMUX_BIN=binary, TMUX_SOCKET=str(fixture.socket),
                           TMUX_DAEMON_VERSION=version, LIBTMUX_ENDPOINT_CASE=mode)
                if host == "luv":
                    command = [env.get("LIBTMUX_TEST_LUA") or shutil.which("lua"),
                               "tests/integration/endpoint.lua"]
                else:
                    env.pop("LUA_CPATH", None)
                    command = [os.environ.get("LIBTMUX_TEST_NVIM") or shutil.which("nvim"), "--headless", "-u", "NONE", "-i", "NONE",
                               "-c", "lua dofile('tests/integration/endpoint.lua')"]
                child = subprocess.Popen(command, cwd=ROOT, env=env, stdin=subprocess.PIPE,
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                old_socket = fixture.path / "old.sock"
                try:
                    if mode in ("replacement", "dead"):
                        self.assertTrue(select.select([child.stdout], [], [], 0.8)[0])
                        ready = child.stdout.readline()
                        self.assertTrue(ready.startswith(b"READY "),
                                        (ready, child.stderr.read() if child.poll() is not None else b""))
                        old_pid, old_started = ready.decode().split()[1:]
                        if mode == "replacement":
                            fixture.socket.rename(old_socket)
                            result = fixture.run("new-session", "-d", "-s", "fixture", "-P", "-F",
                                                 "#{pid} #{pane_pid}", "exec /bin/cat")
                            fixture._record_panes(result.stdout)
                            self.assertNotEqual(str(fixture.server_pid), old_pid)
                            self.assertEqual(fixture.run("display-message", "-p",
                                                         "#{session_id} #{pane_id}").stdout, "$0 %0\n")
                            self.assertTrue(old_started.isdecimal())
                        else:
                            fixture.run("kill-server")
                            fixture._wait_exits()
                        child.stdin.write(b"continue\n")
                        child.stdin.flush()
                    stdout, stderr = child.communicate(timeout=0.8)
                    self.assertEqual(child.returncode, 0, stderr.decode(errors="replace"))
                    self.assertIn(f"{mode} passed", stdout.decode())
                    self.assertEqual(list(fixture.path.glob("libtmux-lua-pin-*")), [])
                    if mode == "replacement":
                        self.assertEqual(fixture.run("list-sessions", "-F", "#{session_name}").stdout,
                                         "fixture\n")
                    elif mode == "dead":
                        self.assertNotEqual(fixture.run("list-sessions", check=False).returncode, 0)
                finally:
                    if child.poll() is None:
                        child.kill()
                    child.communicate(timeout=0.8)
                    if old_socket.exists():
                        subprocess.run([binary, "-N", "-S", str(old_socket), "kill-server"],
                                       env=fixture.env, capture_output=True, check=False, timeout=0.8)

    def test_actual_daemon_evidence_and_explicit_close(self):
        self.run_case("normal")

    def test_path_replacement_rejects_reused_entity_ids(self):
        self.run_case("replacement")

    def test_dead_alias_cannot_autostart_new_daemon(self):
        self.run_case("dead")

    def test_late_cancelled_binding_allocation_is_removed(self):
        self.run_case("cancel_bind")
