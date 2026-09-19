local errors = require("libtmux._internal.error")
local M = {}
local Parser = {}
Parser.__index = Parser

-- tmux CONTROL MODE keeps notifications outside blocks. Its raw command output
-- can forge an exact closing guard; this parser cannot authenticate that boundary
-- or distinguish notification-shaped late command output from a notification.
-- Use controlled, encoded responses; arbitrary commands belong on the process lane.
local defaults = {
    max_input_bytes = 1048576,
    max_line_bytes = 65536,
    max_block_bytes = 1048576,
    max_block_lines = 65536,
    max_events = 1024,
    max_event_bytes = 2097152,
}

local notifications = {}
for name in
    string.gmatch(
        "client-detached client-session-changed config-error continue exit extended-output "
            .. "layout-change message output pane-mode-changed paste-buffer-changed "
            .. "paste-buffer-deleted pause session-changed session-renamed session-window-changed "
            .. "sessions-changed subscription-changed unlinked-window-add unlinked-window-close "
            .. "unlinked-window-renamed window-add window-close window-pane-changed window-renamed",
        "%S+"
    )
do
    notifications[name] = true
end

local function byte_cost(value)
    if type(value) == "string" then
        return #value
    end
    local size = 0
    if type(value) == "table" then
        for _, field in pairs(value) do
            size = size + byte_cost(field)
        end
    end
    return size
end

local function octal(value)
    if value:find("[%z\001-\031]") then
        return nil
    end
    local parts, start = {}, 1
    while true do
        local slash = value:find("\\", start, true)
        if not slash then
            parts[#parts + 1] = value:sub(start)
            return table.concat(parts)
        end
        local digits = value:sub(slash + 1, slash + 3)
        if not digits:match("^[0-3][0-7][0-7]$") then
            return nil
        end
        parts[#parts + 1] = value:sub(start, slash - 1)
        parts[#parts + 1] = string.char(tonumber(digits, 8))
        start = slash + 4
    end
end

local function notification(line, name, payload)
    local event = {
        kind = notifications[name] and "notification" or "unknown",
        name = name,
        payload = payload,
        raw = line,
    }
    if name == "output" then
        local pane, encoded = payload:match("^(%%[0-9]+) (.*)$")
        if not pane then
            return nil
        end
        event.pane, event.data = pane, octal(encoded)
        if not event.data then
            return nil
        end
    elseif name == "extended-output" then
        local pane, age, remainder = payload:match("^(%%[0-9]+) ([0-9]+) (.*)$")
        if not pane then
            return nil
        end
        local metadata, encoded
        if remainder:sub(1, 2) == ": " then
            metadata, encoded = "", remainder:sub(3)
        else
            local colon = remainder:find(" : ", 1, true)
            if not colon then
                return nil
            end
            metadata, encoded = remainder:sub(1, colon - 1), remainder:sub(colon + 3)
        end
        event.pane, event.age, event.metadata = pane, age, metadata
        event.data = octal(encoded)
        if not event.data then
            return nil
        end
    end
    return event
end

function M.new(options)
    options = options or {}
    if type(options) ~= "table" then
        return nil, errors.new("invalid_argument", "control parser options must be a table")
    end
    local limits = {}
    for name, default in pairs(defaults) do
        local value = options[name]
        if value == nil then
            value = default
        end
        if type(value) ~= "number" or value < 1 or value > 2147483647 or value % 1 ~= 0 then
            return nil,
                errors.new("invalid_argument", "control parser limit must be a positive integer")
        end
        limits[name] = value
    end
    if options.bootstrap ~= nil and type(options.bootstrap) ~= "boolean" then
        return nil, errors.new("invalid_argument", "control bootstrap context must be boolean")
    end
    return setmetatable({
        _limits = limits,
        _bootstrap = options.bootstrap == true,
        _parts = {},
        _line_bytes = 0,
        _offset = 0,
    }, Parser)
end

function Parser:_fail(events, code, message, limit, cause)
    local err = errors.new(code, message, { offset = self._offset, limit = limit, cause = cause })
    self._error, self._closed = err, true
    self._parts, self._line_bytes, self._block = {}, 0, nil
    -- One fixed terminal slot is reserved in addition to the bounded data events.
    events[#events + 1] = { kind = "error", error = err }
    return events, err
end

function Parser:_emit(events, event)
    if #events >= self._limits.max_events then
        return "events"
    end
    -- Count raw, payload and decoded copies separately, including extended metadata.
    local bytes = byte_cost(event)
    if self._event_bytes + bytes > self._limits.max_event_bytes then
        return "event_bytes"
    end
    self._event_bytes = self._event_bytes + bytes
    events[#events + 1] = event
end

function Parser:_line(line)
    local block = self._block
    if block then
        local ending
        if line == "%end " .. block.tuple then
            ending = "end"
        elseif line == "%error " .. block.tuple then
            ending = "error"
        end
        if ending then
            self._block = nil
            return {
                kind = "block",
                phase = block.phase,
                guard = block.guard,
                body = table.concat(block.parts),
                ending = ending,
            }
        end
        if block.bytes + #line + 1 > self._limits.max_block_bytes then
            return nil, "block"
        end
        if #block.parts >= self._limits.max_block_lines then
            return nil, "block_lines"
        end
        block.parts[#block.parts + 1] = line .. "\n"
        block.bytes = block.bytes + #line + 1
        return nil
    end
    local name, payload = line:match("^%%([^ ]+) ?(.*)$")
    if name == "begin" then
        local time, number, flags = payload:match("^(%-?[0-9]+) ([0-9]+) ([0-9]+)$")
        if not time then
            return nil, nil, "malformed control begin guard"
        end
        self._block = {
            tuple = payload,
            guard = { time = time, number = number, flags = flags },
            phase = self._bootstrap and "bootstrap" or "command",
            parts = {},
            bytes = 0,
        }
        self._bootstrap = false
    elseif name == "end" or name == "error" then
        return nil, nil, "control closing guard has no open block"
    elseif name then
        local event = notification(line, name, payload)
        if not event then
            return nil, nil, "malformed control output notification"
        end
        return event
    else
        return { kind = "raw", raw = line }
    end
end

-- Returned events belong to the caller; no event history remains in the parser.
-- Input/event budgets are per call, line/block budgets span arbitrary feed splits.
function Parser:feed(bytes)
    local events = {}
    if self._closed then
        return events, self._error or errors.new("closed", "control parser is finished")
    end
    if type(bytes) ~= "string" then
        return self:_fail(events, "invalid_argument", "control input must be a byte string")
    end
    if #bytes > self._limits.max_input_bytes then
        return self:_fail(events, "frame_limit", "control input exceeds its byte limit", "input")
    end
    self._event_bytes = 0
    local start = 1
    while start <= #bytes do
        local newline = bytes:find("\n", start, true)
        local stop = newline and newline - 1 or #bytes
        local length = stop - start + 1
        if self._line_bytes + length > self._limits.max_line_bytes then
            return self:_fail(events, "frame_limit", "control line exceeds its byte limit", "line")
        end
        self._parts[#self._parts + 1] = bytes:sub(start, stop)
        self._line_bytes = self._line_bytes + length
        self._offset = self._offset + length
        if not newline then
            break
        end
        self._offset = self._offset + 1
        local line = table.concat(self._parts)
        self._parts, self._line_bytes = {}, 0
        local event, limit, message = self:_line(line)
        if message then
            return self:_fail(events, "invalid_frame", message)
        end
        if event then
            limit = self:_emit(events, event)
        end
        if limit then
            return self:_fail(
                events,
                "frame_limit",
                "control frame exceeds its " .. limit .. " limit",
                limit
            )
        end
        start = newline + 1
    end
    return events
end

function Parser:finish(cause)
    if self._closed then
        return {}, self._error
    end
    if cause ~= nil then
        return self:_fail({}, "read_failed", "control input failed", nil, cause)
    end
    if self._line_bytes ~= 0 or self._block then
        return self:_fail({}, "truncated_frame", "control input ended inside a line or block")
    end
    self._closed = true
    return { { kind = "eof" } }
end

function Parser:stats()
    local block = self._block
    return {
        retained_bytes = self._line_bytes
            + (block and block.bytes + byte_cost(block.guard) + #block.tuple or 0),
        line_bytes = self._line_bytes,
        block_bytes = block and block.bytes or 0,
        block_lines = block and #block.parts or 0,
        closed = self._closed == true,
    }
end

return M
