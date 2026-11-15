-- Proves ci.yml takes its jobs from the plan and stays bound to the release gate.
--
-- The workflows are read as text, because the job that runs these tests has no YAML parser. Each
-- rule has a mutation that has to be reported: a rule that survives its own removal checks nothing.
local test = require("luaunit")
local files = require("support.files")
local planner = require("ci_plan.planner")
local repo = require("support.repo")

local CI = files.read(repo.root .. "/.github/workflows/ci.yml")
local PUBLISH = files.read(repo.root .. "/.github/workflows/publish.yml")
local MANIFEST = planner.load()
local M = {}

local function lines_of(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

local function has(text, needle)
    return text:find(needle, 1, true) ~= nil
end

local function replaced(text, old, new)
    local first, last = text:find(old, 1, true)
    assert(first, "the mutation target is gone: " .. old)
    return text:sub(1, first - 1) .. new .. text:sub(last + 1)
end

--- Maps each job id to its text.
local function split_jobs(text)
    local _, after = text:find("\njobs:\n", 1, true)
    local found, order, name = {}, {}, nil
    for _, line in ipairs(lines_of(text:sub(after + 1))) do
        local header = line:match("^  ([%w_%-]+):%s*$")
        if header then
            name = header
            found[name], order[#order + 1] = {}, name
        elseif name and (line:sub(1, 4) == "    " or line:match("^%s*$")) then
            table.insert(found[name], line)
        elseif line ~= "" and not line:match("^[ #]") then
            name = nil
        end
    end
    for key, value in pairs(found) do
        found[key] = table.concat(value, "\n")
    end
    return found, order
end

local function field(job, key)
    local value = job:match("\n    " .. key:gsub("%-", "%%-") .. ": ([^\n]*)")
        or job:match("^    " .. key:gsub("%-", "%%-") .. ": ([^\n]*)")
    return value and value:match("^%s*(.-)%s*$")
end

--- Maps each workflow_dispatch input to its text.
local function dispatch_inputs(text)
    local first = text:find("\n  workflow_dispatch:\n    inputs:\n", 1, true)
    local last = text:find("\n  workflow_call:", 1, true)
    local found, name = {}, nil
    for _, line in ipairs(lines_of(text:sub(first, last))) do
        local header = line:match("^      ([%a%-]+):%s*$")
        if header then
            name = header
            found[name] = {}
        elseif name then
            table.insert(found[name], line)
        end
    end
    for key, value in pairs(found) do
        found[key] = table.concat(value, "\n")
    end
    return found
end

local function options(text)
    local list = text:match("options: %[(.-)%]")
    if not list then
        return nil
    end
    local items = {}
    for item in list:gmatch("[^,]+") do
        items[#items + 1] = item:match("^%s*['\"]?(.-)['\"]?%s*$")
    end
    return items
end

local BOOLEANS = {
    y = true,
    yes = true,
    ["true"] = true,
    on = true,
    n = true,
    no = true,
    ["false"] = true,
    off = true,
}

--- Each input default or option that YAML 1.1 reads as a boolean. GitHub reads a bare off as
--- false, so a choice list that holds one refuses every dispatch that sets nothing.
local function bare_booleans(text)
    local found = {}
    local function bare(token)
        token = token:match("^%s*(.-)%s*$")
        if token:sub(1, 1) ~= "'" and token:sub(1, 1) ~= '"' and BOOLEANS[token:lower()] then
            return token
        end
    end
    for name, body in pairs(dispatch_inputs(text)) do
        local in_options = false
        for _, line in ipairs(lines_of(body)) do
            local stripped = line:gsub(" #.*$", "")
            local item = stripped:match("^%s*%-%s+(.+)$")
            local flow = stripped:match("^%s*options:%s*%[(.*)%]$")
            local values = {}
            if in_options and item then
                values = { item }
            elseif flow then
                in_options = false
                for value in flow:gmatch("[^,]+") do
                    values[#values + 1] = value
                end
            else
                in_options = stripped:match("^%s*options:%s*$") ~= nil
            end
            for _, value in ipairs(values) do
                if bare(value) then
                    found[#found + 1] = { name, "option", bare(value) }
                end
            end
            local default = stripped:match("^%s*default:%s*(.+)$")
            if default and bare(default) then
                found[#found + 1] = { name, "default", bare(default) }
            end
        end
    end
    return found
end

local function steps_of(job)
    local steps = {}
    for _, line in ipairs(lines_of(job)) do
        if line:match("^      %- ") then
            steps[#steps + 1] = {}
        end
        if #steps > 0 then
            table.insert(steps[#steps], line)
        end
    end
    for index, step in ipairs(steps) do
        steps[index] = table.concat(step, "\n")
    end
    return steps
end

--- The workflow without its descriptions, which may name a version as an example.
local function without_descriptions(text)
    local kept, skipping = {}, false
    for _, line in ipairs(lines_of(text)) do
        if line:match("^ +description: ") then
            skipping = true
        elseif skipping and line:match("^          ") then
            skipping = true
        else
            skipping = false
            kept[#kept + 1] = line
        end
    end
    return table.concat(kept, "\n")
end

local function problems(ci, publish)
    local found = {}
    local function add(message)
        found[#found + 1] = message
    end
    local jobs, order = split_jobs(ci)
    local code = without_descriptions(ci)
    for _, name in ipairs(MANIFEST.table) do
        if code:find("[^%w%.]" .. name:gsub("%.", "%%.") .. "[^%w%.]") then
            add("ci.yml names tmux " .. name .. ", which only the catalog and manifest may")
        end
    end
    for name in pairs(MANIFEST.refused) do
        if code:find("[^%w%.]" .. name:gsub("%.", "%%.") .. "[^%w%.]") then
            add("ci.yml names tmux " .. name .. ", which only the catalog and manifest may")
        end
    end
    if ci:find("\n%s+include:") then
        add("ci.yml lists its own matrix")
    end
    if not (jobs.plan and jobs.validate) then
        add("ci.yml needs a plan job and a validate job")
        return found
    end
    if field(jobs.validate, "needs") ~= "plan" then
        add("validate: must wait for the plan")
    end
    if field(jobs.validate, "runs-on") ~= "${{ needs.plan.outputs.os }}" then
        add("validate: must run on the image the plan chose")
    end
    if not has(jobs.validate, "matrix: ${{ fromJSON(needs.plan.outputs.matrix) }}") then
        add("validate: the matrix must come from the plan")
    end
    if jobs.validate:find("\n    if:") then
        add("validate: the matrix shrinks through the plan, never an if on the job")
    end
    local gate = jobs.required
    if not gate then
        add("ci.yml needs one stable required job")
    else
        local waited, expected = {}, {}
        for word in (field(gate, "needs") or ""):gmatch("[%w_%-]+") do
            waited[word] = true
        end
        for _, name in ipairs(order) do
            if name ~= "required" then
                expected[name] = true
            end
        end
        for name in pairs(expected) do
            if not waited[name] then
                add("required: must wait for every other job")
                break
            end
        end
        if field(gate, "name") ~= "required" then
            add("required: the check keeps one stable name")
        end
        if field(gate, "if") ~= "always()" then
            add("required: must run when a job it waits for failed")
        end
        if not (has(gate, "NEEDS: ${{ toJSON(needs) }}") and has(gate, "ci_plan.lua verify")) then
            add("required: must verify the needs context with the plan script")
        end
    end

    local inputs = dispatch_inputs(ci)
    for _, each in ipairs(bare_booleans(ci)) do
        add(
            ("the %s input has a bare %s as its %s, which GitHub reads as a boolean"):format(
                each[1],
                each[3],
                each[2]
            )
        )
    end
    if
        table.concat(options(inputs.scope or "") or {}, ",") ~= table.concat(planner.SCOPES, ",")
    then
        add("the scope input must offer exactly the plan's scopes")
    end
    if not has(inputs.scope or "", "default: edges") then
        add("the scope input must default to edges")
    end
    if table.concat(options(inputs.os or "") or {}, ",") ~= table.concat(planner.RUNNERS, ",") then
        add("the os input must offer exactly the plan's runner images")
    end
    if ci:lower():find("macos", 1, true) then
        add("ci.yml must not run on macOS")
    end
    for name in pairs(inputs) do
        if not has(jobs.plan, "inputs." .. name .. " }}") then
            add("plan: the " .. name .. " input must reach the plan")
        end
    end
    for _, line in ipairs(lines_of(ci)) do
        if has(line, "inputs.") and not line:match("^%s+[A-Z_]+: %${{ inputs%.[a-z%-]+ }}$") then
            add("an input may reach a step only through env")
        end
    end
    local group = ci:match("\nconcurrency:\n  group: ([^\n]*)\n  cancel%-in%-progress: ([^\n]*)")
    local progress =
        select(2, ci:match("\nconcurrency:\n  group: ([^\n]*)\n  cancel%-in%-progress: ([^\n]*)"))
    if
        not (group and has(group, "github.event_name == 'workflow_dispatch' && github.run_id ||"))
    then
        add("a dispatch run must have its own concurrency group")
    end
    if
        not (
            group
            and has(group, "github.event.pull_request.number || github.ref")
            and progress == "true"
        )
    then
        add("a push and a pull request must still cancel the run they supersede")
    end
    local call = ci:match("\n  workflow_call:\n    inputs:\n      scope:\n(.-)\n%S")
    if not (call and has(call, "required: true")) then
        add("the workflow_call scope input must be required")
    end

    local release = split_jobs(publish)
    if not has(release.validate or "", "uses: ./.github/workflows/ci.yml") then
        add("publish: validate must call ci.yml")
    end
    if not has(release.validate or "", "\n    with:\n      scope: full") then
        add("publish: validate must ask for scope full")
    end
    if field(release.luarocks or "", "needs") ~= "validate" then
        add("publish: the upload must wait for validate")
    end
    return found
end

--- Each shared action the workflows use must be pinned to a full commit, and no run script may
--- call apt directly: libtmux/.github/actions/apt-get bounds a hung mirror
--- (actions/runner-images#15040) only while every call goes through it.
local function supply_problems(workflows)
    local found = {}
    for path, text in pairs(workflows) do
        for _, line in ipairs(lines_of(text)) do
            local action = line:match("uses: (libtmux/%.github/actions/[%w%-]+@%S+)")
            if
                action and not action:match("@%x+$") or (action and #action:match("@(%x+)$") ~= 40)
            then
                found[#found + 1] = path .. ": " .. action .. " must be pinned to a full commit SHA"
            end
            local command = line:match("^%s*%- run: *(.*)$")
                or line:match("^%s*run: *(.*)$")
                or line:match("^%s+(%S.*)$")
            if
                command
                and not command:match("^#")
                and (
                    command:match("^sudo +apt")
                    or command:match("^apt")
                    or command:match("[;&|] *sudo +apt")
                    or command:match("[;&|] *apt")
                )
            then
                found[#found + 1] = path
                    .. ": calls apt directly; use libtmux/.github/actions/apt-get"
            end
        end
    end
    table.sort(found)
    return found
end

local function sessions(ci, publish)
    local found = {}
    local jobs = split_jobs(ci)
    local count = 0
    for name, job in pairs(jobs) do
        for _, step in ipairs(steps_of(job)) do
            if has(step, "mxschmitt/action-tmate") then
                count = count + 1
                if name ~= "validate" then
                    found[#found + 1] = name
                        .. ": a debugging session belongs only in the test matrix"
                end
                if not step:match("uses: mxschmitt/action%-tmate@%x+ # v") then
                    found[#found + 1] = "a debugging session must be pinned to a full commit SHA"
                end
                if not has(step, "limit-access-to-actor: true") then
                    found[#found + 1] = "a debugging session must be limited to the actor"
                end
                if not step:match("\n        timeout%-minutes: ") then
                    found[#found + 1] = "a debugging session needs its own time limit"
                end
                local condition = step:match("\n        if: ([^\n]*)") or ""
                if
                    not (
                        has(condition, "github.event_name == 'workflow_dispatch'")
                        and has(condition, "matrix.tmate ==")
                    )
                then
                    found[#found + 1] =
                        "a debugging session runs only on a dispatch, on the job the plan chose"
                end
            end
        end
    end
    if count ~= 2 then
        found[#found + 1] =
            "the matrix must offer a session before the tests and one after a failure"
    end
    if
        field(jobs.validate or "", "timeout-minutes") ~= "${{ matrix.tmate == 'off' && 20 || 60 }}"
    then
        found[#found + 1] = "validate: the job must cap its time and give the debugging job more"
    end
    local tmate = dispatch_inputs(ci).tmate or ""
    if
        table.concat(options(tmate) or {}, ",") ~= table.concat(planner.TMATE_MODES, ",")
        or not has(tmate, "default: 'off'")
    then
        found[#found + 1] = "the tmate input must offer exactly the plan's modes and default to off"
    end
    if
        not (
            has(jobs.plan or "", "TMATE: ${{ inputs.tmate }}")
            and has(jobs.plan or "", '--tmate "$TMATE"')
        )
    then
        found[#found + 1] = "plan: must pass the tmate input through env"
    end
    if has(publish, "mxschmitt/action-tmate") then
        found[#found + 1] = "publish: a release never opens a debugging session"
    end
    return found
end

--- Names each Lua source archive the job builds that no cache step restores. www.lua.org times
--- out from runners now and then; the SHA256 pins in runtimes.lua verify a restored archive.
local function archive_problems(job)
    local keys = {}
    for _, step in ipairs(steps_of(job)) do
        local path = step:match("\n          path: ([^\n]*)")
        local key = step:match("\n          key: ([^\n]*)")
        if
            has(step, "actions/cache@")
            and path
            and key
            and has(path, ".cache/source/lua-*.tar.gz")
        then
            keys[#keys + 1] = key
        end
    end
    local builds = {}
    if has(job, 'bootstrap.lua runtimes "$CI_LUA"') then
        builds[#builds + 1] = { "${{ matrix.lua }}", "the matrix Lua" }
    end
    for version in job:gmatch("bootstrap%.lua runtimes (%d+%.%d+%.%d+)") do
        builds[#builds + 1] = { version, "Lua " .. version }
    end
    local found = {}
    for _, build in ipairs(builds) do
        local cached = false
        for _, key in ipairs(keys) do
            cached = cached or key:sub(-#build[1] - 1) == "-" .. build[1]
        end
        if not cached then
            found[#found + 1] = "validate: builds "
                .. build[2]
                .. " from lua.org and no cache step restores its archive"
        end
    end
    return found
end

local function all_problems(ci, publish)
    local found = problems(ci, publish)
    for _, list in ipairs({
        sessions(ci, publish),
        archive_problems(split_jobs(ci).validate or ""),
        supply_problems({ ["ci.yml"] = ci }),
    }) do
        for _, message in ipairs(list) do
            found[#found + 1] = message
        end
    end
    return found
end

function M.test_the_workflows_follow_the_plan()
    test.assertEquals(all_problems(CI, PUBLISH), {})
end

function M.test_the_workflow_as_written_has_no_bare_boolean()
    test.assertEquals(bare_booleans(CI), {})
end

function M.test_a_quoted_block_list_has_no_bare_boolean()
    local block = replaced(
        CI,
        "        options: ['off', before-tests, on-failure]\n",
        "        options:\n          - 'off'\n          - \"before-tests\"\n"
            .. "          - on-failure\n"
    )
    test.assertEquals(bare_booleans(block), {})
end

function M.test_every_workflow_and_action_in_the_repository_is_pinned_and_calls_no_raw_apt()
    local workflows = {}
    for _, name in ipairs({ "ci.yml", "docs.yml", "publish.yml", "docs-preview-cleanup.yml" }) do
        workflows[name] = files.read(repo.root .. "/.github/workflows/" .. name)
    end
    workflows["lua-tools"] = files.read(repo.root .. "/.github/actions/lua-tools/action.yml")
    test.assertEquals(supply_problems(workflows), {})
end

function M.test_no_other_workflow_opens_a_session()
    for _, name in ipairs({ "docs.yml", "publish.yml", "docs-preview-cleanup.yml" }) do
        local text = files.read(repo.root .. "/.github/workflows/" .. name)
        test.assertFalse(has(text, "mxschmitt/action-tmate"), name)
    end
end

function M.test_the_workflow_runs_every_job_the_plan_names()
    local names = {}
    for _, cell in ipairs(planner.plan(MANIFEST, { event = "push" }).matrix.include) do
        names[cell.name] = true
    end
    test.assertTrue(names["Outer current"])
    test.assertEquals(field(split_jobs(CI).validate, "name"), "${{ matrix.name }}")
    test.assertTrue(has(CI, "if: matrix.name == 'Outer current'"))
end

function M.test_a_matrix_cell_names_the_ref_the_tmux_action_builds()
    test.assertTrue(has(CI, "ref: ${{ matrix.ref }}"))
    test.assertTrue(has(CI, "ref: ${{ matrix.client }}"))
end

local SESSION = "mxschmitt/action-tmate@35b54afac29c97fb54faba5b513f8fbd1882f113 # v3.24"
local MUTATIONS = {
    {
        "a tmux version returns to the workflow",
        function(ci, pub)
            return ci .. "      - run: echo " .. MANIFEST.released[1] .. "\n", pub
        end,
        "ci.yml names tmux",
    },
    {
        "the matrix is listed again",
        function(ci, pub)
            return replaced(
                ci,
                "      matrix: ${{ fromJSON(needs.plan.outputs.matrix) }}",
                "      matrix:\n        include:\n          - {name: x}"
            ),
                pub
        end,
        "ci.yml lists its own matrix",
    },
    {
        "validate stops waiting for the plan",
        function(ci, pub)
            return replaced(ci, "    needs: plan\n", ""), pub
        end,
        "validate: must wait for the plan",
    },
    {
        "validate runs on a fixed image",
        function(ci, pub)
            return replaced(ci, "runs-on: ${{ needs.plan.outputs.os }}", "runs-on: ubuntu-24.04"),
                pub
        end,
        "the image the plan chose",
    },
    {
        "validate is trimmed with an if",
        function(ci, pub)
            return replaced(
                ci,
                "    needs: plan\n    runs-on:",
                "    needs: plan\n    if: github.event_name != 'push'\n    runs-on:"
            ),
                pub
        end,
        "never an if on the job",
    },
    {
        "the scope input offers another scope",
        function(ci, pub)
            return replaced(ci, "options: [edges, full, custom]", "options: [edges, full]"), pub
        end,
        "the plan's scopes",
    },
    {
        "the scope input defaults to full",
        function(ci, pub)
            return replaced(ci, "        default: edges\n", "        default: full\n"), pub
        end,
        "must default to edges",
    },
    {
        "a macOS image appears",
        function(ci, pub)
            return replaced(ci, "ubuntu-22.04]", "ubuntu-22.04, macos-latest]"), pub
        end,
        "must not run on macOS",
    },
    {
        "an input stops reaching the plan",
        function(ci, pub)
            return replaced(ci, "          NVIM: ${{ inputs.nvim }}\n", ""), pub
        end,
        "plan: the nvim input must reach the plan",
    },
    {
        "an input is used inline in a script",
        function(ci, pub)
            return replaced(ci, '--lua "$LUA" \\\n', '--lua "${{ inputs.lua }}" \\\n'), pub
        end,
        "only through env",
    },
    {
        "the required job forgets a job",
        function(ci, pub)
            return replaced(ci, "needs: [plan, validate]", "needs: [validate]"), pub
        end,
        "must wait for every other job",
    },
    {
        "the required job is skipped after a failure",
        function(ci, pub)
            return replaced(
                ci,
                "needs: [plan, validate]\n    if: always()\n",
                "needs: [plan, validate]\n"
            ),
                pub
        end,
        "must run when a job it waits for failed",
    },
    {
        "the required job stops verifying",
        function(ci, pub)
            return replaced(ci, "run: luajit scripts/ci_plan/ci_plan.lua verify", "run: 'true'"),
                pub
        end,
        "must verify the needs context",
    },
    {
        "a job is added that the required job does not wait for",
        function(ci, pub)
            return ci .. "\n  extra:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: 'true'\n",
                pub
        end,
        "must wait for every other job",
    },
    {
        "the session is not pinned to a commit",
        function(ci, pub)
            return (ci:gsub("action%-tmate@%x+ # v3.24", "action-tmate@v3")), pub
        end,
        "pinned to a full commit SHA",
    },
    {
        "the session is open to every collaborator",
        function(ci, pub)
            return (ci:gsub("limit%-access%-to%-actor: true", "limit-access-to-actor: false")), pub
        end,
        "limited to the actor",
    },
    {
        "the session runs on every job",
        function(ci, pub)
            return (ci:gsub(" && matrix.tmate == 'on%-failure'", "")), pub
        end,
        "only on a dispatch",
    },
    {
        "a session returns to the release",
        function(ci, pub)
            return ci, pub .. "      - uses: " .. SESSION .. "\n"
        end,
        "a release never opens a debugging session",
    },
    {
        "the tmate options leave off bare",
        function(ci, pub)
            return replaced(
                ci,
                "options: ['off', before-tests, on-failure]",
                "options: [off, before-tests, on-failure]"
            ),
                pub
        end,
        "bare off as its option",
    },
    {
        "the tmate default leaves off bare",
        function(ci, pub)
            return replaced(ci, "default: 'off'", "default: off"), pub
        end,
        "bare off as its default",
    },
    {
        "a dispatch shares its group with the push",
        function(ci, pub)
            local own_group = "github.event_name == 'workflow_dispatch' && github.run_id || "
            return replaced(ci, own_group, ""), pub
        end,
        "a dispatch run must have its own concurrency group",
    },
    {
        "a push no longer cancels its predecessor",
        function(ci, pub)
            return replaced(ci, "cancel-in-progress: true", "cancel-in-progress: false"), pub
        end,
        "must still cancel the run they supersede",
    },
    {
        "the workflow_call scope is optional",
        function(ci, pub)
            return replaced(ci, "        required: true\n", "        required: false\n"), pub
        end,
        "scope input must be required",
    },
    {
        "the release stops calling ci.yml",
        function(ci, pub)
            return ci,
                replaced(
                    pub,
                    "uses: ./.github/workflows/ci.yml",
                    "uses: ./.github/workflows/docs.yml"
                )
        end,
        "validate must call ci.yml",
    },
    {
        "the release asks for the edges",
        function(ci, pub)
            return ci, replaced(pub, "      scope: full", "      scope: edges")
        end,
        "ask for scope full",
    },
    {
        "the upload stops waiting for validation",
        function(ci, pub)
            return ci, replaced(pub, "    needs: validate\n", "")
        end,
        "the upload must wait",
    },
    {
        "the matrix Lua archive is no longer cached",
        function(ci, pub)
            return replaced(ci, "runtimes.lua') }}-${{ matrix.lua }}", "runtimes.lua') }}-lua"), pub
        end,
        "builds the matrix Lua from lua.org",
    },
    {
        "the apt action is called without a commit pin",
        function(ci, pub)
            return (ci:gsub("actions/apt%-get@%x+", "actions/apt-get@main")), pub
        end,
        "must be pinned to a full commit SHA",
    },
    {
        "the tmux action is called without a commit pin",
        function(ci, pub)
            return (ci:gsub("actions/build%-tmux@%x+", "actions/build-tmux@v1")), pub
        end,
        "must be pinned to a full commit SHA",
    },
    {
        "a raw apt-get replaces the action",
        function(ci, pub)
            return replaced(
                ci,
                "      - name: Record tool identities\n",
                "      - run: sudo apt-get update\n      - name: Record tool identities\n"
            ),
                pub
        end,
        "calls apt directly",
    },
}

function M.test_a_mutation_is_reported()
    for _, mutation in ipairs(MUTATIONS) do
        local description, mutate, message = mutation[1], mutation[2], mutation[3]
        local ci, publish = mutate(CI, PUBLISH)
        local matched = false
        for _, reported in ipairs(all_problems(ci, publish)) do
            matched = matched or has(reported, message)
        end
        test.assertTrue(matched, description .. ": nothing reported " .. message)
    end
end

return M
