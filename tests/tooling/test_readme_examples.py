import json
from pathlib import Path
import struct
import tempfile
import unittest

from scripts.readme_examples import check_readmes, console_steps


ROOT = Path(__file__).resolve().parents[2]
EXAMPLE = 'print("hello")\n'
FENCE = "```"
PNG = b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", 512, 512) + bytes(5)
LOGO = """<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="assets/logo.svg" type="image/svg+xml">
    <img src="assets/logo.png" width="128" height="128" alt="{alt}">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

"""
SECTIONS = """## What it leaves out

- **A default server.** The caller names one.

## Support and status

- **Versions.** Pin an exact version.
"""
ROOT_README = LOGO.format(alt="libtmux for Lua") + f"""# Root

</div>

## Quick start

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

{SECTIONS}"""
PACKAGE_README = LOGO.format(alt="libtmux for Lua MCP") + f"""# Package

</div>

## Quick start

{FENCE}console
$ luarocks --local make \\
    rockspecs/libtmux-mcp-scm-1.rockspec
{FENCE}

{FENCE}console
$ lua -e 'print(require("libtmux_mcp")._VERSION)'
scm
{FENCE}

{SECTIONS}"""
FILES = {
    "README.md": ROOT_README,
    "lua/libtmux/README.md": ROOT_README.replace("# Root", "# Core"),
    "packages/mcp/README.md": PACKAGE_README,
    "assets/logo.svg": "<svg>library</svg>",
    "assets/logo.png": PNG,
    "lua/libtmux/assets/logo.svg": "<svg>library</svg>",
    "lua/libtmux/assets/logo.png": PNG,
    "packages/mcp/assets/logo.svg": "<svg>mcp</svg>",
    "packages/mcp/assets/logo.png": PNG,
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
            path.write_bytes(content) if isinstance(content, bytes) else path.write_text(content)

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

    def test_every_readme_needs_a_marker_on_every_lua_block(self):
        unmarked = f"\n{FENCE}lua\nprint(1)\n{FENCE}\n"
        self.rejects("lacks an example or excerpt marker", **{
            "packages/mcp/README.md": PACKAGE_README + unmarked,
        })
        self.write({"packages/mcp/README.md": PACKAGE_README})
        self.rejects("lacks an example or excerpt marker", **{"README.md": ROOT_README + unmarked})

    def test_accepts_an_excerpt_indented_in_its_source(self):
        source = 'local a = 1\nif a then\n    print("a")\n\n    print("b")\nend\n'
        excerpt = f'\n<!-- excerpt: examples/long.lua -->\n\n{FENCE}lua\nprint("a")\n\nprint("b")\n{FENCE}\n'
        self.write({"examples/long.lua": source, "README.md": ROOT_README + excerpt})
        check_readmes(self.root)

    def test_rejects_an_excerpt_that_drifted_or_skips_lines(self):
        source = 'local a = 1\nprint("a")\nprint("b")\nprint("c")\n'
        self.write({"examples/long.lua": source})
        marker = "<!-- excerpt: examples/long.lua -->"
        clean = f'\n{marker}\n\n{FENCE}lua\nprint("a")\nprint("b")\n{FENCE}\n'
        self.write({"README.md": ROOT_README + clean})
        check_readmes(self.root)
        changed = clean.replace('print("b")', 'print("changed")')
        skipped = f'\n{marker}\n\n{FENCE}lua\nprint("a")\nprint("c")\n{FENCE}\n'
        for body in (changed, skipped):
            with self.subTest(body=body):
                self.rejects("not a run of lines from examples/long.lua", **{"README.md": ROOT_README + body})
        self.write({"README.md": ROOT_README + clean})
        (self.root / "examples/long.lua").unlink()
        with self.assertRaisesRegex(ValueError, "excerpt source is missing"):
            check_readmes(self.root)

    def test_rejects_a_readme_without_the_expected_sections(self):
        self.rejects("first section must be Quick start", **{
            "README.md": ROOT_README.replace("## Quick start", "## Install"),
        })
        self.write({"README.md": ROOT_README})
        for title in ("What it leaves out", "Support and status"):
            with self.subTest(title=title):
                self.rejects(f"missing the {title} section", **{
                    "packages/mcp/README.md": PACKAGE_README.replace(f"## {title}", "## Elsewhere"),
                })
                self.write({"packages/mcp/README.md": PACKAGE_README})

    def test_rejects_prose_that_reads_as_a_wall(self):
        wall = " ".join(["word"] * 60)
        self.rejects("reads as a wall", **{"README.md": ROOT_README + f"\n{wall}\n"})
        self.write({"README.md": ROOT_README + f"\n- **Lead.** {wall}\n"})
        with self.assertRaisesRegex(ValueError, "reads as a wall"):
            check_readmes(self.root)
        # Link targets, code and tables do not count toward the length.
        target = "https://example.test/" + "x" * 300
        table = "| " + " | ".join(["cell " * 20] * 3) + " |\n| --- | --- | --- |"
        quiet = f"\n[short]({target}) and [`name`][ref]\n\n{table}\n\n[ref]: {target}\n"
        self.write({"README.md": ROOT_README + quiet})
        check_readmes(self.root)

    def test_rejects_a_reference_link_without_a_definition(self):
        self.rejects(r"link reference is not defined: \[ref-missing\]", **{
            "README.md": ROOT_README + "\nSee [`Server`][ref-missing].\n",
        })
        self.write({"README.md": ROOT_README + "\nSee [`Server`][ref-server].\n\n[ref-server]: https://example.test/\n"})
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

    def test_rejects_a_readme_that_does_not_open_with_the_logo_block(self):
        body = PACKAGE_README.removeprefix(LOGO.format(alt="libtmux for Lua MCP"))
        self.rejects("must open with the centered logo block", **{"packages/mcp/README.md": body})
        self.rejects("must open with the centered logo block", **{
            "packages/mcp/README.md": "# Title\n\n" + PACKAGE_README,
        })

    def test_rejects_a_paragraph_wrapper_and_a_changed_image_tag(self):
        wrappers = [
            ("div align", "p align"),
            ("</div>\n<!-- /libtmux-logo", "</p>\n<!-- /libtmux-logo"),
            ('width="128"', 'width="64"'),
            ("assets/logo.png", "https://example.test/logo.png"),
        ]
        for old, new in wrappers:
            with self.subTest(old=old):
                self.rejects("must open with the centered logo block", **{
                    "packages/mcp/README.md": PACKAGE_README.replace(old, new, 1),
                })
                self.write({"packages/mcp/README.md": PACKAGE_README})

    def test_rejects_the_wrong_alt_text_for_a_product(self):
        self.rejects('alt text must be "libtmux for Lua MCP"', **{
            "packages/mcp/README.md": PACKAGE_README.replace("libtmux for Lua MCP", "libtmux for Lua"),
        })

    def test_rejects_missing_or_malformed_logo_assets(self):
        broken = {
            "assets/logo.svg is missing": {"packages/mcp/assets/logo.svg": "not vector art"},
            "512 x 512": {"packages/mcp/assets/logo.png": PNG.replace(struct.pack(">I", 512), struct.pack(">I", 256), 1)},
        }
        for pattern, files in broken.items():
            with self.subTest(pattern=pattern):
                self.rejects(pattern, **files)
                self.write(FILES)
        (self.root / "packages/mcp/assets/logo.png").unlink()
        with self.assertRaisesRegex(ValueError, "512 x 512"):
            check_readmes(self.root)

    def test_rejects_art_shared_across_products_or_split_within_one(self):
        self.rejects('logo art belongs to "libtmux for Lua"', **{"packages/mcp/assets/logo.svg": "<svg>library</svg>"})
        self.write(FILES)
        self.rejects('differs from the other "libtmux for Lua" README', **{
            "lua/libtmux/assets/logo.svg": "<svg>another</svg>",
        })

    def test_console_steps_join_continuations_and_keep_output(self):
        block = "$ luarocks make \\\n    rockspecs/a.rockspec\n$ lua -e 'x'\nscm\n"
        self.assertEqual(console_steps(block), [
            ("luarocks make rockspecs/a.rockspec", []),
            ("lua -e 'x'", ["scm"]),
        ])


if __name__ == "__main__":
    unittest.main()
