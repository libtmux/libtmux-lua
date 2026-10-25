local host = rawget(_G, "vim")
local adapter = require(host and "libtmux.runtime.nvim" or "libtmux.runtime.luv")

local function must(value, err)
    if err then
        error(err, 0)
    end
    return value
end

---@diagnostic disable-next-line: different-requires
local uv = host and (host.uv or host.loop) or require("luv")

local function now()
    return uv.hrtime() / 1e6
end

local function describe(err)
    return err and (tostring(err.code) .. ": " .. tostring(err.message)) or "no error"
end

local function work(runtime)
    local binary, socket = assert(os.getenv("TMUX_BIN")), assert(os.getenv("TMUX_SOCKET"))
    local dir = assert(os.getenv("LIBTMUX_WAIT_DIR"))
    local case = assert(os.getenv("LIBTMUX_WAIT_CASE"))
    local server = must(runtime:connect({ binary = binary, socket_path = socket }):await())

    local function command(args)
        local result = must(server:command(args):await())
        assert(result.exit_code == 0, result.stderr)
        return result.stdout
    end
    local function sleep(seconds)
        command({ "run-shell", "-d", tostring(seconds) })
    end
    local function program(script, width)
        local created = must(server
            :new_session({
                name = "wait-" .. case,
                width = width or 80,
                height = 24,
                argv = { "/bin/sh", "-c", script, binary, socket },
            })
            :await())
        return created.pane, assert(created.pane:reference()).id
    end
    -- Wait until the pane shows text, without using the method under test.
    local function settle(id, text)
        for _ = 1, 200 do
            if command({ "capture-pane", "-p", "-J", "-t", id }):find(text, 1, true) then
                return
            end
            sleep(0.05)
        end
        error("pane never showed " .. text, 0)
    end
    -- Each capture-pane runs the hook; the first read of a wait wakes `read`.
    local function signal_reads()
        command({ "set-hook", "-g", "after-capture-pane", "wait-for -S read" })
    end
    local function count_hooks(names)
        for _, name in ipairs(names) do
            command({
                "set-hook",
                "-g",
                "after-" .. name,
                'run-shell -b "printf x >> ' .. dir .. "/" .. name .. '"',
            })
        end
    end
    local function expect_error(request, code)
        local value, err = request:await()
        assert(value == nil and err and err.code == code, describe(err))
        return err
    end
    must(server:new_session({ name = "keepalive", argv = { "/bin/cat" } }):await())

    if case == "late" then
        local pane = program("exec cat")
        signal_reads()
        local request = pane:wait_for_text("LATE" .. "NEEDLE", { interval = 20, timeout = 5000 })
        command({ "wait-for", "read" })
        must(pane:send_text("LATE" .. "NEEDLE"):await())
        local found = must(request:await())
        assert(found.matched_at_entry == false, "needle was not on screen at entry")
        assert(found.text:find("LATENEEDLE", 1, true))
    elseif case == "entry" then
        local pane, id = program("printf ALREADY; exec cat")
        settle(id, "ALREADY")
        count_hooks({ "capture-pane" })
        local started = now()
        local found =
            must(pane:wait_for_text("ALREADY", { interval = 60000, timeout = 3000 }):await())
        assert(found.matched_at_entry == true)
        assert(now() - started < 1000, "first read waited for the interval")
    elseif case == "wrapped" then
        local pane, id = program("printf '%078d' 0; printf NEEDLE; exec cat")
        settle(id, "NEEDLE")
        local found = must(pane:wait_for_text("NEEDLE", { timeout = 3000 }):await())
        assert(found.matched_at_entry == true)
        assert(command({ "capture-pane", "-p", "-t", id }):find("NEEDLE", 1, true) == nil)
    elseif case == "pane_killed" then
        local pane, id = program("printf EARLIER; exec cat")
        settle(id, "EARLIER")
        signal_reads()
        local started = now()
        local request = pane:wait_for_text("NEVER", { interval = 20, timeout = 8000 })
        command({ "wait-for", "read" })
        command({ "kill-pane", "-t", id })
        local err = expect_error(request, "pane_died")
        assert(err.reason == "pane_gone", tostring(err.reason))
        assert(err.partial and err.partial.text:find("EARLIER", 1, true))
        assert(now() - started < 3000, "pane death waited for the deadline")
    elseif case == "remain_on_exit" then
        command({ "set-option", "-g", "remain-on-exit", "on" })
        local pane, id = program('printf BYE; "$0" -S "$1" wait-for release; exit 0')
        settle(id, "BYE")
        signal_reads()
        local started = now()
        local request = pane:wait_for_text("NEVER", { interval = 20, timeout = 8000 })
        command({ "wait-for", "read" })
        assert(command({ "display-message", "-p", "-t", id, "#{pane_dead}" }) == "0\n")
        command({ "wait-for", "-S", "release" })
        local err = expect_error(request, "pane_died")
        assert(err.reason == "pane_exited", tostring(err.reason))
        assert(err.partial and type(err.partial.text) == "string")
        assert(now() - started < 3000, "dead pane waited for the deadline")
    elseif case == "server_killed" or case == "server_killed_stopped" then
        local pane, id = program("printf EARLIER; exec cat")
        settle(id, "EARLIER")
        signal_reads()
        local request = pane:wait_for_text("NEVER", { interval = 20, timeout = 20000 })
        command({ "wait-for", "read" })
        io.stdout:write("READY\n")
        io.stdout:flush()
        if case == "server_killed" then
            local _ = server:command({ "kill-server" }):await()
        else
            local deadline = now() + 15000
            -- The harness kills the server once the wait is polling.
            while now() < deadline and not io.open(dir .. "/killed", "r") do
                local ok = pcall(sleep, 0.05)
                if not ok then
                    break
                end
            end
        end
        local started = now()
        local err = expect_error(request, "pane_died")
        assert(err.reason == "server_gone", tostring(err.reason))
        assert(err.partial and err.partial.text:find("EARLIER", 1, true))
        assert(now() - started < 3000, "server death waited for the deadline")
    elseif case == "cancel" or case == "cancel_inflight" or case == "deadline_inflight" then
        local pane, id = program("printf EARLIER; exec cat")
        settle(id, "EARLIER")
        signal_reads()
        local started = now()
        local options = { interval = 5000 }
        if case == "deadline_inflight" then
            options = { interval = 20, timeout = 600 }
        elseif case == "cancel_inflight" then
            options = { interval = 20 }
        end
        local request = pane:wait_for_text("NEVER", options)
        command({ "wait-for", "read" })
        if case ~= "cancel" then
            -- From here every read blocks inside the capture-pane hook.
            command({
                "set-hook",
                "-g",
                "after-capture-pane",
                "wait-for blocker",
            })
        end
        if case == "deadline_inflight" then
            local err = expect_error(request, "deadline_exceeded")
            assert(err.partial and err.partial.text:find("EARLIER", 1, true))
            assert(now() - started < 3000, "deadline waited for the read")
        else
            sleep(0.05)
            assert(request:cancel("stop"))
            local err = expect_error(request, "cancelled")
            assert(err.partial and err.partial.text:find("EARLIER", 1, true))
            assert(now() - started < 1000, "cancel waited for the interval")
        end
    elseif case == "history" or case == "history_under" then
        command({ "set-option", "-g", "history-limit", "50000" })
        local rows = case == "history" and 20000 or 5000
        local pane, id = program(
            "yes 'row xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' "
                .. "| head -n "
                .. rows
                .. "; printf VISIBLE; exec cat"
        )
        settle(id, "VISIBLE")
        local found = must(pane:wait_for_text("VISIBLE", { timeout = 5000 }):await())
        assert(found.matched_at_entry == true)
    elseif case == "hooks" then
        local pane, id = program("printf EARLIER; exec cat")
        settle(id, "EARLIER")
        count_hooks({ "display-message", "list-panes", "show-options", "capture-pane" })
        local err = expect_error(
            pane:wait_for_text("NEVER", { interval = 30, timeout = 500 }),
            "deadline_exceeded"
        )
        assert(err.partial and err.partial.text:find("EARLIER", 1, true))
    elseif case == "matcher_first" then
        local pane, id = program("printf FOUND; exec cat")
        settle(id, "FOUND")
        command({ "set-hook", "-g", "after-capture-pane", "kill-pane -t " .. id })
        local found = must(pane:wait_for_text("FOUND", { timeout = 3000 }):await())
        assert(found.matched_at_entry == true)
    elseif case == "hook_output" then
        local pane = program("exec cat")
        command({ "set-hook", "-g", "after-capture-pane", "run-shell 'printf HOOK''OUT'" })
        local found = must(pane:wait_for_text("HOOK" .. "OUT", { timeout = 3000 }):await())
        assert(found.text:find("HOOKOUT", 1, true))
        command({ "set-hook", "-gu", "after-capture-pane" })
    elseif case == "typed_echo" then
        local pane, id = program("exec cat")
        settle(id, "") -- screen exists
        must(pane:send_text("printf '%s' ECHO" .. "NEEDLE"):await())
        local found = must(pane:wait_for_text("ECHO" .. "NEEDLE", { timeout = 3000 }):await())
        assert(found.text:find("ECHONEEDLE", 1, true))
    elseif case == "validation" then
        local pane, id = program("printf VALID; exec cat")
        settle(id, "VALID")
        local bad = {
            { "", {} },
            { 5, {} },
            { "x", "options" },
            { "x", { unknown = 1 } },
            { "x", { interval = 0 } },
            { "x", { interval = 0.5 } },
            { "x", { interval = "10" } },
            { "x", { interval = 0 / 0 } },
            { "x", { timeout = -1 } },
            { "x", { timeout = "1" } },
            { "x", { deadline = math.huge } },
            { "x", { deadline = "soon" } },
            { "x", { timeout = 2147483648 } },
            { "x", { deadline = 1e15 } },
            { "x", setmetatable({}, {}) },
        }
        for index, item in ipairs(bad) do
            local value, err = pane:wait_for_text(item[1], item[2]):await()
            assert(
                value == nil and err and err.code == "invalid_argument",
                index .. ": " .. describe(err)
            )
        end
        -- A valid call with the same shape succeeds.
        local found = must(pane:wait_for_text("VALID", { interval = 5 }):await())
        assert(found.matched_at_entry == true)
    elseif case == "close" then
        local pane, id = program("printf EARLIER; exec cat")
        settle(id, "EARLIER")
        signal_reads()
        pane:wait_for_text("NEVER", { interval = 5000 })
        command({ "wait-for", "read" })
        -- Let the first read finish, so the wait is paused when the runtime closes.
        sleep(0.3)
        runtime:close("test over")
        error("runtime close returned to the closed task", 0)
    else
        error("unknown case " .. case, 0)
    end
    if case ~= "server_killed" and case ~= "server_killed_stopped" then
        must(server:close():await())
    end
    return "wait text PASS " .. case
end

local timers = {}
if host then
    local new_timer = uv.new_timer
    uv.new_timer = function(...)
        local timer, err = new_timer(...)
        timers[#timers + 1] = timer
        return timer, err
    end
    adapter.start(work, function(value, err)
        if err and os.getenv("LIBTMUX_WAIT_CASE") == "close" and err.code == "cancelled" then
            -- Neovim quits from this callback whatever handles remain, so
            -- check every timer the runtime created.
            local live = 0
            for _, timer in ipairs(timers) do
                local ok, active = pcall(timer.is_active, timer)
                if ok and active then
                    live = live + 1
                end
            end
            if live > 0 then
                io.stderr:write("runtime close left " .. live .. " live timers\n")
                host.cmd("cquit 1")
            end
            io.stdout:write("wait text PASS close\n")
            host.cmd("qa!")
        elseif err then
            io.stderr:write(describe(err), "\n")
            host.cmd("cquit 1")
        else
            io.stdout:write(value, "\n")
            host.cmd("qa!")
        end
    end, {})
else
    local value, err = adapter.run(work, {})
    if err and os.getenv("LIBTMUX_WAIT_CASE") == "close" and err.code == "cancelled" then
        value, err = "wait text PASS close", nil
    end
    if err then
        io.stderr:write(describe(err), "\n")
        os.exit(1)
    end
    print(value)
end
