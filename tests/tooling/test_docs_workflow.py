import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class DocsWorkflowTest(unittest.TestCase):
    def workflow(self):
        return (ROOT / ".github/workflows/docs.yml").read_text()

    def test_preview_publication_uses_the_preview_role(self):
        workflow = (ROOT / ".github/workflows/docs.yml").read_text()

        self.assertIn(
            "role-arn: ${{ matrix.environment == 'docs-preview' && "
            "secrets.LIBTMUX_DOCS_PREVIEW_ROLE_ARN || "
            "secrets.LIBTMUX_DOCS_ROLE_ARN }}",
            workflow,
        )

    def test_source_exporter_and_docs_use_separate_checkouts(self):
        workflow = self.workflow()
        for path in ("port", "docs-generator", "docs"):
            self.assertIn(f"          path: {path}\n", workflow)
        self.assertNotIn("path: .site", workflow)
        self.assertNotIn("path: .docs-generator", workflow)
        self.assertIn("LIBTMUX_DOCS_CHECKOUT_LUA: ${{ github.workspace }}/port", workflow)
        self.assertIn("LIBTMUX_DOCS_GENERATOR_CHECKOUT: ${{ github.workspace }}/docs-generator", workflow)
        self.assertLess(workflow.index("publication-provenance.mjs snapshot"), workflow.index("Bootstrap the pinned LuaLS exporter"))
        self.assertIn('--source "$GITHUB_WORKSPACE/port"', workflow)
        self.assertIn('--output "$GITHUB_WORKSPACE/port/docs/_build"', workflow)
        self.assertIn("LIBTMUX_DOCS_INPUT_SNAPSHOT: ${{ runner.temp }}/build-inputs.json", workflow)

    def test_descriptor_uses_the_exact_content_upload(self):
        workflow = self.workflow()
        self.assertIn("      - id: content\n        uses: actions/upload-artifact@", workflow)
        self.assertIn("include-hidden-files: true", workflow)
        self.assertIn("ARTIFACT_ID: ${{ steps.content.outputs.artifact-id }}", workflow)
        self.assertIn("ARTIFACT_DIGEST: ${{ steps.content.outputs.artifact-digest }}", workflow)
        self.assertIn("ARTIFACT_NAME: docs-lua-${{ matrix.version }}", workflow)
        self.assertIn("name: docs-lua-${{ matrix.version }}-publication", workflow)
        self.assertIn('publication-provenance.mjs descriptor "$RUNNER_TEMP/publication.json"', workflow)
        import re
        docs = re.search(r"repository: libtmux/docs\n\s+ref: ([0-9a-f]{40})", workflow)
        self.assertIsNotNone(docs)
        self.assertIn(f"reusable-deploy.yml@{docs[1]}", workflow)

    def test_arbitrary_source_builds_do_not_restore_caches(self):
        workflow = self.workflow()
        self.assertIn("working_directory: port\n          cache: false", workflow)
        self.assertNotIn("cache: pnpm", workflow)
