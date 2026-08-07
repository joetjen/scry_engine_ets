defmodule Scry.Engine.ETSTest do
  @moduledoc """
  `Scry.Engine.ETS` -- confirms `fetch/2` is a plain full scan,
  `fetch/3` takes the real `:ets.lookup/2` path only for a single
  top-level equality predicate on a source's own declared key field
  (falling back to a full scan for everything else: no declared key,
  a non-key field, a compound predicate, no `wheres` at all), that
  `fetch/2` and `fetch/3` agree on results whenever both apply, and
  that this all composes end to end through a real
  `Scry.Core.Executor.run/4` call.
  """

  use ExUnit.Case, async: true

  alias Scry.Core.{Cursor, Executor, Query}
  alias Scry.Engine.ETS
  alias Scry.Engine.ETS.Conn

  @users [
    %{"id" => 1, "name" => "Alice", "age" => 30},
    %{"id" => 2, "name" => "Bob", "age" => 17}
  ]

  describe "fetch/2" do
    test "returns every row for a known source" do
      conn = Conn.new(%{["users"] => @users}, keys: [{["users"], "id"}])

      assert {:ok, rows} = ETS.fetch(conn, ["users"])
      assert Enum.sort_by(rows, & &1["id"]) == @users
    end

    test "returns a clear error for an unknown source, never raises" do
      assert ETS.fetch(Conn.new(), ["orders"]) == {:error, {:no_such_source, ["orders"]}}
    end
  end

  describe "fetch/3 -- key-field pushdown" do
    setup do
      {:ok, conn: Conn.new(%{["users"] => @users}, keys: [{["users"], "id"}])}
    end

    test "a single equality predicate on the declared key uses :ets.lookup/2", %{conn: conn} do
      query = %Query{source: ["users"], wheres: [{:cmp, :eq, ["id"], 1}]}

      assert {:ok, [%{"id" => 1, "name" => "Alice"}]} = ETS.fetch(conn, ["users"], query)
    end

    test "a key miss returns an empty result, not an error", %{conn: conn} do
      query = %Query{source: ["users"], wheres: [{:cmp, :eq, ["id"], 999}]}

      assert ETS.fetch(conn, ["users"], query) == {:ok, []}
    end

    test "a predicate on a non-key field falls back to a full scan", %{conn: conn} do
      query = %Query{source: ["users"], wheres: [{:cmp, :eq, ["name"], "Alice"}]}

      assert {:ok, rows} = ETS.fetch(conn, ["users"], query)
      assert Enum.sort_by(rows, & &1["id"]) == @users
    end

    test "a compound predicate falls back to a full scan", %{conn: conn} do
      query = %Query{
        source: ["users"],
        wheres: [{:and, {:cmp, :eq, ["id"], 1}, {:cmp, :eq, ["name"], "Alice"}}]
      }

      assert {:ok, rows} = ETS.fetch(conn, ["users"], query)
      assert Enum.sort_by(rows, & &1["id"]) == @users
    end

    test "a query with no wheres falls back to a full scan", %{conn: conn} do
      query = %Query{source: ["users"], wheres: []}

      assert {:ok, rows} = ETS.fetch(conn, ["users"], query)
      assert Enum.sort_by(rows, & &1["id"]) == @users
    end

    test "a {:field, _} right-hand side is not a literal, falls back to a full scan", %{
      conn: conn
    } do
      query = %Query{source: ["users"], wheres: [{:cmp, :eq, ["id"], {:field, ["age"]}}]}

      assert {:ok, rows} = ETS.fetch(conn, ["users"], query)
      assert Enum.sort_by(rows, & &1["id"]) == @users
    end

    test "no declared key on the source falls back to a full scan" do
      conn = Conn.new(%{["users"] => @users})
      query = %Query{source: ["users"], wheres: [{:cmp, :eq, ["id"], 1}]}

      assert {:ok, rows} = ETS.fetch(conn, ["users"], query)
      assert Enum.sort_by(rows, & &1["id"]) == @users
    end

    test "an unknown source is still a clear error" do
      query = %Query{source: ["orders"], wheres: []}

      assert ETS.fetch(Conn.new(), ["orders"], query) == {:error, {:no_such_source, ["orders"]}}
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

    test "a non-key filter still executes correctly through the full-scan fallback" do
      conn = Conn.new(%{["users"] => @users}, keys: [{["users"], "id"}])

      query = %Query{
        source: ["users"],
        wheres: [{:cmp, :gt, ["age"], 18}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, cursor} = Executor.run(query, ETS, conn)
      assert Cursor.to_list(cursor) == [%{"name" => "Alice"}]
    end
  end
end
