# Complete API examples

Each Lua file is a standalone program. It starts its own private tmux
server with `Runtime:start_server`, uses it and stops it, even when the program
fails. No existing session is needed.

Needs Lua, LuaRocks, Git, tmux 3.3a or newer, a C compiler and CMake on Linux.
The programs use `/usr/bin/tmux`; set `TMUX_BIN` to another absolute path to
change that. From the repository root, install the library and its standalone
runtime dependency into a local tree:

```console
$ luarocks --tree ./rocks install luv 1.52.1-0 && \
  luarocks --tree ./rocks make rockspecs/libtmux-scm-1.rockspec && \
  eval "$(luarocks --tree ./rocks path)"
```

Run one complete program:

```console
$ lua examples/api/connect.lua
```

| Program | Task | Expected output |
| --- | --- | --- |
| [start_server.lua](start_server.lua) | Start a private server, use it and stop it | `sessions: 0, then 1` |
| [with_server.lua](with_server.lua) | Run a body on a server that stops when the body ends | `sessions: 1` |
| [connect.lua](connect.lua) | Connect a second handle to a started server | `connected` |
| [capabilities.lua](capabilities.lua) | Check a feature on the connected daemon | `named deletion requires: 3.4`, then `daemon decision checked` |
| [snapshot.lua](snapshot.lua) | List sessions, windows, and panes | Two of each |
| [new_session.lua](new_session.lua) | Create a session | `session: demo` |
| [new_window.lua](new_window.lua) | Create a window in that session | `window: logs` |
| [resize.lua](resize.lua) | Resize a window and a pane | `window 100x30, pane 30 wide` |
| [refresh.lua](refresh.lua) | Read a window again after renaming it | `editor build` |
| [query.lua](query.lua) | Select sessions by name | `matched: demo` |
| [explain.lua](explain.lua) | Show what a pane query runs in tmux and what stays local | Two plans, `never` and `auto` |
| [group.lua](group.lua) | Create a session and two windows in one tmux call | `windows: main, build, test` |
| [send_keys.lua](send_keys.lua) | Send text and press Enter | `lua input ready` |
| [capture.lua](capture.lua) | Read a completed command's output | `lua capture ready` |
| [wait_for_text.lua](wait_for_text.lua) | Wait for text on the visible screen | `lua wait ready` |
| [watch_pane.lua](watch_pane.lua) | Stream a pane's output over control mode (tmux 3.7 or newer) | `output: watched` |
| [unsupported_version.lua](unsupported_version.lua) | Handle a tmux below the minimum | `unsupported_version` and its message |

The [manifest](manifest.json) ties each program to the API symbols it shows
and its exact output.
