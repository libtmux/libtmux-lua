# Pane operations

Pane handles run explicit asynchronous operations. Each method returns a
Request: await it inside a runtime task or pass a completion callback. Get a
handle from a creation receipt or `server:handle`; snapshot records stay plain
data.

```lua
local capture = assert(pane:capture({ history_lines = 20 }):await())
local text = assert(capture:text())
assert(pane:send_text("printf '%s\\n' ready"):await())
assert(pane:send_keys({ "Enter" }):await())
```

## Capture and text

`capture()` returns `{ bytes, target }` with a `text()` method.

- `bytes` is tmux's stdout as is, terminal newline and invalid UTF-8 included.
- `text()` returns the same string when it is valid UTF-8, and otherwise
  `nil, err` with `invalid_utf8`. It does no replacement, trimming or newline
  conversion, and no tmux I/O.
- Capture reads rendered screen and history cells. It cannot recover the
  original PTY byte stream, prove a program finished, or hand off in order to
  an observation. It never enters, leaves or moves in copy mode.

The range:

- By default, the visible screen.
- `history_lines = N` adds up to N history rows, at most 1,000,000.
- `start_line` and `end_line` take integer row offsets or `"-"`. Zero is the
  first visible row and negative offsets reach into history. `start_line = "-"`
  starts at all retained history; `end_line = "-"` ends at the visible
  screen's end.
- An explicit range cannot combine with `history_lines`. tmux clamps a range
  to the data it has.

| Option | Native behavior |
| --- | --- |
| `join_lines` | Join wrapped rows and preserve trailing spaces (`-J`). |
| `preserve_spaces` | Preserve trailing spaces (`-N`). |
| `escape_sequences` | Include text and background attribute sequences (`-e`). |
| `escape_nonprintable` | Request native octal escaping (`-C`). |
| `alternate_screen` | Select tmux's alternate grid (`-a`); a missing grid errors. |
| `trim_empty_cells` | Omit trailing empty cells (`-T`); tmux 3.4 or later. |
| `mode_screen` | Capture the active mode screen when available (`-M`); tmux 3.6 or later. |
| `ignore_missing_alternate` | With `alternate_screen`, return one newline if the grid is missing (`-q`). |
| `pending_escape_sequences` | Capture incomplete input held by tmux's parser (`-P`). |
| `hyperlinks_only` | List native hyperlink URLs instead of cell text (`-H`); tmux 3.7 or later. |
| `line_numbers` | Prefix rows with offsets relative to the visible screen (`-L`); tmux 3.7 or later. |
| `line_flags` | Prefix rows with native grid flags (`-F`); tmux 3.7 or later. |

- `alternate_screen` cannot combine with history, an explicit range or
  `mode_screen`.
- A flag the tmux version lacks fails before anything is sent.
- `pending_escape_sequences` reads parser input, not cells. Only
  `escape_nonprintable` and the process limits apply; other capture options
  are rejected. A pending ESC then `[` returns `"\027[\n"`, or `"\\033[\n"`
  with octal escaping. The last newline is tmux's print newline.
- `hyperlinks_only` keeps tmux's URL listing, including its deduplication and
  spacing. tmux collects at most as many distinct links as the grid is wide,
  so the list may not be complete. Range selection, joined rows and line
  metadata still apply. Attribute sequences, octal escaping, preserved spaces
  and empty-cell trimming are rejected. No match returns one newline.
- `line_numbers` and `line_flags` keep tmux's prefixes, number first. Flags are
  `D` dead, `H` hyperlink, `O` output start, `P` prompt start, `W` wrapped and
  `X` extended; `-` means none. The result stays bytes, not parsed rows.

`capture_to_buffer(name, options)` writes to a named buffer and returns `true`
when tmux completes. It takes the same options and the
[buffer names](buffers.md#storage-and-identity) creation accepts.

- A nonempty capture replaces the slot. An empty one leaves an existing buffer
  alone and creates none, including for empty pending input and a quietly
  missing alternate grid.
- It stores the native bytes without the print newline: a pending ESC then `[`
  is stored as `"\027["`, where `capture()` returns `"\027[\n"`.
- Another client may replace the buffer before you read it.
- Process output limits bound client output, not storage in the daemon. Use a
  range to limit the rows.

## Wait for text

`wait_for_text(text, options)` returns a Request that resolves with
`{ text, matched_at_entry }` once the visible screen contains `text`.

- The match is a plain literal, not a pattern.
- Wrapped rows are joined, so a needle that straddles the pane width matches.
- Only the visible screen is read. Rows scrolled into history are not.

```lua
local found = must(pane:wait_for_text("build ok", { timeout = 5000 }):await())
```

Options:

- `interval`: milliseconds between reads, from 1; default 100.
- `timeout`: milliseconds from the call. Expiry cancels the Request with
  `deadline_exceeded`.
- `deadline`: an absolute time on the runtime driver's clock.

Without `timeout` or `deadline`, the wait runs until it matches, the pane or
server ends, or you call `:cancel(reason)`. An unknown option, empty or
non-string text, a non-plain options table, an `interval` below 1, or a
`timeout` or `deadline` more than 2,147,483,647 ms away returns
`invalid_argument`.

What matches:

- The first read comes before the first pause. Text already on screen resolves
  at once with `matched_at_entry = true`.
- There is no count of new occurrences. To wait only for new output, print a
  token the command produces after it runs, such as `printf '%s%s' NEE''DLE`.
  The shell echoes what you type, so a command containing the contiguous
  needle matches its own echo.

How it reads:

- Each read is one tmux invocation: `capture-pane -p -J`, then `run-shell -C`
  with a marker that reports the pane ID and whether the pane is dead. It
  works on every supported release and never uses control mode.
- The marker is a deliberate parse error, so the invocation exits 1 on
  success. The wait ignores the exit code.
- The capture is an ordinary command, so the owner's `after-capture-pane` hook
  runs on every read. On tmux 3.5a and later, a hook that prints joins the
  captured text. `run-shell -C` runs no hook of its own.

How it ends:

- **Success:** the result table.
- **`deadline_exceeded`**, or the code passed to `:cancel(reason)`. Both carry
  the latest screen in `err.partial.text` when one was read, including when
  the deadline falls mid-read.
- **`pane_died`**, with `err.reason`: `pane_exited` when the program ended and
  the pane stays (`remain-on-exit`), `pane_gone` when the pane no longer
  exists, and `server_gone` when the server ended. `err.partial.text` holds
  the text seen so far. A match on the last read wins over the verdict.
- **`output_limit`** when a read exceeds the process output limit.

After the server ends, the `Server` handle is stale and later calls return
`stale_generation`. Connect again.

## Clear history

`clear_history()` clears the pane's retained history and exits all its modes,
copy mode included. Visible cells stay. It is an explicit mutation of shared
state; cancelling an unrelated Request never calls it.

`clear_history({ clear_hyperlinks = true })` also clears hyperlink storage,
including links the visible cells reference. It needs tmux 3.4; older versions
return `unsupported` before changing anything. Success returns `true`, with the
same process, generation and error rules as the other pane mutations.

## Text, keys and copy mode

`send_text(text)` sends NUL-free UTF-8 with `send-keys -l`.

- It adds no Enter. A CR or LF already in the argument is sent as written.
- It accepts at most 65,536 bytes. It is not a binary-input method.

`send_keys(names, options)` takes a dense list of up to 1,024 names, each at
most 64 bytes.

- Names: Enter, Escape, Tab, BTab, Space, BSpace, arrows, Home and End, Insert
  and Delete with their IC and DC aliases, PageUp and PageDown aliases,
  F1 to F12 and the numeric keypad names.
- `C-`, `M-` and `S-` modifiers may prefix a name or one printable ASCII
  character.
- `repeat_count` is an integer from 1 to 1,000.
- A typo returns `invalid_key`. A recognized native category the library does
  not cover, such as mouse or user-defined keys, returns `unsupported`.
  Unmodified literal characters belong in `send_text`.

Both follow tmux's mode and `synchronize-panes` behavior: a mode can intercept
input, and synchronization can copy it to sibling panes. A dead or
input-disabled pane can accept a command without delivering input. Success
means tmux processed the operation, not that a program read the input. The
library changes none of these policies and does not infer shell success.

`copy_mode({ page_up = true })` enters copy mode. `copy_command` sends one
validated action through `send-keys -X`, with optional arguments and
`repeat_count`. Entering, moving and cancelling affect the shared pane UI, and
nothing exits a mode another client may be using.

```lua
assert(pane:copy_mode():await())
assert(pane:copy_command("search-forward-text", { "ready" }):await())
assert(pane:copy_command("page-up", {}, { repeat_count = 2 }):await())
assert(pane:copy_command("cancel"):await())
```

- Supported actions cover cursor, word, paragraph, page and history movement,
  selection marks, rectangle modes, refresh, search and jumps.
- An unknown action or a wrong argument count returns `invalid_copy_command`.
- Copy and append, clipboard and pipe actions, and newer navigation commands
  return `unsupported`. The subset is not the whole copy mode.
- tmux completing a search does not mean it found a match or moved the cursor.

## Resize, kill and respawn

- `resize({ width = N, height = N })` asks for absolute dimensions.
  `resize({ direction = "left", amount = N })` adjusts one direction, by one
  cell by default. The two forms are exclusive, and values run from 1 to
  65,535. Layout constraints can clamp the result, resize neighbors and unzoom
  the window. Take a fresh snapshot when the geometry matters.
- `kill()` removes only the handle's pane. Removing a window's last pane also
  destroys the window, and can remove links or empty sessions elsewhere.
  Cancelling another Request never calls it.
- `respawn(options)` reuses the pane identity. An active pane gives tmux's
  error unless `kill = true`. Without `argv` or `shell` it reuses the previous
  program; launch options follow [creation](creation.md). Respawn resets the
  screen and mode, and can end the old program before a spawn failure. tmux
  success does not prove the program started.

These return `true` on success, and keep typed errors and partial output on
failure, with no automatic retry. Options must be plain records. The nested
`process` record takes the timeouts and output limit in
[commands](commands.md). Generation and byte limits are checked before
dispatch, and completion waits for the client to exit and both pipes to close.

## Selection, titles and swaps

- `select()` changes the window's active pane for every client. It unzooms
  unless `keep_zoom = true`, and can run focus and selection hooks.
- `set_title(text)` sends UTF-8 as literal text: `#{pane_id}` stays text. NUL,
  control bytes and DEL are rejected because tmux can silently ignore them;
  the limit is 65,536 bytes. tmux 3.7 ignores an empty title, so that case
  returns `unsupported` there. tmux still cleans names, and from 3.7 it can
  double backslashes, so storage is not always byte-exact.
- `swap(other_pane, options)` swaps two different panes of one Server. Their
  IDs follow them into the new windows. The default is native `-d`: across
  windows, an active pane moved out is replaced at its old position, and
  within one window an active source pane can stay selected after moving.
  Neither the active pane nor its position is kept in every case.
  `select = true` selects the swapped panes. `keep_zoom = true` keeps each
  window's zoom. A swap changes inherited window options and the pane
  relationships every linked window shows.

These return `true` on success and share the process limits above. A missing
target keeps tmux's failure and the partial receipt. Session and window
changes: [topology operations](topology.md).
