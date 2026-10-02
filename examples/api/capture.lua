local adapter = require("libtmux.runtime.luv")

local function must(value, err)
    if err ~= nil then
        error(tostring(err), 0)
    end
    return value
end

local binary = assert(os.getenv("TMUX_BIN"), "set TMUX_BIN to an absolute tmux executable")
local socket = assert(os.getenv("TMUX_SOCKET"), "set TMUX_SOCKET to the private socket")

must(adapter.run(function(runtime)
    local server = must(runtime:connect({ binary = binary, socket_path = socket }):await())
    local created = must(server:new_session({ name = "demo", argv = { "/bin/sh" } }):await())
    local pane = created.pane
    local function quote(text)
        return "'" .. text:gsub("'", "'\\''") .. "'"
    end

    -- Signal completion on this socket; do not guess when the shell has printed.
    local command = "printf '\\nlua capture ready\\n'; "
        .. quote(binary)
        .. " -S "
        .. quote(socket)
        .. " wait-for -S example-ready"
    must(pane:send_text(command):await())
    must(pane:send_keys({ "Enter" }):await())
    must(server:command({ "wait-for", "example-ready" }, { timeout = 1000 }):await())
    local capture = must(pane:capture({ history_lines = 20 }):await())
    local found = false
    for line in must(capture:text()):gmatch("[^\r\n]+") do
        if line == "lua capture ready" then
            found = true
        end
    end
    assert(found, "completed command did not print the expected line")
    print("lua capture ready")

    must(server:close():await())
    return true
end))
