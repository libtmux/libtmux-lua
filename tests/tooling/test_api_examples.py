import copy
import json
from pathlib import Path
import shutil
import tempfile
import unittest

from scripts.api_examples import load_examples, public_symbols


ROOT = Path(__file__).resolve().parents[2]
TARGETS = {
    "libtmux.Runtime:connect", "libtmux.Server:snapshot", "libtmux.Snapshot.sessions",
    "libtmux.Snapshot.windows", "libtmux.Snapshot.panes", "libtmux.Server:new_session",
    "libtmux.Session:new_window", "libtmux.Server:query", "libtmux.Pane:send_text",
    "libtmux.Pane:send_keys", "libtmux.Pane:capture",
}


class CompleteApiExamplesTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="libtmux-lua-api-manifest-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        shutil.copytree(ROOT / "examples/api", self.root / "examples/api")
        self.path = self.root / "examples/api/manifest.json"
        self.manifest = json.loads(self.path.read_text())

    def save(self):
        self.path.write_text(json.dumps(self.manifest))

    def test_seven_complete_programs_cover_eleven_existing_targets(self):
        manifest = load_examples(self.root, TARGETS)
        self.assertEqual(len(manifest["examples"]), 7)
        self.assertEqual({symbol for example in manifest["examples"]
                          for symbol in example["symbols"]}, TARGETS)
        for example in manifest["examples"]:
            source = (self.root / example["file"]).read_text()
            self.assertIn('require("libtmux.runtime.luv")', source)
            self.assertIn("server:close():await()", source)
            self.assertNotIn('require("tests.', source)

    def test_receiver_and_collection_identities_match_native_annotations(self):
        declarations = [
            {"name": "libtmux.Server", "fields": [
                {"name": "snapshot", "view": "fun(self: libtmux.Server):libtmux.Request"},
            ]},
            {"name": "libtmux.Snapshot", "fields": [
                {"name": "sessions", "view": "libtmux.Selection<libtmux.SnapshotSession>"},
            ]},
        ]
        self.assertEqual(public_symbols(declarations), {
            "libtmux.Server", "libtmux.Server:snapshot", "libtmux.Snapshot", "libtmux.Snapshot.sessions",
        })

    def test_rejects_unknown_targets_and_duplicate_ownership(self):
        with self.assertRaisesRegex(ValueError, "unknown API target"):
            load_examples(self.root, TARGETS - {"libtmux.Pane:capture"})
        self.manifest["examples"][1]["symbols"].append("libtmux.Runtime:connect")
        self.save()
        with self.assertRaisesRegex(ValueError, "duplicate API target"):
            load_examples(self.root, TARGETS)

    def test_rejects_unsafe_missing_and_unlisted_files(self):
        original = copy.deepcopy(self.manifest)
        for path in ("../capture.lua", "/tmp/capture.lua", "examples/api/other.lua"):
            self.manifest = copy.deepcopy(original)
            self.manifest["examples"][0]["file"] = path
            self.save()
            with self.subTest(path=path), self.assertRaisesRegex(ValueError, "file path"):
                load_examples(self.root)
        self.manifest = original
        self.save()
        extra = self.root / "examples/api/extra.lua"
        extra.write_text('print("unlisted")\n')
        with self.assertRaisesRegex(ValueError, "unlisted Lua example"):
            load_examples(self.root)
        extra.unlink()
        (self.root / "examples/api/capture.lua").unlink()
        with self.assertRaisesRegex(ValueError, "missing or linked"):
            load_examples(self.root)

    def test_rejects_unknown_fields_unpinned_versions_and_missing_output(self):
        original = copy.deepcopy(self.manifest)
        mutations = [
            lambda m: m.update(extra=True),
            lambda m: m["setup"].update(lua="latest"),
            lambda m: m["setup"].update(luv="1.52"),
            lambda m: m["examples"][0].update(stdout=""),
            lambda m: m["examples"][0].update(description=""),
            lambda m: m["examples"][0].update(symbols=[]),
        ]
        for index, mutate in enumerate(mutations):
            self.manifest = copy.deepcopy(original)
            mutate(self.manifest)
            self.save()
            with self.subTest(index=index), self.assertRaises(ValueError):
                load_examples(self.root)

    def test_rejects_linked_and_normalized_source_bytes(self):
        program = self.root / "examples/api/connect.lua"
        program.unlink()
        program.symlink_to(ROOT / "examples/api/connect.lua")
        with self.assertRaisesRegex(ValueError, "missing or linked"):
            load_examples(self.root)
        program.unlink()
        program.write_bytes(b'print("changed")\r\n')
        with self.assertRaisesRegex(ValueError, "LF endings"):
            load_examples(self.root)


if __name__ == "__main__":
    unittest.main()
