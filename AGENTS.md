# Agent instructions

This repository contains the libtmux Lua foundation: queries, explicit async
requests, process execution, snapshots and private control observation.
Domain coverage and the MCP/workspace products remain under development.

Follow the existing project conventions and keep changes scoped to the
requested work. Prefer `rg`, `ag`, and `fd` for discovery.

## Change discipline

- Make the smallest coherent change that solves the verified problem. Keep
  unrelated cleanup out of it.
- Reuse an existing file, helper, API, or test before adding a new one.
- Keep new APIs private until a caller outside the library needs them.
- Add a file for a distinct responsibility, independent reuse, or to split an
  oversized module. Avoid single-use wrappers and one-line re-exports.
- Add tests for critical behavior. Show that a regression test fails for the
  intended reason before relying on its passing result.
- Verify claims against this repository. A sibling port's implementation,
  toolchain, or test result does not establish Lua support.

## Which policy applies

- Setup, validation, tmux isolation, and pull requests:
  [.github/CONTRIBUTING.md](.github/CONTRIBUTING.md).
- Documentation, user-facing text, comments, and commit messages:
  [.github/WRITING.md](.github/WRITING.md).

Each guide is the single home for its subject. `CLAUDE.md` is a relative
symlink to this file so both entry points use the same instructions.

## Merging pull requests

Use a descriptive subject ending in the actual PR number: `Title (#PRNUM)`.
Follow it with `what:` and `why:` sections describing the change and its
reason. Never use the default `Merge pull request ... from ...` subject.

Pass the subject and body explicitly to the merge command. Read back the
resulting commit message before starting another merge.
