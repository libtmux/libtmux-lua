-- Child processes for the integration harness: spawn on luv, wait with a deadline, and give way
-- to SIGINT and SIGTERM so the fixtures that own tmux servers can clean up first.
--
-- Every wait is the same loop: run luv until a condition holds, a timer tick wakes it often enough
-- to look at the condition and the clock, and a cancellation signal ends it. The harness runs on
-- LuaJIT, so a pseudo-terminal comes from its FFI.
local uv = require("support.uv")

local M = {}

-- A write to a client that has already exited raises SIGPIPE, which would end the run; with
-- libuv listening for it the write fails with EPIPE instead.
local sigpipe = assert(uv.new_signal())
sigpipe:unref()
sigpipe:start("sigpipe", function() end)

--- The error value a wait raises once, after SIGINT or SIGTERM arrived.
M.CANCELLED = "integration run cancelled"

--- The signal number that cancelled the run, once one did.
---@type integer?
M.cancelled = nil

---@type integer?
local pending

---@type table<harness.Child, boolean>
local live = {}

local watchers = {}

--- From now on SIGINT and SIGTERM end the run at the next wait: that wait kills the children and
--- raises M.CANCELLED once, so the fixtures between it and the runner clean up. Later signals
--- change nothing, as cleanup must not be cancelled in turn.
function M.watch_signals()
    for name, number in pairs({ sigint = 2, sigterm = 15 }) do
        if not watchers[name] then
            local handle = assert(uv.new_signal())
            handle:unref()
            handle:start(name, function()
                if not M.cancelled then
                    M.cancelled, pending = number, number
                end
            end)
            watchers[name] = handle
        end
    end
end

function M.kill_all()
    for child in pairs(live) do
        child:kill()
    end
end

--- Runs luv until `done()` is true or `seconds` pass. Returns whether it is true. A timer tick
--- every `tick` milliseconds is how a condition that no event announces gets looked at again.
---@param done fun(): boolean
---@param seconds number
---@param tick? integer
---@return boolean
function M.pump(done, seconds, tick)
    tick = tick or 10
    local timer = assert(uv.new_timer())
    timer:start(tick, tick, function() end)
    uv.update_time()
    local limit = uv.now() + seconds * 1000
    local finished = done()
    while not finished do
        if pending then
            pending = nil
            timer:close()
            M.kill_all()
            error(M.CANCELLED, 0)
        end
        uv.update_time()
        if uv.now() >= limit then
            break
        end
        uv.run("once")
        finished = done()
    end
    timer:close()
    return finished
end

--- Waits for a delay without looking at anything.
---@param seconds number
function M.sleep(seconds)
    M.pump(function()
        return false
    end, seconds)
end

---@class harness.Child
---@field argv string[]
---@field pid integer
---@field handle any
---@field stdin? any the write end, until closed
---@field exited boolean
---@field code? integer
---@field signal? integer
---@field out string[]
---@field err string[]
---@field out_open boolean
---@field err_open boolean
local Child = {}
Child.__index = Child
M.Child = Child

local null_descriptor

local function null()
    if not null_descriptor then
        null_descriptor = assert(uv.fs_open("/dev/null", "r+", 0))
    end
    return null_descriptor
end

---@class harness.SpawnOptions
---@field env? table<string, string> the whole environment; this process's when absent
---@field cwd? string
---@field stdin? "null"|"pipe"|integer
---@field stdout? "pipe"|"null"|integer
---@field stderr? "pipe"|"null"|integer

local function environment_list(env)
    local list = {}
    for name, value in pairs(env) do
        list[#list + 1] = name .. "=" .. value
    end
    table.sort(list)
    return list
end

---@param argv string[]
---@param opts? harness.SpawnOptions
---@return harness.Child
function M.spawn(argv, opts)
    opts = opts or {}
    local self = setmetatable({
        argv = argv,
        exited = false,
        out = {},
        err = {},
        out_open = false,
        err_open = false,
    }, Child)
    local pipes = {}
    local function slot(kind)
        if kind == "pipe" then
            local pipe = assert(uv.new_pipe(false))
            pipes[#pipes + 1] = pipe
            return pipe
        elseif type(kind) == "number" then
            return kind
        end
        return null()
    end
    local stdin = slot(opts.stdin or "null")
    local stdout = slot(opts.stdout or "pipe")
    local stderr = slot(opts.stderr or "pipe")
    local handle, pid = uv.spawn(argv[1], {
        args = { unpack(argv, 2) },
        env = environment_list(opts.env or uv.os_environ()),
        cwd = opts.cwd,
        stdio = { stdin, stdout, stderr },
    }, function(code, signal)
        self.exited, self.code, self.signal = true, code, signal
        live[self] = nil
        self.handle:close()
    end)
    if not handle then
        for _, pipe in ipairs(pipes) do
            pipe:close()
        end
        error(("cannot start %s: %s"):format(argv[1], tostring(pid)), 0)
    end
    self.handle, self.pid = handle, pid
    live[self] = true
    if type(stdin) == "userdata" then
        self.stdin = stdin
    end
    local function collect(pipe, chunks, flag)
        self[flag] = true
        pipe:read_start(function(failure, data)
            if data then
                chunks[#chunks + 1] = data
            else
                pipe:read_stop()
                pipe:close()
                self[flag] = false
            end
            assert(not failure or data == nil, failure)
        end)
    end
    if type(stdout) == "userdata" then
        collect(stdout, self.out, "out_open")
    end
    if type(stderr) == "userdata" then
        collect(stderr, self.err, "err_open")
    end
    return self
end

---@return string
function Child:output()
    return table.concat(self.out)
end

---@return string
function Child:errors()
    return table.concat(self.err)
end

--- Writes to the child's standard input.
---@param data string
function Child:write(data)
    assert(self.stdin, "the child has no standard input pipe")
    self.stdin:write(data)
end

--- Closes standard input once what was written has been delivered.
function Child:close_stdin()
    if self.stdin then
        local pipe = self.stdin
        self.stdin = nil
        pipe:shutdown(function()
            pipe:close()
        end)
    end
end

---@param signal? string|integer defaults to sigkill
function Child:kill(signal)
    if not self.exited then
        self.handle:kill(signal or "sigkill")
    end
end

--- Waits for the child to exit and for both of its output pipes to reach the end.
---@param seconds number
---@return boolean
function Child:wait(seconds)
    return M.pump(function()
        return self.exited and not self.out_open and not self.err_open
    end, seconds)
end

--- Waits until the predicate accepts the output that arrives after this call.
---@param accept fun(fresh: string): boolean
---@param seconds number
---@return boolean
function Child:expect(accept, seconds)
    local start = #self:output()
    return M.pump(function()
        return accept(self:output():sub(start + 1))
    end, seconds)
end

---@class harness.Result
---@field code integer
---@field signal integer
---@field stdout string
---@field stderr string

---@return harness.Result
function Child:result()
    return {
        code = self.code or -1,
        signal = self.signal or 0,
        stdout = self:output(),
        stderr = self:errors(),
    }
end

--- Waits like communicate: when the child has not finished in time it is killed, and the wait is
--- an error naming the program and what it wrote.
---@param seconds number
---@return harness.Result
function Child:finish(seconds)
    if not self:wait(seconds) then
        self:kill()
        self:wait(0.8)
        error(
            ("%s did not finish within %s s; stderr: %s"):format(
                self.argv[1],
                seconds,
                self:errors()
            ),
            0
        )
    end
    self:close_stdin()
    return self:result()
end

--- Kills what still runs, closes standard input and waits for the end.
function Child:close()
    self:kill()
    self:close_stdin()
    self:wait(0.8)
end

--- Runs a program to completion within `seconds` and returns its result.
---@param argv string[]
---@param opts? harness.SpawnOptions|{timeout?: number, input?: string}
---@return harness.Result
function M.run(argv, opts)
    opts = opts or {}
    local spawned = {}
    for name, value in pairs(opts) do
        spawned[name] = value
    end
    spawned.stdin = opts.input and "pipe" or opts.stdin
    local self = M.spawn(argv, spawned)
    if opts.input then
        self:write(opts.input)
        self:close_stdin()
    end
    return self:finish(opts.timeout or 5)
end

-- Linux tells a process that has only become a zombie apart from one that is gone.
local has_proc = (function()
    local handle = io.open("/proc/self/stat", "rb")
    if handle then
        handle:close()
    end
    return handle ~= nil
end)()

--- Whether the process exists and has not merely become a zombie or been reaped.
---@param pid integer
---@return boolean
function M.alive(pid)
    if not uv.kill(pid, 0) then
        return false
    end
    if not has_proc then
        return true
    end
    local handle = io.open(("/proc/%d/stat"):format(pid), "rb")
    local text = handle and handle:read("*a")
    if handle then
        handle:close()
    end
    local state = text and text:match("^%d+ %b() (%a)")
    if state == nil then
        -- The entry is unreadable while a process exits and after it is reaped; only the signal
        -- lookup, asked again, tells the two apart.
        return uv.kill(pid, 0) ~= nil
    end
    -- A zombie is Z, and for an instant before its parent has reaped it, X.
    return state ~= "Z" and state ~= "X" and state ~= "x"
end

--- What `ps` would say about a process, for a failure that names it: the state and the command.
---@param pid integer
---@return string
function M.describe(pid)
    local function read(name)
        local handle = io.open(("/proc/%d/%s"):format(pid, name), "rb")
        local text = handle and handle:read("*a")
        if handle then
            handle:close()
        end
        return text or ""
    end
    local state = read("stat"):match("^%d+ %b() (%a)") or "?"
    local command = read("cmdline"):gsub("%z", " "):gsub("%s+$", "")
    return ("%d (state %s) %s"):format(pid, state, command)
end

--- Waits until none of the processes exists. Returns the pids that still do.
---@param pids integer[]
---@param seconds number
---@return integer[]
function M.wait_gone(pids, seconds)
    local function remaining()
        local found = {}
        for _, pid in ipairs(pids) do
            if M.alive(pid) then
                found[#found + 1] = pid
            end
        end
        return found
    end
    M.pump(function()
        return #remaining() == 0
    end, seconds, 2)
    return remaining()
end

--- Makes a named pipe, which a reader opens only once a writer does.
---@param path string
function M.mkfifo(path)
    local ffi = require("ffi")
    if not pcall(ffi.typeof, "libtmux_mkfifo_t") then
        ffi.cdef("typedef int libtmux_mkfifo_t; int mkfifo(const char *path, unsigned int mode);")
    end
    assert(ffi.C.mkfifo(path, 448) == 0, "mkfifo failed")
end

---@class harness.Terminal
---@field master integer
---@field slave integer
---@field name string

--- A pseudo-terminal of the given size, for a client that needs a terminal to attach from.
---@param rows integer
---@param columns integer
---@return harness.Terminal
function M.openpty(rows, columns)
    local ffi = require("ffi")
    if not pcall(ffi.typeof, "libtmux_winsize") then
        ffi.cdef([[
            typedef struct { unsigned short rows, columns, x, y; } libtmux_winsize;
            int openpty(int *master, int *slave, char *name, const void *termios,
                const libtmux_winsize *size);
        ]])
    end
    -- The function is in libc from glibc 2.34 and in libutil before it.
    local library = ffi.C
    if not pcall(function()
        return ffi.C.openpty
    end) then
        library = ffi.load("util")
    end
    local master, slave, name = ffi.new("int[1]"), ffi.new("int[1]"), ffi.new("char[256]")
    local size = ffi.new("libtmux_winsize", { rows, columns, 0, 0 })
    assert(library.openpty(master, slave, name, nil, size) == 0, "openpty failed")
    return { master = master[0], slave = slave[0], name = ffi.string(name) }
end

---@param terminal harness.Terminal
function M.close_terminal(terminal)
    uv.fs_close(terminal.master)
    uv.fs_close(terminal.slave)
end

return M
