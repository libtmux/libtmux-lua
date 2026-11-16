# Scripts

This policy covers the support scripts in this repository: files under
`scripts/`, CI helpers, generators and checkers. It applies the libtmux
decision in [libtmux/docs#323](https://github.com/libtmux/docs/pull/323).

## Keep a script only for a current use

A script stays when this project runs it today: a CI job, a release step, a
code generator, a documentation check, or a maintainer task named in
[CONTRIBUTING.md](CONTRIBUTING.md).

- Parity with Python libtmux or tmuxp is not a use. Delete comparison
  harnesses, oracles, ledgers and generated fixtures, and the CI steps that
  install them.
- A shell step that creates, prepares or stops tmux for an example or test
  means the library lacks an operation. File an issue for the operation and
  remove the step when it lands.
- Delete scripts nothing calls.
- Tooling several ports share lives once, as a shared workflow or action, not
  as a vendored copy.

## Language

Scripts are Lua, run with LuaJIT, the same interpreter CI uses for the
library. Do not add shell or Python script files.

## Layout and checks

- A script with tests lives in `scripts/<name>/`, with a `README.md` (what it
  does, who runs it, how) and `tests/`. A short single-purpose script may be
  one file with a usage header.
- Scripts pass the same formatter, linter, type checker and test runner as the
  library, in CI.
- Use current language and tool idioms; no shims below the project's floor.
- Before a new or rewritten script merges, a reviewer who did not write it
  checks it against [WRITING.md](WRITING.md) and
  [no-ai-slop](https://github.com/petergyang/no-ai-slop).

## What stays

- GitHub Actions `run:` lines that call one command.
- A capability Lua lacks comes from a test-only Lua dependency, not from a
  second language.
- Test data that is not a comparison, such as workspace files a loader reads.
- `scripts/support/shell.lua`, which runs a program through `io.popen` with every
  argument quoted. The bootstrap runs on the Lua that mise installs, and that
  Lua has neither luv nor FFI, so `support.proc` cannot run there. Measured on
  Lua 5.5.1: `mise exec -- lua -e 'print(pcall(require, "luv"))'` and the same
  with `"ffi"` both print `false` and a module-not-found message. The bootstrap
  installs luv, so it cannot use it first. A script that runs under LuaJIT with
  luv uses `support.proc`; the scripts that still call `shell.lua` after the
  bootstrap are listed on libtmux-lua#113 to move.
