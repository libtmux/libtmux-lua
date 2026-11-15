-- Set up the cached tools the gates need: interpreters, rocks, Neovim hosts and LuaLS. Network and
-- builds happen here and never inside a test loop.
--
--   lua scripts/bootstrap/bootstrap.lua runtimes 5.4.9 luajit
--   lua scripts/bootstrap/bootstrap.lua rocks dev live [--lua=PATH] [--luarocks=PATH]
--   luajit scripts/bootstrap/bootstrap.lua hosts 0.10.0 0.12.5 [--check]
--   lua scripts/bootstrap/bootstrap.lua luals
--
-- `runtimes`, `rocks` and `luals` use only the standard library, so any Lua 5.1 to 5.5 runs them
-- before the tool LuaJIT exists. `hosts` reads JSON and runs under the tool LuaJIT. See README.md.
local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local function parse(argv)
    local positional, options = {}, {}
    for _, value in ipairs(argv) do
        local name, setting = value:match("^%-%-([%w%-]+)=(.*)$")
        if name then
            options[name] = setting
        elseif value:match("^%-%-[%w%-]+$") then
            options[value:sub(3)] = true
        else
            positional[#positional + 1] = value
        end
    end
    return table.remove(positional, 1), positional, options
end

local command, arguments, options = parse({ ... })
local ok, failure = pcall(function()
    if command == "runtimes" then
        require("bootstrap.runtimes").main(arguments)
    elseif command == "rocks" then
        require("bootstrap.rocks").main(arguments, options.lua, options.luarocks)
    elseif command == "luals" then
        require("bootstrap.luals").main()
    elseif command == "hosts" then
        require("support.repo").use_rocks()
        os.exit(require("bootstrap.hosts").main(arguments, options.check == true))
    else
        error(
            "usage: bootstrap.lua runtimes|rocks|hosts|luals ... (see scripts/bootstrap/README.md)",
            0
        )
    end
end)
if not ok then
    io.stderr:write("bootstrap: ", tostring(failure), "\n")
    os.exit(1)
end
