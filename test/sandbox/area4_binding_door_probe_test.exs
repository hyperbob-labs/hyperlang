defmodule Hyperlang.Area4BindingDoorProbeTest do
  # AREA 4: binding and door boundary. A guest may reach a binding only through a
  # static remote call matching a pinned MFA; it cannot capture, store, forward,
  # or forge a binding, call an undeclared one, or call an unexported helper
  # through export dispatch. Binding args/returns are sanitized both ways.
  use ExUnit.Case, async: false
  import Hyperlang.SandboxProbe
  alias Hyperlang.Test, as: Kit

  defp kv, do: %{"kv" => %{get: fn _ -> 1 end, put: fn _k, _v -> :stored end}}

  defp kv_manifest(extra \\ %{}) do
    pub(
      Map.merge(
        %{terms: %{public: :erlang, allowed_atoms: [:ok, :stored, :k, :v]}, bindings: kv()},
        extra
      )
    )
  end

  defp run_kv(src) do
    case Kit.program(src, kv_manifest()) do
      {:ok, p} -> Kit.run(p, :entry, [nil], bindings: kv())
      {:error, e} -> {:rejected, e}
    end
  end

  describe "only pinned binding MFAs are callable" do
    test "a declared binding export is callable" do
      assert {:ok, 1, _} = run_kv("result(_) -> kv:get(k).")
    end

    test "an undeclared function on the binding module is rejected" do
      assert match?({:rejected, _}, run_kv("result(_) -> kv:delete(k)."))
    end

    test "a declared binding at the wrong arity is rejected" do
      assert match?({:rejected, _}, run_kv("result(_) -> kv:get(k, extra)."))
    end

    test "an undeclared binding module is rejected" do
      assert match?({:rejected, _}, run_kv("result(_) -> other:get(k)."))
    end
  end

  describe "a binding is never a guest-visible value" do
    for {name, body} <- [
          {"capture as external fun", "F = fun kv:get/1, F(k)"},
          {"dynamic dispatch on binding name", "M = kv, M:get(k)"},
          {"binding module as a term", "{kv}"}
        ] do
      test "reject #{name}" do
        # The first two are hard verify errors; the third names `kv` only as a
        # pooled atom (never an authority handle), so if it compiles it is inert.
        out = run_kv("result(_) -> #{unquote(body)}.")
        refute match?({:ok, v, _} when is_function(v), out)
      end
    end
  end

  describe "binding arguments and returns are sanitized both ways" do
    test "a fun argument never reaches the host binding" do
      assert {:error, %{category: :import}} =
               run_kv("result(_) -> kv:put(k, fun() -> ok end).")
    end

    test "a binding that returns a pid yields a sanitized import error, not the pid" do
      binding = %{"kv" => %{get: fn _ -> :erlang.list_to_pid(~c"<0.1.0>") end}}

      {:ok, p} =
        Kit.program(
          "result(_) -> kv:get(k).",
          pub(%{terms: %{public: :erlang, allowed_atoms: [:k]}, bindings: binding})
        )

      assert {:error, %{category: :import}} = Kit.run(p, :entry, [nil], bindings: binding)
    end

    test "a binding that returns a fun yields a sanitized import error, not the fun" do
      binding = %{"kv" => %{get: fn _ -> fn -> :leaked end end}}

      {:ok, p} =
        Kit.program(
          "result(_) -> kv:get(k).",
          pub(%{terms: %{public: :erlang, allowed_atoms: [:k]}, bindings: binding})
        )

      out = Kit.run(p, :entry, [nil], bindings: binding)
      assert match?({:error, %{category: :import}}, out)
      refute match?({:ok, v, _} when is_function(v), out)
    end
  end

  describe "export entry boundary: only declared exports are callable" do
    defp exported_program do
      Kit.program!(
        """
        -export([helper/0]).
        result(_) -> ok.
        pub() -> public_value.
        helper() -> helper_secret.
        """,
        pub(%{
          terms: %{public: :erlang, allowed_atoms: [:ok, :public_value, :helper_secret]},
          exports: %{functions: %{"pub/0" => %{function: "pub", arity: 0}}}
        })
      )
    end

    test "a declared export id is callable" do
      assert {:ok, :public_value, _} = Kit.run(exported_program(), "pub/0", [])
    end

    test "an unexported helper is not callable through export dispatch" do
      out = Kit.run(exported_program(), "helper/0", [])
      assert match?({:error, _}, out)
      refute match?({:ok, :helper_secret, _}, out)
    end

    test "a generated helper name is not callable through export dispatch" do
      out = Kit.run(exported_program(), "safe_f_0", [])
      assert match?({:error, _}, out)
    end

    test "a source -export attribute does not by itself grant run authority" do
      # helper/0 is in -export but not in the manifest exports; still unreachable.
      out = Kit.run(exported_program(), "helper/0", [])
      refute match?({:ok, :helper_secret, _}, out)
    end
  end

  describe "manifest binding keys must be atom-keyed and well-formed" do
    test "a string-keyed stdlib-reserved binding name is rejected" do
      out =
        Kit.program("result(_) -> erlang:get().", %{
          terms: %{public: :erlang},
          bindings: %{"erlang" => %{get: fn -> 1 end}}
        })

      assert match?({:error, _}, out)
    end
  end
end
