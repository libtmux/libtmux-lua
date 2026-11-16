-- Choose the interpreter a CI job runs its tests under, and build it unless mise already provides
-- it. Runs before the tool interpreter exists, so it uses only the standard library.
local files = require("support.files")
local repo = require("support.repo")
local runtimes = require("bootstrap.runtimes")
local shell = require("support.shell")

local M = {}

--- The Lua that the repository's mise configuration installs; every other runtime is built.
M.PROVIDED = "5.5.1"

--- Where `runtimes` puts a built interpreter.
---@param version string a PUC Lua release or `luajit`
---@param root string the repository root
---@return string
function M.built_path(version, root)
    if version == "luajit" then
        return root .. "/.cache/toolchains/luajit-2.1/bin/luajit"
    end
    return root .. "/.cache/toolchains/lua-" .. version .. "/bin/lua"
end

--- Names the interpreter for a runtime, building it first when mise does not provide it, and
--- appends `TEST_LUA=<path>` to the GitHub environment file when one is given.
---@param version string
---@param github_env? string the GITHUB_ENV file
---@param which? fun(): string the path of mise's Lua; replaced by a test
---@return string
function M.main(version, github_env, which)
    local path
    if version == M.PROVIDED then
        path = (which or function()
            return shell.check({ "mise", "which", "lua" })
        end)():gsub("%s+$", "")
    else
        runtimes.main({ version })
        path = M.built_path(version, repo.root)
    end
    if github_env then
        files.append(github_env, "TEST_LUA=" .. path .. "\n")
    end
    return path
end

return M
