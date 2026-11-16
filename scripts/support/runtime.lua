-- Identify a Lua interpreter's ABI and name its rock tree, so PUC Lua 5.1 and LuaJIT, which share
-- the 5.1 ABI, never share compiled rocks.
local shell = require("support.shell")

local M = {}

--- Environment names a child must not inherit: another interpreter's search paths.
M.LUA_VARIABLES = { "LUA_PATH", "LUA_CPATH", "LUA_INIT", "LUAROCKS_CONFIG" }

---@param path string
---@return boolean
local function is_executable_file(path)
    return shell.run({ "test", "-x", path }) == 0 and shell.run({ "test", "!", "-d", path }) == 0
end

--- The absolute path of an executable on PATH. A mise shim resolves to the tool it stands for.
---@param name string
---@return string
function M.executable_path(name)
    local found
    if name:find("/", 1, true) then
        found = is_executable_file(name) and name or nil
    else
        for directory in (os.getenv("PATH") or ""):gmatch("[^:]+") do
            if is_executable_file(directory .. "/" .. name) then
                found = directory .. "/" .. name
                break
            end
        end
    end
    if not found then
        error("Missing executable: " .. name, 0)
    end
    if found:sub(1, 1) ~= "/" then
        -- A build runs in another directory, so a relative path would stop naming it.
        found = assert(os.getenv("PWD"), "PWD is unset") .. "/" .. found:gsub("^%./", "")
    end
    local _, target = shell.run({ "readlink", "-f", found })
    target = target:match("[^\n]+") or found
    if target:match("/mise$") and not found:match("/mise$") then
        local code, output = shell.run({ target, "which", found:match("[^/]+$") })
        if code == 0 then
            return output:match("[^\n]+")
        end
    end
    return found
end

---@class support.LuaRuntime
---@field executable string
---@field version string "5.1" to "5.5"
---@field cache_label string "5.4", or "luajit-2.1.<build>"
---@field jit_version? string

---@param executable string
---@return support.LuaRuntime
function M.identify(executable)
    local resolved = M.executable_path(executable)
    local output = shell.check({
        resolved,
        "-e",
        'io.write((_VERSION:gsub("Lua ", "")), "\\n"); if jit then io.write(jit.version) end',
    }, { unset = M.LUA_VARIABLES })
    local lines = {}
    for line in output:gmatch("[^\n]+") do
        lines[#lines + 1] = line
    end
    local version = lines[1]
    if #lines > 2 or not (version and version:match("^5%.[1-5]$")) then
        error("Interpreter reports an unrecognized Lua ABI", 0)
    end
    local cache_label, jit_version = version, lines[2]
    if jit_version then
        local build = jit_version:match("^LuaJIT (2%.1[%.%w%-]*)$")
        if not build or version ~= "5.1" then
            error("Interpreter reports an unrecognized LuaJIT version", 0)
        end
        cache_label = "luajit-" .. build
    end
    return {
        executable = resolved,
        version = version,
        cache_label = cache_label,
        jit_version = jit_version,
    }
end

return M
