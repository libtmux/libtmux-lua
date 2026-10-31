"""Building tmux from a ref keeps the pinned path intact, against a local repository."""

import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from scripts import bootstrap_native

ENVIRONMENT = {
    **{key: value for key, value in os.environ.items() if not key.startswith("GIT_")},
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_SYSTEM": os.devnull,
    "GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "test@example.com",
}

# A source tree that "builds" a tmux which reports the contents of VERSION.
CONFIGURE = """#!/bin/sh
prefix="${1#--prefix=}"
printf '#!/bin/sh\\necho tmux %s\\n' "$(cat VERSION)" > tmux
chmod +x tmux
printf 'all:\\n\\t@true\\ninstall:\\n\\tmkdir -p %s/bin\\n\\tcp tmux %s/bin/tmux\\n' "$prefix" "$prefix" > Makefile
"""


def git(directory, *arguments):
    return subprocess.run(["git", "-C", str(directory), *arguments], check=True, env=ENVIRONMENT,
                          capture_output=True, text=True).stdout.strip()


class FakeTmux(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="libtmux-lua-bootstrap-")
        cls.addClassCleanup(cls.temporary.cleanup)
        base = Path(cls.temporary.name)
        cls.repository = base / "tmux"
        cls.repository.mkdir()
        git(cls.repository, "init", "-q", "--initial-branch=master")
        (cls.repository / "autogen.sh").write_text("exit 0\n")
        (cls.repository / "configure").write_text(CONFIGURE)
        (cls.repository / "configure").chmod(0o755)
        cls.commits = {}
        for version, tags in (("one", ("v1", "one")), ("two", ())):
            (cls.repository / "VERSION").write_text(f"{version}\n")
            git(cls.repository, "add", "--all")
            git(cls.repository, "commit", "-q", "-m", version)
            cls.commits[version] = git(cls.repository, "rev-parse", "HEAD")
            for tag in tags:
                git(cls.repository, "tag", tag)
        cls.url = cls.repository.as_uri()

    def setUp(self):
        self.cache = Path(tempfile.mkdtemp(prefix="libtmux-lua-bootstrap-cache-", dir=self.temporary.name))
        (self.cache / "source").mkdir()
        for patch in (mock.patch.object(bootstrap_native, "CACHE", self.cache),
                      mock.patch.object(bootstrap_native, "TMUX_REPOSITORY", self.url)):
            patch.start()
            self.addCleanup(patch.stop)

    def build(self, ref):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            bootstrap_native.tmux_ref(ref)
        return json.loads(output.getvalue())


class BuildFromARef(FakeTmux):
    def test_a_tag_builds_its_commit_not_the_branch_head(self):
        result = self.build("v1")
        self.assertEqual((result["tmux"], result["source_revision"], result["ref"]),
                         ("tmux one", self.commits["one"], "v1"))
        self.assertEqual(Path(result["executable"]),
                         self.cache / f"toolchains/tmux-ref-{self.commits['one']}/bin/tmux")
        self.assertTrue(os.access(result["executable"], os.X_OK))

    def test_a_branch_builds_its_head(self):
        result = self.build("master")
        self.assertEqual((result["tmux"], result["source_revision"]), ("tmux two", self.commits["two"]))

    def test_a_full_commit_builds_that_commit(self):
        result = self.build(self.commits["one"])
        self.assertEqual((result["tmux"], result["source_revision"]), ("tmux one", self.commits["one"]))

    def test_a_second_build_reuses_the_source(self):
        first = self.build("v1")
        second = self.build("v1")
        self.assertEqual(first, second)

    def test_the_build_is_named_for_the_commit_never_the_ref(self):
        self.build("master")
        self.assertEqual(sorted(path.name for path in (self.cache / "toolchains").iterdir()),
                         [f"tmux-ref-{self.commits['two']}"])

    def test_an_unknown_ref_is_refused(self):
        with self.assertRaisesRegex(SystemExit, "not a tag, a branch or a full commit"):
            self.build("nowhere")

    def test_an_unusable_ref_is_refused_before_anything_is_fetched(self):
        for ref in ("-upload-pack=x", "a;b", "a1b2c3d"):
            with self.subTest(ref):
                with self.assertRaises(SystemExit):
                    self.build(ref)
        self.assertEqual(list((self.cache / "source").iterdir()), [])

    def test_a_cached_source_at_another_commit_is_refused(self):
        source = self.cache / f"source/tmux-ref-{self.commits['two']}"
        source.mkdir()
        with self.assertRaisesRegex(SystemExit, "Cached tmux source is not at"):
            self.build("master")


class PinnedBuild(FakeTmux):
    def pinned(self, version, revision):
        catalog = self.cache / "data"
        catalog.mkdir()
        (catalog / "tmux-options.json").write_text(json.dumps({"releases": {version: {"revision": revision}}}))
        output = io.StringIO()
        with mock.patch.object(bootstrap_native, "ROOT", self.cache), \
                mock.patch.object(bootstrap_native, "BRANCHES", {}), \
                mock.patch.object(bootstrap_native, "REFUSED", {}), \
                contextlib.redirect_stdout(output):
            bootstrap_native.tmux(version)
        return json.loads(output.getvalue())

    def test_a_pinned_release_builds_at_its_revision_and_checks_the_version(self):
        result = self.pinned("one", self.commits["one"])
        self.assertEqual((result["tmux"], result["source_revision"]), ("tmux one", self.commits["one"]))
        self.assertEqual(Path(result["executable"]), self.cache / "toolchains/tmux-one/bin/tmux")

    def test_a_pinned_release_at_another_revision_is_refused(self):
        with self.assertRaisesRegex(SystemExit, "differs from its pinned revision"):
            self.pinned("one", self.commits["two"])

    def test_a_pinned_release_that_reports_another_version_is_refused(self):
        with self.assertRaisesRegex(SystemExit, "reports an unexpected version: tmux one"):
            self.pinned("v1", self.commits["one"])


class Command(FakeTmux):
    def run_main(self, *arguments):
        with mock.patch.object(sys, "argv", ["bootstrap_native.py", *arguments]), \
                contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
            try:
                bootstrap_native.main()
            except SystemExit as error:
                return error.code
        return 0

    def test_tmux_needs_exactly_one_of_version_and_ref(self):
        self.assertEqual(self.run_main("tmux"), 2)
        self.assertEqual(self.run_main("tmux", "--tmux-version=3.8", "--tmux-ref=master"), 2)

    def test_the_tmux_options_apply_only_to_tmux(self):
        self.assertEqual(self.run_main("yaml", "--tmux-ref=master"), 2)
        self.assertEqual(self.run_main("luals", "--tmux-version=3.8"), 2)

    def test_standard_output_carries_only_the_json_a_workflow_reads(self):
        code = ("import sys; from pathlib import Path; sys.path.insert(0, sys.argv[1]); "
                "from scripts import bootstrap_native as b; "
                "b.CACHE = Path(sys.argv[2]); b.TMUX_REPOSITORY = sys.argv[3]; "
                "sys.argv = ['bootstrap_native.py', 'tmux', '--tmux-ref=v1']; b.main()")
        result = subprocess.run([sys.executable, "-I", "-c", code, str(ROOT), str(self.cache), self.url],
                                check=True, env=ENVIRONMENT, capture_output=True, text=True)
        lines = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(lines), 2)
        self.assertEqual(Path(lines[0]["executable"]),
                         self.cache / f"toolchains/tmux-ref-{self.commits['one']}/bin/tmux")
        self.assertIn("bootstrap_seconds", lines[1])

    def test_a_ref_builds_through_the_command(self):
        self.assertEqual(self.run_main("tmux", "--tmux-ref=v1"), 0)
        self.assertTrue((self.cache / f"toolchains/tmux-ref-{self.commits['one']}/bin/tmux").exists())


if __name__ == "__main__":
    unittest.main()
