"""Every runner and the fixture enter the sandbox before anything can reach tmux.

Nothing here starts tmux. Assertions compare names and booleans, never
environment values.
"""

import contextlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from scripts import check, package, runtime_config
from tests.support import sandbox
from tests.support.tmux_fixture import TmuxFixture

DECOYS = {
    "TMUX": "/decoy/server,1,0",
    "TMUX_PANE": "%9",
    "LIBTMUX_SOCKET": "decoy-name",
    "LIBTMUX_SOCKET_PATH": "/decoy/path",
    "LIBTMUX_SOCKET_NAME": "decoy-other",
}
DIRTY = {**DECOYS, "TMUX_TMPDIR": "/decoy/tmpdir"}
LUA_PATH = f"{ROOT}/?.lua;{ROOT}/?/init.lua"


class Stop(Exception):
    pass


class RunnerTests(unittest.TestCase):
    def selecting(self, env):
        return [name for name in env if sandbox.ambient(name)]

    def test_child_environments_carry_nothing_that_selects_a_server(self):
        with patch.dict(os.environ, DIRTY):
            self.assertEqual(self.selecting(runtime_config.clean_environment()), [])
            self.assertEqual(self.selecting(check.lua_environment(shutil.which("lua"))), [])

    def test_check_enters_the_sandbox_before_it_looks_for_a_tool(self):
        seen = []

        def look(name):
            seen.append(sandbox.violations(os.environ))
            raise Stop

        with patch.dict(os.environ, DIRTY), patch.object(check, "tool", look), \
                patch.object(sys, "argv", ["check.py", "unit"]):
            with self.assertRaises(Stop):
                check.main()
        self.assertEqual(seen, [[]])

    def test_package_enters_the_sandbox_before_it_builds_anything(self):
        seen = []

        def look(name):
            seen.append(sandbox.violations(os.environ))
            raise Stop

        with patch.dict(os.environ, DIRTY), patch.object(package, "identify", look), \
                patch.object(sys, "argv", ["package.py", "--core-only"]):
            with self.assertRaises(Stop):
                package.main()
        self.assertEqual(seen, [[]])

    def test_a_runner_that_cannot_make_the_sandbox_exits_before_running_anything(self):
        refused = sandbox.Refused("no temporary directory is short enough")
        message = io.StringIO()
        with patch.dict(os.environ, DIRTY), patch.object(sandbox, "enter", side_effect=refused), \
                patch.object(check, "tool", side_effect=Stop), patch.object(sys, "argv", ["check.py", "unit"]), \
                contextlib.redirect_stderr(message):
            with self.assertRaises(SystemExit) as raised:
                check.main()
        self.assertEqual(raised.exception.code, 2)
        self.assertIn("refused to run: no temporary directory is short enough", message.getvalue())

    def test_the_fixture_hands_its_clients_the_sandbox_and_no_selector(self):
        with patch.dict(os.environ, DIRTY):
            fixture = TmuxFixture()
        self.assertEqual(self.selecting(fixture.env), [])
        self.assertEqual(sandbox.violations(fixture.env), [])
        self.assertTrue(fixture.env["TMUX_TMPDIR"] != DIRTY["TMUX_TMPDIR"], "the fixture kept the caller's TMUX_TMPDIR")


class LuaRunnerTests(unittest.TestCase):
    def setUp(self):
        # Short and under /tmp so the sandbox fits a socket path wherever TMPDIR points.
        self.root = tempfile.mkdtemp(prefix="t-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.lua = runtime_config.executable_path(os.environ.get("LIBTMUX_TEST_LUA") or "lua")

    def run_lua(self, env, *arguments):
        return subprocess.run(
            [self.lua, *arguments], cwd=ROOT, env={"PATH": os.environ["PATH"], "LUA_PATH": LUA_PATH, **env},
            capture_output=True, text=True, timeout=10,
        )

    def test_the_unit_runner_refuses_before_it_loads_a_suite_and_names_no_value(self):
        refused = self.run_lua(DIRTY, "tests/run.lua", "query")
        self.assertEqual(refused.returncode, 2)
        for name in DECOYS:
            self.assertIn(f"{name} is set", refused.stderr)
        self.assertIn("TMUX_TMPDIR is not the sandbox directory of this run", refused.stderr)
        self.assertFalse("decoy" in refused.stdout + refused.stderr, "the refusal repeated an environment value")

    def test_the_unit_runner_gets_past_the_check_inside_a_sandbox(self):
        env = {}
        directory, _ = sandbox.prepare(env, roots=[self.root])
        self.addCleanup(sandbox.release, directory)
        # luaunit is not on this path: the runner must fail loading it, not refuse.
        proceeded = self.run_lua(env, "tests/run.lua", "query")
        self.assertEqual(proceeded.returncode, 1)
        self.assertIn("luaunit", proceeded.stderr)
        self.assertNotIn("refused to run", proceeded.stderr)

    def test_lua_and_python_apply_the_same_rules(self):
        valid = {}
        directory = sandbox.prepare(valid, roots=[self.root])[0]
        self.addCleanup(sandbox.release, directory)
        long = f"{directory}/{'x' * sandbox.MAX_BYTES}"
        cases = [
            valid,
            {**valid, "TMUX_TMPDIR": directory + "/"},
            {**valid, **DECOYS},
            {**valid, "TMUX": ""},
            {**valid, "LIBTMUX_SOCKET_NAME": "x"},
            DECOYS,
            {"TMUX_TMPDIR": "", sandbox.MARKER: ""},
            {**valid, "TMUX_TMPDIR": "relative/dir"},
            {**valid, "TMUX_TMPDIR": long, sandbox.MARKER: long},
            {**valid, "TMUX_TMPDIR": "/tmp"},
            {**valid, sandbox.MARKER: "/tmp/other"},
            {"TMUX_TMPDIR": directory},
        ]
        probe = 'print(table.concat(require("tests.support.sandbox").violations(os.getenv), "\\n"))'
        for case in cases:
            with self.subTest(selectors=sorted(name for name in case if sandbox.ambient(name))):
                lua = self.run_lua(case, "-e", probe)
                self.assertEqual(lua.returncode, 0, lua.stderr)
                self.assertEqual([line for line in lua.stdout.splitlines() if line], sandbox.violations(case))


if __name__ == "__main__":
    unittest.main()
