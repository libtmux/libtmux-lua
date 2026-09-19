local host = rawget(_G, "vim")
local adapter = require(host and "libtmux.runtime.nvim" or "libtmux.runtime.luv")

local function must(value, err)
    if err then
        error(err, 0)
    end
    return value
end

local function work(runtime)
    local binary, socket = assert(os.getenv("TMUX_BIN")), assert(os.getenv("TMUX_SOCKET"))
    local server = must(runtime:connect({ binary = binary, socket_path = socket }):await())
    local mode = assert(os.getenv("LIBTMUX_PANE_CASE"))
    local argv = {
        assert(os.getenv("LIBTMUX_TEST_PYTHON")),
        assert(os.getenv("LIBTMUX_PANE_SCRIPT")),
        assert(os.getenv("LIBTMUX_PANE_REPORT")),
    }
    local created = must(server
        :new_session({
            name = "pane-api",
            width = 80,
            height = 20,
            argv = mode == "io" and argv or { "/bin/cat" },
        })
        :await())
    local pane = created.pane
    local id = assert(pane:reference()).id
    local session_id = assert(created.session:reference()).id
    local function command(args)
        local result = must(server:command(args):await())
        assert(result.exit_code == 0, result.stderr)
        return result.stdout
    end
    if mode == "io" then
        command({ "wait-for", "pane-input-ready" })
        local observation = must(server:observe(created.session):await())
        local watch = must(observation:watch_pane(pane):await())
        local function output_until(marker)
            local output = ""
            repeat
                local event = must(watch:next({ timeout = 750 }):await())
                output = output .. event.data
            until output:find(marker, 1, true)
            return output
        end
        must(pane:send_text("literal;#{pane_id}\\λ雪"):await())
        output_until("TEXT_OK")
        must(pane:send_keys({ "Enter" }):await())
        output_until("RENDER_DONE")
        local captured = must(pane:capture({ history_lines = 100, preserve_spaces = true }):await())
        local native = command({ "capture-pane", "-p", "-t", id, "-S", "-100", "-N" })
        assert(captured.bytes == native)
        assert(must(captured:text()) == native)
        assert(
            captured.bytes:find("line%-00 trailing  ")
                and captured.bytes:find("RENDER_DONE", 1, true)
        )
        must(pane:copy_mode({ page_up = true }):await())
        must(pane:copy_command("history-top"):await())
        assert(command({ "display-message", "-p", "-t", id, "#{pane_mode}" }) == "copy-mode\n")
        captured = must(pane:capture():await())
        assert(captured.bytes == command({ "capture-pane", "-p", "-t", id }))
        local version = command({ "display-message", "-p", "#{version}" })
        local minor = tonumber(version:match("^3%.(%d+)"))
        local trimmed, trim_error = pane:capture({ trim_empty_cells = true }):await()
        if minor >= 4 then
            assert(trimmed, tostring(trim_error))
            assert(trimmed.bytes == command({ "capture-pane", "-p", "-T", "-t", id }))
        else
            assert(trimmed == nil and trim_error and trim_error.code == "unsupported")
        end
        local value, err = pane:capture({ mode_screen = true }):await()
        if minor >= 6 then
            assert(value, tostring(err))
            assert(value.bytes == command({ "capture-pane", "-p", "-M", "-t", id }))
        else
            assert(value == nil and err and err.code == "unsupported")
        end
        must(pane:copy_command("cancel"):await())
        assert(command({ "display-message", "-p", "-t", id, "#{pane_in_mode}" }) == "0\n")
        must(watch:close():await())
        must(observation:close():await())
    else
        local other =
            must(pane:split({ direction = "right", percent = 40, argv = { "/bin/cat" } }):await())
        must(pane:resize({ width = 40 }):await())
        assert(command({ "display-message", "-p", "-t", id, "#{pane_width}" }) == "40\n")
        must(pane:resize({ direction = "right", amount = 3 }):await())
        assert(command({ "display-message", "-p", "-t", id, "#{pane_width}" }) == "43\n")
        local value, err = pane:respawn():await()
        assert(value == nil and err and err.code == "exit_failed")
        must(pane:respawn({
            kill = true,
            argv = argv,
            cwd = assert(os.getenv("LIBTMUX_PANE_CWD")),
            environment = { PANE_RESPAWN = "yes", VALUE = "literal#{pid};" },
        }):await())
        command({ "wait-for", "pane-respawn-ready" })
        assert(pane:reference().id == id)
        must(other.pane:kill():await())
        assert(command({ "list-panes", "-t", session_id, "-F", "#{pane_id}" }) == id .. "\n")
        must(pane:kill():await())
        local missing = must(server:command({ "has-session", "-t", session_id }):await())
        assert(missing.exit_code ~= 0)
    end
    must(server:close():await())
    return "public Pane operations PASS"
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
    end, { max_active = 1 })
else
    print(must(adapter.run(work, { max_active = 1 })))
end
