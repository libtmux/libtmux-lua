local host = rawget(_G, "vim")
local adapter = require(host and "libtmux.runtime.nvim" or "libtmux.runtime.luv")

local function must(value, err)
    if err then
        error(err, 0)
    end
    return value
end

local function work(runtime)
    local server = must(runtime
        :connect({
            binary = assert(os.getenv("TMUX_BIN")),
            socket_path = assert(os.getenv("TMUX_SOCKET")),
        })
        :await())
    local case = assert(os.getenv("LIBTMUX_CAPTURE_CASE"))
    local created = must(server
        :new_session({
            name = "capture-api",
            width = 80,
            height = 20,
            argv = {
                assert(os.getenv("LIBTMUX_TEST_PYTHON")),
                assert(os.getenv("LIBTMUX_CAPTURE_SCRIPT")),
                case,
            },
        })
        :await())
    local pane = created.pane
    local id = assert(pane:reference()).id
    local function command(args)
        local result = must(server:command(args):await())
        assert(result.exit_code == 0, result.stderr)
        return result.stdout
    end
    command({ "wait-for", "capture-input-ready" })
    local observation = must(server:observe(created.session):await())
    local watch = must(observation:watch_pane(pane):await())
    must(pane:send_text("x"):await())
    local marker = case == "pending" and "PENDING_READY\027[" or "CAPTURE_READY"
    local output = ""
    repeat
        output = output .. must(watch:next({ timeout = 750 }):await()).data
    until output:find(marker, 1, true)

    if case == "pending" then
        local pending = must(pane:capture({ pending_escape_sequences = true }):await())
        assert(pending.bytes == "\027[\n", string.format("%q", pending.bytes))
        local escaped = must(pane:capture({
            pending_escape_sequences = true,
            escape_nonprintable = true,
        }):await())
        assert(escaped.bytes == "\\033[\n", string.format("%q", escaped.bytes))
    else
        local minor =
            assert(tonumber(command({ "display-message", "-p", "#{version}" }):match("^3%.(%d+)")))
        local value, err = pane:capture({ alternate_screen = true }):await()
        assert(value == nil and err and err.code == "exit_failed")
        local alternate = must(pane:capture({
            alternate_screen = true,
            ignore_missing_alternate = true,
        }):await())
        assert(alternate.bytes == "\n")
        local links, cause = pane:capture({ hyperlinks_only = true, start_line = "-" }):await()
        if minor >= 7 then
            assert(links, tostring(cause))
            assert(links.bytes == "https://example.invalid/\n", links.bytes)
            local numbered = must(pane:capture({
                line_numbers = true,
                line_flags = true,
                start_line = 0,
                end_line = 0,
            }):await())
            assert(numbered.bytes:match("^0 [%u%-]+ "))
            assert(
                numbered.bytes
                    == command({ "capture-pane", "-p", "-L", "-F", "-S", "0", "-E", "0", "-t", id })
            )
        else
            assert(links == nil and cause and cause.code == "unsupported")
        end
        must(pane:copy_mode():await())
        local before =
            command({ "display-message", "-p", "-t", id, "#{history_size}:#{pane_in_mode}" })
        assert(assert(tonumber(before:match("^(%d+):1\n$"))) > 0, before)
        if minor < 4 then
            value, err = pane:clear_history({ clear_hyperlinks = true }):await()
            assert(value == nil and err and err.code == "unsupported" and err.effect == "not_sent")
            assert(
                command({ "display-message", "-p", "-t", id, "#{history_size}:#{pane_in_mode}" })
                    == before
            )
        end
        must(pane:clear_history({ clear_hyperlinks = minor >= 4 }):await())
        assert(
            command({ "display-message", "-p", "-t", id, "#{history_size}:#{pane_in_mode}" })
                == "0:0\n"
        )
        if minor >= 7 then
            assert(must(pane:capture({ hyperlinks_only = true }):await()).bytes == "\n")
        end
    end
    must(watch:close():await())
    must(observation:close():await())
    must(server:close():await())
    return "public capture/history PASS"
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
    print(must(adapter.run(work)))
end
