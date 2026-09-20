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
    local function link_at(index, session_id)
        local snapshot = must(server:snapshot():await())
        for _, record in ipairs(snapshot.window_links) do
            if record.session_id == (session_id or sid) and record.index == index then
                return must(server:handle(snapshot, record))
            end
        end
        error("expected window link missing")
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
    elseif mode == "link_identity" then
        local original = created.window_link
        assert(type(original.link) == "function", "WindowLink link API is missing")
        must(original:link({ session = session, index = 5 }):await())
        local duplicate = link_at(5)
        must(duplicate:select():await())
        assert(field(sid, "window_index") == "5\n")
        must(original:swap(duplicate):await())
        assert(field(sid .. ":0", "window_id") == wid .. "\n")
        assert(field(sid .. ":5", "window_id") == wid .. "\n")
        must(original:unlink():await())
        assert(field(sid .. ":5", "window_id") == wid .. "\n")
        local replacement = must(session:new_window({ index = 0, argv = { "/bin/cat" } }):await())
        local value, err = original:unlink():await()
        assert(value == nil and err and err.code == "stale_target" and err.effect == "not_sent")
        assert(field(sid .. ":0", "window_id") == replacement.window:reference().id .. "\n")
        value, err = duplicate:unlink():await()
        assert(value == nil and err and err.code == "exit_failed" and err.effect == "completed")
        must(duplicate:unlink({ kill_if_last = true }):await())
        value, err = duplicate:select():await()
        assert(value == nil and err and err.code == "stale_target")
    elseif mode == "link_placement" then
        local original = created.window_link
        assert(type(original.move) == "function", "WindowLink move API is missing")
        local anchor = must(session:new_window({ index = 5, argv = { "/bin/cat" } }):await())
        must(original:link({ link = anchor.window_link, position = "after" }):await())
        assert(field(sid .. ":6", "window_id") == wid .. "\n")
        must(original:move({ link = anchor.window_link, position = "before" }):await())
        assert(field(sid .. ":5", "window_id") == wid .. "\n")
        assert(field(sid .. ":6", "window_id") == anchor.window:reference().id .. "\n")
        local moved = link_at(5)
        local value, err = moved:link({ link = anchor.window_link, position = "after" }):await()
        assert(value == nil and err and err.code == "stale_target" and err.effect == "not_sent")
        value, err = moved:link({ session = session, index = 6 }):await()
        assert(value == nil and err and err.code == "exit_failed" and err.effect == "completed")
        local victim = link_at(6)
        must(moved:move({ link = victim, position = "at" }, { replace = true }):await())
        assert(field(sid .. ":6", "window_id") == wid .. "\n")
        assert(
            command({ "list-windows", "-t", sid, "-F", "#{window_id}" })
                == wid .. "\n" .. wid .. "\n"
        )
    elseif mode == "link_swap" then
        local second = must(session:new_window({ index = 5, argv = { "/bin/cat" } }):await())
        local third = must(session:new_window({ index = 9, argv = { "/bin/cat" } }):await())
        must(created.window_link:swap(second.window_link):await())
        assert(field(sid, "window_index") == "0\n")
        assert(field(sid .. ":0", "window_id") == second.window:reference().id .. "\n")
        local value, err = created.window_link:select():await()
        assert(value == nil and err and err.code == "stale_target")
        local current = link_at(0)
        must(current:swap(third.window_link, { select = true }):await())
        assert(field(sid, "window_index") == "9\n")
        assert(field(sid, "window_id") == second.window:reference().id .. "\n")
    elseif mode == "link_group" then
        local original = created.window_link
        assert(type(original.link) == "function", "WindowLink link API is missing")
        local group_id = command({
            "new-session",
            "-d",
            "-t",
            sid,
            "-s",
            "grouped",
            "-P",
            "-F",
            "#{session_id}",
        }):sub(1, -2)
        must(original:link({ session = session, index = 1 }):await())
        assert(field(group_id .. ":1", "window_id") == wid .. "\n")
        local grouped = link_at(0, group_id)
        local value, err = original:link({ link = grouped, position = "after" }):await()
        assert(value == nil and err and err.code == "exit_failed" and err.effect == "completed")
        assert(field(sid .. ":0", "window_id") == wid .. "\n")
        assert(field(group_id .. ":0", "window_id") == wid .. "\n")
        assert(command({ "list-windows", "-t", group_id, "-F", "#{window_index}" }) == "0\n2\n")
        assert(command({ "list-windows", "-t", sid, "-F", "#{window_index}" }) == "0\n1\n")
        must(link_at(1):unlink():await())
        assert(command({ "list-windows", "-t", group_id, "-F", "#{window_id}" }) == wid .. "\n")
    elseif mode == "link_cross_session" then
        local other =
            must(server:new_session({ name = "destination", argv = { "/bin/cat" } }):await())
        local other_id = other.session:reference().id
        must(created.window_link:swap(other.window_link, { select = true }):await())
        assert(field(sid, "window_id") == other.window:reference().id .. "\n")
        assert(field(other_id, "window_id") == wid .. "\n")
        local moved = link_at(0, other_id)
        must(moved:move({ session = session, index = 9 }):await())
        assert(field(sid .. ":9", "window_id") == wid .. "\n")
        assert(must(server:command({ "has-session", "-t", other_id }):await()).exit_code ~= 0)
        must(link_at(9):link({ session = session }):await())
        assert(field(sid .. ":1", "window_id") == wid .. "\n")
    elseif mode == "window_respawn" then
        must(pane:split({ argv = { "/bin/cat" } }):await())
        local destination =
            must(server:new_session({ name = "respawn-target", argv = { "/bin/cat" } }):await())
        local target_sid = destination.session:reference().id
        must(session:set_environment("SCOPE", "source"):await())
        must(destination.session:set_environment("SCOPE", "target"):await())
        must(created.window_link:link({ session = destination.session, index = 5 }):await())
        local context = link_at(5, target_sid)
        local value, err = window:respawn({ context = context }):await()
        assert(value == nil and err and err.code == "exit_failed" and err.effect == "completed")
        assert(field(wid, "window_panes") == "2\n")
        must(window
            :respawn({
                context = context,
                kill = true,
                cwd = assert(os.getenv("LIBTMUX_TEST_DIRECTORY")),
                environment = { VALUE = "literal#{pid};" },
                argv = {
                    assert(os.getenv("LIBTMUX_TEST_PYTHON")),
                    assert(os.getenv("LIBTMUX_RESPAWN_SCRIPT")),
                    assert(os.getenv("TMUX_BIN")),
                    assert(os.getenv("TMUX_SOCKET")),
                    assert(os.getenv("LIBTMUX_RESPAWN_REPORT")),
                    'literal;$#{}\\"',
                    "",
                },
            })
            :await())
        command({ "wait-for", "window-ready" })
        assert(field(wid, "window_panes") == "1\n")
        assert(field(wid, "pane_id") == pid .. "\n")
        assert(field(target_sid .. ":5", "window_id") == wid .. "\n")
        assert(field(sid .. ":0", "window_id") == wid .. "\n")
        assert(field(pid, "pane_current_path") == os.getenv("LIBTMUX_TEST_DIRECTORY") .. "\n")
    elseif mode == "window_respawn_stale" then
        local value, err = window:respawn({ kill = true }):await()
        assert(value == nil and err and err.code == "invalid_target" and err.effect == "not_sent")
        value, err = window
            :respawn({
                context = created.window_link,
                kill = true,
                cwd = "/libtmux-lua-missing-directory",
            })
            :await()
        assert(
            value == nil and err and err.code == "invalid_directory" and err.effect == "not_sent"
        )
        local other = must(session:new_window({ index = 5, argv = { "/bin/cat" } }):await())
        must(created.window_link:swap(other.window_link):await())
        local old_pid = field(other.window:reference().id, "pane_pid")
        value, err = window:respawn({ context = created.window_link, kill = true }):await()
        assert(value == nil and err and err.code == "stale_target" and err.effect == "not_sent")
        assert(field(other.window:reference().id, "pane_pid") == old_pid)
        assert(field(sid .. ":5", "pane_id") == pid .. "\n")
    elseif mode == "pane_move" then
        local destination = must(session:new_window({ argv = { "/bin/cat" } }):await())
        local target_pid = destination.pane:reference().id
        must(created.window_link:link({ session = session, index = 9 }):await())
        must(
            pane:move_to(destination.pane, { direction = "horizontal", size = 20, before = true })
                :await()
        )
        assert(field(pid, "window_id") == destination.window:reference().id .. "\n")
        assert(field(pid, "pane_width") == "20\n")
        assert(field(pid, "pane_left") == "0\n")
        assert(field(destination.window:reference().id, "pane_id") == target_pid .. "\n")
        assert(
            command({ "list-windows", "-t", sid, "-F", "#{window_id}" })
                == destination.window:reference().id .. "\n"
        )
        assert(field(pid, "pane_id") == pid .. "\n")
    elseif mode == "pane_move_context" then
        local sibling = must(pane:split({ argv = { "/bin/cat" } }):await()).pane
        local destination =
            must(server:new_session({ name = "move-destination", argv = { "/bin/cat" } }):await())
        local target_sid = destination.session:reference().id
        must(destination.window_link:link({ session = destination.session, index = 5 }):await())
        local context = link_at(5, target_sid)
        must(
            pane:move_to(destination.pane, { target_link = context, select = true, percent = 30 })
                :await()
        )
        assert(field(target_sid, "window_index") == "5\n")
        assert(field(target_sid, "pane_id") == pid .. "\n")
        assert(field(wid, "pane_id") == sibling:reference().id .. "\n")
        local elsewhere = must(destination.session:new_window({ argv = { "/bin/cat" } }):await())
        must(destination.pane:move_to(elsewhere.pane):await())
        local value, err =
            sibling:move_to(destination.pane, { target_link = context, select = true }):await()
        assert(
            value == nil and err and err.code == "stale_target" and err.effect == "not_sent",
            tostring(value)
                .. " / "
                .. tostring(err)
                .. " / "
                .. tostring(err and err.partial and err.partial.stdout)
        )
        assert(field(sibling:reference().id, "window_id") == wid .. "\n")
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
