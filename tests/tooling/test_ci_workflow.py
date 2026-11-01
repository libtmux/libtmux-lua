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


# What GitHub reads a value as when YAML 1.1 sees it bare.
YAML_BOOLEANS = {**dict.fromkeys(("y", "yes", "true", "on"), "true"),
                 **dict.fromkeys(("n", "no", "false", "off"), "false")}


def options(text):
    match = re.search(r"options: \[(.*?)\]", text)
    return [each.strip().strip("'\"") for each in match[1].split(",")] if match else None


def bare_boolean(token):
    """The boolean YAML 1.1 reads `token` as, or None when it is quoted or not one."""
    token = token.strip()
    if token[:1] in "'\"":
        return None
    return YAML_BOOLEANS.get(token.lower())


def dispatch_booleans(text):
    """Each input default or option that YAML 1.1 reads as a boolean, in a flow or a block list.

    GitHub reads a workflow as YAML 1.1, where a bare off is false. An option list
    then holds a boolean and the string default is no longer among the choices, so
    every dispatch that sets nothing is refused. The test job has no YAML 1.1
    parser, so this reads the lines of each input.
    """
    found = []
    for name, body in dispatch_inputs(text).items():
        in_options = False
        for line in body.splitlines():
            stripped = line.split(" #", 1)[0].rstrip()
            if not stripped.strip():
                continue
            item = re.match(r"\s*-\s+(.+)$", stripped)
            flow = re.match(r"\s*options:\s*\[(.*)\]$", stripped)
            if in_options and item:
                values = [item[1]]
            elif flow:
                values, in_options = flow[1].split(","), False
            else:
                values, in_options = [], stripped.strip() == "options:"
            found += [(name, "option", value.strip(), truth) for value in values if (truth := bare_boolean(value))]
            default = re.match(r"\s*default:\s*(.+)$", stripped)
            if default and (truth := bare_boolean(default[1])):
                found.append((name, "default", default[1].strip(), truth))
    return found


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
    for name, kind, value, truth in dispatch_booleans(ci):
        found.append(f"the {name} input has a bare {value} as its {kind}, which GitHub reads as the boolean {truth}; quote it")
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


def step_name(lines, at, column):
    """The name of the step whose `run` key sits on lines[at] at `column`."""
    for back in range(at, -1, -1):
        named = re.match(rf"^(?: {{{column}}}| {{{column - 2}}}- )name: *(.*)$", lines[back])
        if named:
            return named[1].strip()
        if re.match(rf"^ {{{column - 2}}}- ", lines[back]):
            break
    return f"line {at + 1}"


def run_scripts(text):
    """Yield (job, step, script) for each `run` value in a workflow or action.

    Reads `run: command` and `run: |` or `>` block scalars. A `run:` with no
    value is the `defaults` mapping, never a script.
    """
    lines = text.splitlines()
    job, in_jobs, i = None, False, 0
    while i < len(lines):
        line, at = lines[i], i
        i += 1
        if re.match(r"^[A-Za-z_-]+:", line):
            in_jobs = line.startswith("jobs:")
        elif in_jobs and (header := re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)):
            job = header[1]
        found = re.match(r"^( *)(- )?run: *(.*)$", line)
        if not found:
            continue
        column, value = len(found[1]) + 2 * bool(found[2]), found[3].strip()
        if re.fullmatch(r"[|>][+-]?\d*", value):
            body = []
            while i < len(lines) and (not lines[i].strip() or len(lines[i]) - len(lines[i].lstrip()) > column):
                body.append(lines[i])
                i += 1
            script = "\n".join(body)
        elif value:
            script = value.strip("'\"")
        else:
            continue
        yield job, step_name(lines, at, column), script


# A command word: after a line start, a separator or a shell keyword, then any
# VAR=value words and sudo with its flags.
RAW_APT = re.compile(
    r"(?:^|[;&|(]|\b(?:then|do|else)\b)\s*(?:\w+=\S*\s+)*"
    r"(?:sudo\s+(?:-\S+\s+|\w+=\S*\s+)*)?(apt(?:-get)?)(?=\s|$)"
)


def apt_problems(files):
    """Name each `run` script that calls apt or apt-get without scripts/apt-get.sh.

    The wrapper bounds a hung mirror (actions/runner-images#15040) only while
    every call goes through it. `files` maps a path to its workflow text.
    """
    found = []
    for path, text in files.items():
        for job, step, script in run_scripts(text):
            for line in script.replace("\\\n", " ").splitlines():
                call = None if line.lstrip().startswith("#") else RAW_APT.search(line)
                if call:
                    where = ": ".join(filter(None, [path, job, step]))
                    found.append(f"{where}: calls {call[1]} directly; run it through scripts/apt-get.sh")
    return found


def workflow_files():
    """Map each workflow and composite action path to its text."""
    paths = [*(ROOT / ".github/workflows").glob("*.y*ml"), *(ROOT / ".github/actions").glob("*/action.y*ml")]
    return {str(path.relative_to(ROOT)): path.read_text() for path in sorted(paths)}


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
        ci.replace("options: ['off', before-tests, on-failure]", "options: ['off', always]"), pub), "plan's modes"),
    ("the tmate options leave off bare", lambda ci, pub: (
        ci.replace("options: ['off', before-tests, on-failure]", "options: [off, before-tests, on-failure]"), pub),
     "bare off as its option"),
    ("the tmate default leaves off bare", lambda ci, pub: (
        ci.replace("default: 'off'", "default: off"), pub), "bare off as its default"),
    ("another boolean is bare in any case", lambda ci, pub: (
        ci.replace("default: 'off'", "default: No"), pub), "bare No as its default"),
    ("a choice leaves an upper case ON bare", lambda ci, pub: (
        ci.replace("options: [edges, full, custom]", "options: [edges, full, custom, ON]"), pub),
     "bare ON as its option"),
    ("the tmate options are a block list with a bare off", lambda ci, pub: (
        ci.replace("        options: ['off', before-tests, on-failure]\n",
                   "        options:\n          - off\n          - before-tests\n          - on-failure\n"), pub),
     "bare off as its option"),
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

    def test_the_workflow_as_written_has_no_bare_boolean(self):
        self.assertEqual(dispatch_booleans(CI), [])

    def test_a_quoted_block_list_has_no_bare_boolean(self):
        block = CI.replace("        options: ['off', before-tests, on-failure]\n",
                           "        options:\n          - 'off'\n          - \"before-tests\"\n          - on-failure\n")
        self.assertNotEqual(block, CI)
        self.assertEqual(dispatch_booleans(block), [])

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


def workflow_with(script, indent="          "):
    body = "\n".join(f"{indent}{line}" for line in script.splitlines())
    return (
        "on: push\njobs:\n  build:\n    runs-on: ubuntu-24.04\n    steps:\n"
        f"      - name: Install tmux\n        run: |\n{body}\n"
    )


class AptCallsUseTheWrapper(unittest.TestCase):
    FIX = "calls {} directly; run it through scripts/apt-get.sh"

    def test_the_workflows_call_only_the_wrapper(self):
        files = workflow_files()
        self.assertIn(".github/workflows/ci.yml", files)
        wrapped = [script for text in files.values() for _, _, script in run_scripts(text) if "./scripts/apt-get.sh" in script]
        self.assertTrue(wrapped, "run_scripts no longer finds the wrapper calls in the workflows")
        self.assertEqual(apt_problems(files), [])

    def test_a_raw_apt_get_names_the_file_job_step_and_fix(self):
        reported = apt_problems({"w.yml": workflow_with("sudo apt-get update")})
        self.assertEqual(reported, ["w.yml: build: Install tmux: " + self.FIX.format("apt-get")])

    def test_the_wrapper_passes(self):
        script = "./scripts/apt-get.sh update\n./scripts/apt-get.sh install --yes tmux"
        self.assertEqual(apt_problems({"w.yml": workflow_with(script)}), [])

    def test_each_way_to_call_apt_is_reported(self):
        for script, command in [
            ("apt-get update", "apt-get"),
            ("sudo apt install -y tmux", "apt"),
            ("sudo -E DEBIAN_FRONTEND=noninteractive apt-get install tmux", "apt-get"),
            ("sudo apt-get update && echo ok", "apt-get"),
            ("echo start; sudo apt-get update", "apt-get"),
            ("if true; then sudo apt-get update; fi", "apt-get"),
            ("sudo \\\n  apt-get update", "apt-get"),
        ]:
            with self.subTest(script):
                reported = apt_problems({"w.yml": workflow_with(script)})
                self.assertEqual(reported, ["w.yml: build: Install tmux: " + self.FIX.format(command)])

    def test_a_single_line_run_is_reported(self):
        text = "jobs:\n  build:\n    steps:\n      - run: sudo apt-get update\n"
        self.assertEqual(apt_problems({"w.yml": text}), ["w.yml: build: line 4: " + self.FIX.format("apt-get")])

    def test_a_composite_action_is_reported(self):
        text = "runs:\n  using: composite\n  steps:\n    - name: Deps\n      shell: bash\n      run: sudo apt-get update\n"
        self.assertEqual(apt_problems({"a/action.yml": text}), ["a/action.yml: Deps: " + self.FIX.format("apt-get")])

    def test_comments_and_other_words_pass(self):
        script = "# sudo apt-get update\n  # apt install tmux\necho 'run apt-get later'\npip install apt\n./scripts/apt-get.sh update"
        self.assertEqual(apt_problems({"w.yml": workflow_with(script)}), [])

    def test_the_defaults_mapping_is_not_a_script(self):
        text = "jobs:\n  build:\n    defaults:\n      run:\n        shell: bash\n"
        self.assertEqual(list(run_scripts(text)), [])

    def test_a_raw_call_in_the_real_workflow_is_reported(self):
        raw = replaced(CI, "          ./scripts/apt-get.sh update\n", "          sudo apt-get update\n")
        reported = apt_problems({".github/workflows/ci.yml": raw})
        self.assertEqual(len(reported), 1, reported)
        self.assertTrue(reported[0].startswith(".github/workflows/ci.yml: validate: Native build dependencies: "), reported)
        self.assertTrue(reported[0].endswith(self.FIX.format("apt-get")), reported)


if __name__ == "__main__":
    unittest.main()
