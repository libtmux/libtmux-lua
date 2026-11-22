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
    local server = owned.server
    local where = { active = true, current_command = "cat" }
    for _, mode in ipairs({ "never", "auto" }) do
        -- Explaining sends nothing to tmux.
        local query = { where = where, pushdown = mode }
        local plan = must(server:explain_panes(query):await())
        local count = #plan.commands .. " tmux commands"
        local filter = plan.filter or "none"
        print(mode .. ": " .. count .. ", filter " .. filter)
        for _, left in ipairs(plan.residual) do
            print("  local: " .. left.path .. " (" .. left.reason .. ")")
        end
    end

    must(owned:stop():await())
    return true
end))
