"""Compare bounded native query plans with complete local snapshot evaluation."""

import os
from pathlib import Path
import shutil
import subprocess
import unittest

from tests.support.tmux_fixture import TmuxFixture

ROOT = Path(__file__).resolve().parents[2]


class QueryPlannerTests(unittest.TestCase):
    def test_native_candidates_preserve_local_predicates_and_relations(self):
        with TmuxFixture() as fixture:
            fixture.run("split-window", "-d", "-h", "-t", "fixture:0", "exec /bin/cat")
            fixture.run("split-window", "-d", "-v", "-t", "fixture:0.1", "exec /bin/cat")
            panes = fixture.run("list-panes", "-t", "fixture:0", "-F", "#{pane_id}").stdout.splitlines()
            for pane, title in zip(panes, (panes[0], "needle", "other")):
                fixture.run("select-pane", "-t", pane, "-T", title)
            fixture.run("link-window", "-s", "fixture:0", "-t", "fixture:9")
            fixture.run("set-buffer", "-b", "query-buffer", "bytes")
            env = dict(fixture.env, TMUX_BIN=shutil.which(fixture.binary),
                       TMUX_SOCKET=str(fixture.socket))
            lua = os.environ.get("LIBTMUX_TEST_LUA") or shutil.which("lua")
            self.assertIsNotNone(lua, "missing selected Lua executable")
            result = subprocess.run(
                [lua, "tests/integration/query_planner.lua"], cwd=ROOT, env=env,
                capture_output=True, timeout=0.8,
            )
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
            self.assertIn(b"live query planner PASS", result.stdout)
            self.assertEqual(list(fixture.path.glob("libtmux-lua-pin-*")), [])
