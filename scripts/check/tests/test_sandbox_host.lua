-- The test sandbox removes what selects a tmux server and fails a run that leaks. Nothing here
-- starts tmux: a stand-in named tmux records its arguments and the names of selector variables,
-- never a value, so a failure message cannot print an environment.
local test = require("luaunit")
local files = require("support.files")
local fs = require("support.fs")
local proc = require("support.proc")
local recorder = require("tests.support.recorder")
local repo = require("support.repo")
local runtime = require("support.runtime")
local sandbox = require("tests.support.sandbox")
local host = require("tests.support.sandbox_host")
local uv = require("support.uv")
local M = {}

local LUAJIT = runtime.executable_path(arg and arg[-1] or "luajit")
local DECOYS = {
    TMUX = "/decoy/server,1,0",
    TMUX_PANE = "%9",
    LIBTMUX_SOCKET = "decoy-name",
    LIBTMUX_SOCKET_PATH = "/decoy/path",
    LIBTMUX_SOCKET_NAME = "decoy-other",
}

local root, log, fake
---@type any[]
local servers

local function developer_environment(extra)
    local env = {}
    for name, value in pairs(proc.environment()) do
        if not sandbox.ambient(name) and name ~= "TMUX_TMPDIR" and name ~= sandbox.MARKER then
            env[name] = value
        end
    end
    env.TMPDIR = root
    for name, value in pairs(extra or {}) do
        env[name] = value
    end
    return env
end

--- The environment of a child that finds the stand-in as tmux, and says where it writes.
local function recording(extra)
    local env = developer_environment({
        PATH = root .. "/bin:" .. (os.getenv("PATH") or ""),
        TMUX_BIN = fake,
        FAKE_TMUX_LOG = log,
        FAKE_TMUX_ROOT = root,
    })
    for name, value in pairs(extra or {}) do
        env[name] = value
    end
    return env
end

--- Runs Lua source in a fresh interpreter with the repository on its path.
local function child(source, env)
    local script = root .. "/child.lua"
    files.write(
        script,
        ('package.path = "%s/?.lua;%s/scripts/?.lua;" .. package.path\n'):format(
            repo.root,
            repo.root
        )
            .. 'require("support.repo").use_rocks()\n'
            .. source
    )
    return proc.run({ LUAJIT, script }, { cwd = repo.root, env = env or developer_environment() })
end

--- A listening socket at a path under a directory, kept until the test ends.
local function listen(directory, ...)
    local path = directory .. "/" .. table.concat({ ... }, "/")
    fs.mkdir_p(path:match("^(.*)/[^/]+$"))
    local pipe = assert(uv.new_pipe(false))
    assert(pipe:bind(path))
    assert(pipe:listen(16, function() end))
    servers[#servers + 1] = pipe
    return path
end

--- Runs `body` with environment variables set, then puts them back.
local function with_environment(values, body)
    local before = {}
    for name, value in pairs(values) do
        before[name] = os.getenv(name) or false
        uv.os_setenv(name, value)
    end
    local ok, result = pcall(body)
    for name, value in pairs(before) do
        if value then
            uv.os_setenv(name, value)
        else
            uv.os_unsetenv(name)
        end
    end
    assert(ok, result)
    return result
end

--- A sandbox directory of the kind `prepare` makes, which the test releases itself.
local function sandbox_directory()
    local directory = fs.mkdtemp(sandbox.PREFIX, root)
    return directory
end

--- Releases a directory with the stand-in, which serves sockets as `server` says.
local function release(directory, server, wait, tmux)
    return with_environment({
        FAKE_TMUX_LOG = log,
        FAKE_TMUX_ROOT = root,
        FAKE_TMUX_SERVER = server or "",
    }, function()
        return host.release(directory, tmux or fake, wait or 1)
    end)
end

function M.setUp()
    -- Short and under /tmp so the sandbox fits a socket path wherever TMPDIR points.
    root = fs.mkdtemp("t-")
    log = root .. "/calls"
    fake = recorder.install(root .. "/bin")
    servers = {}
end

function M.tearDown()
    for _, pipe in ipairs(servers) do
        pipe:close()
    end
    fs.remove_tree(root)
end

function M.test_entering_removes_every_selector_and_names_a_fresh_private_directory()
    local result = child(
        'local host = require("tests.support.sandbox_host")\n'
            .. 'local sandbox = require("tests.support.sandbox")\n'
            .. 'local uv = require("luv")\n'
            .. "local code = host.run(function()\n"
            .. '  print("violations", #sandbox.violations(os.getenv))\n'
            .. '  print("dir", os.getenv("TMUX_TMPDIR"))\n'
            .. '  print("marker", os.getenv("LIBTMUX_TEST_SANDBOX") == os.getenv("TMUX_TMPDIR"))\n'
            .. '  print("mode", uv.fs_stat(os.getenv("TMUX_TMPDIR")).mode % 512)\n'
            .. '  print("kept", os.getenv("LIBTMUX_RELEASE_DIR"))\n'
            .. "  for _, name in ipairs(sandbox.SELECTORS) do\n"
            .. '    print("set", name, os.getenv(name) ~= nil)\n'
            .. "  end\n"
            .. "end)\nos.exit(code)",
        developer_environment(DECOYS)
    )
    test.assertEquals(result.code, 0, result.stderr)
    test.assertStrContains(result.stdout, "violations\t0")
    local directory = result.stdout:match("dir\t(%S+)")
    test.assertStrMatches(directory, (root:gsub("%p", "%%%0")) .. "/libtmux%-lua%-sb%-%w+")
    test.assertTrue(#directory <= sandbox.MAX_BYTES)
    test.assertStrContains(result.stdout, "marker\ttrue")
    test.assertStrContains(result.stdout, "mode\t448")
    test.assertNil(result.stdout:find("true\n", 1, true) and result.stdout:find("set\t%S+\ttrue"))
    test.assertNil((result.stdout .. result.stderr):find("decoy", 1, true))
    test.assertFalse(fs.stat(directory) ~= nil, "the sandbox directory outlived its run")
end

function M.test_variables_that_select_nothing_survive_entering()
    local result = child(
        'local host = require("tests.support.sandbox_host")\n'
            .. "print(host.run(function() print(os.getenv('LIBTMUX_RELEASE_DIR')) end))",
        developer_environment({ LIBTMUX_RELEASE_DIR = "kept" })
    )
    test.assertEquals(result.code, 0, result.stderr)
    test.assertStrContains(result.stdout, "kept")
end

function M.test_a_refusal_names_the_variables_and_never_their_values()
    local result = child(
        'local host = require("tests.support.sandbox_host")\n'
            .. "local ok, refusal = pcall(host.check)\n"
            .. "print(ok, tostring(refusal))",
        developer_environment(DECOYS)
    )
    test.assertEquals(result.code, 0, result.stderr)
    for name in pairs(DECOYS) do
        test.assertStrContains(result.stdout, name .. " is set")
    end
    test.assertNil(result.stdout:find("decoy", 1, true))
    test.assertNil(result.stdout:find("/server", 1, true))
end

function M.test_a_sandbox_directory_that_is_gone_is_refused_as_missing()
    local gone = root .. "/" .. sandbox.PREFIX .. "gone"
    local result = child(
        'local host = require("tests.support.sandbox_host")\n'
            .. 'local sandbox = require("tests.support.sandbox")\n'
            .. 'print("findings", #sandbox.violations(os.getenv))\n'
            .. "print(pcall(host.check))",
        developer_environment({ TMUX_TMPDIR = gone, [sandbox.MARKER] = gone })
    )
    test.assertEquals(result.code, 0, result.stderr)
    test.assertStrContains(result.stdout, "findings\t0")
    test.assertStrContains(result.stdout, "the sandbox directory is missing")
end

function M.test_prepare_refuses_when_no_directory_is_short_enough()
    local result = child(
        'local host = require("tests.support.sandbox_host")\n'
            .. 'print(pcall(host.prepare, { "/" .. ("x"):rep(80) }))',
        developer_environment(DECOYS)
    )
    test.assertEquals(result.code, 0, result.stderr)
    test.assertStrContains(result.stdout, "short enough")
end

function M.test_a_process_inside_a_sandbox_joins_it_and_does_not_remove_it()
    local result = child(
        'local host = require("tests.support.sandbox_host")\n'
            .. "local code = host.run(function()\n"
            .. "  local dir, created = host.prepare()\n"
            .. '  print("inner", dir == os.getenv("TMUX_TMPDIR"), created)\n'
            .. "end)\nos.exit(code)"
    )
    test.assertEquals(result.code, 0, result.stderr)
    test.assertStrContains(result.stdout, "inner\ttrue\tfalse")
end

function M.test_a_sandbox_that_cannot_be_made_exits_with_two_before_the_body_runs()
    local result = child(
        'local host = require("tests.support.sandbox_host")\n'
            .. 'host.prepare = function() error("no temporary directory is short enough", 0) end\n'
            .. 'os.exit(host.run(function() print("body ran") end))'
    )
    test.assertEquals(result.code, 2)
    test.assertStrContains(
        result.stderr,
        "libtmux-lua tests refused to run: no temporary directory"
    )
    test.assertNil(result.stdout:find("body ran", 1, true))
end

function M.test_the_default_socket_follows_tmux_tmpdir_through_a_link()
    local result = child(
        'local host = require("tests.support.sandbox_host")\n'
            .. 'local uv = require("luv")\n'
            .. 'local real, link = os.getenv("TMPDIR") .. "/real", os.getenv("TMPDIR") .. "/link"\n'
            .. "assert(uv.fs_mkdir(real, 448))\nassert(uv.fs_symlink(real, link))\n"
            .. "print(host.default_socket({ TMUX_TMPDIR = link }, 1000))\n"
            .. "print(host.default_socket({}, 1000))"
    )
    test.assertEquals(result.code, 0, result.stderr)
    local resolved, fallback = result.stdout:match("^(%S+)\n(%S+)\n$")
    test.assertEquals(resolved, root .. "/real/tmux-1000/default")
    test.assertEquals(fallback, "/tmp/tmux-1000/default")
end

function M.test_a_leak_is_a_socket_anywhere_in_the_tree_whoever_named_it()
    local directory = sandbox_directory()
    test.assertEquals(host.leaks(directory), {})
    fs.mkdir_p(directory .. "/tmux-7")
    files.write(directory .. "/tmux-7/not-a-socket", "")
    test.assertEquals(host.leaks(directory), {})
    listen(directory, "tmux-7", "default")
    listen(directory, "custom.sock")
    listen(directory, ".hidden", "deep", "s")
    test.assertEquals(host.leaks(directory), { ".hidden/deep/s", "custom.sock", "tmux-7/default" })
end

function M.test_a_link_to_a_socket_elsewhere_is_not_a_leak_and_is_not_stopped()
    local directory = sandbox_directory()
    local elsewhere = listen(root, "outside.sock")
    assert(uv.fs_symlink(elsewhere, directory .. "/link.sock"))
    test.assertEquals(release(directory, "answers"), { leaked = {}, answering = {} })
    test.assertEquals(recorder.calls(log), {}, "stopped a server in another tree")
    test.assertFalse(fs.stat(directory) ~= nil)
end

function M.test_release_stops_each_server_wherever_it_sits_and_removes_the_directory()
    local directory = sandbox_directory()
    local sockets = {
        listen(directory, "tmux-7", "default"),
        listen(directory, "custom.sock"),
        listen(directory, "a", "b", "c.sock"),
    }
    test.assertEquals(
        release(directory, "answers"),
        { leaked = { "a/b/c.sock", "custom.sock", "tmux-7/default" }, answering = {} }
    )
    local stopped = {}
    for _, call in ipairs(recorder.calls(log)) do
        test.assertEquals(
            { call.argv[1], call.argv[2], call.argv[4] },
            { "-N", "-S", "kill-server" }
        )
        stopped[#stopped + 1] = call.argv[3]
    end
    table.sort(stopped)
    table.sort(sockets)
    test.assertEquals(stopped, sockets)
    test.assertFalse(fs.stat(directory) ~= nil)
end

function M.test_release_waits_for_a_server_that_takes_a_moment_to_go()
    local directory = sandbox_directory()
    listen(directory, "custom.sock")
    test.assertEquals(release(directory, "slow", 5), { leaked = { "custom.sock" }, answering = {} })
    test.assertFalse(fs.stat(directory) ~= nil)
end

function M.test_release_keeps_the_directory_while_a_server_still_answers()
    local directory = sandbox_directory()
    listen(directory, "custom.sock")
    -- Bound but never listening: tmux leaves such a socket behind when its server dies.
    local stale = assert(uv.new_pipe(false))
    assert(stale:bind(directory .. "/gone.sock"))
    servers[#servers + 1] = stale
    local released = release(directory, "stuck", 0.03)
    test.assertEquals(
        released,
        { leaked = { "custom.sock", "gone.sock" }, answering = { "custom.sock" } }
    )
    test.assertTrue(
        fs.stat(directory .. "/custom.sock") ~= nil,
        "removed the directory of a live server"
    )
    local message = host.describe(released, directory)
    test.assertStrContains(message, "a server still answers at custom.sock")
    test.assertStrContains(message, directory:match("[^/]+$") .. " was kept")
    test.assertNil(message:find(root, 1, true))
end

function M.test_release_keeps_the_directory_when_there_is_no_tmux_to_stop_the_server()
    local directory = sandbox_directory()
    listen(directory, "custom.sock")
    local released = release(directory, nil, 0.03, root .. "/missing-tmux")
    test.assertEquals(released.answering, { "custom.sock" })
    test.assertTrue(fs.stat(directory) ~= nil)
end

function M.test_a_socket_that_vanishes_before_it_is_stopped_does_not_stop_the_release()
    local directory = sandbox_directory()
    local leaks = host.leaks
    ---@diagnostic disable-next-line: duplicate-set-field
    host.leaks = function()
        return { "gone.sock" }
    end
    local ok, released = pcall(release, directory)
    host.leaks = leaks
    assert(ok, released)
    test.assertEquals(released, { leaked = { "gone.sock" }, answering = {} })
    test.assertFalse(fs.stat(directory) ~= nil)
end

function M.test_the_stop_hands_tmux_no_selector_and_keeps_tmux_tmpdir()
    local directory = sandbox_directory()
    listen(directory, "custom.sock")
    local values = { TMUX_TMPDIR = root .. "/kept" }
    for name, value in pairs(DECOYS) do
        values[name] = value
    end
    with_environment(values, function()
        release(directory, "answers")
    end)
    local calls = recorder.calls(log)
    test.assertEquals(#calls, 1)
    test.assertEquals(calls[1].set, {})
    test.assertEquals(calls[1].tmpdir, "inside")
end

--- Runs a child that enters the sandbox, optionally leaves a server on a socket under it, and
--- records the directory it made in a file.
local function leaker(path, server)
    local lines = {
        'local host = require("tests.support.sandbox_host")',
        'local uv = require("luv")',
        "host.STOP_SECONDS = 0.03",
        "local code = host.run(function()",
        '  local directory = os.getenv("TMUX_TMPDIR")',
        ('  require("support.files").write(%q, directory)'):format(root .. "/directory"),
    }
    if path then
        for _, line in ipairs({
            ('  local path = directory .. "/" .. %q'):format(path),
            '  require("support.fs").mkdir_p(path:match("^(.*)/[^/]+$"))',
            "  -- A collected handle would unlink its socket, so the run keeps it.",
            "  KEEP = uv.new_pipe(false)",
            "  assert(KEEP:bind(path))",
            "  assert(KEEP:listen(16, function() end))",
        }) do
            lines[#lines + 1] = line
        end
    end
    lines[#lines + 1] = "end)"
    lines[#lines + 1] = "os.exit(code)"
    return child(table.concat(lines, "\n"), recording({ FAKE_TMUX_SERVER = server }))
end

function M.test_the_process_that_made_the_sandbox_fails_the_run_that_leaks()
    local quiet = leaker()
    test.assertEquals(quiet.code, 0, quiet.stderr)
    test.assertFalse(
        fs.stat(files.read(root .. "/directory")) ~= nil,
        "a clean run left its sandbox behind"
    )
    local uid = uv.os_get_passwd().uid
    for _, path in ipairs({ ("tmux-%d/default"):format(uid), "custom.sock" }) do
        os.remove(log)
        local leaked = leaker(path, "answers")
        test.assertEquals(
            leaked.code,
            1,
            path .. "|" .. leaked.stdout .. "|" .. leaked.stderr .. "|" .. tostring(leaked.signal)
        )
        test.assertStrContains(leaked.stderr, "left sockets in the sandbox: " .. path)
        test.assertNil(leaked.stderr:find("answers", 1, true))
        test.assertFalse(
            fs.stat(files.read(root .. "/directory")) ~= nil,
            "a leaking run left its sandbox behind"
        )
        local calls = recorder.calls(log)
        test.assertEquals(#calls, 1)
        test.assertEquals(calls[1].argv[4], "kill-server", "the leaked server was not stopped")
        test.assertEquals(calls[1].argv[3]:sub(-#path), path)
        test.assertEquals(calls[1].set, {}, "the stop was given an ambient selector")
    end
end

function M.test_a_run_whose_server_survives_kill_server_keeps_the_sandbox_and_says_so()
    local leaked = leaker("custom.sock", "stuck")
    local directory = files.read(root .. "/directory")
    test.assertEquals(leaked.code, 1, leaked.stdout .. "|" .. leaked.stderr)
    test.assertStrContains(leaked.stderr, "a server still answers at custom.sock")
    test.assertStrMatches(leaked.stderr, ".*so libtmux%-lua%-sb%-%w+ was kept\n")
    test.assertNil(leaked.stderr:find(root, 1, true))
    test.assertTrue(
        fs.stat(directory) ~= nil,
        "removed the directory of a server that was not stopped"
    )
    fs.remove_tree(directory)
end

function M.test_a_client_that_names_no_socket_is_handed_nothing_that_selects_a_server()
    local env = recording(DECOYS)
    env.TMUX_TMPDIR = "/decoy/tmpdir"
    local function run(enter)
        os.remove(log)
        local result = child(
            'local host = require("tests.support.sandbox_host")\n'
                .. 'local proc = require("support.proc")\n'
                .. "local function client()\n"
                .. '  proc.run({ "tmux", "list-sessions" })\n'
                .. "end\n"
                .. (enter and "os.exit(host.run(client))" or "client()"),
            env
        )
        test.assertEquals(result.code, 0, result.stderr)
        local calls = recorder.calls(log)
        test.assertEquals(#calls, 1)
        return calls[1]
    end
    local control = run(false)
    local selectors = { unpack(sandbox.SELECTORS) }
    table.sort(selectors)
    table.sort(control.set)
    test.assertEquals(control.set, selectors, "the control must see every decoy")
    test.assertEquals(control.tmpdir, "outside")
    local guarded = run(true)
    test.assertEquals(guarded.argv, { "list-sessions" })
    test.assertEquals(guarded.set, {})
    test.assertEquals(guarded.tmpdir, "inside")
    test.assertEquals(guarded.marker, "matches")
end

return M
