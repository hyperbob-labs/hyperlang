defmodule HyperlangStdlibBoundaryPerfTest do
  use ExUnit.Case, async: false

  test "stdlib admission remains scoped for hand-built contexts" do
    {:ok, permissive} =
      Hyperlang.Manifest.normalize(%{terms: %{public: :erlang}, stdlib: %{lists: true}})

    {:ok, strict} =
      Hyperlang.Manifest.normalize(%{terms: %{public: :erlang}, stdlib: %{lists: false}})

    base = %{
      token: :stdlib_allowed_manual_context_test,
      atom_pool: %{},
      slot_module: __MODULE__,
      slot_version: 1
    }

    permissive_ctx =
      Map.merge(base, %{manifest: permissive, limits: permissive.limits, terms: permissive.terms})

    strict_ctx = Map.merge(base, %{manifest: strict, limits: strict.limits, terms: strict.terms})

    assert Hyperlang.Runtime.stdlib(permissive_ctx, :lists, :sum, [[1, 2, 3]]) == 6

    assert catch_error(Hyperlang.Runtime.stdlib(strict_ctx, :lists, :sum, [[1, 2, 3]])) ==
             {:sandbox, :stdlib_error, :lists, :sum, :forbidden_stdlib_call}
  end
end
