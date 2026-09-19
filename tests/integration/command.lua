local command = require("libtmux._internal.command")
local host = rawget(_G, "vim")
local mode = assert(os.getenv("LIBTMUX_COMMAND_CASE"))
local endpoint = {
    binary = assert(os.getenv("TMUX_BIN")),
    socket = assert(os.getenv("TMUX_SOCKET")),
    config = "/dev/null",
}
local adapter = require(host and "libtmux.runtime.nvim" or "libtmux.runtime.luv")

local function execute(runtime, argv)
    local result, err = command.execute(runtime, endpoint, argv):await()
    assert(result, tostring(err))
    return result
end

local function absent(runtime, option)
    local result = execute(runtime, { "show-options", "-g" })
    assert(not result.stdout:find(option .. " ", 1, true))
end

local function work(runtime)
    if mode == "literal" then
        execute(runtime, { "set-option", "-g", "@libtmux_empty", "" })
        assert(execute(runtime, { "show-options", "-g", "-v", "@libtmux_empty" }).stdout == "\n")
        for _, value in ipairs({
            "\"quote'",
            "back\\slash\\",
            "line\nreturn\r",
            "\255",
            "λ雪",
            "$HOME ~ #{pane_id}",
            ";",
            "tail;",
            "tail\\;",
            "tail;;",
        }) do
            execute(runtime, { "set-buffer", "-b", "libtmux-command", value })
            assert(execute(runtime, { "show-buffer", "-b", "libtmux-command" }).stdout == value)
        end
        local value, err = command.execute(runtime, endpoint, { "-V" }):await()
        assert(value == nil and err.code == "exit_failed")
    elseif mode == "group" then
        local result, err = command
            .group(runtime, endpoint, {
                { "set-option", "-g", "@libtmux_group", "literal;" },
                { "display-message", "-p", "#{@libtmux_group}" },
            })
            :await()
        assert(result and result.stdout == "literal;\n", tostring(err))
        assert(result.members == nil and result.outcomes == nil)
        result, err = command
            .group(runtime, endpoint, {
                { "set-option", "-g", "@libtmux_before", "yes" },
                { "has-session", "-t", "libtmux-missing-session" },
                { "set-option", "-g", "@libtmux_after", "yes" },
            })
            :await()
        assert(result == nil and err.code == "exit_failed" and err.effect == "completed")
        assert(err.partial.members == nil and err.partial.outcomes == nil)
        assert(
            execute(runtime, { "show-options", "-g", "-v", "@libtmux_before" }).stdout == "yes\n"
        )
        absent(runtime, "@libtmux_after")
        result, err = command
            .group(runtime, endpoint, {
                { "set-option", "-g", "@libtmux_parse", "yes" },
                { "libtmux-unknown-command" },
            })
            :await()
        assert(result == nil and err.code == "exit_failed")
        absent(runtime, "@libtmux_parse")
        result, err = command
            .group(runtime, endpoint, {
                { "set-option", "-g", "@libtmux_invalid", "yes" },
                { "display-message", "nul\000" },
            })
            :await()
        assert(result == nil and err.code == "invalid_command" and err.effect == "not_sent")
        absent(runtime, "@libtmux_invalid")
    elseif mode == "wait" then
        local request = command.group(runtime, endpoint, {
            { "run-shell", "-t", "fixture:0.0", assert(os.getenv("LIBTMUX_WAIT_SHELL")) },
            { "set-option", "-g", "@libtmux_wait_continued", "yes" },
            { "display-message", "-p", "WAIT_CONTINUED" },
        })
        execute(runtime, { "wait-for", "libtmux-command-ready" })
        assert(not request:is_settled(), "WAIT request settled before release")
        execute(runtime, { "wait-for", "-S", "libtmux-command-release" })
        local result, err = request:await()
        assert(result == nil and err.code == "exit_failed" and err.partial.exit_code == 7)
        assert(err.partial.stdout == "WAIT_CONTINUED\n" and err.partial.stderr == "")
        assert(
            execute(runtime, { "show-options", "-g", "-v", "@libtmux_wait_continued" }).stdout
                == "yes\n"
        )
    else
        error("unknown command integration case")
    end
    return mode .. " passed"
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
