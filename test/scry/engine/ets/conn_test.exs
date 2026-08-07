defmodule Scry.Engine.ETS.ConnTest do
  @moduledoc """
  `Scry.Engine.ETS.Conn` -- confirms `new/2` loads rows into a real ETS
  table per source (with or without a declared key field), `put/2`
  lands rows in the right table (creating one, honoring an
  already-declared key, if needed), and a table really does disappear
  once its owning process exits -- not just documented, checked.
  """

  use ExUnit.Case, async: true

  alias Scry.Engine.ETS.Conn

  describe "new/2" do
    test "is empty by default" do
      assert Conn.new().tables == %{}
    end

    test "creates one table per source found in data, with no declared key" do
      conn = Conn.new(%{["users"] => [%{"id" => 1, "name" => "Alice"}]})

      assert [{["users"], table}] = Map.to_list(conn.tables)
      assert :ets.info(table, :size) == 1
      assert Map.get(conn.keys, ["users"]) == nil
    end

    test "a declared key field lands as the row's own ETS key" do
      conn =
        Conn.new(
          %{["users"] => [%{"id" => 1, "name" => "Alice"}, %{"id" => 2, "name" => "Bob"}]},
          keys: [{["users"], "id"}]
        )

      table = Map.fetch!(conn.tables, ["users"])
      assert :ets.lookup(table, 1) == [{1, %{"id" => 1, "name" => "Alice"}}]
      assert :ets.lookup(table, 2) == [{2, %{"id" => 2, "name" => "Bob"}}]
    end

    test "a source declared as a key but absent from data still gets an (empty) table" do
      conn = Conn.new(%{}, keys: [{["users"], "id"}])

      assert %{["users"] => table} = conn.tables
      assert :ets.info(table, :size) == 0
    end
  end

  describe "put/2" do
    test "creates a table for a brand new source" do
      conn = Conn.new() |> Conn.put(["users"], [%{"id" => 1, "name" => "Alice"}])

      assert %{["users"] => table} = conn.tables
      assert :ets.info(table, :size) == 1
    end

    test "appends to an existing source's own table" do
      conn =
        Conn.new(%{["users"] => [%{"id" => 1, "name" => "Alice"}]})
        |> Conn.put(["users"], [%{"id" => 2, "name" => "Bob"}])

      table = Map.fetch!(conn.tables, ["users"])
      assert :ets.info(table, :size) == 2
    end

    test "honors an already-declared key field on a later put" do
      conn =
        Conn.new(%{}, keys: [{["users"], "id"}])
        |> Conn.put(["users"], [%{"id" => 7, "name" => "Carol"}])

      table = Map.fetch!(conn.tables, ["users"])
      assert :ets.lookup(table, 7) == [{7, %{"id" => 7, "name" => "Carol"}}]
    end
  end

  describe "table lifecycle" do
    test "a source's table disappears once its owning process exits" do
      parent = self()

      pid =
        spawn(fn ->
          conn = Conn.new(%{["users"] => [%{"id" => 1}]})
          table = Map.fetch!(conn.tables, ["users"])
          send(parent, {:table, table})
        end)

      table =
        receive do
          {:table, table} -> table
        end

      # Give the owning process a moment to actually exit before checking.
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      assert :ets.info(table) == :undefined
    end
  end
end
