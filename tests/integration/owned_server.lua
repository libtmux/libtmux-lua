local host = rawget(_G, "vim")
local adapter = require(host and "libtmux.runtime.nvim" or "libtmux.runtime.luv")
local process = require("libtmux._internal.process")
local mode = assert(os.getenv("LIBTMUX_OWNED_CASE"))
local binary = assert(os.getenv("TMUX_BIN"))
local root = assert(os.getenv("OWNED_ROOT"))

local function must(value, err)
    if err ~= nil then
        error(err, 0)
    end
    return value
end

local function directory_of(owned)
    return assert(owned.socket_path:match("^(.*)/[^/]+$"))
end

-- The Python side reads these lines to check the directory and socket independently.
local function announce(owned)
    io.stdout:write("DIR ", directory_of(owned), "\n", "SOCKET ", owned.socket_path, "\n")
    io.stdout:flush()
end

-- Whether a tmux client reaches a server on the socket; -N never starts one.
local function answers(runtime, socket)
    local result, err =
        process.execute(runtime, { binary, "-S", socket, "-N", "list-sessions" }):await()
    if result then
        return true
    end
    return err.code == "exit_failed" and err.partial.stderr:find("no sessions", 1, true) ~= nil
end

local function exists(runtime, path)
    return runtime._driver.uv.fs_stat(path) ~= nil
end

local function gone(runtime, owned)
    assert(not exists(runtime, directory_of(owned)), "the directory survived stop")
    assert(not answers(runtime, owned.socket_path), "a server still answers after stop")
end

local function names(records)
    local set = {}
    for _, record in ipairs(records) do
        set[record.name] = record.value
    end
    return set
end

local cases = {}

function cases.round_trip(runtime)
    local owned = must(runtime:start_server({ binary = binary, root = root }):await())
    announce(owned)
    local snapshot = must(owned.server:snapshot({ strict = true }):await())
    assert(#snapshot.sessions == 0, "the new server has sessions")
    local created = must(
        owned.server
            :new_session({ name = "demo", window_name = "main", argv = { "/bin/cat" } })
            :await()
    )
    assert(created.session:reference().id == "$0")
    must(owned:stop():await())
    gone(runtime, owned)
    must(owned:stop():await())
    return "round trip"
end

function cases.zero_sessions(runtime)
    local owned = must(runtime:start_server({ binary = binary, root = root }):await())
    announce(owned)
    -- The daemon answers with no session, and keeps answering after the last one ends.
    must(owned.server:snapshot():await())
    local created = must(owned.server:new_session({ name = "demo", argv = { "/bin/cat" } }):await())
    must(created.session:kill():await())
    local snapshot = must(owned.server:snapshot():await())
    assert(#snapshot.sessions == 0, "the killed session is still listed")
    local exit_empty = must(owned.server:get_option("exit-empty"):await())
    assert(exit_empty.value == false, "exit-empty is on")
    must(owned:stop():await())
    return "zero sessions"
end

function cases.environment(runtime)
    for _, name in ipairs({ "TMUX", "TMUX_PANE", "LIBTMUX_SOCKET", "LIBTMUX_SOCKET_PATH" }) do
        assert(os.getenv(name), "the test did not plant " .. name)
    end
    local owned = must(
        runtime
            :start_server({ binary = binary, root = root, environment = { OWNED_OVERLAY = "yes" } })
            :await()
    )
    announce(owned)
    local seen = names(must(owned.server:list_environment():await()))
    for _, name in ipairs({
        "TMUX",
        "TMUX_PANE",
        "LIBTMUX_SOCKET",
        "LIBTMUX_SOCKET_PATH",
        "LIBTMUX_SOCKET_NAME",
    }) do
        assert(seen[name] == nil, name .. " reached the daemon")
    end
    assert(seen.TMUX_TMPDIR == directory_of(owned), "TMUX_TMPDIR is not the private directory")
    assert(seen.OWNED_OVERLAY == "yes", "the environment overlay did not reach the daemon")
    assert(seen.PATH ~= nil, "the rest of the environment was dropped")
    must(owned:stop():await())
    return "environment"
end

-- The server dies with the scope however the body ends.
function cases.scope(runtime)
    local seen
    local value, err = runtime
        :with_server({ binary = binary, root = root }, function(server, owned)
            seen = owned
            announce(owned)
            must(server:new_session({ name = "demo", argv = { "/bin/cat" } }):await())
            return "body value"
        end)
        :await()
    assert(value == "body value" and err == nil, tostring(err))
    gone(runtime, seen)

    value, err = runtime
        :with_server({ binary = binary, root = root }, function(_, owned)
            seen = owned
            announce(owned)
            return nil, { code = "body_failed", message = "the body failed" }
        end)
        :await()
    assert(value == nil and err.code == "body_failed", "the body error was lost")
    gone(runtime, seen)

    -- A raised error settles the request before the stop runs. A task joins only
    -- when its requests retire, so awaiting a child waits out the stop.
    local child = runtime:spawn(function()
        local raised, raised_error = runtime
            :with_server({ binary = binary, root = root }, function(_, owned)
                seen = owned
                announce(owned)
                error("the body raised", 0)
            end)
            :await()
        assert(raised == nil and raised_error ~= nil, "a raised error was lost")
        return true
    end)
    must(child:await())
    gone(runtime, seen)
    return "scope"
end

-- Nothing stops the server by hand: leaving the runtime must.
function cases.exit(runtime)
    local owned = must(runtime:start_server({ binary = binary, root = root }):await())
    announce(owned)
    if os.getenv("OWNED_EXIT") == "error" then
        error("the program failed", 0)
    end
    return "exit"
end

function cases.stuck(runtime)
    local flag = assert(os.getenv("OWNED_STUCK_FLAG"))
    local owned = must(runtime
        :start_server({
            binary = assert(os.getenv("OWNED_STUCK_BIN")),
            root = root,
            timeout = 300,
        })
        :await())
    announce(owned)
    local stopped, err = owned:stop():await()
    assert(stopped == nil, "stop reported success while the daemon answered")
    assert(err.code == "stop_failed", tostring(err.code))
    assert(err.directory == directory_of(owned), "the error does not name the directory")
    assert(exists(runtime, directory_of(owned)), "the directory of a live server was removed")
    assert(answers(runtime, owned.socket_path), "the daemon stopped on its own")
    assert(os.remove(flag), "the stuck flag is missing")
    must(owned:stop():await())
    gone(runtime, owned)
    return "stuck"
end

function cases.leak(runtime)
    local owned = must(runtime:start_server({ binary = binary, root = root }):await())
    announce(owned)
    local directory = directory_of(owned)
    local extra = directory .. "/extra.sock"
    must(process
        .execute(runtime, {
            binary,
            "-S",
            extra,
            "-f",
            "/dev/null",
            "new-session",
            "-d",
            "/bin/cat",
        })
        :await())
    -- A program that names no socket reaches tmux's default one under TMUX_TMPDIR.
    must(process
        .execute(runtime, {
            binary,
            "-f",
            "/dev/null",
            "new-session",
            "-d",
            "/bin/cat",
        }, { env = { "TMUX_TMPDIR=" .. directory } })
        :await())
    assert(answers(runtime, extra), "the extra server did not start")
    local stopped, err = owned:stop():await()
    assert(stopped == nil and err.code == "leaked_server", tostring(err and err.code))
    assert(#err.sockets == 2, "the leaks are not named")
    assert(err.sockets[1] == "extra.sock", err.sockets[1])
    assert(err.sockets[2]:find("^tmux%-%d+/default$"), err.sockets[2])
    assert(not exists(runtime, directory), "the directory survived")
    assert(not answers(runtime, extra), "the leaked server still answers")
    return "leak"
end

function cases.overflow(runtime)
    local long = root .. "/" .. ("r"):rep(120)
    local owned, err = runtime:start_server({ binary = binary, root = long }):await()
    assert(owned == nil and err.code == "invalid_endpoint", tostring(err and err.code))
    assert(err.effect == "not_sent")
    return "overflow"
end

local function work(runtime)
    local result = must(cases[mode](runtime))
    return "owned server " .. result .. " PASS"
end

if host then
    adapter.start(work, function(result, err)
        if not result then
            io.stderr:write(tostring(err) .. "\n")
            host.cmd("cquit 1")
        else
            io.stdout:write(result .. "\n")
            host.cmd("qa!")
        end
    end)
else
    local result, err = adapter.run(work)
    if mode == "exit" then
        -- The runtime has ended; its cleanup must already have stopped the server.
        io.stdout:write(os.getenv("OWNED_EXIT") == "error" and "RUN ERROR " or "RUN OK ")
        io.stdout:write(err and tostring(err.code) or "", "\n")
        os.exit(0)
    end
    print(must(result, err))
end
