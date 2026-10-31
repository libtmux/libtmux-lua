"""Prove ci.yml takes its jobs from the plan and stays bound to the release gate.

The workflows are read as text, because the CI step that runs these tests has
no YAML parser. Each rule has a mutation that has to be reported.
"""

from pathlib import Path
import re
import sys
import unittest


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from scripts import ci_plan

CI = (ROOT / ".github/workflows/ci.yml").read_text()
PUBLISH = (ROOT / ".github/workflows/publish.yml").read_text()
MANIFEST = ci_plan.load()


def split_jobs(text):
    """Map each job id to its text."""
    _, _, body = text.partition("\njobs:\n")
    found, name = {}, None
    for line in body.splitlines():
        header = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if header:
            name = header.group(1)
            found[name] = []
        elif name and (line.startswith("    ") or not line.strip()):
            found[name].append(line)
        elif line and not line.startswith((" ", "#")):
            name = None
    return {key: "\n".join(value) for key, value in found.items()}


def field(job, key):
    match = re.search(rf"^    {re.escape(key)}: (.*)$", job, re.MULTILINE)
    return match.group(1).strip() if match else None


def dispatch_inputs(text):
    """Map each workflow_dispatch input to its text."""
    match = re.search(r"(?ms)^  workflow_dispatch:\n    inputs:\n(.*?)^  workflow_call:", text)
    found, name = {}, None
    for line in (match[1] if match else "").splitlines():
        header = re.match(r"^      ([a-z-]+):\s*$", line)
        if header:
            name = header.group(1)
            found[name] = []
        elif name:
            found[name].append(line)
    return {key: "\n".join(value) for key, value in found.items()}


def options(text):
    match = re.search(r"options: \[(.*?)\]", text)
    return [each.strip() for each in match[1].split(",")] if match else None


def problems(ci, publish):
    """Name each way the workflows stop following the plan."""
    found = []
    jobs = split_jobs(ci)
    code = re.sub(r"(?m)^ +description: .*\n(?: {10,}.*\n)*", "", ci)
    for name in [*MANIFEST["table"], *MANIFEST["refused"]]:
        if re.search(rf"(?<![\w.]){re.escape(name)}(?![\w.])", code):
            found.append(f"ci.yml names tmux {name}, which only the catalog and manifest may")
    if re.search(r"(?m)^\s+include:", ci):
        found.append("ci.yml lists its own matrix")
    if set(jobs) < {"plan", "validate"}:
        return [*found, "ci.yml needs a plan job and a validate job"]
    if field(jobs["validate"], "needs") != "plan":
        found.append("validate: must wait for the plan")
    if field(jobs["validate"], "runs-on") != "${{ needs.plan.outputs.os }}":
        found.append("validate: must run on the image the plan chose")
    if "matrix: ${{ fromJSON(needs.plan.outputs.matrix) }}" not in jobs["validate"]:
        found.append("validate: the matrix must come from the plan")
    if re.search(r"(?m)^    if:", jobs["validate"]):
        found.append("validate: the matrix shrinks through the plan, never an if on the job")

    gate = jobs.get("required")
    if gate is None:
        found.append("ci.yml needs one stable required job")
    else:
        waited = re.findall(r"[A-Za-z0-9_-]+", (field(gate, "needs") or "").strip("[]"))
        if set(waited) != set(jobs) - {"required"}:
            found.append("required: must wait for every other job")
        if field(gate, "name") != "required":
            found.append("required: the check keeps one stable name")
        if field(gate, "if") != "always()":
            found.append("required: must run when a job it waits for failed")
        if "NEEDS: ${{ toJSON(needs) }}" not in gate or "scripts/ci_plan.py verify" not in gate:
            found.append("required: must verify the needs context with the plan script")

    inputs = dispatch_inputs(ci)
    if options(inputs.get("scope", "")) != list(ci_plan.SCOPES):
        found.append("the scope input must offer exactly the plan's scopes")
    if "default: edges" not in inputs.get("scope", ""):
        found.append("the scope input must default to edges")
    if options(inputs.get("os", "")) != list(ci_plan.RUNNERS):
        found.append("the os input must offer exactly the plan's runner images")
    if re.search(r"macos", ci, re.IGNORECASE):
        found.append("ci.yml must not run on macOS")
    for name in inputs:
        if f"inputs.{name} }}}}" not in jobs["plan"]:
            found.append(f"plan: the {name} input must reach the plan")
    for line in ci.splitlines():
        if "inputs." in line and not re.fullmatch(r"\s+[A-Z_]+: \$\{\{ inputs\.[a-z-]+ \}\}", line):
            found.append("an input may reach a step only through env")
    group = re.search(r"(?m)^concurrency:\n  group: (.*)\n  cancel-in-progress: (.*)$", ci)
    if not group or "github.event_name == 'workflow_dispatch' && github.run_id ||" not in group[1]:
        found.append("a dispatch run must have its own concurrency group")
    if not group or "github.event.pull_request.number || github.ref" not in group[1] or group[2] != "true":
        found.append("a push and a pull request must still cancel the run they supersede")
    call = re.search(r"(?ms)^  workflow_call:\n    inputs:\n      scope:\n(.*?)^\S", ci + "\n_")
    if not call or "required: true" not in call[1]:
        found.append("the workflow_call scope input must be required")

    release = split_jobs(publish).get("validate", "")
    if "uses: ./.github/workflows/ci.yml" not in release:
        found.append("publish: validate must call ci.yml")
    if not re.search(r"(?m)^    with:\n      scope: full$", release):
        found.append("publish: validate must ask for scope full")
    if field(split_jobs(publish).get("luarocks", ""), "needs") != "validate":
        found.append("publish: the upload must wait for validate")
    return found


TMATE = "mxschmitt/action-tmate"


def steps_of(job):
    """Split a job's text into its steps."""
    return re.split(r"(?m)^(?=      - )", job)[1:]


def step_field(step, key):
    match = re.search(rf"(?m)^        {re.escape(key)}: (.*)$", step)
    return match[1].strip() if match else None


def session_problems(ci, publish):
    """Name what makes a debugging session unsafe or misplaced."""
    found = []
    jobs = split_jobs(ci)
    sessions = 0
    for name, job in jobs.items():
        for step in steps_of(job):
            if TMATE not in step:
                continue
            sessions += 1
            if name != "validate":
                found.append(f"{name}: a debugging session belongs only in the test matrix")
            if not re.search(rf"uses: {re.escape(TMATE)}@[0-9a-f]{{40}} # v", step):
                found.append("a debugging session must be pinned to a full commit SHA")
            if "limit-access-to-actor: true" not in step:
                found.append("a debugging session must be limited to the actor")
            if not step_field(step, "timeout-minutes"):
                found.append("a debugging session needs its own time limit")
            condition = step_field(step, "if") or ""
            if "github.event_name == 'workflow_dispatch'" not in condition or "matrix.tmate ==" not in condition:
                found.append("a debugging session runs only on a dispatch, on the job the plan chose")
    if sessions != 2:
        found.append("the matrix must offer a session before the tests and one after a failure")
    if "validate" in jobs and field(jobs["validate"], "timeout-minutes") != "${{ matrix.tmate == 'off' && 20 || 60 }}":
        found.append("validate: the job must cap its time and give the debugging job more")
    inputs = dispatch_inputs(ci)
    if options(inputs.get("tmate", "")) != list(ci_plan.TMATE_MODES) or "default: 'off'" not in inputs.get("tmate", ""):
        found.append("the tmate input must offer exactly the plan's modes and default to off")
    if "plan" in jobs and ("TMATE: ${{ inputs.tmate }}" not in jobs["plan"] or '--tmate "$TMATE"' not in jobs["plan"]):
        found.append("plan: must pass the tmate input through env")
    if TMATE in publish:
        found.append("publish: a release never opens a debugging session")
    return found


def without(text, line):
    assert line in text, line
    return text.replace(line, "", 1)


def replaced(text, old, new):
    assert old in text, old
    return text.replace(old, new, 1)


MUTATIONS = [
    ("a tmux version returns to the workflow", lambda ci, pub: (ci + f"      - run: echo {ci_plan.load()['released'][0]}\n", pub),
     "ci.yml names tmux"),
    ("the matrix is listed again", lambda ci, pub: (replaced(
        ci, "      matrix: ${{ fromJSON(needs.plan.outputs.matrix) }}",
        "      matrix:\n        include:\n          - {name: x}"), pub), "ci.yml lists its own matrix"),
    ("validate stops waiting for the plan", lambda ci, pub: (replaced(ci, "    needs: plan\n", ""), pub),
     "validate: must wait for the plan"),
    ("validate runs on a fixed image", lambda ci, pub: (replaced(
        ci, "runs-on: ${{ needs.plan.outputs.os }}", "runs-on: ubuntu-24.04"), pub), "the image the plan chose"),
    ("validate takes its matrix from elsewhere", lambda ci, pub: (replaced(
        ci, "fromJSON(needs.plan.outputs.matrix)", "fromJSON(needs.plan.outputs.other)"), pub),
     "the matrix must come from the plan"),
    ("validate is trimmed with an if", lambda ci, pub: (replaced(
        ci, "    needs: plan\n    runs-on:", "    needs: plan\n    if: github.event_name != 'push'\n    runs-on:"), pub),
     "never an if on the job"),
    ("the scope input offers another scope", lambda ci, pub: (replaced(
        ci, "options: [edges, full, custom]", "options: [edges, full]"), pub), "the plan's scopes"),
    ("the scope input defaults to full", lambda ci, pub: (replaced(
        ci, "        default: edges\n", "        default: full\n"), pub), "must default to edges"),
    ("the os input offers another image", lambda ci, pub: (replaced(
        ci, "options: [ubuntu-24.04, ubuntu-latest, ubuntu-22.04]", "options: [ubuntu-24.04]"), pub),
     "the plan's runner images"),
    ("a macOS image appears", lambda ci, pub: (replaced(
        ci, "ubuntu-22.04]", "ubuntu-22.04, macos-latest]"), pub), "must not run on macOS"),
    ("an input stops reaching the plan", lambda ci, pub: (without(
        ci, "          NVIM: ${{ inputs.nvim }}\n"), pub), "plan: the nvim input must reach the plan"),
    ("an input is used inline in a script", lambda ci, pub: (replaced(
        ci, '            --lua "$LUA" \\\n', '            --lua "${{ inputs.lua }}" \\\n'), pub),
     "only through env"),
    ("the required job is dropped", lambda ci, pub: (ci[:ci.index("\n  # One check to require")] + "\n", pub),
     "needs one stable required job"),
    ("the required job forgets a job", lambda ci, pub: (replaced(
        ci, "needs: [plan, validate]", "needs: [validate]"), pub), "must wait for every other job"),
    ("the required job is renamed", lambda ci, pub: (replaced(
        ci, "    name: required\n", "    name: all green\n"), pub), "keeps one stable name"),
    ("the required job is skipped after a failure", lambda ci, pub: (replaced(
        ci, "needs: [plan, validate]\n    if: always()\n", "needs: [plan, validate]\n"), pub),
     "must run when a job it waits for failed"),
    ("the required job stops verifying", lambda ci, pub: (replaced(
        ci, "run: python3 scripts/ci_plan.py verify", "run: 'true'"), pub), "must verify the needs context"),
    ("a job is added that the required job does not wait for", lambda ci, pub: (
        ci + "\n  extra:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: 'true'\n", pub),
     "must wait for every other job"),
    ("the session is not pinned to a commit", lambda ci, pub: (
        ci.replace("action-tmate@35b54afac29c97fb54faba5b513f8fbd1882f113 # v3.24", "action-tmate@v3"), pub),
     "pinned to a full commit SHA"),
    ("the session is open to every collaborator", lambda ci, pub: (
        ci.replace("limit-access-to-actor: true", "limit-access-to-actor: false"), pub), "limited to the actor"),
    ("the session has no time limit of its own", lambda ci, pub: (
        ci.replace("        timeout-minutes: 30\n", ""), pub), "its own time limit"),
    ("the session runs on every event", lambda ci, pub: (
        ci.replace("github.event_name == 'workflow_dispatch' && matrix.tmate == 'before-tests'", "matrix.tmate == 'before-tests'"), pub),
     "only on a dispatch"),
    ("the session runs on every job", lambda ci, pub: (
        ci.replace("&& matrix.tmate == 'on-failure'", ""), pub), "only on a dispatch"),
    ("a session returns to the release", lambda ci, pub: (
        ci, pub + "      - uses: mxschmitt/action-tmate@35b54afac29c97fb54faba5b513f8fbd1882f113 # v3.24\n"),
     "a release never opens a debugging session"),
    ("the session moves out of the matrix", lambda ci, pub: (
        ci.replace("      - name: Require every planned job\n", "      - uses: mxschmitt/action-tmate@35b54afac29c97fb54faba5b513f8fbd1882f113 # v3.24\n        timeout-minutes: 5\n        with:\n          limit-access-to-actor: true\n      - name: Require every planned job\n"), pub),
     "belongs only in the test matrix"),
    ("one session is dropped", lambda ci, pub: (
        ci[:ci.index("      - name: Open a tmate session after a failure")] + ci[ci.index("\n  # One check to require"):], pub),
     "before the tests and one after a failure"),
    ("the job timeout ignores the session", lambda ci, pub: (
        ci.replace("${{ matrix.tmate == 'off' && 20 || 60 }}", "20"), pub), "cap its time"),
    ("the tmate input offers another mode", lambda ci, pub: (
        ci.replace("options: [off, before-tests, on-failure]", "options: [off, always]"), pub), "plan's modes"),
    ("the tmate input defaults to a session", lambda ci, pub: (
        ci.replace("default: 'off'", "default: before-tests"), pub), "default to off"),
    ("the plan stops hearing the tmate input", lambda ci, pub: (
        ci.replace("          TMATE: ${{ inputs.tmate }}\n", ""), pub), "plan: must pass the tmate input"),
    ("a dispatch shares its group with the push", lambda ci, pub: (replaced(
        ci, "github.event_name == 'workflow_dispatch' && github.run_id || ", ""), pub),
     "a dispatch run must have its own concurrency group"),
    ("a push no longer cancels its predecessor", lambda ci, pub: (replaced(
        ci, "cancel-in-progress: true", "cancel-in-progress: false"), pub),
     "must still cancel the run they supersede"),
    ("a pull request shares one group with every other", lambda ci, pub: (replaced(
        ci, "github.event.pull_request.number || github.ref", "github.ref"), pub),
     "must still cancel the run they supersede"),
    ("the workflow_call scope is optional", lambda ci, pub: (replaced(
        ci, "        required: true\n", "        required: false\n"), pub), "scope input must be required"),
    ("the release stops calling ci.yml", lambda ci, pub: (ci, replaced(
        pub, "uses: ./.github/workflows/ci.yml", "uses: ./.github/workflows/docs.yml")), "validate must call ci.yml"),
    ("the release asks for the edges", lambda ci, pub: (ci, replaced(
        pub, "      scope: full", "      scope: edges")), "ask for scope full"),
    ("the release passes no scope", lambda ci, pub: (ci, without(pub, "    with:\n      scope: full\n")),
     "ask for scope full"),
    ("the upload stops waiting for validation", lambda ci, pub: (ci, replaced(
        pub, "    needs: validate\n", "")), "the upload must wait"),
]


class WorkflowFollowsThePlan(unittest.TestCase):
    def test_the_workflows_follow_the_plan(self):
        self.assertEqual(problems(CI, PUBLISH), [])

    def test_the_debugging_session_is_safe(self):
        self.assertEqual(session_problems(CI, PUBLISH), [])

    def test_no_other_workflow_opens_a_session(self):
        for path in (ROOT / ".github/workflows").glob("*.yml"):
            if path.name != "ci.yml":
                self.assertNotIn(TMATE, path.read_text(), path.name)

    def test_a_mutation_is_reported(self):
        for description, mutate, message in MUTATIONS:
            with self.subTest(description):
                reported = [*problems(*mutate(CI, PUBLISH)), *session_problems(*mutate(CI, PUBLISH))]
                self.assertTrue([each for each in reported if message in each], (message, reported))

    def test_the_workflow_runs_every_job_the_plan_names(self):
        names = {each["name"] for each in ci_plan.plan(MANIFEST, event="push")["matrix"]["include"]}
        self.assertIn("Outer current", names)
        self.assertEqual(field(split_jobs(CI)["validate"], "name"), "${{ matrix.name }}")
        self.assertIn("if: matrix.name == 'Outer current'", CI)


if __name__ == "__main__":
    unittest.main()
