# Changelog

## [Unreleased]

### Added

- Initial release: `Scry.Engine.ETS` -- a real, kind-independent `Scry.Core.EngineBehaviour` implementation over native ETS tables. `fetch/2` is a plain `:ets.tab2list/1` full scan; `fetch/3` recognizes a single top-level equality predicate on a source's own caller-declared key field and turns it into a real `:ets.lookup/2`, O(1) instead of a full scan filtered client-side -- falling back to `fetch/2`'s own full-scan behavior for anything else (no declared key, a non-key field, a compound predicate, no `wheres` at all).
- `Scry.Engine.ETS.Conn` -- one ETS `:set` table per source, created in and owned by the calling process. `new/2` loads an initial `%{source => rows}` map, with an optional `keys:` list declaring which field identifies a row uniquely per source; `put/3` inserts more rows into an existing (or new) source's table afterward, honoring any key already declared for it.
