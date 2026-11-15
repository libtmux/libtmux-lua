-- A stand-in tmux that records how it was called and starts nothing.
--
-- It writes the arguments and the names of the variables that select a server. It never writes an
-- environment value: whether TMUX_TMPDIR lies under FAKE_TMUX_ROOT, whether the sandbox marker
-- equals it, and whether the -S socket lies under it are recorded as words. It exits with
-- FAKE_TMUX_STATUS, which is 1 when unset.
--
-- FAKE_TMUX_SERVER makes the file at the -S path stand for a server. With "answers", kill-server
-- removes it; with "slow", a moment after it returns; with anything else it stays, which is a
-- server that does not stop.
local files = require("support.files")
local fs = require("support.fs")
local runtime = require("support.runtime")
local sandbox = require("tests.support.sandbox")
local uv = require("support.uv")

local M = {}

-- Runs under the interpreter that wrote it, with the same search paths, so it finds luv.
local SCRIPT = [[
package.path, package.cpath = %q, %q
local log = assert(os.getenv("FAKE_TMUX_LOG"))
local root = assert(os.getenv("FAKE_TMUX_ROOT"))
local tmpdir = os.getenv("TMUX_TMPDIR")
local lines = { "CALL" }
local previous, socket, target = nil, "none", nil
local base = (tmpdir or "/nonexistent") .. "/"
for _, argument in ipairs(arg) do
    lines[#lines + 1] = "ARG " .. argument
    if previous == "-S" then
        target = argument
        socket = argument:sub(1, #base) == base and "inside" or "outside"
    end
    previous = argument
end
lines[#lines + 1] = "SOCKET " .. socket
for _, name in ipairs(%s) do
    if os.getenv(name) then
        lines[#lines + 1] = "SET " .. name
    end
end
if tmpdir == nil or tmpdir == "" then
    lines[#lines + 1] = "TMPDIR unset"
elseif tmpdir:sub(1, #root + 1) == root .. "/" then
    lines[#lines + 1] = "TMPDIR inside"
else
    lines[#lines + 1] = "TMPDIR outside"
end
local marker = os.getenv("LIBTMUX_TEST_SANDBOX")
lines[#lines + 1] = (marker ~= nil and marker ~= "" and marker == tmpdir) and "MARKER matches"
    or "MARKER differs"
local handle = assert(io.open(log, "ab"))
handle:write(table.concat(lines, "\n"), "\n")
handle:close()
local server = os.getenv("FAKE_TMUX_SERVER")
if server and target and table.concat(arg, " "):match("kill%%-server$") then
    if server == "answers" then
        os.remove(target)
    elseif server == "slow" then
        local uv = require("luv")
        local remover = "package.path, package.cpath = %%q, %%q; "
            .. "require('luv').sleep(40); os.remove(%%q)"
        remover = remover:format(package.path, package.cpath, target)
        assert(uv.spawn(arg[-1], { args = { "-e", remover }, detached = true }, function() end))
    end
end
os.exit(tonumber(os.getenv("FAKE_TMUX_STATUS")) or 1)
]]

--- Writes the recorder as an executable named tmux and returns its path.
---@param directory string
---@return string
function M.install(directory)
    fs.mkdir_p(directory)
    local path = directory .. "/tmux"
    local names = {}
    for index, name in ipairs(sandbox.SELECTORS) do
        names[index] = ("%q"):format(name)
    end
    local interpreter = runtime.executable_path(arg and arg[-1] or "luajit")
    files.write(
        path,
        ("#!%s\n"):format(interpreter)
            .. SCRIPT:format(package.path, package.cpath, "{ " .. table.concat(names, ", ") .. " }")
    )
    assert(uv.fs_chmod(path, 448))
    return path
end

---@class tests.RecordedCall
---@field argv string[]
---@field set string[] names of the selector variables that were set
---@field tmpdir? string "inside", "outside" or "unset"
---@field marker? string "matches" or "differs"
---@field socket? string "inside", "outside" or "none"

--- The recorded calls: argv, selector names, and the words per call.
---@param log string
---@return tests.RecordedCall[]
function M.calls(log)
    local found = {}
    if not fs.is_file(log) then
        return found
    end
    for line in files.read(log):gmatch("[^\n]+") do
        local word, rest = line:match("^(%u+) ?(.*)$")
        if word == "CALL" then
            found[#found + 1] = { argv = {}, set = {} }
        elseif word == "ARG" then
            table.insert(found[#found].argv, rest)
        elseif word == "SET" then
            table.insert(found[#found].set, rest)
        elseif word == "SOCKET" then
            found[#found].socket = rest
        elseif word == "TMPDIR" then
            found[#found].tmpdir = rest
        elseif word == "MARKER" then
            found[#found].marker = rest
        end
    end
    return found
end

return M
