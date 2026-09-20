local endpoints = require("libtmux._internal.endpoint")
local control = require("libtmux._internal.control")
local host = rawget(_G, "vim")
local adapter = require(host and "libtmux.runtime.nvim" or "libtmux.runtime.luv")
local pane = assert(os.getenv("TMUX_TEST_PANE"))
local session = assert(os.getenv("TMUX_TEST_SESSION"))
local mode = os.getenv("LIBTMUX_CONTROL_CASE") or "stream"

local function work(runtime)
    local bound = assert(endpoints
        .bind(runtime, {
            binary = assert(os.getenv("TMUX_BIN")),
            socket = assert(os.getenv("TMUX_SOCKET")),
            config = "/dev/null",
        })
        :await())
    local connection, connection_error =
        control.open(runtime, bound, { session_id = session }):await()
    if mode == "missing" then
        assert(connection == nil and connection_error ~= nil)
        assert(bound:close():await())
        return "control observation passed"
    end
    assert(connection, tostring(connection_error))
    if mode == "unlink" then
        local watch = assert(connection:watch_pane(pane):await())
        local notifications = assert(connection:watch_notifications():await())
        local unrelated = assert(os.getenv("TMUX_TEST_UNRELATED_WINDOW"))
        assert(bound:execute({ "kill-window", "-t", unrelated }):await())
        local notification
        repeat
            notification = assert(notifications:next({ timeout = 750 }):await())
        until notification.name == "unlinked-window-close" and notification.payload == unrelated
        assert(connection:coverage())
        local pending = watch:next({ timeout = 750 })
        assert(not pending:is_settled())
        local window = assert(os.getenv("TMUX_TEST_WINDOW"))
        assert(bound:execute({ "unlink-window", "-t", session .. ":" .. window }):await())
        local value, err = pending:await()
        assert(value == nil and err.code == "observation_gap", tostring(err))
        value, err = connection:coverage()
        assert(value == nil and err.code == "observation_gap", tostring(err))
        assert(watch:close():await())
        assert(notifications:close():await())
        assert(connection:close():await())
        assert(bound:close():await())
        return "control observation passed"
    end
    if mode == "format" then
        local title = "title;quote'\\λ雪"
        assert(bound:execute({ "select-pane", "-t", pane, "-T", title }):await())
        local reported =
            assert(bound:execute({ "display-message", "-p", "-t", pane, "#{pane_title}" }):await())
        local expected_title = reported.stdout:sub(1, -2)
        local formats = assert(connection:subscribe_format(pane, { "title", "dead" }):await())
        local item = assert(formats:next({ timeout = 1500 }):await())
        assert(item.kind == "format" and item.pane == pane and item.session_id == session)
        assert(
            item.value.title == expected_title and item.value.dead == false,
            string.format("title %q dead %s", item.value.title, tostring(item.value.dead))
        )
        assert(formats:close():await())
        assert(connection:close():await())
        assert(bound:close():await())
        return "control observation passed"
    end
    local watch = assert(connection:watch_pane(pane):await())
    local slow = assert(connection:watch_pane(pane, { max_bytes = 32 }):await())
    local uncovered, uncovered_error = connection:watch_pane("%2147483647"):await()
    assert(uncovered == nil and uncovered_error.code == "uncovered_pane")
    local output = "stty raw -echo; printf 'BYTE\\000\\001\\012\\015\\134\\377DONE'; exec /bin/cat"
    assert(bound:execute({ "respawn-pane", "-k", "-t", pane, output }):await())
    local bytes = ""
    repeat
        local item = assert(watch:next({ timeout = 750 }):await())
        assert(item.pane == pane and item.generation == connection:coverage().generation)
        bytes = bytes .. item.data
    until bytes:find("DONE", 1, true)
    assert(bytes:find("BYTE\000\001\n\r\\\255DONE", 1, true), string.format("%q", bytes))
    local sent, send_error = bound:execute({ "send-keys", "-l", "-t", pane, "--", "INPUT" }):await()
    assert(sent, tostring(send_error))
    assert(sent.exit_code == 0 and sent.signal == 0)
    sent, send_error = bound:execute({ "send-keys", "-t", pane, "Enter" }):await()
    assert(sent, tostring(send_error))
    assert(sent.exit_code == 0 and sent.signal == 0)
    local delivered = ""
    repeat
        local item = assert(watch:next({ timeout = 750 }):await())
        delivered = delivered .. item.data
    until delivered:find("INPUT\r", 1, true)
    local value, err = slow:next():await()
    assert(value == nil and err.code == "observation_gap")
    local pending = watch:next()
    pending:cancel()
    assert(watch:close():await())
    value, err = watch:next():await()
    assert(value == nil and err == nil)
    assert(connection:close():await())
    assert(bound:close():await())
    return "control observation passed"
end

if host then
    adapter.start(work, function(value, err)
        if err then
            io.stderr:write(tostring(err), "\n")
            host.cmd("cquit 1")
        else
            io.stdout:write(value, "\n")
            host.cmd("qa!")
        end
    end)
else
    local value, err = adapter.run(work)
    assert(value, tostring(err))
    io.stdout:write(value, "\n")
end
