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
    local created = must(server
        :new_session({
            name = "literal-#{pid}",
            window_name = "window-#{window_id}",
            cwd = assert(os.getenv("LIBTMUX_CREATE_CWD")),
            environment = { LIBTMUX_LITERAL = "#{pid};$(not-a-shell)" },
            argv = {
                assert(os.getenv("LIBTMUX_TEST_PYTHON")),
                assert(os.getenv("LIBTMUX_CREATE_SCRIPT")),
                assert(os.getenv("LIBTMUX_CREATE_REPORT")),
                "literal;$(not-a-shell)\n#{pid}",
            },
            width = 120,
            height = 40,
        })
        :await())
    local session, window, pane =
        created.session:reference(), created.window:reference(), created.pane:reference()
    assert(session.id ~= "$0" and window.id ~= "@0" and pane.id ~= "%0")
    local ready = must(server:command({ "wait-for", "libtmux-created-ready" }):await())
    assert(ready.exit_code == 0)
    local values = must(server
        :command({
            "display-message",
            "-p",
            "-t",
            pane.id,
            "#{session_name}\t#{window_name}\t#{pane_current_path}",
        })
        :await())
    assert(
        values.stdout
            == "literal-#{pid}\twindow-#{window_id}\t"
                .. os.getenv("LIBTMUX_CREATE_CWD")
                .. "\n"
    )
    local other = must(
        created.session:new_window({ index = 7, name = "other", shell = "exec /bin/cat" }):await()
    )
    assert(other.session:reference().id == session.id and other.window_link:reference().index == 7)
    pane.id = "%999999"
    local split = must(
        created.pane:split({ direction = "right", percent = 40, argv = { "/bin/cat" } }):await()
    )
    assert(split.window:reference().id == window.id)
    assert(split.pane:reference().id ~= created.pane:reference().id)
    assert(#split.created == 1 and split.created[1] == "pane")
    local absent, err = server
        :new_session({
            cwd = os.getenv("LIBTMUX_CREATE_CWD") .. "/absent",
            name = "must-not-exist",
        })
        :await()
    assert(not absent and err.code == "invalid_directory" and err.effect == "not_sent")
    local missing = must(server:command({ "has-session", "-t", "=must-not-exist" }):await())
    assert(missing.exit_code ~= 0)
    must(server:close():await())
    return "public domain creation PASS"
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
