local M = {}

local function open(path, mode)
    local handle, reason = io.open(path, mode)
    if not handle then
        error(reason, 0)
    end
    return handle
end

function M.read(path)
    local handle = open(path, "rb")
    local text = assert(handle:read("*a"))
    handle:close()
    return text
end

local function put(path, mode, text)
    local handle = open(path, mode)
    assert(handle:write(text))
    assert(handle:close())
end

function M.write(path, text)
    put(path, "wb", text)
end

function M.append(path, text)
    put(path, "ab", text)
end

return M
