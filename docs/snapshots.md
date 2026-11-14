# Capture server state

`runtime:connect(options):await()` binds a running tmux server.
`server:snapshot(options):await()` captures its state. Every live call returns
a Request. The [snapshot example](../examples/snapshot.lua) prints each pane
and its window ID.

## Connect to a server

- Pass an absolute `binary` and, usually, an absolute `socket_path`.
  `config_path` defaults to `/dev/null`.
- The library never starts a server. Importing it and reading captured records
  do no I/O.
- Setup reads the daemon's version and identity and disables tmux autostart.

Without a `socket_path`, `connect` picks the server in this order:

1. `LIBTMUX_SOCKET_PATH`: an absolute socket path (tmux `-S`).
2. `LIBTMUX_SOCKET`: a socket name (tmux `-L`).
3. Neither set: tmux chooses. That is the server in `TMUX` inside tmux, and
   otherwise the default socket under `TMUX_TMPDIR`.

An empty or whitespace-only variable counts as unset. A `socket_path` option
leaves both unread.

| Situation | Error |
| --- | --- |
| No server on the socket tmux picked, or on the `LIBTMUX_SOCKET` name | `invalid_endpoint` |
| No file at a socket path | `invalid_endpoint` |
| A socket file that outlived its server | `uncertain_generation` |

Identity:

- Every command carries the daemon's pid, start time and release as a fence.
  A restart, a replaced socket or an uncertain connection invalidates the
  handle. Reconnect explicitly; old references never bind to reused IDs.
- On Linux, a socket path gets a private alias beside it, so that directory
  must allow creating hard links. A socket name, or tmux's own choice, has no
  path to alias and creates nothing.

`server:close():await()` closes the handle and leaves the daemon running. The
runtime also closes handles when its root scope ends, so keep live work inside
that scope.

## Collections and projections

- A snapshot holds `sessions`, `windows`, `panes`, `window_links`, `clients`
  and `buffers` as [native selections](query.md).
- Collections deduplicate identity. `snapshot.raw` keeps the listing rows in
  order: a window linked twice has two link rows and one window.
- Relationships refer only to captured data. Clients are the ones
  `list-clients` shows.
- Window links own `session_id`, `window_id`, `index` and active context.
  Pane and window IDs stay tmux strings; Lua positions are not tmux indexes.
- A server with no sessions can still have buffers. Capture reads them without
  creating a session.

By default, capture loads every field in the [catalog](fields.md). The
`fields` option maps collection names to nonempty field-name lists; omitted
collections keep their default projection, and required identity and
relationship fields are added.

- `requested_projections` records your selection and `projections` the
  effective fields, both keyed by singular entity names such as `pane` and
  `window_link`.
- `capabilities.fields` records which fields the observed tmux version has.

Records are plain mutable tables. Refresh by calling `snapshot` again.
Editing a record changes nothing in tmux or in another snapshot.

## Handles

`server:handle(snapshot, record)` makes a handle from a record. The record's
kind picks the class: a `SnapshotPane` gives a `libtmux.Pane`, a
`SnapshotSession` a `libtmux.Session`, so LuaLS offers only the methods tmux
accepts for that kind.

- The handle copies the record's private identity. Editing the exposed `id`
  or `ref` fields cannot redirect it.
- `handle:reference()` returns a separate reference table, with no I/O.
- `handle:snapshot():await()` captures fresh state and returns the matching
  record.
- A missing link index, client TTY or buffer name returns `target_missing`.
  A stale server generation fails before capture.
- A client or buffer that reuses a name is not treated as the same object.

## Consistency and limits

Capture spans several tmux commands and is not atomic.

- `acquisition.started` and `finished` are monotonic milliseconds.
- A relationship race lands in `races` and sets `complete` to false. A
  transport failure returns an error.
- `strict = true` adds one verification pass that compares membership and
  link context, ignoring order and volatile values. A mismatch returns
  `inconsistent_snapshot` with the first snapshot in `err.partial`. Capture
  never retries to manufacture consistency.
- Equal passes do not prove continuous identity or catch objects created and
  removed between reads. Replacing a named buffer can keep every catalog field
  and change its contents.

| Limit | Default | Effect |
| --- | --- | --- |
| `max_rows` | 65,536 | Raw rows across all collections, per pass |
| `max_bytes` | 16 MiB | Encoded output and retained scalar and key bytes, per pass |
| `timeout` | 750 ms | Each listing command; endpoint checks have their own 750 ms bound |

Accumulated rows and the graph copy also draw on the runtime's byte budget;
exhausting it returns `queue_full`. Cancel the Request to stop earlier.
Cancellation retires owned clients and never kills the daemon. Closing the
server during capture prevents a successful result.

Run the example against an existing server:

```console
$ TMUX_BIN=/usr/bin/tmux TMUX_SOCKET=/tmp/example-tmux.sock lua examples/snapshot.lua
```
