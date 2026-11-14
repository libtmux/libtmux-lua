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
    -- One tmux process runs all four commands, in order.
    local done = must(server
        :group({
            { "new-session", "-d", "-s", "demo", "-n", "main", "/bin/cat" },
            { "new-window", "-d", "-t", "demo:", "-n", "build", "/bin/cat" },
            { "new-window", "-d", "-t", "demo:", "-n", "test", "/bin/cat" },
            { "list-windows", "-t", "demo", "-F", "#{window_name}" },
        })
        :await())
    assert(done.exit_code == 0, "the group failed")
    local names = {}
    for name in done.stdout:gmatch("[^\n]+") do
        names[#names + 1] = name
    end
    assert(#names == 3, "the group did not create three windows")
    print("windows: " .. table.concat(names, ", "))

    must(server:close():await())
    return true
end))
