"""Prove the CI plan picks what each event should run, and that it can fail.

Every rule has a check, and every check has a deliberate break: the rule is
replaced with its absence and the check has to notice. A check that passes
with its rule removed would prove nothing about the rule.
"""

import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from scripts import ci_plan

MANIFEST = ci_plan.load()
RELEASED = MANIFEST["released"]
DEVELOPMENT = [name for name in MANIFEST["table"] if name not in RELEASED]
REFUSED = list(MANIFEST["refused"])
OLDEST, NEWEST = RELEASED[0], RELEASED[-1]
UNIT = MANIFEST["unit"]

# The jobs the workflow ran before the plan, in its order, as (name, gate, lua, tmux, nvim, client).
OLD_FULL_SET = [
    ('Unit Lua 5.1', 'unit', '5.1.5', '', '', ''),
    ('Unit Lua 5.2', 'unit', '5.2.4', '', '', ''),
    ('Unit Lua 5.3', 'unit', '5.3.6', '', '', ''),
    ('Unit Lua 5.4', 'unit', '5.4.9', '', '', ''),
    ('Unit Lua 5.5', 'unit', '5.5.1', '', '', ''),
    ('Unit LuaJIT', 'unit', 'luajit', '', '', ''),
    ('Outer floor', 'outer', '5.1.5', '3.3a', '0.10.0', ''),
    ('Outer current', 'outer', '5.5.1', '3.7c', '0.12.5', ''),
    ('tmux 3.0a refused', 'refusal', '5.5.1', '3.0a', '0.12.5', '3.3a'),
    ('tmux 3.1c refused', 'refusal', '5.5.1', '3.1c', '0.12.5', '3.3a'),
    ('tmux 3.2a refused', 'refusal', '5.5.1', '3.2a', '0.12.5', ''),
    ('tmux 3.3 refused', 'refusal', '5.5.1', '3.3', '0.12.5', ''),
    ('tmux 3.3a', 'integration', '5.5.1', '3.3a', '0.12.5', ''),
    ('tmux 3.4', 'integration', '5.5.1', '3.4', '0.12.5', ''),
    ('tmux 3.5', 'integration', '5.5.1', '3.5', '0.12.5', ''),
    ('tmux 3.5a', 'integration', '5.5.1', '3.5a', '0.12.5', ''),
    ('tmux 3.6', 'integration', '5.5.1', '3.6', '0.12.5', ''),
    ('tmux 3.6a', 'integration', '5.5.1', '3.6a', '0.12.5', ''),
    ('tmux 3.6b', 'integration', '5.5.1', '3.6b', '0.12.5', ''),
    ('tmux 3.7', 'integration', '5.5.1', '3.7', '0.12.5', ''),
    ('tmux 3.7a', 'integration', '5.5.1', '3.7a', '0.12.5', ''),
    ('tmux 3.7b', 'integration', '5.5.1', '3.7b', '0.12.5', ''),
    ('tmux 3.7c', 'integration', '5.5.1', '3.7c', '0.12.5', ''),
    ('tmux 3.7d', 'integration', '5.5.1', '3.7d', '0.12.5', ''),
    ('tmux 3.8', 'integration', '5.5.1', '3.8', '0.12.5', ''),
    ('tmux next-3.9', 'integration', '5.5.1', 'next-3.9', '0.12.5', ''),
]

# The rules as the module defines them, before any deliberate break.
RULES = {name: getattr(ci_plan, name)
         for name in ("resolve_scope", "tmux_cells", "assign_tmate", "check_needs", "outer_cells", "unit_cells")}


def cells(result):
    return result["matrix"]["include"]


def gated(result, gate):
    return [each for each in cells(result) if each["gate"] == gate]


def tmux_of(result, gate="integration"):
    return [each["tmux"] for each in gated(result, gate)]


def run(event, **inputs):
    return ci_plan.plan(MANIFEST, event=event, **inputs)


def refused(test, match, event="workflow_dispatch", **inputs):
    """Fail the check unless the plan is refused with a message naming the problem."""
    try:
        run(event, **inputs)
    except ci_plan.PlanError as error:
        test.assertRegex(str(error), match)
        return
    test.fail(f"the plan was not refused: {match}")


def loaded(table, **changes):
    """Load the manifest against a catalog that lists exactly `table`."""
    with tempfile.TemporaryDirectory(prefix="libtmux-lua-plan-") as directory:
        catalog = Path(directory) / "catalog.json"
        catalog.write_text(json.dumps({"releases": {name: {} for name in table}}))
        manifest = Path(directory) / "manifest.json"
        manifest.write_text(json.dumps({**json.loads((ROOT / "data/ci-matrix.json").read_text()), **changes}))
        return ci_plan.load(manifest, catalog)


def check_push_runs_the_edges_only(test):
    result = run("push")
    test.assertEqual(result["scope"], "edges")
    test.assertEqual(tmux_of(result), [OLDEST, NEWEST])
    test.assertEqual(gated(result, "refusal"), [])
    for name in DEVELOPMENT:
        test.assertNotIn(name, [each["tmux"] for each in cells(result)])
    test.assertEqual([each["lua"] for each in gated(result, "unit")], UNIT)


def check_pull_request_runs_the_edges_only(test):
    result = run("pull_request")
    test.assertEqual(result["scope"], "edges")
    test.assertEqual(tmux_of(result), [OLDEST, NEWEST])
    test.assertEqual(gated(result, "refusal"), [])


def check_dispatch_defaults_to_the_edges(test):
    result = run("workflow_dispatch")
    test.assertEqual(result["scope"], "edges")
    test.assertEqual(tmux_of(result), [OLDEST, NEWEST])


def check_a_schedule_runs_the_full_scope(test):
    test.assertEqual(run("schedule")["scope"], "full")


def check_full_runs_the_whole_table(test):
    result = run("workflow_dispatch", scope="full")
    test.assertEqual(result["scope"], "full")
    test.assertEqual(tmux_of(result), MANIFEST["table"])
    test.assertEqual(tmux_of(result, "refusal"), REFUSED)
    test.assertEqual(len(gated(result, "unit")), len(UNIT))
    test.assertEqual(len(gated(result, "outer")), 2)
    test.assertEqual(len(cells(result)), len(UNIT) + 2 + len(REFUSED) + len(MANIFEST["table"]))
    test.assertEqual({each["client"] for each in gated(result, "refusal")}, {"", OLDEST})
    test.assertEqual([each["tmux"] for each in gated(result, "refusal") if each["client"]],
                     [name for name, lane in MANIFEST["refused"].items() if lane["old_daemon"]])


def check_full_scope_is_exactly_the_old_set(test):
    full = [(each["name"], each["gate"], each["lua"], each["tmux"], each["nvim"], each["client"])
            for each in cells(run("workflow_dispatch", scope="full"))]
    test.assertEqual(full, OLD_FULL_SET)
    test.assertEqual(cells(run("schedule")), cells(run("push", scope="full")))


def check_an_explicit_scope_beats_the_event(test):
    test.assertEqual(run("push", scope="full")["scope"], "full")
    test.assertEqual(run("pull_request", scope="custom", tmux_ref="master")["scope"], "custom")


def check_the_manifest_alone_decides_the_table(test):
    manifest = loaded([*MANIFEST["table"], "4.0"])
    result = ci_plan.plan(manifest, event="push")
    test.assertEqual(tmux_of(result), [OLDEST, "4.0"])
    test.assertEqual([each["tmux"] for each in gated(result, "outer")], [OLDEST, "4.0"])
    test.assertEqual(tmux_of(ci_plan.plan(manifest, event="push", scope="full"))[-1], "4.0")


def check_a_development_build_is_never_an_edge(test):
    manifest = loaded([*RELEASED, *DEVELOPMENT])
    test.assertEqual(manifest["released"], RELEASED)
    test.assertEqual(tmux_of(ci_plan.plan(manifest, event="push")), [OLDEST, NEWEST])
    test.assertNotIn(DEVELOPMENT[-1], tmux_of(ci_plan.plan(manifest, event="push")))


def check_a_single_release_is_one_edge(test):
    manifest = loaded(["3.3a", "next-3.9"], development={"next-3.9": "master"})
    test.assertEqual(tmux_of(ci_plan.plan(manifest, event="push")), ["3.3a"])


def check_the_outer_jobs_follow_the_edges(test):
    for result in (run("push"), run("pull_request"), run("workflow_dispatch")):
        floor, current = gated(result, "outer")
        test.assertEqual((floor["tmux"], current["tmux"]), (OLDEST, NEWEST))
    result = run("push")
    floor, current = gated(result, "outer")
    for job, role in ((floor, "floor"), (current, "current")):
        test.assertEqual((job["lua"], job["nvim"]),
                         (MANIFEST["outer"][role]["lua"], MANIFEST["outer"][role]["nvim"]))
    test.assertEqual(current["name"], "Outer current")


def check_full_scope_keeps_the_outer_current_pin(test):
    pin = MANIFEST["outer"]["current"]["full_tmux"]
    test.assertNotEqual(pin, NEWEST)
    result = run("workflow_dispatch", scope="full")
    floor, current = gated(result, "outer")
    test.assertEqual((floor["tmux"], current["tmux"]), (OLDEST, pin))
    unpinned = {**MANIFEST, "outer": {**MANIFEST["outer"], "current": {
        key: value for key, value in MANIFEST["outer"]["current"].items() if key != "full_tmux"}}}
    test.assertEqual(gated(ci_plan.plan(unpinned, event="push", scope="full"), "outer")[1]["tmux"], NEWEST)


def check_a_scope_must_be_known(test):
    refused(test, "scope must be one of", scope="everything")


def check_an_unknown_event_is_refused(test):
    refused(test, "no scope is defined", event="release")


def check_a_ref_list_needs_the_custom_scope(test):
    refused(test, "only used with scope custom", scope="edges", tmux_ref="master")
    refused(test, "only used with scope custom", tmux_ref="master")


def check_a_custom_run_needs_refs(test):
    refused(test, "needs tmux-ref", scope="custom")
    refused(test, "needs tmux-ref", scope="custom", tmux_ref=" , ")


def check_every_ref_is_validated(test):
    for ref in ("3.6b;id", "-upload-pack=x", "a b", "$(id)", "a..b", "a1b2c3d"):
        refused(test, "tmux ref", scope="custom", tmux_ref=f"master,{ref}")


def check_too_many_jobs_are_refused(test):
    refs = ",".join(f"topic-{number}" for number in range(ci_plan.MAX_CUSTOM_LEGS + 1))
    refused(test, "at most", scope="custom", tmux_ref=refs)
    refused(test, "at most", scope="custom", tmux_ref="a,b,c,d", lua="5.1.5,5.5.1", nvim="0.10.0,0.12.5")


def check_custom_names_resolve_to_their_build(test):
    sha = "a" * 40
    result = run("workflow_dispatch", scope="custom",
                 tmux_ref=f"{OLDEST}, {DEVELOPMENT[0]},{REFUSED[0]},{REFUSED[-1]},master,{sha},{OLDEST}")
    by_tmux = {each["tmux"]: each for each in cells(result)}
    test.assertEqual(list(by_tmux), [OLDEST, DEVELOPMENT[0], REFUSED[0], REFUSED[-1], "master", sha])
    test.assertEqual([(each["gate"], each["build"]) for each in by_tmux.values()],
                     [("integration", "pinned"), ("integration", "pinned"), ("refusal", "pinned"),
                      ("refusal", "pinned"), ("integration", "ref"), ("integration", "ref")])
    test.assertEqual((by_tmux[REFUSED[0]]["client"], by_tmux[REFUSED[-1]]["client"]), (OLDEST, ""))
    test.assertEqual({each["gate"] for each in cells(result)} & {"unit", "outer"}, set())
    test.assertEqual(by_tmux["master"]["name"], "tmux master")


def check_stack_inputs_retarget_the_tmux_jobs(test):
    result = run("workflow_dispatch", scope="custom", tmux_ref="master", lua="5.1.5,luajit", nvim="0.10.0")
    test.assertEqual([(each["lua"], each["nvim"]) for each in cells(result)],
                     [("5.1.5", "0.10.0"), ("luajit", "0.10.0")])
    test.assertEqual([each["name"] for each in cells(result)],
                     ["tmux master (Lua 5.1.5, Neovim 0.10.0)", "tmux master (Lua luajit, Neovim 0.10.0)"])
    edges = run("workflow_dispatch", lua="5.1.5")
    test.assertEqual({each["lua"] for each in gated(edges, "integration")}, {"5.1.5"})
    test.assertEqual([each["lua"] for each in gated(edges, "unit")], UNIT)
    test.assertEqual([each["lua"] for each in gated(edges, "outer")],
                     [MANIFEST["outer"]["floor"]["lua"], MANIFEST["outer"]["current"]["lua"]])


def check_an_unknown_stack_version_is_refused(test):
    refused(test, "lua must name versions", scope="custom", tmux_ref="master", lua="5.0.3")
    refused(test, "nvim must name versions", scope="custom", tmux_ref="master", nvim="0.1.0")


def check_the_runner_is_chosen_from_the_images(test):
    test.assertEqual(run("push")["os"], ci_plan.RUNNERS[0])
    test.assertEqual(run("workflow_dispatch", image="ubuntu-latest")["os"], "ubuntu-latest")
    refused(test, "os must be one of", image="macos-latest")


def check_one_job_gets_the_debug_session(test):
    for mode in ("before-tests", "on-failure"):
        result = run("workflow_dispatch", scope="custom", tmux_ref="master", tmate=mode)
        test.assertEqual([each["tmate"] for each in cells(result)], [mode])


def check_no_debug_session_by_default(test):
    for result in (run("push"), run("workflow_dispatch", scope="full"),
                   run("workflow_dispatch", scope="custom", tmux_ref="master", tmate="off")):
        test.assertEqual({each["tmate"] for each in cells(result)}, {"off"})


def check_several_jobs_cannot_share_a_debug_session(test):
    refused(test, "exactly one job", tmate="on-failure")
    refused(test, "exactly one job", scope="full", tmate="before-tests")
    refused(test, "exactly one job", scope="custom", tmux_ref="master,3.8", tmate="on-failure")
    refused(test, "exactly one job", scope="custom", tmux_ref="master", lua="5.1.5,5.5.1", tmate="on-failure")


def check_a_debug_session_needs_a_dispatch(test):
    for event in ("push", "pull_request"):
        refused(test, "only available on a workflow_dispatch", event=event, scope="custom",
                tmux_ref="master", tmate="on-failure")


def check_a_debug_mode_must_be_known(test):
    refused(test, "tmate must be one of", scope="custom", tmux_ref="master", tmate="always")


def check_the_job_count_adds_up(test):
    for result in (run("push"), run("workflow_dispatch", scope="full"),
                   run("workflow_dispatch", scope="custom", tmux_ref="master,3.8")):
        test.assertEqual(result["expected_jobs"], len(cells(result)) + 2)
    test.assertEqual(run("push")["expected_jobs"], len(UNIT) + 2 + 2 + 2)


def check_the_matrix_is_never_empty(test):
    with test.assertRaisesRegex(ci_plan.PlanError, "no job"):
        ci_plan.require_cells([])


def check_job_names_follow_the_plan(test):
    names = ci_plan.job_names(run("push"))
    test.assertEqual(names, {"plan", "required", *(f"Unit Lua 5.{n}" for n in range(1, 6)), "Unit LuaJIT",
                             "Outer floor", "Outer current", f"tmux {OLDEST}", f"tmux {NEWEST}"})


def check_the_manifest_must_be_consistent(test):
    with test.assertRaisesRegex(ci_plan.PlanError, "not in the catalog"):
        loaded(["3.3a", "3.8"], development={"next-3.9": "master"})
    with test.assertRaisesRegex(ci_plan.PlanError, "no released version"):
        loaded(["next-3.9"], development={"next-3.9": "master"})


def check_the_required_check_needs_the_plan_and_the_matrix(test):
    good = {"plan": {"result": "success"}, "validate": {"result": "success"}}
    test.assertEqual(ci_plan.check_needs(good), [])
    for job in ("plan", "validate"):
        for result in ("failure", "cancelled", "skipped"):
            test.assertTrue(ci_plan.check_needs({**good, job: {"result": result}}), (job, result))
        test.assertTrue(ci_plan.check_needs({key: value for key, value in good.items() if key != job}), job)


def every_edge(released):
    return list(released)


def hard_coded(released):
    return [OLDEST, NEWEST]


def resolving(**fixed):
    return lambda event, scope: fixed["scope"]


def pull_requests_run_everything(event, scope):
    return "full" if event == "pull_request" else RULES["resolve_scope"](event, scope)


def schedules_run_the_edges(event, scope):
    return "edges" if event == "schedule" else RULES["resolve_scope"](event, scope)


def ignoring_the_given_scope(event, scope):
    return RULES["resolve_scope"](event, "")


def unchecked_scope(event, scope):
    return scope or "edges"


def unchecked_event(event, scope):
    return scope if scope in ci_plan.SCOPES else "edges"


def stale_outer(manifest, scope, oldest, newest):
    return [ci_plan.cell(f"Outer {role}", "outer", pair["lua"], "3.7c", pair["nvim"], build="pinned")
            for role, pair in manifest["outer"].items()]


def outer_ignoring_the_scope(manifest, scope, oldest, newest):
    return RULES["outer_cells"](manifest, "edges", oldest, newest)


def outer_always_pinned(manifest, scope, oldest, newest):
    return RULES["outer_cells"](manifest, "full", oldest, newest)


def full_without_development(manifest, versions, luas, nvims):
    return [each for each in RULES["tmux_cells"](manifest, versions, luas, nvims)
            if each["tmux"] not in manifest["development"]]


def full_without_a_unit_job(manifest):
    return RULES["unit_cells"](manifest)[:-1]


def edges_with_refusals(released):
    return [released[0], released[-1], *REFUSED]


def refusals_dropped(manifest, versions, luas, nvims):
    return [] if set(versions) == set(manifest["refused"]) else RULES["tmux_cells"](manifest, versions, luas, nvims)


def always_integration(manifest, versions, luas, nvims):
    plain = {**manifest, "refused": {}}
    return RULES["tmux_cells"](plain, versions, luas, nvims)


def always_pinned(manifest, versions, luas, nvims):
    return [{**each, "build": "pinned"} for each in RULES["tmux_cells"](manifest, versions, luas, nvims)]


def never_pinned(manifest, versions, luas, nvims):
    return [{**each, "build": "ref"} for each in RULES["tmux_cells"](manifest, versions, luas, nvims)]


def without_a_client(manifest, versions, luas, nvims):
    return [{**each, "client": ""} for each in RULES["tmux_cells"](manifest, versions, luas, nvims)]


def custom_without_a_requirement(tmux_ref):
    return ci_plan.split_list(tmux_ref) or ["master"]


def unvalidated(tmux_ref):
    return tmux_ref


def ignored(*arguments):
    return None


def default_stack(requested, allowed, default, label):
    return [default]


def unchecked_stack(requested, allowed, default, label):
    return ci_plan.split_list(requested) or [default]


def any_image(image):
    return image or ci_plan.RUNNERS[0]


def default_image(image):
    return ci_plan.RUNNERS[0]


def debug_session_everywhere(event, mode, got_cells):
    for each in got_cells:
        each["tmate"] = mode


def debug_session_without_event(event, mode, got_cells):
    RULES["assign_tmate"]("workflow_dispatch", mode, got_cells)


def debug_session_on_the_first_job(event, mode, got_cells):
    if mode != "off":
        got_cells[0]["tmate"] = mode


def unchecked_mode(event, mode, got_cells):
    if mode in ci_plan.TMATE_MODES:
        RULES["assign_tmate"](event, mode, got_cells)
    elif len(got_cells) == 1:
        got_cells[0]["tmate"] = mode


def gate_without(prefix):
    return lambda got: [each for each in RULES["check_needs"](got) if not each.startswith(prefix)]


def gate_that_accepts_a_skip(got):
    return RULES["check_needs"](
        {job: {"result": "success" if value.get("result") == "skipped" else value.get("result")}
         for job, value in got.items()})


def unfiltered_load(manifest_path=ci_plan.MANIFEST, catalog_path=ci_plan.CATALOG):
    manifest = json.loads(Path(manifest_path).read_text())
    table = list(json.loads(Path(catalog_path).read_text())["releases"])
    return {**manifest, "table": table, "released": table}


def trusting_load(manifest_path=ci_plan.MANIFEST, catalog_path=ci_plan.CATALOG):
    manifest = json.loads(Path(manifest_path).read_text())
    table = list(json.loads(Path(catalog_path).read_text())["releases"])
    released = [name for name in table if name not in manifest["development"]]
    return {**manifest, "table": table, "released": released}


DELIBERATE_BREAKS = [
    ("the edges rule takes every version", "edge_versions", every_edge, check_push_runs_the_edges_only),
    ("the edges are written into the plan", "edge_versions", hard_coded,
     check_the_manifest_alone_decides_the_table),
    ("the edges run the refusal jobs", "edge_versions", edges_with_refusals, check_push_runs_the_edges_only),
    ("a development build can be an edge", "load", unfiltered_load, check_a_development_build_is_never_an_edge),
    ("a manifest outside the catalog is trusted", "load", trusting_load, check_the_manifest_must_be_consistent),
    ("a pull request runs the full scope", "resolve_scope", pull_requests_run_everything,
     check_pull_request_runs_the_edges_only),
    ("a dispatch ignores the scope it was given", "resolve_scope", ignoring_the_given_scope,
     check_full_runs_the_whole_table),
    ("a given scope loses to the event", "resolve_scope", ignoring_the_given_scope,
     check_an_explicit_scope_beats_the_event),
    ("a dispatch does not default to the edges", "resolve_scope", resolving(scope="full"),
     check_dispatch_defaults_to_the_edges),
    ("a schedule runs the edges", "resolve_scope", schedules_run_the_edges,
     check_a_schedule_runs_the_full_scope),
    ("an unknown scope is accepted", "resolve_scope", unchecked_scope, check_a_scope_must_be_known),
    ("an unknown event is accepted", "resolve_scope", unchecked_event, check_an_unknown_event_is_refused),
    ("the outer jobs keep a stale tmux", "outer_cells", stale_outer, check_the_outer_jobs_follow_the_edges),
    ("the full scope moves the current outer job to the edge", "outer_cells", outer_ignoring_the_scope,
     check_full_scope_keeps_the_outer_current_pin),
    ("the full scope moves a cell of the old set", "outer_cells", outer_ignoring_the_scope,
     check_full_scope_is_exactly_the_old_set),
    ("a push keeps the pinned outer job", "outer_cells", outer_always_pinned, check_the_outer_jobs_follow_the_edges),
    ("the full scope drops the development builds", "tmux_cells", full_without_development,
     check_full_scope_is_exactly_the_old_set),
    ("the full scope drops a unit job", "unit_cells", full_without_a_unit_job,
     check_full_scope_is_exactly_the_old_set),
    ("the full scope drops its refusal jobs", "tmux_cells", refusals_dropped, check_full_runs_the_whole_table),
    ("a refused release runs the integration suite", "tmux_cells", always_integration,
     check_custom_names_resolve_to_their_build),
    ("a custom ref is always pinned", "tmux_cells", always_pinned, check_custom_names_resolve_to_their_build),
    ("a table release is built as a ref", "tmux_cells", never_pinned, check_custom_names_resolve_to_their_build),
    ("an old-daemon refusal has no client", "tmux_cells", without_a_client, check_full_runs_the_whole_table),
    ("a custom run without refs is planned", "custom_refs", custom_without_a_requirement,
     check_a_custom_run_needs_refs),
    ("refs the scope ignores are accepted", "check_scope_inputs", ignored,
     check_a_ref_list_needs_the_custom_scope),
    ("a ref is not validated", "check_ref", unvalidated, check_every_ref_is_validated),
    ("the job count is unlimited", "MAX_CUSTOM_LEGS", 1000, check_too_many_jobs_are_refused),
    ("the stack inputs are ignored", "select_stack", default_stack, check_stack_inputs_retarget_the_tmux_jobs),
    ("an unknown stack version is accepted", "select_stack", unchecked_stack,
     check_an_unknown_stack_version_is_refused),
    ("the os input is ignored", "choose_image", default_image, check_the_runner_is_chosen_from_the_images),
    ("an unknown os is accepted", "choose_image", any_image, check_the_runner_is_chosen_from_the_images),
    ("no job gets the debug session", "assign_tmate", ignored, check_one_job_gets_the_debug_session),
    ("every job gets the debug session", "assign_tmate", debug_session_everywhere,
     check_several_jobs_cannot_share_a_debug_session),
    ("the debug session lands on the first of many jobs", "assign_tmate", debug_session_on_the_first_job,
     check_several_jobs_cannot_share_a_debug_session),
    ("the debug session runs outside a dispatch", "assign_tmate", debug_session_without_event,
     check_a_debug_session_needs_a_dispatch),
    ("an unknown debug mode is accepted", "assign_tmate", unchecked_mode, check_a_debug_mode_must_be_known),
    ("the job count omits the fixed jobs", "FIXED_JOBS", 0, check_the_job_count_adds_up),
    ("an empty matrix is emitted", "require_cells", ignored, check_the_matrix_is_never_empty),
    ("the job names omit the matrix", "job_names", lambda result: {"plan"}, check_job_names_follow_the_plan),
    ("the required check ignores the plan", "check_needs", gate_without("plan"),
     check_the_required_check_needs_the_plan_and_the_matrix),
    ("the required check ignores the matrix", "check_needs", gate_without("validate"),
     check_the_required_check_needs_the_plan_and_the_matrix),
    ("the required check accepts a skip", "check_needs", gate_that_accepts_a_skip,
     check_the_required_check_needs_the_plan_and_the_matrix),
]

ALL_CHECKS = [
    check_push_runs_the_edges_only,
    check_pull_request_runs_the_edges_only,
    check_dispatch_defaults_to_the_edges,
    check_a_schedule_runs_the_full_scope,
    check_full_runs_the_whole_table,
    check_full_scope_is_exactly_the_old_set,
    check_an_explicit_scope_beats_the_event,
    check_the_manifest_alone_decides_the_table,
    check_a_development_build_is_never_an_edge,
    check_a_single_release_is_one_edge,
    check_the_outer_jobs_follow_the_edges,
    check_full_scope_keeps_the_outer_current_pin,
    check_a_scope_must_be_known,
    check_an_unknown_event_is_refused,
    check_a_ref_list_needs_the_custom_scope,
    check_a_custom_run_needs_refs,
    check_every_ref_is_validated,
    check_too_many_jobs_are_refused,
    check_custom_names_resolve_to_their_build,
    check_stack_inputs_retarget_the_tmux_jobs,
    check_an_unknown_stack_version_is_refused,
    check_the_runner_is_chosen_from_the_images,
    check_one_job_gets_the_debug_session,
    check_no_debug_session_by_default,
    check_several_jobs_cannot_share_a_debug_session,
    check_a_debug_session_needs_a_dispatch,
    check_a_debug_mode_must_be_known,
    check_the_job_count_adds_up,
    check_the_matrix_is_never_empty,
    check_job_names_follow_the_plan,
    check_the_manifest_must_be_consistent,
    check_the_required_check_needs_the_plan_and_the_matrix,
]

# Checks that state a default or a boundary no single removal can reach.
WITHOUT_A_BREAK = {check_no_debug_session_by_default, check_a_single_release_is_one_edge}


class PlanFollowsItsRules(unittest.TestCase):
    def test_every_check_passes(self):
        for check in ALL_CHECKS:
            with self.subTest(check=check.__name__):
                check(self)

    def test_every_check_has_a_deliberate_break(self):
        broken = {each[3] for each in DELIBERATE_BREAKS}
        self.assertEqual({check for check in ALL_CHECKS if check not in broken}, WITHOUT_A_BREAK)

    def test_a_check_fails_when_its_rule_is_removed(self):
        for description, attribute, replacement, check in DELIBERATE_BREAKS:
            with self.subTest(description):
                check(self)
                with mock.patch.object(ci_plan, attribute, replacement):
                    with self.assertRaises(AssertionError):
                        check(self)


class PlanCommand(unittest.TestCase):
    def main(self, *arguments, environment=None):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            with mock.patch.dict("os.environ", environment or {}):
                status = ci_plan.main(list(arguments))
        return status, out.getvalue(), err.getvalue()

    def test_the_outputs_are_single_line_json(self):
        with tempfile.TemporaryDirectory(prefix="libtmux-lua-plan-") as directory:
            output, summary = Path(directory) / "output", Path(directory) / "summary"
            status, printed, _ = self.main("plan", "--event", "push", "--github-output", str(output),
                                           "--summary", str(summary))
            self.assertEqual(status, 0)
            self.assertEqual(json.loads(printed)["scope"], "edges")
            lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual(set(lines), {"scope", "os", "matrix", "expected_jobs"})
            self.assertEqual(json.loads(lines["matrix"]), run("push")["matrix"])
            self.assertEqual(lines["expected_jobs"], str(run("push")["expected_jobs"]))
            self.assertIn(f"tmux {NEWEST}", summary.read_text())

    def test_a_refused_plan_exits_nonzero_and_writes_nothing(self):
        with tempfile.TemporaryDirectory(prefix="libtmux-lua-plan-") as directory:
            output = Path(directory) / "output"
            status, printed, error = self.main("plan", "--event", "push", "--tmux-ref", "master",
                                               "--github-output", str(output))
            self.assertEqual((status, printed), (1, ""))
            self.assertIn("only used with scope custom", error)
            self.assertFalse(output.exists())

    def test_the_inputs_reach_the_plan(self):
        status, printed, _ = self.main("plan", "--event", "workflow_dispatch", "--scope", "custom",
                                       "--tmux-ref", "master", "--lua", "luajit", "--nvim", "0.10.0",
                                       "--os", "ubuntu-latest", "--tmate", "on-failure")
        result = json.loads(printed)
        self.assertEqual(status, 0)
        self.assertEqual(result["os"], "ubuntu-latest")
        self.assertEqual([(each["lua"], each["nvim"], each["tmate"]) for each in cells(result)],
                         [("luajit", "0.10.0", "on-failure")])

    def test_verify_reads_the_needs_context(self):
        good = {"plan": {"result": "success"}, "validate": {"result": "success"}}
        self.assertEqual(self.main("verify", environment={"NEEDS": json.dumps(good)})[0], 0)
        bad = {**good, "validate": {"result": "failure"}}
        status, _, error = self.main("verify", environment={"NEEDS": json.dumps(bad)})
        self.assertEqual(status, 1)
        self.assertIn("validate finished failure", error)
        self.assertEqual(self.main("verify", environment={"NEEDS": "{}"})[0], 1)


if __name__ == "__main__":
    unittest.main()
