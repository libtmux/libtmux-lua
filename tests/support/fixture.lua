-- Own one real tmux server for a test, on a socket of its own; never use the default socket.
--
-- `with` starts the server, runs the body and always stops it: kill-server, then a kill of every
-- process the fixture recorded if that failed, then a wait for each to be gone and the removal of
-- the directory. A cancellation signal unwinds through the body, so the cleanup runs for it too.
local child = require("tests.support.child")
local fs = require("support.fs")
local repo = require("support.repo")
local sandbox = require("tests.support.sandbox")
local sandbox_host = require("tests.support.sandbox_host")
local uv = require("support.uv")

local M = {}

M.HOSTS = { "luv", "nvim" }
-- How long any one tmux command or exit may take.
local DEADLINE = 0.8
M.DEADLINE = DEADLINE

--- The first executable called `name` on PATH, or `name` itself when it holds a slash.
---@param name string
---@return string?
function M.which(name)
    if name:find("/", 1, true) then
        return name
    end
    for directory in (os.getenv("PATH") or ""):gmatch("[^:]+") do
        local path = directory .. "/" .. name
        if fs.is_file(path) and uv.fs_access(path, "X") then
            return path
        end
    end
end

---@return string
function M.tmux()
    local binary = M.which(os.getenv("TMUX_BIN") or "tmux")
    return assert(binary, "missing tmux executable")
end

--- The interpreter that runs the library's tests and the programs in panes.
---@return string
function M.lua()
    local binary = os.getenv("LIBTMUX_TEST_LUA") or M.which("lua")
    return assert(binary, "missing selected Lua executable")
end

--- The LuaJIT that runs the harness, for a program the harness starts that needs its modules.
---@return string
function M.luajit()
    return assert(M.which(arg and arg[-1] or "luajit"), "missing LuaJIT executable")
end

---@return string
function M.nvim()
    local binary = os.getenv("LIBTMUX_TEST_NVIM") or M.which("nvim")
    return assert(binary, "missing Neovim integration executable")
end

--- A release written as tmux reports it, as major, minor and the letter after them.
---@param version string
---@return integer major
---@return integer minor
---@return string suffix
function M.release(version)
    local major, minor, suffix = version:gsub("^next%-", ""):match("^(%d+)%.(%d+)(%a*)")
    return tonumber(major) or 0, tonumber(minor) or 0, suffix or ""
end

--- Whether a release is at or above another. A next- build ranks as the release it names, and a
--- letter ranks above none.
---@param version string
---@param major integer
---@param minor integer
---@param suffix? string
---@return boolean
function M.at_least(version, major, minor, suffix)
    local a, b, c = M.release(version)
    if a ~= major then
        return a > major
    end
    if b ~= minor then
        return b > minor
    end
    return c >= (suffix or "")
end

--- A table of the process environment that selects no server or pane: what a test child gets.
---@param extra? table<string, string>
---@return table<string, string>
function M.environment(extra)
    local env = {}
    for name, value in pairs(uv.os_environ()) do
        if not sandbox.ambient(name) then
            env[name] = value
        end
    end
    for name, value in pairs(extra or {}) do
        env[name] = value
    end
    return env
end

local function map(list, transform)
    local mapped = {}
    for index, value in ipairs(list) do
        mapped[index] = transform(value)
    end
    return mapped
end

---@class harness.Fixture
---@field binary string
---@field env table<string, string>
---@field path? string
---@field socket? string
---@field server_pid? integer
---@field pane_pids integer[]
---@field clients harness.Child[]
local Fixture = {}
Fixture.__index = Fixture

--- A fixture that is not started. It clears what selects a server from this process and raises
--- unless the process is inside the sandbox: every test that starts a server passes through here.
---@param opts? {env?: table<string, string>}
---@return harness.Fixture
function M.new(opts)
    -- A test that set TMUX or TMUX_PANE for itself must not reach a server through them.
    for name in pairs(uv.os_environ()) do
        if sandbox.ambient(name) then
            uv.os_unsetenv(name)
        end
    end
    sandbox_host.check()
    return setmetatable({
        binary = M.tmux(),
        env = M.environment(opts and opts.env),
        pane_pids = {},
        clients = {},
        closed = false,
    }, Fixture)
end

--- Starts a client of the fixture's server: tmux with no configuration file, on the fixture's
--- socket. The fixture kills it on close if it still runs.
---@param arguments string[]
---@param opts? harness.SpawnOptions
---@return harness.Child
function Fixture:spawn(arguments, opts)
    assert(self.socket and not self.closed, "tmux fixture is not active")
    local argv = { self.binary, "-f", "/dev/null", "-S", self.socket }
    for _, value in ipairs(arguments) do
        argv[#argv + 1] = value
    end
    local spawned = {}
    for name, value in pairs(opts or {}) do
        spawned[name] = value
    end
    spawned.env = spawned.env or self.env
    local client = child.spawn(argv, spawned)
    self.clients[#self.clients + 1] = client
    return client
end

--- Runs a command and returns its result, whatever its exit status.
---@param ... string
---@return harness.Result
function Fixture:try(...)
    local client = self:spawn({ ... })
    local ok, result = pcall(client.finish, client, DEADLINE)
    if not ok then
        client:close()
        error(result, 0)
    end
    return result
end

--- Runs a command that must succeed and returns its result.
---@param ... string
---@return harness.Result
function Fixture:run(...)
    local arguments = { ... }
    local result = self:try(...)
    if result.code ~= 0 then
        error(
            ("tmux %s exited with %d: %s"):format(
                table.concat(arguments, " "),
                result.code,
                result.stderr
            ),
            0
        )
    end
    return result
end

--- The standard output of a command that must succeed.
---@param ... string
---@return string
function Fixture:out(...)
    return self:run(...).stdout
end

--- The daemon's version, as it reports it.
---@return string
function Fixture:version()
    return (self:out("display-message", "-p", "#{version}"):gsub("%s+$", ""))
end

---@param output string
function Fixture:record_panes(output)
    for line in output:gmatch("[^\n]+") do
        local server, pane = line:match("^(%d+) (%d+)$")
        -- A dead pane reports no pid (tmux 3.8).
        if server then
            self.server_pid = tonumber(server)
            local known = false
            for _, pid in ipairs(self.pane_pids) do
                known = known or pid == tonumber(pane)
            end
            if not known then
                self.pane_pids[#self.pane_pids + 1] = tonumber(pane)
            end
        end
    end
end

--- The pids the fixture owns: the server and every pane process it saw.
---@return integer[]
function Fixture:pids()
    local pids = { self.server_pid }
    for _, pid in ipairs(self.pane_pids) do
        pids[#pids + 1] = pid
    end
    return pids
end

--- Starts the server with one session, "fixture", whose pane runs cat.
function Fixture:open()
    assert(not self.path, "tmux fixture cannot be entered twice")
    -- /tmp keeps Unix socket names short even with a long checkout or TMPDIR.
    self.path = fs.mkdtemp("libtmux-lua-")
    self.socket = self.path .. "/tmux.sock"
    local ok, failure = pcall(function()
        local result = self:run(
            "new-session",
            "-d",
            "-s",
            "fixture",
            "-P",
            "-F",
            "#{pid} #{pane_pid}",
            "exec /bin/cat"
        )
        self:record_panes(result.stdout)
    end)
    if not ok then
        pcall(self.close, self)
        error(failure, 0)
    end
end

--- Stops everything the fixture owns, and raises if any step failed. A cancellation is raised
--- again after the cleanup, whatever else went wrong.
function Fixture:close()
    if self.closed or not self.path then
        return
    end
    local errors = {}
    local function attempt(operation, action, ...)
        local ok, value = pcall(action, ...)
        if not ok then
            errors[#errors + 1] = { operation = operation, error = value }
            return nil
        end
        return value
    end
    if fs.stat(self.socket) then
        local panes =
            attempt("list-panes", self.try, self, "list-panes", "-a", "-F", "#{pid} #{pane_pid}")
        if panes and panes.code == 0 then
            attempt("observe panes", self.record_panes, self, panes.stdout)
        end
        local released = attempt("kill-server", self.try, self, "kill-server")
        if not released or released.code ~= 0 then
            for _, pid in ipairs(self:pids()) do
                uv.kill(pid, "sigkill")
            end
        end
    end
    for _, client in ipairs(self.clients) do
        attempt("close client " .. client.pid, client.close, client)
    end
    attempt("wait for owned process exit", self.wait_exits, self)
    attempt("remove fixture directory", fs.remove_tree, self.path)
    self.closed = true
    local messages = {}
    for _, failure in ipairs(errors) do
        if failure.error == child.CANCELLED then
            error(child.CANCELLED, 0)
        end
        messages[#messages + 1] = failure.operation .. ": " .. tostring(failure.error)
    end
    if #messages > 0 then
        error("tmux fixture cleanup failed: " .. table.concat(messages, "; "), 0)
    end
end

--- Raises what a test that had cleanup to do should raise. A cleanup failure is raised even when
--- the body skipped or failed, with the body's own error named in it, because a server left
--- running must not pass for a skip. Otherwise the body's error is raised as it was, so a skip or
--- a failed assertion passes through untouched.
---@param body_ok boolean
---@param body_result any the body's return value, or its error
---@param cleanup_ok boolean
---@param cleanup_error any
---@return any
function M.settle(body_ok, body_result, cleanup_ok, cleanup_error)
    if not cleanup_ok then
        if cleanup_error ~= child.CANCELLED and not body_ok and body_result ~= child.CANCELLED then
            -- luaunit reads its own skip and failure prefixes anywhere in a message.
            local ended = tostring(body_result):gsub("LuaUnit test %u+: *", "")
            cleanup_error = ("%s (the body ended with: %s)"):format(cleanup_error, ended)
        end
        error(cleanup_error, 0)
    end
    if not body_ok then
        error(body_result, 0)
    end
    return body_result
end

--- Starts a fixture, runs `body(fixture)` and stops the fixture however the body ends; see settle
--- for what is raised.
---@param opts? {env?: table<string, string>}|fun(fixture: harness.Fixture)
---@param body? fun(fixture: harness.Fixture)
---@return any
function M.with(opts, body)
    if type(opts) == "function" then
        opts, body = nil, opts
    end
    local run = assert(body, "fixture.with needs a body")
    local fixture = M.new(opts)
    local ok, result = pcall(function()
        fixture:open()
        return run(fixture)
    end)
    local closed, failure = pcall(fixture.close, fixture)
    return M.settle(ok, result, closed, failure)
end

--- Skips the running test unless the daemon is tmux 3.7 or newer: observation over a control
--- client below that is refused by the library, and test_features asserts the refusal.
---@param fixture harness.Fixture
function M.require_control(fixture)
    local version = fixture:version()
    if not M.at_least(version, 3, 7) then
        require("luaunit").skip(
            ("control observation needs tmux 3.7; daemon is %s"):format(version)
        )
    end
end

--- Registers `name` once for each host as test_<name>_<host>, called with the host.
---@param suite table
---@param name string
---@param body fun(host: string)
function M.each_host(suite, name, body)
    for _, host in ipairs(M.HOSTS) do
        suite[("test_%s_%s"):format(name, host)] = function()
            body(host)
        end
    end
end

--- The command that runs tests/integration/<name>.lua under a host. For Neovim it also moves the
--- compiled-module path in `env` to LIBTMUX_TEST_LUA_CPATH: Neovim runs the program in its own Lua,
--- which a module built for another ABI would break, and the programs that start a child under the
--- selected Lua put the path back for it.
---@param host string
---@param name string
---@param env table<string, string>
---@return string[]
function M.program_command(host, name, env)
    if host == "luv" then
        return { env.LIBTMUX_TEST_LUA or M.lua(), ("tests/integration/%s.lua"):format(name) }
    end
    env.LIBTMUX_TEST_LUA_CPATH, env.LUA_CPATH = env.LUA_CPATH, nil
    return {
        env.LIBTMUX_TEST_NVIM or M.nvim(),
        "--headless",
        "-u",
        "NONE",
        "-i",
        "NONE",
        "-c",
        ("lua dofile('tests/integration/%s.lua')"):format(name),
    }
end

--- Starts the program tests/integration/<name>.lua under a host, from the repository root.
---@param host string
---@param name string
---@param env table<string, string>
---@param stdin? "null"|"pipe"
---@return harness.Child
function M.start_program(host, name, env, stdin)
    env = M.environment(env)
    env.LIBTMUX_TEST_LUA = env.LIBTMUX_TEST_LUA or M.lua()
    local argv = M.program_command(host, name, env)
    return child.spawn(argv, { env = env, cwd = repo.root, stdin = stdin })
end

--- Runs a program under a host and returns what it wrote. Raises unless it exits 0, naming its
--- standard error.
---@param host string
---@param name string
---@param env table<string, string>
---@param opts? {timeout?: number}
---@return harness.Result
function M.program(host, name, env, opts)
    local program = M.start_program(host, name, env)
    local result = program:finish((opts and opts.timeout) or DEADLINE)
    assert(result.code == 0, result.stderr)
    return result
end

--- The pids that must be gone once the server is stopped; raises with what remains.
function Fixture:wait_exits()
    local left = child.wait_gone(self:pids(), DEADLINE)
    if #left > 0 then
        error(
            "owned tmux processes did not exit: " .. table.concat(map(left, child.describe), ", "),
            0
        )
    end
end

--- The environment a program under tests/integration needs to reach this fixture's server.
---@param extra? table<string, string>
---@return table<string, string>
function Fixture:program_env(extra)
    local env = {}
    for name, value in pairs(self.env) do
        env[name] = value
    end
    env.TMUX_BIN, env.TMUX_SOCKET = self.binary, self.socket
    for name, value in pairs(extra or {}) do
        env[name] = value
    end
    return env
end

--- Starts a program under a host against this fixture's server, with standard input a pipe when
--- asked. The fixture closes it with the rest.
---@param host string
---@param name string
---@param extra? table<string, string>
---@param stdin? "null"|"pipe"
---@return harness.Child
function Fixture:start_program(host, name, extra, stdin)
    local program = M.start_program(host, name, self:program_env(extra), stdin)
    self.clients[#self.clients + 1] = program
    return program
end

--- Runs a program under a host against this fixture's server.
---@param host string
---@param name string
---@param extra? table<string, string>
---@param opts? {timeout?: number}
---@return harness.Result
function Fixture:program(host, name, extra, opts)
    return M.program(host, name, self:program_env(extra), opts)
end

--- The pin directories a library leaves in the fixture's directory while it holds a connection.
---@return string[]
function Fixture:pins()
    local found = {}
    for _, name in ipairs(fs.list(self.path)) do
        if name:match("^libtmux%-lua%-pin%-") then
            found[#found + 1] = name
        end
    end
    return found
end

return M
