-- The checks of the CI plan: one function for each rule, named for what it requires.
local S = require("ci_plan.tests.plan_support")
local test = require("luaunit")
local json = require("support.json")
local planner = require("ci_plan.planner")
local MANIFEST = S.MANIFEST
local CATALOG = S.CATALOG
local RELEASED = S.RELEASED
local DEVELOPMENT = S.DEVELOPMENT
local REFUSED = S.REFUSED
local OLDEST = S.OLDEST
local NEWEST = S.NEWEST
local UNIT = S.UNIT
local FULL_SET = S.FULL_SET
local copy = S.copy
local map = S.map
local filter = S.filter
local set = S.set
local field = S.field
local cells = S.cells
local gated = S.gated
local tmux_of = S.tmux_of
local run = S.run
local raises = S.raises
local refused = S.refused
local loaded = S.loaded

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
for name, check in pairs(checks) do
    NAMES[check] = name
end

return { checks = checks, names = NAMES }
