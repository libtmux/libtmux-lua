# Editor completion check

`check_editor.lua` starts the pinned LuaLS, opens a document that chains
handles from the runtime to a snapshot, a pane capture and an observation, and
requires the completions an editor would offer at each cursor position. It also
requires that a handle offers none of the members its kind lacks, such as
`send_keys` on a session.

## Who runs it

The `types` gate of [check.lua](../check/README.md), in the outer loop.

## Run it

Install LuaLS first with `scripts/bootstrap/bootstrap.lua luals`, then:

```console
$ luajit scripts/check_editor/check_editor.lua
```

It prints one JSON line and exits 1 on the first missing or forbidden
completion. The protocol framing and the document are tested without LuaLS:

```console
$ luajit scripts/support/run_tests.lua \
    scripts/check_editor/tests/test_check_editor.lua
```
