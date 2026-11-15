-- Validate source-owned, complete API examples before they are exported or executed.
local files = require("support.files")
local fs = require("support.fs")
local json = require("support.json")

local M = {}

--- The documented symbols of the exported declarations: each type and its `Type.field` or
--- `Type:method` members.
---@param declarations table[]
---@return table<string, boolean>
function M.public_symbols(declarations)
    local symbols = {}
    for _, declaration in ipairs(declarations) do
        local name = declaration.name
        symbols[name] = true
        for _, field in ipairs(declaration.fields or {}) do
            if field.name and field.name ~= "" then
                local view = field.view or ""
                local receiver = view:find("%f[%w_]self%s*:") ~= nil
                symbols[name .. (receiver and ":" or ".") .. field.name] = true
            end
        end
    end
    return symbols
end

local function invalid(message)
    error("Invalid complete API examples: " .. message, 0)
end

local function require_that(condition, message)
    if not condition then
        invalid(message)
    end
end

local function check_keys(value, expected, optional)
    local allowed = {}
    for _, name in ipairs(expected) do
        allowed[name] = true
        require_that(
            type(value) == "table" and value[name] ~= nil,
            "unexpected or missing manifest fields"
        )
    end
    for _, name in ipairs(optional or {}) do
        allowed[name] = true
    end
    for name in pairs(value) do
        require_that(allowed[name], "unexpected or missing manifest fields")
    end
end

local function non_blank(text)
    return type(text) == "string" and text:find("%S") ~= nil
end

--- Reads the manifest of the complete examples under `root` and checks it against the files.
--- `symbols`, when given, is the set a target must belong to.
---@param root string
---@param symbols? table<string, boolean>
---@return table manifest
function M.load_examples(root, symbols)
    local manifest = json.read(root .. "/examples/api/manifest.json")
    check_keys(manifest, { "schema", "setup", "examples" })
    require_that(manifest.schema == 1, "unsupported schema")
    local setup = manifest.setup
    check_keys(setup, { "lua", "luv" })
    require_that(
        type(setup.lua) == "string" and setup.lua:match("^5%.[1-5]%.%d+$"),
        "Lua version must be pinned"
    )
    require_that(
        type(setup.luv) == "string" and setup.luv:match("^%d+%.%d+%.%d+%-%d+$"),
        "luv version must be pinned"
    )
    require_that(type(manifest.examples) == "table" and #manifest.examples > 0, "no examples")
    local ids, targets, listed = {}, {}, {}
    for _, example in ipairs(manifest.examples) do
        check_keys(example, { "id", "symbols", "file", "description", "stdout" }, { "min_tmux" })
        local name = example.id
        require_that(type(name) == "string" and name:match("^[a-z][a-z_]*$"), "invalid example id")
        require_that(not ids[name], "duplicate example id")
        ids[name] = true
        require_that(
            example.file == "examples/api/" .. name .. ".lua",
            "unexpected example file path"
        )
        local path = root .. "/" .. example.file
        require_that(
            fs.is_file(path) and not fs.is_symlink(path),
            "example file is missing or linked"
        )
        local content = files.read(path)
        require_that(
            content:find("%S") and content:sub(-1) == "\n" and not content:find("\r", 1, true),
            "example files must contain complete UTF-8 text with LF endings"
        )
        listed[example.file] = true
        require_that(non_blank(example.description), "missing task description")
        require_that(
            non_blank(example.stdout) and example.stdout:sub(-1) == "\n",
            "missing expected output"
        )
        require_that(
            example.min_tmux == nil
                or (type(example.min_tmux) == "string" and example.min_tmux:match("^%d+%.%d+$")),
            "min_tmux must be a release such as 3.7"
        )
        require_that(
            type(example.symbols) == "table" and #example.symbols > 0,
            "missing API targets"
        )
        for _, symbol in ipairs(example.symbols) do
            require_that(
                type(symbol) == "string" and symbol:match("^libtmux%.[%w_%.]+[:%.][%w_]+$"),
                "invalid API target"
            )
            require_that(not targets[symbol], "duplicate API target")
            require_that(symbols == nil or symbols[symbol], "unknown API target: " .. symbol)
            targets[symbol] = true
        end
    end
    for _, name in ipairs(fs.list(root .. "/examples/api")) do
        if name:match("%.lua$") then
            require_that(listed["examples/api/" .. name], "unlisted Lua example")
        end
    end
    return manifest
end

return M
