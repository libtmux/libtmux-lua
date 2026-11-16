local argparse = require("argparse")
local files = require("support.files")
local identity = require("ci_plan.identity")
local json = require("support.json")
local planner = require("ci_plan.planner")

local M = {}

local function parser()
    local cli = argparse(
        "ci_plan.lua",
        "Plan the CI jobs from the tmux catalog, data/ci-matrix.json and the event."
    )
    cli:command_target("command")
    cli:require_command(true)
    local plan = cli:command("plan", "Plan the matrix for one event.")
    plan:option("--event", "github.event_name"):count(1)
    plan:option("--scope", "edges, full or custom"):default("")
    plan:option("--tmux-ref", "comma-separated tmux refs"):default("")
    plan:option("--lua", "comma-separated Lua runtimes for the tmux jobs"):default("")
    plan:option("--nvim", "comma-separated Neovim versions for the tmux jobs"):default("")
    plan:option("--os", "runner image"):default("")
    plan:option("--tmate", "off, before-tests or on-failure"):default("")
    plan:option("--github-output", "the GITHUB_OUTPUT file")
    plan:option("--summary", "the GITHUB_STEP_SUMMARY file")
    cli:command("verify", "Check the NEEDS environment variable.")
    local tools = cli:command("identity", "Print the identities of the tools a job ran with.")
    tools:option("--lua", "the interpreter the tests run under"):count(1)
    tools:option("--tmux", "the tmux the tests ran against"):default("")
    tools:option("--client", "a newer tmux that starts beside it"):default("")
    tools:option("--nvim", "the Neovim host"):default("")
    return cli
end

local function traceback_unless_refused(failure)
    if getmetatable(failure) == planner.PlanError then
        return failure
    end
    return debug.traceback(tostring(failure), 2)
end

-- `context` replaces getenv, stdout and stderr, so a test needs no process. Returns the exit
-- status.
function M.main(argv, context)
    context = context or {}
    local getenv = context.getenv or os.getenv
    local stdout = context.stdout or io.stdout
    local stderr = context.stderr or io.stderr

    local cli = parser()
    local parsed, arguments = cli:pparse(argv)
    if not parsed then
        stderr:write(cli:get_usage(), "\nci_plan.lua: error: ", arguments, "\n")
        return 2
    end

    if arguments.command == "identity" then
        local ok, failure = identity.report(
            identity.commands({
                lua = arguments.lua,
                tmux = arguments.tmux,
                client = arguments.client,
                nvim = arguments.nvim,
            }),
            stdout,
            context.run
        )
        if not ok then
            stderr:write("identity: ", failure, "\n")
        end
        return ok and 0 or 1
    end

    if arguments.command == "verify" then
        local problems = planner.check_needs(json.decode(getenv("NEEDS") or "{}"))
        for _, problem in ipairs(problems) do
            stderr:write("required: ", problem, "\n")
        end
        return #problems > 0 and 1 or 0
    end

    local planned, result = xpcall(function()
        return planner.plan(planner.load(), {
            event = arguments.event,
            scope = arguments.scope,
            tmux_ref = arguments.tmux_ref,
            lua = arguments.lua,
            nvim = arguments.nvim,
            image = arguments.os,
            tmate = arguments.tmate,
        })
    end, traceback_unless_refused)
    if not planned then
        if getmetatable(result) ~= planner.PlanError then
            error(result, 0)
        end
        stderr:write("plan: ", result.message, "\n")
        return 1
    end
    stdout:write(json.encode(result, 2), "\n")
    if arguments.github_output then
        local lines = {}
        for _, pair in ipairs(planner.outputs(result)) do
            lines[#lines + 1] = pair[1] .. "=" .. pair[2] .. "\n"
        end
        files.append(arguments.github_output, table.concat(lines))
    end
    if arguments.summary then
        files.append(arguments.summary, planner.summary(result))
    end
    return 0
end

return M
