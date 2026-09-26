import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class DocsExportTest(unittest.TestCase):
    def test_export_annotations_are_isolated_from_runtime_modules(self):
        modules = {
            "lua/libtmux/query.lua": "libtmux.query",
            "lua/libtmux/runtime/luv.lua": "libtmux.runtime.luv",
            "lua/libtmux/runtime/nvim.lua": "libtmux.runtime.nvim",
        }
        exporter = (ROOT / "scripts/export-docs").read_text()
        for relative, name in modules.items():
            self.assertNotIn(f"---@class {name}", (ROOT / relative).read_text(), relative)
            self.assertIn(f'"{relative.removeprefix("lua/")}": "{name}"', exporter)

    def test_exporter_is_a_deterministic_json_entrypoint(self):
        exporter = ROOT / "scripts/export-docs"
        self.assertTrue(exporter.is_file())
        source = exporter.read_text()
        self.assertIn("sort_keys=True", source)
        self.assertIn('"schema": 1', source)
        self.assertIn('parser.add_argument("--source"', source)
        self.assertIn("shutil.copytree(SOURCE / \"lua\"", source)
        self.assertIn("if marker not in text", source)

    def test_every_handle_class_is_a_required_export(self):
        entity = (ROOT / "lua/libtmux/_internal/entity.lua").read_text()
        classes = re.findall(r"^---@class (libtmux\.\w+)", entity, re.MULTILINE)
        self.assertIn("libtmux.Session", classes)
        exporter = (ROOT / "scripts/export-docs").read_text()
        self.assertEqual([name for name in classes if f'"{name}"' not in exporter], [])

    def test_committed_product_scaffolds_are_not_export_inputs(self):
        exporter = ROOT / "scripts/export-docs"
        if not exporter.is_file():
            self.fail("scripts/export-docs is missing")
        source = exporter.read_text()
        self.assertNotIn("packages/mcp", source)
        self.assertNotIn("packages/workspace", source)


if __name__ == "__main__":
    unittest.main()
