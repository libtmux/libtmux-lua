"""Run or syntax-check every ```lua fence in the README and docs.

A fence is prose until something executes it. Each one carries a directive on the
line above, and an unclassified fence fails:

    <!-- lua: run -->               run as a program (it requires the runtime itself)
    <!-- lua: fragment -->          run inside a live server; `server`, `session`,
                                    `window`, `pane`, `snapshot` and `must` are bound
    <!-- lua: compile-only: why --> must parse; cannot run (needs a client, nvim, ...)

Usage: python3 scripts/check_doc_fences.py --lua lua
"""

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).parent))
from check import lua_environment, tool  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
FENCE = re.compile(r"(?:<!--\s*lua:\s*(?P<d>[^>]*?)\s*-->\s*\n)?^```lua[^\n]*\n(?P<b>.*?)^```", re.S | re.M)
OPENING = re.compile(r"^[ \t>]*```[ \t]*lua\b", re.I | re.M)
HARNESS = """\
local adapter = require("libtmux.runtime.luv")
local function must(value, err)
    if err ~= nil then error(tostring(err), 0) end
    return value
end
must(adapter.run(function(runtime)
    local server = must(runtime:connect({
        binary = assert(os.getenv("TMUX_BIN")), socket_path = assert(os.getenv("TMUX_SOCKET")),
    }):await())
    local created = must(server:new_session({ name = "fixture", window_name = "main", argv = { "/bin/cat" } }):await())
    local session, window, pane = created.session, created.window, created.pane
    local snapshot = must(server:snapshot():await())
    ;(function(server, session, window, pane, snapshot, must)
%s
    end)(server, session, window, pane, snapshot, must)
    must(server:close():await())
    return true
end))
"""
BOOT = """set -eu
d=$(mktemp -d); s=$d/t.sock; b=${TMUX_BIN:-$(command -v tmux)}
trap '"$b" -S "$s" kill-server 2>/dev/null; rm -rf "$d"' 0
unset TMUX TMUX_PANE
"$b" -S "$s" -f /dev/null new-session -d -s bootstrap -n bootstrap /bin/cat
export TMUX_BIN="$b" TMUX_SOCKET="$s" ENV=/dev/null BASH_ENV=/dev/null
exec "$LUA" "$1"
"""


def documents():
    return [ROOT / "README.md", *sorted((ROOT / "docs").glob("**/*.md"))]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lua", default="lua")
    args = parser.parse_args()
    lua = tool(args.lua)
    env = lua_environment(lua)
    failures, counts = [], {"run": 0, "fragment": 0, "compile-only": 0}
    for doc in documents():
        text = doc.read_text()
        found = list(FENCE.finditer(text))
        if len(found) != len(OPENING.findall(text)):
            failures.append(f"{doc.relative_to(ROOT)}: a lua fence the extractor cannot take")
        for m in found:
            where = f"{doc.relative_to(ROOT)}:{text[:m.start()].count(chr(10)) + 1}"
            kind = (m["d"] or "").split(":")[0].strip()
            if kind not in counts or (kind == "compile-only" and ":" not in m["d"]):
                failures.append(f"{where}: unclassified lua fence (needs run | fragment | compile-only: reason)")
                continue
            counts[kind] += 1
            body = m["b"]
            source = HARNESS % body if kind == "fragment" else body
            with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as handle:
                handle.write(source)
            try:
                if kind == "compile-only":
                    cmd = [lua, "-e", f"assert(loadfile({handle.name!r}))"]
                else:
                    cmd = ["sh", "-c", BOOT, "sh", handle.name]
                result = subprocess.run(cmd, env={**os.environ, **env, "LUA": lua}, capture_output=True, text=True, timeout=20, stdin=subprocess.DEVNULL)
            finally:
                os.unlink(handle.name)
            if result.returncode:
                failures.append(f"{where}: {kind} fence failed\n    " + result.stderr.strip().replace("\n", "\n    "))
    print(counts)
    for failure in failures:
        print(failure, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
