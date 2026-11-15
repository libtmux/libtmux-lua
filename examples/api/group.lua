local adapter = require("libtmux.runtime.luv")

local function must(value, err)
    if err ~= nil then
        error(tostring(err), 0)
    end
    return value
end

-- tmux is /usr/bin/tmux unless TMUX_BIN names another absolute path.
local binary = os.getenv("TMUX_BIN") or "/usr/bin/tmux"

must(adapter.run(function(runtime)
    local owned = must(runtime:start_server({ binary = binary }):await())
    -- One tmux process runs all four commands, in order.
    local done = must(owned.server
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

    must(owned:stop():await())
    return true
end))
