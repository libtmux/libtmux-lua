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
EXCERPT = re.compile(r"<!-- excerpt: (\S+) -->\n\n```lua\n(.*?)```", re.DOTALL)
LUA_FENCE = re.compile(r"^```lua$", re.MULTILINE)
CONSOLE = re.compile(r"```console\n(.*?)```", re.DOTALL)
SOURCE_LINK = re.compile(re.escape(REPOSITORY) + r"/(?:tree|blob)/master/([\w./-]+)")
SOURCE_PATH = re.compile(r"\b(?:rockspecs|examples)/[\w./-]*\w")
RUN_EXAMPLE = re.compile(r"\bexamples/api/run\.sh (examples/api/\w+\.lua)\b")
PRINT_VERSION = re.compile(r"""print\(require\("([\w.]+)"\)\._VERSION\)""")
VERSION = re.compile(r'^\s*(?:return\s*\{\s*)?_VERSION\s*=\s*"([^"]+)"', re.MULTILINE)
FENCED = re.compile(r"^```.*?^```[ \t]*$", re.DOTALL | re.MULTILINE)
HEADING = re.compile(r"^(#{1,6})[ \t]+(.+?)[ \t]*$", re.MULTILINE)
DEFINITION = re.compile(r"^\[([^\]]+)\]:[ \t]+\S+[ \t]*$", re.MULTILINE)
REFERENCE_USE = re.compile(r"\[([^\]]+)\]\[([^\]]+)\]")
LINK = re.compile(r"\[([^\]]+)\](?:\[[^\]]*\]|\([^)]*\))")
# One list item or paragraph reads in about three lines of an 80-column terminal.
PROSE_LIMIT = 240


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


def dedent(lines):
    """Strip the indentation shared by the non-blank lines."""
    widths = [len(line) - len(line.lstrip()) for line in lines if line.strip()]
    cut = min(widths, default=0)
    return [line[cut:] if line.strip() else "" for line in lines]


def is_excerpt(block, source):
    """True when the block is a run of consecutive source lines, up to shared indentation."""
    wanted = dedent(block.rstrip("\n").split("\n"))
    lines = source.split("\n")
    return any(
        dedent(lines[start:start + len(wanted)]) == wanted
        for start in range(len(lines) - len(wanted) + 1)
    )


def prose_blocks(text):
    """Yield each paragraph and list item outside code, tables, headings and HTML."""
    text = FENCED.sub("", text)
    for chunk in re.split(r"\n\s*\n", text):
        lines = chunk.strip("\n").split("\n")
        if not lines or not lines[0].strip():
            continue
        if lines[0].startswith(("#", "|", "<", "**Contents**")) or DEFINITION.match(lines[0]):
            continue
        items, current = [], []
        for line in lines:
            if re.match(r"^(?:[-*]|\d+\.)\s", line) and current:
                items.append(current)
                current = []
            current.append(line)
        items.append(current)
        for item in items:
            yield " ".join(part.strip() for part in item)


def rendered(markdown):
    """The text a reader sees: link targets and code ticks removed."""
    text = LINK.sub(r"\1", markdown).replace("`", "")
    return re.sub(r"\s+", " ", text).strip()


def check_structure(text, fail):
    """Require a Quick start first, the closing sections, short prose and defined links."""
    headings = [title for level, title in HEADING.findall(FENCED.sub("", text)) if level == "##"]
    if not headings or headings[0] != "Quick start":
        fail("the first section must be Quick start")
    for title in ("What it leaves out", "Support and status"):
        if title not in headings:
            fail(f"missing the {title} section")
    for block in prose_blocks(text):
        if len(rendered(block)) > PROSE_LIMIT:
            fail(f"prose over {PROSE_LIMIT} characters, which reads as a wall: {block[:48]}...")
    defined = set(DEFINITION.findall(text))
    for _, label in REFERENCE_USE.findall(FENCED.sub("", text)):
        if label not in defined:
            fail(f"link reference is not defined: [{label}]")


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
        marked, excerpts = EXAMPLE.findall(text), EXCERPT.findall(text)
        if len(LUA_FENCE.findall(text)) != len(marked) + len(excerpts):
            fail("a Lua block lacks an example or excerpt marker, so nothing runs it")
        for path, body in marked:
            source = root / path
            if not source.is_file():
                fail(f"example source is missing: {path}")
            if body != source.read_text():
                fail(f"Lua block differs from {path}")
        for path, body in excerpts:
            source = root / path
            if not source.is_file():
                fail(f"excerpt source is missing: {path}")
            if not is_excerpt(body, source.read_text()):
                fail(f"Lua block is not a run of lines from {path}")
        check_structure(text, fail)

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
