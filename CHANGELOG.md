# Changelog

## [Unreleased]

### Changed

- **Breaking**: `Scry.Engine.ETS` implements `Scry.Core.EngineBehaviour`'s new `execute/3` callback instead of `fetch/2,3` -- the old contract is gone from `scry_core` entirely (its own `CHANGELOG.md` has the full reasoning). `execute/3` still prefers a real `:ets.lookup/2` for a single top-level key-equality predicate, but now also compiles other translatable `WHERE` shapes (`==`/`/=`/`<`/`>`/`=<`/`>=`, boolean-`and`/`or`/`not`-combined, over a top-level field vs. a literal or resolved `{:param, name}`) into a real `:ets.select/2` match spec via the new `Scry.Engine.ETS.MatchSpec` module -- a genuine capability gain: a compound or non-key `WHERE` that previously always fell back to a full scan now genuinely narrows. `GROUP BY`/aggregates/sorting/window functions have no ETS-native equivalent at all, so `Scry.Core.QueryOps.run_flat/3` always finishes the job over whatever the narrowing step produced -- this pivot changes nothing about that, since ETS never had a native primitive for any of them to begin with.
  `Scry.Engine.ETS.MatchSpec`'s own moduledoc documents a real, confirmed-by-property-testing correctness subtlety this module exists specifically to get right: an ETS match-spec guard can never *raise* the way a null-safety hard error does, so a naive guard risks silently excluding a row whose own field is `nil` or absent instead of letting `run_flat/3`'s own re-evaluation raise it -- and a naive *per-comparison* defensive fix still breaks once predicates combine via `and`/`or`, since combining an "might need to raise" signal with a plain `false` via a bare `andalso` collapses back to `false`. Fixed via a `{definite, escape}` guard-pair algebra mirroring `and`/`or`/`not`'s own left-to-right short-circuit evaluation order exactly, verified by two property tests (single and multi-predicate `wheres`) comparing `execute/3`'s narrowed result against `Scry.Core.QueryOps.run_flat/3` run directly over the whole, unnarrowed table across randomly generated predicates and `nil`-containing rows.
  An unknown source now surfaces as `{:error, {:query_error, {:no_such_source, source}}}`, matching the new two-constructor `Scry.Core.EngineBehaviour.error/0` shape.

### Added

- Initial release: `Scry.Engine.ETS` -- a real, kind-independent `Scry.Core.EngineBehaviour` implementation over native ETS tables.
- `Scry.Engine.ETS.Conn` -- one ETS `:set` table per source, created in and owned by the calling process. `new/2` loads an initial `%{source => rows}` map, with an optional `keys:` list declaring which field identifies a row uniquely per source; `put/3` inserts more rows into an existing (or new) source's table afterward, honoring any key already declared for it.
