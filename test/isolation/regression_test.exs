ExUnit.configure(
  exclude:
    Enum.uniq(
      [isolation_stress: true, isolation_finding: true] ++ ExUnit.configuration()[:exclude]
    )
)

Code.require_file("support/probe.ex", __DIR__)

defmodule Hyperlang.Isolation.RegressionTest do
  use ExUnit.Case, async: false
  import Hyperlang.Test

  test "program cache keys are explicitly caller owned" do
    key = {:isolation_regression, make_ref()}
    loader = fn -> %{entry: "main.erl", files: %{"main.erl" => "result(_) -> 42."}} end
    assert {:ok, p} = Hyperlang.program(key, loader)
    assert {:ok, ^p} = Hyperlang.program(key, fn -> raise "cache hit called loader" end)
    assert {:ok, 42, _} = run(p, :entry, [nil])
  end

  test "benign local funs execute and external host fun inputs are rejected" do
    p = program!("result(_) -> F = fun(X) -> X + 1 end, F(2).", terms: %{public: :erlang})
    assert {:ok, 3, _} = run(p, :entry, [nil])
    id = program!("result(X) -> X.")
    assert {:error, %{category: :input}} = run(id, :entry, [&String.length/1])
  end

  test "source atoms project back to their own names across separate programs" do
    for name <- ["tenant_alpha_name", "tenant_beta_name"] do
      p = program!("result(_) -> atom_to_binary('#{name}').", terms: %{public: :erlang})
      assert {:ok, ^name, _} = run(p, :entry, [nil])
    end
  end
end
