defmodule Hyperlang.ChainingProbeTest do
  # CHAINING: assume an attacker knows a live generated slot module name and
  # helper atom (e.g. :hyperlang_slot_000017.safe_f_0). Every attempt to turn
  # such a name into a call into generated, host, or other-guest code must be
  # rejected, so knowing a name never grants authority.
  use ExUnit.Case, async: false
  import Hyperlang.SandboxProbe
  alias Hyperlang.Test, as: Kit

  # A live slot module name, read host-side after a run loads one.
  defp leaked_slot do
    {:ok, _value, _meta} = run("result(_) -> ok.", %{terms: %{allowed_atoms: [:ok]}})

    Enum.find_value(:code.all_loaded(), "hyperlang_slot_000001", fn {module, _path} ->
      name = Atom.to_string(module)
      String.starts_with?(name, "hyperlang_slot_") && name
    end)
  end

  describe "a leaked generated module name cannot be called" do
    test "static remote call to the leaked slot module is rejected" do
      slot = leaked_slot()

      assert rejected?("result(_) -> '#{slot}':safe_f_0()."),
             "a leaked slot module (#{slot}) was callable"
    end

    test "static remote call to the leaked slot module with modules enabled is rejected" do
      slot = leaked_slot()

      assert rejected?(
               "result(_) -> '#{slot}':safe_f_0(1, 2).",
               %{modules: %{enabled: true, guest_modules: [slot]}}
             ),
             "a leaked slot module (#{slot}) was reachable via code path"
    end

    test "dynamic dispatch through a variable holding the leaked name is rejected" do
      slot = leaked_slot()
      assert rejected?("result(_) -> M = '#{slot}', M:safe_f_0().")
    end
  end

  describe "generated helper names are not callable as locals" do
    for helper <- ["safe_f_0", "safe_f_1", "safe_result", "safe_entry", "safe_export"] do
      test "local call to generated helper #{helper} is rejected" do
        assert rejected?("result(_) -> #{unquote(helper)}().")
      end

      test "local capture of generated helper #{helper} is rejected" do
        assert rejected?("result(_) -> fun #{unquote(helper)}/0.")
      end
    end
  end

  describe "leaked / generated names are not reachable through export dispatch" do
    test "running a leaked slot name as an export id fails" do
      program =
        Kit.program!("result(_) -> ok.", pub(%{terms: %{public: :erlang, allowed_atoms: [:ok]}}))

      slot = leaked_slot()

      for export <- [slot, "safe_f_0", "#{slot}:safe_f_0/0", "safe_result", "$safe_entry"] do
        out = Kit.run(program, export, [nil])

        assert match?({:error, _}, out),
               "export id #{inspect(export)} was dispatchable: #{inspect(out)}"
      end
    end
  end

  describe "a leaked pool atom name cannot be turned back into a VM atom or call" do
    test "list_to_existing_atom on a leaked pool name is rejected (no atom creation)" do
      assert rejected?(~S|result(_) -> list_to_existing_atom("hyperlang_atom_0").|)
    end

    test "a reserved-internal-looking source atom is an inert pooled atom, redacted on output" do
      # It compiles to an ordinary pooled atom (not the real reserved VM atom),
      # and the output walk redacts it rather than emitting the reserved name.
      for src <- ["result(_) -> 'hyperlang_slot_000001'.", "result(_) -> 'safe_f_0'."] do
        out = run(src)
        assert match?({:error, %{category: :output}}, out) or match?({:rejected, _}, out)
        refute text(out) =~ "hyperlang_slot_000001"
        refute text(out) =~ "safe_f_0"
      end
    end
  end
end
