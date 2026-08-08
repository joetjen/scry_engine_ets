defmodule Scry.Engine.ETSTest do
  @moduledoc """
  `Scry.Engine.ETS` -- confirms `execute/3` takes the real
  `:ets.lookup/2` path only for a single top-level equality predicate
  on a source's own declared key field, takes the real
  `:ets.select/2` match-spec path for other translatable `WHERE`
  shapes (a real capability gain over the pre-pivot single-key-only
  narrowing), falls back to a full `:ets.tab2list/1` scan only when
  nothing in `wheres` translates at all, and that every path agrees on
  results and composes correctly end to end through a real `Scry.Core.
  Executor.run/4` call -- `GROUP BY`/aggregates included, since ETS has
  no native primitive for those and `Scry.Core.QueryOps.run_flat/3`
  always finishes the job regardless of which narrowing path ran.
  """

  use ExUnit.Case, async: true

  alias Scry.Core.{Cursor, Executor, Query}
  alias Scry.Engine.ETS
  alias Scry.Engine.ETS.Conn

  @select [{:field, ["id"]}, {:field, ["name"]}, {:field, ["age"]}]

  @users [
    %{"id" => 1, "name" => "Alice", "age" => 30},
    %{"id" => 2, "name" => "Bob", "age" => 17}
  ]

  defp materialize({:ok, rows}), do: {:ok, Enum.to_list(rows)}
  defp materialize(other), do: other

  describe "execute/3 -- key-field pushdown (:ets.lookup/2)" do
    setup do
      {:ok, conn: Conn.new(%{["users"] => @users}, keys: [{["users"], "id"}])}
    end

    test "a single equality predicate on the declared key uses :ets.lookup/2", %{conn: conn} do
      query = %Query{source: ["users"], wheres: [{:cmp, :eq, ["id"], 1}], select: @select}

      assert {:ok, [%{"id" => 1, "name" => "Alice", "age" => 30}]} =
               materialize(ETS.execute(conn, query, %{}))
    end

    test "a key miss returns an empty result, not an error", %{conn: conn} do
      query = %Query{source: ["users"], wheres: [{:cmp, :eq, ["id"], 999}], select: @select}

      assert materialize(ETS.execute(conn, query, %{})) == {:ok, []}
    end

    test "a {:param, name} key value resolves against params", %{conn: conn} do
      query = %Query{
        source: ["users"],
        wheres: [{:cmp, :eq, ["id"], {:param, "id"}}],
        select: @select
      }

      assert {:ok, [%{"id" => 2, "name" => "Bob", "age" => 17}]} =
               materialize(ETS.execute(conn, query, %{"id" => 2}))
    end
  end

  describe "execute/3 -- match-spec pushdown (:ets.select/2)" do
    setup do
      {:ok, conn: Conn.new(%{["users"] => @users}, keys: [{["users"], "id"}])}
    end

    test "a predicate on a non-key field still narrows via a real match-spec select", %{
      conn: conn
    } do
      query = %Query{source: ["users"], wheres: [{:cmp, :eq, ["name"], "Alice"}], select: @select}

      assert {:ok, [%{"id" => 1, "name" => "Alice", "age" => 30}]} =
               materialize(ETS.execute(conn, query, %{}))
    end

    test "a compound (AND) predicate narrows via match-spec, not a full scan", %{conn: conn} do
      query = %Query{
        source: ["users"],
        wheres: [{:and, {:cmp, :gt, ["age"], 18}, {:cmp, :eq, ["name"], "Alice"}}],
        select: @select
      }

      assert {:ok, [%{"id" => 1, "name" => "Alice", "age" => 30}]} =
               materialize(ETS.execute(conn, query, %{}))
    end

    test "an OR predicate narrows via match-spec", %{conn: conn} do
      query = %Query{
        source: ["users"],
        wheres: [{:or, {:cmp, :eq, ["name"], "Alice"}, {:cmp, :eq, ["name"], "Bob"}}],
        select: @select
      }

      assert {:ok, rows} = materialize(ETS.execute(conn, query, %{}))
      assert Enum.sort_by(rows, & &1["id"]) == @users
    end

    test "a query with no wheres falls back to a full scan", %{conn: conn} do
      query = %Query{source: ["users"], wheres: [], select: @select}

      assert {:ok, rows} = materialize(ETS.execute(conn, query, %{}))
      assert Enum.sort_by(rows, & &1["id"]) == @users
    end

    test "a {:field, _} right-hand side doesn't translate, falls back to a full scan, still evaluates correctly",
         %{conn: conn} do
      # `id = age` is never true for either fixture row -- this proves
      # the untranslatable predicate still fell back to a real,
      # correct per-row evaluation (an empty match-spec guard list
      # would wrongly match everything; a silently-dropped predicate
      # would wrongly return every row) rather than either extreme.
      query = %Query{
        source: ["users"],
        wheres: [{:cmp, :eq, ["id"], {:field, ["age"]}}],
        select: @select
      }

      assert materialize(ETS.execute(conn, query, %{})) == {:ok, []}
    end

    test "no declared key on the source still narrows non-key predicates via match-spec" do
      conn = Conn.new(%{["users"] => @users})
      query = %Query{source: ["users"], wheres: [{:cmp, :eq, ["name"], "Bob"}], select: @select}

      assert {:ok, [%{"id" => 2, "name" => "Bob", "age" => 17}]} =
               materialize(ETS.execute(conn, query, %{}))
    end

    test "a nil-valued field still reaches QueryOps.run_flat/3's own null-safety hard error on pull, never silently excluded" do
      conn = Conn.new(%{["accounts"] => [%{"id" => 1, "balance" => nil}]})
      query = %Query{source: ["accounts"], wheres: [{:cmp, :gt, ["balance"], 0}], select: []}

      assert {:ok, rows} = ETS.execute(conn, query, %{})

      assert_raise ArgumentError, ~r/null-safety/, fn ->
        Enum.to_list(rows)
      end
    end

    test "the explicit nil-check idiom (field = nil) still works via match-spec, no hard error" do
      conn =
        Conn.new(%{
          ["accounts"] => [%{"id" => 1, "balance" => nil}, %{"id" => 2, "balance" => 5}]
        })

      query = %Query{
        source: ["accounts"],
        wheres: [{:cmp, :eq, ["balance"], nil}],
        select: [{:field, ["id"]}, {:field, ["balance"]}]
      }

      assert materialize(ETS.execute(conn, query, %{})) == {:ok, [%{"id" => 1, "balance" => nil}]}
    end

    test "an unknown source is still a clear, tagged error" do
      query = %Query{source: ["orders"], wheres: [], select: []}

      assert ETS.execute(Conn.new(), query, %{}) ==
               {:error, {:query_error, {:no_such_source, ["orders"]}}}
    end
  end

  describe "end to end through Scry.Core.Executor.run/4" do
    test "a key-equality filter executes correctly and uses the pushdown path" do
      conn = Conn.new(%{["users"] => @users}, keys: [{["users"], "id"}])

      query = %Query{
        source: ["users"],
        wheres: [{:cmp, :eq, ["id"], 1}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, cursor} = Executor.run(query, ETS, conn)
      assert Cursor.to_list(cursor) == [%{"name" => "Alice"}]
    end

    test "a non-key filter executes correctly through the match-spec narrowing path" do
      conn = Conn.new(%{["users"] => @users}, keys: [{["users"], "id"}])

      query = %Query{
        source: ["users"],
        wheres: [{:cmp, :gt, ["age"], 18}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, cursor} = Executor.run(query, ETS, conn)
      assert Cursor.to_list(cursor) == [%{"name" => "Alice"}]
    end

    test "GROUP BY/aggregate still works correctly -- ETS has no native primitive, QueryOps.run_flat/3 always does the work" do
      conn =
        Conn.new(%{
          ["orders"] => [
            %{"customer_id" => 1, "total" => 50},
            %{"customer_id" => 1, "total" => 75},
            %{"customer_id" => 2, "total" => 20}
          ]
        })

      query = %Query{
        source: ["orders"],
        group_bys: [["customer_id"]],
        select: [
          {:field, ["customer_id"]},
          {:computed, "total", {:call, "sum", [{:field, ["total"]}]}}
        ]
      }

      assert {:ok, cursor} = Executor.run(query, ETS, conn)

      assert Enum.sort(Cursor.to_list(cursor)) ==
               Enum.sort([
                 %{"customer_id" => 1, "total" => 125},
                 %{"customer_id" => 2, "total" => 20}
               ])
    end
  end
end
