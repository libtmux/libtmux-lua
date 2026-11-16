-- Version support: reads which tmux release the connected daemon runs.
-- "Support" means the tmux releases this library works with, not helper code.
local M = {}
local codec = require("libtmux._internal.codec")
local MAX_INTEGER = 9007199254740991
local TEMPLATE = assert(codec.format({ "pid", "start_time", "version", "socket_path" }))
local sequence = 0

-- A fresh prefix distinguishes native probe rows and generation-fence refusals.
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
    return { "list-commands", "-F", prefix .. TEMPLATE, "list-sessions" }
end

-- The reserved native command emits one row through the existing bounded codec.
function M.report(prefix, stdout)
    if type(stdout) ~= "string" or stdout:sub(1, #prefix) ~= prefix then
        return nil
    end
    local rows = codec.decode(stdout:sub(#prefix + 1), 4, { max_bytes = 16384, max_rows = 1 })
    if not rows or #rows ~= 1 then
        return nil
    end
    local pid, started, version, socket = rows[1][1], rows[1][2], rows[1][3], rows[1][4]
    if not pid:match("^%d+$") or not started:match("^%d+$") or socket == "" then
        return nil
    end
    local pid_number, start_number = tonumber(pid), tonumber(started)
    if
        not pid_number
        or not start_number
        or pid_number <= 0
        or start_number <= 0
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

-- Old clients reject -N; old protocol peers can reject the connection before
-- parsing a command. A valid older daemon row is refused by the support floor.
local PRE_32 = {
    { "server version is too old for client", "server" },
    { "tmux: unknown option -- N", "client" },
}

-- Which side of the connection is too old to be probed, from a failed probe's
-- stderr: "server", "client", or nil when the failure says nothing about age.
function M.too_old(stderr)
    if type(stderr) ~= "string" then
        return nil
    end
    local line = stderr:match("^[^\n]*")
    for _, entry in ipairs(PRE_32) do
        if line:sub(1, #entry[1]) == entry[1] then
            return entry[2]
        end
    end
    return nil
end

return M
