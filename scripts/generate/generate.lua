-- Generate the files that data/tmux-fields.json and data/tmux-options.json describe, or check that
-- the committed ones are current.
--
--   luajit scripts/generate/generate.lua fields [--check] [--verify-source TMUX_CHECKOUT]
--   luajit scripts/generate/generate.lua options [--check]
--
-- Without --check the files are rewritten. With it a stale file is named on standard error and the
-- exit status is 1. Both need StyLua on PATH and neither needs the network. See README.md.
local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
require("support.repo").use_rocks()
local argparse = require("argparse")
local render = require("generate.render")

local cli =
    argparse("generate.lua", "Generate Lua metadata and reference pages from the tmux catalogs.")
cli:command_target("target")
cli:require_command(true)
local fields = cli:command("fields", "The field catalog.")
fields:flag("--check", "fail if generated files differ")
fields:option("--verify-source", "verify pinned format mappings in a local tmux Git checkout")
cli:command("options", "The option catalog."):flag("--check", "fail if generated files differ")
local parsed, arguments = cli:pparse({ ... })
if not parsed then
    io.stderr:write(cli:get_usage(), "\ngenerate.lua: error: ", arguments, "\n")
    os.exit(2)
end

local ok, failure = pcall(function()
    local outputs, label
    if arguments.target == "fields" then
        local module = require("generate.fields")
        local data = module.load_catalog()
        if arguments.verify_source then
            module.verify_source(data, arguments.verify_source)
        end
        outputs = {
            { "lua/libtmux/_internal/fields.lua", module.generate_lua(data) },
            { "docs/fields.md", module.generate_docs(data) },
        }
        label = "Field catalog"
    else
        local module = require("generate.options")
        local data = module.load_catalog()
        outputs = {
            { "lua/libtmux/_internal/options_catalog.lua", module.generate_lua(data) },
            { "docs/options-reference.md", module.generate_docs(data) },
        }
        label = "Option catalog"
    end
    local stale = render.settle(outputs, arguments.check)
    if #stale > 0 then
        io.stderr:write("Stale generated files: ", table.concat(stale, ", "), "\n")
        os.exit(1)
    end
    print(label .. (arguments.check and " check" or " generation") .. " PASS")
end)
if not ok then
    io.stderr:write("generate: ", tostring(failure), "\n")
    os.exit(1)
end
