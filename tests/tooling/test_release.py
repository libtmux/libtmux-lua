"""Critical release preparation and publication guards, without network access."""

import json
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from scripts import release


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="libtmux-lua-release-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "rockspecs").mkdir()
        (self.root / "lua/libtmux").mkdir(parents=True)
        (self.root / "lua/libtmux/init.lua").write_text('return { _VERSION = "scm" }\n')
        (self.root / "rockspecs/libtmux-scm-1.rockspec").write_text('''rockspec_format = "3.0"
package = "libtmux"
version = "scm-1"
source = { url = "git+https://github.com/libtmux/libtmux-lua.git" }
description = { summary = "Lua tmux API", license = "MIT" }
dependencies = { "lua >= 5.1, < 5.6" }
build = { type = "builtin", modules = { libtmux = "lua/libtmux/init.lua" } }
''')
        (self.root / "CHANGES.md").write_text("# Changelog\n\n## Unreleased\n\n- Initial core.\n")
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)

    def prepare(self, *arguments):
        return subprocess.run(
            [sys.executable, str(ROOT / "scripts/release.py"), "prepare", *arguments],
            cwd=self.root, text=True, capture_output=True,
        )

    def snapshot(self):
        return {str(p.relative_to(self.root)): p.read_bytes()
                for p in self.root.rglob("*") if p.is_file() and ".git" not in p.parts}

    def test_prepare_and_check_keep_one_alpha_identity(self):
        result = self.prepare("0.1.0alpha1-1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.root / "release.json").read_text()),
                         {"package": "libtmux", "version": "0.1.0alpha1-1"})
        self.assertEqual((self.root / "lua/libtmux/init.lua").read_text(),
                         'return { _VERSION = "0.1.0alpha1" }\n')
        self.assertFalse((self.root / "libtmux-scm-1.rockspec").exists(),
                         "preparation leaked a temporary LuaRocks input into the checkout")
        self.assertIn('## 0.1.0alpha1-1\n\n- Initial core.',
                      (self.root / "CHANGES.md").read_text())
        before = self.snapshot()
        checked = self.prepare("0.1.0alpha1-1", "--check")
        self.assertEqual(checked.returncode, 0, checked.stderr)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.prepare("0.1.0alpha1-1").returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_check_rejects_runtime_drift_without_repairing_it(self):
        result = self.prepare("0.1.0alpha1-1")
        self.assertEqual(result.returncode, 0, result.stderr)
        (self.root / "lua/libtmux/init.lua").write_text('return { _VERSION = "wrong" }\n')
        before = self.snapshot()
        checked = self.prepare("0.1.0alpha1-1", "--check")
        self.assertNotEqual(checked.returncode, 0)
        self.assertIn("lua/libtmux/init.lua", checked.stderr)
        self.assertEqual(self.snapshot(), before)

    def test_dated_release_preserves_notes_and_pending_changes(self):
        result = self.prepare("0.1.0alpha1-1")
        self.assertEqual(result.returncode, 0, result.stderr)
        notes = self.root / "CHANGES.md"
        for pending in ("", "- Next release change.\n\n"):
            with self.subTest(pending=pending):
                notes.write_text("# Changelog\n\n## Unreleased\n\n" + pending +
                                 "## 0.1.0alpha1-1 (2026-09-20)\n\n- Initial core.\n")
                before = self.snapshot()
                for arguments in (("--check",), ("0.1.0alpha1-1",)):
                    result = self.prepare(*arguments)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(self.snapshot(), before)

    def test_invalid_identity_does_not_modify_files(self):
        before = self.snapshot()
        for version in ("0.1.0-alpha.1", "0.1.0alpha1-0", "scm-1", "../0.1.0-1"):
            with self.subTest(version=version):
                result = self.prepare(version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("version", result.stderr)
                self.assertEqual(self.snapshot(), before)

    def test_publication_requires_a_canonical_tag_push_and_exact_commit(self):
        result = self.prepare("0.1.0alpha1-1")
        self.assertEqual(result.returncode, 0, result.stderr)
        for args in (["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=test@example.invalid",
                     "-c", "commit.gpgsign=false", "commit", "-qm", "Release"],
                     ["tag", "v0.1.0alpha1"], ["update-ref", "refs/remotes/origin/master", "HEAD"]):
            subprocess.run(["git", *args], cwd=self.root, check=True)
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.root, text=True).strip()
        event = {"ref": "refs/tags/v0.1.0alpha1", "deleted": False,
                 "repository": {"full_name": "libtmux/libtmux-lua"}}
        release.verify_release(self.root, event, head)
        for changed, commit in ((dict(event, ref="refs/heads/master"), head),
                                (dict(event, repository={"full_name": "someone/fork"}), head),
                                (dict(event, ref="refs/tags/v0.1.0"), head),
                                (dict(event, deleted=True), head),
                                (dict(event, deleted=None), head),
                                ({"action": "published", "repository": event["repository"],
                                  "release": {"tag_name": "v0.1.0alpha1", "draft": False,
                                              "prerelease": True}}, head),
                                (event, "0" * 40)):
            with self.subTest(event=changed, commit=commit), self.assertRaises(ValueError):
                release.verify_release(self.root, changed, commit)

    def test_upload_rejects_changed_bytes_and_unpublished_source_artifacts(self):
        result = self.prepare("0.1.0alpha1-1")
        self.assertEqual(result.returncode, 0, result.stderr)
        directory = self.root / "artifacts"
        directory.mkdir()
        spec = "libtmux-0.1.0alpha1-1.rockspec"
        (directory / spec).write_bytes((self.root / "rockspecs" / spec).read_bytes())
        rock = "libtmux-0.1.0alpha1-1.src.rock"
        (directory / rock).write_bytes(b"validated artifact fixture")
        hashes = {name: hashlib.sha256((directory / name).read_bytes()).hexdigest() for name in (spec, rock)}
        manifest = {"package": "libtmux", "version": "0.1.0alpha1-1", "head": "abc",
                    "dirty": False, "source": "public-tag", "artifacts": hashes}
        (directory / "candidate.json").write_text(json.dumps(manifest))
        (directory / "SHA256SUMS").write_text("".join(f"{value}  {key}\n" for key, value in hashes.items()))
        release.verify_artifacts(self.root, directory, "abc")
        for changed in (dict(manifest, source="local-fixture"), dict(manifest, dirty=True),
                        dict(manifest, head="other")):
            (directory / "candidate.json").write_text(json.dumps(changed))
            with self.assertRaises(ValueError):
                release.verify_artifacts(self.root, directory, "abc")
        (directory / "candidate.json").write_text(json.dumps(manifest))
        (directory / rock).write_bytes(b"changed after validation")
        with self.assertRaisesRegex(ValueError, "checksum"):
            release.verify_artifacts(self.root, directory, "abc")

    def test_packaging_revision_keeps_the_source_version(self):
        result = self.prepare("0.1.0alpha1-1")
        self.assertEqual(result.returncode, 0, result.stderr)
        notes = self.root / "CHANGES.md"
        notes.write_text(notes.read_text().replace("## Unreleased\n", "## Unreleased\n\n- Fix packaging.\n"))
        result = self.prepare("0.1.0alpha1-2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "lua/libtmux/init.lua").read_text(),
                         'return { _VERSION = "0.1.0alpha1" }\n')
        self.assertEqual(release.release_tag("0.1.0alpha1-2"), "rocks/0.1.0alpha1-2")
        self.assertTrue((self.root / "rockspecs/libtmux-0.1.0alpha1-1.rockspec").exists())


if __name__ == "__main__":
    unittest.main()
