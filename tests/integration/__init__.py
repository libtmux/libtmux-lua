"""Importing this package enters the sandbox, so a direct unittest run is covered.

tests/run_integration.py enters before it discovers; naming a module with
`python3 -m unittest tests.integration.test_x` imports this package first and
would otherwise reach tmux with the caller's TMUX, TMUX_PANE and TMUX_TMPDIR.
"""

import sys

from tests.support import sandbox

try:
    sandbox.enter()
except sandbox.Refused as error:
    print(f"integration tests refused to run: {error}", file=sys.stderr)
    raise SystemExit(2) from error
