-- Run an external program from a script that has no luv yet: the bootstrap commands that build the
-- tool interpreter and install its rocks. Arguments are quoted, never interpolated, so no argument
-- is read as shell syntax. Anything with luv uses support.proc instead.
local M = {}

local SENTINEL = "libtmux-lua-exit="
local SENTINEL_PATTERN = SENTINEL:gsub("%-", "%%-")

---@param value string
---@return string
function M.quote(value)
    if value:match("^[%w_%-%./=:,@%%+]+$") then
        return value
    end
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

---@param argv string[]
---@return string
function M.join(argv)
    local parts = {}
    for index, value in ipairs(argv) do
        parts[index] = M.quote(value)
    end
    return table.concat(parts, " ")
end

---@class support.ShellOptions
---@field cwd? string
---@field env? table<string, string> Set in the child.
---@field unset? string[] Names removed from the child's environment.
---@field log? string Append standard output and error to this file instead of capturing them.
---@field stdin? string Standard input; a file name such as /dev/null.

--- The command line `argv` runs as, with its directory, environment and redirections.
---@param argv string[]
---@param opts? support.ShellOptions
---@return string
function M.command(argv, opts)
    opts = opts or {}
    local words = { "env" }
    for _, name in ipairs(opts.unset or {}) do
        words[#words + 1] = "-u " .. M.quote(name)
    end
    local names = {}
    for name in pairs(opts.env or {}) do
        names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
        words[#words + 1] = M.quote(name .. "=" .. opts.env[name])
    end
    words[#words + 1] = M.join(argv)
    local line = table.concat(words, " ")
    if opts.cwd then
        line = "cd " .. M.quote(opts.cwd) .. " && " .. line
    end
    if opts.stdin then
        line = line .. " < " .. M.quote(opts.stdin)
    end
    if opts.log then
        line = line .. " >> " .. M.quote(opts.log) .. " 2>&1"
    end
    return line
end

--- Runs a command and returns its exit code with its standard output (and standard error, unless
--- a log file takes them). A command killed by a signal reports 128 plus the signal.
---@param argv string[]
---@param opts? support.ShellOptions
---@return number code
---@return string output
function M.run(argv, opts)
    local line = M.command(argv, opts)
    local merged = (opts and opts.log) and "" or " 2>&1"
    local pipe = assert(
        io.popen("( " .. line .. " )" .. merged .. '; printf "\\n' .. SENTINEL .. '%d" "$?"', "r")
    )
    local text = pipe:read("*a")
    pipe:close()
    local body, code = text:match("^(.*)\n" .. SENTINEL_PATTERN .. "(%d+)$")
    if not body then
        error("cannot read the status of " .. argv[1], 0)
    end
    return assert(tonumber(code)), body
end

--- Like run, but raises when the command fails.
---@param argv string[]
---@param opts? support.ShellOptions
---@return string output
function M.check(argv, opts)
    local code, output = M.run(argv, opts)
    if code ~= 0 then
        error(argv[1] .. " failed (" .. code .. "): " .. output, 0)
    end
    return output
end

return M
