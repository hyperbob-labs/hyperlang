ExUnit.configure(
  exclude:
    Enum.uniq(
      [isolation_stress: true, isolation_finding: true] ++ ExUnit.configuration()[:exclude]
    )
)

Code.require_file("support/probe.ex", __DIR__)

defmodule Hyperlang.Isolation.AtomPoolTest do
  use ExUnit.Case, async: false
  @moduletag skip: not Hyperlang.Isolation.Peer.stress_enabled?(__ENV__.file)
  @moduletag :isolation_stress
  @moduletag timeout: 45_000

  test "shared atom universe exhaustion is bounded and independent universes retain capacity" do
    assert %{result: %{observed: r}} = Hyperlang.Isolation.Peer.run(:atom_capacity)
    assert {:ok, 2500, _} = r.first
    assert {:error, [%{category: :verify, message: message}]} = r.second
    assert message =~ "atom universe exhausted"
    assert {:ok, 2500, _} = r.independent
    assert r.fixed_slots == 4096
  end
end
