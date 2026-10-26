defmodule Hyperlang.CompilerNameBoundTest do
  # The OTP compiler names the functions it makes for funs, comprehensions and
  # receive loops after their enclosing function and a counter. Codegen lifts
  # every such construct into its own `safe_f_N/2`, so those names come from a
  # fixed set computed from host limits: guest code never adds VM atoms beyond
  # `GeneratedAtoms.compiler_name_bound/0` plus the generated families.
  use ExUnit.Case, async: false

  alias Hyperlang.GeneratedAtoms

  @moduletag timeout: 600_000

  defp atoms, do: :erlang.system_info(:atom_count)
  defp atom_at(index), do: :erlang.binary_to_term(<<131, 75, index::24>>)

  defp pub(manifest \\ %{}),
    do: Map.update(manifest, :terms, %{public: :erlang}, &Map.put(&1, :public, :erlang))

  defp new_atoms(fun) do
    before = atoms()
    result = fun.()
    {result, Enum.map(before..(atoms() - 1)//1, &atom_at/1)}
  end

  defp run(source, manifest \\ pub()) do
    with {:ok, program} <- Hyperlang.Test.program(source, manifest),
         {:ok, value, _meta} <- Hyperlang.Test.run(program, :entry, [nil]) do
      {:ok, value}
    end
  end

  # Names a compile may create: a generated family atom or one of the fixed
  # compiler-name shapes.
  @family ~r/^(hyperlang_atom_|hyperlang_kernel_atom_|safe_f_|v_)\d+$/
  @lifted ~r/^-safe_f_\d+\/2-(fun-0|lc\$\^0\/1-0|lbc\$\^0\/2-0)-$/
  @fixed ~r/^(lc\$\^0|lbc\$\^0|recv\$\^1|label\^\d+|-\$safe_entry\/3-fun-[01]-|-\$safe_export\/4-fun-[0-2]-)$/

  defp allowed_name?(atom) do
    name = Atom.to_string(atom)
    name =~ @family or name =~ @lifted or name =~ @fixed
  end

  # One guest expression per construct, with the value it must produce.
  # `a` is the first argument of `f/N`, `i` the item index.
  defp item(kind, i) do
    case kind do
      :fun ->
        {"(fun(X) -> X + A1 + #{i} end)(1)", &(1 + &1 + i)}

      :nested_fun ->
        {"((fun() -> fun(Y) -> Y * A1 end end)())(#{i})", &(i * &1)}

      :named_fun ->
        {"(fun F(0) -> #{i}; F(N) -> N + F(N - 1) end)(3)", fn _ -> 6 + i end}

      :lc ->
        {"lists:sum([X * #{i} || X <- [A1, 2, 3], X > 1])",
         &Enum.sum(for x <- [&1, 2, 3], x > 1, do: x * i)}

      :lc_multi ->
        {"length([{X, Y} || X <- [1, 2], Y <- [A1, #{i}], X =/= Y])",
         &length(for x <- [1, 2], y <- [&1, i], x != y, do: {x, y})}

      :bc ->
        {"byte_size(<< <<(X + #{i})>> || <<X>> <= <<1, 2, 3>>, X =/= A1 >>)",
         &Enum.count([1, 2, 3], fn x -> x != &1 end)}

      :bc_multi ->
        {"byte_size(<< <<X, Y>> || X <- [1, 2], Y <- [A1, #{i}] >>)", fn _ -> 8 end}

      :mc ->
        {"map_size(\#{X => #{i} || X <- [A1, 2, #{i}]})", &MapSet.size(MapSet.new([&1, 2, i]))}

      :mc_multi ->
        {"map_size(\#{{X, Y} => 1 || X <- [1, 2], Y <- [A1, #{i}]})",
         &(2 * MapSet.size(MapSet.new([&1, i])))}

      :receive ->
        {"receive {never, #{i}, Z} -> Z after 0 -> #{i} end", fn _ -> i end}

      :try ->
        {"try A1 div 0 catch error:_ -> #{i} end", fn _ -> i end}

      :split ->
        {"case <<2, 7, 8, #{rem(i, 256)}>> of <<S:8, D:S/binary, _/binary>> -> byte_size(D) + #{i}; _ -> 0 end",
         fn _ -> 2 + i end}

      :record ->
        {"(#r{b = #{i}})#r.a + (#r{b = A1})#r.b", &(1 + &1)}

      :record_filter ->
        {"length([R || R <- [#r{a = 5}, {other}, #r{a = #{i}}], R#r.a > 1])",
         fn _ -> if i > 1, do: 2, else: 1 end}

      :fun_ref ->
        {"lists:sum(lists:map(fun g/1, [#{i}, A1]))", &(2 * i + 2 * &1)}

      :foldl ->
        {"lists:foldl(fun(X, Acc) -> X + Acc + A1 end, 0, [#{i}, 2])", &(i + 2 + 2 * &1)}

      :fun_in_lc ->
        {"lists:sum([(fun() -> X * A1 end)() || X <- [#{i}, 1]])", &(&1 * (i + 1))}
    end
  end

  @kinds [
    :fun,
    :nested_fun,
    :named_fun,
    :lc,
    :lc_multi,
    :bc,
    :bc_multi,
    :mc,
    :mc_multi,
    :receive,
    :try,
    :split,
    :record,
    :record_filter,
    :fun_ref,
    :foldl,
    :fun_in_lc
  ]

  # A guest program from a construct list: `pad` functions shift every
  # generated index, `arity` changes the arity of `f`.
  defp program(pad, arity, kinds, a1) do
    items = kinds |> Enum.with_index(1) |> Enum.map(fn {kind, i} -> item(kind, i) end)
    args = Enum.map_join(1..arity, ", ", &"A#{&1}")
    call = Enum.map_join(1..arity, ", ", &if(&1 == 1, do: "#{a1}", else: "#{&1}"))
    pads = Enum.map_join(1..pad//1, "\n", &"p#{&1}(X) -> X + #{&1}.")
    body = Enum.map_join(items, ", ", &elem(&1, 0))

    source = """
    -record(r, {a = 1, b}).
    result(_) -> f(#{call}).
    g(X) -> 2 * X.
    #{pads}
    f(#{args}) -> [#{body}].
    """

    {source, Enum.map(items, fn {_text, value} -> value.(a1) end)}
  end

  defp stream_program(seed) do
    :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 5})
    pad = :rand.uniform(30) - 1
    arity = :rand.uniform(6)
    count = :rand.uniform(12)
    kinds = for _ <- 1..count, do: Enum.random(@kinds)
    program(pad, arity, kinds, :rand.uniform(9))
  end

  describe "compiler-made names" do
    test "every name a compile creates is a family atom or a fixed compiler-name shape" do
      # The first programs load the Hyperlang modules their constructs use.
      {warm, expected} = program(40, 3, @kinds, 2)
      assert run(warm) == {:ok, expected}

      for kind <- @kinds, pad <- [0, 7] do
        {source, expected} = program(pad, 2, [kind, kind, :fun], 3)
        {result, created} = new_atoms(fn -> run(source) end)
        assert result == {:ok, expected}, source
        assert Enum.reject(created, &allowed_name?/1) == [], inspect({source, created})
      end
    end

    test "a compile creates only names from its exact candidate set" do
      for seed <- 1..40 do
        {source, expected} = stream_program(seed)
        {:ok, program} = Hyperlang.Test.program(source, pub())
        candidates = MapSet.new(GeneratedAtoms.compiler_atom_names(program.artifact.forms))
        bound = GeneratedAtoms.compiler_atom_bound(program.artifact.forms)
        {result, created} = new_atoms(fn -> Hyperlang.Test.run(program, :entry, [nil]) end)
        assert {:ok, ^expected, _} = result

        compiler_made = Enum.reject(created, &(Atom.to_string(&1) =~ @family))
        assert Enum.all?(compiler_made, &MapSet.member?(candidates, Atom.to_string(&1))), source
        assert length(compiler_made) <= bound
      end
    end

    test "the global bound is three names per function index plus the split labels and eight" do
      assert GeneratedAtoms.compiler_name_bound() ==
               3 * GeneratedAtoms.max_functions() + GeneratedAtoms.max_pattern_splits() + 8
    end

    test "an adversarial stream of 1,000 distinct programs adds no atoms after warm-up" do
      # Warm-up: every generated index of every lifted kind the stream can
      # reach, the split labels and the variable names.
      max_index = 3 + 30 + 12 * 4

      for kind <- [:fun, :lc, :bc_multi, :split] do
        {source, expected} = program(0, 6, List.duplicate(kind, max_index), 1)

        assert run(source, pub(%{limits: %{max_ast_nodes: 100_000, max_tokens: 50_000}})) ==
                 {:ok, expected}
      end

      for seed <- 1..200 do
        {source, expected} = stream_program(seed)
        assert run(source) == {:ok, expected}
      end

      before = atoms()

      for seed <- 1_001..2_000 do
        {source, expected} = stream_program(seed)
        assert run(source) == {:ok, expected}, source
      end

      assert atoms() - before == 0
    end
  end

  describe "small atom table" do
    @tag :peer
    test "a +t 65536 VM survives an unbounded lambda stream with every compile succeeding" do
      paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

      {:ok, peer, _node} =
        :peer.start_link(%{connection: :standard_io, args: [~c"+t", ~c"65536" | paths]})

      try do
        {:ok, _apps} = :peer.call(peer, :application, :ensure_all_started, [:hyperlang])
        assert :peer.call(peer, :erlang, :system_info, [:atom_limit]) == 65_536

        counts =
          for seed <- 1..600 do
            {source, expected} = stream_program(seed)
            {:ok, program} = :peer.call(peer, Hyperlang.Test, :program, [source, pub()], 60_000)

            assert {:ok, ^expected, _} =
                     :peer.call(peer, Hyperlang.Test, :run, [program, :entry, [nil]], 60_000)

            :peer.call(peer, :erlang, :system_info, [:atom_count])
          end

        # The table plateaus: the second half of the stream adds almost
        # nothing, and the total stays far below the reserve ceiling.
        {first, second} = Enum.split(counts, 300)
        assert List.last(second) - List.last(first) < 200
        assert List.last(counts) < 65_536 - div(65_536, 4)
      after
        :peer.stop(peer)
      end
    end
  end

  describe "closure semantics" do
    test "captures, shadowing and nested captures" do
      source = """
      result(_) ->
        A = 1, B = 2,
        F = fun(X) -> X + A end,
        G = fun(A) -> A * 10 end,
        H = fun() -> fun(Y) -> {A, B, Y} end end,
        {F(5), G(3), (H())(7), A}.
      """

      assert run(source) == {:ok, {6, 30, {1, 2, 7}, 1}}
    end

    test "named funs recurse, see their name in guards and equal themselves" do
      source = """
      result(_) ->
        K = 2,
        Fact = fun F(0) -> 1; F(N) -> N * F(N - 1) end,
        Self = fun S(get) -> S; S(_) -> K end,
        Guard = fun G(X) when is_function(G, 1), X > 0 -> G(X - 1) + K; G(_) -> 0 end,
        {Fact(5), Self(get) =:= Self, Self(x), Guard(3)}.
      """

      assert run(source) == {:ok, {120, true, 2, 6}}
    end

    test "fun equality follows code and captured values" do
      source = """
      result(_) ->
        Make = fun(V) -> fun() -> V end end,
        {Make(1) =:= Make(1), Make(1) =:= Make(2),
         fun g/1 =:= fun g/1, fun g/1 =:= fun h/1,
         is_function(Make(1), 0), is_function(fun g/1, 1)}.
      g(X) -> X.
      h(X) -> X.
      """

      assert run(source) == {:ok, {true, false, true, false, true, true}}
    end

    test "closures and local fun refs work with higher-order stdlib functions" do
      source = """
      result(_) ->
        N = 3,
        {lists:map(fun(X) -> X * N end, [1, 2]),
         lists:foldl(fun(X, Acc) -> X + Acc end, N, [1, 2]),
         lists:filter(fun is_odd/1, [1, 2, 3]),
         lists:sort(fun(A, B) -> A >= B end, [1, 3, 2])}.
      is_odd(X) -> X rem 2 =:= 1.
      """

      assert run(source) == {:ok, {[3, 6], 6, [1, 3], [3, 2, 1]}}
    end

    test "a fun with no matching clause raises function_clause" do
      source = """
      result(_) ->
        F = fun(0) -> zero end,
        try F(1) catch error:function_clause -> caught end.
      """

      assert run(source, pub(%{terms: %{allowed_atoms: [:function_clause]}})) == {:ok, "caught"}
    end

    test "map and fold over a 10k list with a closure" do
      source = """
      result(_) ->
        K = 2,
        L = lists:seq(1, 10000),
        {lists:sum(lists:map(fun(X) -> X * K end, L)), lists:foldl(fun(X, A) -> X + A end, 0, L)}.
      """

      assert run(source, pub(%{limits: %{max_list_length: 20_000}})) ==
               {:ok, {100_010_000, 50_005_000}}
    end
  end

  describe "comprehension semantics" do
    test "multi-generator comprehensions keep order, filters and bindings" do
      source = """
      result(_) ->
        L = [1, 2, 3],
        {[{X, Y} || X <- L, X > 1, Y <- L, Y < X],
         [Z || X <- L, X > 1, Z <- [X * 2], Y <- [Z], Y =:= Z],
         << <<X, Y>> || X <- [1, 2], <<Y>> <= <<7, 8>> >>,
         \#{{X, Y} => X + Y || X <- [1, 2], Y <- [10]},
         [X || X <- [], Y <- L]}.
      """

      assert run(source) ==
               {:ok,
                {[{2, 1}, {3, 1}, {3, 2}], [4, 6], <<1, 7, 1, 8, 2, 7, 2, 8>>,
                 %{{1, 10} => 11, {2, 10} => 12}, []}}
    end

    test "an inner generator that is not a list raises bad_generator" do
      source = """
      result(_) ->
        try [Y || X <- [1, 2], Y <- X] catch error:{bad_generator, V} -> {bad, V} end.
      """

      assert run(source, pub(%{terms: %{allowed_atoms: [:bad_generator, :bad]}})) ==
               {:ok, {:bad, 1}}
    end

    test "a record filter that is a guard skips; one that is an expression raises" do
      source = """
      -record(r, {a = 1}).
      result(_) ->
        L = [#r{a = 5}, {other}],
        Guard = [R || R <- L, R#r.a > 1],
        Expr = try [R || R <- L, check(R#r.a)] catch error:{badrecord, _} -> badrecord end,
        {length(Guard), Expr}.
      check(X) -> X > 1.
      """

      assert run(source, pub(%{terms: %{allowed_atoms: [:badrecord]}})) ==
               {:ok, {1, :badrecord}}
    end

    test "comprehensions inside funs inside comprehensions" do
      source = """
      result(_) ->
        L = [1, 2],
        Fs = [fun() -> [X * Y || Y <- L] end || X <- L],
        [F() || F <- Fs].
      """

      assert run(source) == {:ok, [[1, 2], [2, 4]]}
    end
  end

  describe "stack traces" do
    test "frames inside lifted constructs name the guest function that wrote them" do
      for {construct, marker} <- [
            {"(fun(X) -> X + 1 end)(zzz)", "-result/1-fun-"},
            {"[X + 1 || X <- [zzz]]", "-result/1-lc-"},
            {"(fun F(0) -> 0; F(N) -> F(N + zzz) end)(1)", "-result/1-fun-"}
          ] do
        {:error, %{details: %{"stack" => stack}}} = run("result(_) -> #{construct}.")
        functions = Enum.map(stack, & &1["function"])
        assert Enum.all?(stack, &(&1["module"] in ["guest", "erlang"])), inspect(stack)
        assert Enum.any?(functions, &String.starts_with?(&1, marker)), inspect(functions)
        refute inspect(stack) =~ "safe_f_"
      end
    end
  end

  describe "generated-form invariants" do
    test "codegen rejects a compiler-named construct outside a lifted function" do
      forms = [
        {:attribute, 0, :module, :hyperlang_pending_slot},
        {:attribute, 0, :export,
         [{:"$safe_entry", 3}, {:"$safe_export", 4}, {:"$safe_raw_export", 3}]},
        {:function, 0, :safe_f_0, 2,
         [
           {:clause, 0, [{:var, 0, :ctx}, {:var, 0, :x}], [],
            [
              {:lc, 0, {:var, 0, :y}, [{:generate, 0, {:var, 0, :y}, {:var, 0, :x}}]},
              {:fun, 0, {:clauses, [{:clause, 0, [], [], [{:atom, 0, :ok}]}]}}
            ]}
         ]}
      ]

      assert {:error, %{message: message}} = Hyperlang.Codegen.verify_generated_forms(forms)
      assert message =~ "compiler-named construct"
    end

    test "a function over the binary pattern split limit is refused" do
      clauses =
        Enum.map_join(1..5, "\n", &"s(<<#{&1}, S:8, D:S/binary, _/binary>>) -> D;") <>
          "\ns(_) -> none."

      source = "result(_) -> s(<<1, 1, 9>>).\n" <> clauses
      assert run(source) == {:ok, <<9>>}

      assert {:error, [%{category: :codegen, message: "binary pattern split limit exceeded"}]} =
               run(source, pub(%{limits: %{max_pattern_splits: 4}}))
    end

    test "max_pattern_splits is capped by the fixed compiler name set" do
      assert {:error, [%{category: :manifest, message: message}]} =
               Hyperlang.Test.program(
                 "result(_) -> ok.",
                 %{limits: %{max_pattern_splits: GeneratedAtoms.max_pattern_splits() + 1}}
               )

      assert message =~ "max_pattern_splits"
    end
  end
end
