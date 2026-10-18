"""Tie README examples, commands, and source links to files the gates exercise."""

import hashlib
import json
from pathlib import Path
import re
import struct

REPOSITORY = "https://github.com/libtmux/libtmux-lua"
LOGO = re.compile(
    r'\A<!-- libtmux-logo -->\n<div align="center">\n  <picture>\n'
    r'    <source srcset="assets/logo\.svg" type="image/svg\+xml">\n'
    r'    <img src="assets/logo\.png" width="128" height="128" alt="([^"]*)">\n'
    r'  </picture>\n</div>\n<!-- /libtmux-logo -->\n\n<div align="center">\n\n# '
)
LOGO_ALT = {"packages/mcp": "libtmux for Lua MCP", "packages/workspace": "libtmux for Lua workspace"}
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
EXAMPLE = re.compile(r"<!-- example: (\S+) -->\n\n```lua\n(.*?)```", re.DOTALL)
LUA_FENCE = re.compile(r"^```lua$", re.MULTILINE)
CONSOLE = re.compile(r"```console\n(.*?)```", re.DOTALL)
SOURCE_LINK = re.compile(re.escape(REPOSITORY) + r"/(?:tree|blob)/master/([\w./-]+)")
SOURCE_PATH = re.compile(r"\b(?:rockspecs|examples)/[\w./-]*\w")
RUN_EXAMPLE = re.compile(r"\bexamples/api/run\.sh (examples/api/\w+\.lua)\b")
PRINT_VERSION = re.compile(r"""print\(require\("([\w.]+)"\)\._VERSION\)""")
VERSION = re.compile(r'^\s*(?:return\s*\{\s*)?_VERSION\s*=\s*"([^"]+)"', re.MULTILINE)


def readmes(root):
    candidates = [root / "README.md", root / "lua/libtmux/README.md", *sorted(root.glob("packages/*/README.md"))]
    return [path for path in candidates if path.is_file()]


def check_logo(root, readme, text, art, fail):
    """Require the centered logo block and the package's own art beside the README."""
    match = LOGO.match(text)
    if not match:
        fail("must open with the centered logo block, then a centered title")
    expected = LOGO_ALT.get(readme.parent.relative_to(root).as_posix(), "libtmux for Lua")
    if match.group(1) != expected:
        fail(f'logo alt text must be "{expected}"')
    svg, png = readme.parent / "assets/logo.svg", readme.parent / "assets/logo.png"
    if not svg.is_file() or b"<svg" not in svg.read_bytes():
        fail("assets/logo.svg is missing or is not SVG")
    header = png.read_bytes()[:24] if png.is_file() else b""
    if header[:8] != PNG_SIGNATURE or header[12:16] != b"IHDR" or struct.unpack(">II", header[16:24]) != (512, 512):
        fail("assets/logo.png is missing or is not a 512 x 512 PNG")
    # Art is keyed both ways: one product, one artwork, and no artwork shared across products.
    digest = hashlib.sha256(svg.read_bytes()).hexdigest()
    if art.setdefault(digest, expected) != expected:
        fail(f'logo art belongs to "{art[digest]}"')
    if art.setdefault(expected, digest) != digest:
        fail(f'logo art differs from the other "{expected}" README')


def console_steps(block):
    """Split a console block into (command, output lines) pairs."""
    steps = []
    for line in block.splitlines():
        if line.startswith("$ "):
            steps.append([line[2:], []])
        elif steps and steps[-1][0].endswith("\\") and not steps[-1][1]:
            steps[-1][0] = steps[-1][0][:-1].rstrip() + " " + line.strip()
        elif steps:
            steps[-1][1].append(line)
    return [(command, output) for command, output in steps]


def module_version(root, module):
    relative = module.replace(".", "/")
    for base in (root / "lua", *sorted(root.glob("packages/*/lua"))):
        for candidate in (base / f"{relative}.lua", base / relative / "init.lua"):
            if candidate.is_file():
                found = VERSION.search(candidate.read_text())
                return found.group(1) if found else None
    return None


def check_readmes(root):
    """Raise ValueError when a README quotes, runs, or links something that differs from the source."""
    root = Path(root).resolve()
    manifest_path = root / "examples/api/manifest.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.is_file() else {"examples": []}
    outputs = {example["file"]: example["stdout"] for example in manifest["examples"]}

    art = {}
    for readme in readmes(root):
        name = readme.relative_to(root).as_posix()
        text = readme.read_text()

        def fail(message):
            raise ValueError(f"Invalid README {name}: {message}")

        check_logo(root, readme, text, art, fail)
        marked = EXAMPLE.findall(text)
        if name != "README.md" and len(LUA_FENCE.findall(text)) != len(marked):
            fail("a Lua block lacks an example marker, so nothing runs it")
        for path, body in marked:
            source = root / path
            if not source.is_file():
                fail(f"example source is missing: {path}")
            if body != source.read_text():
                fail(f"Lua block differs from {path}")

        for block in CONSOLE.findall(text):
            for command, output in console_steps(block):
                for path in SOURCE_PATH.findall(command):
                    if not (root / path).exists():
                        fail(f"command names a missing file: {path}")
                program = RUN_EXAMPLE.search(command)
                if program and "\n".join(output) + "\n" != outputs.get(program.group(1)):
                    fail(f"output differs from the manifest for {program.group(1)}")
                printed = PRINT_VERSION.search(command)
                if printed and output != [module_version(root, printed.group(1))]:
                    fail(f"printed version differs from {printed.group(1)} source")

        for path in SOURCE_LINK.findall(text):
            if not (root / path.rstrip(".")).exists():
                fail(f"source link names a missing path: {path}")
