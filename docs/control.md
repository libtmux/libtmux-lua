# Observing a session

`server:observe(session, options)` returns a Request for an observation lease.
Pass a session handle from that Server's snapshot or creation result. Concurrent
leases for the same session share one owned persistent client. General commands
use the [process command API](commands.md).

Opening verifies the pinned daemon before spawning and checks daemon evidence
again through the new connection. Every client
uses `-N`; a missing session fails without creating a session or linking a
window. Each endpoint owns at most eight observation clients.

The observation offers:

- `watch_pane(pane, options)` returns a ready pane-output watch for a pane handle.
- `watch_notifications(options)` returns a ready notification watch,
  preserving unknown events and raw lines.
- `subscribe_format(pane, field_names, options)` returns a typed native
  format watch using generated pane fields.
- `coverage()` returns copied session/pane coverage and connection generation.
- `close()` closes this lease's watches; final close waits for native cleanup.

Handles must belong to the same Server. Their copied private identities select
targets; overwriting a public `reference` method cannot redirect observation.
Options are copied on submission. Shared connection limits must agree across
leases; conflicting options return `option_conflict`. Separate Server handles
have independent pools even when their socket paths match.

Canceling acquisition releases only that caller's claim. Startup continues for
remaining callers; canceling the final claim closes its client. Acquisition
during final cleanup returns `closing`. Await final `close()` before reopening;
a new connection has a distinct generation and requires new watches. A failed
startup also retains its pool entry until native cleanup finishes.
A new acquisition on a failed shared connection returns its recorded loss
error. Close the old leases before opening a fresh connection.

Watch creation installs its local receiver before a same-connection
`list-panes` coverage check. A pane outside that session returns
`uncovered_pane`. Topology changes invalidate reported coverage and close
affected pane watches with `observation_gap`; opening a new watch performs
another bounded check. These checks are observations, not a topology
transaction. Capture remains a separate operation with no claimed lossless
handoff to the stream.

## Reading and closing

`watch:next({ timeout = milliseconds })` returns a Request for one event.
An absolute monotonic `deadline` is also supported. Only one read may be
pending on a watch; another returns `concurrent_read`. Canceling a read
detaches that waiter and leaves the watch usable. `watch:close()` is explicit
and idempotent. An explicitly closed watch returns `nil, nil`; connection
failure or loss returns `nil, err`.

Pane events carry `kind = "output"`, `pane`, `data`, `sequence`, `generation`
and `server_generation`. `data` is a Lua byte string, including NUL and
non-UTF-8 bytes. Extended output also preserves its decimal `age` and
`metadata`. A sequence identifies ordering within one connection; it does
not imply complete pane history or application completion.

Format events carry `kind = "format"`, a typed `value`, and explicit
`session_id`, `window_id`, window-link `index` and `pane` context. Only catalog
field names are accepted. Unknown or unsupported fields fail before writes;
caller text cannot introduce a format expression. Registration acknowledgement
establishes readiness. Native values arrive on tmux's
[one-second sampling timer](https://github.com/tmux/tmux/blob/3b929f332aafa7f1080eacc31feb11ffbb1d1841/control.c),
so readiness does not wait for the first sample. Native title normalization
and other daemon field behavior remain visible in the returned values.
Closing a format watch unregisters its subscription.

## Bounds and ownership

Defaults are 128 pending housekeeping replies, 128 watches, 4 MiB of retained
connection data, and 1 MiB or 1,024 events per watch. Each observation claim,
shared attachment and public watch consumes a runtime resource slot; the
default runtime limit is 128 resources in total. Runtime byte and logical
request limits also apply. Watch byte accounting includes event metadata;
subscription projections and queued encoded commands are charged before
deferred work begins.

Overflow closes the affected watch with `observation_gap`. Its partial result
reports discarded event count and decoded pane-byte count. Other watches and
the shared reader continue. Native `%pause` also invalidates pane continuity.
There is no silent drop policy, output coalescing, or claim that tmux pause is
lossless backpressure.

The reader parses bounded slices independently of watch consumption. Completion
callbacks run through the runtime scheduler; application callbacks must not
block the shared Lua event loop. A persistent connection occupies a resource
lease, not an active process slot. A pending `next` uses the separate bounded
logical-request lane.

The serialized writer accepts only private housekeeping operations. Arguments
are encoded for tmux's control-line parser. Bootstrap has its own response;
subsequent replies use FIFO attribution and matching guard tuples. A request
canceled after a possible write leaves a connection-owned tombstone until its
reply drains. A write or framing failure closes the connection and fails
pending callers. No command or pane input is retried or replayed.

Normal root return closes resource leases after owned requests retire.
Endpoint close or generation invalidation also closes its observation clients.
Native cleanup waits for exit, pipe closure and pending write callbacks.
Post-exit pipe drain is bounded at 250 ms. Explicit close first ends stdin;
after 100 ms it signals only the owned client, escalating after another
100 ms. It never signals the tmux daemon or a pane program.

## Attachment effects

The client uses `attach-session -E -f ignore-size,active-pane` with an exact
session ID. It issues no shared pane/window selection, resizing, detachment
or session-environment updates. Native client listings, attachment state,
focus hooks and configured lifecycle policy remain observable. Hooks may
themselves change state; preservation fixtures use neutral hooks.

`focus-events` stays unchanged. Disabling it cannot suppress every attachment
focus hook, and tmux provides no supported client flag for that guarantee.
The transport does not create hidden sessions or change window links. It
omits `-r`: on tmux 3.7 and 3.7c, a read-only observer can make independent
process-lane `send-keys` fail with "client is read-only". The private writer
restricts observation commands without that flag.

Closing an observer removes its attached client. Native policy such as
`destroy-unattached` can then destroy its session. A startup check cannot
guarantee lifetime preservation when options or other clients can change.
The library does not rewrite borrowed options or retain hidden clients to
prevent that policy.

Housekeeping assumes the server's native command semantics. Aliases and hooks
can change even builtin commands; control framing does not authenticate server
output. This transport does not enable general command acceleration.

Automatic reconnect and subscription replay are not implemented. Opening a
new connection creates a distinct generation; callers must establish new
watches and treat the interval between connections as a gap.
