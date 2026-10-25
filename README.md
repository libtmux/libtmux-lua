<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="assets/logo.svg" type="image/svg+xml">
    <img src="assets/logo.png" width="128" height="128" alt="libtmux for Lua">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# libtmux for Lua

Script tmux from Lua: [create sessions and panes][ref-server-new-session],
[capture terminal output][ref-pane-capture],
[query server state][ref-server-query], and
[watch pane output][ref-observation-watch-pane]. Use standalone Lua with luv or
Neovim's event loop.

</div>

**Alpha software.** The core API is still changing. The separate MCP and
workspace packages are unpublished scaffolds.

**Contents** — [Quick start](#quick-start) ·
[Read tmux](#read-what-tmux-has-now) ·
[Create](#create-sessions-windows-and-panes) ·
[Type and read](#type-into-a-pane-and-read-the-answer) ·
[Neovim](#use-it-from-neovim) · [Packages](#packages) ·
[Leaves out](#what-it-leaves-out) · [Support](#support-and-status) ·
[Guides](#guides) ·
[CI](https://github.com/libtmux/libtmux-lua/actions/workflows/ci.yml) ·
[MIT license](LICENSE)

## Quick start

Standalone scripts run on `luv`, the event loop. Building `luv` needs a C
compiler, make and CMake. Install them first:

- Debian and Ubuntu: `build-essential` and `cmake`.
- Fedora: `gcc`, `make` and `cmake`.
- macOS (not a CI platform): the Xcode command line tools
  (`xcode-select --install`) and `cmake`.

If the `luv` build fails, use a system package where one exists, such as
`lua-luv` on Debian and Ubuntu. It serves only the distribution's own Lua,
not one built elsewhere.

Install the core alpha, then `luv`, skipping `luv` if you installed the
system package:

```console
$ luarocks --local install libtmux 0.1.0alpha3-1
```

```console
$ luarocks --local install luv 1.52.1-0
```

Add the local rocks tree to Lua's module paths:

```console
$ eval "$(luarocks --local path)"
```

Create a session and read it back. This is the whole program:

<!-- example: examples/api/new_session.lua -->

```lua
local adapter = require("libtmux.runtime.luv")

local function must(value, err)
    if err ~= nil then
        error(tostring(err), 0)
    end
    return value
end

local binary = assert(os.getenv("TMUX_BIN"), "set TMUX_BIN to an absolute tmux executable")
local socket = assert(os.getenv("TMUX_SOCKET"), "set TMUX_SOCKET to the private socket")

must(adapter.run(function(runtime)
    local server = must(runtime:connect({ binary = binary, socket_path = socket }):await())
    local created = must(server
        :new_session({
            name = "demo",
            window_name = "main",
            argv = { "/bin/cat" },
        })
        :await())
    assert(created.session and created.window and created.pane, "creation handles are missing")
    local snapshot = must(created.session:snapshot():await())
    assert(snapshot.name == "demo", "created session has the wrong name")
    print("session: " .. snapshot.name)

    must(server:close():await())
    return true
end))
```

[`Runtime:connect`][ref-runtime-connect] binds the socket you name, because
the library never picks or starts a server.
[`Server:new_session`][ref-server-new-session] creates the session and
[`Session:snapshot`][ref-session-snapshot] reads it back.

Live calls return [Requests][ref-request]. [`:await()`][ref-request-await]
yields inside the [runtime][ref-runtime] body and returns `value, err`; the
`must` helper turns an error into a raised one.

The program reads `TMUX_BIN` and `TMUX_SOCKET`, absolute paths to tmux and a
socket. To run it without touching a tmux you use, clone the repository:

```console
$ git clone https://github.com/libtmux/libtmux-lua.git && cd libtmux-lua
```

Its launcher starts a tmux server on a private socket, runs the program, and
stops the server:

```console
$ sh examples/api/run.sh examples/api/new_session.lua
session: demo
```

Every Lua block on this page is quoted from a program under
[`examples/`](examples/) that CI runs, against a real tmux wherever the block
uses one. Excerpts that talk to tmux run inside the same runtime body, with
`server` and `must` in hand.

## Read what tmux has now

### [`Server:snapshot`][ref-server-snapshot]: what tmux has now

One call reads every session, window and pane the server holds.
[`snapshot.sessions`][ref-snapshot-sessions],
[`snapshot.windows`][ref-snapshot-windows] and
[`snapshot.panes`][ref-snapshot-panes] list them. This prints each pane and
its window:

<!-- excerpt: examples/snapshot.lua -->

```lua
local snapshot = must(server:snapshot({ strict = true }):await())
for _, pane in ipairs(snapshot.panes) do
    io.stdout:write(pane.id, "\t", pane.window_id, "\n")
end
```

The launcher's server has one pane, so the complete
[`snapshot.lua`](examples/snapshot.lua) prints its pane ID and window ID:

```console
$ sh examples/api/run.sh examples/snapshot.lua
%0	@0
```

A [snapshot][ref-snapshot] is a record of what tmux held when it was read. It
does not change when tmux does, and it spans several tmux commands, so it is
not an atomic view. `strict = true` adds a verification pass. Call
[`Server:snapshot`][ref-server-snapshot] again to refresh.

### [`Selection:where`][ref-selection-where]: narrow what you read

[`Selection:where`][ref-selection-where] narrows a collection by structured
criteria, and [`Selection:filter`][ref-selection-filter] by a Lua function.
Both work on [`snapshot.panes`][ref-snapshot-panes] and on any list you give
[`query.select`][ref-query-select], and neither calls tmux:

<!-- excerpt: examples/native_query.lua -->

```lua
local panes = query.select(rows, schema)
local editors = panes:where({ current_command = { one_of = { "nvim", "vim" } } })
assert(#editors == 2 and editors[1] == rows[1] and editors[2] == rows[3])

local inactive = panes:filter(function(pane)
    return not pane.active
end)
assert(#inactive == 2 and inactive[1].id == "%2")
for _, pane in ipairs(editors) do
    print(pane.id, pane.current_command)
end
```

[`native_query.lua`](examples/native_query.lua) defines `rows` and `schema`
and needs only Lua. It prints the panes whose command is `nvim` or `vim`:

```console
$ lua examples/native_query.lua
%1	nvim
%3	vim
```

[Criteria and relationships](docs/query.md) and the
[field reference](docs/fields.md) list what `where` accepts.

### [`Server:query`][ref-server-query]: read and filter in one call

[`Server:query`][ref-server-query] captures a snapshot and applies `where` to
it. `kind` picks the record type. The rows come back as a
[Selection][ref-selection] beside the snapshot behind them:

<!-- excerpt: examples/api/query.lua -->

```lua
local result = must(server
    :query({
        kind = "session",
        where = { name = "demo" },
        snapshot = { strict = true },
    })
    :await())
assert(result.complete, "query observed a topology change")
assert(#result.rows == 1 and result.rows[1].name == "demo", "query selected the wrong session")
print("matched: " .. result.rows[1].name)
```

The program creates sessions named `demo` and `worker`, so the filter matches
one:

```console
$ sh examples/api/run.sh examples/api/query.lua
matched: demo
```

`complete` reports no known inconsistency. The read is still not atomic.

## Create sessions, windows and panes

### [`Session:new_window`][ref-session-new-window]: add a window

[`Session:new_window`][ref-session-new-window] adds a window to a session.
Like [`Server:new_session`][ref-server-new-session], it returns a
[`Creation`][ref-creation] holding [`session`][ref-session],
[`window`][ref-window], [`pane`][ref-pane] and
[`window_link`][ref-windowlink] handles:

<!-- excerpt: examples/api/new_window.lua -->

```lua
local created = must(server
    :new_session({
        name = "demo",
        window_name = "main",
        argv = { "/bin/cat" },
    })
    :await())
local logs = must(created.session:new_window({ name = "logs", argv = { "/bin/cat" } }):await())
local snapshot = must(logs.window:snapshot():await())
assert(snapshot.name == "logs", "created window has the wrong name")
print("window: " .. snapshot.name)
```

`argv` is the literal command the pane runs. Leave it out for tmux's default
shell.

```console
$ sh examples/api/run.sh examples/api/new_window.lua
window: logs
```

Creation does not wait for the program to start or report whether it
succeeds. Closing the server handle leaves what you created running.

### [`Pane:split`][ref-pane-split]: divide a window

[`Pane:split`][ref-pane-split] splits a pane to the `left`, `right`, `up` or
`down`, sized by `percent` or `size`. The new pane is [`split.pane`][ref-pane]:

<!-- excerpt: examples/quickstart.lua -->

```lua
local logs = must(created.session:new_window({ name = "logs", argv = { "/bin/cat" } }):await())
local split =
    must(logs.pane:split({ direction = "right", percent = 40, argv = { "/bin/cat" } }):await())
```

[`quickstart.lua`](examples/quickstart.lua) creates a session, a window and
this split, then prints their IDs. New windows and splits leave the
selection alone unless you pass `select = true`:

```console
$ sh examples/api/run.sh examples/quickstart.lua
$1	@2	%3
```

## Type into a pane and read the answer

### [`Pane:send_text`][ref-pane-send-text]: type a command

[`Pane:send_text`][ref-pane-send-text] types literal text and adds no Enter.
[`Pane:send_keys`][ref-pane-send-keys] presses named keys such as `Enter`.

Success means tmux accepted the input while the command may still be running.
The example waits on a tmux `wait-for` channel with
[`Server:command`][ref-server-command]:

<!-- excerpt: examples/api/send_keys.lua -->

```lua
-- Signal completion on this socket; do not guess when the shell has printed.
local command = "printf '\\nlua input ready\\n'; "
    .. quote(binary)
    .. " -S "
    .. quote(socket)
    .. " wait-for -S example-ready"
must(pane:send_text(command):await())
must(pane:send_keys({ "Enter" }):await())
must(server:command({ "wait-for", "example-ready" }, { timeout = 1000 }):await())
```

`quote` shell-quotes the tmux path and socket for the pane's shell. The
program goes on to capture the pane and print the line the command wrote:

```console
$ sh examples/api/run.sh examples/api/send_keys.lua
lua input ready
```

[`Server:command`][ref-server-command] runs any tmux command from literal
arguments. A nonzero exit is part of the result.

### [`Pane:capture`][ref-pane-capture]: read the screen

[`Pane:capture`][ref-pane-capture] returns the screen tmux drew.
`history_lines = 20` adds up to 20 rows of history.
[`capture:text()`][ref-capture-text] returns the bytes as UTF-8, or an
[`invalid_utf8`](docs/panes.md#capture-and-text) error:

<!-- excerpt: examples/api/capture.lua -->

```lua
local capture = must(pane:capture({ history_lines = 20 }):await())
local found = false
for line in must(capture:text()):gmatch("[^\r\n]+") do
    if line == "lua capture ready" then
        found = true
    end
end
assert(found, "completed command did not print the expected line")
print("lua capture ready")
```

```console
$ sh examples/api/run.sh examples/api/capture.lua
lua capture ready
```

A capture holds the cells tmux rendered, so it cannot say whether a command
finished. [Pane operations](docs/panes.md) lists the capture options, from
joined lines to escape sequences.

### [`Pane:wait_for_text`][ref-pane-wait-for-text]: wait for text on screen

[`Pane:wait_for_text`][ref-pane-wait-for-text] polls the visible screen on
every supported tmux release until it holds the literal text.

The result has the matching screen and `matched_at_entry`, true when the
first read already matched. Pass `timeout` or `deadline` to bound the wait.

<!-- excerpt: examples/api/wait_for_text.lua -->

```lua
-- The shell echoes what is typed, so print the needle from two pieces.
must(pane:send_text("printf '%s%s\\n' 'lua wait ' 'ready'"):await())
must(pane:send_keys({ "Enter" }):await())
local found = must(pane:wait_for_text("lua wait ready", { timeout = 5000 }):await())
assert(found.text:find("lua wait ready", 1, true))
print("lua wait ready")
```

```console
$ sh examples/api/run.sh examples/api/wait_for_text.lua
lua wait ready
```

If the pane exits first, the wait ends with `pane_died` and the text seen so
far. See [waiting for pane text](docs/panes.md#wait-for-text) for the read,
the hooks it runs and every end state.

## Use it from Neovim

### [`runtime.nvim.start`][ref-nvim-start]: borrow the editor's loop

[`start`][ref-nvim-start] returns at once, runs the body on Neovim's loop and
calls `on_done(value, err)` after the work it owns has finished. Handles it
did not create stay open:

<!-- example: examples/nvim_snapshot.lua -->

```lua
local adapter = require("libtmux.runtime.nvim")

adapter.start(function(runtime)
    local server, err = runtime
        :connect({
            binary = vim.fn.exepath("tmux"),
            socket_path = assert(os.getenv("TMUX_SOCKET")),
        })
        :await()
    if not server then
        return nil, err
    end
    return server:snapshot({ strict = true }):await()
end, function(snapshot, err)
    if err then
        vim.notify(tostring(err), vim.log.levels.ERROR)
        return
    end
    vim.notify(("Panes: %d"):format(#snapshot.panes))
end)
```

From the checkout, start Neovim with the library on its `runtimepath` and set
`TMUX_SOCKET` to the absolute path of a server's socket:

```console
$ TMUX_SOCKET=/path/to/tmux.sock nvim \
    --cmd 'set runtimepath+=.' \
    -c 'luafile examples/nvim_snapshot.lua'
```

Neovim then shows the server's pane count. It has its own libuv binding, so
the `luv` rock is not needed here.

The runtime closes its connections when the body finishes and leaves the tmux
server running. See [runtime ownership and cancellation](docs/runtime.md).

## Packages

| Package | Source | Reference | What it is |
| --- | --- | --- | --- |
| `libtmux` | [`lua/libtmux/`](https://github.com/libtmux/libtmux-lua/tree/master/lua/libtmux) | [libtmux.org](https://libtmux.org/en/lua/latest/reference/) | The library. Sessions, windows, panes, snapshots, queries and two event-loop adapters. |
| `libtmux-workspace` | [`packages/workspace/`](https://github.com/libtmux/libtmux-lua/tree/master/packages/workspace) | [libtmux.org](https://libtmux.org/en/lua/latest/workspace/) | An unpublished scaffold for workspace operations. |
| `libtmux-mcp` | [`packages/mcp/`](https://github.com/libtmux/libtmux-lua/tree/master/packages/mcp) | [libtmux.org](https://libtmux.org/en/lua/latest/mcp/) | An unpublished scaffold for the MCP server. |

Each heading below links to its directory on GitHub, which LuaRocks does not
show. Only `libtmux` is published. `libtmux-workspace` and `libtmux-mcp` are
unpublished scaffolds with no public API.

### [`libtmux`](https://github.com/libtmux/libtmux-lua/tree/master/lua/libtmux): the library

Create sessions, windows and panes, capture pane output, query server state
and watch pane output, on luv or Neovim's event loop. Reference:

- [LuaRocks](https://luarocks.org/modules/tony/libtmux) and
  [libtmux.org](https://libtmux.org/en/lua/latest/reference/).
- [`libtmux.Server`](https://libtmux.org/en/lua/latest/reference/libtmux-server/),
  [`libtmux.runtime.luv`](https://libtmux.org/en/lua/latest/reference/libtmux-runtime-luv/),
  [`libtmux.runtime.nvim`](https://libtmux.org/en/lua/latest/reference/libtmux-runtime-nvim/)
  and [`libtmux.query`](https://libtmux.org/en/lua/latest/reference/libtmux-query/).

Importing a module starts neither tmux nor an event loop, and
[local queries][ref-query] need only Lua. To install from a checkout instead
of LuaRocks:

```console
$ luarocks --local make rockspecs/libtmux-scm-1.rockspec
```

The [core README](lua/libtmux/README.md) covers each module, with a complete
program for the standalone loop, Neovim and tables without tmux.

### [`libtmux-workspace`](https://github.com/libtmux/libtmux-lua/tree/master/packages/workspace): workspace scaffold

A development package for planned workspace operations. It has no loader,
command or builder API yet, and its module returns only a version.

[libtmux.org](https://libtmux.org/en/lua/latest/workspace/) records that it
is unpublished. After installing `libtmux`, build it from the checkout:

```console
$ luarocks --local make rockspecs/libtmux-workspace-scm-1.rockspec
```

With the local rocks tree on Lua's module paths, print its version:

```console
$ lua -e 'print(require("libtmux_workspace")._VERSION)'
scm
```

The [package README](packages/workspace/README.md) lists the prerequisites,
including LibYAML for `lyaml`.

### [`libtmux-mcp`](https://github.com/libtmux/libtmux-lua/tree/master/packages/mcp): MCP scaffold

A development package for the planned MCP server. It has no server,
executable, tools or prompts yet, so there is nothing to register with an MCP
client.

[libtmux.org](https://libtmux.org/en/lua/latest/mcp/) records that it is
unpublished. After installing `libtmux`, build it from the checkout:

```console
$ luarocks --local make rockspecs/libtmux-mcp-scm-1.rockspec
```

With the local rocks tree on Lua's module paths, print its version:

```console
$ lua -e 'print(require("libtmux_mcp")._VERSION)'
scm
```

The [package README](packages/mcp/README.md) has the full build steps.

## What it leaves out

- **A default server.** [`Runtime:connect`][ref-runtime-connect] takes an
  absolute tmux binary and socket path. The library never picks or starts a
  server.
- **Live records.** A [snapshot][ref-snapshot] holds what tmux said when it
  was read. Capture again to see a change.
- **Proof that a command finished.** [`Pane:send_keys`][ref-pane-send-keys]
  succeeds when tmux accepts the input. Wait on a `wait-for` channel, or print
  a token and [wait for it][ref-pane-wait-for-text].
- **An interactive terminal.** The luv and Neovim adapters own no terminal, so
  [`Session:attach`][ref-session-attach] returns `unsupported_tty`.
- **Your tmux configuration.** The library does not change a borrowed
  server's configuration, and your aliases and hooks still apply to
  [its commands](docs/commands.md).
- **An MCP server or a workspace loader.** Both packages are
  [scaffolds](#packages) with no public API.

## Support and status

- **Alpha.** The API is not settled. Pin an exact version.
- **Lua 5.1 to 5.5, and LuaJIT.** CI runs the unit suites on each.
- **tmux 3.3a or newer.** An older server is refused with
  [`unsupported_version`](docs/compatibility.md#minimum-tmux-release) before
  any command runs. CI runs the integration suite on every tmux release from
  3.3a, listed in the [compatibility matrix](docs/compatibility.md).
- **Pane-output watches and control observation need tmux 3.7 or newer.**
  `observe` returns `unsupported` on an older server. See
  [control](docs/control.md).
- **Waiting for text polls the visible screen.**
  [`Pane:wait_for_text`][ref-pane-wait-for-text] works on every release. Each
  read runs the `after-capture-pane` hook and never searches scrollback.
- **Nested commands are not checked.** A refused command inside another,
  such as `if-shell -F 1 'break-pane -d'`, reaches tmux and can stop the
  server on exactly 3.7. See the [limit and its advice](docs/commands.md).
- **Optional features.** Some commands and options need a newer release than
  3.3a. The [optional-feature table](docs/compatibility.md#optional-features)
  lists each, and [`capabilities.json`](capabilities.json) holds the same
  data for tools.
- **Neovim.** CI runs the Neovim tests on 0.10.0 and 0.12.5.
- **Linux, including WSL.** CI runs on Ubuntu 24.04 and local checks run under
  WSL2. No CI job runs on macOS, so macOS is untested.
- **Releases.** The [changelog](CHANGES.md) records each one, and the
  [release instructions](.github/CONTRIBUTING.md#releases) cover verification.

## Guides

- **Clients:** [switch sessions and detach terminals](docs/clients.md).
- **Read and watch:** [snapshots](docs/snapshots.md),
  [session notifications and pane streams](docs/control.md).
- **Run and arrange:** [commands and batches](docs/commands.md),
  [session/window topology](docs/topology.md), [binary buffers](docs/buffers.md).
- **Configure:** [options and hooks](docs/settings.md),
  [option reference](docs/options-reference.md),
  [environment values](docs/environment.md).
- **Contribute:** [setup and validation](.github/CONTRIBUTING.md),
  [writing conventions](.github/WRITING.md).

Live tests use private sockets and clean up their own servers. See the
contributing guide for the same offline checks that run in CI.

## Attribution

Please use the following BibTeX template to cite libtmux-lua in scientific discourse:

```bibtex
@misc{libtmux-lua,
   author = {Tony Narlock},
   year = {2026},
   note = {https://libtmux.org/en/lua/},
   title = {libtmux-lua: Lua wrapper for tmux}
}
```

## License

MIT. See [`LICENSE`](LICENSE).

[ref-server-new-session]: https://libtmux.org/en/lua/latest/reference/libtmux-server-new_session/
[ref-pane-capture]: https://libtmux.org/en/lua/latest/reference/libtmux-pane-capture/
[ref-server-query]: https://libtmux.org/en/lua/latest/reference/libtmux-server-query/
[ref-observation-watch-pane]: https://libtmux.org/en/lua/latest/reference/libtmux-observation-watch_pane/
[ref-query]: https://libtmux.org/en/lua/latest/reference/libtmux-query/
[ref-runtime-connect]: https://libtmux.org/en/lua/latest/reference/libtmux-runtime-connect/
[ref-session-snapshot]: https://libtmux.org/en/lua/latest/reference/libtmux-session-snapshot/
[ref-request]: https://libtmux.org/en/lua/latest/reference/libtmux-request/
[ref-request-await]: https://libtmux.org/en/lua/latest/reference/libtmux-request-await/
[ref-runtime]: https://libtmux.org/en/lua/latest/reference/libtmux-runtime/
[ref-server-snapshot]: https://libtmux.org/en/lua/latest/reference/libtmux-server-snapshot/
[ref-snapshot]: https://libtmux.org/en/lua/latest/reference/libtmux-snapshot/
[ref-snapshot-sessions]: https://libtmux.org/en/lua/latest/reference/libtmux-snapshot-sessions/
[ref-snapshot-windows]: https://libtmux.org/en/lua/latest/reference/libtmux-snapshot-windows/
[ref-snapshot-panes]: https://libtmux.org/en/lua/latest/reference/libtmux-snapshot-panes/
[ref-selection]: https://libtmux.org/en/lua/latest/reference/libtmux-selection/
[ref-selection-where]: https://libtmux.org/en/lua/latest/reference/libtmux-selection-where/
[ref-selection-filter]: https://libtmux.org/en/lua/latest/reference/libtmux-selection-filter/
[ref-query-select]: https://libtmux.org/en/lua/latest/reference/libtmux-query-select/
[ref-creation]: https://libtmux.org/en/lua/latest/reference/libtmux-creation/
[ref-session]: https://libtmux.org/en/lua/latest/reference/libtmux-session/
[ref-window]: https://libtmux.org/en/lua/latest/reference/libtmux-window/
[ref-pane]: https://libtmux.org/en/lua/latest/reference/libtmux-pane/
[ref-windowlink]: https://libtmux.org/en/lua/latest/reference/libtmux-windowlink/
[ref-session-new-window]: https://libtmux.org/en/lua/latest/reference/libtmux-session-new_window/
[ref-pane-split]: https://libtmux.org/en/lua/latest/reference/libtmux-pane-split/
[ref-pane-send-text]: https://libtmux.org/en/lua/latest/reference/libtmux-pane-send_text/
[ref-pane-send-keys]: https://libtmux.org/en/lua/latest/reference/libtmux-pane-send_keys/
[ref-server-command]: https://libtmux.org/en/lua/latest/reference/libtmux-server-command/
[ref-pane-wait-for-text]: https://libtmux.org/en/lua/latest/reference/libtmux-pane-wait_for_text/
[ref-capture-text]: https://libtmux.org/en/lua/latest/reference/libtmux-capture-text/
[ref-session-attach]: https://libtmux.org/en/lua/latest/reference/libtmux-session-attach/
[ref-nvim-start]: https://libtmux.org/en/lua/latest/reference/libtmux-runtime-nvim-start/
