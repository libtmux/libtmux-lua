# Query captured data

`libtmux.query` filters ordinary Lua records without contacting tmux, starting
a loop, or loading a codec. Supply a schema for an ordinary sequence, including
an empty one. [The native query example](../examples/native_query.lua) shows
both structured criteria and a Lua predicate over the same records.

`query.select(rows, schema)` copies the sequence and retains the record objects.
The result is a dense one-based Lua table: indexing, `#` and `ipairs` behave
normally. `:where(criteria)` and `:filter(predicate)` return new selections.
They preserve input order, duplicate records and shared record references.
The input and returned tables remain mutable; they are not live views.

| Operation | Result |
| --- | --- |
| `:first()` | First record, or nil |
| `:one()` | Record, or `nil, no_match/multiple_matches` error |
| `:one_or_nil()` | Zero or one record; multiple matches return an error |
| `:exists()` / `:count()` | Whether any records exist / sequence length |
| `:iter()` | Fresh local iterator yielding records |
| `:to_table()` | Shallow sequence copy without selection methods |

Free functions accept the sequence first and its schema last. A selection
carries its schema. `query.compile(schema, criteria)` returns a compiled handle
or `nil, err`; `query.where(rows, compiled)` uses that handle's schema for
ordinary rows. Compilation copies the schema and criteria. Mutating their
original tables cannot change the compiled query. Convenience validation errors
raise structured error tables; `compile` and cardinality errors return them.
Trusted predicates run as ordinary Lua and their errors propagate unchanged.

## Criteria and projections

Schema fields declare `string`, `number` or `boolean`, with optional `nullable`
and `supported` booleans. Relations declare `cardinality = "one"` or `"many"`
and a child `schema`. To-many arrays must describe the complete relationship.

Scalar criteria are equality shorthand; `false` is a value. Operators are
`eq`, `ne`, `one_of`, `none_of`, `lt`, `lte`, `gt`, `gte`, `contains`,
`starts_with`, `ends_with` and `is_null`. Strings compare literal bytes.
`AND`/`OR` contain dense arrays of criteria; `NOT` contains one criterion.
Multiple fields and operators imply AND. To-many relations use `some`, `every`
or `none`; to-one relations use `is` or `is_not` with criteria or `query.NULL`.

`query.NULL` represents a loaded absent nullable value or to-one relation.
A missing key is unloaded. Unloaded and unsupported data produce errors even
inside branches that would otherwise short-circuit. The entire grammar is
validated first, then every required projection, then matching begins. Invalid
criteria fail even when the input is empty.

Empty criteria and `AND` match; empty `OR` and `one_of` do not; empty `none_of`
matches. On empty relationships, `some` is false and `every`/`none` are true.
For an absent to-one relation, `is = criteria` is false, `is_not = criteria`
is true, `is = NULL` is true, and `is_not = NULL` is false.

Criteria reject metatables, functions, cycles and non-finite numbers. Limits
are depth 32, 4,096 copied nodes, 1,024 members per membership operator,
65,536 aggregate string/key bytes and a conservative 524,288-byte encoding
estimate. These limits bound criteria validation. Local row traversal and
arbitrary caller predicates are synchronous CPU work.

## Versioned JSON criteria

`query.encode_json(schema, criteria, codec)` returns a JSON string or `nil, err`.
`query.decode_json(schema, text, codec)` returns new plain criteria tables or
`nil, err`. Both validate the complete grammar against the supplied local
schema. The wire does not supply its own schema or executable predicates.

Pass the consumer's codec explicitly. The supported interface is lunajson
1.2.3's `encode(value, null)` and `newparser(text, callbacks)` SAX API; an
ordinary JSON `decode` function cannot preserve evidence of duplicate keys.
Core imports and ordinary queries require only Lua. Codec functions are
trusted synchronous code; the library does not load a codec automatically.

```lua
local query = require("libtmux.query")
local json = require("lunajson")
local schema = { fields = { active = { type = "boolean" } } }
local text = assert(query.encode_json(schema, { active = false, AND = {} }, json))
local criteria = assert(query.decode_json(schema, text, json))
```

This Lua API's versioned profile has exactly two envelope members:

```json
{"version":"libtmux.where/v1","where":{"active":false,"AND":[]}}
```

Profile compatibility is scoped to this Lua API; cross-port conformance has
not been established. Wire operators retain their Lua spelling, including
uppercase `AND`, `OR` and `NOT`. Unknown members and versions are rejected.
Schema positions determine array versus object encoding: empty `AND`, `OR`,
`one_of` and `none_of` use `[]`; empty criteria use `{}`. Decode rejects a
container of the wrong kind, including an empty object in an array position.
`query.NULL` becomes JSON null and decodes back to the same sentinel. False
remains false. Encoding marks arrays only in private copies and leaves caller
criteria and schemas unchanged.

The decoder rejects duplicate decoded keys, trailing non-whitespace, malformed
Unicode, invalid UTF-8 and non-finite numbers. Wire numbers have magnitude at
most 9,007,199,254,740,991; nonzero number tokens that underflow to zero are
rejected. Numbers otherwise use the host's floating-point representation.
Strings containing arbitrary non-UTF-8 bytes remain usable in local criteria
and require a separate binary representation at a consumer boundary.

Input is capped at 524,288 bytes before constructing the SAX parser. Parsing
checks depth 32, 4,096 nodes and 65,536 aggregate decoded string/key bytes as
events arrive. Membership remains capped at 1,024 values. Encoding applies the
same wire budgets and output-byte cap. Envelope members and keys count toward
wire limits, so criteria at a local limit may exceed a wire limit.

Errors retain `code`, `operation`, `message` and `path`. `invalid_json` covers
syntax and scalar encoding failures, `invalid_wire` covers envelope/container
shape, and `unsupported_wire_version` rejects another profile version.
`invalid_codec` and `codec_error` report absent or failing injected codecs.
Existing grammar errors and `query_limit` remain structured errors as well.

## Query live state explicitly

`server:query_panes(options)` returns a `Request<LiveQueryResult<Pane>>`.
`server:query(options)` accepts `kind` for session, window, pane, window_link,
client or buffer records. Both return `rows`, a canonical Selection, plus the
captured `snapshot`, executed `plan`, acquisition interval, `complete` flag
and detected `races`. Collection methods on these results remain local.

Pass structured `where` criteria and choose a `pushdown` mode:

| Mode | Behavior |
| --- | --- |
| `never` | Capture the graph and evaluate all criteria locally. |
| `auto` | Also apply supported necessary pane predicates at the source. |
| `require` | Reject an incomplete native translation before any listing. |

Native translation currently supports bounded equality tests on selected pane
IDs, booleans and integer fields. Other criteria remain local. AND can supply
necessary source predicates; partial OR, NOT and relationship predicates
cannot. All entity kinds support local evaluation. `require` for another
entity kind reports `unsupported_pushdown`.

`server:explain_panes(options)` and `server:explain(options)` return Requests
with the ordered command phases, projections, relation hydration paths,
pushed predicates and residual reasons. Explaining performs no tmux I/O.
Inputs and projections validate before any live dispatch and are copied so
later caller mutation cannot change the query.

The `snapshot` option accepts [snapshot acquisition options](snapshots.md).
Required criterion fields are added to explicit projections. The current
implementation captures the whole relationship graph before an optional
native candidate listing. It preserves canonical order and linked-window
context; filtering candidate IDs never removes children from quantified
relationships. This establishes semantics, not a performance advantage.

The graph and candidate listing cover different moments. `candidate_missing`
reports a candidate absent from the captured graph; `candidate_changed`
reports disagreement with a pushed predicate. `complete=true` means no known
inconsistency, not an atomic view. `snapshot.strict` adds its one topology
verification pass; it cannot freeze state across the later candidate listing.
The acquisition interval covers both phases. Snapshot and candidate listing
each apply the requested row/byte limits; retained data also shares the
runtime byte budget.

Expert `native_filter` accepts an explicit pane format, up to 16 KiB. It is
mutually exclusive with `where` and `pushdown`. It uses tmux's format language
as supplied, has no equivalent local predicate, and receives no portability
guarantee. Use structured criteria for untrusted data.

The [public live-query fixture](../tests/integration/live_query.lua) exercises
linked-window duplicates, projected fields, relationship quantifiers and an
expert filter through both adapters.
