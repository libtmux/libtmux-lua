# Writing

This file governs documentation, user-facing text, comments, Markdown, and
commit messages. [CONTRIBUTING.md](CONTRIBUTING.md) governs development
workflow.

## Voice

Lead with the conclusion or observable behavior, then give the evidence the
reader needs. Use present tense, active voice, and concrete verbs. Assume the
reader has no conversation history; explain what a ticket or codename means.

State capabilities and limits precisely. Distinguish implemented behavior,
verified compatibility, and planned work. Do not advertise a scaffold as an
installable library or describe a sibling port's feature as available here.

Cut promotional claims, conversational filler, AI signatures, and tool
metadata. Use no emoji in commits, issues, pull requests, comments, or code.
Keep personal information and machine-specific paths out of published text.

## Documentation and examples

Describe the caller's task before implementation details. State defaults,
errors, side effects, ownership, ordering, and concurrency when they affect
the contract. Do not repeat signatures or language basics.

Examples must match available APIs and include required setup and cleanup.
When executable examples exist, prefer quoting their tested source over
maintaining a second copy. A performance claim needs a measurement and a
reproduction command.

Link to the source of a rule instead of copying it across documents. Keep
relative links valid when moving files or renaming headings.

## Comments and errors

Keep comments that explain a non-obvious invariant, protocol constraint,
compatibility workaround, or failure mode. Aim for one or two lines. Preserve
tool directives and comments that explain code which appears wrong but is
required.

Remove comments that translate the next line into English, repeat names or
defaults, or narrate edit history. Put design rationale and rejected
alternatives in the commit message. Avoid bare commit hashes, line numbers,
file counts, and speculative TODOs.

Error messages name the failed operation and its immediate cause. Add context
that helps the caller act; omit empty phrases such as "an error occurred".

## Markdown and code blocks

Use plain CommonMark with sentence-case headings. Put a blank line before
lists and code blocks. Wrap repository prose at 80 columns, except for URLs
and other tokens that cannot be split. Do not hard-wrap issue or pull-request
body paragraphs.

### Code blocks

A shell code block is one paste-and-run action:

- Put one command in each block. An explicit `&&`, `;`, or `\` continuation
  counts as one command.
- Put explanations in prose above the block, not comments inside it.
- Mark shell commands as `console` and prefix them with `$ `.
- Split long commands with `\`, one flag or flag-value pair per continuation
  line.

Show recent commits:

```console
$ git log \
    --max-count=10 \
    --graph \
    --oneline
```

## Examples

<!-- shared:examples -->

An example is code written for a reader: a program under `examples/`, code in
a doc comment or docstring, and every fenced block in a README or docs page.
Shell blocks also follow [Code blocks](#code-blocks).

The text between the shared markers is the same in every libtmux port.
Change it in all of them together.

### Width

- **Examples stay within 80 columns.** They render in fixed-width boxes that
  scroll sideways, and 80 columns fits a libtmux.org code block in a
  laptop-width window. Comments inside examples wrap at 80 too.
- **The width check enforces it.** It reads the tracked files that
  `.github/example-width.toml` names and fails on a wider line. It measures
  the whole source line, so code in a doc comment counts its indent and
  comment marker. It skips output (a fence tagged `text`, and what a
  `console` block prints), hidden setup lines, and a line that is only a URL;
  an untagged fence counts as code.
- **A line that must stay wider is listed there with its reason.** An entry
  that no longer matches a line fails the check, so no stale entry stays.
- **The formatter's width is the hard limit for all other source.** Example
  directories set their formatter to 80 where the formatter takes a width.

### Reaching 80

- **Change the code, not the line breaks.** A formatter rejoins any line that
  fits its width. Name a sub-expression, use a short example name, hide setup
  the reader does not need, or print less.
- **Break at the outermost level when a break is still needed:** after an
  opening parenthesis with one argument per line, one call per line in a
  chain, one field per line in a literal.
- **Put a comment on its own line above the code it explains.** Never trail
  one after code in an example, unless the repository's example runner reads
  it there, as with an assertion marker.
- **Break a long string at a word boundary,** never inside a tmux format
  (`#{...}`) or an escape sequence; the joined text stays the same.
- **Continue a long command in a `console` block the way its shell does:**
  `\` after a `$ ` prompt, a backtick after `PS> `, one flag per continuation
  line.

### What never breaks

- **Output a test compares.** Wrapping it changes what the test expects.
- **A block copied from a source file.** Fix the width in the source and run
  the sync command; never edit the copy.
- **Marker lines and URLs,** which tools and readers take whole.

<!-- /shared:examples -->

### In this repository

- **Hard limit:** StyLua with Lua51 syntax, configured by `stylua.toml` and
  its `column_width` key; `examples/stylua.toml` sets 80 for the example
  directories. The width check is `python3 scripts/check_example_width.py`,
  run by the `mid` gate. It reads `.github/example-width.toml` and checks
  that `examples/stylua.toml` differs from the root config only in
  `column_width`.
- **Not formatted:** StyLua does not wrap comments and never reads Markdown.
  Hold comments and the `lua` fences in the README and `docs/` to the
  example width by hand; the width check fails on a wider line.
- **Runs, compiles, exempt:** a program listed in `examples/api/manifest.json`
  runs through `scripts/api_examples.py` and its output is compared.
  Programs the package gate lists run there. Every `lua` fence in the README
  and `docs/` carries `<!-- lua: run | fragment | compile-only: reason -->`
  above it and an unmarked fence fails. `run` is a whole program,
  `fragment` runs inside a live server with `server`, `session`, `window`,
  `pane`, `snapshot` and `must` bound, and `compile-only` states why it
  cannot run.
- **Compared output and copied blocks:** never wrap the `stdout` in
  `manifest.json` or a line a test matches. The README snapshot fence copies
  `examples/snapshot.lua` and the quickstart region between `docs:begin` and
  `docs:end` is quoted by the documentation site. Neither has a sync tool;
  edit the source file, then copy it.

Bad, over 80:

```lua
local split = must(editor.pane:split({ direction = "right", percent = 40 }):await())
```

Good, a named option table:

```lua
local right = { direction = "right", percent = 40 }
local split = must(editor.pane:split(right):await())
```

## Commit messages

Use `Scope(type[detail]): Description`. The detail is optional. Name the
affected component, use an imperative verb, and keep the subject at or below
50 characters. Typical types are `feat`, `fix`, `refactor`, `docs`, `chore`,
`test`, and `ai`.

For a nontrivial change or one spanning files, include a `why:` paragraph and
a `what:` list, separated by a blank line. Wrap body lines at 72 characters;
URLs, paths, and identifiers may exceed the limit when they cannot be split.
Use a heredoc or message file to preserve real newlines when committing.

Keep each commit focused. Describe the concrete change rather than "wip",
"misc fixes", or "address review". Do not add a pull-request number to an
ordinary commit subject or reproduce file and line counts from the diff.

## Changelogs and release notes

When a changelog exists, record one observable change per bullet under
`Unreleased`, grouped by affected component. Name changed defaults and
incompatibilities, with the migration in the same entry. Omit invisible
refactors and descriptions of effort.

Release notes explain what an upgrader needs to know and any required action.
Do not claim publication, compatibility, or passing checks without evidence.
