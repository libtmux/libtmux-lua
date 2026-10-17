"""The version check reads the daemon's own version without firing user hooks."""

import os
from pathlib import Path
import shutil
import subprocess
import unittest

from tests.support.tmux_fixture import TmuxFixture

ROOT = Path(__file__).resolve().parents[2]
DEADLINE = 3
FLOOR = "3.3a"
# Each hook with the command that fires it. tmux has after-hooks only for commands that
# opt in; if-shell and run-shell, which carry the fence and the probe, have none through
# next-3.9, so those two arm only on a tmux that adds them.
HOOKS = (
    ("after-display-message", "@after-display", ("display-message", "-p", "control")),
    ("command-error", "@command-error", ("has-session", "-t", "=missing-control")),
    ("after-if-shell", "@after-if-shell", ("if-shell", "-F", "1", "")),
    ("after-run-shell", "@after-run-shell", ("run-shell", "true")),
)
_RANKS = {}


def ranks(version, *required):
    """Whether a report ranks at or above each release, as the library decides.

    None means the report names no release. The grammar lives in fields.lua
    only; this asks it instead of keeping a second copy.
    """
    key = (version, required)
    if key not in _RANKS:
        env = dict(os.environ, LIBTMUX_VERSION_CHECK_CASE="ranks", LIBTMUX_RANK_VERSION=version,
                   LIBTMUX_RANK_REQUIRED=",".join(required))
        lua = env.get("LIBTMUX_TEST_LUA") or shutil.which("lua")
        out = subprocess.run([lua, "tests/integration/version_check.lua"], cwd=ROOT, env=env,
                             capture_output=True, text=True, timeout=DEADLINE, check=True)
        _RANKS[key] = tuple({"true": True, "false": False, "none": None}[word]
                            for word in out.stdout.strip().split(","))
    return _RANKS[key]


def supported(version):
    return ranks(version, FLOOR)[0] is True


def refusal_wording(version):
    """The part of the refusal that tells an old daemon from a rejected release."""
    at_32 = ranks(version, "3.2")[0]
    if at_32 is None:
        return "no release"
    return "older than 3.2" if not at_32 else "older than 3.3a"


class VersionCheckTests(unittest.TestCase):
    def arm_hooks(self, fixture):
        armed = {}
        for hook, option, _ in HOOKS:
            # command-error exists from tmux 3.5; older daemons refuse the hook.
            result = fixture.run("set-hook", "-g", hook, f"set-option -g {option} fired",
                                 check=False)
            armed[option] = result.returncode == 0
            if not armed[option] and hook.startswith("after-"):
                self.assertIn("invalid option", result.stderr, hook)
        self.assertTrue(armed["@after-display"])
        return armed

    def state(self, fixture):
        """What a refused connect must leave alone."""
        return tuple(fixture.run(*command).stdout for command in (
            ("list-sessions", "-F", "#{session_name}"),
            ("list-windows", "-a", "-F", "#{window_id}"),
            ("list-panes", "-a", "-F", "#{pane_id}"),
            ("list-buffers", "-F", "#{buffer_name}:#{buffer_size}"),
            ("show-options", "-g", "@sentinel"),
            ("show-options", "-s"),
        ))

    def fired(self, fixture, option):
        return fixture.run("show-options", "-gqv", option).stdout.strip() == "fired"

    def reset(self, fixture, option):
        fixture.run("set-option", "-gu", option)

    def exercise(self, fixture, armed):
        """Prove each armed hook fires for an ordinary command, then clear it."""
        for _, option, trigger in HOOKS:
            if armed[option]:
                fixture.run(*trigger, check=False)
                self.assertTrue(self.fired(fixture, option), option)
                self.reset(fixture, option)

    def run_lua(self, fixture, mode, host, version, **extra):
        env = dict(fixture.env, TMUX_BIN=shutil.which(fixture.binary),
                   TMUX_SOCKET=str(fixture.socket), LIBTMUX_VERSION_CHECK_CASE=mode,
                   LIBTMUX_EXPECT_REFUSAL=refusal_wording(version), **extra)
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
                mode = "supported" if supported(version) else "refuse"
                if os.environ.get("LIBTMUX_REQUIRE_REFUSED"):
                    # A refusal lane built from a supported release would prove nothing.
                    self.assertEqual(mode, "refuse", version)
                fixture.run("set-option", "-g", "@sentinel", "kept")
                fixture.run("set-buffer", "-b", "sentinel", "kept")
                before = self.state(fixture)
                armed = self.arm_hooks(fixture)
                self.exercise(fixture, armed)
                self.run_lua(fixture, mode, host, version)
                for _, option, _ in HOOKS:
                    self.assertFalse(self.fired(fixture, option), option)
                sessions = sorted(fixture.run("list-sessions", "-F", "#{session_name}").stdout.split())
                self.assertEqual(sessions, ["fixture", "supported"] if mode == "supported" else ["fixture"])
                self.assertEqual(list(fixture.path.glob("libtmux-lua-pin-*")), [])
                if mode == "refuse":
                    # A refused connect leaves sessions, options and buffers untouched.
                    self.assertEqual(self.state(fixture), before)

    def test_oracle_asks_the_library_grammar(self):
        """No second copy of the grammar: bare -rc is accepted, -master and -dev are not."""
        self.assertTrue(supported("3.8-rc"))
        self.assertTrue(supported("next-3.9"))
        self.assertFalse(supported("3.3"))
        self.assertIsNone(ranks("3.4-master", "3.3a")[0])
        self.assertIsNone(ranks("3.4-dev", "3.3a")[0])
        self.assertEqual(refusal_wording("3.4-dev"), "no release")
        self.assertEqual(refusal_wording("3.1c"), "older than 3.2")
        self.assertEqual(refusal_wording("3.3"), "older than 3.3a")

    def test_control_fence_refuses_another_daemon_and_attaches_nothing(self):
        for host in ("luv", "nvim"):
            with self.subTest(host=host), TmuxFixture() as fixture:
                version = fixture.run("display-message", "-p", "#{version}").stdout.strip()
                if not supported(version):
                    self.skipTest("refused release")
                # A quiet daemon: tmux before 3.7 can crash on a notification during identify.
                session = fixture.run("display-message", "-p", "#{session_id}").stdout.strip()
                fixture.run("set-option", "-g", "@sentinel", "kept")
                fixture.run("set-buffer", "-b", "sentinel", "kept")
                before = self.state(fixture)
                for lie in ("wrong_pid", "wrong_version", "right"):
                    self.run_lua(fixture, f"control_fence_{lie}", host, version,
                                 TMUX_TEST_SESSION=session)
                    self.assertEqual(fixture.run("list-clients").stdout, "", lie)
                    self.assertEqual(self.state(fixture), before, lie)
