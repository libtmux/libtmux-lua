# Complete API examples

Each Lua file is a standalone program. Save it beside [run.sh](run.sh), which
starts a private tmux daemon and stops it after the program finishes or fails.
No existing session is required. The connection closes without stopping the
daemon; the launcher checks that its bootstrap session still exists before
cleanup. A failed daemon shutdown keeps the socket directory and reports it.

Use Lua 5.5.1, LuaRocks, Git, tmux 3.2a or newer, a C compiler, and CMake on
Linux. From the checked-out repository root, install the library and its
standalone runtime dependency into a local tree:

```console
$ luarocks --tree ./rocks install luv 1.52.1-0 && \
  luarocks --tree ./rocks make rockspecs/libtmux-scm-1.rockspec && \
  eval "$(luarocks --tree ./rocks path)"
```

Run one complete program:

```console
$ sh examples/api/run.sh examples/api/connect.lua
```

| Program | Task | Expected output |
| --- | --- | --- |
| [connect.lua](connect.lua) | Connect to the launcher's daemon | `connected` |
| [snapshot.lua](snapshot.lua) | List sessions, windows, and panes | Two of each |
| [new_session.lua](new_session.lua) | Create a session | `session: demo` |
| [new_window.lua](new_window.lua) | Create a window in that session | `window: logs` |
| [query.lua](query.lua) | Select sessions by name | `matched: demo` |
| [send_keys.lua](send_keys.lua) | Send text and press Enter | `lua input ready` |
| [capture.lua](capture.lua) | Read a completed command's output | `lua capture ready` |

The [manifest](manifest.json) attaches whole files to existing API symbols and
records exact expected output. The native documentation export validates the
targets and includes both files needed for each program. Installed-package
checks run those files outside the checkout; no test helper is imported by
the examples.
