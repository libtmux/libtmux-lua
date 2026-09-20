"""Generate Lua metadata, LuaLS fields, and reference from the curated tmux catalog."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import textwrap

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "data/tmux-fields.json"
KINDS = ("server", "session", "window", "window_link", "pane", "client", "buffer")


def load_catalog():
    data = json.loads(CATALOG.read_text())
    if data["schema_version"] != 1 or data["support_floor"] != "3.2a":
        raise ValueError("unsupported catalog schema or support floor")
    if tuple(entity["name"] for entity in data["entities"]) != KINDS:
        raise ValueError("catalog must include each supported entity in canonical order")
    for entity in data["entities"]:
        names = set()
        for field in entity["fields"]:
            name = field["name"]
            if name in names or not re.fullmatch(r"[a-z][a-z0-9_]*", name):
                raise ValueError("invalid or duplicate record field")
            names.add(name)
            if not re.fullmatch(r"[a-z][a-z0-9_]*", field["format"]):
                raise ValueError("catalog formats must be literal tmux field names")
            if field["type"] not in ("string", "number", "boolean"):
                raise ValueError("unsupported scalar type")
            if type(field["nullable"]) is not bool:
                raise ValueError("nullable must be boolean")
            if field["since"] not in ("3.2a", "3.3"):
                raise ValueError("field availability needs reviewed version evidence")
            if not {"stable", "upstream"} <= field["lines"].keys():
                raise ValueError("field needs stable and upstream source evidence")
            if (field["since"] == "3.2a") != ("floor" in field["lines"]):
                raise ValueError("floor availability disagrees with source evidence")
            if field["source_scope"] not in (*KINDS, "winlink"):
                raise ValueError("unknown native format scope")
            for key, line in field["lines"].items():
                if key not in data["sources"] or type(line) is not int or line < 1:
                    raise ValueError("invalid source anchor")
        if entity["name"] == "window" and names & {"index", "active", "session_id"}:
            raise ValueError("window must not own session-local link fields")
    return data


def lua(value):
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=True)
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, list):
        return "{ " + ", ".join(lua(item) for item in value) + " }"
    entries = []
    reserved = {"and", "break", "do", "else", "elseif", "end", "false", "for", "function",
                "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true",
                "until", "while"}
    for key, item in value.items():
        name = key if re.fullmatch(r"[a-z_][a-z0-9_]*", key) and key not in reserved else f"[{lua(key)}]"
        entries.append(f"{name} = {lua(item)}")
    return "{ " + ", ".join(entries) + " }"


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

local function version(value)
    if type(value) ~= "string" or #value > 32 then
        return nil
    end
    local major, minor, suffix = value:match("^(%d+)%.(%d+)(%l*)$")
    if not major then
        return nil
    end
    return { tonumber(major), tonumber(minor), suffix }
end

local function at_least(actual, required)
    for index = 1, 3 do
        if actual[index] ~= required[index] then
            return actual[index] > required[index]
        end
    end
    return true
end

function M.kinds()
    return copy(kinds)
end

function M.sources()
    return copy(sources)
end

function M.catalog(kind)
    if catalog[kind] == nil then
        return nil, errors.new("invalid_entity", "unknown field catalog entity")
    end
    return copy(catalog[kind])
end

---@param kind string
---@param tmux_version? string
---@return libtmux.QuerySchema? schema
---@return table? error
function M.schema(kind, tmux_version)
    local fields = catalog[kind]
    if not fields then
        return nil, errors.new("invalid_entity", "unknown field catalog entity")
    end
    local actual = version(tmux_version)
    if not actual or not at_least(actual, version(M.support_floor)) then
        return nil, errors.new("unsupported_version", "schema needs a tmux release version at least 3.2a")
    end
    local schema = { name = kind, fields = {} }
    for name, field in pairs(fields) do
        schema.fields[name] = {
            type = field.type,
            nullable = field.nullable,
            supported = at_least(actual, version(field.since)),
        }
    end
    return schema
end

return M
'''


def generate_lua(data):
    lines = ["-- Generated by scripts/generate_fields.py; edit data/tmux-fields.json.",
             'local errors = require("libtmux._internal.error")',
             f'local M = {{ schema_version = 1, support_floor = {lua(data["support_floor"])} }}', ""]
    catalog = {}
    for entity in data["entities"]:
        label = "".join(part.title() for part in entity["name"].split("_"))
        lines.append(f'---@class libtmux.Fields.{label}')
        catalog[entity["name"]] = {}
        for field in entity["fields"]:
            datatype = "integer" if field["type"] == "number" else field["type"]
            if field["nullable"]:
                datatype += "|libtmux.Null"
            lines.append(f'---@field {field["name"]}? {datatype}')
            copied = dict(field)
            del copied["name"]
            catalog[entity["name"]][field["name"]] = copied
        lines.append("")
    lines.extend((f"local kinds = {lua(list(KINDS))}",
                  f'local sources = {lua(data["sources"])}',
                  f"local catalog = {lua(catalog)}", RUNTIME))
    rendered = "\n".join(lines)
    result = subprocess.run(["stylua", "--syntax", "Lua51", "-"], input=rendered,
                            text=True, capture_output=True, check=True)
    return result.stdout


def generate_docs(data):
    result = ["# tmux field catalog", "",
              "This curated catalog describes the scalar fields needed by the core entity",
              "model. It does not enumerate every tmux format. Edit",
              "[the source catalog](../data/tmux-fields.json) and regenerate this reference",
              "together with Lua metadata and LuaLS field annotations:", "",
              "```console", "$ python scripts/generate_fields.py", "```", "",
              "Check generated files without changing them:", "",
              "```console", "$ python scripts/generate_fields.py --check", "```", "",
              "Generation uses Python and the pinned StyLua formatter; it needs no network",
              "or tmux process. The optional `--verify-source` argument accepts a local tmux",
              "Git checkout and verifies every pinned format mapping and source anchor.", "",
              "## Availability and values", "",
              "`Since` means the first release supported by this catalog for that field,",
              "not necessarily the release that introduced it. The floor is tmux 3.2a.",
              "Source inspection establishes format availability; it does not establish",
              "complete runtime or platform compatibility. Later release strings retain",
              "known fields; development and prerelease strings require explicit capability",
              "evidence and are rejected by the schema helper.", "",
              "Record names are Lua aliases for literal tmux format names. IDs retain their",
              "`$`, `@`, and `%` prefixes. `number` fields represent integers; consumers must",
              "reject values outside the exact integer range of their Lua runtime rather",
              "than silently round them. All generated LuaLS fields are optional because a",
              "projection may leave a field unloaded.", "",
              "Nullable fields may be absent within an otherwise valid native context.",
              "Loaded absence uses `query.NULL`; an omitted key means not loaded. Known",
              "fields unavailable at the requested version remain in the query schema with",
              "`supported = false`. Empty text remains text for nonnullable string fields.",
              "The scalar catalog does not build relationships or perform I/O.", "",
              "Window index, active state, and flags belong to `window_link`. Windows and",
              "panes have no scalar session ID because a window can be linked into several",
              "sessions. `client_session` provides a session name, not a session ID. Client",
              "names and buffer names need contextual revalidation before later mutations.", "",
              "## Source provenance", ""]
    for key, source in data["sources"].items():
        label = source["version"] or "inspected upstream revision"
        result.append(f'- {key}: [{label}]({source["url"]}).')
    for entity in data["entities"]:
        result.extend(("", f'## {entity["name"].replace("_", " ").capitalize()}', "",
                       "| Record field | tmux format | Type | Nullable | Since | Native scope |",
                       "| --- | --- | --- | --- | --- | --- |"))
        for field in entity["fields"]:
            source = data["sources"]["stable"]["url"] + "#L" + str(field["lines"]["stable"])
            result.append(f'| `{field["name"]}` | [`{field["format"]}`]({source}) | '
                          f'{field["type"]} | {"yes" if field["nullable"] else "no"} | '
                          f'{field["since"]} | {field["source_scope"]} |')
        result.append("")
        for field in entity["fields"]:
            result.extend(textwrap.wrap(f'- `{field["name"]}`: {field["description"]}',
                                        width=80, subsequent_indent="  "))
    return "\n".join(result) + "\n"


def verify_source(data, checkout):
    for key, source in data["sources"].items():
        text = subprocess.check_output(
            ["git", "-C", str(checkout), "show", f'{source["revision"]}:{source["file"]}'],
            text=True)
        lines = text.splitlines()
        for entity in data["entities"]:
            for field in entity["fields"]:
                expression = (r'\{ "' + re.escape(field["format"]) +
                              r'", FORMAT_TABLE_\w+,\s*' + field["symbol"] + r'\b')
                present = re.search(expression, text) is not None
                if present != (key in field["lines"]):
                    raise ValueError(f'{key}: format availability changed: {field["format"]}')
                if present and not lines[field["lines"][key] - 1].startswith(field["symbol"] + "("):
                    raise ValueError(f'{key}: source anchor changed: {field["format"]}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if generated files differ")
    parser.add_argument("--verify-source", type=Path, help="verify pinned local tmux source objects")
    args = parser.parse_args()
    data = load_catalog()
    if args.verify_source:
        verify_source(data, args.verify_source)
    outputs = {ROOT / "lua/libtmux/_internal/fields.lua": generate_lua(data),
               ROOT / "docs/fields.md": generate_docs(data)}
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
    print("Field catalog " + ("check" if args.check else "generation") + " PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
