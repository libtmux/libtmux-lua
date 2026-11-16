-- Proves the identity report names each tool the job used, in order, and stops at a failure.
local test = require("luaunit")
local cli = require("ci_plan.cli")
local identity = require("ci_plan.identity")
local proc = require("support.proc")
local repo = require("support.repo")
local M = {}

local function buffer()
    local parts = {}
    return {
        write = function(_, ...)
            for _, text in ipairs({ ... }) do
                parts[#parts + 1] = text
            end
        end,
        text = function()
            return table.concat(parts)
        end,
    }
end

--- A runner that answers each command with its own words and records the commands.
local function runner(seen, failing)
    return function(argv)
        seen[#seen + 1] = table.concat(argv, " ")
        local code = failing and argv[1] == failing and 3 or 0
        return {
            code = code,
            signal = 0,
            stdout = argv[1] .. " out\n",
            stderr = argv[1] .. " err\n",
            timed_out = false,
        }
    end
end

local function names(commands)
    local seen = {}
    for _, argv in ipairs(commands) do
        seen[#seen + 1] = table.concat(argv, " ")
    end
    return seen
end

function M.test_a_unit_job_names_the_toolchain_and_no_tmux_or_neovim()
    test.assertEquals(names(identity.commands({ lua = "/t/luajit", tmux = "", nvim = "" })), {
        "git rev-parse HEAD",
        "uname -a",
        "cc --version",
        "/t/luajit -v",
        "luarocks --version",
    })
end

function M.test_a_tmux_job_adds_each_tmux_then_neovim()
    test.assertEquals(
        names(
            identity.commands({ lua = "l", tmux = "/t/tmux", client = "/c/tmux", nvim = "/n/nvim" })
        ),
        {
            "git rev-parse HEAD",
            "uname -a",
            "cc --version",
            "l -v",
            "luarocks --version",
            "/t/tmux -V",
            "/c/tmux -V",
            "/n/nvim --version",
        }
    )
    test.assertEquals(#identity.commands({ lua = "l", tmux = "/t/tmux" }), 6)
end

function M.test_the_report_writes_each_output_in_order()
    local out, seen = buffer(), {}
    local ok = identity.report({ { "git", "x" }, { "uname", "-a" } }, out, runner(seen))
    test.assertTrue(ok)
    test.assertEquals(out.text(), "git out\ngit err\nuname out\nuname err\n")
    test.assertEquals(seen, { "git x", "uname -a" })
end

function M.test_the_report_stops_at_the_first_failing_command()
    local out, seen = buffer(), {}
    local ok, failure = identity.report({ { "a" }, { "b" }, { "c" } }, out, runner(seen, "b"))
    test.assertFalse(ok)
    test.assertEquals(failure, "b exited with status 3")
    test.assertEquals(seen, { "a", "b" })
end

function M.test_a_command_that_cannot_start_or_runs_too_long_fails_the_report()
    local out = buffer()
    local ok, failure = identity.report({ { "missing" } }, out, function()
        error("cannot start missing", 0)
    end)
    test.assertFalse(ok)
    test.assertEquals(failure, "cannot start missing")
    ok, failure = identity.report({ { "slow" } }, out, function()
        return { code = -1, signal = 9, stdout = "", stderr = "", timed_out = true }
    end)
    test.assertFalse(ok)
    test.assertStrContains(failure, "slow ran past")
end

function M.test_the_command_line_prints_the_report_and_reports_a_failure_in_the_exit_status()
    local out, err, seen = buffer(), buffer(), {}
    local status = cli.main(
        { "identity", "--lua", "/t/luajit", "--tmux", "/t/tmux" },
        { stdout = out, stderr = err, run = runner(seen) }
    )
    test.assertEquals(status, 0)
    test.assertEquals(seen[4], "/t/luajit -v")
    test.assertEquals(seen[6], "/t/tmux -V")
    test.assertStrContains(out.text(), "/t/tmux out\n")
    local failing, failures = buffer(), buffer()
    status = cli.main(
        { "identity", "--lua", "/t/luajit" },
        { stdout = failing, stderr = failures, run = runner({}, "uname") }
    )
    test.assertEquals(status, 1)
    test.assertEquals(failures.text(), "identity: uname exited with status 3\n")
    status = cli.main({ "identity" }, { stdout = failing, stderr = failures })
    test.assertEquals(status, 2)
end

-- The `plan` job installs the `dev` rocks and not luv, so the command line has to load without it.
function M.test_the_command_line_loads_without_luv()
    local program = table.concat({
        'package.preload["luv"] = function() error("luv was loaded", 0) end',
        ('package.path = %q .. ";" .. package.path'):format(repo.root .. "/scripts/?.lua"),
        'require("support.repo").use_rocks()',
        'require("ci_plan.cli")',
        'io.write("loaded")',
    }, "; ")
    local result = proc.run({ arg[-1], "-e", program })
    test.assertEquals(result.stderr, "")
    test.assertEquals(result.stdout, "loaded")
    test.assertEquals(result.code, 0)
end

return M
