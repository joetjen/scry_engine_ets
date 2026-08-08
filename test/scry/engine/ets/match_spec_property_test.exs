defmodule Scry.Engine.ETS.MatchSpecPropertyTest do
  @moduledoc """
  `Scry.Engine.ETS`'s own `:ets.select/2` match-spec narrowing --
  proves, across randomly generated single/compound `WHERE` predicates
  and randomly generated rows (including `nil`-valued fields), that
  `execute/3`'s narrowed-then-`QueryOps.run_flat/3`-finished result is
  always identical to running `Scry.Core.QueryOps.run_flat/3` directly
  over the *entire*, unnarrowed table -- the direct replacement for
  the automatic re-verification the old `fetch/3` contract used to
  provide for free, now this engine's own responsibility to prove.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Scry.Core.{Query, QueryOps}
  alias Scry.Engine.ETS
  alias Scry.Engine.ETS.Conn

  @fields ["a", "b", "c"]

  defp row_generator do
    gen all(values <- list_of(field_value(), length: length(@fields))) do
      Enum.zip(@fields, values) |> Map.new()
    end
  end

  defp field_value do
    one_of([integer(-5..5), string(:alphanumeric, max_length: 3), constant(nil)])
  end

  defp literal_value do
    one_of([integer(-5..5), string(:alphanumeric, max_length: 3)])
  end

  defp predicate_generator(depth \\ 0)

  defp predicate_generator(depth) when depth >= 2 do
    comparison_generator()
  end

  defp predicate_generator(depth) do
    one_of([
      comparison_generator(),
      gen all(
            l <- predicate_generator(depth + 1),
            r <- predicate_generator(depth + 1),
            combinator <- member_of([:and, :or])
          ) do
        {combinator, l, r}
      end
    ])
  end

  defp comparison_generator do
    gen all(
          field <- member_of(@fields),
          op <- member_of([:eq, :not_eq, :lt, :gt, :le, :ge]),
          value <- literal_value()
        ) do
      {:cmp, op, [field], value}
    end
  end

  property "execute/3's narrowed result always matches QueryOps.run_flat/3 over the whole table" do
    check all(
            rows <- list_of(row_generator(), max_length: 8),
            predicate <- predicate_generator(),
            max_runs: 500
          ) do
      conn = Conn.new(%{["items"] => rows})
      select = Enum.map(@fields, &{:field, [&1]})
      query = %Query{source: ["items"], wheres: [predicate], select: select}

      via_engine = safe_run(fn -> ETS.execute(conn, query, %{}) |> materialize() end)
      via_toolkit = safe_run(fn -> QueryOps.run_flat(rows, query, %{}) |> materialize() end)

      assert normalize(via_engine) == normalize(via_toolkit)
    end
  end

  property "the same holds for multiple top-level wheres entries (implicitly ANDed, short-circuiting like Enum.all?/2)" do
    check all(
            rows <- list_of(row_generator(), max_length: 8),
            predicates <- list_of(predicate_generator(), min_length: 2, max_length: 3),
            max_runs: 500
          ) do
      conn = Conn.new(%{["items"] => rows})
      select = Enum.map(@fields, &{:field, [&1]})
      query = %Query{source: ["items"], wheres: predicates, select: select}

      via_engine = safe_run(fn -> ETS.execute(conn, query, %{}) |> materialize() end)
      via_toolkit = safe_run(fn -> QueryOps.run_flat(rows, query, %{}) |> materialize() end)

      assert normalize(via_engine) == normalize(via_toolkit)
    end
  end

  defp materialize({:ok, rows}), do: {:ok, Enum.to_list(rows)}
  defp materialize(other), do: other

  defp safe_run(fun) do
    {:ok, fun.()}
  rescue
    e -> {:raised, e.__struct__}
  end

  # Both sides either raise the identical exception kind, or return the
  # identical (order-independent -- neither side promises a particular
  # narrowing/scan order) row set.
  defp normalize({:ok, {:ok, rows}}), do: {:ok, Enum.sort(rows)}
  defp normalize({:ok, other}), do: other
  defp normalize({:raised, kind}), do: {:raised, kind}
end
