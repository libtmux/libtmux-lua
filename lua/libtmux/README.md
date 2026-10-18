# libtmux for Lua: the core package

The `libtmux` rock holds the Lua API for tmux sessions, windows and panes. It
is alpha software, published on
[LuaRocks](https://luarocks.org/modules/tony/libtmux). The
[root README](../../README.md#install) covers installation and a first
program, and the [API reference](https://libtmux.org/en/lua/latest/reference/)
lists every public symbol.

## Modules

Each heading links to its source on GitHub. `require("libtmux")` returns only
the rock's `_VERSION`; the entry points are these modules.

### [`libtmux.runtime.luv`](https://github.com/libtmux/libtmux-lua/blob/master/lua/libtmux/runtime/luv.lua): the standalone loop

`run(body, limits)` drives a luv loop for a standalone Lua process and returns
`value, err` after the work it owns has retired. Reference:
[`libtmux.runtime.luv`](https://libtmux.org/en/lua/latest/reference/libtmux-runtime-luv/)
and [`libtmux.Server`](https://libtmux.org/en/lua/latest/reference/libtmux-server/).

This is the complete [`new_session.lua`](../../examples/api/new_session.lua)
program. It connects to a running tmux server, creates a session and reads it
back:

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

After the [setup for the complete examples](../../examples/api/README.md), run
this from the repository root. The launcher starts a private tmux server and
stops it when the program exits:

```console
$ sh examples/api/run.sh examples/api/new_session.lua
session: demo
```

### [`libtmux.runtime.nvim`](https://github.com/libtmux/libtmux-lua/blob/master/lua/libtmux/runtime/nvim.lua): Neovim's loop

`start(body, on_done, limits)` returns at once, borrows the editor's loop, and
calls `on_done(value, err)` after the work it owns has retired. Handles it did
not create stay open. Reference:
[`libtmux.runtime.nvim`](https://libtmux.org/en/lua/latest/reference/libtmux-runtime-nvim/).
The root README shows [a snapshot from Neovim](../../README.md#neovim), and CI
runs the integration suite inside Neovim 0.10.0 and 0.12.5.

### [`libtmux.query`](https://github.com/libtmux/libtmux-lua/blob/master/lua/libtmux/query.lua): tables without tmux

Selects records from a list of Lua tables by criteria or by a function. It
needs neither tmux nor luv. Reference:
[`libtmux.query`](https://libtmux.org/en/lua/latest/reference/libtmux-query/).

This is the complete [`native_query.lua`](../../examples/native_query.lua)
program:

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

From the repository root, with the rock installed, it prints the two panes
whose command is `nvim` or `vim`:

```console
$ lua examples/native_query.lua
```

## Other packages

The repository also holds two unpublished scaffolds. Each heading links to its
directory.

### [`libtmux-workspace`](https://github.com/libtmux/libtmux-lua/tree/master/packages/workspace)

A development package for planned workspace operations. It has no loader or
builder yet.

### [`libtmux-mcp`](https://github.com/libtmux/libtmux-lua/tree/master/packages/mcp)

A development package for the planned MCP server. It has no server, tools or
prompts yet.
