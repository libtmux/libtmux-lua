-- Generate lua/libtmux/_internal/fields.lua and docs/fields.md from data/tmux-fields.json.
local json = require("support.json")
local render = require("generate.render")
local repo = require("support.repo")
local shell = require("support.shell")

local M = {}

M.CATALOG = repo.root .. "/data/tmux-fields.json"
M.KINDS = { "server", "session", "window", "window_link", "pane", "client", "buffer" }

local function invalid(message)
    error(message, 0)
end

local function is_name(value)
    return type(value) == "string" and value:match("^[a-z][a-z0-9_]*$") ~= nil
end

local function has(map, key)
    return map ~= nil and map[key] ~= nil
end

--- Reads the catalog and refuses anything the generators did not review.
---@param path? string
---@return table
function M.load_catalog(path)
    local data = json.read(path or M.CATALOG)
    if data.schema_version ~= 1 or data.support_floor ~= "3.3a" then
        invalid("unsupported catalog schema or support floor")
    end
    if #data.entities ~= #M.KINDS then
        invalid("catalog must include each supported entity in canonical order")
    end
    for index, kind in ipairs(M.KINDS) do
        if data.entities[index].name ~= kind then
            invalid("catalog must include each supported entity in canonical order")
        end
    end
    local scopes = { winlink = true }
    for _, kind in ipairs(M.KINDS) do
        scopes[kind] = true
    end
    for _, entity in ipairs(data.entities) do
        local names = {}
        for _, field in ipairs(entity.fields) do
            if names[field.name] or not is_name(field.name) then
                invalid("invalid or duplicate record field")
            end
            names[field.name] = true
            if not is_name(field.format) then
                invalid("catalog formats must be literal tmux field names")
            end
            if field.type ~= "string" and field.type ~= "number" and field.type ~= "boolean" then
                invalid("unsupported scalar type")
            end
            if type(field.nullable) ~= "boolean" then
                invalid("nullable must be boolean")
            end
            if field.since ~= data.support_floor then
                invalid("field availability needs reviewed version evidence")
            end
            if not (has(field.lines, "stable") and has(field.lines, "upstream")) then
                invalid("field needs stable and upstream source evidence")
            end
            if not has(field.lines, "floor") then
                invalid("floor availability disagrees with source evidence")
            end
            if not scopes[field.source_scope] then
                invalid("unknown native format scope")
            end
            for key, line in pairs(field.lines) do
                if
                    not has(data.sources, key)
                    or type(line) ~= "number"
                    or line < 1
                    or line % 1 ~= 0
                then
                    invalid("invalid source anchor")
                end
            end
        end
        if entity.name == "window" and (names.index or names.active or names.session_id) then
            invalid("window must not own session-local link fields")
        end
    end
    return data
end

-- The runtime half of the generated file, which StyLua formats after it is appended.
-- luacheck: push ignore 631
local RUNTIME = [==[
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

-- tmux has only reported X.Y with an optional patch letter, X.Y-rc and
-- X.Y-rcN candidates, and next-X.Y development builds. They rank
-- next-X.Y < X.Y-rc < X.Y-rcN < X.Y < X.Ya; anything else names no release.
local function version(value)
    if type(value) ~= "string" or #value > 32 then
        return nil
    end
    local major, minor, letter = value:match("^(%d+)%.(%d+)(%l?)$")
    if major then
        return { tonumber(major), tonumber(minor), 2, 0, letter }
    end
    local candidate
    major, minor, candidate = value:match("^(%d+)%.(%d+)%-rc(%d*)$")
    if major then
        return { tonumber(major), tonumber(minor), 1, tonumber(candidate) or 0, "" }
    end
    major, minor = value:match("^next%-(%d+)%.(%d+)$")
    if major then
        return { tonumber(major), tonumber(minor), 0, 0, "" }
    end
    return nil
end

local function at_least(actual, required)
    for index = 1, 5 do
        if actual[index] ~= required[index] then
            return actual[index] > required[index]
        end
    end
    return true
end

---Whether a reported release ranks at or above a required one.
---@param reported string
---@param required string A release such as "3.7" or "3.4".
---@return boolean? ranked Nil when the report names no release.
function M.at_least(reported, required)
    local actual = version(reported)
    if not actual then
        return nil
    end
    return at_least(actual, assert(version(required)))
end

---Whether a report is exactly one final release: "3.7" matches neither
---"3.7a", a release candidate or a next-3.7 development build.
---@param reported string
---@param release string
---@return boolean
function M.exactly(reported, release)
    local actual, required = version(reported), version(release)
    return actual ~= nil
        and required ~= nil
        and actual[1] == required[1]
        and actual[2] == required[2]
        and actual[3] == 2
        and actual[5] == required[5]
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
    if not actual then
        return nil,
            errors.new(
                "unsupported_version",
                "schema needs a tmux release or development build (MAJOR.MINOR with an optional "
                    .. "patch letter, a -rc or -rcN candidate, or a next- prefix)"
            )
    end
    if not at_least(actual, version(M.support_floor)) then
        return nil,
            errors.new("unsupported_version", "schema needs tmux " .. M.support_floor .. " or newer")
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
]==]
-- luacheck: pop

--- An object table that keeps the order its keys were added in.
local function ordered()
    return json.object({}, {})
end

local function put(object, key, value)
    object[key] = value
    local keys = json.keys(object)
    keys[#keys + 1] = key
end

local function class_label(name)
    local label = ""
    for part in name:gmatch("[^_]+") do
        label = label .. part:sub(1, 1):upper() .. part:sub(2):lower()
    end
    return label
end

---@param data table
---@return string
function M.generate_lua(data)
    local lines = {
        "-- Generated by scripts/generate/generate.lua fields; edit data/tmux-fields.json.",
        'local errors = require("libtmux._internal.error")',
        ("local M = { schema_version = 1, support_floor = %s }"):format(
            render.literal(data.support_floor)
        ),
        "",
    }
    local catalog = ordered()
    for _, entity in ipairs(data.entities) do
        lines[#lines + 1] = "---@class libtmux.Fields." .. class_label(entity.name)
        local fields = ordered()
        put(catalog, entity.name, fields)
        for _, field in ipairs(entity.fields) do
            local datatype = field.type == "number" and "integer" or field.type
            if field.nullable then
                datatype = datatype .. "|libtmux.Null"
            end
            lines[#lines + 1] = ("---@field %s? %s"):format(field.name, datatype)
            local copied = ordered()
            for _, key in ipairs(json.keys(field)) do
                if key ~= "name" then
                    put(copied, key, field[key])
                end
            end
            put(fields, field.name, copied)
        end
        lines[#lines + 1] = ""
    end
    lines[#lines + 1] = "local kinds = " .. render.literal(M.KINDS)
    lines[#lines + 1] = "local sources = " .. render.literal(data.sources)
    lines[#lines + 1] = "local catalog = " .. render.literal(catalog)
    lines[#lines + 1] = ""
    lines[#lines + 1] = RUNTIME
    return render.format(table.concat(lines, "\n"))
end

local DOCS_HEAD = [==[
# tmux field catalog

This curated catalog describes the scalar fields needed by the core entity
model. It does not enumerate every tmux format. Edit
[the source catalog](../data/tmux-fields.json) and regenerate this reference
together with Lua metadata and LuaLS field annotations:

```console
$ luajit scripts/generate/generate.lua fields
```

Check generated files without changing them:

```console
$ luajit scripts/generate/generate.lua fields --check
```

Generation uses LuaJIT and the pinned StyLua formatter; it needs no network
or tmux process. The optional `--verify-source` argument accepts a local tmux
Git checkout and verifies every pinned format mapping and source anchor.

## Availability and values

`Since` means the first release supported by this catalog for that field,
not necessarily the release that introduced it. The floor is tmux __FLOOR__.
Source inspection establishes format availability; it does not establish
complete runtime or platform compatibility. The schema helper accepts recognized
final, release-candidate and `next-X.Y` reports that rank at or above the floor.
Field availability is checked against that rank. Unrecognized reports and
versions below the floor are rejected.

Record names are Lua aliases for literal tmux format names. IDs retain their
`$`, `@`, and `%` prefixes. `number` fields represent integers; consumers must
reject values outside the exact integer range of their Lua runtime rather
than silently round them. All generated LuaLS fields are optional because a
projection may leave a field unloaded.

Nullable fields may be absent within an otherwise valid native context.
Loaded absence uses `query.NULL`; an omitted key means not loaded. Known
fields unavailable at the requested version remain in the query schema with
`supported = false`. Empty text remains text for nonnullable string fields.
The scalar catalog does not build relationships or perform I/O.

Window index, active state, and flags belong to `window_link`. Windows and
panes have no scalar session ID because a window can be linked into several
sessions. `client_session` provides a session name, not a session ID. Client
names and buffer names need contextual revalidation before later mutations.

## Source provenance

]==]

---@param data table
---@return string
function M.generate_docs(data)
    local result = { (DOCS_HEAD:gsub("__FLOOR__", data.support_floor)) }
    for _, key in ipairs(json.keys(data.sources)) do
        local source = data.sources[key]
        local label = (source.version ~= json.null and source.version)
            or "inspected upstream revision"
        result[#result + 1] = ("- %s: [%s](%s).\n"):format(key, label, source.url)
    end
    for _, entity in ipairs(data.entities) do
        local title = entity.name:gsub("_", " ")
        title = title:sub(1, 1):upper() .. title:sub(2):lower()
        result[#result + 1] = "\n## " .. title .. "\n\n"
        result[#result + 1] =
            "| Record field | tmux format | Type | Nullable | Since | Native scope |\n"
        result[#result + 1] = "| --- | --- | --- | --- | --- | --- |\n"
        for _, field in ipairs(entity.fields) do
            local source = data.sources.stable.url .. "#L" .. ("%d"):format(field.lines.stable)
            result[#result + 1] = ("| `%s` | [`%s`](%s) | %s | %s | %s | %s |\n"):format(
                field.name,
                field.format,
                source,
                field.type,
                field.nullable and "yes" or "no",
                field.since,
                field.source_scope
            )
        end
        result[#result + 1] = "\n"
        for _, field in ipairs(entity.fields) do
            local item = ("- `%s`: %s"):format(field.name, field.description)
            result[#result + 1] = table.concat(render.wrap(item, 80, "  "), "\n") .. "\n"
        end
    end
    return table.concat(result)
end

local function escape(text)
    return (text:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

--- Checks every pinned format mapping and source anchor against a local tmux Git checkout.
---@param data table
---@param checkout string
function M.verify_source(data, checkout)
    for _, key in ipairs(json.keys(data.sources)) do
        local source = data.sources[key]
        local text =
            shell.check({ "git", "-C", checkout, "show", source.revision .. ":" .. source.file })
        local lines = {}
        for line in (text .. "\n"):gmatch("(.-)\r?\n") do
            lines[#lines + 1] = line
        end
        for _, entity in ipairs(data.entities) do
            for _, field in ipairs(entity.fields) do
                local pattern = '{ "'
                    .. escape(field.format)
                    .. '", FORMAT_TABLE_[%w_]+,%s*'
                    .. escape(field.symbol)
                local present = text:find(pattern .. "[^%w_]") ~= nil
                    or text:find(pattern .. "$") ~= nil
                if present ~= (field.lines[key] ~= nil) then
                    invalid(key .. ": format availability changed: " .. field.format)
                end
                if
                    present
                    and lines[field.lines[key]]:sub(1, #field.symbol + 1) ~= field.symbol .. "("
                then
                    invalid(key .. ": source anchor changed: " .. field.format)
                end
            end
        end
    end
end

return M
