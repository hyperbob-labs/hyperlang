ExUnit.configure(
  exclude:
    Enum.uniq(
      [isolation_stress: true, isolation_finding: true] ++ ExUnit.configuration()[:exclude]
    )
)

Code.require_file("support/probe.ex", __DIR__)

defmodule Hyperlang.Isolation.SharedProgramSoakTest do
  use ExUnit.Case, async: false

  # 10,000 distinct programs, each loaded, run as an actor and dropped, in a
  # code window far smaller than the program count. The shared program
  # records and every per-actor structure must stay bounded by the window
  # and return to their baseline, and no code-slot pin may outlive its actor.

  @moduletag skip: not Hyperlang.Isolation.Peer.stress_enabled?(__ENV__.file)
  @moduletag :isolation_stress
  @moduletag timeout: 1_800_000

  @window 8
  @programs 10_000

  defp program(salt) do
    source = """
    -module(counter).
    -behaviour(gen_server).
    -export([init/1, handle_call/3]).
    init(Start) -> {ok, Start + #{salt} - #{salt}}.
    handle_call(<<"inc">>, _From, N) -> {reply, N + 1, N + 1}.
    """

    {:ok, program} =
      Hyperlang.program(%{
        entry: "counter.erl",
        files: %{"counter.erl" => source},
        manifest: %{
          code_pool: %{size: @window},
          result: %{name: "init", arity: 1},
          terms: %{public: :erlang, allowed_atoms: [:ok]}
        }
      })

    program
  end

  defp records do
    for {{{Hyperlang.CodeServer, :loaded_artifact}, hash}, _slot} <- :persistent_term.get(),
        do: hash
  end

  defp footprint do
    scope = :sys.get_state(Hyperlang.Scope)
    limits = :sys.get_state(Hyperlang.Limits)

    %{
      scopes: map_size(scope.scopes),
      scope_monitors: map_size(scope.monitors),
      leases: map_size(scope.leases),
      runtime_permits: map_size(scope.runtime_permits),
      limits_groups: map_size(limits.groups),
      limits_monitors: map_size(limits.monitors),
      channel_rows: :ets.info(:hyperlang_scope_channels, :size),
      policy_rows: :ets.info(:hyperlang_scope_policies, :size),
      ets_tables: length(:ets.all()),
      processes: length(Process.list())
    }
  end

  defp stable_footprint do
    first = footprint()
    Process.sleep(20)
    if footprint() == first, do: first, else: stable_footprint()
  end

  defp settle(baseline, deadline) do
    current = footprint()

    cond do
      current == baseline -> :ok
      System.monotonic_time(:millisecond) > deadline -> assert current == baseline
      true -> Process.sleep(10) && settle(baseline, deadline)
    end
  end

  test "10,000 distinct programs leave only a window of shared records" do
    warm = program(0)
    {:ok, pid} = GenServer.start(Hyperlang.Actor, {%{}, warm, 0})
    GenServer.stop(pid)
    baseline = stable_footprint()
    before = records()

    hashes =
      for salt <- 1..@programs do
        program = program(salt)
        {:ok, pid} = GenServer.start(Hyperlang.Actor, {%{}, program, salt})
        assert GenServer.call(pid, "inc") == salt + 1
        GenServer.stop(pid)
        program.content_hash
      end

    after_records = records()
    assert length(after_records) - length(before) <= @window
    live = MapSet.new(after_records)
    assert Enum.count(hashes, &MapSet.member?(live, &1)) <= @window

    code = :sys.get_state(Hyperlang.CodeServer)
    assert code.pins == %{} and code.scope_pins == %{}
    assert :ets.info(:hyperlang_code_pins, :size) == 0
    assert Enum.all?(code.slots, fn {_id, slot} -> slot.pins == 0 end)

    settle(baseline, System.monotonic_time(:millisecond) + 10_000)
  end

  test "an actor's pin survives a CodeServer restart" do
    program = program(-1)
    {:ok, pid} = GenServer.start(Hyperlang.Actor, {%{}, program, 41})
    {:ok, %{module: module}} = Hyperlang.CodeServer.load(program)
    assert GenServer.call(pid, "inc") == 42

    old = Process.whereis(Hyperlang.CodeServer)
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :killed}, 5_000

    Enum.find_value(1..500, fn _ ->
      new = Process.whereis(Hyperlang.CodeServer)
      if is_pid(new) and new != old, do: true, else: Process.sleep(10) && nil
    end)

    assert %{^pid => _} = :sys.get_state(Hyperlang.CodeServer).pins

    # Churn the whole window: the restored pin keeps the actor's slot.
    for salt <- 1..(@window * 3) do
      p = program(-100 - salt)
      {:ok, other} = GenServer.start(Hyperlang.Actor, {%{}, p, salt})
      GenServer.stop(other)
    end

    assert {:ok, %{module: ^module}} = Hyperlang.CodeServer.load(program)
    assert GenServer.call(pid, "inc") == 43
    GenServer.stop(pid)

    Enum.find_value(1..500, fn _ ->
      if :sys.get_state(Hyperlang.CodeServer).pins == %{},
        do: true,
        else: Process.sleep(10) && nil
    end)

    assert :ets.info(:hyperlang_code_pins, :size) == 0
    assert :ok = Hyperlang.CodeServer.release(program.content_hash)
    assert :code.is_loaded(module) == false
  end
end
