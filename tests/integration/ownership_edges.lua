local adapter = require("libtmux.runtime.luv")
-- luv is the native host module, distinct from libtmux.runtime.luv.
---@diagnostic disable-next-line: different-requires
local uv = require("luv")
local function must(value, err)
    if err then
        error(err, 0)
    end
    return value
end
local checks = 0
local function check(value, message)
    assert(value, message)
    checks = checks + 1
end
local function cmd(server, words)
    return must(server:command(words):await())
end
local value, err = adapter.run(function(runtime)
    local root = assert(os.getenv("LIBTMUX_TEST_ROOT"))
    local server = must(runtime:connect():await())
    local raw = must(server:new_session({ name = "adopted", argv = { "/bin/cat" } }):await())
    local session_owner = must(raw.session:adopt():await())
    local child =
        must(raw.session:new_window({ name = "adopt-window", argv = { "/bin/cat" } }):await())
    local window_owner = must(child.window:adopt():await())
    local split = must(child.pane:split({ argv = { "/bin/cat" } }):await())
    local pane_owner = must(split.pane:adopt():await())
    cmd(
        server,
        { "join-pane", "-d", "-s", split.pane:reference().id, "-t", raw.pane:reference().id }
    )
    must(pane_owner:close():await())
    check(pane_owner.closed, "moved pane closes by ID")
    local other =
        must(server:owned_session({ name = "destination", argv = { "/bin/cat" } }):await())
    cmd(server, {
        "move-window",
        "-s",
        child.window:reference().id,
        "-t",
        other.value:reference().id .. ":",
    })
    must(window_owner:close():await())
    check(window_owner.closed, "moved window closes by ID")
    must(raw.session:rename("adopt-renamed"):await())
    must(session_owner:close():await())
    check(session_owner.closed, "renamed session closes by ID")

    local one = must(other.value:find_or_create_window("same", { argv = { "/bin/cat" } }):await())
    local two = must(other.value:find_or_create_window("same"):await())
    check(one.created and not two.created and not two.owner)
    local duplicate =
        must(other.value:owned_window({ name = "same", argv = { "/bin/cat" } }):await())
    local ambiguous, ambiguity = other.value:find_or_create_window("same"):await()
    check(not ambiguous and ambiguity.code == "ambiguous")
    must(duplicate:close():await())
    must(one.owner:close():await())
    must(other:close():await())

    local released =
        must(server:owned_session({ name = "released", argv = { "/bin/cat" } }):await())
    local borrowed = must(released:release())
    must(released:close():await())
    check(must(borrowed:snapshot():await()).name == "released")
    must(must(borrowed:adopt():await()):close():await())

    local old = must(runtime:owned_server({ socket_path = root .. "/replace" }):await())
    must(uv.fs_rename(root .. "/replace", root .. "/original-link"))
    local replacement = must(runtime:owned_server({ socket_path = root .. "/replace" }):await())
    local closed = must(old:close():await())
    check(closed and old.closed, "the original foreground child retires through its own handle")
    check(
        cmd(replacement.value, { "display-message", "-p", "replacement survives" }).stdout
            == "replacement survives\n"
    )
    local old_receipt, new_receipt = old:receipt(), replacement:receipt()
    local collision = "#{&&:#{==:#{pid},"
        .. new_receipt.pid
        .. "},#{&&:#{==:#{start_time},"
        .. new_receipt.started
        .. "},#{==:#{@libtmux_owner_generation},"
        .. old_receipt.token
        .. "}}}"
    local guarded = cmd(
        replacement.value,
        { "if-shell", "-F", collision, "kill-server", "display-message -p token-refused" }
    )
    check(guarded.stdout == "token-refused\n", "token defeats simulated PID/start collision")
    must(replacement:close():await())
    must(uv.fs_unlink(root .. "/original-link"))
    check(must(old:close():await()), "repeat original-child cleanup is harmless")

    local fresh =
        must(runtime:owned_server({ socket_path = root .. "/retry-path-cleanup" }):await())
    local rmdir, denied = uv.fs_rmdir, false
    uv.fs_rmdir = function(path, callback)
        if path:find("libtmux-lua-start-", 1, true) and not denied then
            denied = true
            return nil, "EACCES: injected"
        end
        return rmdir(path, callback)
    end
    local removed, remove_error = fresh:close():await()
    uv.fs_rmdir = rmdir
    check(not removed and remove_error and not fresh.closed)
    must(fresh:close():await())
    check(fresh.closed, "local directory cleanup can be retried after daemon exit")

    local bad, bad_error = runtime
        :owned_server({
            socket_name = "invalid",
            client_env = { TMUX_TMPDIR = root .. "/missing/.." },
        })
        :await()
    check(not bad and bad_error and bad_error.code == "invalid_endpoint")
    must(uv.fs_mkdir(root .. "/branch", 448))
    must(uv.fs_mkdir(root .. "/branch/inner", 448))
    must(uv.fs_symlink(root .. "/branch/inner", root .. "/link"))
    local traversed = must(runtime
        :owned_server({
            socket_name = "traversed",
            client_env = { TMUX_TMPDIR = root .. "/link/.." },
        })
        :await())
    check(uv.fs_stat(root .. "/branch/tmux-" .. uv.getuid() .. "/traversed").type == "socket")
    must(traversed:close():await())

    local stale_socket = uv.new_pipe(false)
    must(stale_socket:bind(root .. "/stale"))
    must(runtime:defer(function()
        if not stale_socket:is_closing() then
            stale_socket:close()
        end
    end))
    local discovered =
        must(runtime:discover_servers({ roots = { root }, max_entries = 128 }):await())
    local failed_probe = false
    for _, diagnostic in ipairs(discovered.diagnostics) do
        if diagnostic.path == root .. "/stale" and diagnostic.code == "probe_failed" then
            failed_probe = true
        end
    end
    check(failed_probe, "stale sockets report failed no-start probes")
    stale_socket:close()
    local truncated = must(
        runtime:discover_servers({ roots = { root }, max_entries = 1, max_probes = 1 }):await()
    )
    check(truncated.truncated and truncated.entries == 1)
    local occupied, occupied_error = runtime:owned_server():await()
    check(not occupied and occupied_error and occupied_error.code == "already_exists")
    print("ownership edge checks PASS " .. checks)
    return true
end)
if not value and type(err) == "table" then
    io.stderr:write("code: ", tostring(err.code), "\n")
    if err.cause then
        io.stderr:write("cause: ", tostring(err.cause), "\n")
    end
    for _, failure in ipairs(err.errors or {}) do
        io.stderr:write("cleanup: ", tostring(failure), "\n")
    end
end
assert(value, tostring(err))
