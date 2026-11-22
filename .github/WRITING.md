# Writing

This file adds Lua, LuaCATS, StyLua, and `libtmux-lua` documentation rules to
the shared organization guide in
[`libtmux/.github/WRITING.md`][org-writing], which governs voice, plain
CommonMark, 80-column prose wrapping, `console` code blocks, slop prevention,
and commit and pull-request format. [CONTRIBUTING.md](CONTRIBUTING.md) governs
development workflow.

## Documentation and examples

State capabilities and limits precisely. Distinguish implemented behavior,
verified compatibility, and planned work; do not advertise a scaffold as an
installable library or describe a sibling port's feature as available in Lua.

Describe the caller's task before implementation details. State defaults,
errors (`value, err` returned from `:await()` versus raised argument errors),
side effects, runtime ownership, ordering, and concurrency when they affect the
contract. Do not repeat LuaCATS signatures or Lua basics.

Public modules and types carry LuaCATS annotations (`---@class`, `---@field`,
`---@param`, `---@return`, `---@generic`) checked by LuaLS 3.19.1
([`.luarc.json`](../.luarc.json)) at `--checklevel=Warning` and exported by
`scripts/docs/docs.lua`. Keep private helpers prefixed with `_` or under
`libtmux._internal` so they stay out of the exported API model.

Format Lua sources (`lua/`, `tests/`, `examples/`, `rockspecs/`, `scripts/`)
with StyLua (`stylua --syntax Lua51`, [`stylua.toml`](../stylua.toml)) and lint
them with Luacheck ([`.luacheckrc`](../.luacheckrc)). Keep Lua code lines in
Markdown fences and `examples/` at or under 80 columns.

Examples must match available APIs, start with their `require` calls, and own
their tmux server through `Runtime:start_server` and `OwnedServer:stop` rather
than shell `tmux` commands. Quote tested files under `examples/` instead of
maintaining a second copy. A performance claim needs a measurement and a
reproduction command.

Link to the source of a rule instead of copying it across documents. Keep
relative links and heading anchors valid when moving files or renaming
headings; `scripts/check/gates.lua` checks both.

## README shape

Both `README.md` and `lua/libtmux/README.md` follow [ADR-0005][adr-0005] and
are checked by `scripts/docs/readme_examples.lua`
([CONTRIBUTING.md](CONTRIBUTING.md#validation)):

- **Header:** the centered `<!-- libtmux-logo -->` block (`alt="libtmux for
  Lua"`), centered title, one sentence linking the API, and badges (`CI`,
  LuaRocks version, `libtmux.org`, and license). Link only pages returning 200.
- **Floors:** state actionable floors (`Lua 5.1 to 5.5 or LuaJIT`, `tmux 3.3a
  or newer`) and link the [compatibility guide](../docs/compatibility.md)
  instead of toolchain patch versions, the CI matrix, or kernel and libc
  details.
- **Task sections and API headings:** open with `## Quick start`. Each `##`
  heading names a task in the reader's words; each `###` heading links an API
  to its `libtmux.org` reference page, followed by a colon and its job in plain
  words.
- **Under a heading:** a line or two linking sibling APIs, the quoted example,
  what it prints, at most one short note, and a `More:` link to the guide.
- **Short prose, no walls:** keep paragraphs and list items at or under three
  lines (`PROSE_LIMIT = 240` rendered characters). Omit manual table-of-contents
  walls, feature inventories, inline BibTeX blocks, and meta prose explaining
  that examples are tested or how docs and gates run.
- **Tested examples:** mark every Lua fence with `<!-- example: path -->` (full
  file) or `<!-- excerpt: path -->` (consecutive lines). Later excerpts in a
  section may continue from the first example's runtime body.
- **Headline features:** show queries and filters, the query planner, command
  groups and batches, control-mode observation, and the Neovim runtime adapter,
  each with a linked API heading and tested example.
- **Packages and closing:** link each published rock's directory on `master`
  with an absolute URL, followed by a short description and reference,
  LuaRocks, and changelog links. Close with bold-lead bullets under
  `## What it leaves out` and `## Support and status`, then a compact links and
  `libtmux.org` family line.

## Comments and errors

Follow the comment discipline in [`libtmux/.github/WRITING.md`][org-writing]:
one or two lines for non-obvious invariants, tmux protocol or release
workarounds, and failure modes, with design rationale and rejected alternatives
kept in the commit message. Avoid bare commit hashes, line numbers, file
counts, and speculative TODOs.

Preserve LuaLS (`---@...`) and Luacheck (`-- luacheck: ...`) directives,
`<!-- example: ... -->` and `<!-- excerpt: ... -->` README markers,
`-- docs:begin` / `-- docs:end` region comments, and comments explaining code
that looks wrong but is required.

Error messages and `libtmux.Error` payloads name the failed operation and its
immediate cause with actionable context; omit empty phrases such as "an error
occurred".

## Markdown and code blocks

Follow the plain CommonMark, sentence-case heading, 80-column repository
wrapping, and single-command `$ `-prefixed `console` block rules (`\`
continuations, explanations in prose outside the fence, no GitHub-only alert
blocks, and no hard-wrapped issue or pull-request paragraphs) in
[`libtmux/.github/WRITING.md`][org-writing].

In READMEs, `scripts/docs/readme_examples.lua` verifies `console` commands
naming `examples/` or `rockspecs/` paths, compares `lua examples/api/<name>.lua`
output against `examples/api/manifest.json`, and checks printed
`libtmux._VERSION` output against `lua/libtmux/init.lua`.

## Commit messages

Follow `Scope(type[detail]): Description` (imperative subject at or below 50
characters, body lines wrapped at 72 characters, `why:` paragraph and `what:`
list separated by a blank line) in [`libtmux/.github/WRITING.md`][org-writing].

Typical types are `feat`, `fix`, `refactor`, `docs`, `chore`, `test`, `ci`, and
`ai`. Use a heredoc or message file to preserve real newlines when committing.
Keep each commit focused on one topic without pull-request numbers on ordinary
commit subjects or diff line and file counts.

## Changelogs and release notes

Record one observable change per bullet under `## Unreleased` in
[`CHANGES.md`](../CHANGES.md), grouped by affected component. Documentation,
CI, and release-tooling changes go there when preparing user-visible notes;
`scripts/release/main.lua changelogs` enforces the `# Changelog` /
``Notable changes to `libtmux`.`` header and `## Unreleased` section.

Name changed defaults and `0.1.N` incompatibilities with their migration in
the same bullet, and omit invisible refactors and descriptions of effort.
Release notes explain what an upgrader needs to know and any required action
without claiming unverified publication, compatibility, or gate results.

[adr-0005]: https://github.com/libtmux/central/blob/master/docs/decisions/0005-readme-shape.md
[org-writing]: https://github.com/libtmux/.github/blob/main/WRITING.md
