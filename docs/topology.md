# Topology operations

Session, Window, Pane and WindowLink handles run explicit mutations. Each
returns a Request that resolves to `true` once tmux processes it. Existing
records do not change in place: take a snapshot to see the result.

```lua
assert(session:rename("build"):await())
assert(window:resize({ width = 120, height = 40 }):await())
assert(window:layout({ named = "tiled" }):await())
```

## Names and removal

`session:rename(name)` and `window:rename(name)` use the stable native ID.

- A name is a nonempty NUL-free string of at most 1,024 bytes. Session names
  also exclude dots, colons, ASCII controls and DEL; exactly tmux 3.7 excludes
  dots and colons from window names too.
- Format markers stay literal. tmux still validates and cleans names, and
  releases differ in the bytes they accept, so success does not promise
  byte-exact storage.
- Renaming a window turns off its automatic rename.

`session:kill()` destroys the session and its links. A linked window can
survive in another session. `window:kill()` destroys the window and **every**
link to it, which can remove sessions left without windows. Cancelling a
Request never implies either.

## Window navigation

- `session:navigate_window(direction)` takes `"next"`, `"previous"` or
  `"last"`. Next and previous accept `activity = true` to pick a window with
  an alert; `last` rejects `activity`, even `false`. It changes the session's
  active window and follows hooks and grouped-session behavior.
- `session:renumber_windows()` renumbers from the session's `base-index`. Window
  IDs stay and captured link indices go stale. It is separate from moving one
  window.

## Window placements

A WindowLink names one placement by session, index and window ID. Use
`creation.window_link`, or a handle from `snapshot.window_links`, when an
operation needs that exact placement, duplicates in one session included.
`link:select()` selects its index within its session.

`link:link(destination)` creates another placement. `link:move(destination)`
also removes this one. A destination is one plain record:

- `{ session = session, index = 5 }`: an explicit index. Without `index`, tmux
  picks a free one from `base-index`; it does not append.
- `{ link = anchor, position = "before"|"after" }`: next to an existing
  placement, which may shift indices.
- `{ link = victim, position = "at" }`: needs `{ replace = true }` as the
  options, and can destroy the victim window if it has no other links. A
  numeric index alone never replaces.

Both default to `select = false`, though removing an active source or replacing
an active destination can still force a selection. An occupied numeric
destination returns tmux's error; the library never looks elsewhere or retries.

- `link:swap(other)` exchanges the windows in two placements. By default the
  selected **slots** stay selected while their windows change. `select = true`
  selects the destination slot, and the source slot when the sessions differ.
  Swapping two placements of one window does nothing.
- `link:unlink()` removes only this placement and refuses tmux's last-link
  destruction unless `kill_if_last = true`. Grouped sessions keep tmux's
  synchronization and last-link rules. A tmux refusal is not a rollback:
  insertion can shift indices before a later grouped-session error.

Guards:

- Each operation checks the stored source tuple, and any destination tuple, in
  tmux's command queue just before mutating. A recognized mismatch returns
  `stale_target` with `effect = "not_sent"` and the receipt.
- Old handles never rebind after an index is reused, moved or swapped.
  Recreating the same tuple cannot be told from continuity, and aliases can
  change the checks. The guards are not a transaction or an unconditional
  compare-and-swap. See [commands](commands.md).
- Success returns `true`. Take a snapshot to find the new placements; no
  predicted index or hidden read builds a new WindowLink.

## Window size and layout

`window:resize(options)` takes exactly one form:

- `width` and `height`, either or both, integers from 1 to 10,000.
- `direction = "left"|"right"|"up"|"down"` with `amount` from 1 to 10,000,
  default 1.
- `largest = true` or `smallest = true`, by tmux's client-size rule.

Resizing sets `window-size` to manual, applies to every link to the window,
and can be constrained by the layout and client sizes, so success does not
tell you the dimensions.

`window:layout(options)` also takes exactly one form:

- `named`: `even-horizontal`, `even-vertical`, `main-horizontal`,
  `main-vertical` or `tiled`. The mirrored main layouts need tmux 3.5 or
  later.
- `layout`: an exported layout string of at most 65,536 bytes. It is the
  checksum form (four hex digits, a comma, the body), or on tmux 3.8 and later
  the JSON form.
- `next = true`, `previous = true` or `restore = true`.

A malformed layout header returns `invalid_layout` before sending, which avoids
tmux 3.3a's faulty error handling and short-header reads in older parsers. A
JSON layout also returns `invalid_layout` below 3.8, the first release that
accepts one ([compatibility](compatibility.md)). tmux 3.8 exports
`window_layout` as JSON, except to a control-mode client that has not set the
`new-layouts` flag, which still gets the checksum form
([tmux 3.8 CHANGES](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/CHANGES#L38-L40)).

- Layout operations unzoom before tmux validates the checksum and body, so a
  rejected layout can still change zoom.
- A nonzero exit carries its receipt and `effect = "completed"`; it is not a
  rollback.
- Layout syntax is tmux's grammar, never evaluated as Lua or shell text.

## Restart a window

`window:respawn({ context = link, ... })` needs a WindowLink naming this
window. Its session supplies the launch context, inherited environment
included. The link is checked in tmux's queue first; the method never picks a
session from a global window ID.

- Launch options match [creation](creation.md): literal `argv` or explicit
  `shell`, an absolute `cwd` and a per-process `environment` map. Without
  launch text it reuses the previous command. The `cwd` check completes before
  sending.
- `kill = true` replaces running processes; otherwise tmux refuses an active
  window.
- Respawn keeps the window ID and its first pane, removes the other panes and
  resets the layout through every link. It can fail after destructive
  preparation, and an error is not a rollback. Handles to the removed panes do
  not become references to the first one.

## Move a pane

`pane:move_to(target, options)` moves the same pane into the target pane's
window.

- It splits vertically by default, with `select = false`. Pick
  `direction = "horizontal"`, a `size` of 1 to 10,000 cells, or a `percent`
  of 1 to 100; size and percent exclude each other.
- `before = true` changes tmux's geometry, not a promised pane-index order.
  `full_size = true` spans the whole window.
- `select = true` needs `target_link = link`, naming the placement whose
  session and index get selected. A target link also checks membership when
  selection is off. The library checks that placement and the target pane's
  window separately in tmux's queue, then sends the compound target. A moved
  target pane returns `stale_target`; one tmux cannot resolve can keep tmux's
  own error.

Moving changes pane membership through every window link. Moving the last pane
destroys the old window and all its placements. Layout and selection changes
can happen before a later error. The pane keeps its ID and running process.

## Break a pane into a window

`pane:break_out(source_link, destination, options)` needs the pane's exact
source WindowLink. A destination is a session with an optional numeric index,
or an anchor WindowLink with `position = "before"|"after"` (see
[window placements](#window-placements)). Replacement is not supported, and an
occupied numeric destination returns tmux's error.

- The source placement, the pane's membership and any anchor are checked in
  tmux's queue. The pane keeps its ID and running process.
- With several panes, tmux creates a new window and the source window keeps its
  links. With one pane, it moves that placement of the existing window, and
  other links survive.
- `select` defaults to false, though removing an active placement can force a
  selection.
- `name` follows the window name rules above. Without it, a lone pane keeps its
  window's name and options, and a new window takes tmux's default name and
  inherited options. An explicit name turns off automatic rename.

Exactly tmux 3.7 has a multi-pane naming defect, so a literal `break-pane`
through `server:command` is refused there ([commands](commands.md)). The typed
operation repairs it:

- With no name requested, it supplies a placeholder to avoid the faulty null
  name path.
- For a named multi-pane break, it renames the pane's window afterward. The
  repair fires rename notifications and `after-rename-window` hooks. Lone
  panes and other releases need no repair.
- A repair failure can happen after the pane moved, and it is not a rollback.

## Effects and boundaries

- Options are plain records, copied before sending. The nested `process`
  limits are those of [pane operations](panes.md). Input is at most 1 MiB per
  operation.
- A stale generation or invalid target fails before dispatch. If continuity is
  lost after tmux succeeded, the error keeps `effect = "completed"` and the
  receipt. Mutations are never retried.
- [Aliases and hooks](commands.md) still apply. Nothing here is a transaction
  or protects against an alias that replaces a built-in command.
