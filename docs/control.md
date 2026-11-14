# Observing a session

`server:observe(session, options)` returns a Request for an observation lease.
Pass a session handle from the same Server's snapshot or creation result. Leases
for one session share one persistent client. Other commands use the
[process command API](commands.md).

Observation needs tmux 3.7 or newer.

- On an older server, `server:observe` returns `unsupported` with
  `required = "3.7"` and `effect = "not_sent"`, before any lease, process or
  client exists. A short control attach can crash servers that lack the 3.7
  initialization fixes.
- Commands, typed operations, snapshots and polling captures work from 3.3a.
  To wait for text on any release, use
  [`pane:wait_for_text`](panes.md#wait-for-text).

Opening checks the daemon before spawning. The client's first command is a
fence on the daemon's pid, start time and version, so a replaced daemon
attaches nothing and reports `stale_generation`. Every client uses `-N`, so a
missing session fails without creating a session or linking a window. An
endpoint owns at most eight observation clients.

The observation offers:

- `watch_pane(pane, options)`: a ready pane-output watch.
- `watch_notifications(options)`: a ready notification watch that keeps
  unknown events and raw lines.
- `subscribe_format(pane, field_names, options)`: a typed format watch over
  generated pane fields.
- `coverage()`: a copy of the session and pane coverage, and the connection
  generation.
- `close()`: closes this lease's watches. The last close waits for native
  cleanup.

Handles and options:

- Handles must belong to the same Server. Their private identities pick the
  targets, so overwriting a public `reference` method cannot redirect one.
- Options are copied on submission. Shared connection limits must agree across
  leases, or the call returns `option_conflict`. Separate Server handles keep
  separate pools, even for the same socket path.

Opening and closing:

- Cancelling an open releases only that caller's claim. Startup continues for
  the others, and cancelling the last claim closes the client.
- Opening during final cleanup returns `closing`. Await the final `close()`
  before reopening. A new connection has a new generation and needs new
  watches.
- A failed startup keeps its pool entry until cleanup ends. A new open on a
  failed shared connection returns its recorded loss error. Close the old
  leases to open a fresh one.

Coverage:

- Creating a watch installs its receiver before a `list-panes` coverage check
  on the same connection. A pane outside the session returns `uncovered_pane`.
- A topology change invalidates coverage and closes the affected pane watches
  with `observation_gap`. Opening a new watch checks again.
- These checks are observations, not a transaction. Capture is a separate
  operation with no lossless handoff to the stream.

## Reading and closing

`watch:next({ timeout = milliseconds })` returns a Request for one event. An
absolute monotonic `deadline` also works.

- Only one read may be pending per watch; another returns `concurrent_read`.
- Cancelling a read detaches that waiter and leaves the watch usable.
- `watch:close()` is explicit and idempotent. A watch you closed returns
  `nil, nil`. A lost connection returns `nil, err`.

Event fields:

| Event | Fields |
| --- | --- |
| Pane output | `kind = "output"`, `pane`, `data`, `sequence`, `generation`, `server_generation`; extended output adds `age` and `metadata` |
| Format | `kind = "format"`, a typed `value`, `session_id`, `window_id`, the window link `index` and `pane` |

- `data` is a Lua byte string, NUL and non-UTF-8 bytes included.
- A sequence orders events within one connection. It does not mean the history
  is complete or that a program finished.
- Format watches take catalog field names only. An unknown or unsupported
  field fails before anything is written, and caller text never becomes a
  format expression.
- Registration acknowledgement means the watch is ready. Values arrive on
  tmux's [one-second sampling timer](https://github.com/tmux/tmux/blob/3b929f332aafa7f1080eacc31feb11ffbb1d1841/control.c),
  so readiness does not wait for the first sample. tmux's title cleaning and
  other field behavior show in the values. Closing a format watch unregisters
  it.

## Bounds and ownership

Defaults:

| Limit | Default |
| --- | --- |
| Pending housekeeping replies | 128 |
| Watches | 128 |
| Retained connection data | 4 MiB |
| Events per watch | 1,024, or 1 MiB |

- Each claim, shared attachment and public watch takes one runtime resource
  slot. The runtime allows 128 in total. Runtime byte and logical-request
  limits also apply, and watch bytes include event metadata.
- Overflow closes the affected watch with `observation_gap`, and the partial
  result reports the discarded event count and decoded pane bytes. Other
  watches and the shared reader continue. tmux's `%pause` also breaks pane
  continuity.
- There is no silent drop, no output coalescing, and no claim that tmux pause
  is lossless backpressure.
- The reader parses bounded slices whether or not watches are consumed.
  Completion callbacks run through the runtime scheduler, so a callback must
  not block the shared Lua event loop.
- A persistent connection holds a resource lease, not an active process slot.
  A pending `next` uses the logical-request lane.
- A write or framing failure closes the connection and fails pending callers.
  No command or pane input is retried or replayed.
- A normal root return closes leases after owned requests finish. Closing the
  endpoint, or a new generation, also closes its observation clients.
- Cleanup waits for the client to exit, its pipes to close and pending writes
  to finish. The post-exit pipe drain is bounded at 250 ms. An explicit close
  ends stdin first, then after 100 ms signals only the owned client, and
  escalates after another 100 ms. It never signals the tmux daemon or a pane's
  program.

## Attachment effects

- The client runs `attach-session -E -f ignore-size,active-pane` on an exact
  session ID. It does not select, resize, detach or update the session
  environment.
- Client listings, attachment state, focus hooks and lifecycle policy stay
  observable, and hooks can change state themselves. The `focus-events` option
  is unchanged; disabling it cannot suppress every attachment focus hook, and
  tmux offers no client flag that guarantees it.
- No hidden sessions are created and no window links change.
- The client omits `-r`. On tmux 3.7 and 3.7c a read-only observer can make
  independent `send-keys` fail with "client is read-only". The private writer
  restricts observation commands without it.
- Closing an observer removes its client. A policy such as `destroy-unattached`
  can then destroy its session, and no startup check can promise otherwise when
  options or other clients can change. The library does not rewrite borrowed
  options or keep hidden clients to prevent that.
- Observation assumes the server's native command semantics. Aliases and hooks
  can change built-in commands, and control framing does not authenticate
  server output. It does not accelerate general commands.

Reconnect and subscription replay are not implemented. A new connection has a
new generation: establish new watches and treat the time between connections
as a gap.
