# Pane operations

Pane handles perform explicit asynchronous operations through the pinned
PROCESS endpoint. Each method returns a Request; await it inside a managed
runtime task or use its completion callback. Snapshot records remain plain
captured data. Obtain a handle from a creation receipt or `server:handle`.

```lua
local capture = assert(pane:capture({ history_lines = 20 }):await())
local text = assert(capture:text())
assert(pane:send_text("printf '%s\\n' ready"):await())
assert(pane:send_keys({ "Enter" }):await())
```

The executable [integration fixture](../tests/integration/pane.lua) includes
connection setup, creation, output barriers and teardown.

## Capture and text

`capture()` returns `{ bytes, target }` with a pure `text()` method. `bytes`
preserves tmux's stdout, including its terminal newline and invalid UTF-8.
`text()` validates UTF-8 strictly and returns the same string; invalid input
returns `nil, err` with `invalid_utf8`. It performs no replacement, trimming,
newline conversion or tmux I/O.

Ordinary capture reads rendered screen/history cells. It does not recover the
original PTY byte stream, prove application completion, or establish an
ordered handoff to observation. It does not enter, exit or navigate copy mode.

The default captures the visible terminal screen. `history_lines = N` adds
up to N history rows, bounded at 1,000,000. Alternatively, `start_line` and
`end_line` accept integer row offsets or `"-"`: zero is the first visible row,
negative offsets refer to history, `start_line = "-"` selects all retained
history and `end_line = "-"` selects the visible screen's end. Explicit ranges
cannot be combined with `history_lines`. tmux clamps ranges to available data.

| Option | Native behavior |
| --- | --- |
| `join_lines` | Join wrapped rows and preserve trailing spaces (`-J`). |
| `preserve_spaces` | Preserve trailing spaces (`-N`). |
| `escape_sequences` | Include text/background attribute sequences (`-e`). |
| `escape_nonprintable` | Request native octal escaping (`-C`). |
| `alternate_screen` | Select tmux's alternate grid (`-a`); missing grid errors. |
| `trim_empty_cells` | Omit trailing empty cells (`-T`); tmux 3.4 or later. |
| `mode_screen` | Capture the active mode screen when available (`-M`); tmux 3.6 or later. |
| `ignore_missing_alternate` | With `alternate_screen`, return one newline if the grid is missing (`-q`). |
| `pending_escape_sequences` | Capture incomplete input held by tmux's parser (`-P`). |
| `hyperlinks_only` | List native hyperlink URLs instead of cell text (`-H`); tmux 3.7 or later. |
| `line_numbers` | Prefix rows with offsets relative to the visible screen (`-L`); tmux 3.7 or later. |
| `line_flags` | Prefix rows with native grid flags (`-F`); tmux 3.7 or later. |

`alternate_screen` cannot be combined with history, explicit ranges or
`mode_screen`. Unsupported version flags fail before dispatch.

`pending_escape_sequences` selects parser input instead of screen cells. Only
`escape_nonprintable` and process limits apply; other enabled capture options
are rejected. For example, a pending ESC followed by `[` produces `"\027[\n"`,
or `"\\033[\n"` with native octal escaping. The final newline belongs to tmux's
print output, not the pending input.

`hyperlinks_only` preserves tmux's URL listing, including native deduplication
and spacing. It does not guarantee an exhaustive URL inventory: tmux limits
the number of distinct links collected to the grid width. Screen/range
selection, joined rows and line metadata still apply. Attribute sequences,
octal escaping, preserved spaces and empty-cell trimming are rejected because
tmux ignores them in this mode. No matches produce one newline.

`line_numbers` and `line_flags` preserve native prefixes; with both enabled,
the number precedes the flags. Flags include `D`, `H`, `O`, `P`, `W` and `X`
for dead, hyperlink, output-start, prompt-start, wrapped and extended rows;
`-` means none. The result remains bytes, not parsed row records.

The executable [capture fixture](../tests/integration/capture.lua) demonstrates
the supported capture modes with output barriers and cleanup.

`capture_to_buffer(name, options)` writes directly to an explicit named buffer
and returns `true` when the native command completes. It accepts the same
capture options and [buffer creation names](buffers.md#storage-and-identity).
Nonempty capture replaces the current slot. Empty capture leaves an existing
buffer unchanged and does not create a missing buffer; this includes empty
pending input and quiet missing alternate grids.

Buffer capture stores native bytes without adding the print newline. A pending
ESC followed by `[` is stored as `"\027["`, whereas `capture()` returns
`"\027[\n"`. Another client may replace the buffer before a subsequent read.
Process output limits bound client output, not storage inside the tmux daemon;
use a capture range to limit the selected rows.

## Wait for text

`wait_for_text(text, options)` returns a Request that resolves with
`{ text, matched_at_entry }` once the visible screen contains `text`. The
search is a plain literal match, not a pattern. Wrapped rows are joined, so a
needle that straddles the pane width still matches. Only the visible screen is
read: rows that scrolled into history are not searched.

```lua
local found = must(pane:wait_for_text("build ok", { timeout = 5000 }):await())
```

Options:

- `interval`: milliseconds between reads, from 1; defaults to 100.
- `timeout`: milliseconds from the call. Expiry cancels the Request with
  `deadline_exceeded`.
- `deadline`: an absolute time on the runtime driver clock, as for any other
  Request.

With neither `timeout` nor `deadline` the wait runs until it matches, the pane
or server ends, or you call `:cancel(reason)`. An unknown option, empty or
non-string text, a non-plain options table, an `interval` below 1, or a
`timeout` or `deadline` more than 2,147,483,647 ms away returns
`invalid_argument`.

The first read comes before the first pause. Text already on screen resolves
at once with `matched_at_entry = true`. There is no count of new occurrences:
a command that printed before the wait started is already on screen. To wait
only for new output, print a token the command produces after it ran, such as
`printf '%s%s' NEE''DLE`. The shell echoes what you type, so a command that
contains the contiguous needle matches its own echo.

Each read is one tmux invocation, `capture-pane -p -J` followed by
`run-shell -C` with a marker that reports the pane id and whether the pane is
dead. It works on every supported release and never uses control mode. The
marker is a deliberate parse error, so the invocation exits 1 on success;
the wait ignores the exit code. Because the capture is an ordinary command,
the owner's `after-capture-pane` hook runs on every read, and on tmux 3.5a and
later a hook that prints joins the captured text. `run-shell -C` runs no hook
of its own.

The wait ends with one of these:

- Success: the result table.
- `deadline_exceeded` or the code passed to `:cancel(reason)`. Both carry the
  latest screen in `err.partial.text` when one was read, including when the
  deadline falls during a read.
- `pane_died` with `err.reason`: `pane_exited` when the program ended and the
  pane remains (`remain-on-exit`), `pane_gone` when the pane no longer exists,
  and `server_gone` when the tmux server ended, whether the daemon refused the
  connection or reported that it exited. `err.partial.text` holds the text
  seen so far. A match on the last read wins over the verdict.
- `output_limit` if a read exceeds the process output limit, surfaced as is.

After the server ends, the `Server` handle is stale and later calls return
`stale_generation`; connect again.

## Clear history

`clear_history()` clears the pane's retained history and exits all its modes,
including copy mode. It leaves visible screen cells intact. This is an
explicit shared-state mutation; cancellation of an unrelated Request never
calls it.

`clear_history({ clear_hyperlinks = true })` also clears hyperlink storage,
including links referenced by visible cells. This option requires tmux 3.4;
older versions return `unsupported` before changing history or mode state.
Success returns `true` under the same process, generation and error contracts
as the other Pane mutations.

## Text, keys and copy mode

`send_text(text)` sends bounded NUL-free UTF-8 with native `send-keys -l`.
It appends no Enter. A CR or LF already present in the argument remains
explicit caller input. It accepts at most 65,536 bytes; arbitrary binary
input is not part of this method.

`send_keys(names, options)` accepts a dense sequence of up to 1,024 names.
Supported names include Enter, Escape, Tab, BTab, Space, BSpace, arrows,
Home/End, Insert/Delete and their IC/DC aliases, PageUp/PageDown aliases,
F1–F12 and numeric keypad names. C-, M- and S- modifiers may prefix these
names or one printable ASCII character. Names are bounded at 64 bytes.
`repeat_count` is an integer from 1 to 1,000. Typos return `invalid_key`;
recognized deferred native categories such as mouse and user-defined keys
return `unsupported`. Unmodified literal characters belong in `send_text`.

Both methods preserve native mode and `synchronize-panes` behavior. Modes can
intercept input; synchronization can copy it to sibling panes. Dead or
input-disabled panes can accept a command without delivering input. Success
means tmux processed the operation, not that an application consumed it.
The library does not change these policies or infer shell-command success.

`copy_mode({ page_up = true })` explicitly enters copy mode. `copy_command`
sends one validated action through `send-keys -X`, with optional arguments
and `repeat_count`. Entry, navigation and cancellation affect shared pane UI.
No automatic cleanup exits a mode that another client may be using.

The initial action subset includes cursor/word/paragraph/page/history
navigation, selection marking, rectangle modes, refresh, search and jumps.
For example:

```lua
assert(pane:copy_mode():await())
assert(pane:copy_command("search-forward-text", { "ready" }):await())
assert(pane:copy_command("page-up", {}, { repeat_count = 2 }):await())
assert(pane:copy_command("cancel"):await())
```

Unknown actions or incorrect argument counts return `invalid_copy_command`.
Recognized deferred actions return `unsupported`, including copy/append,
clipboard/pipe actions and newer navigation commands. This subset does not
claim complete native copy-mode parity. Native command completion does not
guarantee a search match or cursor movement.

## Resize, kill and respawn

`resize({ width = N, height = N })` requests absolute dimensions;
`resize({ direction = "left", amount = N })` adjusts one direction. Forms are
mutually exclusive, dimensions/amount are 1–65,535 and adjustment defaults to
one. Native layout constraints can clamp the result, resize neighbors and
unzoom the window. Obtain a fresh snapshot when the resulting geometry matters.

`kill()` targets only the handle's pane ID. Native removal of the last pane
also destroys its window and can remove links or empty sessions elsewhere.
This is an explicit mutation; canceling another Request never calls it.

`respawn(options)` reuses the same pane identity. Without `kill = true`, an
active pane produces a native error. Omitted `argv`/`shell` reuses its previous
program; explicit launch options follow [creation](creation.md), including
absolute `cwd`, environment and separate literal argv/shell forms. Respawn
resets the terminal screen and mode. It can terminate the old program before
a later spawn failure, and tmux success does not prove executable startup.

These methods return `true` on successful native completion. They preserve
typed errors and partial command output on failure, with no automatic retry.
All options must be plain records. The nested `process` record accepts timeout,
deadline, output limit and drain/kill timeouts as described in
[commands](commands.md). Generation validation and runtime byte limits apply
before dispatch; native completion still waits for client exit and both EOFs.

## Selection, titles and swaps

`select()` changes the window's shared active pane. It unzooms when changing
panes unless `keep_zoom = true`. This explicit mutation affects other clients
and can run native focus and selection hooks.

`set_title(text)` sends format-literal UTF-8: `#{pane_id}` stays text. NUL,
ASCII control bytes and DEL are rejected before dispatch because native tmux
can silently ignore them. The limit is 65,536 bytes. Exact tmux 3.7 also
silently ignores empty titles, so that combination returns `unsupported`.
Other accepted releases allow clearing the title. tmux's native name cleaning
still applies; from 3.7, backslashes can be doubled. Completion does not
promise byte-exact storage for every accepted title.

`swap(other_pane, options)` swaps two explicit, different panes from the same
Server. Their stable IDs follow them into their new windows. The default uses
native `-d`: across windows, an active pane moved out is replaced at its old
position. Within one window, an active source pane can remain selected after
moving positions. Neither active identity nor active position is preserved in
every case. `select = true` uses native selection of the swapped panes.
`keep_zoom = true`
preserves each window's zoom. Swaps change inherited window options and the
pane relationships visible through every linked window.

These methods return `true` on native completion and share the process limits
above. Missing targets retain the native failure and its partial receipt.
See [topology operations](topology.md) for Session and Window mutations.
