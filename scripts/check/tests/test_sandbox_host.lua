-- The test sandbox removes what selects a tmux server and fails a run that leaks. Nothing here
-- starts tmux: a stand-in named tmux records its arguments and the names of selector variables,
-- never a value, so a failure message cannot print an environment.
local test = require("luaunit")
local files = require("support.files")
local fs = require("support.fs")
local proc = require("support.proc")
local repo = require("support.repo")
local runtime = require("support.runtime")
local M = {}

local LUAJIT = runtime.executable_path(arg and arg[-1] or "luajit")
local DECOYS = {
    TMUX = "/decoy/server,1,0",
    TMUX_PANE = "%9",
    LIBTMUX_SOCKET = "decoy-name",
    LIBTMUX_SOCKET_PATH = "/decoy/path",
    LIBTMUX_SOCKET_NAME = "decoy-other",
}

local root

local function developer_environment(extra)
    local env = {}
    for name, value in pairs(proc.environment()) do
        local ambient = name == "TMUX" or name == "TMUX_PANE" or name:sub(1, 14) == "LIBTMUX_SOCKET"
        if not ambient and name ~= "TMUX_TMPDIR" and name ~= "LIBTMUX_TEST_SANDBOX" then
            env[name] = value
        end
    end
    env.TMPDIR = root
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

--- A stand-in tmux: a Lua script that records what it was called with and the selector names in
--- its environment. It stops a server at once or never.
local function stand_in(stops)
    local path = root .. "/bin/tmux"
    fs.mkdir_p(root .. "/bin")
    files.write(
        path,
        "#!"
            .. LUAJIT
            .. "\n"
            .. 'local log = assert(io.open(os.getenv("FAKE_TMUX_LOG"), "a"))\n'
            .. 'log:write(table.concat(arg, " "), "\\n")\n'
            .. 'for _, name in ipairs({"TMUX", "TMUX_PANE", "LIBTMUX_SOCKET"}) do\n'
            .. '  if os.getenv(name) then log:write("selector ", name, "\\n") end\nend\n'
            .. "log:close()\n"
            .. (stops and "" or "")
    )
    assert(require("support.uv").fs_chmod(path, 448))
    return path
end

function M.setUp()
    -- Short and under /tmp so the sandbox fits a socket path wherever TMPDIR points.
    root = fs.mkdtemp("t-")
end

function M.tearDown()
    fs.remove_tree(root)
end

function M.test_entering_removes_every_selector_and_names_a_fresh_private_directory()
    local result = child(
        'local host = require("tests.support.sandbox_host")\n'
            .. 'local sandbox = require("tests.support.sandbox")\n'
            .. "local code = host.run(function()\n"
            .. '  print("violations", #sandbox.violations(os.getenv))\n'
            .. '  print("dir", os.getenv("TMUX_TMPDIR"))\n'
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
    test.assertNil(result.stdout:find("true", 1, true))
    test.assertNil((result.stdout .. result.stderr):find("decoy", 1, true))
    test.assertFalse(fs.stat(directory) ~= nil, "the sandbox directory outlived its run")
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

function M.test_a_socket_the_run_left_fails_it_even_when_the_body_passed()
    local tmux = stand_in(true)
    local log = root .. "/calls"
    local result = child(
        'local host = require("tests.support.sandbox_host")\n'
            .. "host.STOP_SECONDS = 0.05\n"
            .. 'local uv = require("luv")\n'
            .. "local code = host.run(function()\n"
            .. '  local socket = os.getenv("TMUX_TMPDIR") .. "/left.sock"\n'
            .. "  -- A collected handle would unlink its socket, so the run keeps it.\n"
            .. "  KEEP = uv.new_pipe(false)\n"
            .. "  assert(KEEP:bind(socket))\n"
            .. "end)\nos.exit(code)",
        developer_environment({ TMUX_BIN = tmux, FAKE_TMUX_LOG = log })
    )
    test.assertEquals(result.code, 1)
    test.assertStrContains(
        result.stderr,
        "libtmux-lua tests left sockets in the sandbox: left.sock"
    )
    test.assertNil(result.stderr:find("a server still answers", 1, true))
    test.assertStrContains(files.read(log), "-N -S")
    test.assertStrContains(files.read(log), "kill-server")
    test.assertNil(
        files.read(log):find("selector", 1, true),
        "the stop was given an ambient selector"
    )
end

function M.test_a_server_that_still_answers_keeps_the_directory_and_says_so()
    local tmux = stand_in(false)
    local result = child(
        'local host = require("tests.support.sandbox_host")\n'
            .. "host.STOP_SECONDS = 0.05\n"
            .. 'local uv = require("luv")\n'
            .. "local code = host.run(function()\n"
            .. '  local socket = os.getenv("TMUX_TMPDIR") .. "/alive/s.sock"\n'
            .. '  assert(uv.fs_mkdir(os.getenv("TMUX_TMPDIR") .. "/alive", 448))\n'
            .. "  KEEP = uv.new_pipe(false)\n"
            .. "  assert(KEEP:bind(socket))\n"
            .. "  assert(KEEP:listen(16, function() end))\n"
            .. "end)\nos.exit(code)",
        developer_environment({ TMUX_BIN = tmux, FAKE_TMUX_LOG = root .. "/calls" })
    )
    test.assertTrue(
        result.code == 1,
        "code " .. result.code .. ": " .. result.stdout .. result.stderr
    )
    test.assertStrContains(result.stderr, "a server still answers at alive/s.sock")
    test.assertStrMatches(result.stderr, ".*so libtmux%-lua%-sb%-%w+ was kept\n")
    for _, name in ipairs(fs.list(root)) do
        if name:match("^libtmux%-lua%-sb%-") then
            fs.remove_tree(root .. "/" .. name)
        end
    end
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

return M
