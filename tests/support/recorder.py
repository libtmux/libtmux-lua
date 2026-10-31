"""A stand-in tmux that records how it was called and starts nothing.

It writes the arguments and the names of the variables that select a server.
It never writes an environment value: whether TMUX_TMPDIR lies under
FAKE_TMUX_ROOT, whether the sandbox marker equals it, and whether the -S
socket lies under it are recorded as words. It exits with FAKE_TMUX_STATUS,
which is 1 when unset.

FAKE_TMUX_SERVER makes the file at the -S path stand for a server. With
"answers", kill-server removes it; with "slow", a moment after it returns;
with "stuck", never. "deaf" is "stuck" for a server that never answers its
client: kill-server writes its pid to FAKE_TMUX_ROOT/client and waits until it
is killed.
"""

import os
from pathlib import Path

SCRIPT = """#!/bin/sh
: "${FAKE_TMUX_LOG:?}" "${FAKE_TMUX_ROOT:?}"
{
  echo CALL
  previous=
  socket=none
  target=
  for argument in "$@"; do
    echo "ARG $argument"
    if [ "$previous" = -S ]; then
      target=$argument
      case "$argument" in
        "${TMUX_TMPDIR:-/nonexistent}"/*) socket=inside ;;
        *) socket=outside ;;
      esac
    fi
    previous=$argument
  done
  echo "SOCKET $socket"
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
if [ -n "${FAKE_TMUX_SERVER-}" ] && [ -n "$target" ]; then
  case "$*" in
    *kill-server)
      case "$FAKE_TMUX_SERVER" in
        answers) rm -f -- "${target:?}" ;;
        slow) (sleep 0.2; rm -f -- "${target:?}") >/dev/null 2>&1 </dev/null & ;;
        deaf) echo "$$" > "$FAKE_TMUX_ROOT/client"; exec tail -f /dev/null ;;
      esac ;;
  esac
fi
exit "${FAKE_TMUX_STATUS:-1}"
"""


def install(directory):
    """Write the recorder as an executable named tmux and return its path."""
    path = Path(directory) / "tmux"
    path.write_text(SCRIPT)
    path.chmod(0o755)
    return path


def calls(log):
    """The recorded calls: argv, selector names, and the words per call."""
    found = []
    if not os.path.exists(log):
        return found
    for line in Path(log).read_text().splitlines():
        word, _, rest = line.partition(" ")
        if word == "CALL":
            found.append({"argv": [], "set": [], "tmpdir": None, "marker": None, "socket": None})
        elif word == "ARG":
            found[-1]["argv"].append(rest)
        elif word == "SET":
            found[-1]["set"].append(rest)
        elif word == "SOCKET":
            found[-1]["socket"] = rest
        elif word == "TMPDIR":
            found[-1]["tmpdir"] = rest
        elif word == "MARKER":
            found[-1]["marker"] = rest
    return found
