local M = {}
local mt = {
    __tostring = function(err)
        return err.message or err.code
    end,
}

function M.new(code, message, fields)
    local err = fields or {}
    err.code, err.message = code, message
    return setmetatable(err, mt)
end

function M.wrap(value, code)
    if type(value) == "table" and value.code then
        return value
    end
    return M.new(code, tostring(value), { cause = value })
end

return M
