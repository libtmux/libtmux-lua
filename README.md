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

[![CI](https://github.com/libtmux/libtmux-lua/actions/workflows/ci.yml/badge.svg)](https://github.com/libtmux/libtmux-lua/actions/workflows/ci.yml)
[![libtmux](https://img.shields.io/luarocks/v/tony/libtmux?label=libtmux)](https://luarocks.org/modules/tony/libtmux)
[![libtmux.org](https://img.shields.io/badge/docs-libtmux.org-0b7285)](https://libtmux.org/en/lua/)
[![license](https://img.shields.io/badge/license-MIT-blue)](https://github.com/libtmux/libtmux-lua/blob/master/LICENSE)

</div>

Needs Lua 5.1 to 5.5 or LuaJIT, and tmux 3.3a or newer. Before 1.0, any
release may change an API: pin an exact version and read the
[changelog](CHANGES.md).

**Contents** — [Quick start](#quick-start) ·
[Read tmux](#read-what-tmux-has-now) ·
[Create](#create-sessions-windows-and-panes) ·
[Type and read](#type-into-a-pane-and-read-the-answer) ·
[Run together](#run-several-commands-together) ·
[Watch](#watch-a-pane-as-it-prints) ·
[Neovim](#use-it-from-neovim) · [Packages](#packages) ·
[Leaves out](#what-it-leaves-out) · [Support](#support-and-status) ·
[Guides](#guides) ·
[CI](https://github.com/libtmux/libtmux-lua/actions/workflows/ci.yml) ·
[MIT license](LICENSE)

## Quick start

Standalone scripts run on `luv`, the event loop. It builds with a C compiler,
make and CMake:

- Debian and Ubuntu: `build-essential` and `cmake`.
- Fedora: `gcc`, `make` and `cmake`.
- macOS: the Xcode command line tools and `cmake`.

If the build fails, install `lua-luv` on Debian or Ubuntu instead. It serves
only the distribution's own Lua.

Install the rock, then `luv` (skip it if you installed `lua-luv`):

```console
$ luarocks --local install libtmux
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

[`Runtime:connect`][ref-runtime-connect] binds the socket you name and never
starts a server.
[`Server:new_session`][ref-server-new-session] creates the session and
[`Session:snapshot`][ref-session-snapshot] reads it back.

Live calls return [Requests][ref-request]. [`:await()`][ref-request-await]
yields inside the [runtime][ref-runtime] body and returns `value, err`; `must`
raises the error.

The program needs `TMUX_BIN` and `TMUX_SOCKET`, absolute paths to tmux and a
socket. The repository's launcher sets both on a private server, runs the
program, then stops the server:

```console
$ git clone https://github.com/libtmux/libtmux-lua.git && cd libtmux-lua
```

The launcher needs `perl` to confirm the stop:

```console
$ sh examples/api/run.sh examples/api/new_session.lua
session: demo
```

Every Lua block here comes from a program under [`examples/`](examples/).
Excerpts continue inside the same runtime body, with `server` and `must` in
hand.

## Read what tmux has now

### [`Server:snapshot`][ref-server-snapshot]: what tmux has now

One call reads every session, window and pane.
[`snapshot.sessions`][ref-snapshot-sessions],
[`snapshot.windows`][ref-snapshot-windows] and
[`snapshot.panes`][ref-snapshot-panes] list them. This prints each pane and
its window:

<!-- example: examples/snapshot.lua -->

```lua
local adapter = require("libtmux.runtime.luv")

local function must(value, err)
    if err ~= nil then
        error(err, 0)
    end
    return value
end

must(adapter.run(function(runtime)
    local server = must(runtime
        :connect({
            binary = assert(os.getenv("TMUX_BIN"), "set TMUX_BIN to an absolute tmux executable"),
            socket_path = assert(os.getenv("TMUX_SOCKET"), "set TMUX_SOCKET to an explicit socket"),
        })
        :await())
    local snapshot = must(server:snapshot({ strict = true }):await())
    for _, pane in ipairs(snapshot.panes) do
        io.stdout:write(pane.id, "\t", pane.window_id, "\n")
    end
    must(server:close():await())
    return true
end))
```

The launcher's server has one pane, so it prints that pane's ID and its
window's ID:

```console
$ sh examples/api/run.sh examples/snapshot.lua
%0	@0
```

A [snapshot][ref-snapshot] is what tmux held when it was read, across several
tmux commands: not live and not atomic. `strict = true` adds a verification
pass. Call [`Server:snapshot`][ref-server-snapshot] again to refresh.

More: [Snapshots](docs/snapshots.md).

### [`Selection:where`][ref-selection-where]: narrow what you read

[`Selection:where`][ref-selection-where] narrows a collection by structured
criteria, and [`Selection:filter`][ref-selection-filter] by a Lua function.
Both work on [`snapshot.panes`][ref-snapshot-panes] and on any list you give
[`query.select`][ref-query-select], and neither calls tmux. This program needs
only Lua:

<!-- example: examples/native_query.lua -->

```lua
local query = require("libtmux.query")

local schema = {
    fields = {
        id = { type = "string" },
        active = { type = "boolean" },
        current_command = { type = "string" },
    },
}
local rows = {
    { id = "%1", active = true, current_command = "nvim" },
    { id = "%2", active = false, current_command = "sh" },
    { id = "%3", active = false, current_command = "vim" },
}
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

It prints the panes whose command is `nvim` or `vim`:

```console
$ lua examples/native_query.lua
%1	nvim
%3	vim
```

More: [criteria and relationships](docs/query.md), the
[field reference](docs/fields.md).

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

More: [live queries](docs/query.md#query-live-state-explicitly).

### [`Server:explain_panes`][ref-server-explain-panes]: see what runs in tmux

[`Server:explain_panes`][ref-server-explain-panes] and
[`Server:explain`][ref-server-explain] return the plan for a query without
contacting tmux: its commands, the criteria sent to tmux as a filter, and the
ones kept local. `pushdown` picks the mode: `never`, `auto` or `require`:

<!-- excerpt: examples/api/explain.lua -->

```lua
    local where = { active = true, current_command = "cat" }
    for _, mode in ipairs({ "never", "auto" }) do
        -- Explaining sends nothing to tmux.
        local plan = must(server:explain_panes({ where = where, pushdown = mode }):await())
        local filter = plan.filter or "none"
        print(mode .. ": " .. #plan.commands .. " tmux commands, filter " .. filter)
        for _, left in ipairs(plan.residual) do
            print("  local: " .. left.path .. " (" .. left.reason .. ")")
        end
    end
```

`never` keeps every criterion local. `auto` sends `active` to tmux and keeps
`current_command` local:

```console
$ sh examples/api/run.sh examples/api/explain.lua
never: 6 tmux commands, filter none
  local: $ (pushdown_disabled)
auto: 7 tmux commands, filter #{==:#{pane_active},1}
  local: $.current_command.eq (nullable_field_remains_local)
```

`auto` adds a tmux-side listing; it does not make the query faster.

More: [live queries](docs/query.md#query-live-state-explicitly).

### [`Window:snapshot`][ref-window-snapshot]: read one object again

A record is what tmux said when it was read. Lua has no `refresh` that updates
one in place, as Python libtmux's `.refresh()` does. Call `snapshot` on the
handle instead: [`Window:snapshot`][ref-window-snapshot] returns a new record
and leaves the one you hold as it was.

[`Session:snapshot`][ref-session-snapshot] and
[`Pane:snapshot`][ref-pane-snapshot] work the same way.

This reads a window, renames it with [`Window:rename`][ref-window-rename], and
reads it again:

<!-- excerpt: examples/api/refresh.lua -->

```lua
local window = created.window
local held = must(window:snapshot():await())
must(window:rename("build"):await())
local fresh = must(window:snapshot():await())
assert(held.name == "editor" and fresh.name == "build", "refresh did not read the rename")
print(held.name .. " " .. fresh.name)
```

```console
$ sh examples/api/run.sh examples/api/refresh.lua
editor build
```

## Create sessions, windows and panes

### [`Session:new_window`][ref-session-new-window]: add a window

[`Session:new_window`][ref-session-new-window] adds a window to a session.
Like [`Server:new_session`][ref-server-new-session], it returns a
[`Creation`][ref-creation] holding [`session`][ref-session],
[`window`][ref-window], [`pane`][ref-pane] and
[`window_link`][ref-windowlink] handles:

<!-- example: examples/api/new_window.lua -->

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
    local logs = must(created.session:new_window({ name = "logs", argv = { "/bin/cat" } }):await())
    local snapshot = must(logs.window:snapshot():await())
    assert(snapshot.name == "logs", "created window has the wrong name")
    print("window: " .. snapshot.name)

    must(server:close():await())
    return true
end))
```

`argv` is the literal command the pane runs. Leave it out for tmux's default
shell.

```console
$ sh examples/api/run.sh examples/api/new_window.lua
window: logs
```

Creation does not wait for the program to start or report whether it
succeeds. Closing the server handle leaves what you created running.

More: [Creation](docs/creation.md).

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

<!-- example: examples/api/send_keys.lua -->

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
    local created = must(server:new_session({ name = "demo", argv = { "/bin/sh" } }):await())
    local pane = created.pane
    local function quote(text)
        return "'" .. text:gsub("'", "'\\''") .. "'"
    end

    -- Signal completion on this socket; do not guess when the shell has printed.
    local command = "printf '\\nlua input ready\\n'; "
        .. quote(binary)
        .. " -S "
        .. quote(socket)
        .. " wait-for -S example-ready"
    must(pane:send_text(command):await())
    must(pane:send_keys({ "Enter" }):await())
    must(server:command({ "wait-for", "example-ready" }, { timeout = 1000 }):await())
    local capture = must(pane:capture({ history_lines = 20 }):await())
    local found = false
    for line in must(capture:text()):gmatch("[^\r\n]+") do
        if line == "lua input ready" then
            found = true
        end
    end
    assert(found, "completed command did not print the expected line")
    print("lua input ready")

    must(server:close():await())
    return true
end))
```

`quote` shell-quotes the tmux path and socket for the pane's shell. The
program captures the pane and prints the line the command wrote:

```console
$ sh examples/api/run.sh examples/api/send_keys.lua
lua input ready
```

[`Server:command`][ref-server-command] runs any tmux command from literal
arguments. A nonzero exit is part of the result.

More: [Pane operations](docs/panes.md).

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

[`Pane:wait_for_text`][ref-pane-wait-for-text] polls the visible screen until
it holds the literal text. The result has the matching screen and
`matched_at_entry`, true when the first read already matched. Pass `timeout`
or `deadline` to bound the wait:

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
far. More: [waiting for pane text](docs/panes.md#wait-for-text).

## Run several commands together

### [`Server:group`][ref-server-group]: several commands, one tmux call

[`Server:group`][ref-server-group] runs commands in order in one tmux call.
[`Server:batch`][ref-server-batch] runs independent commands and reports each
outcome. This group creates a session and two windows, then lists them:

<!-- example: examples/api/group.lua -->

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
    -- One tmux process runs all four commands, in order.
    local done = must(server
        :group({
            { "new-session", "-d", "-s", "demo", "-n", "main", "/bin/cat" },
            { "new-window", "-d", "-t", "demo:", "-n", "build", "/bin/cat" },
            { "new-window", "-d", "-t", "demo:", "-n", "test", "/bin/cat" },
            { "list-windows", "-t", "demo", "-F", "#{window_name}" },
        })
        :await())
    assert(done.exit_code == 0, "the group failed")
    local names = {}
    for name in done.stdout:gmatch("[^\n]+") do
        names[#names + 1] = name
    end
    assert(#names == 3, "the group did not create three windows")
    print("windows: " .. table.concat(names, ", "))

    must(server:close():await())
    return true
end))
```

```console
$ sh examples/api/run.sh examples/api/group.lua
windows: main, build, test
```

A group is not a transaction: a failing command skips the rest, and commands
that already ran stay done.

More: [commands and batches](docs/commands.md).

## Watch a pane as it prints

### [`Server:observe`][ref-server-observe]: keep a control-mode client open

[`Server:observe`][ref-server-observe] holds one control-mode client for a
session. [`Observation:watch_pane`][ref-observation-watch-pane] streams a
pane's output, and
[`Observation:watch_notifications`][ref-observation-watch-notifications]
streams tmux's own events. [`watch:next`][ref-watch-next] returns the next
event. This needs tmux 3.7 or newer:

<!-- example: examples/api/watch_pane.lua -->

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
    local created = must(
        server:new_session({ name = "demo", window_name = "main", argv = { "/bin/cat" } }):await()
    )
    -- Observation holds one control-mode client open; it needs tmux 3.7 or newer.
    local observation = must(server:observe(created.session):await())
    local watch = must(observation:watch_pane(created.pane):await())

    must(created.pane:send_text("watched"):await())
    local output = ""
    while not output:find("watched", 1, true) do
        output = output .. must(watch:next({ timeout = 5000 }):await()).data
    end
    print("output: watched")

    must(observation:close():await())
    must(server:close():await())
    return true
end))
```

```console
$ sh examples/api/run.sh examples/api/watch_pane.lua
output: watched
```

Each event carries the pane's bytes and a sequence number. A slow reader loses
events: the watch ends with `observation_gap` instead of dropping them
silently.

More: [observing a session](docs/control.md).

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

Neovim shows the server's pane count. It has its own libuv binding, so the
`luv` rock is not needed.

More: [runtime ownership and cancellation](docs/runtime.md).

## Packages

### [`libtmux`](https://github.com/libtmux/libtmux-lua/tree/master/lua/libtmux): the library

Sessions, windows, panes, queries and pane watches on luv or Neovim's event
loop. Importing a module starts neither tmux nor an event loop, and
[local queries][ref-query] need only Lua.

Reference: [LuaRocks](https://luarocks.org/modules/tony/libtmux),
[libtmux.org](https://libtmux.org/en/lua/latest/reference/),
[`libtmux.Server`](https://libtmux.org/en/lua/latest/reference/libtmux-server/),
[`libtmux.runtime.luv`](https://libtmux.org/en/lua/latest/reference/libtmux-runtime-luv/),
[`libtmux.runtime.nvim`](https://libtmux.org/en/lua/latest/reference/libtmux-runtime-nvim/),
[`libtmux.query`](https://libtmux.org/en/lua/latest/reference/libtmux-query/).
Changelog: [`CHANGES.md`](CHANGES.md). Module by module: the
[core README](lua/libtmux/README.md).

To install from a checkout instead of LuaRocks:

```console
$ luarocks --local make rockspecs/libtmux-scm-1.rockspec
```

## What it leaves out

- **Starting a server.** [`Runtime:connect`][ref-runtime-connect] never starts
  one. Without a `socket_path`, `LIBTMUX_SOCKET_PATH` or `LIBTMUX_SOCKET` names
  the server, and otherwise tmux picks it.
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

## Support and status

- **Before 1.0.** Any release may change or remove an exported name. Pin an
  exact version; the [changelog](CHANGES.md) marks each break.
- **Lua.** 5.1 to 5.5, and LuaJIT.
- **tmux.** 3.3a or newer. An older server is refused with
  [`unsupported_version`](docs/compatibility.md#minimum-tmux-release).
  [Compatibility matrix](docs/compatibility.md).
- **Optional features.** Some commands and options need a newer tmux. The
  [table](docs/compatibility.md#optional-features) and
  [`capabilities.json`](capabilities.json) list each.
- **Control mode.** [`observe`][ref-server-observe] needs tmux 3.7 or newer
  and returns `unsupported` below it. [Control guide](docs/control.md).
- **Polling.** [`Pane:wait_for_text`][ref-pane-wait-for-text] works on every
  release. It reads the visible screen, never scrollback, and each read runs
  the `after-capture-pane` hook.
- **Nested commands are not checked.** `if-shell -F 1 'break-pane -d'` reaches
  tmux unchecked and can stop a 3.7 server. [Details](docs/commands.md).
- **No release candidates.** An `X.Y-rcN` build ranks below `X.Y`.
  [Policy](https://libtmux.org/en/tmux/guides/tmux-support/#release-candidates).
- **Neovim.** 0.10 or newer.
- **Linux, WSL included.** macOS is not tested.
- **Changelog.** [`CHANGES.md`](CHANGES.md) records each release;
  [release steps](.github/CONTRIBUTING.md#releases).

## Guides

- **Read and query:** [snapshots](docs/snapshots.md),
  [queries](docs/query.md), [field reference](docs/fields.md).
- **Create and type:** [creation](docs/creation.md),
  [pane operations](docs/panes.md).
- **Run and arrange:** [commands and batches](docs/commands.md),
  [topology](docs/topology.md), [binary buffers](docs/buffers.md),
  [clients](docs/clients.md).
- **Watch:** [session notifications and pane streams](docs/control.md).
- **Configure:** [options and hooks](docs/settings.md),
  [option reference](docs/options-reference.md),
  [environment values](docs/environment.md).
- **Runtime and compatibility:** [runtime ownership](docs/runtime.md),
  [compatibility matrix](docs/compatibility.md).
- **Contribute:** [setup and validation](.github/CONTRIBUTING.md),
  [writing conventions](.github/WRITING.md).

## AI policy

Use these packages with AI tools as you like. When contributing, check what you
submit and wait for a maintainer's invitation before preparing a pull request.
See the [AI policy](https://libtmux.org/en/meta/ai-policy/), also kept as
[AI_POLICY.md](https://github.com/libtmux/.github/blob/HEAD/AI_POLICY.md).

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
[ref-window-snapshot]: https://libtmux.org/en/lua/latest/reference/libtmux-window-snapshot/
[ref-window-rename]: https://libtmux.org/en/lua/latest/reference/libtmux-window-rename/
[ref-pane-snapshot]: https://libtmux.org/en/lua/latest/reference/libtmux-pane-snapshot/
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
[ref-server-explain-panes]: https://libtmux.org/en/lua/latest/reference/libtmux-server-explain_panes/
[ref-server-explain]: https://libtmux.org/en/lua/latest/reference/libtmux-server-explain/
[ref-server-group]: https://libtmux.org/en/lua/latest/reference/libtmux-server-group/
[ref-server-batch]: https://libtmux.org/en/lua/latest/reference/libtmux-server-batch/
[ref-server-observe]: https://libtmux.org/en/lua/latest/reference/libtmux-server-observe/
[ref-observation-watch-notifications]: https://libtmux.org/en/lua/latest/reference/libtmux-observation-watch_notifications/
[ref-watch-next]: https://libtmux.org/en/lua/latest/reference/libtmux-watch-next/
