local query = require("libtmux.query")

local schema = {
    fields = {
        id = { type = "string" },
        active = { type = "boolean" },
        current_command = { type = "string" },
    },
}
local rows = {
    { id = "%1", active = true, current_command = "nvim" },
    { id = "%2", active = false, current_command = "sh" },
    { id = "%3", active = false, current_command = "vim" },
}
local panes = query.select(rows, schema)
local editors = panes:where({ current_command = { one_of = { "nvim", "vim" } } })
assert(#editors == 2 and editors[1] == rows[1] and editors[2] == rows[3])

local inactive = panes:filter(function(pane)
    return not pane.active
end)
assert(#inactive == 2 and inactive[1].id == "%2")
for _, pane in ipairs(editors) do
    print(pane.id, pane.current_command)
end
