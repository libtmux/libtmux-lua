import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class DocsExportTest(unittest.TestCase):
    def test_public_modules_are_named_at_the_exported_table(self):
        modules = {
            "lua/libtmux/query.lua": "libtmux.query",
            "lua/libtmux/runtime/luv.lua": "libtmux.runtime.luv",
            "lua/libtmux/runtime/nvim.lua": "libtmux.runtime.nvim",
        }
        for relative, name in modules.items():
            lines = (ROOT / relative).read_text().splitlines()
            table = lines.index("local M = {}")
            self.assertEqual(f"---@class {name}", lines[table - 1], relative)

    def test_exporter_is_a_deterministic_json_entrypoint(self):
        exporter = ROOT / "scripts/export-docs"
        self.assertTrue(exporter.is_file())
        source = exporter.read_text()
        self.assertIn("sort_keys=True", source)
        self.assertIn('"schema": 1', source)
        self.assertIn('parser.add_argument("--source"', source)
        self.assertIn("shutil.copytree(SOURCE / \"lua\"", source)
        self.assertIn("if marker not in text", source)

    def test_committed_product_scaffolds_are_not_export_inputs(self):
        exporter = ROOT / "scripts/export-docs"
        if not exporter.is_file():
            self.fail("scripts/export-docs is missing")
        source = exporter.read_text()
        self.assertNotIn("packages/mcp", source)
        self.assertNotIn("packages/workspace", source)


if __name__ == "__main__":
    unittest.main()
