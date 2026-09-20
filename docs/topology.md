# Session and window operations

Session, Window and WindowLink handles perform explicit mutations through
the PROCESS endpoint. Each operation returns a Request that resolves to
`true` when tmux successfully processes it. Refresh or capture a snapshot
explicitly to inspect the resulting state; existing records do not change
in place.

```lua
assert(session:rename("build"):await())
assert(window:resize({ width = 120, height = 40 }):await())
assert(window:layout({ named = "tiled" }):await())
```

The [integration fixture](../tests/integration/topology.lua) includes setup,
native-state assertions and cleanup through both runtime adapters.

## Names and removal

`session:rename(name)` and `window:rename(name)` use their stable native IDs.
Names are nonempty NUL-free strings up to 1,024 bytes. Session names also
exclude dots, colons, ASCII controls and DEL. Format markers remain literal;
native name validation and cleaning still apply. Releases differ in accepted
bytes and escaping, so success does not promise byte-exact storage. Exact
tmux 3.7 also rejects dots and colons in Window names. Renaming a Window turns
off its automatic rename option.

`session:kill()` destroys that session and its links. A linked window can
survive in another session. `window:kill()` destroys the window and **every**
link to it, potentially removing sessions left without windows. Neither
method targets all other sessions or windows. Use these only for intended
mutations; Request cancellation never implies either operation.

## Window navigation

`session:navigate_window(direction)` accepts `"next"`, `"previous"` or
`"last"`. Next/previous support `activity = true` to select a window with a
native alert. Last rejects the `activity` option, including explicit false.
Navigation changes the session's active window and follows native hooks and
grouped-session behavior.

`session:renumber_windows()` renumbers from the session's `base-index` option.
It preserves Window IDs but invalidates captured link indices. It is a
separate operation from moving one window.

## Window placements

A WindowLink identifies one placement by session, index and Window ID. Use
`creation.window_link` or a handle from `snapshot.window_links` when an
operation needs that exact placement, including duplicate links in one
session. `link:select()` selects its index within its session.

`link:link(destination)` creates another placement;
`link:move(destination)` also removes this source placement. Destinations
accept one of these plain records:

- `{ session = session, index = 5 }` chooses an explicit index. Omitting
  `index` requests a native free index from `base-index`, not append.
- `{ link = anchor, position = "before"|"after" }` inserts relative to an
  existing placement and may shift indices.
- `{ link = victim, position = "at" }` requires `{ replace = true }` as the
  operation options. Replacement can destroy the victim Window if it has no
  other links. A numeric index alone never authorizes replacement.

Both operations default to `select = false`. Removal of an active source or
replacement of an active destination can still force native selection.
Occupied numeric destinations return native errors; the library never
searches for a different destination or retries.

`link:swap(other)` exchanges the Windows in two placements. By default,
selected **slots** remain selected, although their Window identities change.
`select = true` selects the destination slot, and the source slot when the
sessions differ. Swapping two placements of the same Window is a native no-op.

`link:unlink()` removes only this placement and refuses native last-link
destruction. `kill_if_last = true` permits that destruction. Grouped sessions
retain tmux's synchronization and last-link rules. Native refusal is not
rollback: insertion can shift indices before a later grouped-session error.

Each operation checks the stored source tuple, and any destination link
tuple, in the native command queue immediately before the mutation. A
recognized mismatch returns `stale_target`, `effect = "not_sent"`, and the
native receipt. Old handles never rebind automatically after index reuse,
movement or swapping. Recreating the identical tuple cannot be distinguished
from continuous identity; native command aliases can also change these checks.
The [native-command contract](commands.md) applies to the generated guards
and their mutation branches. They are not a transaction or an unconditional
compare-and-swap guarantee.

Success returns `true`; capture a new snapshot explicitly to find resulting
placements. No predicted index or hidden post-mutation read constructs a new
WindowLink handle.

## Window size and layout

`window:resize(options)` accepts exactly one form:

- `width` and/or `height`, integers from 1 to 10,000.
- `direction = "left"|"right"|"up"|"down"`, with `amount` from 1 to
  10,000, defaulting to one.
- `largest = true` or `smallest = true`, using tmux's native client-size rule.

Native resizing sets `window-size` to manual. Layout constraints and available
client sizes can affect the result; the command's success is not a dimensions
oracle. Resizing affects every link to the Window.

`window:layout(options)` also accepts exactly one form:

- `named`: `even-horizontal`, `even-vertical`, `main-horizontal`,
  `main-vertical` or `tiled`. The mirrored main layouts require tmux 3.5+.
- `layout`: an exported native layout string with a four-digit hexadecimal
  checksum, comma and body, bounded at 65,536 bytes.
- `next = true`, `previous = true` or `restore = true`.

Malformed custom-layout headers return `invalid_layout` before dispatch.
This avoids faulty error handling in tmux 3.3/3.3a and short-header reads in
older native parsers. Use `named` for standard layout names.

Layout operations unzoom before native checksum and body validation. A rejected
layout can therefore change zoom state. A nonzero native exit carries its receipt
and `effect = "completed"`; it does not establish rollback. Custom layout
syntax is tmux's grammar and is not evaluated as Lua or shell text.

## Restart a window

`window:respawn({ context = link, ... })` requires a WindowLink naming this
Window. Its session supplies the native launch context, including inherited
environment. The link is checked in the native queue before respawn; the
method never chooses an arbitrary session from a global Window ID.

Launch options match [creation](creation.md): literal `argv` or explicit
`shell`, absolute `cwd` and a per-process `environment` map. Omitting launch
text reuses the previous command. Working-directory validation is asynchronous
and completes before dispatch. `kill = true` permits replacement of running
processes; otherwise tmux refuses an active window.

Respawn retains the Window ID and its first Pane, removes sibling panes, and
resets layout through every link to the Window. It can fail after destructive
preparation; a native error does not establish rollback. Existing sibling
Pane handles do not become references to the restarted first Pane.

## Move a pane

`pane:move_to(target, options)` moves the same Pane into the target Pane's
Window. It defaults to a vertical split with `select = false`. Choose
`direction = "horizontal"`, `size` from 1 to 10,000 cells, or `percent` from
1 to 100. Size and percent exclude one another. `before = true` changes native
geometry; it does not promise a matching pane-index order. `full_size = true`
extends the split across the Window.

`select = true` requires `target_link = link`, identifying the exact placement
whose session and index will be selected. An optional target link also checks
membership when selection is disabled. The library checks that placement and
the target Pane's current Window separately in the native queue, then submits
the compound target. A moved target Pane produces `stale_target`; a target
that tmux cannot resolve can instead retain its native command error.

Movement changes global pane membership through all Window links. Moving the
last Pane destroys the old Window and all its placements. Native layout and
selection changes can happen before a later error. Moving a Pane preserves
its ID and running process; it does not restart that process.

## Effects and boundaries

Options are copied before dispatch and must be plain records. These methods
accept the same nested `process` limits as [Pane operations](panes.md).
Input is bounded at one MiB per operation. A stale generation or invalid
target fails before dispatch. If continuity is lost after successful native
completion, the error preserves `effect = "completed"` and that receipt.
Mutations are never retried automatically.

Native [aliases and hooks](commands.md) remain observable. These APIs do not
promise transactions or protection against aliases that replace a built-in
command. Pane break-out remains a pending typed domain operation.
