-- The documentation tooling: export the public model for the documentation site, and check that the
-- READMEs quote what the gates run.
--
--   luajit scripts/docs/docs.lua export [--source DIR] [--luals PATH] [--output DIR] [--check]
--   luajit scripts/docs/docs.lua readmes [--source DIR]
--   luajit scripts/docs/docs.lua delete-preview --bucket NAME --pr NUMBER
--
-- `export` writes api.json and the guide and example bundles; with --check it only validates. It
-- needs the pinned LuaLS that scripts/bootstrap/bootstrap.lua luals installs. `readmes` exits 1 and
-- names the first README that differs from its sources. `delete-preview` removes a closed pull
-- request's preview from the site bucket and is run only by the docs-preview-cleanup workflow. See
-- README.md.
local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local repo = require("support.repo")
repo.use_rocks()
local argparse = require("argparse")

local cli = argparse("docs.lua", "Export the public model and check the README examples.")
cli:command_target("target")
cli:require_command(true)
local export = cli:command("export", "Write api.json and the guide and example bundles.")
export:option("--source", "the checkout to export"):default(repo.root)
export
    :option("--luals", "the LuaLS executable")
    :default(repo.root .. "/.cache/tools/luals-3.19.1/bin/lua-language-server")
export:option("--output", "where to write the export"):default(repo.root .. "/docs/_build")
export:flag("--check", "validate without writing")
local readmes = cli:command("readmes", "Check the READMEs against their sources.")
readmes:option("--source", "the checkout to check"):default(repo.root)
local delete =
    cli:command("delete-preview", "Delete a closed pull request's documentation preview.")
delete:option("--bucket", "the site bucket"):count(1)
delete:option("--pr", "the pull request number"):count(1)
local parsed, arguments = cli:pparse({ ... })
if not parsed then
    io.stderr:write(cli:get_usage(), "\ndocs.lua: error: ", arguments, "\n")
    os.exit(2)
end

local ok, failure = pcall(function()
    if arguments.target == "export" then
        print(require("docs.export").run({
            source = arguments.source,
            luals = arguments.luals,
            output = arguments.output,
            check = arguments.check,
        }))
    elseif arguments.target == "delete-preview" then
        require("docs.preview").delete(arguments.bucket, arguments.pr)
        print(("PASS deleted the preview of pull request %s"):format(arguments.pr))
    else
        require("docs.readme_examples").check_readmes(arguments.source)
        print("README check PASS")
    end
end)
if not ok then
    io.stderr:write(tostring(failure), "\n")
    os.exit(1)
end
