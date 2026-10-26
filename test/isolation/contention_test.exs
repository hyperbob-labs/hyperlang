Code.require_file("support/probe.ex", __DIR__)

defmodule Hyperlang.Isolation.ContentionTest do
  use ExUnit.Case, async: false
  @moduletag skip: not Hyperlang.Isolation.Peer.stress_enabled?(__ENV__.file)
  @moduletag :isolation_stress
  @moduletag timeout: 300_000
  alias Hyperlang.Isolation.Peer

  defp measure(name, args) do
    session = Peer.start(schedulers: 4)

    try do
      Peer.call(session, name, args)
    after
      Peer.stop(session)
    end
  end

  test "exact wall timers measure 1ms deadline overshoot on an unloaded peer" do
    assert %{result: r} = measure(:wall_precision, [])
    assert r.outcomes == %{timeout: 1000}
    assert r.samples == 1000
    save("wall_precision", r)
  end

  test "noisy neighbour CPU heap and compile matrix measures scope policy off and on" do
    rows =
      for enabled <- [false, true], mode <- [:cpu, :memory, :compile], n <- [0, 1, 4, 16] do
        assert %{result: r} = measure(:contention, [mode, n, enabled])
        assert r.outcomes == %{ok: 1000}
        r
      end

    save("contention_matrix", rows)
  end

  test "one offending scope measures victim latency and confirmed throttle reaction" do
    rows =
      for mode <- [:cpu, :memory, :compile], enabled <- [false, true] do
        assert %{result: r} = measure(:contention, [mode, 1, enabled, true])
        assert r.outcomes == %{ok: 1000}

        if enabled do
          assert r.scope_stats.throttles > 0
          assert r.scope_stats.max_reaction_us > 0

          assert r.scope_stats.last_offence ==
                   %{cpu: :cpu, memory: :churn, compile: :compile}[mode]
        end

        r
      end

    save("offending_scope", rows)
  end

  test "native call interruption residue is measured with guest reachable larger terms" do
    assert %{result: rows} = measure(:native_interruptions, [])
    assert length(rows) == 6
    assert Enum.all?(rows, &(length(&1.samples) == 20))
    save("native_interruptions", rows)
  end

  defp save(name, data) do
    if dir = System.get_env("ISOLATION_EVIDENCE_DIR"),
      do: File.write!(Path.join(dir, name <> ".etf"), :erlang.term_to_binary(data))
  end
end
