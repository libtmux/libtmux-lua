local test = require("luaunit")
local hosts = require("bootstrap.hosts")
local luals = require("bootstrap.luals")
local rocks = require("bootstrap.rocks")
local runtimes = require("bootstrap.runtimes")
local runtime = require("support.runtime")
local shell = require("support.shell")
local M = {}

local LUA = runtime.executable_path(arg and arg[-1] or "luajit")

--- A child that runs Lua source, so the shell runner is tested without writing a shell program.
---@param source string
---@return string[]
local function lua_child(source)
    return { LUA, "-e", source }
end

local function argument_after(argv, flag)
    for index, value in ipairs(argv) do
        if value == flag then
            return argv[index + 1]
        end
    end
end

function M.test_a_download_retries_a_transient_failure_a_bounded_number_of_times()
    local argv = runtimes.download_command("https://example.invalid/x.tar.gz", "/tmp/x")
    test.assertEquals(argv[1], "curl")
    test.assertEquals(argv[#argv], "https://example.invalid/x.tar.gz")
    test.assertEquals(argument_after(argv, "--output"), "/tmp/x")
    test.assertEquals(argument_after(argv, "--retry"), tostring(runtimes.ATTEMPTS - 1))
    test.assertNotNil(argument_after(argv, "--max-time"))
    test.assertEquals(argv[2], "--fail")
end

function M.test_every_pin_is_a_full_digest_or_revision()
    for version, digest in pairs(runtimes.RELEASES) do
        test.assertStrMatches(digest, "%x+")
        test.assertEquals(#digest, 64, version)
    end
    test.assertEquals(#runtimes.LUAJIT_REVISION, 40)
    for version, pin in pairs(hosts.RELEASES) do
        test.assertEquals(#pin[2], 64, version)
    end
    for host, pin in pairs(luals.ARTIFACTS) do
        test.assertEquals(#pin[2], 64, host)
    end
end

function M.test_the_sha256_of_a_file_is_read_through_the_host_tool()
    local path = os.tmpname()
    local handle = assert(io.open(path, "wb"))
    handle:write("abc")
    handle:close()
    local digest = runtimes.sha256(path)
    os.remove(path)
    test.assertEquals(digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
end

function M.test_shell_arguments_are_quoted_not_interpolated()
    local hostile = "a b; echo pwned $(echo x) 'q' \"d\""
    local code, output = shell.run({ "printf", "%s", hostile })
    test.assertEquals(code, 0)
    test.assertEquals(output, hostile)
end

function M.test_shell_reports_the_exit_code_and_merges_the_streams()
    local code, output = shell.run(lua_child([=[
        io.stdout:write("out\n")
        io.stdout:flush()
        io.stderr:write("err\n")
        os.exit(3)
    ]=]))
    test.assertEquals(code, 3)
    test.assertEquals(output, "out\nerr\n")
    test.assertErrorMsgContains("failed (3)", shell.check, lua_child("os.exit(3)"))
end

function M.test_shell_sets_and_unsets_the_childs_environment()
    local _, output =
        shell.run(lua_child('io.write(os.getenv("KEPT"), "|", os.getenv("HOME") or "unset")'), {
            env = { KEPT = "yes" },
            unset = { "HOME" },
        })
    test.assertEquals(output, "yes|unset")
end

function M.test_shell_appends_a_logged_command_to_its_file()
    local path = os.tmpname()
    shell.check({ "echo", "one" }, { log = path })
    shell.check({ "echo", "two" }, { log = path })
    local handle = assert(io.open(path, "rb"))
    local text = handle:read("*a")
    handle:close()
    os.remove(path)
    test.assertEquals(text, "one\ntwo\n")
end

function M.test_the_running_luajit_names_its_own_rock_tree()
    local lua = runtime.identify(arg and arg[-1] or "luajit")
    test.assertEquals(lua.version, "5.1")
    test.assertStrMatches(lua.cache_label, "luajit%-2%.1[%.%w%-]*")
    local base, tree = rocks.base(lua, "luarocks")
    test.assertEquals(base[2], "--lua-version=5.1")
    test.assertEquals(base[4], "--tree=" .. tree)
    test.assertStrContains(tree, "/.cache/rocks/" .. lua.cache_label)
end

function M.test_a_relative_interpreter_path_is_named_absolutely_because_a_build_changes_directory()
    local lua = runtime.identify(".cache/toolchains/luajit-2.1/bin/luajit")
    test.assertStrMatches(lua.executable, "/.*/luajit%-2%.1/bin/luajit")
    local base = rocks.base(lua, "luarocks")
    test.assertStrMatches(base[3], "%-%-lua%-dir=/.*")
end

function M.test_every_rock_group_is_pinned_to_an_exact_version()
    for _, list in pairs(rocks.DEPENDENCIES) do
        for _, rock in ipairs(list) do
            test.assertStrMatches(rock[2], "%d[%w%.]*%-%d+")
        end
    end
    test.assertNotNil(rocks.DEPENDENCIES.dev)
end

function M.test_an_unknown_request_is_refused_before_anything_runs()
    test.assertErrorMsgContains("Unknown runtime", runtimes.main, { "5.0.1" })
    test.assertErrorMsgContains("Unknown rock group", rocks.main, { "nonsense" })
    test.assertErrorMsgContains("Unknown Neovim version", hosts.main, { "0.0.1" }, true)
end

return M
