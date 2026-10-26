ExUnit.configure(
  exclude:
    Enum.uniq(
      [isolation_stress: true, isolation_finding: true] ++ ExUnit.configuration()[:exclude]
    )
)

Code.require_file("support/probe.ex", __DIR__)
Code.require_file("support/round2.ex", __DIR__)

defmodule Hyperlang.Isolation.Round2FindingsTest do
  use ExUnit.Case, async: false
  alias Hyperlang.Isolation.{Round2Peer, Round2Probe}

  @moduletag timeout: 90_000

  test "R2-1 same-scope nested runs borrow ancestor permits" do
    result = Round2Probe.nested_admission()

    for row <- result.same_scope do
      assert row.outcome == {:ok, row.depth}
      assert row.time_us < 30_000

      assert row.stats.runs == 0
      assert row.stats.queued == 0
      assert row.stats.members == 0
    end

    for row <- result.other_scope do
      assert row.outcome == {:ok, row.depth}
    end

    save("nested_admission", result)
  end

  test "R2-2 closing an in-flight scope reports scope termination" do
    result = Round2Probe.scope_lifecycle()
    assert result.first == {:error, :busy, "scope_closed"}
    assert result.second == {:error, :busy, "scope_closed"}
    refute result.broker_alive
    refute result.timer_retained
    assert result.stats_after == nil
    assert result.reused == {:ok, 1}
    save("scope_close_classification", result)
  end

  test "R2-3 slow timer delivery does not block an unrelated scope" do
    assert %{result: result} = Round2Peer.run(:timer_head_of_line)
    save("timer_head_of_line", result)
    assert result.slow_started
    # Every victim timer was delivered while the slow scope's resolver was held.
    assert result.victim_delivered_while_slow_held
    # Delay added by Hyperlang delivery over a bare BEAM timer of the same delay.
    assert result.victim_excess_us < 5_000
  end

  defp save(name, data) do
    if dir = System.get_env("ISOLATION_EVIDENCE_DIR") do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, name <> ".etf"), :erlang.term_to_binary(data))
    end
  end
end
