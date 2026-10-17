"""Unsafe optional tmux features are refused before they reach the daemon."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import unittest

from tests.support.tmux_fixture import TmuxFixture

ROOT = Path(__file__).resolve().parents[2]
DEADLINE = 3


def release(version):
    match = re.fullmatch(r"(\d+)\.(\d+)([a-z]?)", version.removeprefix("next-"))
    return (int(match[1]), int(match[2]), match[3])


class FeatureTests(unittest.TestCase):
    def run_lua(self, fixture, version, case, argv=(), host="luv"):
        env = dict(fixture.env, TMUX_BIN=shutil.which(fixture.binary),
                   TMUX_SOCKET=str(fixture.socket), TMUX_DAEMON_VERSION=version,
                   LIBTMUX_FEATURE_CASE=case,
                   LIBTMUX_FEATURE_ARGV="".join(word + "|" for word in argv))
        if host == "luv":
            command = [env.get("LIBTMUX_TEST_LUA") or shutil.which("lua"),
                       "tests/integration/features.lua"]
        else:
            env.pop("LUA_CPATH", None)
            command = [os.environ.get("LIBTMUX_TEST_NVIM") or shutil.which("nvim"),
                       "--headless", "-u", "NONE", "-i", "NONE",
                       "-c", "lua dofile('tests/integration/features.lua')"]
        result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, timeout=DEADLINE)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        report = re.search(rb"FEATURE (.*)", result.stdout)
        self.assertIsNotNone(report, result.stdout)
        return report[1].decode()

    def alive(self, fixture):
        self.assertEqual(fixture.run("list-sessions", "-F", "#{session_name}").returncode, 0)

    def state(self, fixture):
        """Everything a refused command must leave alone."""
        return tuple(fixture.run(*command).stdout for command in (
            ("list-buffers", "-F", "#{buffer_name}"),
            ("list-windows", "-a", "-F", "#{window_id}"),
            ("list-panes", "-a", "-F", "#{pane_id}"),
            ("list-sessions", "-F", "#{session_name}"),
        ))

    def test_control_observation_needs_tmux_3_7_and_attaches_nothing_below(self):
        for host in ("luv", "nvim"):
            with self.subTest(host=host), TmuxFixture() as fixture:
                version = fixture.run("display-message", "-p", "#{version}").stdout.strip()
                report = self.run_lua(fixture, version, "observe", host=host)
                clients = fixture.run("list-clients", "-F", "#{client_control_mode}").stdout
                if release(version) < (3, 7, ""):
                    self.assertEqual(report, "REFUSED unsupported 3.7 not_sent")
                else:
                    self.assertEqual(report, "RAN")
                # Observation closed or never attached: no control client remains.
                self.assertEqual(clients, "")
                self.alive(fixture)

    def test_raw_commands_are_refused_per_release_without_effects(self):
        for host in ("luv", "nvim"):
            with self.subTest(host=host), TmuxFixture() as fixture:
                version = fixture.run("display-message", "-p", "#{version}").stdout.strip()
                parsed = release(version)
                fixture.run("split-window", "-d", "-t", "$0", "exec /bin/cat")
                fixture.run("set-buffer", "-b", "keep", "sentinel")
                fixture.run("set-buffer", "-b", "spare", "renamable")
                cases = (
                    # tmux 3.3a exits its daemon on a layout whose first character is
                    # not a hex digit; "bogus" is an ordinary error there.
                    ("invalid layout", ("select-layout", "-t", "@0", "x"), parsed < (3, 4, "")),
                    ("empty layout", ("select-layout", "-t", "@0", ""), parsed < (3, 4, "")),
                    ("preset layout", ("select-layout", "-t", "@0", "tiled"), False),
                    ("named buffer delete", ("delete-buffer", "-b", "absent-name"),
                     parsed < (3, 4, "")),
                    ("buffer rename", ("set-buffer", "-b", "spare", "-n", "spare2"),
                     parsed < (3, 4, "")),
                    ("split percent", ("split-window", "-d", "-t", "@0", "-p", "40",
                                       "exec /bin/cat"), version == "3.4"),
                    ("break pane", ("break-pane", "-d", "-s", "%1"), version == "3.7"),
                    ("dotted session", ("new-session", "-d", "-s", "dot.name", "exec /bin/cat"),
                     version == "3.7"),
                )
                for label, argv, refused in cases:
                    with self.subTest(case=label):
                        before = self.state(fixture)
                        report = self.run_lua(fixture, version, "raw", argv, host)
                        after = self.state(fixture)
                        self.alive(fixture)
                        if refused:
                            self.assertEqual(report.split()[:2], ["REFUSED", "unsupported"], report)
                            self.assertEqual(after, before)
                        else:
                            self.assertTrue(report.startswith("RAN"), report)
                        # The sentinel survives every case, including the refused delete.
                        self.assertIn("keep", after[0])
