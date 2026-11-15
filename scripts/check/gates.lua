-- The development gates: what each one runs, with the budget each command gets.
local files = require("support.files")
local fs = require("support.fs")
local proc = require("support.proc")
local readme_examples = require("docs.readme_examples")
local repo = require("support.repo")
local runtime = require("support.runtime")
local sandbox = require("tests.support.sandbox")

local M = {}

local ROOT = repo.root

M.GATES = {
    "unit",
    "mid",
    "format",
    "lint",
    "generated",
    "docs",
    "integration",
    "refusal",
    "package",
    "types",
    "outer",
}

--- The seconds a whole gate may take: the loops of CONTRIBUTING.md.
---@param gate string
---@return integer
function M.budget(gate)
    return gate == "unit" and 5 or gate == "mid" and 30 or 300
end

--- The environment for a child: nothing that selects a tmux server, and no Lua search paths of
--- this process.
---@param env? table<string, string>
---@return table<string, string>
function M.clean_environment(env)
    local clean = {}
    for name, value in pairs(env or proc.environment()) do
        if
            not sandbox.ambient(name)
            and name:sub(1, 8) ~= "LUA_PATH"
            and name:sub(1, 9) ~= "LUA_CPATH"
            and name:sub(1, 8) ~= "LUA_INIT"
        then
            clean[name] = value
        end
    end
    return clean
end

--- The environment a test interpreter needs: its own rock tree, this checkout's sources and the
--- executable the tests name.
---@param lua string
---@param env? table<string, string>
---@return table<string, string>
function M.lua_environment(lua, env)
    local clean = M.clean_environment(env)
    local rt = runtime.identify(lua)
    local tree = ROOT .. "/.cache/rocks/" .. rt.cache_label
    local share = ("%s/share/lua/%s"):format(tree, rt.version)
    clean.LUA_PATH = table.concat({
        ROOT .. "/lua/?.lua",
        ROOT .. "/lua/?/init.lua",
        ROOT .. "/?.lua",
        ROOT .. "/?/init.lua",
        share .. "/?.lua",
        share .. "/?/init.lua",
    }, ";")
    clean.LUA_CPATH = ("%s/lib/lua/%s/?.so"):format(tree, rt.version)
    local parent = rt.executable:match("^(.*)/[^/]+$")
    clean.PATH = table.concat({ tree .. "/bin", parent, clean.PATH or "" }, ":")
    clean.LIBTMUX_TEST_LUA = rt.executable
    return clean
end

--- A tool on PATH, or an error naming the missing prerequisite.
---@param name string
---@return string
function M.tool(name)
    local ok, found = pcall(runtime.executable_path, name)
    if not ok then
        error("Missing " .. name .. "; run the documented bootstrap first", 0)
    end
    return found
end

local function lines_of(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

---@param heading string
---@return string
function M.slug(heading)
    local plain = heading:gsub("<[^>]+>", ""):gsub("[`*_~]", ""):lower()
    local text = plain:gsub("[^%w_%- \128-\255]", "")
    return (text:match("^%s*(.-)%s*$"):gsub("%s+", "-"))
end

local slug = M.slug

local anchor_cache = {}

--- The fragments a Markdown file can be linked to: its headings and its named anchors.
local function anchors(path)
    if not anchor_cache[path] then
        local text = files.read(path)
        local found, counts = {}, {}
        for name in text:gmatch('<a%s+name="([^"]+)"') do
            found[name] = true
        end
        for name in text:gmatch('<a%s+id="([^"]+)"') do
            found[name] = true
        end
        for _, line in ipairs(lines_of(text)) do
            local hashes, title = line:match("^(#+)%s+(.-)%s*#*%s*$")
            if hashes and #hashes <= 6 and title ~= "" then
                local name = slug(title)
                local duplicate = counts[name] or 0
                counts[name] = duplicate + 1
                found[duplicate > 0 and ("%s-%d"):format(name, duplicate) or name] = true
            end
        end
        anchor_cache[path] = found
    end
    return anchor_cache[path]
end

local function unquote(text)
    return (
        text:gsub("%%(%x%x)", function(hex)
            return string.char(tonumber(hex, 16))
        end)
    )
end

--- The Markdown files whose links are checked.
local function documents()
    local found = { "AGENTS.md", "CHANGES.md" }
    for _, name in ipairs(fs.list(ROOT)) do
        if name:match("^README.*%.md$") then
            found[#found + 1] = name
        end
    end
    for _, directory in ipairs(fs.list(ROOT .. "/lua")) do
        if fs.is_file(ROOT .. "/lua/" .. directory .. "/README.md") then
            found[#found + 1] = "lua/" .. directory .. "/README.md"
        end
    end
    for _, name in ipairs(fs.list(ROOT .. "/.github")) do
        if name:match("%.md$") then
            found[#found + 1] = ".github/" .. name
        end
    end
    for _, relative in ipairs(fs.walk(ROOT .. "/docs")) do
        if relative:match("%.md$") and not relative:match("^_build/") then
            found[#found + 1] = "docs/" .. relative
        end
    end
    return found
end

--- Fails on a Markdown link to a missing file or heading, on a README that differs from its
--- sources, and on a CLAUDE.md that is not a relative link to AGENTS.md.
function M.docs()
    for _, relative in ipairs(documents()) do
        local path = ROOT .. "/" .. relative
        local directory = path:match("^(.*)/[^/]+$")
        for target in files.read(path):gmatch("%]%(([^)]+)%)") do
            local destination
            if target:match("^https?:") or target:match("^mailto:") then
                destination = nil
            elseif target:sub(1, 1) == "#" then
                destination = path
            else
                local name = target:match("^([^#]*)")
                destination = name ~= "" and (directory .. "/" .. name) or path
            end
            if destination and not (fs.stat(destination)) then
                error(("Broken link in %s: %s"):format(relative, target), 0)
            end
            if destination and destination:match("%.md$") and target:find("#", 1, true) then
                local fragment = unquote(target:match("#(.*)$"))
                if fragment ~= "" and not anchors(destination)[fragment] then
                    error(("Broken anchor in %s: %s"):format(relative, target), 0)
                end
            end
        end
    end
    readme_examples.check_readmes(ROOT)
    local link = require("support.uv").fs_readlink(ROOT .. "/CLAUDE.md")
    if link ~= "AGENTS.md" then
        error("CLAUDE.md must remain a relative symlink to AGENTS.md", 0)
    end
end

--- One command a gate runs.
---@class check.Step
---@field argv? string[]
---@field env? table<string, string>
---@field timeout? number
---@field call? fun()

---@class check.Options
---@field lua string
---@field nvim? string
---@field suites string[]

--- The steps of one gate, in order. `mid` and `outer` are the other gates in sequence.
---@param gate string
---@param options check.Options
---@return check.Step[]
function M.steps(gate, options)
    local luajit = arg and arg[-1] or "luajit"
    luajit = runtime.executable_path(luajit)
    local lua = M.tool(options.lua)
    local env = M.lua_environment(lua)
    if options.nvim then
        env.LIBTMUX_TEST_NVIM = runtime.executable_path(options.nvim)
    end
    local function lint_command()
        local lint_lua = ROOT .. "/.cache/toolchains/lua-5.4.9/bin/lua"
        if not fs.is_file(lint_lua) then
            error("Luacheck needs the pinned Lua 5.4.9 tool interpreter; see CONTRIBUTING.md", 0)
        end
        local lint_env = M.lua_environment(lint_lua)
        local tree = ROOT .. "/.cache/rocks/" .. runtime.identify(lint_lua).cache_label
        local executable = tree .. "/bin/luacheck"
        if not fs.is_file(executable) then
            error("Missing luacheck; run scripts/bootstrap/bootstrap.lua rocks lint first", 0)
        end
        return {
            argv = { executable, "lua", "tests", "examples", "scripts" },
            env = lint_env,
            timeout = 10,
        }
    end
    local plans = {
        unit = function()
            local suites = options.suites
            if #suites == 0 then
                for _, name in ipairs(fs.list(ROOT .. "/tests/unit")) do
                    if name:match("%.lua$") then
                        suites[#suites + 1] = (name:gsub("%.lua$", ""))
                    end
                end
            end
            if #suites == 0 then
                error("No unit suites discovered", 0)
            end
            local argv = { lua, "tests/run.lua" }
            for _, name in ipairs(suites) do
                argv[#argv + 1] = name
            end
            return { { argv = argv, env = env, timeout = 5 } }
        end,
        format = function()
            return {
                {
                    argv = {
                        M.tool("stylua"),
                        "--check",
                        "--syntax",
                        "Lua51",
                        "lua",
                        "tests",
                        "examples",
                        "rockspecs",
                        "scripts",
                    },
                    timeout = 10,
                },
            }
        end,
        lint = function()
            return { lint_command() }
        end,
        docs = function()
            return { { call = M.docs }, { argv = { "git", "diff", "--check" }, timeout = 5 } }
        end,
        generated = function()
            return {
                {
                    argv = { luajit, "scripts/generate/generate.lua", "fields", "--check" },
                    env = env,
                    timeout = 5,
                },
                {
                    argv = { luajit, "scripts/generate/generate.lua", "options", "--check" },
                    env = env,
                    timeout = 5,
                },
                {
                    argv = { luajit, "scripts/release/main.lua", "prepare", "--check" },
                    timeout = 5,
                },
                { argv = { luajit, "scripts/release/main.lua", "changelogs" }, timeout = 5 },
            }
        end,
        integration = function()
            return { { argv = { "python", "tests/run_integration.py" }, env = env } }
        end,
        refusal = function()
            local refuse = {}
            for name, value in pairs(env) do
                refuse[name] = value
            end
            refuse.LIBTMUX_REQUIRE_REFUSED = "1"
            return {
                {
                    argv = {
                        "python",
                        "tests/run_integration.py",
                        "--pattern",
                        "test_version_check.py",
                    },
                    env = refuse,
                },
            }
        end,
        package = function()
            return { { argv = { luajit, "scripts/package/main.lua", "--lua", lua }, env = env } }
        end,
        types = function()
            local server = ROOT .. "/.cache/tools/luals-3.19.1/bin/lua-language-server"
            if not fs.is_file(server) then
                error("Missing pinned LuaLS 3.19.1; see CONTRIBUTING.md", 0)
            end
            return {
                {
                    argv = {
                        server,
                        "--check=.",
                        "--checklevel=Warning",
                        "--logpath=.cache/luals",
                    },
                    env = env,
                },
                {
                    argv = {
                        luajit,
                        "scripts/docs/docs.lua",
                        "export",
                        "--luals",
                        server,
                        "--check",
                    },
                    env = env,
                },
                {
                    argv = { luajit, "scripts/check_editor/check_editor.lua" },
                    env = env,
                    timeout = 20,
                },
            }
        end,
    }
    if gate == "mid" then
        local steps = {}
        -- Mid-loop work, so the mid budget: the Python tooling that remains is subprocess-bound.
        steps[#steps + 1] = {
            argv = { "python", "-m", "unittest", "discover", "-s", "tests/tooling", "-v" },
            timeout = 30,
        }
        local suites = {}
        for _, directory in ipairs(fs.list(ROOT .. "/scripts")) do
            local tests = ROOT .. "/scripts/" .. directory .. "/tests"
            if fs.is_directory(tests) then
                for _, name in ipairs(fs.list(tests)) do
                    if name:match("^test_.*%.lua$") then
                        suites[#suites + 1] = "scripts/" .. directory .. "/tests/" .. name
                    end
                end
            end
        end
        local argv = { luajit, "scripts/support/run_tests.lua" }
        for _, suite in ipairs(suites) do
            argv[#argv + 1] = suite
        end
        steps[#steps + 1] = { argv = argv, timeout = 30 }
        steps[#steps + 1] = { argv = { M.tool("actionlint") }, timeout = 5 }
        for _, name in ipairs({ "unit", "format", "lint", "generated", "docs" }) do
            for _, step in ipairs(plans[name]()) do
                steps[#steps + 1] = step
            end
        end
        return steps
    elseif gate == "outer" then
        local steps = {}
        for _, name in ipairs({ "mid", "integration", "package", "types" }) do
            for _, step in ipairs(M.steps(name, options)) do
                steps[#steps + 1] = step
            end
        end
        return steps
    end
    return plans[gate]()
end

return M
