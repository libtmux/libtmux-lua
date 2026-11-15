-- Generate lua/libtmux/_internal/options_catalog.lua and docs/options-reference.md from
-- data/tmux-options.json.
local json = require("support.json")
local render = require("generate.render")
local repo = require("support.repo")

local M = {}

M.CATALOG = repo.root .. "/data/tmux-options.json"
-- The releases the catalog describes, oldest first, with the commit each one is pinned to. A
-- development build reports next-X.Y and describes that one commit.
M.PINS = {
    { "3.3a", "0b355ae8114511e1ff6359272b164f1cdf718e80" },
    { "3.4", "9ae69c3795ab5ef6b4d760f6398cd9281151f632" },
    { "3.5", "ac44566c9c7e3e94d23be6def4c7ae83472543f5" },
    { "3.5a", "549c35b06165f6ae023115eb76f83f2cbf945395" },
    { "3.6", "0dac7fe434d029a4f0b819cba8eb7963df291990" },
    { "3.6a", "cc117b5048f77a4842820f8ebbe3a86e5c077224" },
    { "3.6b", "0623d1e968423ad0c192e0d8debf1258671063d5" },
    { "3.7", "81f88f8517c9fc5371b56cf117530c6b477c96ac" },
    { "3.7a", "0e418b62d259ce8da8970f75732cc6632ee4c3a0" },
    { "3.7b", "e802909de06012a4df6209d55e86487c56223163" },
    { "3.7c", "e476c1230b958df0cb12977517d24b3dc931375b" },
    { "3.7d", "0d7b9e87f45d51e96c4f6f26450bcbb2411f11c8" },
    { "3.8", "7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53" },
    { "next-3.9", "b17d3da7cd84114e4c58630637f0b80428c0aa34" },
}
M.SCOPE = { { "SERVER", 1 }, { "SESSION", 2 }, { "WINDOW", 4 }, { "PANE", 8 } }
M.FLAGS = { IS_ARRAY = 1, IS_HOOK = 2, IS_STYLE = 4, IS_COLOUR = 8 }
M.TYPES = { "string", "number", "key", "colour", "flag", "choice", "command" }
-- Supported Linux and macOS ABIs have a 32-bit int and a 16-bit short.
M.UINT_MAX = 4294967295

local ALLOWED = {}
for name in
    ([[name native_type scope_bits scopes flags_bits array hook style separator array_separator
    minimum maximum minimum_expression maximum_expression choices pattern unit]]):gmatch("%S+")
do
    ALLOWED[name] = true
end

local function invalid(message)
    error(message, 0)
end

local function contains(list, value)
    for _, item in ipairs(list) do
        if item == value then
            return true
        end
    end
    return false
end

--- A string for a decoded value with every object's keys sorted, to compare structure.
local function canonical(value)
    if type(value) ~= "table" then
        return json.encode(value)
    end
    if not json.is_object(value) then
        local parts = {}
        for index, item in ipairs(value) do
            parts[index] = canonical(item)
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    local parts = {}
    for index, key in ipairs(keys) do
        parts[index] = json.encode(key) .. ":" .. canonical(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function scope_names(bits)
    local names = {}
    for _, scope in ipairs(M.SCOPE) do
        if bits % (scope[2] * 2) >= scope[2] then
            names[#names + 1] = scope[1]:lower()
        end
    end
    return names
end

local function is_integer(value)
    return type(value) == "number" and value % 1 == 0
end

local function check_definition(key, item)
    if not key:match("^d%d%d%d%d$") then
        invalid("invalid definition identity or fields")
    end
    for field in pairs(item) do
        if not ALLOWED[field] then
            invalid("invalid definition identity or fields")
        end
    end
    if not item.name:match("^[a-z][a-z0-9%-]*$") then
        invalid("invalid canonical option name")
    end
    if not contains(M.TYPES, item.native_type) then
        invalid("unknown native option type")
    end
    local bits = item.scope_bits
    if not (is_integer(bits) and (bits == 1 or bits == 2 or bits == 4 or bits == 12)) then
        invalid("unreviewed native option scope")
    end
    if table.concat(item.scopes, ",") ~= table.concat(scope_names(bits), ",") then
        invalid("scope names disagree with native bits")
    end
    for _, flag in ipairs({ "array", "hook", "style" }) do
        if type(item[flag]) ~= "boolean" then
            invalid("option flags must be booleans")
        end
    end
    -- Releases from 3.8 mark a colour with IS_COLOUR on a string option.
    local expected = (item.native_type == "colour" and item.flags_bits % 16 >= M.FLAGS.IS_COLOUR)
            and M.FLAGS.IS_COLOUR
        or 0
    for _, flag in ipairs({ "array", "hook", "style" }) do
        if item[flag] then
            expected = expected + M.FLAGS["IS_" .. flag:upper()]
        end
    end
    if not is_integer(item.flags_bits) or item.flags_bits ~= expected then
        invalid("option flags disagree with native bits")
    end
    if item.hook and (item.native_type ~= "command" or not item.array) then
        invalid("built-in hooks must be command arrays")
    end
    if item.style and item.native_type ~= "string" then
        invalid("style option must be a string")
    end
    local separator = item.separator
    if separator ~= nil and separator ~= json.null and type(separator) ~= "string" then
        invalid("separator must be a string or null")
    end
    if separator == json.null then
        separator = nil
    end
    if item.array then
        if not contains({ "string", "colour", "command" }, item.native_type) then
            invalid("unsupported array element type")
        end
        if item.array_separator ~= (separator ~= nil and separator or " ,") then
            invalid("array separator disagrees with native default")
        end
    elseif item.array_separator ~= nil then
        invalid("scalar option has an array separator")
    end
    if item.hook and separator ~= "" then
        invalid("hook array must preserve its complete command string")
    end
    local bounds = { "minimum", "maximum", "minimum_expression", "maximum_expression" }
    if item.native_type == "number" then
        for _, bound in ipairs({ "minimum", "maximum" }) do
            local value = item[bound]
            if not (is_integer(value) and value >= 0 and value <= M.UINT_MAX) then
                invalid("numeric option range is not an exact supported integer")
            end
            local expression = item[bound .. "_expression"]
            if
                type(expression) ~= "string"
                or not (expression:match("^[A-Z_]+$") or expression:match("^%d+$"))
            then
                invalid("unsupported numeric bound expression")
            end
        end
        if item.minimum > item.maximum then
            invalid("reversed numeric option range")
        end
    else
        for _, bound in ipairs(bounds) do
            if item[bound] ~= nil then
                invalid("nonnumeric option has a numeric bound")
            end
        end
    end
    if item.native_type == "choice" then
        local seen = {}
        if type(item.choices) ~= "table" or #item.choices == 0 then
            invalid("invalid option choices")
        end
        for _, value in ipairs(item.choices) do
            if type(value) ~= "string" or seen[value] then
                invalid("invalid option choices")
            end
            seen[value] = true
        end
    elseif item.choices ~= nil then
        invalid("nonchoice option has choices")
    end
    for _, field in ipairs({ "pattern", "unit" }) do
        if item[field] ~= nil and type(item[field]) ~= "string" then
            invalid("invalid option pattern or unit")
        end
    end
end

--- Reads the catalog and refuses anything the generators did not review.
---@param path? string
---@return table
function M.load_catalog(path)
    local data = json.read(path or M.CATALOG)
    if data.schema_version ~= 1 or data.support_floor ~= "3.3a" then
        invalid("unsupported option catalog schema or floor")
    end
    local pinned = {}
    for _, pin in ipairs(M.PINS) do
        pinned[pin[1]] = pin[2]
        if data.releases[pin[1]] == nil then
            invalid("option catalog must describe every pinned release")
        end
    end
    for version in pairs(data.releases) do
        if pinned[version] == nil then
            invalid("option catalog must describe every pinned release")
        end
    end
    local identities = {}
    for _, key in ipairs(json.keys(data.definitions)) do
        local item = data.definitions[key]
        check_definition(key, item)
        local identity = canonical(item)
        if identities[identity] then
            invalid("duplicate option definition")
        end
        identities[identity] = true
    end
    local referenced = {}
    for _, version in ipairs(json.keys(data.releases)) do
        local release = data.releases[version]
        if release.revision ~= pinned[version] then
            invalid("option catalog release pin changed")
        end
        local inventory = table.concat(json.keys(release.sources), ",")
        if
            inventory ~= "options-table.c,options.c,tmux.h"
            and inventory ~= "options-table.c,tmux.h,options.c"
        then
            local wanted = { ["options-table.c"] = true, ["options.c"] = true, ["tmux.h"] = true }
            local count = 0
            for path_name in pairs(release.sources) do
                count = count + 1
                if not wanted[path_name] then
                    invalid("option catalog source inventory changed")
                end
            end
            if count ~= 3 then
                invalid("option catalog source inventory changed")
            end
        end
        for path_name, source in pairs(release.sources) do
            if not (source.sha256:match("^%x+$") and #source.sha256 == 64) then
                invalid("invalid source digest")
            end
            local url = ("https://github.com/tmux/tmux/blob/%s/%s"):format(
                pinned[version],
                path_name
            )
            if source.url ~= url then
                invalid("source URL does not identify the pinned file")
            end
        end
        for name, entry in pairs(release.entries) do
            local definition = data.definitions[entry.definition]
            if definition == nil or definition.name ~= name then
                invalid("release map points at the wrong option definition")
            end
            if not is_integer(entry.line) or entry.line < 1 then
                invalid("invalid option source anchor")
            end
            referenced[entry.definition] = true
        end
    end
    for key in pairs(data.definitions) do
        if not referenced[key] then
            invalid("option catalog contains unused definitions")
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
]==]
-- luacheck: pop

local HEAD = {
    "-- Generated by scripts/generate/generate.lua options; edit data/tmux-options.json.",
    'local errors = require("libtmux._internal.error")',
    "local M = {}",
    "",
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
    "---@field unit? string",
    "",
}

local function names_of(data, hook)
    local seen, names = {}, {}
    for _, key in ipairs(json.keys(data.definitions)) do
        local item = data.definitions[key]
        if item.hook == hook and not seen[item.name] then
            seen[item.name] = true
            names[#names + 1] = item.name
        end
    end
    table.sort(names)
    return names
end

---@param data table
---@return string
function M.generate_lua(data)
    local lines = {}
    for index, line in ipairs(HEAD) do
        lines[index] = line
    end
    for _, family in ipairs({ { false, "OptionName" }, { true, "HookName" } }) do
        lines[#lines + 1] = "---@alias libtmux." .. family[2]
        for _, name in ipairs(names_of(data, family[1])) do
            lines[#lines + 1] = "---| " .. render.literal(name)
        end
        lines[#lines + 1] = ""
    end
    lines[#lines + 1] = "---@type table<string, libtmux.OptionDescriptor>"
    lines[#lines + 1] = "local definitions = " .. render.literal(data.definitions)
    local maps, map_keys, by_identity, release_keys = {}, {}, {}, {}
    for _, pin in ipairs(M.PINS) do
        local version = pin[1]
        local entries = json.object({}, {})
        local entry_keys = json.keys(entries)
        local release = data.releases[version]
        for _, name in ipairs(json.keys(release.entries)) do
            entries[name] = release.entries[name].definition
            entry_keys[#entry_keys + 1] = name
        end
        local identity = canonical(entries)
        if by_identity[identity] == nil then
            local key = "c" .. (#map_keys + 1)
            by_identity[identity] = key
            maps[key] = entries
            map_keys[#map_keys + 1] = key
        end
        release_keys[#release_keys + 1] = { version, by_identity[identity] }
    end
    local catalogs = json.object(map_keys, maps)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "local catalogs = " .. render.literal(catalogs)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "local releases = {"
    for _, row in ipairs(release_keys) do
        lines[#lines + 1] = ("[%s] = catalogs.%s,"):format(render.literal(row[1]), row[2])
    end
    lines[#lines + 1] = "}"
    lines[#lines + 1] = ""
    lines[#lines + 1] = RUNTIME
    return render.format(table.concat(lines, "\n"))
end

local function describe(item)
    local value
    if item.native_type == "choice" then
        local choices = {}
        for index, choice in ipairs(item.choices) do
            choices[index] = "`" .. choice .. "`"
        end
        value = table.concat(choices, ", ")
    elseif item.native_type == "number" then
        value = ("%d..%d"):format(item.minimum, item.maximum)
    else
        value = item.native_type
    end
    if item.style then
        value = "style string"
    end
    if item.array then
        value = value .. "; sparse array"
    end
    return value
end

local DOCS_HEAD = [==[
# tmux option and hook reference

This generated catalog records every canonical built-in option and hook
in the supported tmux releases listed below. It describes native types
and storage scopes; it does not establish runtime or platform compatibility.
Edit [the catalog](../data/tmux-options.json), then regenerate:

```console
$ luajit scripts/generate/generate.lua options
```

Check generated Lua metadata and this reference without changing files:

```console
$ luajit scripts/generate/generate.lua options --check
```

Both commands run offline with LuaJIT and the pinned StyLua formatter. They
do not download sources, build tmux or start a server.

## Values and scopes

Built-in names select their native storage scope; command flags alone do
not enforce the caller's intended scope. Session and window defaults are
separate global stores. Pane-capable options also support window storage;
there is no global pane store. Unknown release strings require new source
evidence: the private catalog does not fall back to the latest version.

Flags use booleans, numbers use exact bounded integers, and choices use
literal strings, including numeric-looking choices such as `"24"`. Keys,
colours, styles and commands retain their native string grammars. A command
value is tmux command-list source, not shell argv. Native grammar validation
and remote conditions such as shell suitability still require tmux.

Arrays retain native zero-based sparse indices and their element type.
The separator is a set of splitting characters, not a reversible codec.
An omitted array separator means space/comma; an empty separator preserves
one complete command-list entry. Indexed assignment avoids splitting.
All built-in hooks are command arrays; a scalar command option is not a
hook. User options beginning with `@` are separate string scalars.

Global built-in unset restores the default; local unset removes an override.
Native aliases, prefix matching, default values and descriptive option text
are outside this catalog. Source integer limits assume the supported target
ABIs' 32-bit `int` and 16-bit `short`; the largest bound is 4294967295.

## Source releases

| Release | Built-ins, including hooks | Hooks |
| --- | ---: | ---: |
]==]

---@param data table
---@return string
function M.generate_docs(data)
    local lines = { DOCS_HEAD }
    for _, pin in ipairs(M.PINS) do
        local release = data.releases[pin[1]]
        local total, hooks = 0, 0
        for _, entry in pairs(release.entries) do
            total = total + 1
            if data.definitions[entry.definition].hook then
                hooks = hooks + 1
            end
        end
        lines[#lines + 1] = ("| [%s](%s) | %d | %d |\n"):format(
            pin[1],
            release.sources["options-table.c"].url,
            total,
            hooks
        )
    end
    lines[#lines + 1] = [==[

Full commit identities, hashes for `options-table.c`, `options.c` and
`tmux.h`, and per-entry source anchors are recorded in the source catalog.
Repeated release labels below mean the extracted metadata is identical,
not that defaults or other native behavior are identical.

]==]
    for index, family in ipairs({ { false, "Options" }, { true, "Hooks" } }) do
        lines[#lines + 1] = (index > 1 and "\n" or "") .. "## " .. family[2] .. "\n\n"
        lines[#lines + 1] = "| Name | Releases | Scope | Value | Array separator |\n"
        lines[#lines + 1] = "| --- | --- | --- | --- | --- |\n"
        for _, name in ipairs(names_of(data, family[1])) do
            local variants, order = {}, {}
            for _, pin in ipairs(M.PINS) do
                local entry = data.releases[pin[1]].entries[name]
                if entry then
                    if not variants[entry.definition] then
                        variants[entry.definition] = {}
                        order[#order + 1] = entry.definition
                    end
                    table.insert(variants[entry.definition], pin[1])
                end
            end
            for _, key in ipairs(order) do
                local versions = variants[key]
                local item = data.definitions[key]
                local release = data.releases[versions[1]]
                local source = release.sources["options-table.c"].url
                    .. "#L"
                    .. ("%d"):format(release.entries[name].line)
                local separator = "—"
                if item.array then
                    separator = item.array_separator == "" and "empty"
                        or "`" .. json.encode(item.array_separator) .. "`"
                end
                lines[#lines + 1] = ("| [`%s`](%s) | %s | %s | %s | %s |\n"):format(
                    name,
                    source,
                    table.concat(versions, ", "),
                    table.concat(item.scopes, ", "),
                    describe(item),
                    separator
                )
            end
        end
    end
    return table.concat(lines)
end

return M
