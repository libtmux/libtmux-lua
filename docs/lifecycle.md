# Ownership, discovery and example testing

Use an owned scope when Lua should destroy the tmux objects it creates. A borrowed connection leaves the daemon running. Ownership lasts until the current managed task exits, or until you call the owner's `close()` or `release()` method. The scopes use the existing coroutine runtime and support Lua 5.1; they do not depend on garbage collection or Lua 5.4 closing variables.

## Automatic examples and test fixtures

Run this complete [example](../examples/owned_session.lua) with an existing default tmux server. It creates `owned-example`, prints its name, and removes that session after the body returns. A duplicate session name fails creation without adopting the existing session.

```lua
local adapter = require("libtmux.runtime.luv")

local function must(value, err)
    if err then
        error(err, 0)
    end
    return value
end

local result, err = adapter.run(function(runtime)
    local server = must(runtime:connect():await())
    return server
        :with_session({ name = "owned-example", argv = { "/bin/cat" } }, function(session)
            local snapshot = must(session:snapshot():await())
            print("session: " .. snapshot.name)
            return true
        end)
        :await()
end)
assert(result, tostring(err))
```

The external test runner supplies `LIBTMUX_SOCKET_PATH` or `LIBTMUX_SOCKET_NAME` before launching Lua. The file stays unchanged. `runtime:connect()` requires a running daemon. Use `runtime:owned_server(options)` to start a daemon on an unused endpoint, or `runtime:find_or_create_server(options)` to connect or start.

## Taking ownership of existing objects

Call `adopt()` on a server, session, window or pane handle. The returned `Owned` value has the accepted object in `value`, a copied identity from `receipt()`, and asynchronous `close()`. This complete program creates a borrowed session first, then adopts that existing session:

```lua
local adapter = require("libtmux.runtime.luv")

local function must(value, err)
    if err then error(err, 0) end
    return value
end

local result, err = adapter.run(function(runtime)
    local server = must(runtime:connect():await())
    local existing = must(server:new_session({
        name = "adoption-example",
        argv = { "/bin/cat" },
    }):await())
    local owner = must(existing.session:adopt():await())
    must(owner.value:rename("adoption-renamed"):await())
    return owner:close():await()
end)
assert(result, tostring(err))
```

`window:adopt()` destroys that window across its links. `pane:adopt()` destroys that pane after a move. Session owners destroy the accepted session after a rename. Server owners destroy the whole daemon; use an explicit disposable endpoint for server-ownership demonstrations.

Acceptance initializes the reserved server option `@libtmux_owner_generation` with 32 random hexadecimal characters if it is absent. It preserves a valid existing token and rejects an empty or malformed token. Keep this option unchanged and do not shadow it on sessions, windows or panes. Destruction checks the accepted token, PID and start time inside tmux. The connection also pins the socket inode and retains a private route to it. Numeric IDs, rather than mutable names or indexes, identify owned objects.

A daemon started through `owned_server` has an additional native child-process handle. Startup accepts ownership and returns a server handle through that child's private endpoint. If another daemon replaces the published socket before handoff or close, commands on this handle and owner cleanup still address the child that startup created. A separate `runtime:connect` to the public path sees its current daemon. An adopted daemon has no startup child handle and refuses a replaced or uncertain endpoint. Closing the borrowed server connection does not discard a live owner's pin.

## Finding running tmux servers

Discovery returns metadata and per-path diagnostics. It does not start servers or adopt them.

```lua
local adapter = require("libtmux.runtime.luv")

local result, err = adapter.run(function(runtime)
    local found, failure = runtime:discover_servers():await()
    if not found then return nil, failure end
    for _, server in ipairs(found.servers) do
        print(server.socket_path, server.pid, server.version)
    end
    print("truncated", found.truncated)
    return true
end)
assert(result, tostring(err))
```

The default roots are the current user's `tmux-UID` directories below captured `TMUX_TMPDIR` and `/tmp`. Pass `roots` to replace those directories and `paths` to add exact endpoints. Each list accepts up to 32 absolute paths. The defaults limit enumeration to 256 entries, probes to 32, and elapsed time between probes to 2,000 ms. One in-flight probe can add up to 750 ms. Discovery reads directory batches of 16 entries, rejects symlink roots and foreign-user sockets, reports failed probes, and deduplicates socket inodes. It does not promise a system-wide inventory or scan process tables.

## Find or create

Each result has `value` and `created`. A newly created result also has an `owner`; a reused result has none. This program creates or reuses a named session and window, then finds a pane by its application key:

```lua
local adapter = require("libtmux.runtime.luv")

local function must(value, err)
    if err then error(err, 0) end
    return value
end

local result, err = adapter.run(function(runtime)
    local found = must(runtime:find_or_create_server():await())
    local server = found.value
    local session = must(server:find_or_create_session("lookup-example"):await())
    local window = must(session.value:find_or_create_window("editor"):await())
    local pane = must(window.value:find_or_create_pane("editor-process"):await())
    print(found.created, session.created, window.created, pane.created)
    return true
end)
assert(result, tostring(err))
```

Session and window lookup use exact names; both reject backslashes because tmux rewrites them. Session names also exclude dots and colons. Pane lookup uses an exact value in the pane option `@libtmux_pane_key`; it searches the containing window when called on a pane. A missing key creates a split and stores that key on the new pane. More than one match returns `ambiguous`.

Find-or-create requests serialize within one Lua runtime for one captured socket path. Other processes and alternate path spellings can race. tmux enforces session-name uniqueness; window names and pane keys do not carry a cross-process uniqueness guarantee. Server startup publishes its private foreground socket with an atomic hard link and returns a concurrent winner as borrowed when the selected path already exists. `owned_server` refuses an occupied endpoint.

After closing a newly created server, the owner retains its published socket alias. A later `find_or_create_server` at that stale path returns a connection error; it does not remove the alias or start a replacement. `owned_server` returns `already_exists`. A caller that controls the directory namespace can retire the stale alias after proving the old daemon has exited and coordinating with other publishers, or select an unused path. Repeated calls work without alias retirement while the existing daemon remains live: they return it with `created = false` and no owner.

## Cleanup at scope exit

`server:with_session(options, body)`, `session:with_window(options, body)`, and `pane:with_pane(options, body)` invoke the body with the owned object and its owner. `runtime:with_server(options, body)` supplies a new server. `owner:scope(body)` limits an existing owner's lifetime to that body.

```lua
local adapter = require("libtmux.runtime.luv")

local result, err = adapter.run(function(runtime)
    local server, failure = runtime:connect():await()
    if not server then return nil, failure end
    local owner
    owner, failure = server:owned_session({
        name = "cleanup-example",
        argv = { "/bin/cat" },
    }):await()
    if not owner then return nil, failure end
    return owner:scope(function(session)
        return session:rename("cleanup-renamed"):await()
    end):await()
end)
assert(result, tostring(err))
```

Use `owned_session`, `owned_window`, `owned_pane` or `owned_server` for an owner that lasts to the current managed task's exit. `owner:close():await()` permits early cleanup and repeat calls. A failed attempt retains `cleanup_error` and permits retry. `owner:release()` relinquishes destruction responsibility and returns the borrowed object. Releasing a newly started server also transfers responsibility for its private startup directory and socket links to the caller; the library retains them so the daemon stays usable.

Server cleanup waits for the accepted child to exit, then removes its private startup socket and directory. It leaves the published alias in place during normal close and startup rollback. An inode check followed by a pathname unlink cannot exclude a concurrent replacement between those operations. Keeping the alias protects that replacement, at the cost of leaving a stale socket path for the directory owner to manage. Releasing an owner retains both private and public routes for the caller.

Body failure and cancellation still run task cleanup. If both the body and cleanup fail, `cleanup_failed.cause` retains the body error and `cleanup_failed.errors` retains cleanup errors. The runtime retains deferred-cleanup diagnostics even after code handles a nested failure and retries; inspect the final adapter result as well as the local request.

Owned creation accepts one complete identity receipt before returning an owner. A later creation failure rolls back through that receipt; a rollback failure exposes its recovery owner. Cancellation cannot turn incomplete output into an object identity. An unknown receipt reports `creation_unknown`; the outer test harness owns final fixture cleanup. Caller cancellation does not prove that tmux rejected a command.

## Environment defaults and overrides

The library captures defaults at the public call. Explicit `socket_path` or `socket_name` wins, followed by nonempty `LIBTMUX_SOCKET_PATH`, nonempty `LIBTMUX_SOCKET_NAME`, a valid `TMUX` context, then tmux's named `default` socket. Supplying both explicit selectors fails. An invalid selected value fails without trying weaker selectors.

Named endpoints use the captured absolute `TMUX_TMPDIR` or `/tmp`. Startup creates only a missing `tmux-UID` directory, with mode 0700, below an existing root. It rejects foreign ownership, symlinks at the UID directory, and other-user permission bits; group permissions remain valid. Explicit paths create no parent directories. Filesystem lookup preserves `missing/..` and `symlink/..` semantics.

`client_env` copies child-only overrides; a `false` value removes a key. The additive connection option `ConnectOptions.env` supplies a complete child-environment sequence: `env = {}` means an empty environment, and supplied entries retain order, duplicates, empty entries and bare entries. It does not inherit host values. The existing per-command `CommandOptions.env` retains those sequence semantics. Choose either connection `env` or `client_env`; supplying a complete environment and an override map together fails validation because their meanings conflict. The library captures either form at the public call and removes `TMUX` and `TMUX_PANE` from launched clients. It leaves Lua's host environment unchanged and defines no `LIBTMUX_SOCKET_ENV` variable. tmux's server/session environment methods remain a separate API.

Endpoint selection and discovery use the first value for each name in a complete environment sequence. For `TMUX_TMPDIR`, an empty first value selects `/tmp` even when a later duplicate supplies a nonempty directory. The child receives the original order and duplicate values, apart from the tmux-context filtering above.

```lua
local adapter = require("libtmux.runtime.luv")

local result, err = adapter.run(function(runtime)
    local server, failure = runtime:connect({
        client_env = { EXAMPLE_MODE = "documentation", OLD_SETTING = false },
    }):await()
    if not server then return nil, failure end
    return server:command({ "display-message", "-p", "connected" }):await()
end)
assert(result, tostring(err))
```

## Sandbox and example testing

The lifecycle evidence runner starts a foreground fixture under an owned `/dev/shm/libtmux-lua-*` directory, passes a child environment, and executes the example file from the checkout. It accepts daemon process identities through pidfds and observes exits before removing the outer fixture root. Injected body, transport and cleanup failures exercise the library's error paths. The same imported example file is also run with an external output hook that throws a body error, stalls until the outer timeout, or kills the Lua worker. The source bytes stay unchanged. The body error runs Lua cleanup; timeout and worker death require the outer harness to stop its accepted processes before deleting its root.

Run the collected checks with `python3 tests/run_integration.py --pattern test_ownership.py`. They use the installed `LIBTMUX_TEST_LUA` and `TMUX_BIN` executables; `LIBTMUX_TEST_NVIM` adds the Neovim host check. For a persistent receipt from one unchanged example:

```sh
python3 tests/support/ownership_fixture.py ordinary examples/owned_session.lua \
    --evidence .cache/lifecycle-results --lua lua --tmux tmux
```

The shared documentation-testing scope includes Markdown, Astro Markdown/MDX, Sphinx reStructuredText/MyST and Python doctest. This Lua change supplies native Lua programs and an external environment boundary. Reusable format adapters, rendered-source binding across those formats, and hosted CI/release evidence remain separate gates. A killed Lua worker needs outer harness cleanup; in-process scopes cannot run after that worker exits.

For an explicit whole-server cleanup demonstration, choose an unused path below a directory you own before running this program. Socket configuration belongs in this example because it demonstrates daemon ownership. The scope stops its daemon and retires its private startup directory; the published alias remains. Retire that alias under your directory's namespace coordination before rerunning with the same path:

```lua
local adapter = require("libtmux.runtime.luv")

local result, err = adapter.run(function(runtime)
    return runtime:with_server({
        socket_path = assert(os.getenv("EXAMPLE_UNUSED_SOCKET")),
    }, function(server)
        return server:command({ "display-message", "-p", "owned daemon" }):await()
    end):await()
end)
assert(result, tostring(err))
```
