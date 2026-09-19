local host = rawget(_G, "vim")
local adapter = require(host and "libtmux.runtime.nvim" or "libtmux.runtime.luv")

local function work(runtime)
    local server = assert(runtime
        :connect({
            binary = assert(os.getenv("TMUX_BIN")),
            socket_path = assert(os.getenv("TMUX_SOCKET")),
            config_path = "/dev/null",
        })
        :await())
    local missing, err = server:command({ "has-session", "-t", "missing" }):await()
    assert(missing and not err and missing.exit_code ~= 0 and missing.signal == 0)
    assert(type(missing.stdout) == "string" and #missing.stderr > 0)
    local success = assert(server:command({ "display-message", "-p", "literal;" }):await())
    assert(success.stdout == "literal;\n" and success.exit_code == 0)
    local incomplete
    incomplete, err = server
        :command({ "display-message", "-p", "too long" }, { max_output_bytes = 1 })
        :await()
    assert(not incomplete and err and err.code == "output_limit")
    local grouped = assert(server
        :group({
            { "set-option", "-g", "@execution_first", "yes" },
            { "has-session", "-t", "missing" },
            { "set-option", "-g", "@execution_skipped", "no" },
        })
        :await())
    assert(grouped.exit_code ~= 0 and grouped.members == nil)
    local first = assert(server:command({ "show-options", "-g", "-v", "@execution_first" }):await())
    assert(first.stdout == "yes\n")
    local skipped = assert(server:command({ "show-options", "-g" }):await())
    assert(not skipped.stdout:find("@execution_skipped ", 1, true))
    local outcomes = assert(server
        :batch({
            { "has-session", "-t", "missing" },
            { "display-message", "-p", "after failure" },
        }, { concurrency = 2 })
        :await())
    assert(outcomes[1].status == "failed" and outcomes[1].error.partial.exit_code ~= 0)
    assert(outcomes[2].status == "completed" and outcomes[2].value.stdout == "after failure\n")
    assert(server:close():await())
    return "public execution passed"
end

if host then
    adapter.start(work, function(value, err)
        if not value then
            io.stderr:write(tostring(err), "\n")
            host.cmd("cquit 1")
        else
            io.stdout:write(value, "\n")
            host.cmd("qa!")
        end
    end, { max_active = 1 })
else
    local value, err = adapter.run(work, { max_active = 1 })
    assert(value, tostring(err))
    print(value)
end
