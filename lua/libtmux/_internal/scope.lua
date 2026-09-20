local identity = require("libtmux._internal.identity")
local errors = require("libtmux._internal.error")
local M = {}
local native_scopes = {
    server = "server",
    session = "session",
    window = "window",
    pane = "pane",
    global_session = "session",
    global_window = "window",
}

local function failure(code, message)
    return nil, errors.new(code, message, { operation = "settings", effect = "not_sent" })
end

function M.resolve(state, owned, requested, family)
    if state.closed then
        return failure("closed", "server handle is closed")
    end
    local generation, err = state.bound:generation()
    if not generation then
        return nil, err
    end
    local ref
    if owned then
        ref, err = identity.inspect(generation, owned)
        if not ref then
            return nil, err
        end
    else
        ref = { kind = "server", generation = generation }
    end
    local selected, flags
    if ref.kind == "server" then
        if family == "environment" and (requested == nil or requested == "global") then
            selected, flags = "global", { "-g" }
        elseif family == "option" or family == "hook" then
            selected = requested or (family == "option" and "server" or nil)
            if selected == "server" and family == "option" then
                flags = { "-s" }
            elseif selected == "global_session" then
                flags = { "-g" }
            elseif selected == "global_window" then
                flags = { "-g", "-w" }
            end
        end
    elseif requested == nil or requested == ref.kind then
        selected = ref.kind
        if family == "environment" and selected == "session" then
            flags = { "-t", ref.id }
        elseif family == "option" or family == "hook" then
            if selected == "session" then
                flags = { "-t", ref.id }
            elseif selected == "window" then
                flags = { "-w", "-t", ref.id }
            elseif selected == "pane" then
                flags = { "-p", "-t", ref.id }
            end
        end
    end
    if not flags then
        return failure("invalid_scope", "settings scope is unavailable on this handle")
    end
    return { scope = selected, flags = flags, target = ref }
end

function M.check_option(resolved, definition)
    local required = native_scopes[resolved.scope]
    for _, accepted in ipairs(definition.scopes) do
        if required == accepted then
            return true
        end
    end
    return failure("invalid_scope", "option is not defined in the requested scope")
end

return M
