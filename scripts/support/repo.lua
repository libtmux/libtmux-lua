local M = {}

local function normalize(path)
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." and #parts > 0 and parts[#parts] ~= ".." then
            parts[#parts] = nil
        elseif part ~= "." then
            parts[#parts + 1] = part
        end
    end
    local joined = table.concat(parts, "/")
    return (path:sub(1, 1) == "/" and "/" or "") .. (joined == "" and "." or joined)
end

local here =
    assert(debug.getinfo(1, "S").source:match("^@(.*)repo%.lua$"), "cannot locate repo.lua")

-- Derived from this file, so it holds for any working directory. Absolute, because a build
-- changes directory.
local root = normalize(here .. "../..")
if root:sub(1, 1) ~= "/" then
    root = normalize(assert(os.getenv("PWD"), "PWD is unset") .. "/" .. root)
end
M.root = root

-- The rock tree is named for the LuaJIT build, so another build finds no rocks.
function M.use_rocks()
    local jit = assert(package.loaded.jit or require("jit"), "scripts run under LuaJIT")
    local tree = M.root .. "/.cache/rocks/luajit-" .. jit.version:match("^LuaJIT (.+)$")
    local share = tree .. "/share/lua/5.1/"
    package.path = share .. "?.lua;" .. share .. "?/init.lua;" .. package.path
    package.cpath = tree .. "/lib/lua/5.1/?.so;" .. package.cpath
end

return M
