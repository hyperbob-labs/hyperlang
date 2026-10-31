defmodule SharedProgramTest do
  use ExUnit.Case, async: false

  # Shared state behind cheap actors and calls:
  #
  #   * a loaded program's canonical value is one `:persistent_term` literal
  #     on its code slot record; actors and runs reference it, they do not
  #     copy it, and it lives exactly as long as the slot;
  #   * every process's top-level in-caller runs share one Limits group and
  #     slot, whose per-run state is reset by generation;
  #   * a scope's channel counters are one row of the shared channel table.

  alias Hyperlang.{Limits, Scope}

  @counter """
  -module(counter).
  -behaviour(gen_server).
  -export([init/1, handle_call/3]).
  init(Start) -> {ok, Start}.
  handle_call(<<"inc">>, _From, N) -> {reply, N + 1, N + 1};
  handle_call({<<"spin">>, Count}, _From, N) -> {reply, spin(Count), N}.
  spin(0) -> done;
  spin(Count) -> spin(Count - 1).
  """

  @actor_manifest %{
    result: %{name: "init", arity: 1},
    terms: %{public: :erlang, allowed_atoms: [:ok, :done]}
  }

  defp counter_program(salt \\ 0, manifest \\ @actor_manifest) do
    source =
      String.replace(
        @counter,
        "init(Start) -> {ok, Start}.",
        "init(Start) -> {ok, Start + #{salt} - #{salt}}."
      )

    {:ok, program} =
      Hyperlang.program(%{
        entry: "counter.erl",
        files: %{"counter.erl" => source},
        manifest: manifest
      })

    program
  end

  defp start_actor(program, start, policy \\ %{}) do
    {:ok, pid} = GenServer.start(Hyperlang.Actor, {%{policy: policy}, program, start})
    pid
  end

  defp loaded_records do
    for {{{Hyperlang.CodeServer, :loaded_artifact}, hash}, %Hyperlang.CodeServer.Slot{} = slot} <-
          :persistent_term.get(),
        do: {hash, slot}
  end

  defp wait(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn -> fun.() end)
    |> Enum.find(fn
      true ->
        true

      _ ->
        if System.monotonic_time(:millisecond) > deadline,
          do: flunk("condition not reached"),
          else: Process.sleep(5) && false
    end)
  end

  # Every piece of engine state an actor or a run can create.
  defp engine_footprint do
    scope = :sys.get_state(Scope)
    limits = :sys.get_state(Limits)
    code = :sys.get_state(Hyperlang.CodeServer)

    %{
      scopes: map_size(scope.scopes),
      scope_monitors: map_size(scope.monitors),
      leases: map_size(scope.leases),
      lease_owners: map_size(scope.lease_owners),
      runtime_permits: map_size(scope.runtime_permits),
      runtime_scopes: map_size(scope.runtime_scopes),
      limits_groups: map_size(limits.groups),
      limits_monitors: map_size(limits.monitors),
      limits_active: MapSet.size(limits.active),
      code_artifacts: map_size(code.artifacts),
      code_pins: map_size(code.pins),
      scope_pins: map_size(code.scope_pins),
      pin_rows: :ets.info(:hyperlang_code_pins, :size),
      persistent_terms: length(:persistent_term.get()),
      channel_rows: :ets.info(:hyperlang_scope_channels, :size),
      policy_rows: :ets.info(:hyperlang_scope_policies, :size),
      runtime_slots: :ets.info(:hyperlang_runtime_slots, :size),
      ets_tables: length(:ets.all()),
      processes: length(Process.list())
    }
  end

  # Asynchronous cleanup (monitors, casts) settles within the wait.
  defp settled_footprint do
    first = engine_footprint()
    Process.sleep(20)
    if engine_footprint() == first, do: first, else: settled_footprint()
  end

  defp assert_footprint_returns(baseline) do
    deadline = System.monotonic_time(:millisecond) + 10_000
    await_footprint(baseline, deadline)
  end

  defp await_footprint(baseline, deadline) do
    current = engine_footprint()

    cond do
      current == baseline -> :ok
      System.monotonic_time(:millisecond) > deadline -> assert current == baseline
      true -> Process.sleep(10) && await_footprint(baseline, deadline)
    end
  end

  describe "program literal" do
    test "actors reference the program value instead of copying it" do
      program = counter_program()
      program_bytes = :erts_debug.flat_size(program) * :erlang.system_info(:wordsize)
      assert program_bytes > 20_000

      actors = for start <- 1..20, do: start_actor(program, start)

      for {pid, start} <- Enum.zip(actors, 1..20) do
        assert GenServer.call(pid, "inc") == start + 1
        :erlang.garbage_collect(pid)
        {:memory, bytes} = Process.info(pid, :memory)
        assert bytes < 16_384, "an idle actor holds #{bytes} bytes"
      end

      Enum.each(actors, &GenServer.stop/1)
    end

    test "the record lives exactly as long as the code slot" do
      program = counter_program(1)
      :ok = Hyperlang.load(program)
      hash = program.content_hash

      assert [{^hash, %{program: shared}}] =
               Enum.filter(loaded_records(), fn {h, _} -> h == hash end)

      assert shared == program
      assert :ok = Hyperlang.CodeServer.release(hash)
      refute Enum.any?(loaded_records(), fn {h, _} -> h == hash end)

      # The next use loads the program again and publishes a new record.
      assert {:ok, {:ok, 7}, _meta} = Hyperlang.run(%{}, program, :entry, [7])
      assert Enum.any?(loaded_records(), fn {h, _} -> h == hash end)
    end

    test "an idle actor pins its slot: no reuse, no copy onto its heap" do
      window = 3
      manifest = Map.put(@actor_manifest, :code_pool, %{size: window})
      program = counter_program(2, manifest)
      pid = start_actor(program, 10)
      {:ok, %{module: module}} = Hyperlang.CodeServer.load(program)
      assert GenServer.call(pid, "inc") == 11
      :erlang.garbage_collect(pid)
      {:memory, shared_bytes} = Process.info(pid, :memory)

      # Oversubscribe the window: the other slots are reclaimed and reused,
      # the actor's pinned slot and its record stay.
      for salt <- 100..(100 + window * 2),
          do: :ok = Hyperlang.load(counter_program(salt, manifest))

      assert Enum.any?(loaded_records(), fn {h, _} -> h == program.content_hash end)
      assert {:ok, %{module: ^module}} = Hyperlang.CodeServer.load(program)
      assert :code.is_loaded(module) != false

      :erlang.garbage_collect(pid)
      {:memory, bytes} = Process.info(pid, :memory)
      assert bytes < shared_bytes + 4_096, "idle actor grew from #{shared_bytes} to #{bytes}"

      assert GenServer.call(pid, "inc") == 12
      GenServer.stop(pid)
    end

    test "records stay bounded by the code window over many distinct programs" do
      window = 8
      manifest = Map.put(@actor_manifest, :code_pool, %{size: window})
      before = length(loaded_records())

      hashes =
        for salt <- 1..300 do
          program = counter_program(10_000 + salt, manifest)
          pid = start_actor(program, salt)
          assert GenServer.call(pid, "inc") == salt + 1
          GenServer.stop(pid)
          program.content_hash
        end

      records = loaded_records()
      assert length(records) - before <= window
      live = MapSet.new(records, &elem(&1, 0))
      assert Enum.count(hashes, &MapSet.member?(live, &1)) <= window
    end

    test "guest code cannot reach the shared records or another program's module" do
      for source <- [
            "result(_) -> persistent_term:get().\n",
            "result(_) -> erlang:get_module_info(hyperlang_slot_000001).\n",
            "result(_) -> hyperlang_slot_000001:module_info().\n"
          ] do
        assert {:error, [%{category: :verify} | _]} = Hyperlang.Test.program(source, %{})
      end
    end
  end

  describe "lifecycle" do
    test "10,000 actor start/stop cycles leave no engine state behind" do
      program = counter_program(3)
      warm = start_actor(program, 0)
      assert GenServer.call(warm, "inc") == 1
      GenServer.stop(warm)
      baseline = settled_footprint()

      for start <- 1..10_000 do
        pid = start_actor(program, start)
        assert GenServer.call(pid, "inc") == start + 1
        GenServer.stop(pid)
      end

      assert_footprint_returns(baseline)
    end

    test "a host's in-caller limits group and default scope go with the host" do
      program = counter_program(4)
      baseline = settled_footprint()
      parent = self()

      # The host's first scope activity is the code load of its first run:
      # CodeServer asks for the host's default scope before the host does.
      host =
        spawn(fn ->
          for n <- 1..50 do
            {:ok, {:ok, ^n}, _meta} =
              Hyperlang.run(%{policy: %{run_in_caller?: true}}, program, :entry, [n])
          end

          send(parent, :done)
          receive do: (:exit -> :ok)
        end)

      assert_receive :done, 5_000
      assert map_size(:sys.get_state(Limits).groups) == baseline.limits_groups + 1
      assert Scope.stats({Scope, host}) != nil
      send(host, :exit)
      wait(fn -> not Process.alive?(host) end)
      assert :ok = Hyperlang.CodeServer.release(program.content_hash)
      assert_footprint_returns(baseline)
    end
  end

  describe "process limits group" do
    test "no run's reductions count toward the next run" do
      program = counter_program(5)
      # Each call spins well past half the ceiling and spans several Limits
      # ticks, so a carried-over usage would exceed the ceiling.
      pid = start_actor(program, 0, %{max_reductions: 40_000_000})

      for _ <- 1..4 do
        assert GenServer.call(pid, {"spin", 3_000_000}, 30_000) == :done
      end

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "a callback over its own ceiling still fails" do
      program = counter_program(6)
      pid = start_actor(program, 0, %{max_reductions: 200_000})
      ref = Process.monitor(pid)
      catch_exit(GenServer.call(pid, {"spin", 5_000_000}, 30_000))
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 30_000
    end

    test "a child of a finished run is never admitted to the next run" do
      group = Limits.in_caller_group(%{})
      generation = Limits.arm(group, self(), %{})
      assert :ok = Limits.disarm(group, self(), generation)

      late = spawn(fn -> Process.sleep(:infinity) end)
      assert {:error, :closed} = Limits.attach(group, late, %{spawned?: true})
      assert :ok = Limits.delete(group)

      next = Limits.in_caller_group(%{})
      assert next.id == group.id
      next_generation = Limits.arm(next, self(), %{})
      assert next_generation > generation
      assert {:error, :closed} = Limits.attach(group, late, %{spawned?: true})

      child = spawn(fn -> Process.sleep(:infinity) end)
      ref = Process.monitor(child)
      assert :ok = Limits.attach(next, child, %{spawned?: true})
      assert :ok = Limits.disarm(next, self(), next_generation)
      assert :ok = Limits.delete(next)

      # `delete/1` returns after the kill signal to the run's child is sent.
      assert_receive {:DOWN, ^ref, :process, ^child, :killed}, 1_000
      Process.exit(late, :kill)
    end

    test "max_procs and the child count are per run" do
      group = Limits.in_caller_group(%{max_procs: 1})
      generation = Limits.arm(group, self(), %{max_procs: 1})
      first = spawn(fn -> Process.sleep(:infinity) end)
      second = spawn(fn -> Process.sleep(:infinity) end)
      assert :ok = Limits.attach(group, first, %{spawned?: true})
      assert {:error, :eagain} = Limits.attach(group, second, %{spawned?: true})
      assert :ok = Limits.disarm(group, self(), generation)
      assert :ok = Limits.delete(group)
      wait(fn -> not Process.alive?(first) end)

      next = Limits.in_caller_group(%{max_procs: 1})
      next_generation = Limits.arm(next, self(), %{max_procs: 1})
      assert :ok = Limits.attach(next, second, %{spawned?: true})
      assert :ok = Limits.disarm(next, self(), next_generation)
      assert :ok = Limits.delete(next)
      wait(fn -> not Process.alive?(second) end)
    end

    test "the run's own wall timer kills the run or records the expiry" do
      parent = self()

      killed =
        spawn(fn ->
          group = Limits.in_caller_group(%{})
          _generation = Limits.arm(group, self(), %{wall_ms: 20})
          send(parent, :armed)
          Process.sleep(:infinity)
        end)

      ref = Process.monitor(killed)
      assert_receive :armed
      assert_receive {:DOWN, ^ref, :process, ^killed, {:hyperlang_limit, :wall_ms}}, 2_000

      # A caller-supplied kill means record only: the run sees the fault.
      group = Limits.in_caller_group(%{})
      generation = Limits.arm(group, self(), %{wall_ms: 20, kill: fn _pid, _reason -> :ok end})
      Process.sleep(80)
      assert {:error, :wall_ms} = Limits.disarm(group, self(), generation)
      assert :ok = Limits.delete(group)

      # A disarmed run's timer can never fire into a later run.
      next = Limits.in_caller_group(%{})
      next_generation = Limits.arm(next, self(), %{wall_ms: 1_000})
      Process.sleep(40)
      assert :ok = Limits.disarm(next, self(), next_generation)
      assert :ok = Limits.delete(next)
    end

    test "a nested in-caller run gets its own run group" do
      outer = Limits.in_caller_group(%{})
      inner = Limits.in_caller_group(%{})
      assert {:process, _, _} = outer.limits
      assert {pid, _limits} = inner.limits
      assert pid == self()
      assert inner.id != outer.id
      :ok = Limits.delete(inner)
      :ok = Limits.delete(outer)
    end
  end

  describe "spawned run limits" do
    test "a worker leaves its run group before the group is deleted" do
      program = counter_program(8)

      # Finishing without waiting must never kill the worker that sends it,
      # whether or not the reply has gone out yet.
      for n <- 1..2_000 do
        assert {:ok, {:ok, ^n}, _meta} = Hyperlang.run(%{}, program, :entry, [n])
      end
    end

    test "a worker over its ceiling or wall deadline returns the typed fault" do
      {:ok, spin} =
        Hyperlang.program(%{
          entry: "spin.erl",
          files: %{
            "spin.erl" =>
              "-module(spin).\n-export([result/1]).\nresult(_) -> spin().\nspin() -> spin().\n"
          }
        })

      assert {:error, %{category: :reduction_watchdog}} =
               Hyperlang.run(%{policy: %{max_reductions: 100_000}}, spin, :entry, [0])

      assert {:error, %{category: :timeout}} =
               Hyperlang.run(%{policy: %{max_reductions: nil, wall_ms: 30}}, spin, :entry, [0])
    end
  end

  describe "request ordering" do
    setup do
      scope = make_ref()
      :ok = Scope.configure(scope, %{})
      on_exit(fn -> Scope.close(scope) end)
      %{scope: scope}
    end

    test "a finished run's lease and membership are gone at the caller's next request",
         %{scope: scope} do
      program = counter_program(7)
      spec = %{policy: %{scope: scope, run_in_caller?: true}}

      for _ <- 1..200 do
        assert {:ok, {:ok, 1}, _meta} = Hyperlang.run(spec, program, :entry, [1])
        assert %{runs: 0, members: 0} = Scope.stats(scope)
      end

      for _ <- 1..200 do
        assert {:ok, {:ok, 1}, _meta} =
                 Hyperlang.run(%{policy: %{scope: scope}}, program, :entry, [1])

        assert %{runs: 0, members: 0} = Scope.stats(scope)
      end

      pid = start_actor(program, 0, %{scope: scope})

      for n <- 1..200 do
        assert GenServer.call(pid, "inc") == n
        assert %{runs: 0, members: 0} = Scope.stats(scope)
      end

      GenServer.stop(pid)
    end
  end

  describe "channel counters row" do
    test "a scope's row is removed when the scope closes or its controller dies" do
      scope = make_ref()
      :ok = Scope.configure(scope, %{})

      assert [{^scope, controller, %{channels: 0}}] =
               :ets.lookup(:hyperlang_scope_channels, scope)

      Scope.close(scope)
      assert [] = :ets.lookup(:hyperlang_scope_channels, scope)
      wait(fn -> not Process.alive?(controller) end)

      other = make_ref()
      :ok = Scope.configure(other, %{})
      [{^other, controller, _}] = :ets.lookup(:hyperlang_scope_channels, other)
      Process.exit(controller, :kill)
      wait(fn -> :ets.lookup(:hyperlang_scope_channels, other) == [] end)
      assert Scope.stats(other) == nil
    end
  end
end
