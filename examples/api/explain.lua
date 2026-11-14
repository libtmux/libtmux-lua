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
    local where = { active = true, current_command = "cat" }
    for _, mode in ipairs({ "never", "auto" }) do
        -- Explaining sends nothing to tmux.
        local plan = must(server:explain_panes({ where = where, pushdown = mode }):await())
        local filter = plan.filter or "none"
        print(mode .. ": " .. #plan.commands .. " tmux commands, filter " .. filter)
        for _, left in ipairs(plan.residual) do
            print("  local: " .. left.path .. " (" .. left.reason .. ")")
        end
    end

    must(server:close():await())
    return true
end))
