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

    def test_a_mutation_is_reported(self):
        for description, mutate, message in MUTATIONS:
            with self.subTest(description):
                reported = problems(*mutate(CI, PUBLISH))
                self.assertTrue([each for each in reported if message in each], (message, reported))

    def test_the_workflow_runs_every_job_the_plan_names(self):
        names = {each["name"] for each in ci_plan.plan(MANIFEST, event="push")["matrix"]["include"]}
        self.assertIn("Outer current", names)
        self.assertEqual(field(split_jobs(CI)["validate"], "name"), "${{ matrix.name }}")
        self.assertIn("if: matrix.name == 'Outer current'", CI)


if __name__ == "__main__":
    unittest.main()
