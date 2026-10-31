defmodule DurableActorTest do
  # A Durable Object approximated by the parts Hyperlang ships: the
  # `Hyperlang.Actor` callback actor (one callback at a time is the input
  # gate), a host storage binding passed in the spec (a write-through call
  # that returns only after the write landed is the output gate), and
  # `init/1` reloading from storage (eviction and restart need no
  # passivation hooks).
  use ExUnit.Case, async: false

  import Hyperlang.Test

  defmodule Storage do
    @behaviour Hyperlang.Binding

    @impl true
    def exports, do: [get: 2, put: 2]

    @impl true
    def call(%{table: table, ns: ns}, :get, [key, default]) do
      case :ets.lookup(table, {ns, key}) do
        [{_key, value}] -> value
        [] -> default
      end
    end

    def call(%{table: table, ns: ns, log: log}, :put, [key, value]) do
      :ets.insert(log, {System.unique_integer([:monotonic]), :enter, self()})
      # Widen the window in which an interleaved callback would show up.
      Process.sleep(2)
      true = :ets.insert(table, {{ns, key}, value})
      :ets.insert(log, {System.unique_integer([:monotonic]), :exit, self()})
      :ok
    end
  end

  @source """
  -module(counter).
  -behaviour(gen_server).
  -export([init/1, handle_call/3, handle_cast/2]).

  init(_Id) -> {ok, storage:get(<<"n">>, 0)}.

  handle_call(<<"inc">>, _From, N) ->
      ok = storage:put(<<"n">>, N + 1),
      {reply, N + 1, N + 1};
  handle_call(<<"get">>, _From, N) ->
      {reply, N, N};
  handle_call(<<"inc_then_crash">>, _From, N) ->
      ok = storage:put(<<"n">>, N + 1),
      erlang:error(boom).

  handle_cast(<<"spin">>, N) -> spin(), {noreply, N}.

  spin() -> spin().
  """

  setup do
    table = :ets.new(:durable_actor_storage, [:public, :set])
    log = :ets.new(:durable_actor_log, [:public, :ordered_set])

    program =
      program!(@source,
        result: %{name: "init", arity: 1},
        terms: %{public: :erlang, allowed_atoms: [:ok, :boom]},
        bindings: %{"storage" => Storage}
      )

    %{program: program, table: table, log: log}
  end

  defp start(program, ctx, ns, policy \\ %{}) do
    storage = {Storage, %{table: ctx.table, log: ctx.log, ns: ns}}
    start_actor!(program, ns, bindings: %{"storage" => storage}, policy: policy)
  end

  test "callbacks are serialized: concurrent calls never interleave", ctx do
    pid = start(ctx.program, ctx, "counter-a")

    results =
      1..20
      |> Enum.map(fn _ -> Task.async(fn -> GenServer.call(pid, "inc") end) end)
      |> Enum.map(&Task.await/1)

    assert Enum.sort(results) == Enum.to_list(1..20)
    assert GenServer.call(pid, "get") == 20

    phases = ctx.log |> :ets.tab2list() |> Enum.map(fn {_seq, phase, _pid} -> phase end)
    assert phases == List.duplicate([:enter, :exit], 20) |> List.flatten()

    GenServer.stop(pid)
  end

  test "state survives stop and restart through storage reload in init/1", ctx do
    pid = start(ctx.program, ctx, "counter-b")
    assert 1 = GenServer.call(pid, "inc")
    assert 2 = GenServer.call(pid, "inc")
    :ok = GenServer.stop(pid)

    restarted = start(ctx.program, ctx, "counter-b")
    assert GenServer.call(restarted, "get") == 2
    assert 3 = GenServer.call(restarted, "inc")

    other = start(ctx.program, ctx, "counter-c")
    assert GenServer.call(other, "get") == 0

    Enum.each([restarted, other], &GenServer.stop/1)
  end

  test "a crash mid-callback leaves storage holding exactly what the binding wrote", ctx do
    pid = start(ctx.program, ctx, "counter-d")
    assert 1 = GenServer.call(pid, "inc")
    monitor = Process.monitor(pid)

    assert {{:hyperlang, %{category: _category}}, _call} =
             catch_exit(GenServer.call(pid, "inc_then_crash"))

    assert_receive {:DOWN, ^monitor, :process, ^pid, {:hyperlang, _reason}}

    # The write before the crash completed, so it is durable; the lost
    # in-memory state was only a cache of it.
    assert :ets.lookup(ctx.table, {"counter-d", "n"}) == [{{"counter-d", "n"}, 2}]

    restarted = start(ctx.program, ctx, "counter-d")
    assert GenServer.call(restarted, "get") == 2
    GenServer.stop(restarted)
  end

  test "closing its scope terminates an engine-owned spinning actor", ctx do
    scope = make_ref()
    :ok = Hyperlang.Scope.configure(scope, %{})

    pid =
      start(ctx.program, ctx, "scope-owned", %{
        scope: scope,
        max_reductions: nil,
        wall_ms: :infinity
      })

    monitor = Process.monitor(pid)
    GenServer.cast(pid, "spin")

    Enum.reduce_while(1..500, :ok, fn _, _ ->
      if Hyperlang.Scope.stats(scope).runnable == 1,
        do: {:halt, :ok},
        else:
          (
            Process.sleep(2)
            {:cont, :ok}
          )
    end)

    assert Hyperlang.Scope.stats(scope).runnable == 1
    Hyperlang.Scope.close(scope)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 2000
  end

  test "limits from the spec policy are enforced on the actor without host plumbing", ctx do
    # Per-callback max_reductions: a spinning callback is stopped.
    pid = start(ctx.program, ctx, "counter-e", %{max_reductions: 200_000})
    assert 1 = GenServer.call(pid, "inc")
    monitor = Process.monitor(pid)
    GenServer.cast(pid, "spin")
    assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, 2_000
    assert match?({:hyperlang_limit, _}, reason) or match?({:hyperlang, _}, reason)

    # Actor-lifetime ceiling across callbacks.
    pid = start(ctx.program, ctx, "counter-f", %{max_reductions: nil, ceiling: 100_000})
    monitor = Process.monitor(pid)
    GenServer.cast(pid, "spin")
    assert_receive {:DOWN, ^monitor, :process, ^pid, {:hyperlang_limit, :ceiling}}, 2_000

    # The storage write that preceded the spin is intact.
    assert :ets.lookup(ctx.table, {"counter-e", "n"}) == [{{"counter-e", "n"}, 1}]
  end
end
