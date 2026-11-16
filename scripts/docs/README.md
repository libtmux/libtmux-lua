# Documentation tooling

`docs.lua` exports the public model for the documentation site and checks that
the READMEs quote what the gates run.

| Command | Does |
| --- | --- |
| `export` | Runs the pinned LuaLS over a copy of `lua/`, adds the public declarations, the guides, the examples and the validated complete API examples, and writes `api.json` and the bundles. `--check` validates without writing. |
| `readmes` | Checks each README's logo block, that every Lua block is an example or excerpt of a file the gates run, console output against the examples manifest, prose length and links. |

## Who runs it

- The `types` gate runs `export --check`; the `docs` gate runs `readmes`.
- The `docs` workflow runs `export` for the documentation build.

The Python `export-docs` this replaced is `git show 8dc4642~1:scripts/export-docs`. The comparison and its result (the exports differ only in exporter.name) are in
[libtmux-lua#106](https://github.com/libtmux/libtmux-lua/issues/106#issuecomment-6907114327).

## Run it

Install LuaLS, then export into the default directory:

```console
$ luajit scripts/docs/docs.lua export
```

Check the READMEs:

```console
$ luajit scripts/docs/docs.lua readmes
```

Run the tests:

```console
$ luajit scripts/support/run_tests.lua \
    scripts/docs/tests/test_api_examples.lua \
    scripts/docs/tests/test_export.lua \
    scripts/docs/tests/test_readme_examples.lua
```
