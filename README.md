# libtmux for Lua

Script tmux from Lua: create sessions and panes, capture terminal output,
query server state, and watch pane output. Use standalone Lua with luv or
Neovim's event loop.

**Under development.** Install from a checkout; the API is still changing.
The separate MCP and workspace packages are scaffolds.

[Install](#install) · [Read a server](#read-a-server) ·
[Query](#query-captured-state) · [Create panes](#create-sessions-and-panes) ·
[Neovim](#neovim) · [Guides](#guides) ·
[CI](https://github.com/libtmux/libtmux-lua/actions/workflows/ci.yml) ·
[MIT license](LICENSE)

## Install

From this checkout, use LuaRocks configured for your Lua interpreter:

```console
$ luarocks --local make rockspecs/libtmux-scm-1.rockspec
```

Add the local rocks tree to Lua's module paths:

```console
$ eval "$(luarocks --local path)"
```

For standalone scripts, also install luv. Building it requires a C compiler
and CMake. Neovim provides its own libuv binding.

```console
$ luarocks --local install luv 1.52.1-0
```

Core and local queries require only Lua. Importing a module does not start
tmux or an event loop. CI runs unit tests on Lua 5.1–5.5 and LuaJIT, plus live
tests across tmux 3.2a–3.7c. See the [compatibility matrix](docs/compatibility.md)
for exact versions and remaining platform coverage.

## Read a server

Connect to an existing server by its explicit socket path. This is the full
[snapshot example](examples/snapshot.lua), which prints pane and window IDs:

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

Live operations return Requests; `:await()` yields inside the runtime body and
returns `value, err`. The `must` helper propagates errors. Closing the connection
leaves the tmux server and its sessions running.

Set `TMUX_BIN` and `TMUX_SOCKET` to absolute paths for your server, then run:

```console
$ lua examples/snapshot.lua
```

<details>
<summary>Try it on a temporary server</summary>

Run from the checkout after installing the dependencies above. This starts a
private tmux server and removes it when the example finishes.

```console
$ sh <<'SH'
set -eu
unset TMUX TMUX_PANE
TMUX_BIN=$(command -v tmux)
demo_dir=$(mktemp -d /tmp/libtmux-lua-XXXXXX)
TMUX_SOCKET="$demo_dir/tmux.sock"
export TMUX_BIN TMUX_SOCKET
cleanup() {
    "$TMUX_BIN" -S "$TMUX_SOCKET" kill-server 2>/dev/null || true
    rm -rf "$demo_dir"
}
trap cleanup EXIT
"$TMUX_BIN" -f /dev/null -S "$TMUX_SOCKET" new-session -d -s demo
lua examples/snapshot.lua
SH
```

</details>

## Query captured state

After capturing `snapshot` in the example above, filter its panes with
structured criteria or an ordinary Lua function:

```lua
local editors = snapshot.panes:where({
    current_command = { one_of = { "nvim", "vim" } },
})
local inactive = snapshot.panes:filter(function(pane)
    return not pane.active
end)

print(#editors, #inactive)
for _, pane in ipairs(editors) do
    print(pane.id, pane.current_command)
end
```

Selections are dense, one-based Lua tables. Both queries read the snapshot
without calling tmux. Capture again to refresh it; a snapshot spans multiple
tmux commands and is not an atomic view.

See [criteria, relationships and live queries](docs/query.md), the
[field reference](docs/fields.md), or run the
[standalone table-query example](examples/native_query.lua):

```console
$ lua examples/native_query.lua
```

## Create sessions and panes

Before closing `server` in that runtime body, create a session and split a
window. These calls use the same `must` helper:

```lua
local work = must(server:new_session({ name = "work" }):await())
local editor = must(work.session:new_window({ name = "editor" }):await())
local split = must(editor.pane:split({ direction = "right", percent = 40 }):await())

must(split.pane:send_text("printf '%s\\n' hello"):await())
must(split.pane:send_keys({ "Enter" }):await())
```

Creation returns a table with `session`, `window`, `pane` and `window_link`
handles. These operations leave the new sessions and panes running. Sending
keys confirms that tmux accepted input; it does not wait for a shell command
to finish. See [creation](docs/creation.md) and [pane operations](docs/panes.md)
for literal argv, capture, resize and cleanup.

## Neovim

From the checkout, start Neovim with the library on its `runtimepath`:

```console
$ nvim --cmd 'set runtimepath+=.'
```

With `TMUX_SOCKET` set to an existing server's absolute socket path, run this
Lua code. `start` uses the editor's loop and reports the result in a callback:

```lua
local adapter = require("libtmux.runtime.nvim")

adapter.start(function(runtime)
    local server, err = runtime:connect({
        binary = vim.fn.exepath("tmux"),
        socket_path = assert(os.getenv("TMUX_SOCKET")),
    }):await()
    if err then
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

The runtime closes its connections when the body finishes and leaves the tmux
server running. See [runtime ownership and cancellation](docs/runtime.md).

## Guides

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
