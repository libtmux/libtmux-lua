# Options and hooks

Options and hooks return Requests through the process lane. Session, Window
and Pane handles select their own storage scope. Server methods default to
server options; use `scope = "global_session"` or `"global_window"` for global
defaults. Server hook methods require one of those explicit global scopes.
There is no global pane scope. A scope that conflicts with the handle or
built-in definition fails before I/O.

The [release catalog](options-reference.md) records exact names, types and
scopes for supported tmux releases. Names do not accept tmux's abbreviations.
Unknown releases fail with `unsupported_version`. User options support names
such as `@project_name`, with ASCII letters, digits, underscores, dots and
hyphens after `@`; broader native names return `unsupported_name`.

## Read a setting

`get_option(name, options)` returns a record with `present`, `inherited`,
`type`, requested `scope` and `target`. Scalar `value` preserves booleans,
integers and bytes. Choice values use their canonical names. Keys, colours,
styles and command options return native canonical text. Reads never execute
that text. `list_options(options)` returns records sorted by name.

Reads include inherited values by default. Set `inherit = false` to inspect
only the selected table. `present = false` distinguishes absence from an
empty string, `false` or an explicit empty array. Local and inherited reads
are separate observations; concurrent changes can occur between them.

Arrays return ordered `entries`, each with a native zero-based `index` and
`value`. Indices may have gaps. An `index` read option selects a slot after
reading the complete array, preserving the distinction between an absent
slot and an empty string. An absent slot has `present = false` and no entries.

## Change a setting

`set_option(name, value, options)` accepts booleans for flags, integers within
the release-specific range, exact choice names and NUL-free strings for
string, key, colour and style options. Native key, colour and style grammar
is still checked by tmux. Command values use the program record described
below. Input structure, types, bounds and scopes are checked before I/O.

Use `index` to write one array slot. To replace a sparse array, supply
`{ entries = { { index = 0, value = "first" }, ... } }`. The library copies and
validates the whole input, clears the local array, then writes slots in index
order in one stop-on-error command group. Empty entries create an explicit
empty local array. A first local indexed write also creates a local array;
it does not copy inherited slots.

Replacement is not atomic. Native value validation or hooks may fail after
an earlier write; the returned error preserves the process result without
claiming which slots completed. tmux can run hooks between group commands.

`append = true` concatenates a scalar string or an indexed string-array value.
Whole-array append is unsupported: native separator splitting cannot preserve
arbitrary string elements. Indexed colour or command append is rejected
because tmux replaces those values instead of appending.

`unset_option(name, options)` removes a local override, restoring inheritance.
For global defaults it restores tmux's default. An optional `index` removes
one array slot. The API never uses tmux's wider `-U` operation, which can also
remove pane overrides.

## Store and run hook programs

`set_hook(name, program, options)` stores a tmux command program. Supply exactly
one of `commands`, a dense sequence of argv sequences, or `source`, explicit
tmux program text. `commands` encodes each argument as literal tmux-parser
data in one command group. Commands retain their own native format and shell
semantics. `source` is not pre-parsed; tmux aliases and grammar are resolved
by tmux. Neither form is evaluated as Lua.

Use `index` for a built-in hook slot. Without an index, setting a built-in hook
replaces its array with one program. `append = true` adds a program at the first
free native slot. Indexed append is rejected because native command-array
append replaces that slot. Invalid native source can clear an existing array
before tmux reports failure; storing a hook is not transactional.

`get_hook` and `list_hooks` return the same presence and inheritance metadata
as options. Built-in hooks have sparse `entries` containing `index` and
canonical program `source`. Canonical text may expand aliases or reorder
flags; it does not reconstruct the original argv. Custom `@` hooks return a
single `source`. They can be retrieved by name but are omitted from
`list_hooks`, since tmux cannot distinguish them from ordinary user options.
`unset_hook` removes the selected hook or slot.

Session, Window and Pane handles offer `run_hook(name, options)`. Execution
uses that live context's native hook lookup. Only process limits are accepted;
storage scopes, indices, append and replacement source do not select a hook
for execution. Custom hook execution requires tmux 3.3 or newer. A successful
process result means tmux completed its command; malformed custom source may
still be ignored by tmux without an error.

## Bounds and failures

Settings use at most one MiB of encoded input and aggregate native output.
Listings accept at most 4096 rows. Array replacement accepts at most 512
entries and remains subject to the aggregate argv and byte limits. Programs
accept at most 1024 commands, 4096 arguments and one MiB after encoding.

`process` accepts deadline, timeout, output and cleanup limits. Caller-provided
process environment, cwd and stdin are rejected. Output preserves bytes even
when the caller uses a C locale. No operation changes the caller's environment.

Canceling a client does not undo accepted tmux mutations. Errors distinguish
`not_sent`, `unknown` and `completed` effects. A stale handle detected after a
completed command retains that completed effect; it does not imply rollback.
