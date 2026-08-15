defmodule Scry.Engine.ETS.Conn do
  @moduledoc """
  The "connection" `Scry.Engine.ETS.execute/3` reads from -- one ETS
  `:set` table per source, created in (and owned by) the calling
  process, matching the connection/config struct every real adapter
  exposes.

  A source's own table is optionally backed by a caller-declared *key
  field* (`new/2`'s own `keys:` option, e.g. `{["users"], "id"}`) --
  this is what lets `Scry.Engine.ETS.execute/3` recognize a single
  top-level equality predicate on that field and turn it into a real
  `:ets.lookup/2` instead of a scan. A source with no declared key
  still works fine -- `execute/3` simply always uses its own match-spec
  compiler (or a full scan, if nothing in `WHERE` translates) for it
  instead, the same "engine may decline to optimize a given shape"
  posture every engine in this family has.

  Every table is created `:protected` (the ETS default): the owning
  process can read and write it, any other process can only read it --
  exactly the access pattern a connection struct handed to
  `Scry.Core.Executor.run/4` needs. Tables have no explicit heir, so
  they disappear when the owning process exits, same as any other ETS
  table.
  """

  @typedoc "One `{source_path, key_field}` pair, e.g. `{[\"users\"], \"id\"}`."
  @type key_spec :: {[String.t()], String.t()}

  @typedoc "Keyed by source path (e.g. `[\"orders\"]`), matching `Scry.Core.Query.source`."
  @type data :: %{optional([String.t()]) => [Scry.Core.EngineBehaviour.row()]}

  @type t :: %__MODULE__{
          tables: %{optional([String.t()]) => :ets.tid()},
          keys: %{optional([String.t()]) => String.t()}
        }

  defstruct tables: %{}, keys: %{}

  @doc """
  Builds a `Conn`, loading `data` into one fresh ETS table per source.
  `keys:` (a list of `key_spec()`) declares, per source, which field
  identifies a row uniquely -- a source may appear here even with no
  rows yet in `data`, so a later `put/3` call still lands in a
  key-aware table.
  """
  @spec new(data(), keyword()) :: t()
  def new(data \\ %{}, opts \\ []) when is_map(data) do
    keys = opts |> Keyword.get(:keys, []) |> Map.new()
    sources = data |> Map.keys() |> MapSet.new() |> MapSet.union(MapSet.new(Map.keys(keys)))

    tables =
      Map.new(sources, fn source ->
        table = :ets.new(:scry_engine_ets_source, [:set, :protected])
        :ets.insert(table, Enum.map(Map.get(data, source, []), &to_object(&1, keys[source])))
        {source, table}
      end)

    %__MODULE__{tables: tables, keys: keys}
  end

  @doc """
  Inserts `rows` into `source`'s own table, creating it (honoring any
  key field already declared for `source` via `new/2`'s own `keys:`
  option) if this is the first row seen for it.
  """
  @spec put(t(), [String.t()], [Scry.Core.EngineBehaviour.row()]) :: t()
  def put(%__MODULE__{} = conn, source, rows) when is_list(rows) do
    table =
      case Map.fetch(conn.tables, source) do
        {:ok, table} -> table
        :error -> :ets.new(:scry_engine_ets_source, [:set, :protected])
      end

    :ets.insert(table, Enum.map(rows, &to_object(&1, conn.keys[source])))
    %{conn | tables: Map.put(conn.tables, source, table)}
  end

  defp to_object(row, nil), do: {make_ref(), row}
  defp to_object(row, key_field), do: {Map.fetch!(row, key_field), row}
end
