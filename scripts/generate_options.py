"""Generate private Lua metadata and reference from the pinned tmux option catalog."""

import argparse
import ast
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

if __package__:
    from .generate_fields import lua
else:
    from generate_fields import lua

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "data/tmux-options.json"

PINS = {
    "3.2a": "3b929f332aafa7f1080eacc31feb11ffbb1d1841",
    "3.3": "87fe00e8b44901240fc22d7120c1b31e4331f6f5",
    "3.3a": "0b355ae8114511e1ff6359272b164f1cdf718e80",
    "3.4": "9ae69c3795ab5ef6b4d760f6398cd9281151f632",
    "3.5": "ac44566c9c7e3e94d23be6def4c7ae83472543f5",
    "3.5a": "549c35b06165f6ae023115eb76f83f2cbf945395",
    "3.6": "0dac7fe434d029a4f0b819cba8eb7963df291990",
    "3.6a": "cc117b5048f77a4842820f8ebbe3a86e5c077224",
    "3.6b": "0623d1e968423ad0c192e0d8debf1258671063d5",
    "3.7": "81f88f8517c9fc5371b56cf117530c6b477c96ac",
    "3.7a": "0e418b62d259ce8da8970f75732cc6632ee4c3a0",
    "3.7b": "e802909de06012a4df6209d55e86487c56223163",
    "3.7c": "e476c1230b958df0cb12977517d24b3dc931375b",
}
SCOPE = {"SERVER": 1, "SESSION": 2, "WINDOW": 4, "PANE": 8}
FLAGS = {"IS_ARRAY": 1, "IS_HOOK": 2, "IS_STYLE": 4}
TYPES = {"STRING", "NUMBER", "KEY", "COLOUR", "FLAG", "CHOICE", "COMMAND"}
# Supported Linux/macOS ABIs have 32-bit int and 16-bit short. Preserve the
# symbolic expression as well as this explicit target-ABI interpretation.
CONSTANTS = {"INT_MAX": 2147483647, "UINT_MAX": 4294967295,
             "SHRT_MAX": 32767, "USHRT_MAX": 65535}
KNOWN_FIELDS = {"name", "type", "scope", "flags", "minimum", "maximum",
                "choices", "separator", "pattern", "unit", "default_arr",
                "default_num", "default_str", "text"}
TOKEN = re.compile(r'\s+|/\*[\s\S]*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|'
                   r"'(?:\\.|[^'\\])*'|[A-Za-z_][A-Za-z_0-9]*|"
                   r'0[xX][0-9A-Fa-f]+|[0-9]+|[^\w\s]')


def tokens(text):
    result = []
    end = 0
    for match in TOKEN.finditer(text):
        assert match.start() == end, "unrecognized C token"
        end = match.end()
        value = match.group()
        if value.isspace() or value.startswith(("/*", "//")):
            continue
        result.append(value)
    assert end == len(text)
    return result


def groups(items):
    result, group, nesting = [], [], []
    pairs = {"}": "{", ")": "(", "]": "["}
    for item in items:
        if item in ("{", "(", "["):
            nesting.append(item)
        elif item in pairs:
            assert nesting.pop() == pairs[item], "unbalanced initializer"
        if item == "," and not nesting:
            result.append(group)
            group = []
        else:
            group.append(item)
    assert not nesting
    if group:
        result.append(group)
    return result


def fields(items):
    assert items[0] == "{" and items[-1] == "}"
    result = {}
    for part in groups(items[1:-1]):
        assert len(part) >= 4 and part[0] == "." and part[2] == "="
        assert part[1] in KNOWN_FIELDS and part[1] not in result
        result[part[1]] = part[3:]
    return result


def string(items):
    assert items and all(item.startswith('"') for item in items), items
    # Relevant catalog strings use shared C/Python escapes only. Refuse any
    # escape whose interpretation would differ rather than guessing.
    assert not any(re.search(r'\\[exuU?]', item) for item in items)
    return "".join(ast.literal_eval(item) for item in items)


def bits(items, vocabulary):
    assert len(items) % 2 == 1
    result = 0
    for index, item in enumerate(items):
        if index % 2:
            assert item == "|"
        else:
            assert item.startswith("OPTIONS_TABLE_")
            result |= vocabulary[item.removeprefix("OPTIONS_TABLE_")]
    return result


def scalar_number(items, constants):
    assert len(items) == 1
    item = items[0]
    return constants[item] if item in constants else int(item, 10)


def extract(source, header):
    constants = dict(CONSTANTS)
    match = re.search(r'^#define INPUT_BUF_DEFAULT_SIZE ([0-9]+)$', header, re.M)
    if match:
        constants["INPUT_BUF_DEFAULT_SIZE"] = int(match[1])
    for key, value in {**SCOPE, **FLAGS}.items():
        match = re.search(r'^#define OPTIONS_TABLE_' + key + r' (0x[0-9a-f]+)$',
                          header, re.M)
        assert match and int(match[1], 16) == value

    marker = "const struct options_table_entry options_table[] = {"
    start = source.index(marker) + len(marker)
    body = source[start:]
    assert body.rstrip().endswith("};")
    parts = groups(tokens(body[:body.rfind("}")]))
    assert parts[-1] == ["{", ".", "name", "=", "NULL", "}"]
    entries = parts[:-1]
    macros = {}
    joined = source.replace("\\\n", "")
    for match in re.finditer(r'^#define (OPTIONS_TABLE_(?:PANE_|WINDOW_)?HOOK)'
                             r'\(([^)]*)\)[ \t]*(.*)$', joined, re.M):
        macros[match[1]] = ([item.strip() for item in match[2].split(",")],
                            tokens(match[3]))
    assert set(macros) == {"OPTIONS_TABLE_HOOK", "OPTIONS_TABLE_PANE_HOOK",
                           "OPTIONS_TABLE_WINDOW_HOOK"}
    choices = {}
    for match in re.finditer(r'static const char \*(options_table_\w+_list)'
                             r'\[\] = \{([\s\S]*?)\};', source):
        values = groups(tokens(match[2]))
        assert values.pop() == ["NULL"]
        choices[match[1]] = [string(value) for value in values]

    result, anchors = {}, {}
    for entry in entries:
        macro_name = None
        if entry[0] != "{":
            macro_name = entry[0]
            assert macro_name in macros and entry[1] == "(" and entry[-1] == ")"
            names, body_tokens = macros[macro_name]
            values = groups(entry[2:-1])
            assert len(names) == len(values)
            substitutions = dict(zip(names, values, strict=True))
            entry = [value for item in body_tokens
                     for value in substitutions.get(item, [item])]
        data = fields(entry)
        name = string(data["name"])
        assert re.fullmatch(r"[a-z][a-z0-9-]*", name) and name not in result
        native_type = data["type"]
        assert len(native_type) == 1
        native_type = native_type[0].removeprefix("OPTIONS_TABLE_")
        assert native_type in TYPES
        scope = bits(data["scope"], SCOPE)
        flags = bits(data["flags"], FLAGS) if "flags" in data else 0
        item = {"name": name, "native_type": native_type.lower(),
                "scope_bits": scope,
                "scopes": [key.lower() for key, bit in SCOPE.items() if scope & bit],
                "flags_bits": flags, "array": bool(flags & FLAGS["IS_ARRAY"]),
                "hook": bool(flags & FLAGS["IS_HOOK"]),
                "style": bool(flags & FLAGS["IS_STYLE"]),
                "separator": string(data["separator"]) if "separator" in data else None}
        if item["array"]:
            item["array_separator"] = item["separator"] if item["separator"] is not None else " ,"
        if native_type == "NUMBER":
            for field in ("minimum", "maximum"):
                expression = data.get(field, ["0"])
                item[field] = scalar_number(expression, constants)
                item[field + "_expression"] = "".join(expression)
        if native_type == "CHOICE":
            assert len(data["choices"]) == 1
            item["choices"] = choices[data["choices"][0]]
        if "pattern" in data:
            item["pattern"] = string(data["pattern"])
        if "unit" in data:
            item["unit"] = string(data["unit"])
        if item["hook"]:
            assert native_type == "COMMAND" and item["array"] and item["separator"] == ""
        expression = (re.escape(macro_name) + r'\("' + re.escape(name) + '"') if macro_name else (r'\.name\s*=\s*"' + re.escape(name) + '"')
        matches = list(re.finditer(expression, source))
        assert len(matches) == 1
        anchors[name] = source.count("\n", 0, matches[0].start()) + 1
        result[name] = item

    # An independent spelling inventory catches any omitted designated entry
    # or hook invocation even if it was not represented by the main parser.
    inventory = re.findall(r'\.name\s*=\s*"([^"]+)"', source[start:])
    inventory += re.findall(r'OPTIONS_TABLE_(?:PANE_|WINDOW_)?HOOK\("([^"]+)"', source[start:])
    assert len(inventory) == len(result) and set(inventory) == set(result)
    return result, anchors


def load_catalog():
    data = json.loads(CATALOG.read_text())
    if data["schema_version"] != 1 or data["support_floor"] != "3.2a":
        raise ValueError("unsupported option catalog schema or floor")
    if set(data["releases"]) != set(PINS):
        raise ValueError("option catalog must describe every pinned release")
    definitions = data["definitions"]
    identities = set()
    allowed = {"name", "native_type", "scope_bits", "scopes", "flags_bits",
               "array", "hook", "style", "separator", "array_separator",
               "minimum", "maximum", "minimum_expression", "maximum_expression",
               "choices", "pattern", "unit"}
    for key, item in definitions.items():
        if not re.fullmatch(r"d[0-9]{4}", key) or set(item) - allowed:
            raise ValueError("invalid definition identity or fields")
        if not re.fullmatch(r"[a-z][a-z0-9-]*", item["name"]):
            raise ValueError("invalid canonical option name")
        if item["native_type"] not in {name.lower() for name in TYPES}:
            raise ValueError("unknown native option type")
        if type(item["scope_bits"]) is not int or item["scope_bits"] not in (1, 2, 4, 12):
            raise ValueError("unreviewed native option scope")
        if item["scopes"] != [name.lower() for name, bit in SCOPE.items()
                              if item["scope_bits"] & bit]:
            raise ValueError("scope names disagree with native bits")
        for flag in ("array", "hook", "style"):
            if type(item[flag]) is not bool:
                raise ValueError("option flags must be booleans")
        if type(item["flags_bits"]) is not int or item["flags_bits"] != sum(
                FLAGS["IS_" + flag.upper()] for flag in ("array", "hook", "style") if item[flag]):
            raise ValueError("option flags disagree with native bits")
        if item["hook"] and (item["native_type"] != "command" or not item["array"]):
            raise ValueError("built-in hooks must be command arrays")
        if item["style"] and item["native_type"] != "string":
            raise ValueError("style option must be a string")
        separator = item["separator"]
        if separator is not None and not isinstance(separator, str):
            raise ValueError("separator must be a string or null")
        if item["array"]:
            if item["native_type"] not in ("string", "colour", "command"):
                raise ValueError("unsupported array element type")
            if item["array_separator"] != (separator if separator is not None else " ,"):
                raise ValueError("array separator disagrees with native default")
        elif "array_separator" in item:
            raise ValueError("scalar option has an array separator")
        if item["hook"] and separator != "":
            raise ValueError("hook array must preserve its complete command string")
        if item["native_type"] == "number":
            for bound in ("minimum", "maximum"):
                if type(item[bound]) is not int or not 0 <= item[bound] <= CONSTANTS["UINT_MAX"]:
                    raise ValueError("numeric option range is not an exact supported integer")
                if not re.fullmatch(r"[A-Z_]+|[0-9]+", item[bound + "_expression"]):
                    raise ValueError("unsupported numeric bound expression")
            if item["minimum"] > item["maximum"]:
                raise ValueError("reversed numeric option range")
        elif any(bound in item for bound in ("minimum", "maximum", "minimum_expression", "maximum_expression")):
            raise ValueError("nonnumeric option has a numeric bound")
        if item["native_type"] == "choice":
            choices = item["choices"]
            if not choices or any(not isinstance(value, str) for value in choices) or len(set(choices)) != len(choices):
                raise ValueError("invalid option choices")
        elif "choices" in item:
            raise ValueError("nonchoice option has choices")
        for field in ("pattern", "unit"):
            if field in item and not isinstance(item[field], str):
                raise ValueError("invalid option pattern or unit")
        identity = json.dumps(item, sort_keys=True)
        if identity in identities:
            raise ValueError("duplicate option definition")
        identities.add(identity)
    referenced = set()
    for version, release in data["releases"].items():
        if release["revision"] != PINS[version]:
            raise ValueError("option catalog release pin changed")
        if set(release["sources"]) != {"options-table.c", "options.c", "tmux.h"}:
            raise ValueError("option catalog source inventory changed")
        for path, source in release["sources"].items():
            if not re.fullmatch(r"[0-9a-f]{64}", source["sha256"]):
                raise ValueError("invalid source digest")
            if source["url"] != f"https://github.com/tmux/tmux/blob/{PINS[version]}/{path}":
                raise ValueError("source URL does not identify the pinned file")
        for name, entry in release["entries"].items():
            if entry["definition"] not in definitions or definitions[entry["definition"]]["name"] != name:
                raise ValueError("release map points at the wrong option definition")
            if type(entry["line"]) is not int or entry["line"] < 1:
                raise ValueError("invalid option source anchor")
            referenced.add(entry["definition"])
    if referenced != set(definitions):
        raise ValueError("option catalog contains unused definitions")
    return data


def verify_source(data, checkout):
    for version, release in data["releases"].items():
        revision = release["revision"]
        actual = subprocess.check_output(
            ["git", "-C", str(checkout), "rev-parse", f"refs/tags/{version}^{{commit}}"], text=True).strip()
        if actual != revision:
            raise ValueError(f"{version}: release tag does not match the pinned commit")
        texts = {}
        for path, source in release["sources"].items():
            raw = subprocess.check_output(["git", "-C", str(checkout), "show", f"{revision}:{path}"])
            if hashlib.sha256(raw).hexdigest() != source["sha256"]:
                raise ValueError(f"{version}: pinned source digest changed: {path}")
            texts[path] = raw.decode()
        extracted, anchors = extract(texts["options-table.c"], texts["tmux.h"])
        expected = {name: data["definitions"][entry["definition"]]
                    for name, entry in release["entries"].items()}
        if extracted != expected:
            raise ValueError(f"{version}: option metadata differs from pinned source")
        if anchors != {name: entry["line"] for name, entry in release["entries"].items()}:
            raise ValueError(f"{version}: option source anchors changed")


RUNTIME = '''
local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, item in pairs(value) do
        result[key] = copy(item)
    end
    return result
end

local function release(version)
    if type(version) ~= "string" or releases[version] == nil then
        return nil, errors.new("unsupported_version", "option catalog needs an explicitly cataloged tmux release")
    end
    return releases[version]
end

---@param version string
---@param name string
---@return libtmux.OptionDescriptor? descriptor
---@return libtmux.Error? error
function M.lookup(version, name)
    local entries, err = release(version)
    if not entries then
        return nil, err
    end
    local key = type(name) == "string" and entries[name] or nil
    if key == nil then
        return nil, errors.new("unknown_option", "option catalog needs a canonical built-in name for this release")
    end
    return copy(definitions[key])
end

---@param version string
---@param family? 'option'|'hook'
---@return string[]? names
---@return libtmux.Error? error
function M.names(version, family)
    local entries, err = release(version)
    if not entries then
        return nil, err
    end
    if family ~= nil and family ~= "option" and family ~= "hook" then
        return nil, errors.new("invalid_family", "option catalog family must be option or hook")
    end
    local names = {}
    for name, key in pairs(entries) do
        local hook = definitions[key].hook
        if family == nil or (family == "hook" and hook) or (family == "option" and not hook) then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

return M
'''


def generate_lua(data):
    lines = ["-- Generated by scripts/generate_options.py; edit data/tmux-options.json.",
             'local errors = require("libtmux._internal.error")', "local M = {}", "",
             "---@class libtmux.OptionDescriptor",
             "---@field name string",
             "---@field native_type 'string'|'number'|'key'|'colour'|'flag'|'choice'|'command'",
             "---@field scope_bits integer",
             "---@field scopes ('server'|'session'|'window'|'pane')[]",
             "---@field flags_bits integer",
             "---@field array boolean",
             "---@field hook boolean",
             "---@field style boolean",
             "---@field separator? string",
             "---@field array_separator? string",
             "---@field minimum? integer",
             "---@field maximum? integer",
             "---@field minimum_expression? string",
             "---@field maximum_expression? string",
             "---@field choices? string[]",
             "---@field pattern? string",
             "---@field unit? string", ""]
    for family, label in ((False, "OptionName"), (True, "HookName")):
        names = sorted({item["name"] for item in data["definitions"].values() if item["hook"] == family})
        lines.append(f"---@alias libtmux.{label}")
        lines.extend("---| " + lua(name) for name in names)
        lines.append("")
    lines.append("---@type table<string, libtmux.OptionDescriptor>")
    lines.append("local definitions = " + lua(data["definitions"]))
    maps, by_identity, release_keys = {}, {}, {}
    for version in PINS:
        entries = {name: row["definition"] for name, row in data["releases"][version]["entries"].items()}
        identity = json.dumps(entries, sort_keys=True)
        if identity not in by_identity:
            key = f"c{len(maps) + 1}"
            by_identity[identity] = key
            maps[key] = entries
        release_keys[version] = by_identity[identity]
    lines.extend(("", "local catalogs = " + lua(maps), "", "local releases = {"))
    lines.extend(f"[{lua(version)}] = catalogs.{key}," for version, key in release_keys.items())
    lines.extend(("}", RUNTIME))
    result = subprocess.run(["stylua", "--syntax", "Lua51", "-"], input="\n".join(lines),
                            text=True, capture_output=True, check=True)
    return result.stdout


def describe(item):
    if item["native_type"] == "choice":
        value = ", ".join(f'`{choice}`' for choice in item["choices"])
    elif item["native_type"] == "number":
        value = f'{item["minimum"]}..{item["maximum"]}'
    else:
        value = item["native_type"]
    if item["style"]:
        value = "style string"
    if item["array"]:
        value += "; sparse array"
    return value


def generate_docs(data):
    lines = ["# tmux option and hook reference", "",
             "This generated catalog records every canonical built-in option and hook",
             "in the 13 released tmux versions listed below. It describes native types",
             "and storage scopes; it does not establish runtime or platform compatibility.",
             "Edit [the catalog](../data/tmux-options.json), then regenerate:", "",
             "```console", "$ python scripts/generate_options.py", "```", "",
             "Check generated Lua metadata and this reference without changing files:", "",
             "```console", "$ python scripts/generate_options.py --check", "```", "",
             "Both commands run offline with Python and the pinned StyLua formatter.",
             "`--verify-source` additionally accepts a local tmux Git checkout and checks",
             "every release tag, pinned source digest, definition and line anchor. It",
             "does not download sources, build tmux or start a server.", "",
             "## Values and scopes", "",
             "Built-in names select their native storage scope; command flags alone do",
             "not enforce the caller's intended scope. Session and window defaults are",
             "separate global stores. Pane-capable options also support window storage;",
             "there is no global pane store. Unknown release strings require new source",
             "evidence: the private catalog does not fall back to the latest version.", "",
             "Flags use booleans, numbers use exact bounded integers, and choices use",
             "literal strings, including numeric-looking choices such as `\"24\"`. Keys,",
             "colours, styles and commands retain their native string grammars. A command",
             "value is tmux command-list source, not shell argv. Native grammar validation",
             "and remote conditions such as shell suitability still require tmux.", "",
             "Arrays retain native zero-based sparse indices and their element type.",
             "The separator is a set of splitting characters, not a reversible codec.",
             "An omitted array separator means space/comma; an empty separator preserves",
             "one complete command-list entry. Indexed assignment avoids splitting.",
             "All built-in hooks are command arrays; a scalar command option is not a",
             "hook. User options beginning with `@` are separate string scalars.", "",
             "Global built-in unset restores the default; local unset removes an override.",
             "Native aliases, prefix matching, default values and descriptive option text",
             "are outside this catalog. Source integer limits assume the supported target",
             "ABIs' 32-bit `int` and 16-bit `short`; the largest bound is 4294967295.", "",
             "## Source releases", "",
             "| Release | Built-ins, including hooks | Hooks |", "| --- | ---: | ---: |"]
    for version in PINS:
        release = data["releases"][version]
        hooks = sum(data["definitions"][entry["definition"]]["hook"] for entry in release["entries"].values())
        url = release["sources"]["options-table.c"]["url"]
        lines.append(f'| [{version}]({url}) | {len(release["entries"])} | {hooks} |')
    lines.extend(("", "Full commit identities, hashes for `options-table.c`, `options.c` and",
                  "`tmux.h`, and per-entry source anchors are recorded in the source catalog.",
                  "Repeated release labels below mean the extracted metadata is identical,",
                  "not that defaults or other native behavior are identical.", ""))
    for hook, title in ((False, "Options"), (True, "Hooks")):
        lines.extend((f"## {title}", "", "| Name | Releases | Scope | Value | Array separator |",
                      "| --- | --- | --- | --- | --- |"))
        names = sorted({item["name"] for item in data["definitions"].values() if item["hook"] == hook})
        for name in names:
            variants = {}
            for version in PINS:
                entry = data["releases"][version]["entries"].get(name)
                if entry:
                    variants.setdefault(entry["definition"], []).append(version)
            for key, versions in variants.items():
                item = data["definitions"][key]
                release = data["releases"][versions[0]]
                source = release["sources"]["options-table.c"]["url"] + "#L" + str(release["entries"][name]["line"])
                separator = "—"
                if item["array"]:
                    separator = "empty" if item["array_separator"] == "" else "`" + json.dumps(item["array_separator"]) + "`"
                lines.append(f'| [`{name}`]({source}) | {", ".join(versions)} | '
                             f'{", ".join(item["scopes"])} | {describe(item)} | {separator} |')
        lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if generated files differ")
    parser.add_argument("--verify-source", type=Path, help="verify all pinned objects in a local tmux Git checkout")
    args = parser.parse_args()
    data = load_catalog()
    if args.verify_source:
        verify_source(data, args.verify_source)
    outputs = {ROOT / "lua/libtmux/_internal/options_catalog.lua": generate_lua(data),
               ROOT / "docs/options-reference.md": generate_docs(data)}
    stale = []
    for path, content in outputs.items():
        if args.check:
            if not path.exists() or path.read_text() != content:
                stale.append(str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
    if stale:
        print("Stale generated files: " + ", ".join(stale), file=sys.stderr)
        return 1
    print("Option catalog " + ("check" if args.check else "generation") + " PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
