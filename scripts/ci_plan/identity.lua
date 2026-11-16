-- The identities of the tools a CI job ran with, printed so the log shows what produced a result.
-- Starting a process needs luv, which the `plan` job does not install, so `support.proc` loads only
-- when a command runs.
local M = {}

--- Seconds one identity command may take.
M.TIMEOUT = 30

---@class ci_plan.Tools
---@field lua string the interpreter the tests run under
---@field tmux? string
---@field client? string a newer tmux that starts beside the first
---@field nvim? string

--- The commands whose output identifies a toolchain, in the order they print. An empty path means
--- the job does not use that tool.
---@param tools ci_plan.Tools
---@return string[][]
function M.commands(tools)
    local commands = {
        { "git", "rev-parse", "HEAD" },
        { "uname", "-a" },
        { "cc", "--version" },
        { tools.lua, "-v" },
        { "luarocks", "--version" },
    }
    for _, path in ipairs({ tools.tmux or "", tools.client or "" }) do
        if path ~= "" then
            commands[#commands + 1] = { path, "-V" }
        end
    end
    if (tools.nvim or "") ~= "" then
        commands[#commands + 1] = { tools.nvim, "--version" }
    end
    return commands
end

---@param argv string[]
---@return support.RunResult
local function run(argv)
    return require("support.proc").run(argv, { timeout = M.TIMEOUT })
end

--- Runs each command and writes what it printed, standard error included, to `out`. Stops at the
--- first command that fails or cannot start.
---@param commands string[][]
---@param out { write: fun(self: any, ...: string) }
---@param runner? fun(argv: string[]): support.RunResult
---@return boolean ok
---@return string? failure
function M.report(commands, out, runner)
    for _, argv in ipairs(commands) do
        local started, result = pcall(runner or run, argv)
        if not started then
            return false, tostring(result)
        end
        out:write(result.stdout, result.stderr)
        if result.timed_out then
            return false, argv[1] .. " ran past " .. M.TIMEOUT .. " seconds"
        elseif result.code ~= 0 then
            return false, ("%s exited with status %d"):format(argv[1], result.code)
        end
    end
    return true
end

return M
