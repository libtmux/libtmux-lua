local host = rawget(_G, "vim")
local adapter = require(host and "libtmux.runtime.nvim" or "libtmux.runtime.luv")
local mode = assert(os.getenv("LIBTMUX_BUFFER_CASE"))

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
    local name = "-buffer #{pid};λ;"
    if mode == "storage" then
        local pieces = {}
        for byte = 0, 255 do
            pieces[#pieces + 1] = string.char(byte)
        end
        local bytes = table.concat(pieces) .. "\000tail\n\n"
        must(server:set_buffer(name, bytes):await())
        local shown = must(server:show_buffer(name):await())
        assert(shown.name == name and shown.bytes == bytes)
        local value, err = shown:text()
        assert(value == nil and err and err.code == "invalid_utf8" and err.effect == "completed")
        shown.name, shown.bytes = "changed", "changed"
        assert(must(server:show_buffer(name):await()).bytes == bytes)
        value, err = server:set_buffer(name, ""):await()
        assert(value == nil and err and err.code == "invalid_argument" and err.effect == "not_sent")
        assert(must(server:show_buffer(name):await()).bytes == bytes)
        must(server:set_buffer(name, "UTF8 λ雪\000\n"):await())
        assert(must(must(server:show_buffer(name):await()):text()) == "UTF8 λ雪\000\n")
        value, err = server:show_buffer(name, { process = { max_output_bytes = 2 } }):await()
        assert(value == nil and err and err.code == "output_limit")
        must(server:delete_buffer(name):await())
        value, err = server:show_buffer(name):await()
        assert(value == nil and err and err.code == "exit_failed" and err.effect == "completed")
        value, err = server:set_buffer("bad\\name", "value"):await()
        assert(value == nil and err and err.code == "unsupported_name" and err.effect == "not_sent")
    else
        local created =
            must(server:new_session({ name = "buffer-paste", argv = { "/bin/cat" } }):await())
        local pane, pid = created.pane, created.pane:reference().id
        local payload = "A\000\001\027\127\255\nBENDMARK"
        must(server:set_buffer(name, payload):await())
        if mode == "disabled" then
            must(server:command({ "select-pane", "-t", pid, "-d" }):await())
            must(pane:paste_buffer(name, { delete_after = true }):await())
            local value, err = server:show_buffer(name):await()
            assert(value == nil and err and err.code == "exit_failed")
        else
            local observation = must(server:observe(created.session):await())
            local watch = must(observation:watch_pane(pane):await())
            must(pane:respawn({
                kill = true,
                argv = {
                    assert(os.getenv("LIBTMUX_TEST_PYTHON")),
                    assert(os.getenv("LIBTMUX_BUFFER_SCRIPT")),
                    assert(os.getenv("TMUX_BIN")),
                    assert(os.getenv("TMUX_SOCKET")),
                    assert(os.getenv("LIBTMUX_BUFFER_REPORT")),
                    mode,
                },
            }):await())
            local ready = ""
            repeat
                ready = ready .. must(watch:next({ timeout = 750 }):await()).data
            until ready:find("BUFFER_READY", 1, true)
            local options = {}
            if mode == "raw" or mode == "bracket" then
                options.bytes, options.linefeed_separator = "raw", true
                options.bracket = mode == "bracket"
            elseif mode == "separator" then
                options.separator = "|"
            else
                assert(mode == "native")
            end
            must(pane:paste_buffer(name, options):await())
            must(server:command({ "wait-for", "buffer-read" }):await())
            assert(must(server:show_buffer(name):await()).bytes == payload)
            must(watch:close():await())
            must(observation:close():await())
        end
    end
    must(server:close():await())
    return "public buffer " .. mode .. " PASS"
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
