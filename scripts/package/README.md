# Package check

`main.lua` builds the rock and tests it as a user would get it: installed into
its own temporary tree, imported from outside the checkout, with network
servers and ambient Lua paths disabled. A missing dependency fails locally
instead of downloading.

It checks the development rock (license, changelog, module inventory,
dependency closure, imports, the pure query example) and the release candidate
in [release.json](../../release.json): its source rock, packed from the public
tag or an isolated copy of the checkout, and the installed rockspec, license
and changelog. With `luv` added it runs the installed snapshot and quickstart
examples and every complete API program on a private tmux server, then proves a
failing import and a failing runtime propagate and leave no server behind.

## Who runs it

The `package` gate of `scripts/check.py`, and the release step of
[ci.yml](../../.github/workflows/ci.yml), which keeps the validated artifacts.

## Run it

`TMUX_BIN` selects the tmux the examples use:

```console
$ luajit scripts/package/main.lua \
    --lua lua
```

`--release` checks only the candidate, `--output DIR` keeps its artifacts in an
empty directory, and `--public-tag` fetches the source tag from the network.
The tests cover the source-drift check and the installed-changelog rule:

```console
$ luajit scripts/support/run_tests.lua \
    scripts/package/tests/test_package.lua
```
