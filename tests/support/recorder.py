"""A stand-in tmux that records how it was called and starts nothing.

It writes the arguments and the names of the variables that select a server.
It never writes an environment value: whether TMUX_TMPDIR lies under
FAKE_TMUX_ROOT, and whether the sandbox marker equals it, are recorded as
words.
"""

import os
from pathlib import Path

SCRIPT = """#!/bin/sh
: "${FAKE_TMUX_LOG:?}" "${FAKE_TMUX_ROOT:?}"
{
  echo CALL
  for argument in "$@"; do echo "ARG $argument"; done
  env | sed -n -E 's/^(TMUX|TMUX_PANE|LIBTMUX_SOCKET[A-Z_]*)=.*/SET \\1/p'
  case "${TMUX_TMPDIR-}" in
    "") echo "TMPDIR unset" ;;
    "$FAKE_TMUX_ROOT"/*) echo "TMPDIR inside" ;;
    *) echo "TMPDIR outside" ;;
  esac
  if [ -n "${LIBTMUX_TEST_SANDBOX-}" ] && [ "${LIBTMUX_TEST_SANDBOX-}" = "${TMUX_TMPDIR-}" ]; then
    echo "MARKER matches"
  else
    echo "MARKER differs"
  fi
} >> "$FAKE_TMUX_LOG"
exit 1
"""


def install(directory):
    """Write the recorder as an executable named tmux and return its path."""
    path = Path(directory) / "tmux"
    path.write_text(SCRIPT)
    path.chmod(0o755)
    return path


def calls(log):
    """The recorded calls: argv, selector names, and the two words per call."""
    found = []
    if not os.path.exists(log):
        return found
    for line in Path(log).read_text().splitlines():
        word, _, rest = line.partition(" ")
        if word == "CALL":
            found.append({"argv": [], "set": [], "tmpdir": None, "marker": None})
        elif word == "ARG":
            found[-1]["argv"].append(rest)
        elif word == "SET":
            found[-1]["set"].append(rest)
        elif word == "TMPDIR":
            found[-1]["tmpdir"] = rest
        elif word == "MARKER":
            found[-1]["marker"] = rest
    return found
