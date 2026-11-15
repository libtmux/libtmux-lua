-- Timed, offline development gates; dependency setup is a separate command.
--
--   luajit scripts/check/check.lua GATE [SUITE...] [--lua PATH] [--nvim PATH]
--
-- Gates: unit, mid, format, lint, generated, docs, integration, refusal, package, types and outer.
-- SUITE names select unit suites. The process makes the tmux sandbox first, so nothing a gate
-- starts can reach a server of the developer's, and fails the run when a socket is left in it.
-- Each command prints one JSON line with its exit code and wall time; the gate prints its own
-- and fails when it exceeds its budget. See README.md.
local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/../../?.lua;" .. package.path
local repo = require("support.repo")
repo.use_rocks()
local argparse = require("argparse")
local gates = require("check.gates")
local json = require("support.json")
local proc = require("support.proc")
local sandbox_host = require("tests.support.sandbox_host")

local cli = argparse("check.lua", "Timed, offline development gates.")
cli:argument("gate", "the gate to run"):choices(gates.GATES)
cli:argument("suites", "unit suite names"):args("*")
cli:option("--lua", "interpreter executable"):default("lua")
cli:option("--nvim", "Neovim executable for embedded integration tests")
local parsed, arguments = cli:pparse({ ... })
if not parsed then
    io.stderr:write(cli:get_usage(), "\ncheck.lua: error: ", arguments, "\n")
    os.exit(2)
end
if #arguments.suites > 0 and arguments.gate ~= "unit" then
    io.stderr:write("check.lua: error: suite names apply only to the unit gate\n")
    os.exit(2)
end

local function command_line(argv)
    local quoted = {}
    for index, value in ipairs(argv) do
        quoted[index] = value
    end
    return quoted
end

--- Runs the steps of the gate, printing a JSON line for each command. Returns the exit status.
local function execute(steps)
    local luv = require("support.uv")
    for _, step in ipairs(steps) do
        if step.call then
            step.call()
        else
            local started = luv.hrtime()
            local result = proc.run(step.argv, {
                cwd = repo.root,
                env = step.env,
                timeout = step.timeout or 290,
                inherit = true,
            })
            local seconds = (luv.hrtime() - started) / 1e9
            local code = result.timed_out and 124 or result.code
            print(json.encode(json.object({ "command", "exit_code", "wall_seconds" }, {
                command = command_line(step.argv),
                exit_code = code,
                wall_seconds = tonumber(("%.4f"):format(seconds)),
            })))
            if code ~= 0 then
                return code
            end
        end
    end
    return 0
end

os.exit(sandbox_host.run(function()
    local luv = require("support.uv")
    local started = luv.hrtime()
    local ok, steps = pcall(gates.steps, arguments.gate, {
        lua = arguments.lua,
        nvim = arguments.nvim,
        suites = arguments.suites,
    })
    if not ok then
        io.stderr:write(tostring(steps), "\n")
        return 1
    end
    local code
    ok, code = pcall(execute, steps)
    if not ok then
        io.stderr:write(tostring(code), "\n")
        return 1
    end
    local elapsed = (luv.hrtime() - started) / 1e9
    local budget = gates.budget(arguments.gate)
    local status = elapsed < budget and "PASS" or "FAIL"
    print(json.encode(json.object({ "gate", "wall_seconds", "budget_seconds", "status" }, {
        gate = arguments.gate,
        wall_seconds = tonumber(("%.4f"):format(elapsed)),
        budget_seconds = budget,
        status = code == 0 and status or "FAIL",
    })))
    if code ~= 0 then
        return code
    end
    if elapsed >= budget then
        io.stderr:write("Gate exceeded its whole-command budget\n")
        return 1
    end
    return 0
end))
