"""The version check reads the daemon's own version without firing user hooks."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import unittest

from tests.support.tmux_fixture import TmuxFixture

ROOT = Path(__file__).resolve().parents[2]
DEADLINE = 3
FLOOR = (3, 3, "a")
HOOKS = (("after-display-message", "@after-display"), ("command-error", "@command-error"))


def release(version):
    match = re.fullmatch(r"(\d+)\.(\d+)([a-z]?)", version)
    return (int(match[1]), int(match[2]), match[3]) if match else None


class VersionCheckTests(unittest.TestCase):
    def arm_hooks(self, fixture):
        armed = {}
        for hook, option in HOOKS:
            # command-error exists from tmux 3.5; older daemons refuse the hook.
            result = fixture.run("set-hook", "-g", hook, f"set-option -g {option} fired",
                                 check=False)
            armed[option] = result.returncode == 0
        return armed

    def fired(self, fixture, option):
        return fixture.run("show-options", "-gqv", option).stdout.strip() == "fired"

    def reset(self, fixture, option):
        fixture.run("set-option", "-gu", option)

    def exercise(self, fixture, armed):
        """Prove each armed hook fires for an ordinary command, then clear it."""
        fixture.run("display-message", "-p", "control")
        self.assertTrue(self.fired(fixture, "@after-display"))
        self.reset(fixture, "@after-display")
        if armed["@command-error"]:
            fixture.run("has-session", "-t", "=missing-control", check=False)
            self.assertTrue(self.fired(fixture, "@command-error"))
            self.reset(fixture, "@command-error")

    def run_lua(self, fixture, mode, host):
        env = dict(fixture.env, TMUX_BIN=shutil.which(fixture.binary),
                   TMUX_SOCKET=str(fixture.socket), LIBTMUX_VERSION_CHECK_CASE=mode)
        if host == "luv":
            command = [env.get("LIBTMUX_TEST_LUA") or shutil.which("lua"),
                       "tests/integration/version_check.lua"]
        else:
            env.pop("LUA_CPATH", None)
            command = [os.environ.get("LIBTMUX_TEST_NVIM") or shutil.which("nvim"),
                       "--headless", "-u", "NONE", "-i", "NONE",
                       "-c", "lua dofile('tests/integration/version_check.lua')"]
        result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, timeout=DEADLINE)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertIn(f"{mode} passed".encode(), result.stdout)

    def test_version_check_fires_no_hooks_and_refusal_has_no_effects(self):
        for host in ("luv", "nvim"):
            with self.subTest(host=host), TmuxFixture() as fixture:
                version = fixture.run("display-message", "-p", "#{version}").stdout.strip()
                parsed = release(version)
                self.assertIsNotNone(parsed, version)
                mode = "admit" if parsed >= FLOOR else "refuse"
                armed = self.arm_hooks(fixture)
                self.exercise(fixture, armed)
                self.run_lua(fixture, mode, host)
                if parsed >= (3, 7, ""):
                    # The control attachment verifies its daemon with the same probe.
                    self.run_lua(fixture, "observe", host)
                self.assertFalse(self.fired(fixture, "@after-display"))
                self.assertFalse(self.fired(fixture, "@command-error"))
                sessions = sorted(fixture.run("list-sessions", "-F", "#{session_name}").stdout.split())
                self.assertEqual(sessions, ["fixture", "supported"] if mode == "supported" else ["fixture"])
                self.assertEqual(list(fixture.path.glob("libtmux-lua-pin-*")), [])

    def test_fence_refuses_another_release_before_any_effect(self):
        with TmuxFixture() as fixture:
            version = fixture.run("display-message", "-p", "#{version}").stdout.strip()
            marker = "unknown command: libtmux-version-0123456789abcdef-"
            for mode, refused in (("fence_wrong", True), ("fence_right", False)):
                env = dict(fixture.env, TMUX_BIN=shutil.which(fixture.binary),
                           TMUX_SOCKET=str(fixture.socket), TMUX_DAEMON_VERSION=version,
                           LIBTMUX_ADMISSION_CASE=mode)
                built = subprocess.run([env.get("LIBTMUX_TEST_LUA") or shutil.which("lua"),
                                        "tests/integration/version_check.lua"], cwd=ROOT, env=env,
                                       capture_output=True, timeout=DEADLINE, check=True)
                argv = built.stdout.split(b"\0\n")[0].split(b"\0")
                result = subprocess.run([os.fsdecode(word) for word in argv], env=fixture.env,
                                        capture_output=True, text=True, timeout=DEADLINE)
                sessions = fixture.run("list-sessions", "-F", "#{session_name}").stdout.split()
                if refused:
                    self.assertEqual(result.returncode, 1, mode)
                    self.assertEqual(result.stderr.splitlines(), [marker], mode)
                    self.assertEqual(sessions, ["fixture"], mode)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(sorted(sessions), ["fenced", "fixture"])
