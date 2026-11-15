-- Prepare and validate LuaRocks release versions, and guard publication, without publishing.
--
--   luajit scripts/release/main.lua prepare [VERSION] [--check]
--   luajit scripts/release/main.lua changelogs
--   luajit scripts/release/main.lua verify --event FILE --commit SHA [--artifacts DIR]
--
-- Run from the repository root. `prepare` rewrites release.json, the runtime version, the release
-- rockspec and CHANGES.md; with --check it reports drift and changes nothing. `changelogs` checks
-- that the changelog opens with the rock's name and has an Unreleased section. `verify` is the
-- publication guard the Publish workflow runs. Failures print FAIL and exit 1. See README.md.
local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
require("support.repo").use_rocks()
local argparse = require("argparse")
local files = require("support.files")
local json = require("support.json")
local release = require("release.release")

local cli =
    argparse("main.lua", "Prepare and validate LuaRocks release versions without publishing.")
cli:command_target("target")
cli:require_command(true)
local prepare = cli:command("prepare", "Update candidate metadata and release notes.")
prepare:argument("version", "explicit LuaRocks version, including the revision"):args("?")
prepare:flag("--check", "report drift without changing files")
cli:command("changelogs", "Check that libtmux keeps its changelog.")
local verify = cli:command("verify", "Check publication guards without uploading.")
verify:option("--event", "GitHub tag-push event JSON"):count(1)
verify:option("--commit", "exact commit validated by the workflow"):count(1)
verify:option("--artifacts", "directory containing validated artifacts")
local parsed, arguments = cli:pparse({ ... })
if not parsed then
    io.stderr:write(cli:get_usage(), "\nmain.lua: error: ", arguments, "\n")
    os.exit(2)
end

local root = assert(os.getenv("PWD"), "PWD is unset")
local ok, failure = pcall(function()
    if arguments.target == "changelogs" then
        local failures = release.changelog_failures(root)
        if #failures > 0 then
            error("every rock needs a changelog:\n" .. table.concat(failures, "\n"), 0)
        end
        print("PASS libtmux keeps a changelog")
    elseif arguments.target == "verify" then
        release.verify_release(
            root,
            json.decode(files.read(arguments.event)),
            arguments.commit,
            arguments.artifacts
        )
        print(
            ("PASS publication guards for %s at %s"):format(
                release.candidate(root),
                arguments.commit
            )
        )
    else
        if arguments.version == nil and not arguments.check then
            io.stderr:write("main.lua: error: prepare requires an explicit version\n")
            os.exit(2)
        end
        local version = arguments.version or release.candidate(root)
        release.prepare(root, version, arguments.check)
        print(("PASS %s libtmux %s"):format(arguments.check and "checked" or "prepared", version))
    end
end)
if not ok then
    io.stderr:write("FAIL ", tostring(failure), "\n")
    os.exit(1)
end
