# Capture server state

Use `runtime:connect(options):await()` to bind a borrowed tmux daemon, then
`server:snapshot(options):await()` to capture its state. Every live operation
returns a Request. The [snapshot example](../examples/snapshot.lua) prints
each unique pane and its window ID using the public API.

`runtime:connect():await()` selects an existing daemon from captured defaults.
Pass `socket_path` or `socket_name` to select one explicitly; supplying both
returns `invalid_endpoint`. Selection follows this order:

1. An explicit path or name.
2. Nonempty `LIBTMUX_SOCKET_PATH`.
3. Nonempty `LIBTMUX_SOCKET_NAME`.
4. Nonempty `TMUX`, parsed from its last two commas.
5. The named socket `default`.

An empty environment selector counts as absent. A selected invalid value
returns `invalid_endpoint`; lower-precedence selectors do not override it.
Paths must be absolute and NUL-free. Names must be nonempty leaf names,
exclude `/`, `\` and NUL, and differ from `.` and `..`. The selected `TMUX`
context requires an absolute path, a positive decimal PID and a nonnegative
decimal session ID or `-1`; one leading `$` on a session ID is accepted. Paths
retain commas and whitespace.

Named sockets use captured `TMUX_TMPDIR`, or `/tmp` when it is empty or absent,
followed by `tmux-UID/name`. The root must exist. Connection setup creates a
missing per-UID directory with mode 0700, without creating parent directories.
It accepts an existing real directory owned by the current UID with no
other-user permission bits; group permissions are allowed. Filesystem lookup
preserves `missing/..` failures and `symlink/..` traversal. Explicit paths do
not create parent directories.

The connection captures its endpoint and client environment at the `connect`
call, before its Request runs. Later host edits cannot redirect commands or
cleanup. `binary` accepts an absolute path; omission resolves `tmux` through
the captured `PATH`. Optional `config_path` defaults to `/dev/null`.
`client_env` applies copied string overrides to the child environment; `false`
removes a key. These overrides also participate in endpoint selection. Clients
receive that snapshot with `TMUX` and `TMUX_PANE` removed. These settings leave
the host and tmux's [persistent environment](environment.md) unchanged.

The additive connection option `env` supplies a complete child-environment sequence; `env = {}` supplies an empty environment. It preserves entry order, duplicate names, empty entries and bare entries, apart from filtering `TMUX` and `TMUX_PANE` before child launch. Endpoint selection uses the first value for each name, including an empty value. Connection and discovery use that same rule for `TMUX_TMPDIR`; an empty first value selects `/tmp`. Choose `env` or `client_env`, since complete replacement and overrides have different meanings. The existing per-command `CommandOptions.env` remains available with its sequence semantics and the same tmux-context filtering.

Connect requires a running daemon, including on a fresh valid root. Preparing a directory does not start tmux. Use [`runtime:owned_server(options)`](lifecycle.md#taking-ownership-of-existing-objects) to start and own a daemon on an unused endpoint, or [`runtime:find_or_create_server(options)`](lifecycle.md#find-or-create) to reuse an existing daemon or start an owned one. The creator's managed task owns cleanup; a reused daemon remains borrowed. Server cleanup retains the published socket alias, so a later call cannot recreate a daemon at that stale path until the directory owner retires the alias under its own namespace coordination. Importing the library performs no I/O.
The [ordinary example](../examples/ordinary.lua) uses defaults and removes its
created session through [deferred cleanup](runtime.md#deferred-cleanup).

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
