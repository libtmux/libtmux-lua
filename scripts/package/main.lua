-- Build and test installed rocks offline; dependency setup is an outer step.
--
--   luajit scripts/package/main.lua [--lua PATH] [--luarocks PATH] [--cache TREE]
--       [--release] [--output DIR] [--public-tag]
--
-- Without --release it builds the development rock, installs it into a temporary tree, imports it
-- from outside the checkout and then checks the release candidate. With --release only the
-- candidate is checked: its source rock, installed rockspec, license, changelog, import and the
-- complete examples. --output keeps the validated artifacts in an empty directory; --public-tag
-- fetches the actual source tag (network). Missing dependencies fail locally. See README.md.
local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/../../?.lua;" .. package.path
local repo = require("support.repo")
repo.use_rocks()
local argparse = require("argparse")

local cli = argparse("main.lua", "Build and test installed rocks offline.")
cli:flag("--release", "check only the core release candidate")
cli:option("--output", "retain validated release artifacts in an empty directory")
cli:flag("--public-tag", "fetch the actual public source tag (network)")
cli:option("--cache", "installed prerequisite LuaRocks tree")
cli:option("--lua", "interpreter executable"):default("lua")
cli:option("--luarocks", "LuaRocks executable"):default("luarocks")
local parsed, arguments = cli:pparse({ ... })
if not parsed then
    io.stderr:write(cli:get_usage(), "\nmain.lua: error: ", arguments, "\n")
    os.exit(2)
end

os.exit(require("tests.support.sandbox_host").run(function()
    local ok, failure = pcall(function()
        require("package.package").main({
            lua = arguments.lua,
            luarocks = arguments.luarocks,
            cache = arguments.cache,
            release = arguments.release,
            output = arguments.output,
            public_tag = arguments.public_tag,
        })
    end)
    if not ok then
        io.stderr:write("FAIL package checks: ", tostring(failure), "\n")
        return 1
    end
    return 0
end))
