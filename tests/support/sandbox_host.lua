-- A private tmux world for the processes that run the tests.
--
-- A tmux command that names no socket goes to the server an inherited TMUX names, and otherwise to
-- the default socket under TMUX_TMPDIR. Every test passes -S, so none should reach either.
-- Entering the sandbox removes what selects a server and points TMUX_TMPDIR at a directory this run
-- owns: a test that forgets -S finds nothing, and the run fails when it finds a socket anywhere in
-- the sandbox. Findings name variables and never print their values.
local uv = require("support.uv")
local sandbox = require("tests.support.sandbox")

local M = {}

-- tmux resolves the directory through realpath. luv's mkdtemp appends six characters.
local NAME_BYTES = #sandbox.PREFIX + 6
-- How long kill-server may take before a socket that still accepts a connection counts as a server
-- that was not stopped.
M.STOP_SECONDS = 3

---@class tests.Refused
---@field message string

local function refuse(message)
    error(
        setmetatable({ message = message }, {
            __tostring = function(self)
                return self.message
            end,
        }),
        0
    )
end

--- Why the sandbox directory cannot be used, or nil.
---@param directory string
---@return string?
local function directory_problem(directory)
    local stat = uv.fs_stat(directory)
    if not stat then
        return "the sandbox directory is missing"
    end
    if stat.type ~= "directory" or stat.uid ~= uv.os_get_passwd().uid then
        return "the sandbox directory belongs to another user"
    end
end

--- Raises unless this process's environment is a sandbox that exists and is this user's.
function M.check()
    local found = sandbox.violations(os.getenv)
    if #found == 0 then
        local problem = directory_problem(assert(os.getenv("TMUX_TMPDIR")))
        found = problem and { problem } or {}
    end
    if #found > 0 then
        refuse(table.concat(found, "; "))
    end
end

---@param env table<string, string>
---@return table<string, string>
function M.scrub(env)
    local clean = {}
    for name, value in pairs(env) do
        if not sandbox.ambient(name) then
            clean[name] = value
        end
    end
    return clean
end

--- The socket tmux connects to when TMUX is unset and no -S or -L is given. tmux resolves the
--- directory through realpath, so a symlinked TMUX_TMPDIR (macOS /tmp) names the target.
---@param env table<string, string>
---@param uid? integer
---@return string
function M.default_socket(env, uid)
    uid = uid or uv.os_get_passwd().uid
    local base = env.TMUX_TMPDIR
    if base == nil or base == "" then
        base = "/tmp"
    end
    return ("%s/tmux-%d/default"):format(uv.fs_realpath(base) or base, uid)
end

local function create(roots)
    for _, root in ipairs(roots) do
        local stat = uv.fs_stat(root)
        if
            #root + 1 + NAME_BYTES <= sandbox.MAX_BYTES
            and stat
            and stat.type == "directory"
            and uv.fs_access(root, "W")
            and uv.fs_access(root, "X")
        then
            return assert(uv.fs_mkdtemp(root .. "/" .. sandbox.PREFIX .. "XXXXXX"))
        end
    end
    refuse(
        "no temporary directory is short enough for a tmux socket path; set TMPDIR to a shorter one"
    )
end

local function remove(directory)
    local name = directory:match("([^/]+)/*$") or ""
    if name:sub(1, #sandbox.PREFIX) == sandbox.PREFIX then
        require("support.fs").remove_tree(directory)
    end
end

--- Turns this process's environment into a sandbox in place and returns its directory and whether
--- it made one. A process whose environment already names a live sandbox joins it instead of making
--- another, so the process that made it is the one that checks it.
---@param roots? string[]
---@return string directory
---@return boolean created
function M.prepare(roots)
    roots = roots or { os.getenv("TMPDIR") or "/tmp", "/tmp" }
    local directory = os.getenv("TMUX_TMPDIR")
    local joined = #sandbox.directory_findings(os.getenv) == 0
        and directory_problem(assert(directory)) == nil
    for name in pairs(uv.os_environ()) do
        if sandbox.ambient(name) then
            uv.os_unsetenv(name)
        end
    end
    if not joined then
        directory = create(roots)
    end
    uv.os_setenv("TMUX_TMPDIR", directory)
    uv.os_setenv(sandbox.MARKER, directory)
    local ok, failure = pcall(M.check)
    if not ok then
        if not joined then
            remove(directory)
        end
        error(failure, 0)
    end
    return assert(directory), not joined
end

--- Every socket under the directory, at any depth, relative to it. Each test puts its own server
--- on a socket in a directory of its own, so a socket anywhere in the sandbox, whether tmux chose
--- it or a test named it with -S, is a server no test stopped. A link is not followed.
---@param directory string
---@return string[]
function M.leaks(directory)
    local found = {}
    local fs = require("support.fs")
    for _, relative in ipairs(fs.walk(directory)) do
        local stat = uv.fs_lstat(directory .. "/" .. relative)
        if stat and stat.type == "socket" then
            found[#found + 1] = relative
        end
    end
    table.sort(found)
    return found
end

--- Whether a connection to the socket succeeds. Only a refusal or a missing path shows that no
--- server is behind it; any other outcome leaves the server unproven gone.
---@param target string
---@return boolean
function M.answering(target)
    if #target >= 104 then
        return true
    end
    local pipe = uv.new_pipe(false)
    local answered, finished = true, false
    pipe:connect(target, function(failure)
        if
            failure
            and (failure:find("ECONNREFUSED") or failure:find("ENOENT") or failure:find("ENOTDIR"))
        then
            answered = false
        end
        pipe:close(function()
            finished = true
        end)
    end)
    -- The caller's own handles may keep the loop alive, so run it only until the probe is done.
    while not finished do
        uv.run("once")
    end
    return answered
end

--- Runs kill-server on a socket and returns whether nothing answers there. A server leaves a moment
--- after kill-server returns, so the connection is retried until it fails or the wait runs out.
local function stop(target, tmux, wait)
    local proc = require("support.proc")
    pcall(proc.run, { tmux, "-N", "-S", target, "kill-server" }, {
        env = M.scrub(proc.environment()),
        timeout = 5,
        stdin = "",
    })
    local deadline = uv.now() + wait * 1000
    while M.answering(target) do
        uv.update_time()
        if uv.now() >= deadline then
            return false
        end
        uv.sleep(20)
    end
    return true
end

---@class tests.Release
---@field leaked string[] every socket found under the sandbox, relative to it
---@field answering string[] those that still accepted a connection after the stop

--- Stops the server behind each socket and removes the directory. The directory stays while a
--- server still answers.
---@param directory string
---@param tmux? string
---@param wait? number
---@return tests.Release
function M.release(directory, tmux, wait)
    tmux = tmux or os.getenv("TMUX_BIN") or "tmux"
    wait = wait or M.STOP_SECONDS
    local found = M.leaks(directory)
    local answering = {}
    for _, path in ipairs(found) do
        if not stop(directory .. "/" .. path, tmux, wait) then
            answering[#answering + 1] = path
        end
    end
    if #answering == 0 then
        remove(directory)
    end
    return { leaked = found, answering = answering }
end

--- The failure for a release that found sockets: names, never values.
---@param released tests.Release
---@param directory string
---@return string
function M.describe(released, directory)
    local text = "libtmux-lua tests left sockets in the sandbox: "
        .. table.concat(released.leaked, ", ")
    if #released.answering > 0 then
        text = text
            .. ("; a server still answers at %s, so %s was kept"):format(
                table.concat(released.answering, ", "),
                directory:match("([^/]+)/*$")
            )
    end
    return text
end

--- Runs `body` inside the sandbox and returns its exit status. The process that made the sandbox
--- checks it afterwards and fails the run when a socket was left, even when the body passed.
--- Returns 2 when no sandbox can be made.
---@param body fun(): integer?
---@return integer
function M.run(body)
    local ok, directory, created = pcall(M.prepare)
    if not ok then
        io.stderr:write("libtmux-lua tests refused to run: ", tostring(directory), "\n")
        return 2
    end
    local succeeded, status = pcall(body)
    local code = succeeded and (status or 0) or 1
    if not succeeded then
        io.stderr:write(tostring(status), "\n")
    end
    if created then
        local released = M.release(directory)
        if #released.leaked > 0 then
            io.stderr:write(M.describe(released, directory), "\n")
            return 1
        end
    end
    return code
end

return M
