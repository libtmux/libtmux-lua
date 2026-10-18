"""Tie README examples, commands, and source links to files the gates exercise."""

import json
from pathlib import Path
import re

REPOSITORY = "https://github.com/libtmux/libtmux-lua"
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

    for readme in readmes(root):
        name = readme.relative_to(root).as_posix()
        text = readme.read_text()

        def fail(message):
            raise ValueError(f"Invalid README {name}: {message}")

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
