"""Collect native lifecycle programs and unchanged examples with outer cleanup."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class OwnershipTests(unittest.TestCase):
    def run_case(self, name, source, *arguments):
        original = (ROOT / source).read_bytes()
        with tempfile.TemporaryDirectory(prefix="libtmux-lua-evidence-") as directory:
            command = [sys.executable, "tests/support/ownership_fixture.py", name, source,
                       "--evidence", directory, *arguments]
            result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=12)
            receipt = json.loads((Path(directory) / name / "receipt.json").read_text())
            logs = "\n".join(path.read_text() for path in (Path(directory) / name).glob("*.log"))
            self.assertEqual(result.returncode, 0, result.stderr + logs)
            self.assertTrue(receipt["root_removed"])
            self.assertTrue(receipt["parent_environment_unchanged"])
            events = receipt["events"]
            self.assertEqual(events[-1]["event"], "removed_root")
            accepted = {event["pid"] for event in events if event["event"] == "accepted"}
            exited = {event["pid"] for event in events
                      if event["event"] == "observed_exit" and event["exited"]}
            self.assertEqual(accepted, exited)
            self.assertEqual((ROOT / source).read_bytes(), original)
            return receipt

    def test_native_ownership_and_failure_programs(self):
        for name in ("ownership", "ownership_failures", "ownership_edges", "acquisition",
                     "receipt_failures", "server_lifecycle", "startup_failures", "legacy_environment",
                     "replacement_cleanup", "discovery_environment", "startup_handoff"):
            with self.subTest(program=name):
                receipt = self.run_case(name, f"tests/integration/{name}.lua")
                expected = "fixture\nunknown-receipt\n" if name == "receipt_failures" else "fixture\n"
                self.assertEqual(receipt["remaining_sessions"], expected)

    def test_exact_owned_example_for_both_selectors(self):
        for named in (False, True):
            with self.subTest(named=named):
                receipt = self.run_case("example", "examples/owned_session.lua",
                                        *(["--named"] if named else []))
                self.assertEqual(receipt["remaining_sessions"], "fixture\n")

    def test_unchanged_example_body_failure_timeout_and_worker_death(self):
        for mode in ("body-fail", "timeout", "crash"):
            with self.subTest(mode=mode):
                self.run_case(mode, "examples/owned_session.lua", "--worker-mode", mode,
                              "--timeout", "0.8")

    def test_neovim_ownership_and_cancellation(self):
        nvim = os.environ.get("LIBTMUX_TEST_NVIM")
        if not nvim:
            self.skipTest("pass LIBTMUX_TEST_NVIM for the installed Neovim host lane")
        receipt = self.run_case("nvim", "tests/integration/ownership_nvim.lua", "--nvim", nvim)
        self.assertEqual(receipt["remaining_sessions"], "fixture\n")
