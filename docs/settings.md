# Options and hooks

Options and hooks return Requests. Session, Window and Pane handles use their
own storage scope.

- Server methods default to server options. Pass `scope = "global_session"` or
  `"global_window"` for global defaults; server hook methods require one of
  them. There is no global pane scope.
- A scope that conflicts with the handle or the built-in definition fails
  before I/O.

The [release catalog](options-reference.md) lists exact names, types and scopes
per tmux release. Names do not accept tmux's abbreviations, and an unknown
release fails with `unsupported_version`. User options take names such as
`@project_name`: ASCII letters, digits, underscores, dots and hyphens after
`@`. Broader names return `unsupported_name`.

## Read a setting

`get_option(name, options)` returns a record with `present`, `inherited`,
`type`, the requested `scope` and `target`. `list_options(options)` returns
records sorted by name.

- Scalar `value` keeps booleans, integers and bytes. Choices use canonical
  names. Keys, colours, styles and command options return tmux's canonical
  text, which reads never execute.
- Reads include inherited values. `inherit = false` inspects only the selected
  table. Local and inherited reads are separate observations, and tmux can
  change between them.
- `present = false` tells absence from an empty string, `false` or an empty
  array.
- Arrays return ordered `entries`, each with tmux's zero-based `index` and a
  `value`. Indices can have gaps. The `index` read option picks one slot after
  the whole array is read, so an absent slot (`present = false`, no entries)
  differs from an empty string.

## Change a setting

`set_option(name, value, options)` accepts:

- booleans for flags;
- integers within the release's range;
- exact choice names;
- NUL-free strings for string, key, colour and style options (tmux still
  checks their grammar);
- a program record for command values (see hooks below).

Structure, types, bounds and scopes are checked before I/O.

Arrays:

- `index` writes one slot.
- `{ entries = { { index = 0, value = "first" }, ... } }` replaces a sparse
  array. The library validates the whole input, clears the local array, then
  writes the slots in index order as one stop-on-error group. Empty entries
  make an explicit empty local array.
- A first indexed write creates a local array and does not copy inherited
  slots.
- Replacement is not atomic. tmux validation or hooks can fail after an earlier
  write, and the error does not say which slots completed. tmux can run hooks
  between the commands of a group.
- `append = true` concatenates a string, or an indexed string-array value.
  Whole-array append is unsupported, since tmux's separator splitting cannot
  keep arbitrary elements. Indexed colour or command append is rejected,
  because tmux replaces those values.

`unset_option(name, options)` removes a local override and restores
inheritance; for global defaults it restores tmux's default. `index` removes
one slot. The API never uses tmux's wider `-U`, which can also remove pane
overrides.

## Store and run hook programs

`set_hook(name, program, options)` stores a tmux command program. Give exactly
one of:

- `commands`: a dense list of argv lists. Each argument is encoded as literal
  tmux-parser data, in one command group. Commands keep their own format and
  shell semantics.
- `source`: tmux program text you write. It is not pre-parsed; tmux resolves
  aliases and grammar.

Neither is evaluated as Lua.

- `index` picks a built-in hook slot. Without one, setting a built-in hook
  replaces its array with one program. `append = true` adds a program at the
  first free slot; indexed append is rejected, since tmux replaces that slot.
- Invalid source can clear an existing array before tmux reports the error.
  Storing a hook is not transactional.

`get_hook` and `list_hooks` return the same presence and inheritance data as
options.

- Built-in hooks have sparse `entries` with `index` and canonical `source`.
  Canonical text may expand aliases or reorder flags, so it is not the
  original argv.
- Custom `@` hooks return one `source`. You can get one by name, but
  `list_hooks` omits them, since tmux cannot tell them from user options.
- `unset_hook` removes the hook or slot.

Session, Window and Pane handles have `run_hook(name, options)`, which uses
that live context's own hook lookup. Only process limits apply here. Success
means tmux completed its command; malformed custom source may still be ignored
without an error.

## Bounds and failures

- At most 1 MiB of encoded input and total output, 4,096 listed rows, and 512
  entries in an array replacement, within the aggregate argument and byte
  limits.
- A program takes at most 1,024 commands, 4,096 arguments and 1 MiB encoded.
- `process` takes deadline, timeout, output and cleanup limits. Environment,
  cwd and stdin overrides are rejected. Output keeps its bytes even in a C
  locale. No operation changes your environment.
- Cancelling a client does not undo a mutation tmux accepted. Errors tell
  `not_sent`, `unknown` and `completed` apart. A stale handle found after a
  completed command keeps `completed`; it does not imply a rollback.
