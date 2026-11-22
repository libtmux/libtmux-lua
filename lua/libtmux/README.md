<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="assets/logo.svg" type="image/svg+xml">
    <img src="assets/logo.png" width="128" height="128" alt="libtmux for Lua">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# libtmux for Lua: the core package

The `libtmux` rock holds the Lua API for tmux
[sessions, windows and panes][ref-concepts].

[![libtmux.org](https://img.shields.io/badge/docs-libtmux.org-0b7285)](https://libtmux.org/en/lua/)
[![libtmux](https://img.shields.io/luarocks/v/tony/libtmux?label=libtmux)](https://luarocks.org/modules/tony/libtmux)

</div>

Needs Lua 5.1 to 5.5 or LuaJIT, and tmux 3.3a or newer. Before 1.0, any
release may change an API: pin an exact version and read the
[changelog][changes].

The [root README][root-readme] shows a first tmux program, and the
[API reference][ref-index] lists every public symbol.

## Quick start

Install the rock and add the local rocks tree to Lua's module paths:

```console
$ luarocks --local install libtmux
```

```console
$ eval "$(luarocks --local path)"
```

[`libtmux.query`][ref-query] selects records from Lua tables and needs neither
tmux nor luv. This is the whole program:

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

[`query.select`][ref-query-select] wraps the list in a
[`Selection`][ref-selection]; [`where`][ref-selection-where] filters by
criteria and [`filter`][ref-selection-filter] by a function:

```console
$ lua examples/native_query.lua
%1	nvim
%3	vim
```

## Modules

`require("libtmux")` returns only the rock's `_VERSION`; the entry points are
these modules.

### [`libtmux.runtime.luv`][ref-runtime-luv]: the standalone loop

[`run(body, limits)`][ref-luv-run] drives a luv loop (`luv` rock) and returns
`value, err` when done; importing starts no loop. Related:
[`libtmux.Server`][ref-server]. Source: [`luv.lua`][src-luv].

[`new_session.lua`][ex-new-session] calls [`start_server`][guide-start-server],
[`Server:new_session`][ref-server-new-session] and
[`Session:snapshot`][ref-session-snapshot]:

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

After the [setup for the complete examples][ex-setup], run this from the
repository root:

```console
$ lua examples/api/new_session.lua
session: demo
```

### [`libtmux.runtime.nvim`][ref-runtime-nvim]: Neovim's loop

[`start(body, on_done, limits)`][ref-nvim-start] borrows Neovim's loop, calls
`on_done(value, err)` when done, and leaves borrowed handles open. Source:
[`nvim.lua`][src-nvim].

[`nvim_snapshot.lua`][ex-nvim-snapshot] starts a private server, creates a
session and shows the pane count:

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

From the repository root, with `tmux` on Neovim's `PATH`:

```console
$ nvim \
    --cmd 'set runtimepath+=.' \
    -c 'luafile examples/nvim_snapshot.lua'
```

### [`libtmux.query`][ref-query]: tables without tmux

[`select`][ref-query-select] wraps Lua tables in a [`Selection`][ref-selection],
matching `snapshot.panes`; Quick start shows the program. Source:
[`query.lua`][src-query].

[`Server:query`][ref-server-query] applies criteria to a live server instead
of a table. The [query guide][guide-query] lists the criteria both accept.

## What it leaves out

- **Starting a server on connect.** [`Runtime:connect`][ref-runtime-connect]
  never starts one; [`start_server`][guide-start-server] does. Without
  `socket_path`, `LIBTMUX_SOCKET_PATH` or `LIBTMUX_SOCKET` picks the server.
- **Live records.** A [snapshot][ref-snapshot] holds what tmux said when it
  was read. Capture again to see a change.
- **An interactive terminal.** The luv and Neovim adapters own no terminal, so
  [`Session:attach`][ref-session-attach] returns `unsupported_tty`.

## Support and status

- **Before 1.0.** Any release may change or remove an exported name. Pin an
  exact version; the [changelog][changes] marks each break.
- **Lua.** 5.1 to 5.5, and LuaJIT.
- **tmux.** 3.3a or newer. An older server is refused with
  `unsupported_version` before any operation runs.
- **Neovim.** 0.10 or newer.
- **Linux, WSL included.** macOS is not tested.

[changes]: https://github.com/libtmux/libtmux-lua/blob/master/CHANGES.md
[ex-new-session]: https://github.com/libtmux/libtmux-lua/blob/master/examples/api/new_session.lua
[ex-nvim-snapshot]: https://github.com/libtmux/libtmux-lua/blob/master/examples/nvim_snapshot.lua
[ex-setup]: https://github.com/libtmux/libtmux-lua/blob/master/examples/api/README.md
[guide-query]: https://github.com/libtmux/libtmux-lua/blob/master/docs/query.md
[guide-start-server]: https://github.com/libtmux/libtmux-lua/blob/master/docs/runtime.md#start-a-private-server
[ref-concepts]: https://libtmux.org/en/lua/latest/concepts/server-session-window-pane/
[ref-index]: https://libtmux.org/en/lua/latest/reference/
[ref-luv-run]: https://libtmux.org/en/lua/latest/reference/libtmux-runtime-luv-run/
[ref-nvim-start]: https://libtmux.org/en/lua/latest/reference/libtmux-runtime-nvim-start/
[ref-query]: https://libtmux.org/en/lua/latest/reference/libtmux-query/
[ref-query-select]: https://libtmux.org/en/lua/latest/reference/libtmux-query-select/
[ref-runtime-connect]: https://libtmux.org/en/lua/latest/reference/libtmux-runtime-connect/
[ref-runtime-luv]: https://libtmux.org/en/lua/latest/reference/libtmux-runtime-luv/
[ref-runtime-nvim]: https://libtmux.org/en/lua/latest/reference/libtmux-runtime-nvim/
[ref-selection]: https://libtmux.org/en/lua/latest/reference/libtmux-selection/
[ref-selection-filter]: https://libtmux.org/en/lua/latest/reference/libtmux-selection-filter/
[ref-selection-where]: https://libtmux.org/en/lua/latest/reference/libtmux-selection-where/
[ref-server]: https://libtmux.org/en/lua/latest/reference/libtmux-server/
[ref-server-new-session]: https://libtmux.org/en/lua/latest/reference/libtmux-server-new_session/
[ref-server-query]: https://libtmux.org/en/lua/latest/reference/libtmux-server-query/
[ref-session-attach]: https://libtmux.org/en/lua/latest/reference/libtmux-session-attach/
[ref-session-snapshot]: https://libtmux.org/en/lua/latest/reference/libtmux-session-snapshot/
[ref-snapshot]: https://libtmux.org/en/lua/latest/reference/libtmux-snapshot/
[root-readme]: https://github.com/libtmux/libtmux-lua/blob/master/README.md#quick-start
[src-luv]: https://github.com/libtmux/libtmux-lua/blob/master/lua/libtmux/runtime/luv.lua
[src-nvim]: https://github.com/libtmux/libtmux-lua/blob/master/lua/libtmux/runtime/nvim.lua
[src-query]: https://github.com/libtmux/libtmux-lua/blob/master/lua/libtmux/query.lua
