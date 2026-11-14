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
