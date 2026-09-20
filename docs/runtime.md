# Runtime ownership

The runtime schedules asynchronous requests and owns their cleanup.
Use its [connection and snapshot API](snapshots.md) for explicit capture.
[Literal command execution](commands.md) shares that connection. Named domain
operations and observation are still being integrated.

Select `libtmux.runtime.luv` for a standalone Lua process. Its
`run(body, limits)` function drives a quiescent top-level loop and returns
`value, err` after owned work retires. It rejects coroutine entry, Neovim,
active borrowed handles and nested calls from a Lua-driven luv loop. A C host
that drives libuv without a Lua `uv.run` frame is outside this standalone
contract. Importing the adapter does not import luv or start a loop.

Select `libtmux.runtime.nvim` in Neovim. Its `start(body, on_done, limits)`
function returns the runtime and root Request immediately. It borrows the
host loop and schedules callbacks outside fast events. `on_done(value, err)`
runs after owned cleanup; unrelated host handles remain open.

## Tasks and results

The body receives its runtime. `runtime:spawn(body)` creates a child task and
returns its Request eagerly. Tasks return `value, err`; a non-nil error or
exception fails the enclosing task scope. Public library operations isolate
operational failures in their returned Request; an unhandled failure in a
caller's spawned task still fails the root. Returning normally joins child
tasks, requests and deferred callbacks. A task may yield only through
runtime operations; arbitrary Lua CPU work is not preemptible.

`request:await()` returns `value, err` from a managed coroutine in the same
runtime. Main-thread, foreign-coroutine and cross-runtime waits raise
`invalid_await_context`. Multiple tasks can wait on one Request.

`request:on_complete(fn)` registers a deferred `fn(value, err)` callback.
Registration after settlement remains deferred while the runtime is live.
Registration after root retirement or closure raises `closed`; exceeding
callback or retained-byte limits raises `queue_full` synchronously.
Callback failures fail their scope or appear in `runtime:errors()` when the
scope has already failed or retired.

`request:result()` reads a settled result without waiting; an unsettled
request returns `nil, err` with code `pending`. `is_settled()` describes
caller completion. `is_retired()` describes transport cleanup. Cancellation
can settle before retirement, so these states differ.

## Cancellation and limits

The task that creates an operation owns its cancellation. Canceling another
task that waits on that operation detaches its wait; it does not cancel the
producer. `request:cancel(reason)` cancels the requested operation explicitly.
`runtime:close(reason)` rejects new work, cancels owned work and returns the
root Request; repeated close calls are safe.

Transport errors preserve `effect`: `not_sent`, `unknown`, or `completed`.
Canceling a tmux client cannot prove that accepted daemon work stopped.
Cleanup failures remain visible even when a result has already settled.

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

Pass overrides as the adapter's `limits` table. Runtime counters are exposed
by `runtime:stats()`. Byte accounting includes queued callback and waiter
delivery until transport retirement and delivery finish. Completed values
retained by the caller belong to the caller's memory budget. Timers use
monotonic milliseconds and reject delays above 2,147,483,647 ms.

Logical Requests represent one-shot waits owned by the runtime, such as an
observation's next event. They use the separate `max_logical` limit through
retirement and do not occupy active or pending process slots. A normal root
return joins these waits. Cancel them, close their producer, or supply a
deadline when no further event is expected. Canceling a borrowed waiter
still detaches that waiter without canceling the producer.

Persistent native resources use private leases outside process slots. A
lease can own one bounded byte reservation for its buffers; those bytes
count toward `max_bytes` and `stats().resource_bytes`. Internal producers
can release discarded bytes or transfer their reservation atomically to a
same-runtime, unsettled Request before delivering its value. The total
runtime charge stays unchanged during transfer and lasts through queued
delivery. Closing the lease stops new retention and transfer; release
remains available during cleanup. Cleanup must discard and release its
buffers before reporting completion. Unreleased bytes report
`cleanup_failed`, remain charged, and increment `resources_failed` even
after the native close attempt ends. Leases and raw Request constructors
remain private implementation APIs.

Standalone host failures trigger bounded cleanup. If cleanup cannot finish,
`cleanup_failed` reports remaining counters; it does not report successful
retirement. The runtime never closes borrowed host loops or kills a tmux
server as part of request cancellation.

See [development checks](../.github/CONTRIBUTING.md) for real luv and Neovim
host probes and [compatibility targets](compatibility.md) for pending lanes.

LuaLS 3.19.1 completes runtime, Request, Server and snapshot chains in both
adapter bodies, including related pane/window fields. It preserves the
standalone `run` return type. That version does not infer the body result's
members inside Neovim's separate `on_done` callback; annotate the callback's
result parameter explicitly when editor completion is needed there.
