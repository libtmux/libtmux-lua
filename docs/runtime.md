# Runtime ownership

The runtime schedules asynchronous requests and owns their cleanup. Its
[connection and snapshot API](snapshots.md) captures state explicitly.
[Commands](commands.md), [creation](creation.md) and
[session observation](control.md) use the same runtime.

Choose an adapter:

- `libtmux.runtime.luv` for a standalone Lua process. `run(body, limits)` drives
  a quiescent top-level loop and returns `value, err` once owned work has
  finished. It rejects coroutine entry, Neovim, active borrowed handles and
  nested calls from a Lua-driven luv loop. A C host that drives libuv without a
  Lua `uv.run` frame is outside this contract. Importing the adapter does not
  load luv or start a loop.
- `libtmux.runtime.nvim` in Neovim. `start(body, on_done, limits)` returns the
  runtime and root Request at once. It borrows the host loop and schedules
  callbacks outside fast events. `on_done(value, err)` runs after owned cleanup;
  unrelated host handles stay open.

## Start a private server

`runtime:start_server(options):await()` starts a tmux server this runtime owns
and resolves to an `OwnedServer`. [`connect`](snapshots.md) only binds a server
that already runs. The tested programs are
[`start_server.lua`](../examples/api/start_server.lua) and
[`with_server.lua`](../examples/api/with_server.lua).

| Option | Default | Meaning |
| --- | --- | --- |
| `binary` | required | Absolute tmux executable |
| `config` | `/dev/null` | Absolute configuration file; the default loads none |
| `root` | system temporary directory | Absolute directory that holds the private one |
| `environment` | none | `NAME = value` entries for the daemon and its panes |
| `timeout` | 5000 | Milliseconds that starting and stopping each wait for tmux |

- The server lives in a new `libtmux-XXXXXX` directory under `root`, with its
  socket `tmux.sock` inside. The directory is private to the caller.
- The daemon inherits your environment without `TMUX`, `TMUX_PANE` and every
  `LIBTMUX_SOCKET*` variable. `environment` is added, and `TMUX_TMPDIR` names
  the private directory. `environment` cannot set those names.
- The daemon runs with `exit-empty off`, so it stays up with no session. The
  call resolves once the server answers; create sessions with
  [`new_session`](creation.md).
- The directory name and tmux's socket alias must fit `sun_path`: 107 bytes on
  Linux, 103 on macOS and the BSDs. A `root` more than 45 bytes under that
  limit fails with `invalid_endpoint` before anything is created. Without
  `root`, the system temporary directory is used, or `/tmp` when it is too long.

`OwnedServer` has `server`, the same handle `connect` returns, and
`socket_path`, which a second handle can connect to.
`server:close()` releases the handle and leaves the daemon running.

`owned:stop():await()` ends the server:

- It runs `kill-server`, connects to the socket until it is refused or gone,
  and removes the directory. Each wait is bounded by `timeout`.
- A daemon that still answers fails with `stop_failed`. The directory stays and
  `err.directory` names it. Calling `stop` again tries once more.
- A server the program left under the directory is stopped too, and `stop` fails
  with `leaked_server`. `err.sockets` lists each socket, relative to the
  directory.
- After a successful stop, calling it again returns `true`.

The runtime stops every owned server that is still running when it ends,
whether the body returned, failed or was cancelled. A stop that fails then
fails the run with `cleanup_failed`. Cleanup does not run when the process is
killed with `SIGKILL`: the daemon and its directory stay.

`runtime:with_server(options, body)` starts a server, calls
`body(server, owned)` and stops the server whether the body returns a value or
an error or raises one. It resolves to what the body returns. The body runs in
the calling task, so it can await.

## Tasks and results

The body receives its runtime. `runtime:spawn(body)` creates a child task and
returns its Request at once.

- Tasks return `value, err`. A non-nil error or an exception fails the enclosing
  task scope.
- Library operations isolate operational failures in the Request they return.
  An unhandled failure in a task you spawned still fails the root.
- Returning normally joins child tasks, requests and deferred callbacks.
- A task yields only through runtime operations. Lua CPU work is not
  preemptible.

Waiting:

- `request:await()` returns `value, err` from a managed coroutine in the same
  runtime. A wait from the main thread, a foreign coroutine or another runtime
  raises `invalid_await_context`. Several tasks can wait on one Request.
- `request:on_complete(fn)` registers a deferred `fn(value, err)`. Registering
  after settlement stays deferred while the runtime is live. After the root
  retires or the runtime closes it raises `closed`, and exceeding the callback
  or retained-byte limits raises `queue_full` at once. A callback failure fails
  its scope, or appears in `runtime:errors()` when the scope has already failed
  or retired.
- `request:result()` reads a settled result without waiting. An unsettled one
  returns `nil, err` with code `pending`.
- `is_settled()` is caller completion and `is_retired()` is transport cleanup.
  Cancellation can settle before retirement.

## Cancellation and limits

- The task that creates an operation owns its cancellation. Cancelling a task
  that waits on it only detaches the wait.
- `request:cancel(reason)` cancels the operation. `runtime:close(reason)`
  rejects new work, cancels owned work and returns the root Request. Repeated
  closes are safe.
- Transport errors keep `effect`: `not_sent`, `unknown` or `completed`.
  Cancelling a tmux client cannot prove that accepted daemon work stopped.
  Cleanup failures stay visible even after a result settled.

| Limit | Default |
| --- | ---: |
| `max_active` | 16 |
| `max_pending` | 128 |
| `max_logical` | 128 |
| `max_bytes` | 16 MiB |
| `max_tasks` | 128 |
| `max_callbacks` | 256 |
| `max_resources` | 128 |
| `dispatch_budget` | 64 |

Pass overrides as the adapter's `limits` table. `runtime:stats()` exposes the
counters.

- Byte accounting covers queued callback and waiter delivery until transport
  retirement and delivery finish. Values you keep belong to your own budget.
- Timers use monotonic milliseconds and reject delays above 2,147,483,647 ms.
- One-shot waits owned by the runtime, such as an observation's next event, use
  the separate `max_logical` limit until retirement and take no active or
  pending process slot. A normal root return joins them. Cancel them, close
  their producer or set a deadline when no event is expected. Cancelling a
  borrowed waiter only detaches that waiter.
- Persistent native resources use private leases outside the process slots. A
  lease can own one bounded byte reservation for its buffers, which counts
  toward `max_bytes` and `stats().resource_bytes`. Unreleased bytes report
  `cleanup_failed`, stay charged and count in `resources_failed`. Leases and
  raw Request constructors are private.
- A host failure triggers bounded cleanup. If it cannot finish, `cleanup_failed`
  reports the remaining counters rather than successful retirement.
- The runtime never closes a borrowed host loop or kills a tmux server as part
  of cancelling a request.

See the [development checks](../.github/CONTRIBUTING.md) for the luv and
Neovim host probes, and [compatibility targets](compatibility.md).

## Editor completion

LuaLS completes runtime, Request, Server and snapshot chains in both adapter
bodies, related pane and window fields included, and keeps the standalone `run`
return type. It cannot infer the body result's members in Neovim's separate
`on_done` callback: annotate that callback's result parameter when you want
completion there.
