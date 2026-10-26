defmodule Hyperlang.AtomPoolTest do
  # Generated atom families are materialized on first use, every Hyperlang
  # atom creation keeps the atom-table reserve free, and atom existence never
  # tells one guest about another's pool use.
  use ExUnit.Case, async: false

  alias Hyperlang.GeneratedAtoms

  defp atoms, do: :erlang.system_info(:atom_count)

  defp existing_atom?(name) do
    _ = String.to_existing_atom(name)
    true
  rescue
    ArgumentError -> false
  end

  defp pub(manifest \\ %{}), do: Map.put(manifest, :terms, %{public: :erlang})

  defp run(program) do
    case Hyperlang.Test.run(program, :entry, [nil]) do
      {:ok, value, _meta} -> {:ok, value}
      {:error, error} -> {:error, error}
    end
  end

  # The highest index of a family whose atom does not exist yet.
  defp unmaterialized_index(prefix, cap) do
    Enum.find((cap - 1)..0//-1, fn index -> not existing_atom?(prefix <> "#{index}") end)
  end

  # Runs `fun` with the atom-table ceiling `headroom` entries above the
  # current atom count.
  defp with_headroom(headroom, fun) do
    previous = Application.get_env(:hyperlang, :atom_table_reserve)
    reserve = :erlang.system_info(:atom_limit) - atoms() - headroom
    Application.put_env(:hyperlang, :atom_table_reserve, reserve)

    try do
      fun.()
    after
      if previous == nil,
        do: Application.delete_env(:hyperlang, :atom_table_reserve),
        else: Application.put_env(:hyperlang, :atom_table_reserve, previous)
    end
  end

  # One function per arity 1..`arities`, each with `funs` funs; `salt` pads the
  # function index so every call yields compiler names no earlier call made.
  defp lambda_source(salt, arity, funs) do
    args = Enum.map_join(1..arity, ", ", &"A#{&1}")
    lambdas = Enum.map_join(1..funs, ", ", &"fun() -> {A1, #{&1}} end")
    pad = Enum.map_join(1..salt//1, "\n", &"p#{&1}(_) -> #{&1}.")
    call = Enum.map_join(1..arity, ", ", fn _ -> "0" end)

    """
    -module(k).
    -export([result/1]).
    result(_) -> length(f(#{call})).
    #{pad}
    f(#{args}) -> [#{lambdas}].
    """
  end

  describe "first use" do
    test "a fresh VM pays for the pool atoms its first program needs, not the caps" do
      paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
      {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io, args: paths})

      try do
        {:ok, _apps} = :peer.call(peer, :application, :ensure_all_started, [:hyperlang])
        before = :peer.call(peer, :erlang, :system_info, [:atom_count])

        {:ok, program} =
          :peer.call(peer, Hyperlang.Test, :program, ["result(_) -> warm.", pub()], 60_000)

        assert {:ok, "warm", _meta} =
                 :peer.call(peer, Hyperlang.Test, :run, [program, :entry, [nil]], 60_000)

        delta = :peer.call(peer, :erlang, :system_info, [:atom_count]) - before

        # The former eager pools added 540,672 family atoms here. What remains
        # is Hyperlang's own modules loading on first use.
        assert delta < 10_000

        for name <- [
              "v_524287",
              "safe_f_8191",
              "hyperlang_atom_4095",
              "hyperlang_kernel_atom_4095"
            ] do
          refute peer_existing_atom?(peer, name)
        end
      after
        :peer.stop(peer)
      end
    end

    test "a program materializes only the pool indices it uses" do
      {:ok, warm} = Hyperlang.Test.program("result(_) -> warm.", pub())
      assert {:ok, "warm"} = run(warm)

      suffix = System.unique_integer([:positive])
      names = Enum.map(1..50, &"first_use_#{suffix}_#{&1}")
      before = atoms()
      {:ok, program} = Hyperlang.Test.program("result(_) -> [#{Enum.join(names, ", ")}].", pub())
      assert {:ok, ^names} = run(program)
      # At most one new family atom per pooled literal (fewer when an earlier
      # program already reached those indices).
      assert atoms() - before <= 50 + 8
      refute Enum.any?(names, &existing_atom?/1)

      # Another universe with 50 other names reuses the same indices.
      other = Enum.map(1..50, &"first_use_other_#{suffix}_#{&1}")
      before = atoms()
      {:ok, program} = Hyperlang.Test.program("result(_) -> [#{Enum.join(other, ", ")}].", pub())
      assert {:ok, ^other} = run(program)
      assert atoms() - before == 0
      refute Enum.any?(other, &existing_atom?/1)
    end
  end

  describe "adversarial streams" do
    test "an atom-heavy guest stream grows the table only to the family high-water mark" do
      source = fn salt ->
        body =
          for f <- 1..25 do
            vars = Enum.map_join(1..30, ", ", &"V#{&1} = #{&1}")
            sum = Enum.map_join(1..30, " + ", &"V#{&1}")
            lits = Enum.map_join(1..20, ", ", &"stream_#{salt}_#{f}_#{&1}")
            "f#{f}(_) -> #{vars}, {#{sum}, [#{lits}]}."
          end

        "-module(k).\n-export([result/1]).\nresult(X) -> f1(X).\n" <> Enum.join(body, "\n")
      end

      salt = System.unique_integer([:positive])
      {:ok, warm} = Hyperlang.Test.program(source.("warm_#{salt}"), pub())
      assert {:ok, {465, _}} = run(warm)

      before = atoms()

      for round <- 1..40 do
        {:ok, program} = Hyperlang.Test.program(source.("r#{round}_#{salt}"), pub())
        assert {:ok, {465, [_ | _]}} = run(program)
      end

      # 40 programs x 500 distinct atom literals: every program maps its names
      # onto indices the warm-up program already materialized.
      assert atoms() - before == 0
      refute existing_atom?("stream_r1_#{salt}_1_1")
    end

    test "each OTP compile creates no more atoms than it promised" do
      salt = 7 + rem(System.unique_integer([:positive]), 40)

      mixed = fn salt ->
        """
        -module(k).
        -export([result/1]).
        result(_) -> c([1, 2, 3], <<1, 2>>).
        #{Enum.map_join(1..salt//1, "\n", &"p#{&1}(_) -> #{&1}.")}
        c(L, B) ->
          {[X * Y || X <- L, Y <- L, X < Y],
           << <<(X + 1)>> || <<X>> <= B >>,
           (fun F(0) -> 0; F(N) -> F(N - 1) end)(3),
           try length(L) catch _:_ -> 0 end,
           receive {never, Z} -> Z after 0 -> timeout end}.
        """
      end

      templates = [
        &lambda_source(&1, 3, 25),
        &lambda_source(&1, 5, 25),
        mixed
      ]

      for template <- templates do
        # The first program loads whatever runtime code the shape needs; the
        # second, with a new salt, measures only the compile.
        {:ok, warm} = Hyperlang.Test.program(template.(salt + 100), pub())
        assert {:ok, _value} = run(warm)

        {:ok, program} = Hyperlang.Test.program(template.(salt), pub())
        bound = GeneratedAtoms.compiler_atom_bound(program.artifact.forms)
        before = atoms()
        assert {:ok, _value} = run(program)
        created = atoms() - before
        assert created <= bound, "compile created #{created} atoms, promised #{bound}"
      end
    end

    test "guest funs add at most one fixed-shape compiler name per lifted fun" do
      salt = 60 + rem(System.unique_integer([:positive]), 100)
      {:ok, program} = Hyperlang.Test.program(lambda_source(salt, 7, 30), pub())
      before = atoms()
      assert {:ok, 30} = run(program)

      compiler_made =
        before..(atoms() - 1)//1
        |> Enum.map(&Atom.to_string(:erlang.binary_to_term(<<131, 75, &1::24>>)))
        |> Enum.reject(&(&1 =~ ~r/^(safe_f_|v_|hyperlang_atom_)\d+$/))

      # Lifted funs are `safe_f_N/2` whatever the enclosing arity, so the
      # names are `-safe_f_N/2-fun-0-`, one per lifted index at most.
      assert length(compiler_made) <= 30
      assert Enum.all?(compiler_made, &(&1 =~ ~r/^-safe_f_\d+\/2-fun-0-$/))
      assert atoms() <= :erlang.system_info(:atom_limit) - GeneratedAtoms.atom_table_reserve()
    end
  end

  describe "atom-table reserve" do
    test "a family atom is refused at the ceiling and the host keeps its headroom" do
      index = unmaterialized_index("v_", GeneratedAtoms.max_variables())

      kernel =
        unmaterialized_index("hyperlang_kernel_atom_", GeneratedAtoms.max_kernel_source_atoms())

      with_headroom(0, fn ->
        assert catch_throw(GeneratedAtoms.variable!(index)) ==
                 {:hyperlang_generated_atom, :variable, :atom_table_reserve}

        if kernel do
          assert GeneratedAtoms.kernel_source_atom(kernel) == {:error, :atom_table_reserve}
        end

        refute existing_atom?("v_#{index}")

        before = atoms()
        made = for i <- 1..100, do: String.to_atom("host_after_reserve_#{i}_#{index}")
        assert length(Enum.uniq(made)) == 100
        assert atoms() - before == 100
      end)

      assert is_atom(GeneratedAtoms.variable!(index))
      assert GeneratedAtoms.variable!(GeneratedAtoms.max_variables() - 1) |> is_atom()

      assert catch_throw(GeneratedAtoms.variable!(GeneratedAtoms.max_variables())) ==
               {:hyperlang_generated_atom, :variable, :exhausted}
    end

    test "an OTP compile that could cross the ceiling fails with a clear error" do
      salt = 170 + rem(System.unique_integer([:positive]), 60)
      {:ok, program} = Hyperlang.Test.program(lambda_source(salt, 9, 20), pub())

      with_headroom(8, fn ->
        assert {:error, %{category: :compile, message: "VM atom table reserve reached"} = error} =
                 run(program)

        assert %{"atom_table_reserve" => reserve, "atom_limit" => limit} = error.details
        assert is_integer(reserve) and is_integer(limit)
        refute Map.has_key?(error.details, "atom_count")
      end)

      # Atoms already created stay valid; with the reserve restored the same
      # program loads and runs.
      assert {:ok, 20} = run(program)
    end

    test "a universe that needs a new pool atom at the ceiling fails to compile" do
      universe = {:atom_pool_test_reserve, System.unique_integer([:positive])}
      fresh = unmaterialized_index("hyperlang_atom_", GeneratedAtoms.max_source_atoms())

      if fresh do
        # Advance the universe to the first index that does not exist yet.
        lowest_fresh =
          Enum.find(0..fresh, fn index -> not existing_atom?("hyperlang_atom_#{index}") end)

        filler = Enum.map(0..(lowest_fresh - 1)//1, &"reserve_filler_#{&1}")
        assert {:ok, _, _} = Hyperlang.AtomUniverse.reserve(universe, filler)

        with_headroom(0, fn ->
          assert {:error, [%{category: :compile, message: "VM atom table reserve reached"}]} =
                   Hyperlang.Test.program("needs_fresh_pool_atom.", %{atom_universe: universe})
        end)

        refute existing_atom?("needs_fresh_pool_atom")
      else
        # Every source index exists already: the per-universe cap is the
        # bound a guest meets instead.
        assert {:ok, _, _} =
                 Hyperlang.AtomUniverse.reserve(
                   universe,
                   Enum.map(1..GeneratedAtoms.max_source_atoms(), &"reserve_filler_#{&1}")
                 )

        assert {:error, [%{category: :verify, message: message}]} =
                 Hyperlang.Test.program("needs_fresh_pool_atom.", %{atom_universe: universe})

        assert message =~ "atom universe exhausted"
      end
    end
  end

  describe "isolation" do
    test "universes share pool atoms but never each other's mappings" do
      suffix = System.unique_integer([:positive])
      a = {:atom_pool_test_a, suffix}
      b = {:atom_pool_test_b, suffix}

      assert {:ok, a_map, _} =
               Hyperlang.AtomUniverse.reserve(a, ["alpha_#{suffix}", "beta_#{suffix}"])

      assert {:ok, b_map, _} = Hyperlang.AtomUniverse.reserve(b, ["gamma_#{suffix}"])

      alpha = Map.fetch!(a_map, "alpha_#{suffix}")
      beta = Map.fetch!(a_map, "beta_#{suffix}")
      gamma = Map.fetch!(b_map, "gamma_#{suffix}")

      # Both universes start at index 0: the same VM atom, two meanings.
      assert alpha == gamma
      assert Hyperlang.AtomUniverse.source_for_atom(a, alpha) == "alpha_#{suffix}"
      assert Hyperlang.AtomUniverse.source_for_atom(b, gamma) == "gamma_#{suffix}"
      assert Hyperlang.AtomUniverse.source_for_atom(b, beta) == nil
      refute existing_atom?("alpha_#{suffix}")
    end

    test "a family name in the binding compatibility profile stays pooled whether or not it exists" do
      parent = self()
      binding = %{"tool" => %{echo: fn arg -> send(parent, {:echo, arg}) && :ok end}}
      manifest = %{terms: %{public: :erlang}, modules: %{enabled: true}, bindings: binding}

      host_atom = :"atom_pool_test_host_atom_#{System.unique_integer([:positive])}"
      {:ok, program} = Hyperlang.Test.program("tool:echo(#{host_atom}).", manifest)
      assert {:ok, :ok, _} = Hyperlang.Test.run(program, :entry, [nil], bindings: binding)
      # The compatibility profile keeps an existing host atom's identity.
      assert_receive {:echo, ^host_atom}

      index = unmaterialized_index("v_", GeneratedAtoms.max_variables())

      for _state <- [:absent, :materialized] do
        {:ok, program} = Hyperlang.Test.program("tool:echo(v_#{index}).", manifest)
        assert {:ok, :ok, _} = Hyperlang.Test.run(program, :entry, [nil], bindings: binding)
        assert_receive {:echo, echoed}
        assert echoed == "v_#{index}"
        _ = GeneratedAtoms.variable!(index)
      end
    end
  end

  defp peer_existing_atom?(peer, name) do
    _ = :peer.call(peer, :erlang, :binary_to_existing_atom, [name, :utf8])
    true
  rescue
    ArgumentError -> false
  end
end
