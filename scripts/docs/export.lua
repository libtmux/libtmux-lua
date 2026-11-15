-- Export the public LuaLS model, the source guides and the examples as deterministic JSON, for
-- the documentation site to render.
local api_examples = require("docs.api_examples")
local files = require("support.files")
local fs = require("support.fs")
local json = require("support.json")
local repo = require("support.repo")
local shell = require("support.shell")

local M = {}

M.EXPECTED_MODULES = {
    ["libtmux.query"] = {
        "NULL",
        "compile",
        "count",
        "decode_json",
        "encode_json",
        "exists",
        "filter",
        "first",
        "iter",
        "one",
        "one_or_nil",
        "select",
        "to_table",
        "where",
    },
    ["libtmux.runtime.luv"] = { "run" },
    ["libtmux.runtime.nvim"] = { "start" },
}
M.EXPECTED_TYPES = {
    "libtmux.Buffer",
    "libtmux.Client",
    "libtmux.Configurable",
    "libtmux.Entity",
    "libtmux.Pane",
    "libtmux.Reference",
    "libtmux.Request",
    "libtmux.Runtime",
    "libtmux.Selection",
    "libtmux.Server",
    "libtmux.Session",
    "libtmux.Snapshot",
    "libtmux.Window",
    "libtmux.WindowLink",
}
-- Public modules whose annotations the export adds to a copy of the source, so the runtime
-- modules stay free of export-only tags.
M.ANNOTATED = {
    { "libtmux/query.lua", "libtmux.query" },
    { "libtmux/runtime/luv.lua", "libtmux.runtime.luv" },
    { "libtmux/runtime/nvim.lua", "libtmux.runtime.nvim" },
}

local function fail(message)
    error(message, 0)
end

local function is_integer(value)
    return type(value) == "number" and value % 1 == 0
end

--- A copy of a LuaLS node without its DOC keys, files under lua/, and 1-based start and finish.
function M.normalize(value, key)
    if type(value) ~= "table" then
        return value
    end
    if not json.is_object(value) then
        if
            (key == "start" or key == "finish")
            and #value == 2
            and is_integer(value[1])
            and is_integer(value[2])
        then
            return { value[1] + 1, value[2] }
        end
        local list = {}
        for index, item in ipairs(value) do
            list[index] = M.normalize(item)
        end
        return list
    end
    local keys, result = {}, {}
    for _, child_key in ipairs(json.keys(value)) do
        if child_key ~= "DOC" then
            result[child_key] = M.normalize(value[child_key], child_key)
            keys[#keys + 1] = child_key
        end
    end
    if type(result.file) == "string" then
        result.file = "lua/" .. result.file:gsub("^lua/", "")
    end
    return json.object(keys, result)
end

local function sort_key(item)
    local start = item.start
    return { item.name or "", item.type or "", item.file or "", start and start[1] or 0 }
end

local function before(left, right)
    for index = 1, 4 do
        if left[index] ~= right[index] then
            return left[index] < right[index]
        end
    end
    return false
end

--- A stable sort: equal keys keep the order they had.
local function sorted(list, key)
    local rows = {}
    for index, item in ipairs(list) do
        rows[index] = { key(item), index, item }
    end
    table.sort(rows, function(a, b)
        if before(a[1], b[1]) then
            return true
        elseif before(b[1], a[1]) then
            return false
        end
        return a[2] < b[2]
    end)
    local result = {}
    for index, row in ipairs(rows) do
        result[index] = row[3]
    end
    return result
end

local function declaration_key(item)
    return sort_key(item)
end

---@param raw table[] The LuaLS documentation entries.
---@return table[]
function M.public_declarations(raw)
    local declarations = {}
    for _, entry in ipairs(raw) do
        local name = entry.name or ""
        if name:sub(1, 8) == "libtmux." then
            local item = M.normalize(entry)
            local fields = {}
            for _, field in ipairs(item.fields or {}) do
                if (field.name or ""):sub(1, 1) ~= "_" then
                    fields[#fields + 1] = field
                end
            end
            item.fields = sorted(fields, declaration_key)
            item.defines = sorted(item.defines or {}, declaration_key)
            local keys = json.keys(item)
            for _, extra in ipairs({ "fields", "defines" }) do
                local present = false
                for _, key in ipairs(keys) do
                    present = present or key == extra
                end
                if not present then
                    keys[#keys + 1] = extra
                end
            end
            declarations[#declarations + 1] = item
        end
    end
    table.sort(declarations, function(a, b)
        return a.name < b.name
    end)
    return declarations
end

local function read_lines(path)
    local lines = {}
    for line in (files.read(path) .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

---@param source string
---@return table
function M.rock_metadata(source)
    local specs = {}
    for _, name in ipairs(fs.list(source .. "/rockspecs")) do
        if name:match("^libtmux%-.*%.rockspec$") then
            specs[#specs + 1] = name
        end
    end
    if #specs == 0 then
        fail("could not find libtmux rockspec")
    end
    local release = specs[#specs]
    for _, name in ipairs(specs) do
        if not name:find("-scm-", 1, true) then
            release = name
            break
        end
    end
    local version, tag
    for _, line in ipairs(read_lines(source .. "/rockspecs/" .. release)) do
        version = version or line:match('^version = "([^"]+)"')
        tag = tag or line:match('^%s+tag = "([^"]+)"')
    end
    if not version or not tag then
        fail("could not read rock version and source tag")
    end
    return { name = "libtmux", version = version, source_tag = tag }
end

--- The guides or examples under `source`, as { path, content } rows sorted by path.
---@param source string
---@param entries { [1]: string, [2]: string }[] pairs of a directory (or file) and a file suffix
function M.content_files(source, entries)
    local paths, seen = {}, {}
    local function add(path)
        if not seen[path] then
            seen[path] = true
            paths[#paths + 1] = path
        end
    end
    for _, entry in ipairs(entries) do
        local base, suffix = entry[1], entry[2]
        if suffix == "" then
            if fs.is_file(source .. "/" .. base) then
                add(base)
            end
        elseif fs.is_directory(source .. "/" .. base) then
            for _, relative in ipairs(fs.walk(source .. "/" .. base)) do
                if relative:sub(-#suffix) == suffix then
                    add(base .. "/" .. relative)
                end
            end
        end
    end
    table.sort(paths)
    local rows = {}
    for index, path in ipairs(paths) do
        rows[index] = json.object(
            { "path", "content" },
            { path = path, content = files.read(source .. "/" .. path) }
        )
    end
    return rows
end

---@param payload table
function M.validate(payload)
    local declarations = {}
    for _, entry in ipairs(payload.declarations) do
        declarations[entry.name] = entry
    end
    local missing = {}
    for _, name in ipairs(M.EXPECTED_TYPES) do
        if not declarations[name] then
            missing[#missing + 1] = name
        end
    end
    if #missing > 0 then
        table.sort(missing)
        fail("missing public types: " .. table.concat(missing, ", "))
    end
    for module, expected in pairs(M.EXPECTED_MODULES) do
        local entry = declarations[module]
        if not entry then
            fail("missing public module: " .. module)
        end
        local actual, absent, extra = {}, {}, {}
        for _, field in ipairs(entry.fields or {}) do
            actual[field.name] = true
        end
        local wanted = {}
        for _, name in ipairs(expected) do
            wanted[name] = true
            if not actual[name] then
                absent[#absent + 1] = name
            end
        end
        for name in pairs(actual) do
            if not wanted[name] then
                extra[#extra + 1] = name
            end
        end
        table.sort(absent)
        table.sort(extra)
        if #absent > 0 or #extra > 0 then
            fail(
                ("public module coverage differs for %s: missing=[%s] extra=[%s]"):format(
                    module,
                    table.concat(absent, ", "),
                    table.concat(extra, ", ")
                )
            )
        end
    end
    for _, entry in ipairs(payload.declarations) do
        local nodes = {}
        for _, group in ipairs({ entry.defines or {}, entry.fields or {} }) do
            for _, node in ipairs(group) do
                nodes[#nodes + 1] = node
            end
        end
        for _, node in ipairs(nodes) do
            local path = node.file
            if path and (path:sub(1, 4) ~= "lua/" or path:find("/tests/", 1, true)) then
                fail("invalid declaration source: " .. path)
            end
            if (node.name or ""):sub(1, 1) == "_" then
                fail(("private helper exported: %s.%s"):format(entry.name, node.name))
            end
        end
    end
    local text = json.encode(payload, nil, true)
    if text:find("/home/", 1, true) or text:find("/Users/", 1, true) then
        fail("machine-specific path in export")
    end
    if text:find("luals.config", 1, true) or text:find("package.loaded", 1, true) then
        fail("tool configuration leaked into export")
    end
end

local function annotate(source_lua)
    for _, row in ipairs(M.ANNOTATED) do
        local path, module = source_lua .. "/" .. row[1], row[2]
        local text = files.read(path)
        local marker = "---@class " .. module
        if not text:find(marker, 1, true) then
            local replaced, count = text:gsub("^local M = {}\n", marker .. "\nlocal M = {}\n", 1)
            if count ~= 1 then
                replaced, count =
                    text:gsub("\nlocal M = {}\n", "\n" .. marker .. "\nlocal M = {}\n", 1)
            end
            if count ~= 1 then
                fail("could not annotate public module " .. module)
            end
            files.write(path, replaced)
        end
    end
end

---@param source string The checkout to export.
---@param luals string The language server executable.
---@return table payload
function M.build_payload(source, luals)
    local temporary = fs.mkdtemp("libtmux-lua-docs-")
    local ok, result = pcall(function()
        fs.copy_tree(source .. "/lua", temporary .. "/source/lua")
        annotate(temporary .. "/source/lua")
        fs.mkdir_p(temporary .. "/output")
        fs.mkdir_p(temporary .. "/log")
        local code, output = shell.run({
            luals,
            "--doc=" .. temporary .. "/source/lua",
            "--doc_out_path=" .. temporary .. "/output",
            "--configpath=" .. repo.root .. "/.luarc.json",
            "--logpath=" .. temporary .. "/log",
        }, { cwd = source })
        if code ~= 0 then
            fail("LuaLS export failed: " .. output)
        end
        return json.read(temporary .. "/output/doc.json")
    end)
    fs.remove_tree(temporary)
    if not ok then
        error(result, 0)
    end
    local declarations = M.public_declarations(result)
    local revision = shell
        .check({ "git", "rev-parse", "HEAD" }, { cwd = source })
        :match("^(%x+)%s*$")
    if not revision or #revision ~= 40 then
        fail("could not resolve source revision")
    end
    local version = shell.check({ luals, "--version" }):match("%d+%.%d+%.%d+")
    if not version then
        fail("could not resolve LuaLS version")
    end
    local payload = {
        schema = 1,
        port = "lua",
        source = { repository = "libtmux/libtmux-lua", revision = revision },
        exporter = { name = "scripts/docs/docs.lua", version = 1, luals = version },
        package = M.rock_metadata(source),
        declarations = declarations,
        guides = M.content_files(source, { { "README.md", "" }, { "docs", ".md" } }),
        examples = M.content_files(source, { { "examples", ".lua" } }),
    }
    -- Historical sources predate complete examples; an opted-in directory must validate.
    if fs.is_directory(source .. "/examples/api") then
        payload.api_examples =
            api_examples.load_examples(source, api_examples.public_symbols(declarations))
    end
    M.validate(payload)
    return payload
end

local function write_bundle(output, name, rows)
    local directory = output .. "/" .. name
    fs.remove_tree(directory)
    for _, entry in ipairs(rows) do
        local target = directory .. "/" .. entry.path
        fs.mkdir_p(target:match("^(.*)/[^/]+$"))
        files.write(target, entry.content)
    end
end

--- Exports the source and, unless `check` is set, writes api.json and the guide and example
--- bundles into `output`. Returns a one-line summary.
---@param options { source: string, luals: string, output: string, check: boolean }
---@return string
function M.run(options)
    if not fs.is_file(options.source .. "/lua/libtmux/init.lua") then
        fail("Invalid source checkout: " .. options.source)
    end
    if not fs.is_file(options.luals) then
        fail("Missing pinned LuaLS 3.19.1; see CONTRIBUTING.md")
    end
    local payload = M.build_payload(options.source, options.luals)
    if not options.check then
        fs.mkdir_p(options.output)
        json.write(options.output .. "/api.json", payload, 2, true)
        write_bundle(options.output, "guides", payload.guides)
        write_bundle(options.output, "examples", payload.examples)
    end
    local fields = 0
    for _, item in ipairs(payload.declarations) do
        fields = fields + #(item.fields or {})
    end
    return ("Documentation export: %d declarations; %d fields"):format(
        #payload.declarations,
        fields
    )
end

return M
