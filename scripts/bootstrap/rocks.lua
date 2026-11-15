-- Install the pinned development rocks into the tree of one Lua interpreter, outside every test
-- loop. Like runtimes.lua it uses only the standard library: the tree it fills holds luv.
local repo = require("support.repo")
local runtime = require("support.runtime")
local shell = require("support.shell")

local unpack = rawget(table, "unpack") or unpack
local M = {}

M.DEPENDENCIES = {
    dev = { { "luaunit", "3.5-1" }, { "lunajson", "1.2.3-1" }, { "argparse", "0.7.2-1" } },
    lint = { { "luafilesystem", "1.9.0-1" }, { "luacheck", "1.2.0-1" } },
    live = { { "luv", "1.52.1-0" } },
}

--- The luarocks command line for one interpreter's tree.
---@param lua support.LuaRuntime
---@param luarocks string
---@return string[] base
---@return string tree
function M.base(lua, luarocks)
    local tree = repo.root .. "/.cache/rocks/" .. lua.cache_label
    local prefix = lua.executable:match("^(.*)/bin/[^/]+$") or "."
    return {
        luarocks,
        "--lua-version=" .. lua.version,
        "--lua-dir=" .. prefix,
        "--tree=" .. tree,
    },
        tree
end

---@param groups string[]
---@param lua_name? string
---@param luarocks? string
function M.main(groups, lua_name, luarocks)
    if #groups == 0 then
        error("usage: bootstrap.lua rocks GROUP... [--lua=PATH] (dev, lint, live)", 0)
    end
    for _, group in ipairs(groups) do
        if not M.DEPENDENCIES[group] then
            error("Unknown rock group: " .. group, 0)
        end
    end
    local lua = runtime.identify(lua_name or "lua")
    local base = M.base(lua, luarocks or "luarocks")
    local env = { unset = runtime.LUA_VARIABLES, cwd = repo.root }
    local started = os.time()
    for _, group in ipairs(groups) do
        for _, rock in ipairs(M.DEPENDENCIES[group]) do
            local name, pin = rock[1], rock[2]
            local show = { unpack(base) }
            show[#show + 1] = "show"
            show[#show + 1] = name
            show[#show + 1] = pin
            if shell.run(show, env) == 0 then
                print("Installed: " .. name .. " " .. pin)
            else
                local install = { unpack(base) }
                install[#install + 1] = "install"
                install[#install + 1] = name
                install[#install + 1] = pin
                print(shell.check(install, env))
            end
        end
    end
    print(('{"bootstrap_seconds": %d}'):format(os.time() - started))
end

return M
