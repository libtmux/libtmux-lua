# Capture server state

Use `runtime:connect(options):await()` to bind a borrowed tmux daemon, then
`server:snapshot(options):await()` to capture its state. Every live operation
returns a Request. The [snapshot example](../examples/snapshot.lua) prints
each unique pane and its window ID using the public API.

Pass an absolute `binary` and explicit absolute `socket_path` to `connect`.
Optional `config_path` defaults to `/dev/null`. Connection options are copied
before dispatch. The library does not select a default server or start one.
Importing the library and inspecting captured records perform no I/O.

Connection setup reads the actual daemon's version and identity. Linux socket
binding creates a private socket alias in the selected socket's parent
directory; that directory must permit creation and hard links. Each command
checks the original socket and alias, reads bounded daemon evidence, and
disables tmux autostart. A restart, replaced socket or uncertain connection
invalidates the handle. Reconnect explicitly; old references do not bind to
reused IDs. Tests currently cover Linux under WSL2. Native Linux and macOS
remain separate unverified platform lanes.

`server:close():await()` closes the handle and its owned connections. It leaves
the borrowed daemon running. The runtime also closes handles when its root
scope finishes. Keep live work inside that scope; returning a handle from
`adapter.run` does not keep its runtime alive.

## Collections and projections

Snapshots contain `sessions`, `windows`, `panes`, `window_links`, `clients`
and `buffers` as [native selections](query.md). Canonical entity collections
deduplicate identity; `snapshot.raw` preserves contextual listing rows and
their order. A window linked twice has two link rows and one canonical window.
Relationships refer only to captured data. Clients are the attached clients
that tmux exposes through `list-clients`.

Window links own `session_id`, `window_id`, `index` and active context. Pane
and window IDs remain tmux strings; Lua positions are not tmux indexes.
A daemon with no sessions can still have buffers. Capture reads them without
creating a session.

By default, capture loads every supported field in the [catalog](fields.md).
The `fields` option maps collection names to nonempty field-name sequences;
omitted collections keep their default projection. Required identity and
relationship fields are added. `requested_projections` records the caller's
selection; `projections` records effective fields, including for empty
collections. Both maps use singular entity names such as `pane` and
`window_link`. `capabilities.fields` records availability for the observed
daemon version; it does not claim every tmux command is supported.

Refresh by calling `snapshot` again. It returns fresh records. Tables remain
mutable, so do not edit them during traversal. Editing a record does not
refresh the server, another snapshot or its private identity index.

Create a handle with `server:handle(snapshot, record)`. The record's kind picks
the handle's class: a `SnapshotPane` gives a `libtmux.Pane`, a
`SnapshotSession` a `libtmux.Session`, and so on, so LuaLS offers only the
methods tmux accepts for that kind. It copies the record's
private identity, so edits to exposed `id` or `ref` fields cannot redirect it.
`handle:reference()` returns a separate reference table without I/O.
`handle:snapshot():await()` explicitly captures fresh state and returns the
matching record. A missing link/index, client/TTY or buffer name returns
`target_missing`; stale server generations fail before capture. Same-name
client or buffer reuse cannot establish continuous object identity.

## Consistency and limits

Capture spans multiple commands. `acquisition.started` and `finished` are
monotonic milliseconds. Normal capture reports observed relationship races
in `races` and sets `complete` to false. Transport failures return an error.

Set `strict = true` for one additional identity/topology verification pass.
It compares membership and link context, ignoring listing order and volatile
scalar values. A mismatch returns `inconsistent_snapshot` with the original
snapshot in `err.partial`; capture never retries to manufacture consistency.
`verification` records the pass and its result. Equal observations do not
make capture atomic, prove continuous identity, or detect objects created
and removed between reads. Replacing a named buffer can preserve every
catalog field while changing its contents.

Each pass permits at most `max_rows` raw rows (default 65,536) across all
collections, before deduplication. `max_bytes` (default 16 MiB) limits both
total encoded output and retained scalar/key bytes per pass. Strict mode
adds one bounded pass. Accumulated rows and the graph copy also consume the
runtime's byte budget; exhaustion returns `queue_full`. These counters bound
data, not exact Lua heap allocation.

`timeout` defaults to 750 milliseconds per listing command. Endpoint evidence
checks have a separate bounded 750-millisecond deadline. Whole capture has
a finite command count; cancel its Request for an earlier stop. Closing the
server during capture prevents a successful current-reference result.
Cancellation retires owned clients; it does not kill the daemon.

Run the example against an explicitly selected existing server:

```console
$ TMUX_BIN=/usr/bin/tmux TMUX_SOCKET=/tmp/example-tmux.sock lua examples/snapshot.lua
```

The package gate runs this file from installed core and luv outside the
checkout, checks exact output, and verifies cleanup. Core-only installation
still has no luv dependency; this standalone example selects it explicitly.
