defmodule CompileBudgetTest do
  use ExUnit.Case, async: false

  # The compile limit is a reduction budget on the compile worker
  # (`max_compile_reductions`), with `max_compile_ms` as a wall-clock backstop.

  # Raised structural limits, so the reduction budget is the bound under test.
  @large_limits %{
    max_tokens: 100_000,
    max_source_bytes: 500_000,
    max_ast_nodes: 1_000_000,
    max_nesting_depth: 256
  }

  # OTP compile cost of one guard with N `orelse` terms grows quadratically:
  # 400 terms take about 44M reductions, 800 about 160M and 1,600 about 600M.
  defp guard_bomb(terms) do
    guard = Enum.map_join(1..terms, " orelse ", &"(X =:= #{&1} andalso Y > #{&1})")
    "f(X, Y) when #{guard} -> 1; f(_, _) -> 0.\nresult({X, Y}) -> f(X, Y)."
  end

  defp hogs(count) do
    for _ <- 1..count do
      spawn(fn -> spin(0) end)
    end
  end

  defp spin(n), do: spin(n + 1)

  test "the compile limits are positive integers" do
    for limits <- [
          %{max_compile_reductions: 0},
          %{max_compile_reductions: nil},
          %{max_compile_ms: 0}
        ] do
      assert {:error, [%{category: :manifest, message: message}]} =
               Hyperlang.Test.program("result(X) -> X.", %{limits: limits})

      assert message =~ "runtime-critical limits must be positive"
    end
  end

  test "the front end is charged against the reduction budget" do
    assert {:error, [%{category: :compile_budget, message: message, details: details}]} =
             Hyperlang.Test.program("result(X) -> lists:reverse(X).", %{
               limits: %{max_compile_reductions: 2_000}
             })

    assert message == "compile reduction budget exceeded"
    assert details == %{limit: 2_000}
  end

  test "an OTP-compile guard bomb is stopped by the reduction budget" do
    manifest = %{limits: Map.put(@large_limits, :max_compile_reductions, 50_000_000)}
    {:ok, program} = Hyperlang.Test.program(guard_bomb(800), manifest)

    started = System.monotonic_time(:millisecond)

    assert {:error, %{category: :compile_budget, message: "compile reduction budget exceeded"}} =
             Hyperlang.Test.run(program, :entry, [{1, 5}])

    assert System.monotonic_time(:millisecond) - started < 30_000
  end

  test "the default budget stops a guard bomb that the structural limits admit" do
    {:ok, program} = Hyperlang.Test.program(guard_bomb(1_600), %{limits: @large_limits})

    assert {:error, %{category: :compile_budget}} =
             Hyperlang.Test.run(program, :entry, [{1, 5}])
  end

  test "the wall-clock backstop still stops a compile" do
    assert {:error, [%{category: :compile_timeout, message: "compile wall time exceeded"}]} =
             Hyperlang.Test.program(guard_bomb(400), %{limits: %{max_compile_ms: 1}})
  end

  test "the budget decision does not depend on host load" do
    source = guard_bomb(100)
    admit = %{limits: %{max_compile_reductions: 200_000_000}}
    reject = %{limits: %{max_compile_reductions: 1_000_000}}

    outcome = fn manifest ->
      case Hyperlang.Test.program(source, manifest) do
        {:ok, program} ->
          case Hyperlang.Test.run(program, :entry, [{1, 5}]) do
            {:ok, 1, _meta} -> :admitted
            {:error, error} -> error.category
          end

        {:error, [error | _]} ->
          error.category
      end
    end

    idle = {outcome.(admit), outcome.(reject)}
    pids = hogs(2 * System.schedulers_online())

    loaded =
      try do
        {outcome.(admit), outcome.(reject)}
      after
        Enum.each(pids, &Process.exit(&1, :kill))
      end

    assert idle == {:admitted, :compile_budget}
    assert loaded == idle
  end

  test "every guest apply site shares one snapshot dispatcher" do
    source = """
    -module(counter).
    -export([result/1]).

    result(_) ->
      {ok, Server} = gen_server:start(counter, 1, []),
      R = gen_server:call(Server, get),
      gen_server:stop(Server),
      R.

    init(Value) -> {ok, Value}.
    handle_call(get, _From, State) -> {reply, State, State}.
    handle_cast(_Msg, State) -> {noreply, State}.
    """

    {:ok, program} =
      Hyperlang.Test.program(source, %{
        capabilities: %{gen_server: true},
        terms: %{public: :erlang, allowed_atoms: [:ok, :get, :reply, :noreply]},
        modules: %{enabled: true, guest_modules: ["counter"]}
      })

    forms = program.artifact.forms

    assert [{:function, _, :safe_snapshot_apply, 4, clauses}] =
             Enum.filter(forms, &match?({:function, _, :safe_snapshot_apply, _, _}, &1))

    assert length(clauses) > 100
    assert largest_case(forms) < 100
  end

  defp largest_case({:case, _anno, _expr, clauses} = term),
    do: max(length(clauses), term |> Tuple.to_list() |> largest_case())

  defp largest_case(term) when is_tuple(term), do: term |> Tuple.to_list() |> largest_case()

  defp largest_case(term) when is_list(term),
    do: Enum.reduce(term, 0, &max(largest_case(&1), &2))

  defp largest_case(_term), do: 0
end
