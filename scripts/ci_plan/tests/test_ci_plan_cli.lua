-- Proves the command line writes single-line JSON, refuses a bad plan without writing and exits
-- with the status it documents.
local S = require("ci_plan.tests.plan_support")
local test = require("luaunit")
local cli = require("ci_plan.cli")
local json = require("support.json")
local NEWEST = S.NEWEST
local copy = S.copy
local map = S.map
local set = S.set
local cells = S.cells
local run = S.run

local M = {}

local function buffer()
    local chunks = {}
    return {
        write = function(self, ...)
            for _, chunk in ipairs({ ... }) do
                chunks[#chunks + 1] = chunk
            end
            return self
        end,
        text = function()
            return table.concat(chunks)
        end,
    }
end

local function main(argv, environment)
    local out, err = buffer(), buffer()
    local status = cli.main(argv, {
        getenv = function(name)
            return (environment or {})[name]
        end,
        stdout = out,
        stderr = err,
    })
    return status, out.text(), err.text()
end

local function read_all(path)
    local handle = assert(io.open(path, "rb"))
    local text = handle:read("*a")
    handle:close()
    return text
end

function M.test_the_outputs_are_single_line_json()
    local output, summary = os.tmpname(), os.tmpname()
    local status, printed = main({
        "plan",
        "--event",
        "push",
        "--github-output",
        output,
        "--summary",
        summary,
    })
    local written, described = read_all(output), read_all(summary)
    os.remove(output)
    os.remove(summary)
    test.assertEquals(status, 0)
    test.assertEquals(json.decode(printed).scope, "edges")
    local lines = {}
    for line in written:gmatch("[^\n]+") do
        local name, value = line:match("^([^=]+)=(.*)$")
        lines[name] = value
    end
    test.assertEquals(
        set(json.keys(lines)),
        { scope = true, os = true, matrix = true, expected_jobs = true }
    )
    test.assertEquals(json.decode(lines.matrix), json.decode(json.encode(run("push").matrix)))
    test.assertEquals(lines.expected_jobs, tostring(run("push").expected_jobs))
    test.assertStrContains(described, "- tmux " .. NEWEST)
    test.assertStrContains(described, "### CI plan: edges\n\nExpected jobs in this workflow: ")
end

function M.test_a_refused_plan_exits_nonzero_and_writes_nothing()
    local output = os.tmpname()
    os.remove(output)
    local status, printed, failure = main({
        "plan",
        "--event",
        "push",
        "--tmux-ref",
        "master",
        "--github-output",
        output,
    })
    local created = io.open(output)
    test.assertEquals({ status, printed }, { 1, "" })
    test.assertStrContains(failure, "only used with scope custom")
    test.assertNil(created)
end

function M.test_the_inputs_reach_the_plan()
    local status, printed = main({
        "plan",
        "--event",
        "workflow_dispatch",
        "--scope",
        "custom",
        "--tmux-ref",
        "master",
        "--lua",
        "luajit",
        "--nvim",
        "0.10.0",
        "--os",
        "ubuntu-latest",
        "--tmate",
        "on-failure",
    })
    local result = json.decode(printed)
    test.assertEquals(status, 0)
    test.assertEquals(result.os, "ubuntu-latest")
    test.assertEquals(
        map(cells(result), function(each)
            return { each.lua, each.nvim, each.tmate }
        end),
        { { "luajit", "0.10.0", "on-failure" } }
    )
end

function M.test_empty_inputs_are_the_defaults()
    local status, printed = main({
        "plan",
        "--event",
        "push",
        "--scope",
        "",
        "--tmux-ref",
        "",
        "--lua",
        "",
        "--nvim",
        "",
        "--os",
        "",
        "--tmate",
        "",
    })
    test.assertEquals(status, 0)
    test.assertEquals(json.decode(printed), json.decode(json.encode(run("push"), 2)))
end

function M.test_a_usage_error_exits_2()
    local status, printed, failure = main({ "plan" })
    test.assertEquals({ status, printed }, { 2, "" })
    test.assertStrContains(failure, "--event")
end

function M.test_verify_reads_the_needs_context()
    local good = { plan = { result = "success" }, validate = { result = "success" } }
    test.assertEquals((main({ "verify" }, { NEEDS = json.encode(good) })), 0)
    local bad = copy(good)
    bad.validate = { result = "failure" }
    local status, _, failure = main({ "verify" }, { NEEDS = json.encode(bad) })
    test.assertEquals(status, 1)
    test.assertStrContains(failure, "validate finished failure")
    test.assertEquals((main({ "verify" }, { NEEDS = "{}" })), 1)
    test.assertEquals((main({ "verify" })), 1)
end

return M
