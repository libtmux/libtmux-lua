#!/usr/bin/env python3
"""Plan the CI jobs from the tmux catalog, data/ci-matrix.json and the event.

A push and a pull request used to run every tmux release of the support
table, although the oldest and newest released versions bracket the rest. This
script decides what a run covers, so the workflow lists no version.

Scopes:

- edges: the unit jobs, both outer jobs and the integration suite on the
  oldest and newest released tmux. The default for a push, a pull request and
  a dispatch.
- full: the unit jobs, the outer jobs (the current one on the release the
  manifest pins), the refusal jobs and every table entry, development builds
  included. A release and a schedule, and a dispatch that asks.
- custom: only the tmux versions, tags, branches or commits a dispatch names.
"""

import argparse
import json
import os
from pathlib import Path
import sys

if __package__:
    from .tmux_ref import check_ref
else:
    from tmux_ref import check_ref

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "data/ci-matrix.json"
CATALOG = ROOT / "data/tmux-options.json"

SCOPES = ("edges", "full", "custom")
EVENT_SCOPES = {"push": "edges", "pull_request": "edges", "workflow_dispatch": "edges", "schedule": "full"}
TMATE_MODES = ("off", "before-tests", "on-failure")
RUNNERS = ("ubuntu-24.04", "ubuntu-latest", "ubuntu-22.04")

# A mistyped list should fail rather than fan out into a huge matrix.
MAX_CUSTOM_LEGS = 12

# The plan and the required check, which every run has.
FIXED_JOBS = 2

PLAN_JOB = "plan"
MATRIX_JOB = "validate"


class PlanError(ValueError):
    """The inputs name a run that cannot or must not happen."""


def load(manifest_path=MANIFEST, catalog_path=CATALOG):
    """Read the manifest and sort the catalog's releases into released and development."""
    manifest = json.loads(Path(manifest_path).read_text())
    table = list(json.loads(Path(catalog_path).read_text())["releases"])
    for name in manifest["development"]:
        if name not in table:
            raise PlanError(f"development build {name} is not in the catalog")
    released = [name for name in table if name not in manifest["development"]]
    if not released:
        raise PlanError("the catalog has no released version")
    return {**manifest, "table": table, "released": released}


def split_list(value):
    """Split a comma-separated input, dropping blanks and repeats."""
    items = []
    for each in value.split(","):
        item = each.strip()
        if item and item not in items:
            items.append(item)
    return items


def resolve_scope(event, scope):
    """Decide how much of the table a run covers."""
    if scope:
        if scope not in SCOPES:
            raise PlanError(f"scope must be one of {', '.join(SCOPES)}, not {scope!r}")
        return scope
    if event in EVENT_SCOPES:
        return EVENT_SCOPES[event]
    raise PlanError(f"no scope is defined for the {event!r} event")


def check_scope_inputs(scope, tmux_ref):
    """Refuse a list of refs that the scope would silently ignore."""
    if tmux_ref and scope != "custom":
        raise PlanError("tmux-ref is only used with scope custom")


def edge_versions(released):
    """Pick the oldest and the newest released tmux."""
    return list(dict.fromkeys([released[0], released[-1]]))


def custom_refs(tmux_ref):
    """Validate the refs a custom run was asked to build."""
    items = split_list(tmux_ref)
    if not items:
        raise PlanError("scope custom needs tmux-ref, a comma-separated list of tmux refs")
    try:
        return [check_ref(item) for item in items]
    except ValueError as error:
        raise PlanError(str(error)) from error


def select_stack(requested, allowed, default, label):
    """Narrow the Lua or Neovim versions of the tmux jobs, or keep the default."""
    chosen = split_list(requested)
    for item in chosen:
        if item not in allowed:
            raise PlanError(f"{label} must name versions from {', '.join(allowed)}, not {item!r}")
    return chosen or [default]


def choose_image(image):
    """Pick the runner image, which is the one CI always used unless a dispatch asks."""
    if not image:
        return RUNNERS[0]
    if image not in RUNNERS:
        raise PlanError(f"os must be one of {', '.join(RUNNERS)}, not {image!r}")
    return image


def cell(name, gate, lua, tmux="", nvim="", client="", build=""):
    """Describe one job of the matrix."""
    return {"name": name, "gate": gate, "lua": lua, "tmux": tmux, "nvim": nvim,
            "client": client, "build": build, "tmate": "off"}


def unit_cells(manifest):
    """One unit job per Lua runtime, which no tmux version changes."""
    return [cell("Unit LuaJIT" if lua == "luajit" else "Unit Lua " + ".".join(lua.split(".")[:2]),
                 "unit", lua)
            for lua in manifest["unit"]]


def outer_cells(manifest, scope, oldest, newest):
    """The outer gate at the floor and the current stack.

    A push runs both on the edge releases. The full scope keeps the current one
    on the release the manifest pins it to, as it always ran.
    """
    current = newest if scope != "full" else manifest["outer"]["current"].get("full_tmux", newest)
    return [cell(f"Outer {role}", "outer", manifest["outer"][role]["lua"], tmux,
                 manifest["outer"][role]["nvim"], build="pinned")
            for role, tmux in (("floor", oldest), ("current", current))]


def tmux_cells(manifest, versions, luas, nvims):
    """One job per tmux version and stack: the integration suite, or the refusal check."""
    cells = []
    for version in versions:
        refused = manifest["refused"].get(version)
        if refused:
            gate, build, label = "refusal", "pinned", f"tmux {version} refused"
            client = manifest["released"][0] if refused["old_daemon"] else ""
        else:
            gate, client, label = "integration", "", f"tmux {version}"
            build = "pinned" if version in manifest["table"] else "ref"
        for lua in luas:
            for nvim in nvims:
                stack = [f"Lua {lua}"] if lua != manifest["stack"]["lua"] else []
                stack += [f"Neovim {nvim}"] if nvim != manifest["stack"]["nvim"] else []
                name = f"{label} ({', '.join(stack)})" if stack else label
                cells.append(cell(name, gate, lua, version, nvim, client, build))
    return cells


def require_cells(cells):
    """Refuse a plan with no job, which GitHub would reject anyway."""
    if not cells:
        raise PlanError("the plan has no job")


def assign_tmate(event, mode, cells):
    """Give exactly one job the debugging session, or fail."""
    if mode not in TMATE_MODES:
        raise PlanError(f"tmate must be one of {', '.join(TMATE_MODES)}, not {mode!r}")
    if mode == "off":
        return
    if event != "workflow_dispatch":
        raise PlanError("tmate is only available on a workflow_dispatch run")
    if len(cells) != 1:
        raise PlanError(f"tmate needs exactly one job and this run has {len(cells)}; "
                        "use scope custom with one tmux-ref, lua and nvim")
    cells[0]["tmate"] = mode


def plan(manifest, *, event, scope="", tmux_ref="", lua="", nvim="", image="", tmate=""):
    """Return the matrix, the runner image and the job count for one run."""
    chosen = resolve_scope(event, scope)
    check_scope_inputs(chosen, tmux_ref)
    runner = choose_image(image)
    luas = select_stack(lua, manifest["unit"], manifest["stack"]["lua"], "lua")
    nvims = select_stack(nvim, manifest["nvim"], manifest["stack"]["nvim"], "nvim")
    edges = edge_versions(manifest["released"])

    if chosen == "custom":
        versions = custom_refs(tmux_ref)
        legs = len(versions) * len(luas) * len(nvims)
        if legs > MAX_CUSTOM_LEGS:
            raise PlanError(f"this run would have {legs} jobs; at most {MAX_CUSTOM_LEGS} fit a custom run")
        cells = tmux_cells(manifest, versions, luas, nvims)
    else:
        cells = unit_cells(manifest) + outer_cells(manifest, chosen, edges[0], edges[-1])
        if chosen == "full":
            cells += tmux_cells(manifest, list(manifest["refused"]), luas, nvims)
            cells += tmux_cells(manifest, manifest["table"], luas, nvims)
        else:
            cells += tmux_cells(manifest, edges, luas, nvims)
    require_cells(cells)
    assign_tmate(event, tmate or "off", cells)

    return {"scope": chosen, "os": runner, "matrix": {"include": cells},
            "expected_jobs": FIXED_JOBS + len(cells)}


def job_names(result):
    """Name the jobs a plan produces, as the workflow names them."""
    return {PLAN_JOB, "required", *(each["name"] for each in result["matrix"]["include"])}


def check_needs(needs):
    """Find what stops the required check from passing: the plan and the matrix must both succeed."""
    problems = []
    for job in (PLAN_JOB, MATRIX_JOB):
        result = needs.get(job, {}).get("result")
        if result != "success":
            problems.append(f"{job} finished {result or 'missing'}, not success")
    return problems


def summary(result):
    """Describe a plan for the job summary."""
    lines = [f"### CI plan: {result['scope']}", "",
             f"Expected jobs in this workflow: {result['expected_jobs']}", ""]
    lines += [f"- {each['name']}" for each in result["matrix"]["include"]]
    return "\n".join(lines) + "\n"


def outputs(result):
    """Flatten a plan into single-line workflow outputs."""
    return {"scope": result["scope"], "os": result["os"],
            "matrix": json.dumps(result["matrix"], separators=(",", ":")),
            "expected_jobs": str(result["expected_jobs"])}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    planner = commands.add_parser("plan", help="plan the matrix for one event")
    planner.add_argument("--event", required=True, help="github.event_name")
    planner.add_argument("--scope", default="", help="edges, full or custom")
    planner.add_argument("--tmux-ref", default="", help="comma-separated tmux refs")
    planner.add_argument("--lua", default="", help="comma-separated Lua runtimes for the tmux jobs")
    planner.add_argument("--nvim", default="", help="comma-separated Neovim versions for the tmux jobs")
    planner.add_argument("--os", default="", help="runner image")
    planner.add_argument("--tmate", default="", help="off, before-tests or on-failure")
    planner.add_argument("--github-output", type=Path, help="the GITHUB_OUTPUT file")
    planner.add_argument("--summary", type=Path, help="the GITHUB_STEP_SUMMARY file")
    commands.add_parser("verify", help="check the NEEDS environment variable")
    arguments = parser.parse_args(argv)

    if arguments.command == "verify":
        problems = check_needs(json.loads(os.environ.get("NEEDS", "{}")))
        for problem in problems:
            print(f"required: {problem}", file=sys.stderr)
        return 1 if problems else 0

    try:
        result = plan(load(), event=arguments.event, scope=arguments.scope,
                      tmux_ref=arguments.tmux_ref, lua=arguments.lua, nvim=arguments.nvim,
                      image=arguments.os, tmate=arguments.tmate)
    except PlanError as error:
        print(f"plan: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    if arguments.github_output:
        with arguments.github_output.open("a") as handle:
            for key, value in outputs(result).items():
                handle.write(f"{key}={value}\n")
    if arguments.summary:
        with arguments.summary.open("a") as handle:
            handle.write(summary(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
