defmodule Scry.Engine.ETS do
  @moduledoc """
  A real, kind-independent `Scry.Core.EngineBehaviour` implementation
  over native ETS tables (`Scry.Engine.ETS.Conn`).

  `fetch/2` is an unconditional `:ets.tab2list/1` -- every row, same
  contract shape every engine in this family has for the un-optimized
  case. `fetch/3` recognizes exactly one shape: `query.wheres` holding
  a *single* `{:cmp, :eq, path, value}` predicate where `path` names
  that source's own declared key field (`Scry.Engine.ETS.Conn.new/2`'s
  `keys:` option) and `value` is a literal (not `{:field, _}` or
  `{:param, _}`) -- that becomes a real `:ets.lookup/2`, O(1) instead of
  a full scan filtered client-side. Anything else (no declared key, a
  compound/`:and`/`:or`/`:in` predicate, more than one `where`, no
  `wheres` at all) falls back to `fetch/2`'s own full-scan behavior --
  same "engine may decline to optimize" posture `Scry.Core.
  EngineBehaviour`'s own moduledoc describes. `Scry.Core.Executor`
  re-applies the query's full semantics to whatever either callback
  returns regardless, so this narrowing only ever needs to be
  correct, never complete, exactly that moduledoc's own safety
  invariant.

  Real match-spec-based pushdown for non-key or compound predicates is
  a natural future extension of this same module, not attempted here.
  """

  @behaviour Scry.Core.EngineBehaviour

  alias Scry.Core.Query
  alias Scry.Engine.ETS.Conn

  @impl true
  def fetch(%Conn{tables: tables}, source) do
    case Map.fetch(tables, source) do
      {:ok, table} -> {:ok, table |> :ets.tab2list() |> rows_of()}
      :error -> {:error, {:no_such_source, source}}
    end
  end

  @impl true
  def fetch(%Conn{} = conn, source, %Query{} = query) do
    case Map.fetch(conn.tables, source) do
      {:ok, table} ->
        case key_lookup(conn, source, table, query) do
          {:ok, objects} -> {:ok, rows_of(objects)}
          :not_applicable -> {:ok, table |> :ets.tab2list() |> rows_of()}
        end

      :error ->
        {:error, {:no_such_source, source}}
    end
  end

  defp key_lookup(conn, source, table, %Query{wheres: [{:cmp, :eq, path, value}]}) do
    with key_field when not is_nil(key_field) <- Map.get(conn.keys, source),
         true <- path == [key_field],
         true <- literal?(value) do
      {:ok, :ets.lookup(table, value)}
    else
      _ -> :not_applicable
    end
  end

  defp key_lookup(_conn, _source, _table, _query), do: :not_applicable

  defp literal?({:field, _}), do: false
  defp literal?({:param, _}), do: false
  defp literal?(_value), do: true

  defp rows_of(objects), do: Enum.map(objects, fn {_key, row} -> row end)
end
