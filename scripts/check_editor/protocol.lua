-- JSON-RPC over a language server's standard streams: Content-Length framing, with a reader that
-- keeps the bytes of a partial message until the rest arrives.
local json = require("support.json")

local M = {}

M.MAX_BYTES = 16 * 1024 * 1024

--- A message framed for the wire.
---@param message table
---@return string
function M.frame(message)
    local data = json.encode(message)
    return "Content-Length: " .. #data .. "\r\n\r\n" .. data
end

--- Takes one complete message off the front of `buffer`. Returns the message and the rest of the
--- buffer, or nil and the buffer unchanged when a message is still incomplete.
---@param buffer string
---@return table? message
---@return string rest
function M.take(buffer)
    local header_end = buffer:find("\r\n\r\n", 1, true)
    if not header_end then
        return nil, buffer
    end
    local size
    for line in buffer:sub(1, header_end - 1):gmatch("[^\r\n]+") do
        local value = line:match("^[Cc]ontent%-[Ll]ength:%s*(%d+)")
        size = size or tonumber(value)
    end
    if not size then
        error("language-server message without a Content-Length", 0)
    end
    if size > M.MAX_BYTES then
        error("oversized language-server response", 0)
    end
    local body_start = header_end + 4
    if #buffer < body_start + size - 1 then
        return nil, buffer
    end
    return json.decode(buffer:sub(body_start, body_start + size - 1)), buffer:sub(body_start + size)
end

return M
