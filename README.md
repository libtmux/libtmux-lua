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

Script tmux from Lua on luv or Neovim:
[create sessions][ref-server-new-session], [capture panes][ref-pane-capture],
[query state][ref-server-query], and [watch output][ref-observation-watch-pane].

[![CI](https://github.com/libtmux/libtmux-lua/actions/workflows/ci.yml/badge.svg)](https://github.com/libtmux/libtmux-lua/actions/workflows/ci.yml)
[![libtmux](https://img.shields.io/luarocks/v/tony/libtmux?label=libtmux)](https://luarocks.org/modules/tony/libtmux)
[![libtmux.org](https://img.shields.io/badge/docs-libtmux.org-0b7285)](https://libtmux.org/en/lua/)
[![license](https://img.shields.io/badge/license-MIT-blue)](https://github.com/libtmux/libtmux-lua/blob/master/LICENSE)

</div>

Needs Lua 5.1 to 5.5 or LuaJIT, and tmux 3.3a or newer. Before 1.0, any
release may change an API: pin an exact version and read the
[changelog](CHANGES.md).

## Quick start

Standalone scripts run on `luv`, the event loop. It builds with a C compiler,
make and CMake:

- Debian and Ubuntu: `build-essential` and `cmake`.
- Fedora: `gcc`, `make` and `cmake`.
- macOS: the Xcode command line tools and `cmake`.

If the build fails, install `lua-luv` on Debian or Ubuntu instead. It serves
only the distribution's own Lua.

`Runtime:start_server`, which the programs below call, is not in the published
`0.1.1-1` rock. It ships in the release after it. Until then, put this
repository's `lua/` directory ahead of the installed rock on `LUA_PATH`.

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

-- tmux is /usr/bin/tmux unless TMUX_BIN names another absolute path.
local binary = os.getenv("TMUX_BIN") or "/usr/bin/tmux"

must(adapter.run(function(runtime)
    local owned = must(runtime:start_server({ binary = binary }):await())
    local created = must(owned.server
        :new_session({
            name = "demo",
            window_name = "main",
            argv = { "/bin/cat" },
        })
        :await())
    local handles = created.session and created.window and created.pane
    assert(handles, "creation handles are missing")
    local snapshot = must(created.session:snapshot():await())
    assert(snapshot.name == "demo", "created session has the wrong name")
    print("session: " .. snapshot.name)

    must(owned:stop():await())
    return true
end))
```

[`Runtime:start_server`][guide-start-server] starts a private tmux server and
`owned:stop()` ends it. [`Server:new_session`][ref-server-new-session] creates
the session and [`Session:snapshot`][ref-session-snapshot] reads it back.

Live calls return [Requests][ref-request]. [`:await()`][ref-request-await]
yields inside the [runtime][ref-runtime] body and returns `value, err`; `must`
raises the error.

The programs use `/usr/bin/tmux`. Set `TMUX_BIN` to another absolute path to
change that. Run one from a checkout:

```console
$ git clone https://github.com/libtmux/libtmux-lua.git && cd libtmux-lua
```

```console
$ lua examples/api/new_session.lua
session: demo
```

Every Lua block here comes from a program under [`examples/`](examples/).
Excerpts continue inside the same runtime body, with `server` and `must` in
hand.

## Start and stop a private server

### [`Runtime:start_server`][guide-start-server]: own a tmux server

`start_server` starts a tmux server in a directory of its own, with no
configuration and none of your `TMUX` variables. It returns an `OwnedServer`
with its `server`, its `socket_path` and `stop()`:

<!-- example: examples/api/start_server.lua -->

```lua
local adapter = require("libtmux.runtime.luv")

local function must(value, err)
    if err ~= nil then
        error(tostring(err), 0)
    end
    return value
end

-- tmux is /usr/bin/tmux unless TMUX_BIN names another absolute path.
local binary = os.getenv("TMUX_BIN") or "/usr/bin/tmux"

must(adapter.run(function(runtime)
    -- The server is private: its own directory, socket and environment.
    local owned = must(runtime:start_server({ binary = binary }):await())
    local server = owned.server
    local before = must(server:snapshot():await())

    must(server:new_session({ name = "demo", argv = { "/bin/cat" } }):await())
    local after = must(server:snapshot():await())
    print(("sessions: %d, then %d"):format(#before.sessions, #after.sessions))

    must(owned:stop():await())
    return true
end))
```

- `stop()` kills the server, waits until nothing answers and removes the
  directory.
- The runtime stops a server you did not, even when the program fails.
- `Runtime:with_server(options, body)` stops it when the body ends.
- The server stays up with no session, so the program creates its own.

More: [private servers](docs/runtime.md#start-a-private-server).

## Read what tmux has now

### [`Server:snapshot`][ref-server-snapshot]: what tmux has now

One call reads [`snapshot.sessions`][ref-snapshot-sessions],
[`snapshot.windows`][ref-snapshot-windows] and
[`snapshot.panes`][ref-snapshot-panes]:

<!-- example: examples/snapshot.lua -->

```lua
local adapter = require("libtmux.runtime.luv")

local function must(value, err)
    if err ~= nil then
        error(err, 0)
    end
    return value
end

-- tmux is /usr/bin/tmux unless TMUX_BIN names another absolute path.
local binary = os.getenv("TMUX_BIN") or "/usr/bin/tmux"

must(adapter.run(function(runtime)
    local owned = must(runtime:start_server({ binary = binary }):await())
    local server = owned.server
    must(server:new_session({ name = "demo", argv = { "/bin/cat" } }):await())
    local snapshot = must(server:snapshot({ strict = true }):await())
    for _, pane in ipairs(snapshot.panes) do
        io.stdout:write(pane.id, "\t", pane.window_id, "\n")
    end
    must(owned:stop():await())
    return true
end))
```

The program creates one session with one pane, so it prints that pane's ID and
its window's ID:

```console
$ lua examples/snapshot.lua
%0	@0
```

A [snapshot][ref-snapshot] is what tmux held when it was read, across several
tmux commands: not live and not atomic. `strict = true` adds a verification
pass. Call [`Server:snapshot`][ref-server-snapshot] again to refresh.

More: [Snapshots](docs/snapshots.md).

### [`Selection:where`][ref-selection-where]: narrow what you read

[`Selection:where`][ref-selection-where] filters by criteria and
[`Selection:filter`][ref-selection-filter] by a function, on
[`snapshot.panes`][ref-snapshot-panes] or [`query.select`][ref-query-select]:

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
local editors = panes:where({
    current_command = { one_of = { "nvim", "vim" } },
})
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
local matched = #result.rows == 1 and result.rows[1].name == "demo"
assert(matched, "query selected the wrong session")
print("matched: " .. result.rows[1].name)
```

The program creates sessions named `demo` and `worker`, so the filter matches
one:

```console
$ lua examples/api/query.lua
matched: demo
```

`complete` reports no known inconsistency. The read is still not atomic.

More: [live queries](docs/query.md#query-live-state-explicitly).

### [`Server:explain_panes`][ref-server-explain-panes]: see what runs in tmux

[`Server:explain_panes`][ref-server-explain-panes] and
[`Server:explain`][ref-server-explain] plan a query locally, splitting tmux and
local criteria for `pushdown` (`never`, `auto`, `require`):

<!-- excerpt: examples/api/explain.lua -->

```lua
local where = { active = true, current_command = "cat" }
for _, mode in ipairs({ "never", "auto" }) do
    -- Explaining sends nothing to tmux.
    local query = { where = where, pushdown = mode }
    local plan = must(server:explain_panes(query):await())
    local count = #plan.commands .. " tmux commands"
    local filter = plan.filter or "none"
    print(mode .. ": " .. count .. ", filter " .. filter)
    for _, left in ipairs(plan.residual) do
        print("  local: " .. left.path .. " (" .. left.reason .. ")")
    end
end
```

`never` keeps every criterion local. `auto` sends `active` to tmux and keeps
`current_command` local:

```console
$ lua examples/api/explain.lua
never: 6 tmux commands, filter none
  local: $ (pushdown_disabled)
auto: 7 tmux commands, filter #{==:#{pane_active},1}
  local: $.current_command.eq (nullable_field_remains_local)
```

`auto` adds a tmux-side listing; it does not make the query faster.

More: [live queries](docs/query.md#query-live-state-explicitly).

### [`Window:snapshot`][ref-window-snapshot]: read one object again

Records never mutate in place like Python libtmux's `.refresh()`.
[`Window:snapshot`][ref-window-snapshot] returns a new record and leaves the
held table unchanged.

[`Session:snapshot`][ref-session-snapshot] and
[`Pane:snapshot`][ref-pane-snapshot] work the same way. Rename a window with
[`Window:rename`][ref-window-rename] and read it again:

<!-- excerpt: examples/api/refresh.lua -->

```lua
local window = created.window
local held = must(window:snapshot():await())
must(window:rename("build"):await())
local fresh = must(window:snapshot():await())
local renamed = held.name == "editor" and fresh.name == "build"
assert(renamed, "refresh did not read the rename")
print(held.name .. " " .. fresh.name)
```

```console
$ lua examples/api/refresh.lua
editor build
```

## Create sessions, windows and panes

### [`Session:new_window`][ref-session-new-window]: add a window

[`Session:new_window`][ref-session-new-window] adds a window to a session,
like [`Server:new_session`][ref-server-new-session].

Both return a [`Creation`][ref-creation] holding [`session`][ref-session],
[`window`][ref-window], [`pane`][ref-pane] and [`window_link`][ref-windowlink]:

<!-- example: examples/api/new_window.lua -->

```lua
local adapter = require("libtmux.runtime.luv")

local function must(value, err)
    if err ~= nil then
        error(tostring(err), 0)
    end
    return value
end

-- tmux is /usr/bin/tmux unless TMUX_BIN names another absolute path.
local binary = os.getenv("TMUX_BIN") or "/usr/bin/tmux"

must(adapter.run(function(runtime)
    local owned = must(runtime:start_server({ binary = binary }):await())
    local created = must(owned.server
        :new_session({
            name = "demo",
            window_name = "main",
            argv = { "/bin/cat" },
        })
        :await())
    local window = { name = "logs", argv = { "/bin/cat" } }
    local logs = must(created.session:new_window(window):await())
    local snapshot = must(logs.window:snapshot():await())
    assert(snapshot.name == "logs", "created window has the wrong name")
    print("window: " .. snapshot.name)

    must(owned:stop():await())
    return true
end))
```

`argv` is the literal command the pane runs. Leave it out for tmux's default
shell.

```console
$ lua examples/api/new_window.lua
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
local window_opts = { name = "logs", argv = { "/bin/cat" } }
local logs = must(created.session:new_window(window_opts):await())
local split_opts = {
    direction = "right",
    percent = 40,
    argv = { "/bin/cat" },
}
local split = must(logs.pane:split(split_opts):await())
```

[`quickstart.lua`](examples/quickstart.lua) creates a session, a window and
this split, then prints their IDs. New windows and splits leave the
selection alone unless you pass `select = true`:

```console
$ lua examples/quickstart.lua
$0	@1	%2
```

## Type into a pane and read the answer

### [`Pane:send_text`][ref-pane-send-text]: type a command

[`Pane:send_text`][ref-pane-send-text] types literal text and adds no Enter.
[`Pane:send_keys`][ref-pane-send-keys] presses named keys such as `Enter`.

Success means tmux accepted the input while the command may still be running.
The example [waits for the command's output][ref-pane-wait-for-text] before it
goes on:

<!-- example: examples/api/send_keys.lua -->

```lua
local adapter = require("libtmux.runtime.luv")

local function must(value, err)
    if err ~= nil then
        error(tostring(err), 0)
    end
    return value
end

-- tmux is /usr/bin/tmux unless TMUX_BIN names another absolute path.
local binary = os.getenv("TMUX_BIN") or "/usr/bin/tmux"

must(adapter.run(function(runtime)
    local owned = must(runtime:start_server({ binary = binary }):await())
    local session = { name = "demo", argv = { "/bin/sh" } }
    local created = must(owned.server:new_session(session):await())
    local pane = created.pane

    -- The shell echoes what is typed, so print the needle from two pieces.
    must(pane:send_text("printf '%s%s\\n' 'lua input ' 'ready'"):await())
    must(pane:send_keys({ "Enter" }):await())
    local wait = pane:wait_for_text("lua input ready", { timeout = 5000 })
    local found = must(wait:await())
    local matched = found.text:find("lua input ready", 1, true)
    assert(matched, "the command did not print its line")
    print("lua input ready")

    must(owned:stop():await())
    return true
end))
```

The shell echoes what is typed, so the command prints its text from two
pieces and the wait cannot match the echo. The program prints the line the
command wrote:

```console
$ lua examples/api/send_keys.lua
lua input ready
```

[`Server:command`][ref-server-command] runs any tmux command from literal
arguments, such as `wait-for`. A nonzero exit is part of the result.

More: [Pane operations](docs/panes.md).

### [`Pane:capture`][ref-pane-capture]: read the screen

[`Pane:capture`][ref-pane-capture] reads the screen (`history_lines = 20` adds
scrollback). [`capture:text()`][ref-capture-text] decodes UTF-8 or returns an
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
$ lua examples/api/capture.lua
lua capture ready
```

A capture holds the cells tmux rendered, so it cannot say whether a command
finished. [Pane operations](docs/panes.md) lists the capture options, from
joined lines to escape sequences.

### [`Pane:wait_for_text`][ref-pane-wait-for-text]: wait for text on screen

[`Pane:wait_for_text`][ref-pane-wait-for-text] polls the visible screen for
literal text, returning the matching screen and `matched_at_entry`. Pass
`timeout` or `deadline` to bound the wait:

<!-- excerpt: examples/api/wait_for_text.lua -->

```lua
-- The shell echoes what is typed, so print the needle from two pieces.
must(pane:send_text("printf '%s%s\\n' 'lua wait ' 'ready'"):await())
must(pane:send_keys({ "Enter" }):await())
local wait = pane:wait_for_text("lua wait ready", { timeout = 5000 })
local found = must(wait:await())
assert(found.text:find("lua wait ready", 1, true))
print("lua wait ready")
```

```console
$ lua examples/api/wait_for_text.lua
lua wait ready
```

If the pane exits first, the wait ends with `pane_died` and the text seen so
far. More: [waiting for pane text](docs/panes.md#wait-for-text).

## Resize, remove and configure

### [`Pane:resize`][ref-pane-resize]: set a size

[`Pane:resize`][ref-pane-resize] sets `width` and `height` or adjusts by
`direction` and `amount`; [`Window:resize`][ref-window-resize] sets `width` and
`height`. tmux clamps both to the layout, so read the sizes back:

<!-- example: examples/api/resize.lua -->

```lua
local adapter = require("libtmux.runtime.luv")

local function must(value, err)
    if err ~= nil then
        error(tostring(err), 0)
    end
    return value
end

-- tmux is /usr/bin/tmux unless TMUX_BIN names another absolute path.
local binary = os.getenv("TMUX_BIN") or "/usr/bin/tmux"

must(adapter.run(function(runtime)
    local owned = must(runtime:start_server({ binary = binary }):await())
    local session = { name = "demo", argv = { "/bin/cat" } }
    local created = must(owned.server:new_session(session):await())
    local split_opts = { direction = "right", argv = { "/bin/cat" } }
    local split = must(created.pane:split(split_opts):await())

    must(created.window:resize({ width = 100, height = 30 }):await())
    must(split.pane:resize({ width = 30 }):await())

    -- A resize can clamp to the layout, so read the sizes tmux settled on.
    local window = must(created.window:snapshot():await())
    local pane = must(split.pane:snapshot():await())
    local sized = window.width == 100 and window.height == 30
    assert(sized, "the window kept its old size")
    assert(pane.width == 30, "the pane kept its old width")
    local template = "window %dx%d, pane %d wide"
    print(template:format(window.width, window.height, pane.width))

    must(owned:stop():await())
    return true
end))
```

```console
$ lua examples/api/resize.lua
window 100x30, pane 30 wide
```

More: [pane operations](docs/panes.md#resize-kill-and-respawn),
[window size](docs/topology.md#window-size-and-layout).

### [`Pane:kill`][ref-pane-kill]: remove what you made

[`Pane:kill`][ref-pane-kill], [`Window:kill`][ref-window-kill] and
[`Session:kill`][ref-session-kill] remove their target; killing a window's last
pane removes the window. More: [removal](docs/topology.md#names-and-removal).

### [`Window:set_option`][ref-window-set-option]: change a setting

[`Window:set_option`][ref-window-set-option] and
[`Window:get_option`][ref-window-get-option] write and read options across
handles, and [`Window:set_hook`][ref-window-set-hook] stores a hook command.

More: [options and hooks](docs/settings.md),
[option reference](docs/options-reference.md),
[environment values](docs/environment.md).

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

-- tmux is /usr/bin/tmux unless TMUX_BIN names another absolute path.
local binary = os.getenv("TMUX_BIN") or "/usr/bin/tmux"

must(adapter.run(function(runtime)
    local owned = must(runtime:start_server({ binary = binary }):await())
    -- One tmux process runs all four commands, in order.
    local done = must(owned.server
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

    must(owned:stop():await())
    return true
end))
```

```console
$ lua examples/api/group.lua
windows: main, build, test
```

A group is not a transaction: a failing command skips the rest, and commands
that already ran stay done.

More: [commands and batches](docs/commands.md),
[binary buffers](docs/buffers.md), [clients](docs/clients.md).

## Watch a pane as it prints

### [`Server:observe`][ref-server-observe]: keep a control-mode client open

[`Server:observe`][ref-server-observe] holds one control-mode client for a
session (tmux 3.7 or newer).

[`Observation:watch_pane`][ref-observation-watch-pane] streams pane output,
[`Observation:watch_notifications`][ref-observation-watch-notifications]
streams tmux events, and [`watch:next`][ref-watch-next] reads the next event:

<!-- example: examples/api/watch_pane.lua -->

```lua
local adapter = require("libtmux.runtime.luv")

local function must(value, err)
    if err ~= nil then
        error(tostring(err), 0)
    end
    return value
end

-- tmux is /usr/bin/tmux unless TMUX_BIN names another absolute path.
local binary = os.getenv("TMUX_BIN") or "/usr/bin/tmux"

must(adapter.run(function(runtime)
    local owned = must(runtime:start_server({ binary = binary }):await())
    local created = must(owned.server
        :new_session({
            name = "demo",
            window_name = "main",
            argv = { "/bin/cat" },
        })
        :await())
    -- Observation keeps one control-mode client open (tmux 3.7 or newer).
    local observation = must(owned.server:observe(created.session):await())
    local watch = must(observation:watch_pane(created.pane):await())

    must(created.pane:send_text("watched"):await())
    local output = ""
    while not output:find("watched", 1, true) do
        output = output .. must(watch:next({ timeout = 5000 }):await()).data
    end
    print("output: watched")

    must(observation:close():await())
    must(owned:stop():await())
    return true
end))
```

```console
$ lua examples/api/watch_pane.lua
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
    local binary = vim.fn.exepath("tmux")
    local owned, err = runtime:start_server({ binary = binary }):await()
    if not owned then
        return nil, err
    end
    local session = { name = "demo", argv = { "/bin/cat" } }
    local created
    created, err = owned.server:new_session(session):await()
    local snapshot
    if created then
        snapshot, err = owned.server:snapshot({ strict = true }):await()
    end
    local stopped, stop_err = owned:stop():await()
    if not snapshot then
        return nil, err
    end
    if not stopped then
        return nil, stop_err
    end
    return snapshot
end, function(snapshot, err)
    if err then
        vim.notify(tostring(err), vim.log.levels.ERROR)
        return
    end
    vim.notify(("Panes: %d"):format(#snapshot.panes))
end)
```

From the checkout, start Neovim with the library on its `runtimepath`. `tmux`
must be on its `PATH`:

```console
$ nvim \
    --cmd 'set runtimepath+=.' \
    -c 'luafile examples/nvim_snapshot.lua'
```

Neovim starts a private server, creates a session and shows the pane count. It
has its own libuv binding, so the `luv` rock is not needed.

More: [runtime ownership and cancellation](docs/runtime.md).

## Packages

### [`libtmux`][pkg-libtmux]: the library

Sessions, windows, panes, [local queries][ref-query] and pane watches on luv or
Neovim, with no loop or server started on import.

Reference: [libtmux.org][ref-index] ·
Registry: [LuaRocks][luarocks-libtmux] · Changelog: [`CHANGES.md`](CHANGES.md) ·
Modules: [`lua/libtmux/`](lua/libtmux/README.md)

To install from a checkout instead of LuaRocks:

```console
$ luarocks --local make rockspecs/libtmux-scm-1.rockspec
```

## What it leaves out

- **Starting a server on connect.** [`Runtime:connect`][ref-runtime-connect]
  never starts one; [`start_server`][guide-start-server] does. Without
  `socket_path`, `LIBTMUX_SOCKET_PATH` or `LIBTMUX_SOCKET` picks the server.
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

[Docs][docs-home] · [API reference][ref-index] · [`examples/`](examples/) ·
[`CHANGES.md`](CHANGES.md) · [Contributing](.github/CONTRIBUTING.md) ·
[AI policy][ai-policy] · [Citation](CITATION.cff) · [MIT License](LICENSE)

Part of the [libtmux.org](https://libtmux.org/) family alongside Python
[`libtmux`][python-libtmux], sibling [language ports][libtmux-gh], and
[tmux][tmux].

[ai-policy]: https://libtmux.org/en/meta/ai-policy/
[docs-home]: https://libtmux.org/en/lua/
[guide-start-server]: docs/runtime.md#start-a-private-server
[libtmux-gh]: https://github.com/libtmux
[luarocks-libtmux]: https://luarocks.org/modules/tony/libtmux
[pkg-libtmux]: https://github.com/libtmux/libtmux-lua/tree/master/lua/libtmux
[python-libtmux]: https://github.com/tmux-python/libtmux
[ref-capture-text]: https://libtmux.org/en/lua/latest/reference/libtmux-capture-text/
[ref-creation]: https://libtmux.org/en/lua/latest/reference/libtmux-creation/
[ref-index]: https://libtmux.org/en/lua/latest/reference/
[ref-nvim-start]: https://libtmux.org/en/lua/latest/reference/libtmux-runtime-nvim-start/
[ref-observation-watch-notifications]: https://libtmux.org/en/lua/latest/reference/libtmux-observation-watch_notifications/
[ref-observation-watch-pane]: https://libtmux.org/en/lua/latest/reference/libtmux-observation-watch_pane/
[ref-pane]: https://libtmux.org/en/lua/latest/reference/libtmux-pane/
[ref-pane-capture]: https://libtmux.org/en/lua/latest/reference/libtmux-pane-capture/
[ref-pane-kill]: https://libtmux.org/en/lua/latest/reference/libtmux-pane-kill/
[ref-pane-resize]: https://libtmux.org/en/lua/latest/reference/libtmux-pane-resize/
[ref-pane-send-keys]: https://libtmux.org/en/lua/latest/reference/libtmux-pane-send_keys/
[ref-pane-send-text]: https://libtmux.org/en/lua/latest/reference/libtmux-pane-send_text/
[ref-pane-snapshot]: https://libtmux.org/en/lua/latest/reference/libtmux-pane-snapshot/
[ref-pane-split]: https://libtmux.org/en/lua/latest/reference/libtmux-pane-split/
[ref-pane-wait-for-text]: https://libtmux.org/en/lua/latest/reference/libtmux-pane-wait_for_text/
[ref-query]: https://libtmux.org/en/lua/latest/reference/libtmux-query/
[ref-query-select]: https://libtmux.org/en/lua/latest/reference/libtmux-query-select/
[ref-request]: https://libtmux.org/en/lua/latest/reference/libtmux-request/
[ref-request-await]: https://libtmux.org/en/lua/latest/reference/libtmux-request-await/
[ref-runtime]: https://libtmux.org/en/lua/latest/reference/libtmux-runtime/
[ref-runtime-connect]: https://libtmux.org/en/lua/latest/reference/libtmux-runtime-connect/
[ref-selection]: https://libtmux.org/en/lua/latest/reference/libtmux-selection/
[ref-selection-filter]: https://libtmux.org/en/lua/latest/reference/libtmux-selection-filter/
[ref-selection-where]: https://libtmux.org/en/lua/latest/reference/libtmux-selection-where/
[ref-server-batch]: https://libtmux.org/en/lua/latest/reference/libtmux-server-batch/
[ref-server-command]: https://libtmux.org/en/lua/latest/reference/libtmux-server-command/
[ref-server-explain]: https://libtmux.org/en/lua/latest/reference/libtmux-server-explain/
[ref-server-explain-panes]: https://libtmux.org/en/lua/latest/reference/libtmux-server-explain_panes/
[ref-server-group]: https://libtmux.org/en/lua/latest/reference/libtmux-server-group/
[ref-server-new-session]: https://libtmux.org/en/lua/latest/reference/libtmux-server-new_session/
[ref-server-observe]: https://libtmux.org/en/lua/latest/reference/libtmux-server-observe/
[ref-server-query]: https://libtmux.org/en/lua/latest/reference/libtmux-server-query/
[ref-server-snapshot]: https://libtmux.org/en/lua/latest/reference/libtmux-server-snapshot/
[ref-session]: https://libtmux.org/en/lua/latest/reference/libtmux-session/
[ref-session-attach]: https://libtmux.org/en/lua/latest/reference/libtmux-session-attach/
[ref-session-kill]: https://libtmux.org/en/lua/latest/reference/libtmux-session-kill/
[ref-session-new-window]: https://libtmux.org/en/lua/latest/reference/libtmux-session-new_window/
[ref-session-snapshot]: https://libtmux.org/en/lua/latest/reference/libtmux-session-snapshot/
[ref-snapshot]: https://libtmux.org/en/lua/latest/reference/libtmux-snapshot/
[ref-snapshot-panes]: https://libtmux.org/en/lua/latest/reference/libtmux-snapshot-panes/
[ref-snapshot-sessions]: https://libtmux.org/en/lua/latest/reference/libtmux-snapshot-sessions/
[ref-snapshot-windows]: https://libtmux.org/en/lua/latest/reference/libtmux-snapshot-windows/
[ref-watch-next]: https://libtmux.org/en/lua/latest/reference/libtmux-watch-next/
[ref-window]: https://libtmux.org/en/lua/latest/reference/libtmux-window/
[ref-window-get-option]: https://libtmux.org/en/lua/latest/reference/libtmux-window-get_option/
[ref-window-kill]: https://libtmux.org/en/lua/latest/reference/libtmux-window-kill/
[ref-window-rename]: https://libtmux.org/en/lua/latest/reference/libtmux-window-rename/
[ref-window-resize]: https://libtmux.org/en/lua/latest/reference/libtmux-window-resize/
[ref-window-set-hook]: https://libtmux.org/en/lua/latest/reference/libtmux-window-set_hook/
[ref-window-set-option]: https://libtmux.org/en/lua/latest/reference/libtmux-window-set_option/
[ref-window-snapshot]: https://libtmux.org/en/lua/latest/reference/libtmux-window-snapshot/
[ref-windowlink]: https://libtmux.org/en/lua/latest/reference/libtmux-windowlink/
[tmux]: https://github.com/tmux/tmux
