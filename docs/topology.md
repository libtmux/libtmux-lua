# Session and window operations

Session and Window handles perform explicit mutations through the PROCESS
endpoint. Each operation returns a Request that resolves to `true` when tmux
successfully processes it. Refresh or capture a snapshot explicitly to inspect
the resulting state; existing records do not change in place.

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
- `layout`: a nonempty native layout string, bounded at 65,536 bytes.
- `next = true`, `previous = true` or `restore = true`.

Layout operations unzoom before native layout validation. A rejected layout
can therefore change zoom state. A nonzero native exit carries its receipt
and `effect = "completed"`; it does not establish rollback. Custom layout
syntax is tmux's grammar and is not evaluated as Lua or shell text.

## Effects and boundaries

Options are copied before dispatch and must be plain records. These methods
accept the same nested `process` limits as [Pane operations](panes.md).
Input is bounded at one MiB per operation. A stale generation or invalid
target fails before dispatch. If continuity is lost after successful native
completion, the error preserves `effect = "completed"` and that receipt.
Mutations are never retried automatically.

Native [aliases and hooks](commands.md) remain observable. These APIs do not
promise transactions or protection against aliases that replace a built-in
command. Contextual link moves, swaps, linking/unlinking, Window respawn and
Pane join/break remain pending typed domain operations.
