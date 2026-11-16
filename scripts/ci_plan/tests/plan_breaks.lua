-- The deliberate breaks of the CI plan: for each rule a replacement that removes it, and the check
-- that has to notice.
local S = require("ci_plan.tests.plan_support")
local json = require("support.json")
local planner = require("ci_plan.planner")
local REFUSED = S.REFUSED
local OLDEST = S.OLDEST
local NEWEST = S.NEWEST
local RULES = S.RULES
local copy = S.copy
local map = S.map
local filter = S.filter
local checks = require("ci_plan.tests.plan_checks").checks

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

return DELIBERATE_BREAKS
