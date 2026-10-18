import json
from pathlib import Path
import tempfile
import unittest

from scripts.readme_examples import check_readmes, console_steps


ROOT = Path(__file__).resolve().parents[2]
EXAMPLE = 'print("hello")\n'
FENCE = "```"
ROOT_README = f"""# Root

<!-- example: examples/hello.lua -->

{FENCE}lua
{EXAMPLE}{FENCE}

{FENCE}console
$ lua examples/hello.lua
{FENCE}

{FENCE}console
$ sh examples/api/run.sh examples/api/connect.lua
connected
{FENCE}

[Core](https://github.com/libtmux/libtmux-lua/tree/master/lua/libtmux)
"""
PACKAGE_README = f"""# Package

{FENCE}console
$ luarocks --local make \\
    rockspecs/libtmux-mcp-scm-1.rockspec
{FENCE}

{FENCE}console
$ lua -e 'print(require("libtmux_mcp")._VERSION)'
scm
{FENCE}
"""
FILES = {
    "README.md": ROOT_README,
    "packages/mcp/README.md": PACKAGE_README,
    "examples/hello.lua": EXAMPLE,
    "examples/api/run.sh": "#!/bin/sh\n",
    "examples/api/connect.lua": 'print("connected")\n',
    "examples/api/manifest.json": json.dumps(
        {"examples": [{"file": "examples/api/connect.lua", "stdout": "connected\n"}]}
    ),
    "rockspecs/libtmux-mcp-scm-1.rockspec": "package = 'libtmux-mcp'\n",
    "packages/mcp/lua/libtmux_mcp/init.lua": 'return { _VERSION = "scm" }\n',
    "lua/libtmux/init.lua": 'return { _VERSION = "1" }\n',
}


class ReadmeExamplesTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="libtmux-lua-readme-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.write(FILES)

    def write(self, files):
        for name, content in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)

    def rejects(self, pattern, **files):
        self.write(files)
        with self.assertRaisesRegex(ValueError, pattern):
            check_readmes(self.root)

    def test_repository_readmes_match_their_sources(self):
        check_readmes(ROOT)

    def test_clean_control_passes(self):
        check_readmes(self.root)

    def test_rejects_a_block_that_drifted_from_its_source(self):
        self.rejects("differs from examples/hello.lua", **{"examples/hello.lua": 'print("changed")\n'})

    def test_rejects_a_marker_without_a_source_file(self):
        (self.root / "examples/hello.lua").unlink()
        with self.assertRaisesRegex(ValueError, "example source is missing"):
            check_readmes(self.root)

    def test_package_readmes_need_a_marker_on_every_lua_block(self):
        unmarked = PACKAGE_README + f"\n{FENCE}lua\nprint(1)\n{FENCE}\n"
        self.rejects("lacks an example marker", **{"packages/mcp/README.md": unmarked})
        self.write({"README.md": ROOT_README + f"\n{FENCE}lua\nprint(1)\n{FENCE}\n"})
        self.write({"packages/mcp/README.md": PACKAGE_README})
        check_readmes(self.root)

    def test_rejects_a_command_naming_a_missing_file(self):
        (self.root / "rockspecs/libtmux-mcp-scm-1.rockspec").unlink()
        with self.assertRaisesRegex(ValueError, "missing file: rockspecs/libtmux-mcp-scm-1.rockspec"):
            check_readmes(self.root)
        self.rejects("missing file: examples/missing.lua", **{
            "README.md": ROOT_README.replace("lua examples/hello.lua", "lua examples/missing.lua"),
            "rockspecs/libtmux-mcp-scm-1.rockspec": "",
        })

    def test_rejects_output_that_differs_from_the_manifest(self):
        self.rejects("manifest for examples/api/connect.lua", **{
            "README.md": ROOT_README.replace("\nconnected\n", "\nconnected twice\n"),
        })

    def test_rejects_a_printed_version_that_differs_from_the_source(self):
        self.rejects("printed version differs from libtmux_mcp", **{
            "packages/mcp/lua/libtmux_mcp/init.lua": 'return { _VERSION = "1.0" }\n',
        })

    def test_rejects_a_source_link_to_a_missing_path(self):
        self.rejects("missing path: packages/gone", **{
            "README.md": ROOT_README + "[Gone](https://github.com/libtmux/libtmux-lua/tree/master/packages/gone)\n",
        })

    def test_console_steps_join_continuations_and_keep_output(self):
        block = "$ luarocks make \\\n    rockspecs/a.rockspec\n$ lua -e 'x'\nscm\n"
        self.assertEqual(console_steps(block), [
            ("luarocks make rockspecs/a.rockspec", []),
            ("lua -e 'x'", ["scm"]),
        ])


if __name__ == "__main__":
    unittest.main()
