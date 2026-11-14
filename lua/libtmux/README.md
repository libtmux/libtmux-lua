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

The `libtmux` rock holds the Lua API for tmux [sessions, windows and
panes][ref-concepts].

[![libtmux.org](https://img.shields.io/badge/docs-libtmux.org-0b7285)](https://libtmux.org/en/lua/)
[![libtmux](https://img.shields.io/luarocks/v/tony/libtmux?label=libtmux)](https://luarocks.org/modules/tony/libtmux)

</div>

Needs Lua 5.1 to 5.5 or LuaJIT, and tmux 3.3a or newer. Before 1.0, any
release may change an API: pin an exact version and read the
[changelog][changes].

The [root README](https://github.com/libtmux/libtmux-lua/blob/master/README.md#quick-start)
shows a first tmux program. The
[API reference](https://libtmux.org/en/lua/latest/reference/) lists every
public symbol.

**Contents** — [Quick start](#quick-start) · [Modules](#modules) ·
[Leaves out](#what-it-leaves-out) · [Support](#support-and-status)

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

[`query.select`][ref-query-select] wraps the list in a
[`Selection`][ref-selection]. [`where`][ref-selection-where] narrows it by
criteria and [`filter`][ref-selection-filter] by a function. Save the program
and run it, or run it from a checkout:

```console
$ lua examples/native_query.lua
%1	nvim
%3	vim
```

## Modules

`require("libtmux")` returns only the rock's `_VERSION`; the entry points are
these modules.

### [`libtmux.runtime.luv`][ref-runtime-luv]: the standalone loop

[`run(body, limits)`][ref-luv-run] drives a luv loop for a standalone script
and returns `value, err` once its work has finished. It needs the `luv` rock;
importing the module starts no loop. Related:
[`libtmux.Server`][ref-server]. Source:
[`luv.lua`](https://github.com/libtmux/libtmux-lua/blob/master/lua/libtmux/runtime/luv.lua).

This is the complete
[`new_session.lua`](https://github.com/libtmux/libtmux-lua/blob/master/examples/api/new_session.lua)
program. It connects with [`Runtime:connect`][ref-runtime-connect], creates a
session with [`Server:new_session`][ref-server-new-session] and reads it back
with [`Session:snapshot`][ref-session-snapshot]:

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

After the
[setup for the complete examples](https://github.com/libtmux/libtmux-lua/blob/master/examples/api/README.md),
run this from the repository root. The launcher starts a private tmux server
and stops it when the program ends:

```console
$ sh examples/api/run.sh examples/api/new_session.lua
session: demo
```

### [`libtmux.runtime.nvim`][ref-runtime-nvim]: Neovim's loop

[`start(body, on_done, limits)`][ref-nvim-start] returns at once and borrows
the editor's loop. It calls `on_done(value, err)` once its work has finished,
and handles it did not create stay open. Source:
[`nvim.lua`](https://github.com/libtmux/libtmux-lua/blob/master/lua/libtmux/runtime/nvim.lua).

This is the complete
[`nvim_snapshot.lua`](https://github.com/libtmux/libtmux-lua/blob/master/examples/nvim_snapshot.lua)
program. It reads the server's snapshot and shows the pane count:

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

From the repository root, with `TMUX_SOCKET` set to the absolute path of a
server's socket:

```console
$ TMUX_SOCKET=/path/to/tmux.sock nvim \
    --cmd 'set runtimepath+=.' \
    -c 'luafile examples/nvim_snapshot.lua'
```

### [`libtmux.query`][ref-query]: tables without tmux

[`select`][ref-query-select] wraps a list of Lua tables in a
[`Selection`][ref-selection], the same type as a snapshot's `panes`. The quick
start program is the complete example. Source:
[`query.lua`](https://github.com/libtmux/libtmux-lua/blob/master/lua/libtmux/query.lua).

[`Server:query`][ref-server-query] applies criteria to a live server instead
of a table. The [query guide](https://github.com/libtmux/libtmux-lua/blob/master/docs/query.md)
lists the criteria both accept.

## What it leaves out

- **Starting a server.** [`Runtime:connect`][ref-runtime-connect] never starts
  one. Without a `socket_path`, `LIBTMUX_SOCKET_PATH` or `LIBTMUX_SOCKET` names
  the server, and otherwise tmux picks it.
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

[ref-concepts]: https://libtmux.org/en/lua/latest/concepts/server-session-window-pane/
[ref-runtime-luv]: https://libtmux.org/en/lua/latest/reference/libtmux-runtime-luv/
[ref-runtime-nvim]: https://libtmux.org/en/lua/latest/reference/libtmux-runtime-nvim/
[ref-server]: https://libtmux.org/en/lua/latest/reference/libtmux-server/
[ref-luv-run]: https://libtmux.org/en/lua/latest/reference/libtmux-runtime-luv-run/
[ref-runtime-connect]: https://libtmux.org/en/lua/latest/reference/libtmux-runtime-connect/
[ref-server-new-session]: https://libtmux.org/en/lua/latest/reference/libtmux-server-new_session/
[ref-server-query]: https://libtmux.org/en/lua/latest/reference/libtmux-server-query/
[ref-session-snapshot]: https://libtmux.org/en/lua/latest/reference/libtmux-session-snapshot/
[ref-session-attach]: https://libtmux.org/en/lua/latest/reference/libtmux-session-attach/
[ref-snapshot]: https://libtmux.org/en/lua/latest/reference/libtmux-snapshot/
[ref-nvim-start]: https://libtmux.org/en/lua/latest/reference/libtmux-runtime-nvim-start/
[ref-query]: https://libtmux.org/en/lua/latest/reference/libtmux-query/
[ref-query-select]: https://libtmux.org/en/lua/latest/reference/libtmux-query-select/
[ref-selection]: https://libtmux.org/en/lua/latest/reference/libtmux-selection/
[ref-selection-where]: https://libtmux.org/en/lua/latest/reference/libtmux-selection-where/
[ref-selection-filter]: https://libtmux.org/en/lua/latest/reference/libtmux-selection-filter/
[changes]: https://github.com/libtmux/libtmux-lua/blob/master/CHANGES.md
