ExUnit.configure(
  exclude:
    Enum.uniq(
      [isolation_stress: true, isolation_finding: true] ++ ExUnit.configuration()[:exclude]
    )
)

Code.require_file("support/probe.ex", __DIR__)
Code.require_file("support/round2.ex", __DIR__)

defmodule Hyperlang.Isolation.Round2StressTest do
  use ExUnit.Case, async: false
  alias Hyperlang.Isolation.{Peer, Round2Peer}

  @moduletag skip: not Peer.stress_enabled?(__ENV__.file)
  @moduletag :isolation_stress
  @moduletag timeout: 600_000

  test "nested parent death and scope owner/name lifecycle release all state" do
    assert %{result: %{runs: 0, queued: 0, members: 0}} =
             Round2Peer.run(:nested_parent_kill)

    assert %{result: %{iterations: 100, failures: []} = reuse} =
             Round2Peer.run(:owner_reuse_race, [100])

    assert %{result: %{iterations: 100, outcomes: outcomes} = races} =
             Round2Peer.run(:close_configure_race, [100])

    assert Enum.all?(outcomes, &(&1.configured == :ok and &1.closed == :ok))
    save("scope_owner_reuse", %{reuse: reuse, close_configure: races})
  end

  test "timer server handles many scopes expiry storms and cancel/read races" do
    assert %{result: result} = Round2Peer.run(:timer_stress, [32, 128])
    assert result.timers == 4_096
    assert result.race_results_valid
    assert result.lateness_max_us < 1_000_000
    save("timer_stress", result)
  end

  test "100k mixed fresh-caller runs have no retained resource slope" do
    session = Round2Peer.start()

    try do
      assert %{result: before} = Round2Peer.call(session, :soak_start)

      batches =
        for batch <- 1..100 do
          assert %{result: result} = Round2Peer.call(session, :soak_batch, [batch], 30_000)
          assert result.count == 1_000
          assert result.outcomes[{:normal, :ok}] == 940
          assert result.outcomes[{:wall, :timeout}] == 10
          assert result.outcomes[{:reductions, :reduction_watchdog}] == 10
          assert result.outcomes[{:heap, :heap}] == 10
          assert result.outcomes[{:crash, :runtime}] == 10
          assert result.outcomes[{:binding, :import}] == 10
          assert result.outcomes[{:busy, :busy}] == 10
          assert Enum.sum(Map.values(result.outcomes)) == 1_000
          result
        end

      assert %{result: after_} = Round2Peer.call(session, :soak_finish)
      assert Enum.sum(Enum.map(batches, & &1.count)) == 100_000
      assert after_.groups == 0
      assert after_.timers == 0
      assert after_.scopes == 0
      assert after_.channel_aliases == 0
      assert after_.broker_aliases == 0
      assert after_.broker_ref_index == 0
      assert after_.scope_leases == 0
      assert after_.scope_lease_owners == 0
      assert after_.runtime_scopes == 0
      assert after_.scope_queue == 0
      assert after_.runtime_permits == 0
      assert after_.runtime_queue == 0
      assert after_.runnable == 0
      assert after_.background_runnable == 0
      assert after_.scope_monitors == 0
      assert after_.limits_monitors == 0
      assert after_.limits_active == 0

      samples = [before | Enum.map(batches, & &1.snapshot)] ++ [after_]

      save("soak_100k", %{
        before: before,
        batches: batches,
        after: after_,
        slopes: slopes(samples),
        warm_slopes: regression_slopes(batches |> Enum.drop(9) |> Enum.map(& &1.snapshot))
      })
    after
      Round2Peer.stop(session)
    end
  end

  test "durable actors serialize storage through crashes overload and killed callers" do
    assert %{result: result} = Round2Peer.run(:durable_actor_stress, [], timeout: 90_000)

    for row <- result.concurrent do
      assert row.ordered_values == Enum.to_list(1..25)
      assert row.stored == 25
    end

    assert result.crash_values == Enum.map(1..10, &{&1, &1})
    assert result.crash_reload == 10
    assert result.killed_caller_value == 1
    assert result.overload_values == Enum.to_list(1..200)
    assert result.overload_stored == 200
    assert result.max_mailbox > 0
    assert result.serialized_writes
    save("durable_actor_stress", result)
  end

  @tag :isolation_finding
  test "R2-4 measure latency reservation at 4, 16 and 64 tenants" do
    runtime_session = Peer.start(schedulers: 4)

    runtime_rows =
      try do
        for mode <- [:cpu, :memory, :compile], tenants <- [0, 4, 16, 64] do
          load_before = elem(System.cmd("uptime", []), 0)
          assert %{result: row} = Peer.call(runtime_session, :contention, [mode, tenants, true])
          assert row.outcomes == %{ok: 1_000}

          Map.merge(row, %{
            load_before: load_before,
            load_after: elem(System.cmd("uptime", []), 0)
          })
        end
      after
        Peer.stop(runtime_session)
      end

    extra_session = Round2Peer.start(schedulers: 4)

    extra_rows =
      try do
        for mode <- [:channel, :timer], tenants <- [0, 4, 16, 64] do
          load_before = elem(System.cmd("uptime", []), 0)
          assert %{result: row} = Round2Peer.call(extra_session, :noisy_extra, [mode, tenants])
          assert row.outcomes == %{ok: 1_000}

          Map.merge(row, %{
            load_before: load_before,
            load_after: elem(System.cmd("uptime", []), 0)
          })
        end
      after
        Round2Peer.stop(extra_session)
      end

    save("latency_4_16_64", runtime_rows ++ extra_rows)
    assert Enum.all?(runtime_rows, &is_integer(&1.p999_us))
    assert Enum.all?(extra_rows, &is_integer(&1.p999_us))

    # Admission correctness is asserted in the default suite. These shared-VM
    # tail measurements are evidence, not a hard real-time guarantee.
    for mode <- [:cpu, :channel] do
      rows = runtime_rows ++ extra_rows
      unloaded = Enum.find(rows, &(&1.mode == mode and &1.tenants == 0))
      loaded = Enum.find(rows, &(&1.mode == mode and &1.tenants == 64))

      assert loaded.p99_us <= unloaded.p99_us * 3

      IO.puts(
        "#{mode}64 p99/unloaded: #{loaded.p99_us}/#{unloaded.p99_us} = #{loaded.p99_us / unloaded.p99_us}"
      )
    end
  end

  @tag :isolation_finding
  test "R2-4 channel64 stays within three times unloaded in three fresh trials" do
    trials =
      for trial <- 1..3 do
        session = Round2Peer.start(schedulers: 4)

        try do
          load_before = elem(System.cmd("uptime", []), 0)
          assert %{result: unloaded} = Round2Peer.call(session, :noisy_extra, [:channel, 0])
          load_between = elem(System.cmd("uptime", []), 0)
          assert %{result: loaded} = Round2Peer.call(session, :noisy_extra, [:channel, 64])

          row = %{
            trial: trial,
            unloaded: unloaded,
            loaded: loaded,
            load_before: load_before,
            load_between: load_between,
            load_after: elem(System.cmd("uptime", []), 0)
          }

          save("channel64_trial_#{trial}", row)
          assert unloaded.outcomes == %{ok: 1000}
          assert loaded.outcomes == %{ok: 1000}
          row
        after
          Round2Peer.stop(session)
        end
      end

    save("channel64_trials", trials)
    for row <- trials, do: assert(row.loaded.p99_us <= row.unloaded.p99_us * 3)
  end

  test "five fresh 16-tenant heap trials and throttle-to-kill reaction distributions" do
    heap_trials =
      for trial <- 1..5 do
        session = Peer.start(schedulers: 4)

        try do
          assert %{result: row} = Peer.call(session, :contention, [:memory, 16, true])
          Map.put(row, :trial, trial)
        after
          Peer.stop(session)
        end
      end

    reaction_session = Round2Peer.start(schedulers: 4)

    reactions =
      try do
        for mode <- [:cpu, :churn, :compile] do
          assert %{result: row} = Round2Peer.call(reaction_session, :throttle_reaction, [mode])
          assert row.throttle_us > 0
          assert row.kill_us > row.throttle_us
          assert row.final.killed?
          row
        end
      after
        Round2Peer.stop(reaction_session)
      end

    save("heap_trials_and_reactions", %{heap_trials: heap_trials, reactions: reactions})
  end

  test "seeded randomized lifecycle interleavings preserve invariants" do
    seeds = [20_261_024, 20_261_025, 20_261_026, 20_261_027, 20_261_028]
    assert %{result: result} = Round2Peer.run(:randomized, [seeds, 400], timeout: 120_000)
    assert result.failures == []
    assert result.final.groups == 0
    assert result.final.timers == 0
    assert result.final.scopes == 0
    assert result.final.channel_aliases == 0
    assert result.final.broker_aliases == 0
    assert result.final.broker_ref_index == 0
    assert result.final.scope_leases == 0
    assert result.final.scope_lease_owners == 0
    assert result.final.runtime_scopes == 0
    assert result.final.scope_queue == 0
    assert result.final.runtime_permits == 0
    assert result.final.runtime_queue == 0
    assert result.final.runnable == 0
    assert result.final.background_runnable == 0
    assert result.final.scope_monitors == 0
    assert result.final.limits_monitors == 0
    assert result.final.limits_active == 0
    save("randomized_interleavings", result)
  end

  defp slopes(samples) do
    first = hd(samples)
    last = List.last(samples)
    runs = max(1, (length(samples) - 2) * 1_000)

    Map.new(
      [
        atoms: {first.atoms, last.atoms},
        processes: {first.processes, last.processes},
        ets: {first.ets, last.ets},
        groups: {first.groups, last.groups},
        timers: {first.timers, last.timers},
        scopes: {first.scopes, last.scopes},
        scope_monitors: {first.scope_monitors, last.scope_monitors},
        limits_monitors: {first.limits_monitors, last.limits_monitors},
        binary_bytes: {first.memory.binary, last.memory.binary},
        total_bytes: {first.memory.total, last.memory.total}
      ],
      fn {key, {a, b}} -> {key, %{delta: b - a, per_run: (b - a) / runs}} end
    )
  end

  defp regression_slopes(samples) do
    metrics = %{
      atoms: & &1.atoms,
      processes: & &1.processes,
      ets: & &1.ets,
      ets_bytes: & &1.memory.ets,
      binary_bytes: & &1.memory.binary,
      process_bytes: & &1.memory.processes,
      total_bytes: & &1.memory.total,
      timers: & &1.timers,
      scopes: & &1.scopes,
      scope_leases: & &1.scope_leases,
      scope_queue: & &1.scope_queue,
      scope_monitors: & &1.scope_monitors,
      limits_monitors: & &1.limits_monitors,
      limits_active: & &1.limits_active
    }

    Map.new(metrics, fn {name, value} ->
      points =
        samples
        |> Enum.with_index(10)
        |> Enum.map(fn {sample, batch} ->
          {batch * 1_000, value.(sample)}
        end)

      {name, linear_slope(points)}
    end)
  end

  defp linear_slope(points) do
    n = length(points)
    sum_x = Enum.sum(Enum.map(points, &elem(&1, 0)))
    sum_y = Enum.sum(Enum.map(points, &elem(&1, 1)))
    sum_xx = Enum.sum(Enum.map(points, fn {x, _y} -> x * x end))
    sum_xy = Enum.sum(Enum.map(points, fn {x, y} -> x * y end))
    (n * sum_xy - sum_x * sum_y) / (n * sum_xx - sum_x * sum_x)
  end

  defp save(name, data) do
    if dir = System.get_env("ISOLATION_EVIDENCE_DIR") do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, name <> ".etf"), :erlang.term_to_binary(data))
    end
  end
end
