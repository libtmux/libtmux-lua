# Complete API examples

Each Lua file is a standalone program. [run.sh](run.sh) runs one on a private
tmux server and stops that server afterward, even when the program fails. No
existing session is needed. If the server will not stop, the launcher keeps the
socket directory and says so.

Needs Lua, LuaRocks, Git, tmux 3.3a or newer, a C compiler, CMake and perl on
Linux. The launcher uses perl to confirm the server stopped. From the
repository root, install the library and its standalone runtime dependency
into a local tree:

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
| [connect.lua](connect.lua) | Connect to the launcher's server | `connected` |
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
