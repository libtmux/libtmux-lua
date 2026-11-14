# Query captured data

`libtmux.query` filters ordinary Lua records without contacting tmux, starting
a loop or loading a codec. Pass a schema for any sequence, an empty one
included. [The native query example](../examples/native_query.lua) shows
structured criteria and a Lua predicate over the same records.

- `query.select(rows, schema)` copies the sequence and keeps the record
  objects. The result is a dense one-based table: indexing, `#` and `ipairs`
  work as usual.
- `:where(criteria)` and `:filter(predicate)` return new selections. They keep
  input order, duplicate records and shared record references.
- Input and results stay mutable. They are not live views.

| Operation | Result |
| --- | --- |
| `:first()` | First record, or nil |
| `:one()` | Record, or `nil, no_match/multiple_matches` error |
| `:one_or_nil()` | Zero or one record; multiple matches return an error |
| `:exists()` / `:count()` | Whether any records exist / sequence length |
| `:iter()` | Fresh local iterator yielding records |
| `:to_table()` | Shallow sequence copy without selection methods |

- Free functions take the sequence first and its schema last. A selection
  carries its schema.
- `query.compile(schema, criteria)` returns a compiled handle, or `nil, err`.
  `query.where(rows, compiled)` uses that handle's schema for ordinary rows.
  Compilation copies the schema and criteria, so later edits to the originals
  change nothing.
- Convenience validation raises structured error tables; `compile` and
  cardinality errors return them. A predicate runs as ordinary Lua and its
  errors propagate unchanged.

## Criteria and projections

- Schema fields declare `string`, `number` or `boolean`, with optional
  `nullable` and `supported` booleans.
- Relations declare `cardinality = "one"` or `"many"` and a child `schema`.
  A to-many array must describe the whole relationship.
- A scalar criterion is equality shorthand; `false` is a value. Operators are
  `eq`, `ne`, `one_of`, `none_of`, `lt`, `lte`, `gt`, `gte`, `contains`,
  `starts_with`, `ends_with` and `is_null`. Strings compare literal bytes.
- `AND` and `OR` hold dense arrays of criteria, `NOT` holds one. Several
  fields or operators mean AND.
- To-many relations use `some`, `every` or `none`. To-one relations use `is`
  or `is_not` with criteria or `query.NULL`.

`query.NULL` is a loaded absent nullable value or to-one relation. A missing
key is unloaded. Unloaded and unsupported data is an error, even inside a
branch that would otherwise short-circuit. The whole grammar is validated
first, then every projection it needs, then matching begins. Invalid criteria
fail even for empty input.

| Case | Result |
| --- | --- |
| Empty criteria, empty `AND`, empty `none_of` | Match |
| Empty `OR`, empty `one_of` | No match |
| `some` on an empty relation | False |
| `every`, `none` on an empty relation | True |
| `is = criteria` on an absent to-one relation | False |
| `is_not = criteria` on an absent to-one relation | True |
| `is = NULL` on an absent to-one relation | True |
| `is_not = NULL` on an absent to-one relation | False |

Criteria reject metatables, functions, cycles and non-finite numbers. The limits
are depth 32, 4,096 copied nodes, 1,024 members per membership operator, 65,536
aggregate string and key bytes and a 524,288-byte encoding estimate. They bound
criteria validation. Row traversal and your predicates are synchronous CPU work.

## Versioned JSON criteria

- `query.encode_json(schema, criteria, codec)` returns a JSON string, or
  `nil, err`.
- `query.decode_json(schema, text, codec)` returns new plain criteria tables,
  or `nil, err`.
- Both validate the whole grammar against your schema. The wire carries no
  schema and no predicates.
- Pass the codec yourself: lunajson's `encode(value, null)` and
  `newparser(text, callbacks)` SAX API. A plain JSON `decode` cannot see
  duplicate keys. Core imports and ordinary queries need only Lua, and the
  library never loads a codec for you. Codec functions are trusted code.

```lua
local query = require("libtmux.query")
local json = require("lunajson")
local schema = { fields = { active = { type = "boolean" } } }
local text = assert(query.encode_json(schema, { active = false, AND = {} }, json))
local criteria = assert(query.decode_json(schema, text, json))
```

The envelope has exactly two members:

```json
{"version":"libtmux.where/v1","where":{"active":false,"AND":[]}}
```

- The profile is specific to this Lua API; cross-port conformance has not been
  established.
- Operators keep their Lua spelling, uppercase `AND`, `OR` and `NOT` included.
  Unknown members and versions are rejected.
- The schema decides array or object encoding: empty `AND`, `OR`, `one_of` and
  `none_of` are `[]`, and empty criteria are `{}`. Decoding rejects a container
  of the wrong kind, an empty object in an array position included.
- `query.NULL` is JSON null and decodes back to the sentinel. `false` stays
  false. Encoding tags arrays only in private copies.
- The decoder rejects duplicate keys, trailing non-whitespace, malformed
  Unicode, invalid UTF-8 and non-finite numbers. Numbers are at most
  9,007,199,254,740,991 in magnitude, and a nonzero token that underflows to
  zero is rejected. A string of arbitrary non-UTF-8 bytes works in local
  criteria but needs a separate binary form at a consumer boundary.
- Input is capped at 524,288 bytes before the parser is built. Parsing checks
  depth 32, 4,096 nodes and 65,536 string and key bytes as events arrive, and
  membership is capped at 1,024. Encoding applies the same budgets and an
  output cap. Envelope members and keys count, so criteria at a local limit can
  exceed a wire limit.
- Errors keep `code`, `operation`, `message` and `path`: `invalid_json` for
  syntax and scalar encoding, `invalid_wire` for envelope and container shape,
  `unsupported_wire_version` for another version, and `invalid_codec` or
  `codec_error` for a missing or failing codec. Grammar errors and
  `query_limit` stay structured.

## Query live state explicitly

`server:query_panes(options)` returns a `Request<LiveQueryResult<Pane>>`.
`server:query(options)` takes `kind`: session, window, pane, window_link, client
or buffer. Both return:

- `rows`: a canonical Selection, with local collection methods;
- the captured `snapshot` and the executed `plan`;
- the acquisition interval, the `complete` flag and any detected `races`.

Pass structured `where` criteria and a `pushdown` mode:

| Mode | Behavior |
| --- | --- |
| `never` | Capture the graph and evaluate all criteria locally. |
| `auto` | Also apply supported necessary pane predicates at the source. |
| `require` | Reject an incomplete native translation before any listing. |

- Native translation covers bounded equality tests on selected pane IDs,
  booleans and integer fields. Other criteria stay local.
- AND can supply necessary source predicates. Partial OR, NOT and relationship
  predicates cannot.
- Every kind supports local evaluation. `require` on another kind reports
  `unsupported_pushdown`.

`server:explain_panes(options)` and `server:explain(options)` return Requests
with the ordered command phases, projections, relation hydration paths, pushed
predicates and residual reasons. Explaining does no tmux I/O. Inputs and
projections are validated before any live dispatch and copied, so later edits
cannot change the query.

- The `snapshot` option takes [snapshot options](snapshots.md). Fields a
  criterion needs are added to explicit projections.
- The query captures the whole relationship graph before any native candidate
  listing. It keeps canonical order and linked-window context, and filtering
  candidate IDs never removes children from quantified relationships. This
  fixes the semantics; it is not a speedup.
- The graph and the candidate listing cover different moments.
  `candidate_missing` reports a candidate absent from the graph, and
  `candidate_changed` one that disagrees with a pushed predicate.
  `complete = true` means no known inconsistency, not an atomic view.
- `snapshot.strict` adds its one topology check, which cannot freeze state
  across the later candidate listing. The acquisition interval covers both
  phases. Snapshot and candidate listing each apply the row and byte limits,
  and retained data shares the runtime byte budget.
- The expert `native_filter` takes a pane format of up to 16 KiB. It excludes
  `where` and `pushdown`, uses tmux's format language as written, has no local
  equivalent and no portability guarantee. Use structured criteria for
  untrusted data.
