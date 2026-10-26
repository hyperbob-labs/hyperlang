defmodule Hyperlang.Area3AtomTermProbeTest do
  # AREA 3: atom and term policy. Guest input must not exhaust the VM atom table,
  # must not forge host-trusted carriers (capability/opaque handles), and must
  # not smuggle pids/ports/refs/funs/improper/oversized terms across the door.
  use ExUnit.Case, async: false
  import Hyperlang.SandboxProbe

  defp existing_atom?(name) do
    _ = String.to_existing_atom(name)
    true
  rescue
    ArgumentError -> false
  end

  describe "source atoms are pooled, never interned as VM atoms" do
    # Load the compiler path (and its rejection path) once, so the counts
    # below measure guest atoms, not Hyperlang's own modules loading.
    setup do
      {:ok, _} = compile("result(_) -> [warm_a, warm_b].")
      {:error, _} = compile("result(_) -> [#{Enum.map_join(1..1_001, ", ", &"warm_#{&1}")}].")
      :ok
    end

    test "300 distinct source atoms create no guest-named VM atoms" do
      atoms = Enum.map_join(1..300, ", ", &"src_atom_#{&1}")
      before = atom_count()
      assert {:ok, _} = compile("result(_) -> [#{atoms}].")
      # At most one pool atom per index on first use, never a guest name.
      assert atom_count() - before <= 300
      refute existing_atom?("src_atom_1")

      others = Enum.map_join(1..300, ", ", &"src_atom_other_#{&1}")
      before = atom_count()
      assert {:ok, _} = compile("result(_) -> [#{others}].")
      assert atom_count() - before == 0
    end

    test "many distinct atoms across repeated compiles do not grow the atom table" do
      before = atom_count()

      for batch <- 1..5 do
        atoms = Enum.map_join(1..200, ", ", &"batch#{batch}_atom_#{&1}")
        assert {:ok, _} = compile("result(_) -> [#{atoms}].")
      end

      # Pool atoms are made on first use of an index; repeated distinct guest
      # atoms reuse the same 200 indices and must not leak.
      assert atom_count() - before <= 200 + 8
      refute existing_atom?("batch5_atom_1")
    end

    test "an atom flood beyond the pool fails closed without creating VM atoms" do
      atoms = Enum.map_join(1..6000, ", ", &"flood_#{&1}")
      before = atom_count()
      assert {:error, _} = compile("result(_) -> [#{atoms}].")
      assert atom_count() - before == 0
    end
  end

  describe "oversized and malformed terms are bounded at the output boundary" do
    test "a huge integer is rejected (integer_bits)" do
      assert {:error, %{category: :output, message: "integer_bits"}} =
               run("result(_) -> 1 bsl 100000.")
    end

    test "an improper list is rejected" do
      assert {:error, %{category: :output, message: "improper_list"}} =
               run("result(_) -> [1 | 2].")
    end

    test "an over-deep nested term is rejected (term_depth)" do
      deep_open = String.duplicate("[", 200)
      deep_close = String.duplicate("]", 200)
      out = run("result(_) -> #{deep_open}1#{deep_close}.")
      assert match?({:error, %{category: :output, message: "term_depth"}}, out)
    end

    test "an over-long list is rejected" do
      long = Enum.map_join(1..100_000, ",", &Integer.to_string/1)

      out =
        run("result(_) -> [#{long}].", %{
          limits: %{max_tokens: 1_000_000, max_ast_nodes: 2_000_000}
        })

      # Either the compiler bounds it or the output walk rejects the length.
      assert match?({:error, _}, out) or match?({:rejected, _}, out)
    end
  end

  describe "funs, pids, ports and refs never cross the result boundary" do
    for {name, body} <- [
          {"bare fun", "fun() -> ok end"},
          {"fun in tuple", "{fun() -> ok end}"},
          {"fun in list", "[fun() -> ok end]"},
          {"fun in map value", "\#{k => fun() -> ok end}"},
          {"fun via tuple_to_list", "tuple_to_list({fun() -> ok end})"}
        ] do
      test "reject at output: #{name}" do
        assert match?(
                 {:error, %{category: :output}},
                 run(
                   "result(_) -> #{unquote(body)}.",
                   %{terms: %{public: :erlang, allowed_atoms: [:ok, :k]}}
                 )
               )
      end
    end

    test "funs cannot ride out through throw or exit" do
      assert {:error, _} = run("result(_) -> throw(fun() -> ok end).")
      assert {:error, _} = run("result(_) -> exit(fun() -> ok end).")
    end
  end

  describe "the Opaque round-trip box cannot be forged by guest source" do
    test "a guest map tagged as Hyperlang.Terms.Opaque is inert data, not an unwrapped box" do
      out =
        run(
          ~S|result(_) -> #{'__struct__' => 'Elixir.Hyperlang.Terms.Opaque', token => 1, term => secret}.|,
          %{terms: %{public: :erlang, allowed_atoms: [:secret]}}
        )

      # It must either be rejected or come back as a plain map — never treated as
      # a trusted already-validated box (which would skip the atom defense).
      case out do
        {:ok, value, _} ->
          refute is_struct(value)
          assert is_map(value)

        {:error, _} ->
          :ok
      end
    end
  end

  describe "the reserved message-envelope atom cannot be named by guest source" do
    for src <- [
          "result(_) -> '$hyperlang_msg'.",
          "result(_) -> {'$hyperlang_msg', from, payload}.",
          "result(_) -> ['$hyperlang_msg']."
        ] do
      test "reject #{src}" do
        assert {:error, [%{category: :verify, message: message} | _]} =
                 compile(unquote(src), %{
                   terms: %{public: :erlang, allowed_atoms: [:from, :payload]}
                 })

        assert message =~ "reserved Hyperlang internal name"
      end
    end
  end

  describe "process dictionary keys are namespaced away from host keys" do
    test "guest put/get only sees its own keys" do
      assert {:ok, [{"a", 1}], _} = run("result(_) -> put(a, 1), get().")
    end

    for key <- ["'$ancestors'", "'$initial_call'", "'$hyperlang_msg_context'"] do
      test "guest cannot read host dict key #{key}" do
        assert {:ok, :undefined, _} =
                 run(
                   "result(_) -> get(#{unquote(key)}).",
                   %{terms: %{public: :erlang, allowed_atoms: [:undefined]}}
                 )
      end
    end
  end
end
