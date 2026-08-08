defmodule Scry.Engine.ETS do
  @moduledoc """
  A real, kind-independent `Scry.Core.EngineBehaviour` implementation
  over native ETS tables (`Scry.Engine.ETS.Conn`).

  `execute/3` narrows via a real ETS index/scan wherever it can, then
  *always* hands the reduced row set to `Scry.Core.QueryOps.run_flat/3`
  with the original, complete query -- ETS itself has no native
  `GROUP BY`/aggregation/sorting/window-function primitive at all, so
  every construct beyond `WHERE` is the toolkit's job regardless, and
  re-applying the full `wheres` too is always safe (idempotent over an
  already-narrowed set) and is what keeps this narrowing's own
  correctness bar at "never wrong," not "provably exhaustive":

  - A *single* `{:cmp, :eq, path, value}` predicate where `path` names
    that source's own declared key field (`Scry.Engine.ETS.Conn.new/2`'s
    `keys:` option) and `value` resolves to a literal (a literal
    outright, or a `{:param, name}` bound to one) becomes a real
    `:ets.lookup/2` -- O(1), unchanged from before this pivot.
  - Otherwise, `Scry.Engine.ETS.MatchSpec.compile/2` translates
    whatever top-level, single-segment `==`/`/=`/`<`/`>`/`=<`/`>=`
    comparisons (boolean-combined) it can into a real `:ets.select/2`
    guard -- that module's own moduledoc has the complete translation
    rules and a real, confirmed-by-measurement correctness subtlety
    (a guard can never raise the way a null-safety hard error does,
    so every generated guard defensively lets a `nil`-or-absent field
    through rather than risk silently swallowing an error `run_flat/3`
    should still raise).
  - Nothing in `wheres` translates at all -- an unconditional
    `:ets.tab2list/1`, the same full-scan fallback this engine has
    always had.

  This is a real, new capability versus the single-key-equality-only
  narrowing this module had before: a multi-predicate `WHERE` (or one
  against a non-key field) that previously always fell through to a
  full scan can now genuinely narrow via `:ets.select/2` first. `GROUP
  BY`/aggregate/window-function/`ROLLUP`/`CUBE` queries see no
  performance change from this pivot at all -- ETS has no native
  primitive for any of them, so `run_flat/3` does exactly the same
  work it always would have, just reached one call earlier.
  """

  @behaviour Scry.Core.EngineBehaviour

  alias Scry.Core.{CombinedQuery, Query, QueryOps}
  alias Scry.Engine.ETS.{Conn, MatchSpec}

  @impl true
  def execute(conn, %CombinedQuery{} = combined, params),
    do: QueryOps.run_document(conn, combined, params, __MODULE__)

  def execute(%Conn{} = conn, %Query{source: source} = query, params) do
    if Enum.any?(query.select, &match?(%Query{}, &1)) or with_bound_source?(query) do
      QueryOps.run_document(conn, query, params, __MODULE__)
    else
      case Map.fetch(conn.tables, source) do
        {:ok, table} -> QueryOps.run_flat(scan(conn, source, table, query, params), query, params)
        :error -> {:error, {:query_error, {:no_such_source, source}}}
      end
    end
  end

  defp with_bound_source?(%Query{source: [name], with_bindings: with_bindings}),
    do: Map.has_key?(with_bindings, name)

  defp with_bound_source?(_query), do: false

  defp scan(conn, source, table, query, params) do
    case key_lookup(conn, source, table, query, params) do
      {:ok, objects} ->
        rows_of(objects)

      :not_applicable ->
        case MatchSpec.compile(query.wheres, params) do
          {:ok, match_spec} -> :ets.select(table, match_spec)
          :none -> table |> :ets.tab2list() |> rows_of()
        end
    end
  end

  defp key_lookup(conn, source, table, %Query{wheres: [{:cmp, :eq, [field], rhs}]}, params) do
    with key_field when not is_nil(key_field) <- Map.get(conn.keys, source),
         true <- [field] == [key_field],
         {:ok, value} <- resolve_literal(rhs, params) do
      {:ok, :ets.lookup(table, value)}
    else
      _ -> :not_applicable
    end
  end

  defp key_lookup(_conn, _source, _table, _query, _params), do: :not_applicable

  defp resolve_literal({:field, _}, _params), do: :error
  defp resolve_literal({:call, _, _}, _params), do: :error
  defp resolve_literal({:dot, _, _}, _params), do: :error

  defp resolve_literal({:param, name}, params) do
    case Map.fetch(params, name) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  defp resolve_literal(value, _params), do: {:ok, value}

  defp rows_of(objects), do: Enum.map(objects, fn {_key, row} -> row end)
end
