"""The CI manifest, the tmux catalog, the bootstrap scripts and the docs agree."""

import copy
import json
from pathlib import Path
import re
import sys
import unittest


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from scripts import bootstrap_hosts, bootstrap_native, bootstrap_runtimes

FULL_SHA = re.compile(r"[0-9a-f]{40}")


def table_row(docs, component):
    found = re.search(rf"^\| {re.escape(component)} \| (.+?) \|$", docs, re.MULTILINE)
    return found[1] if found else None


def problems(manifest, catalog, docs):
    """Name each way the manifest and what it describes disagree."""
    found = []
    releases = list(catalog["releases"])
    unit = [each for each in manifest["unit"] if each != "luajit"]
    if table_row(docs, "tmux") != ", ".join(releases):
        found.append("the docs tmux row differs from the catalog releases")
    if table_row(docs, "PUC Lua") != ", ".join(unit):
        found.append("the docs PUC Lua row differs from the unit runtimes")
    if table_row(docs, "Neovim") != ", ".join(manifest["nvim"]):
        found.append("the docs Neovim row differs from the manifest hosts")
    for name in manifest["development"]:
        if name not in releases:
            found.append(f"development build {name} is not in the catalog")
    if not [each for each in releases if each not in manifest["development"]]:
        found.append("the catalog has no released version")
    pin = manifest["outer"]["current"].get("full_tmux")
    if pin is not None and pin not in releases:
        found.append(f"the full-scope outer pin {pin} is not in the catalog")
    refusal = next((each for each in docs.split("\n\n") if "refusal lane" in each), "")
    for name, lane in manifest["refused"].items():
        if name in releases:
            found.append(f"refused release {name} is in the catalog")
        if not FULL_SHA.fullmatch(lane["revision"]):
            found.append(f"refused release {name} has no full revision")
        if not re.search(rf"\b{re.escape(name)}\b", refusal):
            found.append(f"the docs refusal lanes omit {name}")
    runtimes = {*bootstrap_runtimes.RELEASES, "luajit"}
    wanted = {*manifest["unit"], manifest["stack"]["lua"],
              *(each["lua"] for each in manifest["outer"].values())}
    if wanted - runtimes:
        found.append("the manifest names a Lua runtime the bootstrap cannot build")
    hosts = {manifest["stack"]["nvim"], *(each["nvim"] for each in manifest["outer"].values())}
    if (hosts | set(manifest["nvim"])) - set(bootstrap_hosts.RELEASES):
        found.append("the manifest names a Neovim host the bootstrap cannot install")
    if not hosts <= set(manifest["nvim"]) or manifest["stack"]["lua"] not in manifest["unit"]:
        found.append("the default stack is not one the dispatch inputs accept")
    refused = {name: lane["revision"] for name, lane in manifest["refused"].items()}
    if bootstrap_native.REFUSED != refused or bootstrap_native.BRANCHES != manifest["development"]:
        found.append("bootstrap_native does not build what the manifest lists")
    return found


class ManifestAgreement(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads((ROOT / "data/ci-matrix.json").read_text())
        self.catalog = json.loads((ROOT / "data/tmux-options.json").read_text())
        self.docs = (ROOT / "docs/compatibility.md").read_text()

    def test_the_repository_agrees(self):
        self.assertEqual(problems(self.manifest, self.catalog, self.docs), [])

    def test_a_docs_row_that_drifts_is_reported(self):
        for component, old in (("tmux", "3.8, next-3.9"), ("PUC Lua", "5.5.1"), ("Neovim", "0.12.5")):
            with self.subTest(component):
                docs = re.sub(rf"(^\| {component} \| .*?){re.escape(old)} \|$",
                              r"\1|", self.docs, flags=re.MULTILINE)
                self.assertNotEqual(docs, self.docs)
                self.assertTrue(problems(self.manifest, self.catalog, docs))

    def test_a_development_build_outside_the_catalog_is_reported(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["development"]["3.9"] = "release_3.9"
        self.assertIn("development build 3.9 is not in the catalog",
                      problems(manifest, self.catalog, self.docs))

    def test_an_outer_pin_outside_the_catalog_is_reported(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["outer"]["current"]["full_tmux"] = "3.9"
        self.assertIn("the full-scope outer pin 3.9 is not in the catalog",
                      problems(manifest, self.catalog, self.docs))

    def test_a_refused_release_in_the_catalog_is_reported(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["refused"]["3.4"] = {"revision": "0" * 40, "old_daemon": False}
        self.assertIn("refused release 3.4 is in the catalog",
                      problems(manifest, self.catalog, self.docs))

    def test_a_short_refused_revision_is_reported(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["refused"]["3.3"]["revision"] = "87fe00e"
        self.assertIn("refused release 3.3 has no full revision",
                      problems(manifest, self.catalog, self.docs))

    def test_a_refusal_lane_the_docs_omit_is_reported(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["refused"]["2.9"] = {"revision": "0" * 40, "old_daemon": False}
        self.assertIn("the docs refusal lanes omit 2.9",
                      problems(manifest, self.catalog, self.docs))

    def test_a_runtime_or_host_the_bootstrap_lacks_is_reported(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["unit"].append("5.6.0")
        self.assertIn("the manifest names a Lua runtime the bootstrap cannot build",
                      problems(manifest, self.catalog, self.docs))
        manifest = copy.deepcopy(self.manifest)
        manifest["nvim"].append("0.99.0")
        self.assertIn("the manifest names a Neovim host the bootstrap cannot install",
                      problems(manifest, self.catalog, self.docs))

    def test_a_default_stack_the_inputs_reject_is_reported(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["stack"]["nvim"] = "0.10.4"
        self.assertIn("the default stack is not one the dispatch inputs accept",
                      problems(manifest, self.catalog, self.docs))

    def test_a_catalog_without_a_release_is_reported(self):
        catalog = {"releases": {name: {} for name in self.manifest["development"]}}
        self.assertIn("the catalog has no released version",
                      problems(self.manifest, catalog, self.docs))

    def test_a_bootstrap_that_builds_something_else_is_reported(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["development"]["next-3.9"] = "other"
        self.assertIn("bootstrap_native does not build what the manifest lists",
                      problems(manifest, self.catalog, self.docs))


if __name__ == "__main__":
    unittest.main()
