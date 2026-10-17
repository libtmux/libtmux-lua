-- Version support: reads which tmux release the connected daemon runs.
-- "Support" means the tmux releases this library works with, not helper code.
local M = {}
local MAX_INTEGER = 9007199254740991
-- tmux fires no hook for run-shell -C: its expanded text fails in the parser.
-- The doubled q: survives that parser's one level of unquoting.
local TEMPLATE = "#{pid}_#{start_time}_#{version}_#{q:#{q:socket_path}}."
local sequence = 0

-- A marker names no tmux command, so tmux refuses it and reports the word.
function M.marker(uv)
    sequence = sequence + 1
    local random
    if uv and type(uv.random) == "function" then
        local ok, bytes = pcall(uv.random, 8)
        if ok and type(bytes) == "string" and #bytes == 8 then
            random = bytes:gsub(".", function(byte)
                return string.format("%02x", byte:byte())
            end)
        end
    end
    random = random
        or string.format(
            "%08x%08x",
            (os.time() * 65537 + sequence) % 4294967296,
            math.floor(os.clock() * 1000000) % 4294967296
        )
    return string.format("libtmux-version-%s%04x-", random, sequence % 65536)
end

-- True only on the daemon whose pid, start time and release were checked.
function M.condition(evidence)
    return "#{&&:#{==:#{pid},"
        .. evidence.pid
        .. "},#{&&:#{==:#{start_time},"
        .. evidence.started
        .. "},#{==:#{version},"
        .. evidence.version
        .. "}}}"
end

function M.argv(prefix)
    return { "run-shell", "-C", prefix .. TEMPLATE }
end

-- The report is exactly one stderr line: tmux's refusal of this probe's marker.
function M.report(prefix, stderr)
    local head = "unknown command: " .. prefix
    if type(stderr) ~= "string" or stderr:sub(1, #head) ~= head or stderr:sub(-1) ~= "\n" then
        return nil
    end
    local record = stderr:sub(#head + 1, -2)
    local pid, started, version, socket = record:match("^(%d+)_(%d+)_([^_]+)_(.+)%.$")
    local pid_number, start_number = tonumber(pid), tonumber(started)
    if
        not pid
        or socket:find("\n", 1, true)
        or pid_number <= 0
        or pid_number > MAX_INTEGER
        or start_number > MAX_INTEGER
    then
        return nil
    end
    return {
        pid = string.format("%.0f", pid_number),
        started = string.format("%.0f", start_number),
        version = version,
        socket = socket,
    }
end

return M
