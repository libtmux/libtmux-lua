# Contributing

This repository contains the setup for a Lua port of libtmux. There is no
library implementation, package manifest, test suite, or CI workflow yet.

[AGENTS.md](../AGENTS.md) governs scope and change discipline.
[WRITING.md](WRITING.md) governs prose and commit messages.

## Environment

[.tool-versions](../.tool-versions) pins the development interpreter. The pin
does not define a supported Lua range or promise LuaJIT compatibility.

Install the pinned interpreter with mise:

```console
$ mise install
```

Check the selected interpreter:

```console
$ mise exec -- lua -v
```

## Validation

No build, test, lint, or package commands are defined yet. For scaffold
changes, review the complete diff, check relative Markdown links, and confirm
that `CLAUDE.md` remains a symlink to `AGENTS.md`.

Check whitespace in unstaged changes:

```console
$ git diff --check
```

Check whitespace in staged changes:

```console
$ git diff --cached --check
```

Report which checks ran and which are unavailable. An absent or skipped test
suite is not a passing suite. Document runnable checks here when they exist.

### Test loops

Measure the whole command, including startup and setup. Libraries should aim
for the target times below.

| Loop | Budget | Target | Scope |
| --- | --- | --- | --- |
| Inner | < 5 seconds | < 2 seconds | Tests for changed code, after each edit. |
| Mid | < 30 seconds | < 10 seconds | Unit tests, lint, generated-file checks. |
| Outer | < 5 minutes | < 60 seconds | Builds, type checks, and full matrices. |

Run the mid loop after each change and before handoff, and the outer loop
before a commit or pull request.

- Keep network access, installs, production builds, browser launches, sleeps,
  and broad corpus scans out of the inner and mid loops.
- Treat a timeout or wait over one second as a structural bug. Use events or
  subscriptions and fix the cause instead of adding sleeps.
- Tag slow tests with a one-line reason and run them in the outer loop.
- If a loop exceeds its budget, remove redundant setup and slow paths before
  adding more tests. Do not raise the budget.
- Keep benchmarks separate: under ten minutes per run and one hour per sweep.

## tmux isolation

Any test or probe that starts tmux must use an explicit socket in a unique
temporary directory named for `libtmux-lua`. Clear inherited `TMUX` and
`TMUX_PANE` values in the child environment. Never use the default server.

Clean up only the server and files owned by that run, including on failure.
Do not stop servers or remove directories belonging to another port or to
the developer's sessions. Use real tmux to verify tmux behavior once the
library and its integration tests exist.

## Pull requests

Keep one subject per pull request and one logical change per commit. Describe
the resulting behavior, why it matters, and the checks actually run. Include
elapsed time and any unverified compatibility claims. Update documentation
when observable behavior changes.

## Repository metadata

[repository.json](repository.json) records the desired visibility, default
branch, description, topics, and issue labels for both GitHub repositories.
GitHub does not apply this file automatically; apply metadata changes through
the GitHub CLI or API and verify both repositories afterward.

- `origin`: [libtmux/libtmux-lua](https://github.com/libtmux/libtmux-lua).
- `tony`: [tony/libtmux-lua](https://github.com/tony/libtmux-lua).

Both repositories are private and independent, with `master` as the default
branch. The personal repository is not a GitHub fork.
