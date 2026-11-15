# Catalog generators

`generate.lua` writes the Lua metadata and reference pages that the two tmux
catalogs describe, and checks that the committed copies are current.

| Catalog | Generates |
| --- | --- |
| [`data/tmux-fields.json`](../../data/tmux-fields.json) | [`fields.lua`](../../lua/libtmux/_internal/fields.lua) and [`docs/fields.md`](../../docs/fields.md) |
| [`data/tmux-options.json`](../../data/tmux-options.json) | [`options_catalog.lua`](../../lua/libtmux/_internal/options_catalog.lua) and [`docs/options-reference.md`](../../docs/options-reference.md) |

## Who runs it

- The `generated` gate of [check.lua](../check/README.md) runs both with `--check`, so a
  catalog edit without regeneration fails `mid` and CI.
- A maintainer runs it after reviewing a catalog change.

## Run it

Regenerate the field files; StyLua must be on `PATH`:

```console
$ luajit scripts/generate/generate.lua fields
```

Check that the option files are current:

```console
$ luajit scripts/generate/generate.lua options --check
```

`fields --verify-source CHECKOUT` also checks every pinned format mapping and
source anchor against a local tmux Git checkout. Run the tests:

```console
$ luajit scripts/support/run_tests.lua \
    scripts/generate/tests/test_generate.lua
```
