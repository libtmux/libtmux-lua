"""Stable entity mutations and native topology side effects on owned servers."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

from tests.support.tmux_fixture import TmuxFixture

ROOT = Path(__file__).resolve().parents[2]


class TopologyTests(unittest.TestCase):
    def run_case(self, mode, automatic=False):
        for host in ("luv", "nvim"):
            fixture = TmuxFixture()
            fixture.env.update(LC_ALL="C", LANG="C")
            with self.subTest(host=host), fixture:
                version = fixture.run("display-message", "-p", "#{version}").stdout.strip()
                env = dict(fixture.env, TMUX_BIN=shutil.which(fixture.binary),
                           TMUX_SOCKET=str(fixture.socket), LIBTMUX_TOPOLOGY_CASE=mode,
                           TMUX_DAEMON_VERSION=version,
                           LIBTMUX_BREAK_AUTOMATIC="1" if automatic else "0")
                if mode == "window_respawn":
                    report = fixture.path / "respawn.bin"
                    script = fixture.path / "respawn.py"
                    script.write_text(
                        "import os,subprocess,sys\n"
                        "from pathlib import Path\n"
                        "binary,socket,report=sys.argv[1:4]\n"
                        "Path(report).write_bytes(b'\\0'.join(x.encode() for x in [os.environ['SCOPE'],os.environ['VALUE'],*sys.argv[4:]]))\n"
                        "subprocess.run([binary,'-N','-S',socket,'wait-for','-S','window-ready'],check=True,timeout=.8)\n"
                        "os.execl('/bin/cat','cat')\n"
                    )
                    env.update(LIBTMUX_RESPAWN_SCRIPT=str(script), LIBTMUX_RESPAWN_REPORT=str(report),
                               LIBTMUX_TEST_PYTHON=sys.executable, LIBTMUX_TEST_DIRECTORY=str(fixture.path))
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
                if mode == "window_respawn":
                    self.assertEqual(report.read_bytes(),
                                     "target\0literal#{pid};\0literal;$#{}\\\"\0\0~$HOME'\n #literal\r\tλ".encode())
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

    def test_window_respawn_launch_context_and_pane_identity(self):
        self.run_case("window_respawn")

    def test_window_respawn_refuses_invalid_and_replaced_context(self):
        self.run_case("window_respawn_stale")

    def test_pane_move_preserves_identity_geometry_and_destroys_empty_window(self):
        self.run_case("pane_move")

    def test_pane_move_selection_context_and_stale_membership(self):
        self.run_case("pane_move_context")

    def test_pane_break_singleton_named(self):
        for automatic in (False, True):
            self.run_case("break_single_named", automatic)

    def test_pane_break_singleton_default_name(self):
        for automatic in (False, True):
            self.run_case("break_single_default", automatic)

    def test_pane_break_multiple_named(self):
        for automatic in (False, True):
            self.run_case("break_multi_named", automatic)

    def test_pane_break_multiple_default_name(self):
        for automatic in (False, True):
            self.run_case("break_multi_default", automatic)

    def test_pane_break_occupied_destination_and_stale_membership(self):
        self.run_case("break_refusal")
