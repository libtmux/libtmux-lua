"""Stable entity mutations and native topology side effects on owned servers."""

import os
from pathlib import Path
import shutil
import subprocess
import unittest

from tests.support.tmux_fixture import TmuxFixture

ROOT = Path(__file__).resolve().parents[2]


class TopologyTests(unittest.TestCase):
    def run_case(self, mode):
        for host in ("luv", "nvim"):
            fixture = TmuxFixture()
            fixture.env.update(LC_ALL="C", LANG="C")
            with self.subTest(host=host), fixture:
                version = fixture.run("display-message", "-p", "#{version}").stdout.strip()
                env = dict(fixture.env, TMUX_BIN=shutil.which(fixture.binary),
                           TMUX_SOCKET=str(fixture.socket), LIBTMUX_TOPOLOGY_CASE=mode,
                           TMUX_DAEMON_VERSION=version)
                if host == "luv":
                    command = [os.environ.get("LIBTMUX_TEST_LUA") or shutil.which("lua"),
                               "tests/integration/topology.lua"]
                else:
                    env.pop("LUA_CPATH", None)
                    command = [os.environ.get("LIBTMUX_TEST_NVIM") or shutil.which("nvim"),
                               "--headless", "-u", "NONE", "-i", "NONE", "-c",
                               "lua dofile('tests/integration/topology.lua')"]
                result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True,
                                        timeout=0.8)
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
                self.assertIn(f"public topology {mode} PASS".encode(), result.stdout)
                self.assertEqual(list(fixture.path.glob("libtmux-lua-pin-*")), [])
                self.assertEqual(fixture.run("list-clients").stdout, "")
                self.assertEqual(fixture.run("has-session", "-t", "$0").returncode, 0)

    def test_pane_selection_title_and_zoom(self):
        self.run_case("pane_selection")

    def test_pane_swap_identity_selection_and_missing_target(self):
        self.run_case("pane_swap")

    def test_session_window_rename_and_kill_scope(self):
        self.run_case("rename_kill")

    def test_session_navigation_and_renumber(self):
        self.run_case("navigation")

    def test_window_dimensions_layout_and_error_side_effect(self):
        self.run_case("layout")

    def test_link_identity_selection_noop_unlink_and_index_reuse(self):
        self.run_case("link_identity")

    def test_link_insertion_move_replacement_and_stale_destination(self):
        self.run_case("link_placement")

    def test_link_swap_selection_and_stale_handles(self):
        self.run_case("link_swap")

    def test_link_group_propagation_and_cross_group_refusal(self):
        self.run_case("link_group")

    def test_link_cross_session_move_swap_and_free_index(self):
        self.run_case("link_cross_session")
