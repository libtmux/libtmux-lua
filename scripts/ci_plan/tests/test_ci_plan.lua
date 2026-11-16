-- Proves the CI plan picks what each event should run, and that it can fail.
--
-- Every rule has a check, and every check has a deliberate break: the rule is replaced with its
-- absence and the check has to notice. A check that passes with its rule removed would prove
-- nothing about the rule.
local test = require("luaunit")
local cli = require("ci_plan.cli")
local json = require("support.json")
local planner = require("ci_plan.planner")

local MANIFEST = planner.load()
local CATALOG = json.read(planner.CATALOG)
local RELEASED = MANIFEST.released
local DEVELOPMENT = {}
for _, name in ipairs(MANIFEST.table) do
    if MANIFEST.development[name] ~= nil then
        DEVELOPMENT[#DEVELOPMENT + 1] = name
    end
end
local REFUSED = json.keys(MANIFEST.refused)
local OLDEST, NEWEST = RELEASED[1], RELEASED[#RELEASED]
local UNIT = MANIFEST.unit

-- The jobs the full scope runs, in the workflow's order.
local FULL_SET = {
    { "Unit Lua 5.1", "unit", "5.1.5", "", "", "" },
    { "Unit Lua 5.2", "unit", "5.2.4", "", "", "" },
    { "Unit Lua 5.3", "unit", "5.3.6", "", "", "" },
    { "Unit Lua 5.4", "unit", "5.4.9", "", "", "" },
    { "Unit Lua 5.5", "unit", "5.5.1", "", "", "" },
    { "Unit LuaJIT", "unit", "luajit", "", "", "" },
    { "Outer floor", "outer", "5.1.5", "3.3a", "0.10.0", "" },
    { "Outer current", "outer", "5.5.1", "3.7c", "0.12.5", "" },
    { "tmux 3.0a refused", "refusal", "5.5.1", "3.0a", "0.12.5", "3.3a" },
    { "tmux 3.1c refused", "refusal", "5.5.1", "3.1c", "0.12.5", "3.3a" },
    { "tmux 3.2a refused", "refusal", "5.5.1", "3.2a", "0.12.5", "" },
    { "tmux 3.3 refused", "refusal", "5.5.1", "3.3", "0.12.5", "" },
    { "tmux 3.3a", "integration", "5.5.1", "3.3a", "0.12.5", "" },
    { "tmux 3.4", "integration", "5.5.1", "3.4", "0.12.5", "" },
    { "tmux 3.5", "integration", "5.5.1", "3.5", "0.12.5", "" },
    { "tmux 3.5a", "integration", "5.5.1", "3.5a", "0.12.5", "" },
    { "tmux 3.6", "integration", "5.5.1", "3.6", "0.12.5", "" },
    { "tmux 3.6a", "integration", "5.5.1", "3.6a", "0.12.5", "" },
    { "tmux 3.6b", "integration", "5.5.1", "3.6b", "0.12.5", "" },
    { "tmux 3.7", "integration", "5.5.1", "3.7", "0.12.5", "" },
    { "tmux 3.7a", "integration", "5.5.1", "3.7a", "0.12.5", "" },
    { "tmux 3.7b", "integration", "5.5.1", "3.7b", "0.12.5", "" },
    { "tmux 3.7c", "integration", "5.5.1", "3.7c", "0.12.5", "" },
    { "tmux 3.7d", "integration", "5.5.1", "3.7d", "0.12.5", "" },
    { "tmux 3.8", "integration", "5.5.1", "3.8", "0.12.5", "" },
    { "tmux next-3.9", "integration", "5.5.1", "next-3.9", "0.12.5", "" },
}

-- The rules as the module defines them, before any deliberate break.
local RULES = {}
for _, name in ipairs({
    "resolve_scope",
    "tmux_cells",
    "assign_tmate",
    "check_needs",
    "outer_cells",
    "unit_cells",
    "combine",
}) do
    RULES[name] = planner[name]
end

local function copy(source)
    local result = {}
    for key, value in pairs(source) do
        result[key] = value
    end
    return result
end

local function map(list, transform)
    local result = {}
    for index, item in ipairs(list) do
        result[index] = transform(item)
    end
    return result
end

local function filter(list, keep)
    local result = {}
    for _, item in ipairs(list) do
        if keep(item) then
            result[#result + 1] = item
        end
    end
    return result
end

local function set(list)
    local result = {}
    for _, item in ipairs(list) do
        result[item] = true
    end
    return result
end

local function field(name)
    return function(item)
        return item[name]
    end
end

local function cells(result)
    return result.matrix.include
end

local function gated(result, gate)
    return filter(cells(result), function(each)
        return each.gate == gate
    end)
end

local function tmux_of(result, gate)
    return map(gated(result, gate or "integration"), field("tmux"))
end

local function run(event, inputs)
    local all = copy(inputs or {})
    all.event = event
    return planner.plan(MANIFEST, all)
end

-- Runs `action` and fails the check unless it is refused with a message naming the problem.
local function raises(action, match)
    local ok, failure = pcall(action)
    if ok then
        test.fail("the plan was not refused: " .. match)
    end
    if getmetatable(failure) ~= planner.PlanError then
        error(failure, 0)
    end
    test.assertStrContains(failure.message, match)
end

local function refused(match, inputs)
    local all = copy(inputs or {})
    local event = all.event or "workflow_dispatch"
    raises(function()
        return run(event, all)
    end, match)
end

-- The manifest against a catalog that lists exactly `names`, each with a revision.
local function loaded(names, changes)
    local releases = {}
    for _, name in ipairs(names) do
        releases[name] = { revision = "revision-of-" .. name }
    end
    local manifest = json.read(planner.MANIFEST)
    for key, value in pairs(changes or {}) do
        manifest[key] = value
    end
    return planner.combine(manifest, { releases = json.object(names, releases) })
end

local checks = {}

function checks.push_runs_the_edges_only()
    local result = run("push")
    test.assertEquals(result.scope, "edges")
    test.assertEquals(tmux_of(result), { OLDEST, NEWEST })
    test.assertEquals(gated(result, "refusal"), {})
    local planned = set(map(cells(result), field("tmux")))
    for _, name in ipairs(DEVELOPMENT) do
        test.assertNil(planned[name])
    end
    test.assertEquals(map(gated(result, "unit"), field("lua")), UNIT)
end

function checks.pull_request_runs_the_edges_only()
    local result = run("pull_request")
    test.assertEquals(result.scope, "edges")
    test.assertEquals(tmux_of(result), { OLDEST, NEWEST })
    test.assertEquals(gated(result, "refusal"), {})
end

function checks.dispatch_defaults_to_the_edges()
    local result = run("workflow_dispatch")
    test.assertEquals(result.scope, "edges")
    test.assertEquals(tmux_of(result), { OLDEST, NEWEST })
end

function checks.a_schedule_runs_the_full_scope()
    test.assertEquals(run("schedule").scope, "full")
end

function checks.full_runs_the_whole_table()
    local result = run("workflow_dispatch", { scope = "full" })
    test.assertEquals(result.scope, "full")
    test.assertEquals(tmux_of(result), MANIFEST.table)
    test.assertEquals(tmux_of(result, "refusal"), REFUSED)
    test.assertEquals(#gated(result, "unit"), #UNIT)
    test.assertEquals(#gated(result, "outer"), 2)
    test.assertEquals(#cells(result), #UNIT + 2 + #REFUSED + #MANIFEST.table)
    local refusals = gated(result, "refusal")
    test.assertEquals(set(map(refusals, field("client"))), { [""] = true, [OLDEST] = true })
    local old_daemon = filter(REFUSED, function(name)
        return MANIFEST.refused[name].old_daemon
    end)
    test.assertEquals(
        map(
            filter(refusals, function(each)
                return each.client ~= ""
            end),
            field("tmux")
        ),
        old_daemon
    )
end

function checks.full_scope_is_exactly_the_listed_set()
    local full = map(cells(run("workflow_dispatch", { scope = "full" })), function(each)
        return { each.name, each.gate, each.lua, each.tmux, each.nvim, each.client }
    end)
    test.assertEquals(full, FULL_SET)
    test.assertEquals(cells(run("schedule")), cells(run("push", { scope = "full" })))
end

function checks.an_explicit_scope_beats_the_event()
    test.assertEquals(run("push", { scope = "full" }).scope, "full")
    test.assertEquals(
        run("pull_request", { scope = "custom", tmux_ref = "master" }).scope,
        "custom"
    )
end

function checks.the_manifest_alone_decides_the_table()
    local names = copy(MANIFEST.table)
    names[#names + 1] = "4.0"
    local manifest = loaded(names)
    local result = planner.plan(manifest, { event = "push" })
    test.assertEquals(tmux_of(result), { OLDEST, "4.0" })
    test.assertEquals(tmux_of(result, "outer"), { OLDEST, "4.0" })
    local full = tmux_of(planner.plan(manifest, { event = "push", scope = "full" }))
    test.assertEquals(full[#full], "4.0")
end

function checks.a_development_build_is_never_an_edge()
    local names = copy(RELEASED)
    for _, name in ipairs(DEVELOPMENT) do
        names[#names + 1] = name
    end
    local manifest = loaded(names)
    test.assertEquals(manifest.released, RELEASED)
    local planned = tmux_of(planner.plan(manifest, { event = "push" }))
    test.assertEquals(planned, { OLDEST, NEWEST })
    test.assertNil(set(planned)[DEVELOPMENT[#DEVELOPMENT]])
end

function checks.a_single_release_is_one_edge()
    local manifest = loaded({ "3.3a", "next-3.9" }, {
        development = json.object({ "next-3.9" }, { ["next-3.9"] = "master" }),
    })
    test.assertEquals(tmux_of(planner.plan(manifest, { event = "push" })), { "3.3a" })
end

function checks.the_outer_jobs_follow_the_edges()
    for _, result in ipairs({ run("push"), run("pull_request"), run("workflow_dispatch") }) do
        local floor, current = unpack(gated(result, "outer"))
        test.assertEquals({ floor.tmux, current.tmux }, { OLDEST, NEWEST })
    end
    local floor, current = unpack(gated(run("push"), "outer"))
    for _, pair in ipairs({ { floor, "floor" }, { current, "current" } }) do
        local job, role = pair[1], pair[2]
        test.assertEquals(
            { job.lua, job.nvim },
            { MANIFEST.outer[role].lua, MANIFEST.outer[role].nvim }
        )
    end
    test.assertEquals(current.name, "Outer current")
end

function checks.full_scope_keeps_the_outer_current_pin()
    local pin = MANIFEST.outer.current.full_tmux
    test.assertNotEquals(pin, NEWEST)
    local floor, current = unpack(gated(run("workflow_dispatch", { scope = "full" }), "outer"))
    test.assertEquals({ floor.tmux, current.tmux }, { OLDEST, pin })
    local unpinned = copy(MANIFEST)
    unpinned.outer = copy(MANIFEST.outer)
    unpinned.outer.current = copy(MANIFEST.outer.current)
    unpinned.outer.current.full_tmux = nil
    local result = planner.plan(unpinned, { event = "push", scope = "full" })
    test.assertEquals(gated(result, "outer")[2].tmux, NEWEST)
end

function checks.a_scope_must_be_known()
    refused("scope must be one of", { scope = "everything" })
end

function checks.an_unknown_event_is_refused()
    refused("no scope is defined", { event = "release" })
end

function checks.a_ref_list_needs_the_custom_scope()
    refused("only used with scope custom", { scope = "edges", tmux_ref = "master" })
    refused("only used with scope custom", { tmux_ref = "master" })
end

function checks.a_custom_run_needs_refs()
    refused("needs tmux-ref", { scope = "custom" })
    refused("needs tmux-ref", { scope = "custom", tmux_ref = " , " })
end

function checks.every_ref_is_validated()
    for _, ref in ipairs({ "3.6b;id", "-upload-pack=x", "a b", "$(id)", "a..b", "a1b2c3d" }) do
        refused("tmux ref", { scope = "custom", tmux_ref = "master," .. ref })
    end
    for _, ref in ipairs({ "topic.lock", "topic/", ("a"):rep(65) }) do
        refused("tmux ref", { scope = "custom", tmux_ref = ref })
    end
    test.assertEquals(planner.check_ref(("a"):rep(40)), ("a"):rep(40))
    test.assertEquals(planner.check_ref("release/3.7_x-1.0"), "release/3.7_x-1.0")
end

local function topics(count)
    local refs = {}
    for number = 1, count do
        refs[number] = "topic-" .. number
    end
    return table.concat(refs, ",")
end

function checks.too_many_jobs_are_refused()
    local ok, result = pcall(run, "workflow_dispatch", {
        scope = "custom",
        tmux_ref = topics(12),
    })
    test.assertTrue(ok, "twelve jobs fit a custom run")
    test.assertEquals(#cells(result), 12)
    refused("at most", { scope = "custom", tmux_ref = topics(13) })
    refused("at most", {
        scope = "custom",
        tmux_ref = "a,b,c,d",
        lua = "5.1.5,5.5.1",
        nvim = "0.10.0,0.12.5",
    })
end

function checks.custom_names_resolve_to_their_build()
    local sha = ("a"):rep(40)
    local result = run("workflow_dispatch", {
        scope = "custom",
        tmux_ref = ("%s, %s,%s,%s,master,%s,%s"):format(
            OLDEST,
            DEVELOPMENT[1],
            REFUSED[1],
            REFUSED[#REFUSED],
            sha,
            OLDEST
        ),
    })
    test.assertEquals(tmux_of(result, "integration"), { OLDEST, DEVELOPMENT[1], "master", sha })
    test.assertEquals(
        map(cells(result), function(each)
            return { each.tmux, each.gate, each.build }
        end),
        {
            { OLDEST, "integration", "pinned" },
            { DEVELOPMENT[1], "integration", "pinned" },
            { REFUSED[1], "refusal", "pinned" },
            { REFUSED[#REFUSED], "refusal", "pinned" },
            { "master", "integration", "ref" },
            { sha, "integration", "ref" },
        }
    )
    local by_tmux = {}
    for _, each in ipairs(cells(result)) do
        by_tmux[each.tmux] = each
    end
    test.assertEquals(
        { by_tmux[REFUSED[1]].client, by_tmux[REFUSED[#REFUSED]].client },
        { OLDEST, "" }
    )
    test.assertEquals(#gated(result, "unit") + #gated(result, "outer"), 0)
    test.assertEquals(by_tmux.master.name, "tmux master")
end

function checks.stack_inputs_retarget_the_tmux_jobs()
    local result = run("workflow_dispatch", {
        scope = "custom",
        tmux_ref = "master",
        lua = "5.1.5,luajit",
        nvim = "0.10.0",
    })
    test.assertEquals(
        map(cells(result), function(each)
            return { each.lua, each.nvim }
        end),
        { { "5.1.5", "0.10.0" }, { "luajit", "0.10.0" } }
    )
    test.assertEquals(map(cells(result), field("name")), {
        "tmux master (Lua 5.1.5, Neovim 0.10.0)",
        "tmux master (Lua luajit, Neovim 0.10.0)",
    })
    local edges = run("workflow_dispatch", { lua = "5.1.5" })
    test.assertEquals(set(map(gated(edges, "integration"), field("lua"))), { ["5.1.5"] = true })
    test.assertEquals(map(gated(edges, "unit"), field("lua")), UNIT)
    test.assertEquals(
        map(gated(edges, "outer"), field("lua")),
        { MANIFEST.outer.floor.lua, MANIFEST.outer.current.lua }
    )
end

function checks.an_unknown_stack_version_is_refused()
    refused("lua must name versions", { scope = "custom", tmux_ref = "master", lua = "5.0.3" })
    refused("nvim must name versions", { scope = "custom", tmux_ref = "master", nvim = "0.1.0" })
end

function checks.the_runner_is_chosen_from_the_images()
    test.assertEquals(run("push").os, planner.RUNNERS[1])
    test.assertEquals(run("workflow_dispatch", { image = "ubuntu-latest" }).os, "ubuntu-latest")
    refused("os must be one of", { image = "macos-latest" })
end

function checks.one_job_gets_the_debug_session()
    for _, mode in ipairs({ "before-tests", "on-failure" }) do
        local result =
            run("workflow_dispatch", { scope = "custom", tmux_ref = "master", tmate = mode })
        test.assertEquals(map(cells(result), field("tmate")), { mode })
    end
end

function checks.no_debug_session_by_default()
    for _, result in ipairs({
        run("push"),
        run("workflow_dispatch", { scope = "full" }),
        run("workflow_dispatch", { scope = "custom", tmux_ref = "master", tmate = "off" }),
    }) do
        test.assertEquals(set(map(cells(result), field("tmate"))), { off = true })
    end
end

function checks.several_jobs_cannot_share_a_debug_session()
    refused("exactly one job", { tmate = "on-failure" })
    refused("exactly one job", { scope = "full", tmate = "before-tests" })
    refused("exactly one job", { scope = "custom", tmux_ref = "master,3.8", tmate = "on-failure" })
    refused("exactly one job", {
        scope = "custom",
        tmux_ref = "master",
        lua = "5.1.5,5.5.1",
        tmate = "on-failure",
    })
end

function checks.a_debug_session_needs_a_dispatch()
    for _, event in ipairs({ "push", "pull_request" }) do
        refused("only available on a workflow_dispatch", {
            event = event,
            scope = "custom",
            tmux_ref = "master",
            tmate = "on-failure",
        })
    end
end

function checks.a_debug_mode_must_be_known()
    refused("tmate must be one of", { scope = "custom", tmux_ref = "master", tmate = "always" })
end

function checks.the_job_count_adds_up()
    for _, result in ipairs({
        run("push"),
        run("workflow_dispatch", { scope = "full" }),
        run("workflow_dispatch", { scope = "custom", tmux_ref = "master,3.8" }),
    }) do
        test.assertEquals(result.expected_jobs, #cells(result) + 2)
    end
    test.assertEquals(run("push").expected_jobs, #UNIT + 2 + 2 + 2)
end

function checks.the_matrix_is_never_empty()
    raises(function()
        planner.require_cells({})
    end, "no job")
end

function checks.job_names_follow_the_plan()
    local expected = {
        plan = true,
        required = true,
        ["Unit LuaJIT"] = true,
        ["Outer floor"] = true,
        ["Outer current"] = true,
        ["tmux " .. OLDEST] = true,
        ["tmux " .. NEWEST] = true,
    }
    for number = 1, 5 do
        expected["Unit Lua 5." .. number] = true
    end
    test.assertEquals(planner.job_names(run("push")), expected)
end

function checks.the_manifest_must_be_consistent()
    local development = json.object({ "next-3.9" }, { ["next-3.9"] = "master" })
    raises(function()
        loaded({ "3.3a", "3.8" }, { development = development })
    end, "not in the catalog")
    raises(function()
        loaded({ "next-3.9" }, { development = development })
    end, "no released version")
    raises(function()
        local manifest = json.read(planner.MANIFEST)
        manifest.development = development
        planner.combine(manifest, {
            releases = json.object({ "3.3a", "next-3.9" }, { ["3.3a"] = {}, ["next-3.9"] = {} }),
        })
    end, "has no revision")
end

function checks.the_required_check_needs_the_plan_and_the_matrix()
    local good = { plan = { result = "success" }, validate = { result = "success" } }
    test.assertEquals(planner.check_needs(good), {})
    for _, job in ipairs({ "plan", "validate" }) do
        for _, result in ipairs({ "failure", "cancelled", "skipped" }) do
            local bad = copy(good)
            bad[job] = { result = result }
            test.assertTrue(#planner.check_needs(bad) > 0, job .. " " .. result)
        end
        local missing = copy(good)
        missing[job] = nil
        test.assertTrue(#planner.check_needs(missing) > 0, job)
    end
end

function checks.every_cell_has_a_string_ref()
    for _, result in ipairs({
        run("push"),
        run("workflow_dispatch", { scope = "full" }),
        run("workflow_dispatch", { scope = "custom", tmux_ref = "master," .. REFUSED[1] }),
    }) do
        for _, each in ipairs(cells(result)) do
            test.assertEquals(type(each.ref), "string", each.name)
            if each.gate == "unit" then
                test.assertEquals(each.ref, "")
            else
                test.assertNotEquals(each.ref, "", each.name)
            end
        end
    end
end

function checks.a_development_build_is_pinned_to_its_catalog_revision()
    local full = run("workflow_dispatch", { scope = "full" })
    for _, name in ipairs(DEVELOPMENT) do
        local revision = CATALOG.releases[name].revision
        test.assertNotEquals(revision, name)
        local planned = filter(cells(full), function(each)
            return each.tmux == name
        end)
        test.assertEquals(map(planned, field("ref")), { revision })
        test.assertEquals(planned[1].build, "pinned")
    end
    local custom = run("workflow_dispatch", { scope = "custom", tmux_ref = DEVELOPMENT[1] })
    test.assertEquals(
        map(cells(custom), field("ref")),
        { CATALOG.releases[DEVELOPMENT[1]].revision }
    )

    local pinned = copy(MANIFEST)
    pinned.outer = copy(MANIFEST.outer)
    pinned.outer.current = copy(MANIFEST.outer.current)
    pinned.outer.current.full_tmux = DEVELOPMENT[#DEVELOPMENT]
    local outer = gated(planner.plan(pinned, { event = "push", scope = "full" }), "outer")
    test.assertEquals(outer[2].ref, CATALOG.releases[DEVELOPMENT[#DEVELOPMENT]].revision)
end

function checks.a_released_or_refused_build_is_its_own_ref()
    local full = cells(run("workflow_dispatch", { scope = "full" }))
    local seen = 0
    for _, each in ipairs(full) do
        if each.gate ~= "unit" and MANIFEST.development[each.tmux] == nil then
            test.assertEquals(each.ref, each.tmux, each.name)
            seen = seen + 1
        end
    end
    test.assertEquals(seen, #full - #UNIT - #DEVELOPMENT)
    for _, name in ipairs(REFUSED) do
        test.assertNotEquals(MANIFEST.refused[name].revision, name)
    end
end

function checks.a_custom_ref_is_passed_as_given()
    local sha = ("b"):rep(40)
    local result = run("workflow_dispatch", {
        scope = "custom",
        tmux_ref = "master,release/3.7,v1.0_rc," .. sha,
        lua = "5.1.5,luajit",
    })
    for _, each in ipairs(cells(result)) do
        test.assertEquals(each.build, "ref")
        test.assertEquals(each.ref, each.tmux)
    end
    test.assertEquals(#cells(result), 8)
end

local NAMES = {}
local M = {}
for name, check in pairs(checks) do
    NAMES[check] = name
    M["test_" .. name] = check
end

local function sorted_names(allowed)
    local names = {}
    for check, name in pairs(NAMES) do
        if allowed(check) then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

local function every_edge(released)
    return copy(released)
end

local function hard_coded()
    return { OLDEST, NEWEST }
end

local function resolving(scope)
    return function()
        return scope
    end
end

local function pull_requests_run_everything(event, scope)
    return event == "pull_request" and "full" or RULES.resolve_scope(event, scope)
end

local function schedules_run_the_edges(event, scope)
    return event == "schedule" and "edges" or RULES.resolve_scope(event, scope)
end

local function ignoring_the_given_scope(event)
    return RULES.resolve_scope(event, "")
end

local function unchecked_scope(_, scope)
    return scope ~= "" and scope or "edges"
end

local function unchecked_event(_, scope)
    for _, known in ipairs(planner.SCOPES) do
        if known == scope then
            return scope
        end
    end
    return "edges"
end

local function stale_outer(manifest)
    local result = {}
    for _, role in ipairs({ "floor", "current" }) do
        local pair = manifest.outer[role]
        result[#result + 1] = planner.cell({
            name = "Outer " .. role,
            gate = "outer",
            lua = pair.lua,
            tmux = "3.7c",
            nvim = pair.nvim,
            build = "pinned",
            ref = "3.7c",
        })
    end
    return result
end

local function outer_ignoring_the_scope(manifest, _, oldest, newest)
    return RULES.outer_cells(manifest, "edges", oldest, newest)
end

local function outer_always_pinned(manifest, _, oldest, newest)
    return RULES.outer_cells(manifest, "full", oldest, newest)
end

local function outer_without_a_ref(manifest, scope, oldest, newest)
    return map(RULES.outer_cells(manifest, scope, oldest, newest), function(each)
        local bare = copy(each)
        bare.ref = ""
        return bare
    end)
end

local function full_without_development(manifest, versions, luas, nvims)
    return filter(RULES.tmux_cells(manifest, versions, luas, nvims), function(each)
        return manifest.development[each.tmux] == nil
    end)
end

local function full_without_a_unit_job(manifest)
    local result = RULES.unit_cells(manifest)
    result[#result] = nil
    return result
end

local function units_without_a_ref(manifest)
    return map(RULES.unit_cells(manifest), function(each)
        local bare = copy(each)
        bare.ref = nil
        return bare
    end)
end

local function edges_with_refusals(released)
    return { released[1], released[#released], unpack(REFUSED) }
end

local function refusals_dropped(manifest, versions, luas, nvims)
    local dropped = true
    for _, name in ipairs(versions) do
        dropped = dropped and manifest.refused[name] ~= nil
    end
    if dropped and #versions == #REFUSED then
        return {}
    end
    return RULES.tmux_cells(manifest, versions, luas, nvims)
end

local function always_integration(manifest, versions, luas, nvims)
    local plain = copy(manifest)
    plain.refused = {}
    return RULES.tmux_cells(plain, versions, luas, nvims)
end

local function rebuilt(change)
    return function(manifest, versions, luas, nvims)
        return map(RULES.tmux_cells(manifest, versions, luas, nvims), function(each)
            local changed = copy(each)
            change(changed, manifest)
            return changed
        end)
    end
end

local always_pinned = rebuilt(function(each)
    each.build = "pinned"
end)

local never_pinned = rebuilt(function(each)
    each.build = "ref"
end)

local without_a_client = rebuilt(function(each)
    each.client = ""
end)

local development_from_its_name = rebuilt(function(each, manifest)
    if manifest.development[each.tmux] ~= nil then
        each.ref = each.tmux
    end
end)

local refusals_from_their_revision = rebuilt(function(each, manifest)
    if each.gate == "refusal" then
        each.ref = manifest.refused[each.tmux].revision
    end
end)

local custom_refs_dropped = rebuilt(function(each)
    if each.build == "ref" then
        each.ref = ""
    end
end)

local function custom_without_a_requirement(tmux_ref)
    local items = planner.split_list(tmux_ref)
    return #items > 0 and items or { "master" }
end

local function unvalidated(ref)
    return ref
end

local function ignored() end

local function default_stack(_, _, default)
    return { default }
end

local function unchecked_stack(requested, _, default)
    local chosen = planner.split_list(requested)
    return #chosen > 0 and chosen or { default }
end

local function any_image(image)
    return image ~= "" and image or planner.RUNNERS[1]
end

local function default_image()
    return planner.RUNNERS[1]
end

local function debug_session_everywhere(_, mode, planned)
    for _, each in ipairs(planned) do
        each.tmate = mode
    end
end

local function debug_session_without_event(_, mode, planned)
    RULES.assign_tmate("workflow_dispatch", mode, planned)
end

local function debug_session_on_the_first_job(_, mode, planned)
    if mode ~= "off" then
        planned[1].tmate = mode
    end
end

local function unchecked_mode(event, mode, planned)
    for _, known in ipairs(planner.TMATE_MODES) do
        if known == mode then
            return RULES.assign_tmate(event, mode, planned)
        end
    end
    if #planned == 1 then
        planned[1].tmate = mode
    end
end

local function gate_without(prefix)
    return function(needs)
        return filter(RULES.check_needs(needs), function(problem)
            return problem:sub(1, #prefix) ~= prefix
        end)
    end
end

local function gate_that_accepts_a_skip(needs)
    local relaxed = {}
    for job, value in pairs(needs) do
        relaxed[job] = { result = value.result == "skipped" and "success" or value.result }
    end
    return RULES.check_needs(relaxed)
end

local function unfiltered_combine(manifest, catalog)
    local names = json.keys(catalog.releases)
    local combined = { table = names, released = names, revisions = {} }
    for key, value in pairs(manifest) do
        combined[key] = value
    end
    return combined
end

local function trusting_unknown_builds(manifest, catalog)
    local names = json.keys(catalog.releases)
    local released = filter(names, function(name)
        return manifest.development[name] == nil
    end)
    local combined = { table = names, released = released, revisions = {} }
    for key, value in pairs(manifest) do
        combined[key] = value
    end
    return combined
end

local function unrevisioned_combine(manifest, catalog)
    local filled = {}
    for name, release in pairs(catalog.releases) do
        filled[name] = { revision = release.revision or name }
    end
    return RULES.combine(manifest, { releases = json.object(json.keys(catalog.releases), filled) })
end

-- Each break is { description, rule, replacement, check }: with the rule replaced, the check
-- must fail.
local DELIBERATE_BREAKS = {
    {
        "the edges rule takes every version",
        "edge_versions",
        every_edge,
        checks.push_runs_the_edges_only,
    },
    {
        "the edges are written into the plan",
        "edge_versions",
        hard_coded,
        checks.the_manifest_alone_decides_the_table,
    },
    {
        "the edges run the refusal jobs",
        "edge_versions",
        edges_with_refusals,
        checks.push_runs_the_edges_only,
    },
    {
        "a development build can be an edge",
        "combine",
        unfiltered_combine,
        checks.a_development_build_is_never_an_edge,
    },
    {
        "a manifest outside the catalog is trusted",
        "combine",
        trusting_unknown_builds,
        checks.the_manifest_must_be_consistent,
    },
    {
        "a development build without a revision is accepted",
        "combine",
        unrevisioned_combine,
        checks.the_manifest_must_be_consistent,
    },
    {
        "a pull request runs the full scope",
        "resolve_scope",
        pull_requests_run_everything,
        checks.pull_request_runs_the_edges_only,
    },
    {
        "a dispatch ignores the scope it was given",
        "resolve_scope",
        ignoring_the_given_scope,
        checks.full_runs_the_whole_table,
    },
    {
        "a given scope loses to the event",
        "resolve_scope",
        ignoring_the_given_scope,
        checks.an_explicit_scope_beats_the_event,
    },
    {
        "a dispatch does not default to the edges",
        "resolve_scope",
        resolving("full"),
        checks.dispatch_defaults_to_the_edges,
    },
    {
        "a schedule runs the edges",
        "resolve_scope",
        schedules_run_the_edges,
        checks.a_schedule_runs_the_full_scope,
    },
    {
        "an unknown scope is accepted",
        "resolve_scope",
        unchecked_scope,
        checks.a_scope_must_be_known,
    },
    {
        "an unknown event is accepted",
        "resolve_scope",
        unchecked_event,
        checks.an_unknown_event_is_refused,
    },
    {
        "the outer jobs keep a stale tmux",
        "outer_cells",
        stale_outer,
        checks.the_outer_jobs_follow_the_edges,
    },
    {
        "the full scope moves the current outer job to the edge",
        "outer_cells",
        outer_ignoring_the_scope,
        checks.full_scope_keeps_the_outer_current_pin,
    },
    {
        "the full scope moves a cell of the full set",
        "outer_cells",
        outer_ignoring_the_scope,
        checks.full_scope_is_exactly_the_listed_set,
    },
    {
        "a push keeps the pinned outer job",
        "outer_cells",
        outer_always_pinned,
        checks.the_outer_jobs_follow_the_edges,
    },
    {
        "the outer jobs carry no ref",
        "outer_cells",
        outer_without_a_ref,
        checks.every_cell_has_a_string_ref,
    },
    {
        "the full scope drops the development builds",
        "tmux_cells",
        full_without_development,
        checks.full_scope_is_exactly_the_listed_set,
    },
    {
        "the full scope drops a unit job",
        "unit_cells",
        full_without_a_unit_job,
        checks.full_scope_is_exactly_the_listed_set,
    },
    {
        "a unit job has no ref",
        "unit_cells",
        units_without_a_ref,
        checks.every_cell_has_a_string_ref,
    },
    {
        "the full scope drops its refusal jobs",
        "tmux_cells",
        refusals_dropped,
        checks.full_runs_the_whole_table,
    },
    {
        "a refused release runs the integration suite",
        "tmux_cells",
        always_integration,
        checks.custom_names_resolve_to_their_build,
    },
    {
        "a custom ref is always pinned",
        "tmux_cells",
        always_pinned,
        checks.custom_names_resolve_to_their_build,
    },
    {
        "a table release is built as a ref",
        "tmux_cells",
        never_pinned,
        checks.custom_names_resolve_to_their_build,
    },
    {
        "an old-daemon refusal has no client",
        "tmux_cells",
        without_a_client,
        checks.full_runs_the_whole_table,
    },
    {
        "a development build is built from its name",
        "tmux_cells",
        development_from_its_name,
        checks.a_development_build_is_pinned_to_its_catalog_revision,
    },
    {
        "a refused release is built from its recorded revision",
        "tmux_cells",
        refusals_from_their_revision,
        checks.a_released_or_refused_build_is_its_own_ref,
    },
    {
        "a custom ref is dropped",
        "tmux_cells",
        custom_refs_dropped,
        checks.a_custom_ref_is_passed_as_given,
    },
    {
        "a development outer job is built from its name",
        "pinned_ref",
        function(_, version)
            return version
        end,
        checks.a_development_build_is_pinned_to_its_catalog_revision,
    },
    {
        "a custom run without refs is planned",
        "custom_refs",
        custom_without_a_requirement,
        checks.a_custom_run_needs_refs,
    },
    {
        "refs the scope ignores are accepted",
        "check_scope_inputs",
        ignored,
        checks.a_ref_list_needs_the_custom_scope,
    },
    {
        "a ref is not validated",
        "check_ref",
        unvalidated,
        checks.every_ref_is_validated,
    },
    {
        "the job count is unlimited",
        "MAX_CUSTOM_LEGS",
        1000,
        checks.too_many_jobs_are_refused,
    },
    {
        "the job limit refuses its own count",
        "MAX_CUSTOM_LEGS",
        11,
        checks.too_many_jobs_are_refused,
    },
    {
        "the stack inputs are ignored",
        "select_stack",
        default_stack,
        checks.stack_inputs_retarget_the_tmux_jobs,
    },
    {
        "an unknown stack version is accepted",
        "select_stack",
        unchecked_stack,
        checks.an_unknown_stack_version_is_refused,
    },
    {
        "the os input is ignored",
        "choose_image",
        default_image,
        checks.the_runner_is_chosen_from_the_images,
    },
    {
        "an unknown os is accepted",
        "choose_image",
        any_image,
        checks.the_runner_is_chosen_from_the_images,
    },
    {
        "no job gets the debug session",
        "assign_tmate",
        ignored,
        checks.one_job_gets_the_debug_session,
    },
    {
        "every job gets the debug session",
        "assign_tmate",
        debug_session_everywhere,
        checks.several_jobs_cannot_share_a_debug_session,
    },
    {
        "the debug session lands on the first of many jobs",
        "assign_tmate",
        debug_session_on_the_first_job,
        checks.several_jobs_cannot_share_a_debug_session,
    },
    {
        "the debug session runs outside a dispatch",
        "assign_tmate",
        debug_session_without_event,
        checks.a_debug_session_needs_a_dispatch,
    },
    {
        "an unknown debug mode is accepted",
        "assign_tmate",
        unchecked_mode,
        checks.a_debug_mode_must_be_known,
    },
    {
        "the job count omits the fixed jobs",
        "FIXED_JOBS",
        0,
        checks.the_job_count_adds_up,
    },
    {
        "an empty matrix is emitted",
        "require_cells",
        ignored,
        checks.the_matrix_is_never_empty,
    },
    {
        "the job names omit the matrix",
        "job_names",
        function()
            return { plan = true }
        end,
        checks.job_names_follow_the_plan,
    },
    {
        "the required check ignores the plan",
        "check_needs",
        gate_without("plan"),
        checks.the_required_check_needs_the_plan_and_the_matrix,
    },
    {
        "the required check ignores the matrix",
        "check_needs",
        gate_without("validate"),
        checks.the_required_check_needs_the_plan_and_the_matrix,
    },
    {
        "the required check accepts a skip",
        "check_needs",
        gate_that_accepts_a_skip,
        checks.the_required_check_needs_the_plan_and_the_matrix,
    },
}

-- Reports whether `check` fails, as opposed to passing or breaking for another reason.
local function fails(check)
    local ok, failure = pcall(check)
    if ok then
        return false
    end
    if type(failure) == "string" and failure:find(test.FAILURE_PREFIX, 1, true) then
        return true
    end
    error(failure, 0)
end

local function fails_with_rule_replaced(rule, replacement, check)
    local original = planner[rule]
    planner[rule] = replacement
    local ok, result = pcall(fails, check)
    planner[rule] = original
    if not ok then
        error(result, 0)
    end
    return result
end

for index, each in ipairs(DELIBERATE_BREAKS) do
    local description, rule, replacement, check = unpack(each)
    local slug = description:lower():gsub("[^%w]+", "_")
    M[("test_break_%02d_%s"):format(index, slug)] = function()
        test.assertNotNil(planner[rule], rule)
        check()
        test.assertTrue(fails_with_rule_replaced(rule, replacement, check), description)
    end
end

function M.test_every_check_has_a_deliberate_break()
    local broken = {}
    for _, each in ipairs(DELIBERATE_BREAKS) do
        broken[each[4]] = true
    end
    -- These state a default or a boundary that no single removal can reach.
    test.assertEquals(
        sorted_names(function(check)
            return not broken[check]
        end),
        { "a_single_release_is_one_edge", "no_debug_session_by_default" }
    )
end

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
