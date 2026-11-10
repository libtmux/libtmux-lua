"""A Lua source download survives a transient network failure, within a bound."""

import contextlib
import io
from pathlib import Path
import sys
import unittest
from unittest import mock
import urllib.error


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from scripts import bootstrap_runtimes


class Response(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class Download(unittest.TestCase):
    def fetch(self, outcomes):
        opener = mock.Mock(side_effect=outcomes)
        with mock.patch.object(bootstrap_runtimes.urllib.request, "urlopen", opener), \
             mock.patch.object(bootstrap_runtimes.time, "sleep"), \
             contextlib.redirect_stderr(io.StringIO()) as log:
            try:
                return bootstrap_runtimes.download("https://example.invalid/x"), opener, log.getvalue()
            except urllib.error.URLError as error:
                return error, opener, log.getvalue()

    def test_retries_a_timeout_and_logs_it(self):
        body, opener, log = self.fetch([urllib.error.URLError("timed out"), Response(b"ok")])
        self.assertEqual(body, b"ok")
        self.assertEqual(opener.call_count, 2)
        self.assertIn("attempt 1 of", log)

    def test_gives_up_after_the_bound(self):
        error, opener, _ = self.fetch([urllib.error.URLError("timed out")] * 10)
        self.assertIsInstance(error, urllib.error.URLError)
        self.assertEqual(opener.call_count, bootstrap_runtimes.ATTEMPTS)


if __name__ == "__main__":
    unittest.main()
