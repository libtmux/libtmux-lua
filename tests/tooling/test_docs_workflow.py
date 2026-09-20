import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class DocsWorkflowTest(unittest.TestCase):
    def test_preview_publication_uses_the_preview_role(self):
        workflow = (ROOT / ".github/workflows/docs.yml").read_text()

        self.assertIn(
            "role-arn: ${{ matrix.environment == 'docs-preview' && "
            "secrets.LIBTMUX_DOCS_PREVIEW_ROLE_ARN || "
            "secrets.LIBTMUX_DOCS_ROLE_ARN }}",
            workflow,
        )
