ExUnit.configure(
  exclude:
    Enum.uniq(
      [isolation_stress: true, isolation_finding: true] ++ ExUnit.configuration()[:exclude]
    )
)

Code.require_file("support/probe.ex", __DIR__)

defmodule Hyperlang.Isolation.StressTest do
  use ExUnit.Case, async: false
  @moduletag skip: not Hyperlang.Isolation.Peer.stress_enabled?(__ENV__.file)
  @moduletag :isolation_stress
  @moduletag timeout: 300_000
  alias Hyperlang.Isolation.Peer

  test "default actor callbacks are metered without host Limits wiring" do
    assert %{result: %{observed: r}} = Peer.run(:actor)
    assert %{time_us: us, reason: reason} = r.spin
    assert us < 2_000_000
    assert reason =~ "hyperlang_limit"
    assert Enum.all?(r.hostile_messages, &(&1 =~ "forbidden_term"))
  end

  test "local fun application has no public host fun ingress" do
    assert %{result: %{observed: r}} = Peer.run(:fun_admission)
    assert {:ok, 3, _} = r.local
    assert {:error, %{category: :input}} = r.external_input
    assert {:error, %{category: :import}} = r.external_import
  end

  test "concurrent manifests and binding states remain separate" do
    assert %{result: %{observed: r}} = Peer.run(:cache_isolation)
    assert r.different_manifests_differ
    assert r.cache_key_is_caller_owned
    assert r.per_tenant_values == Enum.map(1..40, &Integer.to_string/1)
  end

  test "source atom universes preserve tenant names without creating source atoms" do
    assert %{result: %{observed: r}} = Peer.run(:atoms)
    assert r.all_source_names_projected
    refute r.host_atom_exists
    assert r.configured_source_slots == 4096
  end

  test "file and table handles cannot be reused in the next run" do
    assert %{result: %{observed: r}} = Peer.run(:handles)
    assert {:error, %{category: :output}} = r.file_open
    assert {:ok, {:ok, data}, _} = r.file_internal
    assert data == ~c"tenant dat" or data == "tenant dat"
    refute match?({:ok, {:ok, "tenant data"}, _}, r.file_next_run)
    assert {:ok, _, _} = r.table_open
    refute match?({:ok, [], _}, r.table_next_run)
  end

  test "runtime limits terminate bounded heavy workloads and leave the peer responsive" do
    assert %{result: rows} = Peer.run(:limits)
    assert is_list(rows)
    by_name = Map.new(rows, &{&1.attack, &1})
    assert {:error, %{category: :reduction_watchdog}} = by_name["tail_cpu"].observed
    assert {:error, %{category: :timeout}} = by_name["wall"].observed

    for name <- [
          "non_tail",
          "map_growth",
          "tuple_growth",
          "stdout_flood",
          "deep_nesting",
          "binary_retention",
          "list_size",
          "binary_size"
        ] do
      assert {:error, _} = by_name[name].observed
      assert by_name[name].time_us < 2_000_000
    end
  end

  test "channel handles are isolated by host selected namespace" do
    assert %{result: %{observed: r}} = Peer.run(:channel_handles)
    assert {:ok, own, _} = r.own_scope
    assert own == r.handle
    refute r.other_scope == r.own_scope
  end

  test "max_procs limits guest children at admission" do
    assert %{result: %{observed: r}} = Peer.run(:spawn_quota)
    assert r.admitted_children == 2
    assert {:error, _} = r.result
    assert inspect(r.result) =~ "eagain"
  end

  test "compile source depth integer and wall budgets are bounded" do
    assert %{result: rows} = Peer.run(:compile_limits)

    for r <- rows do
      assert {:error, _} = r.observed
      assert r.time_us < 2_000_000
    end
  end

  @tag :isolation_finding
  test "mailbox channel table and start channel allocation is measured" do
    assert %{result: rows} = Peer.run(:allocation_floods)
    assert length(rows) == 4
    assert Enum.all?(rows, &(&1.time_us < 2_000_000))
    by_name = Map.new(rows, &{&1.attack, &1})
    assert by_name["channel_flood"].delta.processes <= 1026
    assert %{compile: :ok, run: {:ok, 1024, _}} = by_name["channel_flood"].observed
    assert %{compile: :ok, run: {:ok, 1024, _}} = by_name["startchan_flood"].observed
    assert inspect(by_name["mailbox_quota"].observed) =~ "mailbox_quota_exceeded"
    assert inspect(by_name["table_flood"].observed) =~ "max_tables"
  end

  @tag :isolation_finding
  test "node deltas over 10k ordinary and limit killed runs" do
    session = Peer.start()

    try do
      before_idle = Peer.call(session, :idle_limits)

      batches =
        for {mode, chunks, size} <- [
              {:normal, 7, 1000},
              {:wall, 10, 100},
              {:reductions, 10, 100},
              {:heap, 10, 100}
            ],
            _ <- 1..chunks do
          assert %{result: r} = envelope = Peer.call(session, :leaks_chunk, [mode, size])
          assert r.observed.count == size

          expected =
            case mode do
              :normal -> :ok
              :wall -> :timeout
              :reductions -> :reduction_watchdog
              :heap -> :heap
            end

          assert r.observed.outcomes == %{expected => size}
          Map.put(r, :peak_rss_kib, envelope.peak_rss_kib)
        end

      after_idle = Peer.call(session, :idle_limits)
      assert Enum.sum(Enum.map(batches, & &1.observed.count)) == 10_000
      assert List.last(batches).after.groups - hd(batches).before.groups == 0

      if dir = System.get_env("ISOLATION_EVIDENCE_DIR") do
        File.write!(Path.join(dir, "leaks_10000.etf"), :erlang.term_to_binary(batches))

        File.write!(
          Path.join(dir, "leak_tick_cost.etf"),
          :erlang.term_to_binary(%{before: before_idle, after: after_idle})
        )
      end
    after
      Peer.stop(session)
    end
  end

  @tag :isolation_finding
  test "victim p50 and p99 under 1 4 and 16 legitimate heavy tenants" do
    rows =
      for mode <- [:cpu, :memory, :atoms], n <- [0, 1, 4, 16] do
        assert %{result: r} = Peer.run(:noisy, [mode, n])
        assert r.observed.outcomes == %{ok: 300}
        r
      end

    if dir = System.get_env("ISOLATION_EVIDENCE_DIR") do
      File.write!(Path.join(dir, "noisy_neighbour.etf"), :erlang.term_to_binary(rows))
    end
  end
end
