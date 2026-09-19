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
"misc fixes", or "address review". Do not add a pull-request number to the
subject or reproduce file and line counts from the diff.

## Changelogs and release notes

When a changelog exists, record one observable change per bullet under
`Unreleased`, grouped by affected component. Name changed defaults and
incompatibilities, with the migration in the same entry. Omit invisible
refactors and descriptions of effort.

Release notes explain what an upgrader needs to know and any required action.
Do not claim publication, compatibility, or passing checks without evidence.
