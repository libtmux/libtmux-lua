local host = rawget(_G, "vim")
local adapter = require(host and "libtmux.runtime.nvim" or "libtmux.runtime.luv")
local mode = assert(os.getenv("LIBTMUX_TOPOLOGY_CASE"))

local function must(value, err)
    if err then
        error(tostring(err), 2)
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
    local created = must(
        server
            :new_session({ name = "topology", width = 100, height = 40, argv = { "/bin/cat" } })
            :await()
    )
    local session, window, pane = created.session, created.window, created.pane
    local sid, wid, pid = session:reference().id, window:reference().id, pane:reference().id
    local function command(args)
        local result = must(server:command(args):await())
        assert(result.exit_code == 0, result.stderr)
        return result.stdout
    end
    local function field(target, name)
        return command({ "display-message", "-p", "-t", target, "#{" .. name .. "}" })
    end
    if mode == "pane_selection" then
        local other = must(pane:split({ direction = "right", argv = { "/bin/cat" } }):await()).pane
        local other_id = other:reference().id
        assert(field(wid, "pane_id") == pid .. "\n")
        must(pane:set_title("literal#{pane_id};λ雪"):await())
        assert(field(pid, "pane_title") == "literal#{pane_id};λ雪\n")
        assert(field(wid, "pane_id") == pid .. "\n")
        command({ "resize-pane", "-t", pid, "-Z" })
        must(other:select({ keep_zoom = true }):await())
        assert(field(wid, "pane_id") == other_id .. "\n")
        assert(field(wid, "window_zoomed_flag") == "1\n")
        must(pane:select():await())
        assert(field(wid, "pane_id") == pid .. "\n")
        assert(field(wid, "window_zoomed_flag") == "0\n")
        local value, err = pane:set_title("\255"):await()
        assert(value == nil and err and err.code == "invalid_utf8" and err.effect == "not_sent")
        value, err = pane:set_title("line\nnext"):await()
        assert(value == nil and err and err.code == "invalid_argument" and err.effect == "not_sent")
        value, err = pane:set_title(""):await()
        if os.getenv("TMUX_DAEMON_VERSION") == "3.7" then
            assert(value == nil and err and err.code == "unsupported" and err.effect == "not_sent")
            assert(field(pid, "pane_title") == "literal#{pane_id};λ雪\n")
        else
            must(value, err)
            assert(field(pid, "pane_title") == "\n")
        end
    elseif mode == "pane_swap" then
        local sibling =
            must(pane:split({ direction = "right", argv = { "/bin/cat" } }):await()).pane
        local second = must(session:new_window({ argv = { "/bin/cat" } }):await())
        local target = must(second.pane:split({ argv = { "/bin/cat" } }):await()).pane
        local sibling_id, target_id = sibling:reference().id, target:reference().id
        local second_wid, second_pid = second.window:reference().id, second.pane:reference().id
        must(sibling:swap(target):await())
        assert(field(sibling_id, "window_id") == second_wid .. "\n")
        assert(field(target_id, "window_id") == wid .. "\n")
        assert(field(wid, "pane_id") == pid .. "\n")
        assert(field(second_wid, "pane_id") == second_pid .. "\n")
        must(sibling:swap(target, { select = true }):await())
        assert(field(wid, "pane_id") == sibling_id .. "\n")
        assert(field(second_wid, "pane_id") == target_id .. "\n")
        local old_index = field(sibling_id, "pane_index")
        must(sibling:swap(pane):await())
        assert(field(wid, "pane_id") == sibling_id .. "\n")
        assert(field(sibling_id, "pane_index") ~= old_index)
        must(target:kill():await())
        local value, err = sibling:swap(target):await()
        assert(value == nil and err and err.code == "exit_failed" and err.effect == "completed")
        assert(field(sibling_id, "window_id") == wid .. "\n")
    elseif mode == "rename_kill" then
        must(session:rename("literal#{session_id};λ"):await())
        assert(field(sid, "session_name") == "literal#{session_id};λ\n")
        must(window:rename("literal#{window_id};雪"):await())
        assert(field(wid, "window_name") == "literal#{window_id};雪\n")
        assert(must(window:get_option("automatic-rename"):await()).value == false)
        local second = must(session:new_window({ argv = { "/bin/cat" } }):await())
        command({ "link-window", "-s", wid, "-t", sid .. ":5", "-d" })
        must(window:kill():await())
        assert(
            command({ "list-windows", "-t", sid, "-F", "#{window_id}" })
                == second.window:reference().id .. "\n"
        )
        must(session:kill():await())
        local result = must(server:command({ "has-session", "-t", sid }):await())
        assert(result.exit_code ~= 0)
    elseif mode == "navigation" then
        local second = must(session:new_window({ index = 5, argv = { "/bin/cat" } }):await())
        local third = must(session:new_window({ index = 9, argv = { "/bin/cat" } }):await())
        must(session:navigate_window("next"):await())
        assert(field(sid, "window_id") == second.window:reference().id .. "\n")
        must(session:navigate_window("previous"):await())
        assert(field(sid, "window_id") == wid .. "\n")
        must(session:navigate_window("last"):await())
        assert(field(sid, "window_id") == second.window:reference().id .. "\n")
        must(session:renumber_windows():await())
        assert(command({ "list-windows", "-t", sid, "-F", "#{window_index}" }) == "0\n1\n2\n")
        assert(field(third.window:reference().id, "window_index") == "2\n")
    elseif mode == "layout" then
        must(pane:split({ direction = "right", argv = { "/bin/cat" } }):await())
        must(window:resize({ width = 90, height = 30 }):await())
        assert(field(wid, "window_width") == "90\n")
        assert(field(wid, "window_height") == "30\n")
        assert(must(window:get_option("window-size"):await()).value == "manual")
        must(window:layout({ named = "even-vertical" }):await())
        local saved = field(wid, "window_layout"):sub(1, -2)
        must(window:layout({ named = "even-horizontal" }):await())
        assert(field(wid, "window_layout") ~= saved .. "\n")
        must(window:layout({ layout = saved }):await())
        assert(field(wid, "window_layout") == saved .. "\n")
        command({ "resize-pane", "-t", pid, "-Z" })
        local value, err = window:layout({ layout = "invalid-layout" }):await()
        assert(value == nil and err and err.code == "invalid_layout" and err.effect == "not_sent")
        assert(field(wid, "window_zoomed_flag") == "1\n")
        value, err = window:layout({ layout = "0000,invalid-layout" }):await()
        assert(value == nil and err and err.code == "exit_failed" and err.effect == "completed")
        assert(field(wid, "window_zoomed_flag") == "0\n")
    else
        error("unknown topology test case")
    end
    must(server:close():await())
    return "public topology " .. mode .. " PASS"
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
