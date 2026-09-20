"""Current-client selection using owned terminal attachments and native barriers."""

import fcntl
import os
from pathlib import Path
import pty
import shlex
import shutil
import struct
import subprocess
import termios
import unittest

from tests.support.tmux_fixture import TmuxFixture

ROOT = Path(__file__).resolve().parents[2]


class ClientTests(unittest.TestCase):
    def run_case(self, reconnect):
        for host in ("luv", "nvim"):
            with self.subTest(host=host), TmuxFixture() as fixture:
                terminals, clients = [], []
                try:
                    fixture.run("set-option", "-g", "update-environment", "DISPLAY")
                    prefix = [shutil.which(fixture.binary), "-N", "-f", "/dev/null",
                              "-S", str(fixture.socket)]
                    env = dict(fixture.env, TERM="xterm-256color", DISPLAY="client-display")
                    for index in range(2):
                        master, slave = pty.openpty()
                        terminals.extend((master, slave))
                        fcntl.ioctl(slave, termios.TIOCSWINSZ,
                                    struct.pack("HHHH", 24, 80, 0, 0))
                        event = f"client-ready-{index}"
                        command = prefix + ["attach-session", "-E", "-t", "$0", ";",
                                            "wait-for", "-S", event]
                        clients.append(subprocess.Popen(command, stdin=slave, stdout=slave,
                                                        stderr=slave, env=env))
                        fixture.run("wait-for", event)
                    selected = os.ttyname(terminals[1])
                    survivor = os.ttyname(terminals[3])
                    if reconnect:
                        command = prefix + ["attach-session", "-E", "-t", "$0", ";",
                                            "wait-for", "-S", "client-reconnected"]
                        fixture.run("detach-client", "-t", selected, "-E",
                                    "exec " + shlex.join(command))
                        fixture.run("wait-for", "client-reconnected")
                        listing = fixture.run("list-clients", "-F",
                                              "#{client_name}\t#{client_pid}").stdout
                        pids = dict(line.split("\t") for line in listing.splitlines())
                        self.assertEqual(int(pids[selected]), clients[0].pid)
                    env.update(TMUX_BIN=prefix[0], TMUX_SOCKET=str(fixture.socket),
                               LIBTMUX_CLIENT_NAME=selected, LIBTMUX_CLIENT_SURVIVOR=survivor)
                    if host == "luv":
                        command = [os.environ.get("LIBTMUX_TEST_LUA") or shutil.which("lua"),
                                   "tests/integration/client.lua"]
                    else:
                        env.pop("LUA_CPATH", None)
                        command = [os.environ.get("LIBTMUX_TEST_NVIM") or shutil.which("nvim"),
                                   "--headless", "-u", "NONE", "-i", "NONE", "-c",
                                   "lua dofile('tests/integration/client.lua')"]
                    result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True,
                                            timeout=.8)
                    self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
                    self.assertIn(b"public client PASS", result.stdout)
                    self.assertEqual(clients[0].wait(timeout=.8), 0)
                    self.assertIsNone(clients[1].poll())
                    self.assertEqual(fixture.run("list-clients", "-F", "#{client_name}").stdout,
                                     survivor + "\n")
                    self.assertEqual(list(fixture.path.glob("libtmux-lua-pin-*")), [])
                    fixture.run("detach-client", "-t", survivor)
                    self.assertEqual(clients[1].wait(timeout=.8), 0)
                finally:
                    for client in clients:
                        if client.poll() is None:
                            client.kill()
                        client.wait(timeout=.8)
                    for descriptor in terminals:
                        os.close(descriptor)
            self.assertFalse(fixture.path.exists())

    def test_switch_environment_and_detach_leave_other_terminal_alive(self):
        self.run_case(False)

    def test_same_process_reconnection_remains_addressable_by_explicit_selector(self):
        self.run_case(True)
