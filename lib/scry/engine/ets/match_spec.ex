defmodule Scry.Engine.ETS.MatchSpec do
  @moduledoc """
  Compiles a subset of `Scry.Core.Query.predicate()` (`query.wheres`)
  into a real ETS match-spec guard -- top-level, single-segment
  `{:cmp, op, [field], literal_or_param}` comparisons (`==`/`/=`/`<`/
  `>`/`=<`/`>=`), combined via `and`/`or`/`not`, over a table storing
  `{key, row}` objects where `row` is a plain string-keyed map.
  Anything wider (a multi-segment path, `{:field, ...}`/`{:call, ...}`
  on either side, `:in`, `:match`) simply doesn't compile for that one
  predicate -- `Scry.Engine.ETS.execute/3` always re-applies the
  *original*, complete query via `Scry.Core.QueryOps.run_flat/3`
  afterward regardless of what this narrows, so a predicate this can't
  translate only costs speed, never correctness, by design.

  **The real correctness subtlety this exists to get right, confirmed
  by direct measurement, not assumed:** an ETS match-spec guard can
  never *raise* the way `Scry.Core.QueryOps.eval_predicate/4`'s own
  null-safety hard error does -- a guard that would error simply
  evaluates to `false`. A single comparison against a `nil`-valued (or
  absent) field is handled by letting it through defensively (`Scry.
  Core.QueryOps.run_flat/3`'s own re-evaluation is what actually
  raises). But a *compound* predicate is where a naive per-comparison
  defensive guard still goes wrong: combining a "this might need to
  raise" comparison with a plain `false` one via a bare `andalso`
  collapses the whole thing back to `false`, silently dropping the row
  again -- confirmed directly by a property test generating random
  compound predicates against random `nil`-containing rows, not
  assumed safe from the single-comparison case alone. Every predicate
  therefore compiles to a `{definite, escape}` guard *pair* --
  `definite` true only when the comparison genuinely holds with no
  `nil`/absent ambiguity anywhere it touched, `escape` true whenever
  evaluating the equivalent interpreter expression, in the *same*
  left-to-right, short-circuiting order `and`/`or`/`not` actually use,
  could still raise -- combined per combinator to mirror that
  short-circuit order exactly (an `and` never lets a right-hand
  `escape` survive past a definitely-`false` left-hand side, since the
  interpreter would never evaluate the right side there either). The
  match spec's own final guard is simply `escape or definite`.
  """

  alias Scry.Core.Query

  @typedoc "A real `:ets.match_spec()` compiled from as much of `wheres` as translates."
  @type match_spec :: [{{term(), term()}, [term()], [term()]}]

  @typedoc "`definite` -- genuinely, unambiguously matches; `escape` -- might still need to raise downstream."
  @type guard_pair :: {definite :: term(), escape :: term()}

  @ets_ops %{eq: :==, not_eq: :"/=", lt: :<, gt: :>, le: :"=<", ge: :>=}

  @doc """
  Compiles `wheres` (`Scry.Core.Query.t()`'s own `wheres` field,
  already implicitly `AND`ed left to right, exactly like `Enum.all?/2`
  short-circuits) into a single match spec selecting the row half of a
  `{key, row}` object -- `:none` when nothing in `wheres` translates
  at all (the caller falls back to a full `:ets.tab2list/1` scan),
  never a partial/incorrect one silently dropping a real error.
  """
  @spec compile([Query.predicate()], map()) :: {:ok, match_spec()} | :none
  def compile(wheres, params) do
    wheres
    |> Enum.reduce({:ok, {true, false}}, fn predicate, acc ->
      with {:ok, acc_pair} <- acc,
           pair when not is_nil(pair) <- compile_predicate(predicate, params) do
        {:ok, combine_and(acc_pair, pair)}
      else
        _ -> :none
      end
    end)
    |> case do
      {:ok, {true, false}} ->
        :none

      {:ok, {definite, escape}} ->
        {:ok, [{{:"$1", :"$2"}, [{:orelse, escape, definite}], [:"$2"]}]}

      :none ->
        :none
    end
  end

  # The literal-nil-rhs null-check idiom (`field = nil`/`field != nil`)
  # never hard-errors in the interpreter regardless of what the field
  # actually holds, so this always has a definite answer -- no escape
  # needed, including on a genuinely-absent field (`map_get/2` failing
  # there makes the guard fail, the correct "not equal" answer for
  # `/=` and correct "not a match" answer for `==` alike).
  defp compile_predicate({:cmp, op, [field], nil}, _params) when is_binary(field) do
    case ets_op(op) do
      {:ok, ets_op} -> {{ets_op, {:map_get, field, :"$2"}, nil}, false}
      :error -> nil
    end
  end

  defp compile_predicate({:cmp, op, [field], rhs}, params) when is_binary(field) do
    with {:ok, ets_op} <- ets_op(op),
         {:ok, literal} <- literal_value(rhs, params) do
      present = {:is_map_key, field, :"$2"}
      value = {:map_get, field, :"$2"}
      escape = {:orelse, {:not, present}, {:andalso, present, {:==, value, nil}}}
      definite = {:andalso, {:not, escape}, {:andalso, present, {ets_op, value, literal}}}
      {definite, escape}
    else
      _ -> nil
    end
  end

  defp compile_predicate({:and, l, r}, params) do
    with pl when not is_nil(pl) <- compile_predicate(l, params),
         pr when not is_nil(pr) <- compile_predicate(r, params) do
      combine_and(pl, pr)
    else
      _ -> nil
    end
  end

  defp compile_predicate({:or, l, r}, params) do
    with pl when not is_nil(pl) <- compile_predicate(l, params),
         pr when not is_nil(pr) <- compile_predicate(r, params) do
      combine_or(pl, pr)
    else
      _ -> nil
    end
  end

  defp compile_predicate({:not, p}, params) do
    case compile_predicate(p, params) do
      nil -> nil
      {definite, escape} -> {{:andalso, {:not, escape}, {:not, definite}}, escape}
    end
  end

  # `:in`, a `{:call, ...}`/`{:dot, ...}` lhs, and anything else this
  # module doesn't recognize -- left untranslated, not an error.
  defp compile_predicate(_other, _params), do: nil

  # `l` is evaluated first, matching `and`'s own left-to-right
  # short-circuit: if `l` might raise, the whole thing might (`r` is
  # never reached to matter); if `l` is a definite `true`, the result
  # is whatever `r` says; if `l` is a definite `false`, `r` is never
  # evaluated at all -- so `r`'s own `escape` must NOT survive into the
  # combined escape unless `l` was definitely `true` first.
  defp combine_and({dl, el}, {dr, er}) do
    {{:andalso, dl, dr}, {:orelse, el, {:andalso, dl, er}}}
  end

  # `l` evaluated first, matching `or`'s own short-circuit: a definite
  # `true` on the left short-circuits to `true` without ever touching
  # `r`; only when `l` is a definite `false` does `r` get evaluated at
  # all, so `r`'s own `escape`/`definite` only survive into the
  # combined result when `l` was definitely `false`.
  defp combine_or({dl, el}, {dr, er}) do
    l_false = {:andalso, {:not, el}, {:not, dl}}
    {{:orelse, dl, {:andalso, l_false, dr}}, {:orelse, el, {:andalso, l_false, er}}}
  end

  defp ets_op(op), do: Map.fetch(@ets_ops, op)

  defp literal_value({:field, _}, _params), do: :error
  defp literal_value({:call, _, _}, _params), do: :error
  defp literal_value({:dot, _, _}, _params), do: :error

  defp literal_value({:param, name}, params) do
    case Map.fetch(params, name) do
      {:ok, value} -> if literal?(value), do: {:ok, value}, else: :error
      :error -> :error
    end
  end

  defp literal_value(value, _params) do
    if literal?(value), do: {:ok, value}, else: :error
  end

  # Scry's own concrete value universe minus the struct-shaped ones
  # (`%Rational{}`/`%Date{}`/`%DateTime{}`/`%NaiveDateTime{}`) -- a
  # real ETS match-spec guard's own comparison operators only ever
  # compare against a plain term the same way the underlying BEAM
  # comparison does, with none of `Scry.Core.QueryOps.term_order/2`'s
  # own struct-aware exact/precision-correct comparison rules, so
  # pushing one of those down would silently compare by raw field
  # values instead -- left untranslated (falls through to `Scry.Core.
  # QueryOps.run_flat/3`'s own correct comparison) rather than risk it.
  defp literal?(v), do: is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v)
end
