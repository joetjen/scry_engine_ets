# scry_engine_ets

A real, kind-independent [`Scry.Core.EngineBehaviour`](https://github.com/joetjen/scry_core)
implementation over native [ETS](https://www.erlang.org/doc/man/ets.html)
tables — `fetch/2` (a full `:ets.tab2list/1`) plus a real `fetch/3`:
a single top-level equality predicate on a table's own declared key
field becomes an O(1) `:ets.lookup/2`, instead of a full scan filtered
client-side.

Kind-independent by construction, like every engine in this family: it
only ever sees the `source`/`Scry.Core.Query.t()` shapes `Scry.Core.
Executor` already produces once any kind-specific vocabulary (`LAST`,
eventually `via`/`hops`, ...) has been lowered away. No backend of its
own — an in-process, ephemeral engine, not for production use across
process boundaries.

Source: <https://github.com/joetjen/scry_engine_ets>. Specs live in the
separate [`scry`](https://github.com/joetjen/scry) repository; the
behaviour this implements lives in
[`scry_core`](https://github.com/joetjen/scry_core).

## Usage

```elixir
{:ok, conn} =
  Scry.Engine.ETS.Conn.new(
    %{["users"] => [%{"id" => 1, "name" => "Alice", "age" => 30}]},
    keys: [{["users"], "id"}]
  )

{:ok, query} = Scry.Core.parse(~s(SELECT users WHERE id = 1 { name }))
{:ok, cursor} = Scry.Core.Executor.run(query, Scry.Engine.ETS, conn)
rows = Scry.Core.Cursor.to_list(cursor)
# rows == [%{"name" => "Alice"}]
```

`Conn.put/3` inserts more rows into an existing (or new) source's table
after the fact. A source with no declared key still works through both
`fetch/2` and `fetch/3` — `fetch/3` just always falls back to a full
scan for it, the same "engine may decline to optimize" posture every
engine in this family has.

The ETS table backing each source is created in, and owned by, the
calling process — it disappears when that process exits, exactly like
any other ETS table with no explicit heir.

## Installation

```elixir
def deps do
  [
    {:scry_engine_ets, "~> 0.1.0"}
  ]
end
```

## Documentation

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc):

- Released versions are published to [HexDocs](https://hexdocs.pm) once the
  package ships, at <https://hexdocs.pm/scry_engine_ets>.
