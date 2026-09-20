# Contributing

This repository contains the Lua query, transport and package foundation for
libtmux. Domain coverage and consumer features remain under development.
Complete product compatibility remains unverified.

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

Development scripts require Python 3.12 or newer; the development pin supplies
3.14.6. LuaRocks 3.13.0, a C compiler, make, CMake and StyLua 2.4.0 are build
prerequisites. Bootstrap runs outside all test loops and may use the network.

Build the floor interpreter and the Lua 5.4.9 lint-tool interpreter:

```console
$ mise exec -- python scripts/bootstrap_runtimes.py 5.1.5 5.4.9
```

Install unit-test and standalone runtime dependencies for the development Lua:

```console
$ mise exec -- python scripts/bootstrap.py dev live
```

Install lint dependencies under the separate tool interpreter. Luacheck 1.2.0
assigns to a loop variable, which Lua 5.5 rejects; this tool constraint does
not change the library's runtime targets.

```console
$ mise exec -- python scripts/bootstrap.py lint \
    --lua=.cache/toolchains/lua-5.4.9/bin/lua
```

Install native prerequisites and LuaLS 3.19.1 into the ignored local cache:

```console
$ mise exec -- python scripts/bootstrap_native.py yaml luals
```

Install consumer codecs. LibYAML 0.2.5 is built statically in that cache; the
external package check verifies the resulting native binding actually loads.

```console
$ mise exec -- python scripts/bootstrap.py consumers \
    --yaml-dir=.cache/libyaml
```

Bootstrap additional interpreters' unit dependencies with the same `--lua`
option. C modules must be built separately for each interpreter ABI.

Build the accepted standalone LuaJIT revision:

```console
$ mise exec -- python scripts/bootstrap_runtimes.py luajit
```

Install its independent unit and live dependencies:

```console
$ mise exec -- python scripts/bootstrap.py dev live \
    --lua=.cache/toolchains/luajit-2.1/bin/luajit
```

The scripts keep LuaJIT and PUC Lua 5.1 rocks in separate cache trees, even
though both report the Lua 5.1 ABI. LuaJIT uses the same absolute prefix during
build and installation, following its [installation guide](https://luajit.org/install.html).

Install the accepted Neovim hosts into separate local cache directories:

```console
$ mise exec -- python scripts/bootstrap_hosts.py 0.10.0 0.10.4 0.11.7 0.12.5
```

The host bootstrap supports Linux x86_64. It verifies pinned official archive
hashes, each executable and its embedded runtime. Existing installations stay
unchanged. `--check` verifies the cached hosts without network access.

## Validation

The runner discovers unit suites and reports whole-process child timings.
Time the invoking command too when recording gate evidence. Test gates are
offline and fail on missing prerequisites; they never install dependencies.

Run a focused inner suite:

```console
$ mise exec -- python scripts/check.py unit query
```

Run unit suites, Lua51 formatting, lint, generated-field drift, links and
whitespace checks:

```console
$ mise exec -- python scripts/check.py mid
```

Run the current outer gates: mid checks, owned-tmux integration, independent
artifact builds/imports, LuaLS diagnostics and actual editor completion:

```console
$ mise exec -- python scripts/check.py outer
```

Integration includes real luv and Neovim loop ownership, process cancellation,
post-exit pipe draining and metadata byte round-trips. These use the selected
Lua interpreter and its own luv ABI; Neovim uses its embedded runtime.

The package gate builds development rocks and installs each into its own
temporary prefix. Consumer prerequisites are packed from the bootstrap cache;
network servers and ambient Lua paths are disabled. Imports and the native
query example execute outside the checkout. Missing dependencies fail locally.
All three packages use the [MIT license](../LICENSE). The gate verifies each
installed rockspec and license against the source files. No release artifacts
are published.

Select a specific tmux binary through `TMUX_BIN`. Run floor/current versions
separately and record their actual identities. The fixture runner handles
SIGINT/SIGTERM by unwinding owned resources before exit. Linux forced cleanup
uses owned pidfds; macOS cleanup remains an explicit unverified gate.

Select the floor Lua and a cached Neovim explicitly:

```console
$ mise exec -- python scripts/check.py integration \
    --lua=.cache/toolchains/lua-5.1.5/bin/lua \
    --nvim=.cache/toolchains/nvim-0.10.0/bin/nvim
```

Set `TMUX_BIN` to the intended floor or current executable for each run.
Local WSL2 checks are recorded separately from hosted Linux and macOS.
The official Neovim 0.10.0 archive reports
`prerelease="dev"` through `vim.version()` despite its release CLI version;
the bootstrap records both values and verifies the exact artifact checksum.

Compatibility sweeps, live examples, generated reference checks and benchmarks
will extend these commands as their implementations land. The present outer
gate does not establish the full [compatibility matrix](../docs/compatibility.md).

The [field catalog](../data/tmux-fields.json) generates Lua schemas, LuaLS
annotations and the [field reference](../docs/fields.md). Regenerate after
reviewing a catalog change; the mid gate checks drift without network access:

```console
$ mise exec -- python scripts/generate_fields.py
```

The [option catalog](../data/tmux-options.json) generates private release
metadata and the [option reference](../docs/options-reference.md). Normal
generation and drift checks are offline:

```console
$ mise exec -- python scripts/generate_options.py
```

Check whitespace in unstaged changes:

```console
$ git diff --check
```

Check whitespace in staged changes:

```console
$ git diff --cached --check
```

Report which checks ran and which remain unavailable. Missing or skipped
compatibility, examples and CI evidence remain open gates.

### GitHub Actions

[CI](workflows/ci.yml) runs on pull requests, pushes to `master` and manual
dispatch. Ubuntu 24.04 jobs run the existing offline gates after a separate
dependency bootstrap:

- Unit suites on every accepted PUC Lua version and standalone LuaJIT.
- Full outer checks at Lua/tmux/Neovim floor and current versions, including
  format, lint, generated files, docs, installed rocks and LuaLS completion.
- The full integration suite on every accepted tmux release, using current
  Lua and Neovim.

Jobs retain tool identities, gate output and build diagnostics. Actions use
pinned commits and read-only repository permissions. Setup failures fail the
job; gates do not install missing dependencies. The job deadline includes
bootstrap and does not replace the test-loop budgets below.

CI builds tmux at the commit recorded in the option catalog, checks the
reported version and records the binary hash. To reproduce that setup:

```console
$ mise exec -- python scripts/bootstrap_native.py tmux \
    --tmux-version=3.7c
```

The build requires Autoconf, Automake, a C compiler, make, pkg-config, Bison,
libevent and ncurses development headers. Select its result through
`TMUX_BIN=.cache/toolchains/tmux-3.7c/bin/tmux` when running a gate.
macOS, remaining runtime/host combinations and unfinished product gates stay
open in the [compatibility matrix](../docs/compatibility.md).

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

The organization repository is public; the personal repository is private.
They are independent, with `master` as the default branch. The personal
repository is not a GitHub fork. Push only to `origin`.
