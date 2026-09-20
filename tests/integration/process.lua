local process = require("libtmux._internal.process")
local host = rawget(_G, "vim")
local python = assert(os.getenv("LIBTMUX_PYTHON"))
local mode = assert(os.getenv("LIBTMUX_PROCESS_CASE"))
local module = require(host and "libtmux.runtime.nvim" or "libtmux.runtime.luv")

local function command(runtime, argv, options)
    local value, err = process.execute(runtime, argv, options):await()
    assert(value, tostring(err))
    return value
end

local function work(runtime)
    if mode == "bytes" then
        local argv = {
            python,
            "-c",
            "import os,sys;os.write(1,b'|'.join(os.fsencode(a) for a in sys.argv[1:]))",
            "",
            "quote'\"",
            "slash\\",
            "semi;",
            "$literal",
            "line\nreturn\r",
            "\255",
        }
        local result = command(runtime, argv)
        assert(result.stdout == "|quote'\"|slash\\|semi;|$literal|line\nreturn\r|\255")
        result = command(
            runtime,
            { python, "-c", "import os;os.write(1,os.read(0,100));os.write(2,b'err\\x00\\xff')" },
            { stdin = "in\000\255" }
        )
        assert(result.stdout == "in\000\255" and result.stderr == "err\000\255")
        local value, err = process
            .execute(runtime, { python, "-c", "import os;os.write(1,b'partial');os._exit(17)" })
            :await()
        assert(value == nil and err.code == "exit_failed" and err.partial.exit_code == 17)
        assert(err.partial.stdout == "partial" and err.effect == "completed")
        value, err = process.execute(runtime, { "/libtmux-lua-missing-executable" }):await()
        assert(value == nil and err.code == "spawn_failed" and err.effect == "not_sent")
        return "bytes passed"
    elseif mode == "tmux" then
        local binary, socket = assert(os.getenv("TMUX_BIN")), assert(os.getenv("TMUX_SOCKET"))
        local function argv(...)
            return { binary, "-f", "/dev/null", "-S", socket, ... }
        end
        local req = process.execute(runtime, argv("wait-for", "libtmux-process-held"))
        local progress = command(runtime, argv("display-message", "-p", "#{socket_path}"))
        assert(progress.stdout == socket .. "\n" and not req:is_settled())
        req:cancel()
        local value, err = req:await()
        assert(value == nil and err.code == "cancelled" and err.effect == "unknown")
        assert(command(runtime, argv("has-session", "-t", "fixture")).exit_code == 0)
        -- tmux owns its command parser even when the operating-system argv is literal.
        assert(command(runtime, argv("display-message", "-p", "literal;")).stdout == "literal\n")
        return "tmux passed"
    elseif mode == "drain" then
        local value, err = process
            .execute(
                runtime,
                { python, "-c", assert(os.getenv("LIBTMUX_DESCENDANT_CODE")) },
                { drain_timeout = 20 }
            )
            :await()
        assert(value == nil and err.code == "drain_timeout" and err.effect == "completed")
        assert(err.partial.stdout:match("^%d+\n$"))
        return "descendant " .. err.partial.stdout
    end
    error("unknown integration case")
end

if host then
    module.start(work, function(value, err)
        if err then
            io.stderr:write(tostring(err), "\n")
            host.cmd("cquit 1")
        else
            io.stdout:write(value, "\n")
            host.cmd("qa!")
        end
    end)
else
    local value, err = module.run(work)
    assert(value, tostring(err))
    io.stdout:write(value, "\n")
end
