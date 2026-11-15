-- Run a program to completion on luv: no shell, an explicit environment, bounded time.
local uv = require("support.uv")

local M = {}

-- A write to a pipe whose reader has exited raises SIGPIPE, which kills a process that leaves it at
-- its default. A child that exits without reading its input is ordinary, so the write fails with
-- EPIPE instead: libuv handles the signal once something listens for it.
local sigpipe = assert(uv.new_signal())
sigpipe:unref()
sigpipe:start("sigpipe", function() end)

---@param env table<string, string>
---@return string[]
local function environment_list(env)
    local list = {}
    for name, value in pairs(env) do
        list[#list + 1] = name .. "=" .. value
    end
    table.sort(list)
    return list
end

--- This process's environment as a table. Children inherit it unless they are given another.
---@return table<string, string>
function M.environment()
    return uv.os_environ()
end

---@class support.RunOptions
---@field cwd? string
---@field env? table<string, string> Replaces the whole environment. Defaults to this process's.
---@field stdin? string Written to the child's standard input, which is then closed.
---@field timeout? number Seconds before the child is killed.
---@field inherit? boolean Give the child this process's standard streams instead of capturing them.

---@class support.RunResult
---@field code integer
---@field signal integer
---@field stdout string
---@field stderr string
---@field timed_out boolean

--- Runs argv, waits, and returns its exit code, signal and captured output.
---@param argv string[]
---@param opts? support.RunOptions
---@return support.RunResult
function M.run(argv, opts)
    opts = opts or {}
    local result = { code = -1, signal = 0, stdout = "", stderr = "", timed_out = false }
    local input, out, err
    local stdio
    if opts.inherit then
        stdio = { 0, 1, 2 }
    else
        input = opts.stdin and uv.new_pipe(false) or nil
        out, err = uv.new_pipe(false), uv.new_pipe(false)
        stdio = { input or 0, out, err }
    end
    local open = 0
    local function closed()
        open = open - 1
    end
    local chunks = { stdout = {}, stderr = {} }
    local function collect(pipe, name)
        open = open + 1
        pipe:read_start(function(read_error, data)
            assert(not read_error, read_error)
            if data then
                chunks[name][#chunks[name] + 1] = data
            else
                pipe:read_stop()
                pipe:close(closed)
            end
        end)
    end
    local handle, started
    local timer
    open = open + 1
    handle, started = uv.spawn(argv[1], {
        args = { unpack(argv, 2) },
        env = environment_list(opts.env or uv.os_environ()),
        cwd = opts.cwd,
        stdio = stdio,
    }, function(code, signal)
        result.code, result.signal = code, signal
        handle:close(closed)
        if timer then
            timer:stop()
            timer:close(closed)
            timer = nil
        end
    end)
    if not handle then
        for _, pipe in ipairs({ input, out, err }) do
            if pipe then
                pipe:close()
            end
        end
        error("cannot start " .. argv[1] .. ": " .. tostring(started), 0)
    end
    if out and err then
        collect(out, "stdout")
        collect(err, "stderr")
    end
    if input then
        open = open + 1
        input:write(opts.stdin, function()
            input:shutdown(function()
                input:close(closed)
            end)
        end)
    end
    if opts.timeout then
        timer = uv.new_timer()
        open = open + 1
        timer:start(opts.timeout * 1000, 0, function()
            result.timed_out = true
            handle:kill("sigkill")
        end)
    end
    -- A caller's own handles, such as a listening socket, keep the loop alive, so run it only until
    -- this child is finished.
    while open > 0 do
        uv.run("once")
    end
    result.stdout = table.concat(chunks.stdout)
    result.stderr = table.concat(chunks.stderr)
    return result
end

return M
