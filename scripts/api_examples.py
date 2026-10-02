"""Validate source-owned, complete API examples before export or execution."""

import json
from pathlib import Path
import re


def public_symbols(declarations):
    symbols = set()
    for declaration in declarations:
        name = declaration["name"]
        symbols.add(name)
        for field in declaration.get("fields", []):
            if field.get("name"):
                receiver = re.search(r"\bself\s*:", field.get("view", ""))
                separator = ":" if receiver else "."
                symbols.add(name + separator + field["name"])
    return symbols


def load_examples(root, symbols=None):
    root = Path(root).resolve()
    manifest = json.loads((root / "examples/api/manifest.json").read_text())

    def require(condition, message):
        if not condition:
            raise ValueError("Invalid complete API examples: " + message)

    def keys(value, expected):
        require(isinstance(value, dict) and set(value) == set(expected),
                "unexpected or missing manifest fields")

    def file(path, expected):
        require(path == expected, "unexpected example file path")
        candidate = root / path
        require(candidate.is_file() and not candidate.is_symlink(), "example file is missing or linked")
        require(candidate.resolve().is_relative_to(root), "example file escapes source")
        content = candidate.read_bytes().decode("utf-8")
        require(bool(content.strip()) and content.endswith("\n") and "\r" not in content,
                "example files must contain complete UTF-8 text with LF endings")

    keys(manifest, ("schema", "setup", "examples"))
    require(type(manifest["schema"]) is int and manifest["schema"] == 1, "unsupported schema")
    setup = manifest["setup"]
    keys(setup, ("lua", "luv", "launcher"))
    require(isinstance(setup["lua"], str) and re.fullmatch(r"5\.[1-5]\.\d+", setup["lua"]),
            "Lua version must be pinned")
    require(isinstance(setup["luv"], str) and re.fullmatch(r"\d+\.\d+\.\d+-\d+", setup["luv"]),
            "luv version must be pinned")
    file(setup["launcher"], "examples/api/run.sh")
    require(isinstance(manifest["examples"], list) and bool(manifest["examples"]), "no examples")
    ids, targets = set(), set()
    for example in manifest["examples"]:
        keys(example, ("id", "symbols", "file", "description", "stdout"))
        name = example["id"]
        require(isinstance(name, str) and re.fullmatch(r"[a-z][a-z_]*", name), "invalid example id")
        require(name not in ids, "duplicate example id")
        ids.add(name)
        file(example["file"], f"examples/api/{name}.lua")
        require(isinstance(example["description"], str) and bool(example["description"].strip()),
                "missing task description")
        require(isinstance(example["stdout"], str) and bool(example["stdout"].strip())
                and example["stdout"].endswith("\n"), "missing expected output")
        require(isinstance(example["symbols"], list) and bool(example["symbols"]), "missing API targets")
        for symbol in example["symbols"]:
            require(isinstance(symbol, str) and re.fullmatch(r"libtmux\.[\w.]+[:.]\w+", symbol),
                    "invalid API target")
            require(symbol not in targets, "duplicate API target")
            require(symbols is None or symbol in symbols, "unknown API target: " + symbol)
            targets.add(symbol)
    actual = {str(path.relative_to(root)) for path in (root / "examples/api").glob("*.lua")}
    require(actual == {example["file"] for example in manifest["examples"]}, "unlisted Lua example")
    return manifest
