defmodule Hyperlang.GeneratedAtoms do
  @moduledoc false

  # Hyperlang's generated atom families. Each family is a fixed name set
  # `<prefix>N` with `0 <= N < cap`; guest source never chooses a name, only
  # how many of a family a program needs. An atom is materialized the first
  # time any program needs its index, so the VM atom table pays for the
  # high-water mark of real use, not for the caps. The caps are host
  # configuration (compile time):
  #
  #   :source_atom_count         hyperlang_atom_N          per atom universe
  #   :kernel_source_atom_count  hyperlang_kernel_atom_N   per evaluation bridge
  #   :function_atom_count       safe_f_N                  per generated module
  #   :variable_atom_count       v_N                       per generated module
  #
  # Every atom Hyperlang creates, from these families and from the OTP
  # compiler's local-function names for guest code, passes the atom-table
  # reserve check below: Hyperlang never takes the VM atom table to fewer than
  # `:atom_table_reserve` free entries (default: a quarter of the table).
  require Application

  @source_atom_count Application.compile_env(:hyperlang, :source_atom_count, 4_096)
  @kernel_source_atom_count Application.compile_env(:hyperlang, :kernel_source_atom_count, 4_096)
  @function_count Application.compile_env(:hyperlang, :function_atom_count, 8_192)
  @variable_count Application.compile_env(:hyperlang, :variable_atom_count, 524_288)

  @source_prefix "hyperlang_atom_"
  @kernel_source_prefix "hyperlang_kernel_atom_"
  @function_prefix "safe_f_"
  @variable_prefix "v_"

  @families [
    {@source_prefix, @source_atom_count},
    {@kernel_source_prefix, @kernel_source_atom_count},
    {@function_prefix, @function_count},
    {@variable_prefix, @variable_count}
  ]

  # Atom-table entries currently promised to in-flight OTP compiles.
  @inflight_key {__MODULE__, :inflight}

  def max_source_atoms, do: @source_atom_count
  def max_kernel_source_atoms, do: @kernel_source_atom_count
  def max_functions, do: @function_count
  def max_variables, do: @variable_count

  def source_atom(index), do: materialize(@source_prefix, @source_atom_count, index)

  def kernel_source_atom(index),
    do: materialize(@kernel_source_prefix, @kernel_source_atom_count, index)

  def function!(index), do: materialize!(@function_prefix, @function_count, index, :function)
  def variable!(index), do: materialize!(@variable_prefix, @variable_count, index, :variable)

  def source_atom?(atom) when is_atom(atom),
    do: family_index(Atom.to_string(atom), @source_prefix, @source_atom_count) != nil

  def source_atom?(_value), do: false

  # True for every name of every family, materialized or not. Callers that
  # decide behaviour by atom EXISTENCE use it so their answer for these names
  # never depends on which indices other programs have materialized.
  def family_name?(name) when is_binary(name),
    do: Enum.any?(@families, fn {prefix, count} -> family_index(name, prefix, count) != nil end)

  def family_name?(_name), do: false

  # The free atom-table entries Hyperlang must leave to the host.
  def atom_table_reserve do
    case Application.get_env(:hyperlang, :atom_table_reserve) do
      reserve when is_integer(reserve) and reserve >= 0 -> reserve
      _ -> div(:erlang.system_info(:atom_limit), 4)
    end
  end

  # Runs `fun` with `count` atom-table entries promised to it. `count` is an
  # upper bound on the atoms `fun` may create; concurrent callers see each
  # other's promises, so together they cannot cross the reserve.
  def with_atom_headroom(count, fun) when is_integer(count) and count >= 0 do
    ref = inflight_ref()
    promised = :atomics.add_get(ref, 1, count)

    try do
      if :erlang.system_info(:atom_count) + promised <= atom_table_ceiling() do
        fun.()
      else
        {:error, :atom_table_reserve}
      end
    after
      :atomics.sub(ref, 1, count)
    end
  end

  def reserve_error do
    Hyperlang.Error.new(:compile, "VM atom table reserve reached",
      details: %{
        atom_limit: :erlang.system_info(:atom_limit),
        atom_table_reserve: atom_table_reserve()
      }
    )
  end

  # Compiler-made names. Generated code (verified by
  # `Hyperlang.Codegen.verify_generated_forms/1`) gives the OTP 29 compiler
  # exactly these name sources:
  #
  #   lifted `safe_f_N/2` holding a fun        -safe_f_N/2-fun-0-   (+ recv$^1)
  #   lifted `safe_f_N/2` holding an lc or mc  -safe_f_N/2-lc$^0/1-0-, lc$^0
  #   lifted `safe_f_N/2` holding a bc         -safe_f_N/2-lbc$^0/2-0-, lbc$^0
  #   `$safe_entry/3`, `$safe_export/4` thunks -$safe_entry/3-fun-K- (K < 2),
  #                                            -$safe_export/4-fun-K- (K < 3)
  #   clause splits of binary patterns         label^K (K < split weight)
  #
  # Every other function has total clauses (no `-inlined-` fallback name),
  # no records (no `recN` variables) and is compiled with `no_alias` (no
  # `@rN` variables). The whole set over every program is therefore
  # 3 * function_atom_count + pattern_split_count + 8 names.
  @fixed_compiler_names 8
  @pattern_split_count Application.compile_env(:hyperlang, :pattern_split_count, 1_024)

  def max_pattern_splits, do: @pattern_split_count

  def compiler_name_bound,
    do: 3 * @function_count + @pattern_split_count + @fixed_compiler_names

  # The exact set of names one OTP compile of `forms` can create.
  def compiler_atom_names(forms) do
    functions = for {:function, _anno, name, arity, clauses} <- forms, do: {name, arity, clauses}

    splits =
      functions
      |> Enum.map(fn {_name, _arity, clauses} -> pattern_split_weight(clauses) end)
      |> Enum.max(fn -> 0 end)

    functions
    |> Enum.flat_map(&construct_names/1)
    |> Kernel.++(Enum.map(0..(splits - 1)//1, &"label^#{&1}"))
    |> Enum.uniq()
  end

  # The atoms one OTP compile of `forms` can add to the table: the names of
  # `compiler_atom_names/1` that do not exist yet.
  def compiler_atom_bound(forms) do
    forms
    |> compiler_atom_names()
    |> Enum.count(fn name ->
      try do
        _ = :erlang.binary_to_existing_atom(name, :utf8)
        false
      rescue
        ArgumentError -> true
      end
    end)
  end

  defp construct_names({name, arity, [{:clause, _, _, _, [body]} | _]} = function) do
    prefix = "-#{name}/#{arity}-"

    case body do
      {:fun, _, {:clauses, clauses}} ->
        recv = if receive?(clauses), do: ["recv$^1"], else: []
        [prefix <> "fun-0-" | recv]

      {:call, _, {:atom, _, _}, [{:lc, _, _, _}]} ->
        ["lc$^0", prefix <> "lc$^0/1-0-"]

      {kind, _, _, _} when kind in [:lc, :mc] ->
        ["lc$^0", prefix <> "lc$^0/1-0-"]

      {:bc, _, _, _} ->
        ["lbc$^0", prefix <> "lbc$^0/2-0-"]

      _other ->
        thunk_names(function)
    end
  end

  defp construct_names(function), do: thunk_names(function)

  defp thunk_names({name, arity, clauses}) do
    Enum.map(0..(count_funs(clauses) - 1)//1, &"-#{name}/#{arity}-fun-#{&1}-")
  end

  defp count_funs({:fun, _, {:clauses, clauses}}), do: 1 + count_funs(clauses)

  defp count_funs(term) when is_tuple(term), do: term |> Tuple.to_list() |> count_funs()
  defp count_funs(term) when is_list(term), do: Enum.reduce(term, 0, &(&2 + count_funs(&1)))
  defp count_funs(_term), do: 0

  defp receive?({:receive, _, _}), do: true
  defp receive?({:receive, _, _, _, _}), do: true
  defp receive?(term) when is_tuple(term), do: term |> Tuple.to_list() |> receive?()
  defp receive?(term) when is_list(term), do: Enum.any?(term, &receive?/1)
  defp receive?(_term), do: false

  # Upper bound of the clause splits `v3_core` makes in one function, each
  # named `label^K`: a binary segment in a pattern whose size is not a
  # literal (a variable bound earlier in the same binary, or an expression),
  # and a pattern that aliases two binaries. Generator patterns count three
  # times: the comprehension's accumulate, skip and tail clauses copy them.
  def pattern_split_weight(clauses), do: split_expr(clauses)

  defp split_expr({:clause, _, patterns, guards, body}),
    do: split_pattern(patterns) + split_expr(guards) + split_expr(body)

  defp split_expr({:match, _, pattern, expr}), do: split_pattern(pattern) + split_expr(expr)

  defp split_expr({tag, _, pattern, expr}) when tag in [:generate, :b_generate],
    do: 3 * split_pattern(pattern) + split_expr(expr)

  defp split_expr(term) when is_tuple(term), do: term |> Tuple.to_list() |> split_expr()
  defp split_expr(term) when is_list(term), do: Enum.reduce(term, 0, &(&2 + split_expr(&1)))
  defp split_expr(_term), do: 0

  defp split_pattern({:bin_element, _, value, size, _types}) do
    split = if size == :default or match?({:integer, _, _}, size), do: 0, else: 1
    split + split_pattern(value)
  end

  defp split_pattern({:match, _, {:bin, _, _} = left, {:bin, _, _} = right}),
    do: 1 + split_pattern(left) + split_pattern(right)

  defp split_pattern(term) when is_tuple(term), do: term |> Tuple.to_list() |> split_pattern()
  defp split_pattern(term) when is_list(term), do: Enum.reduce(term, 0, &(&2 + split_pattern(&1)))
  defp split_pattern(_term), do: 0

  def init_inflight do
    case :persistent_term.get(@inflight_key, nil) do
      nil -> :persistent_term.put(@inflight_key, :atomics.new(1, signed: true))
      _ref -> :ok
    end
  end

  defp inflight_ref do
    case :persistent_term.get(@inflight_key, nil) do
      nil ->
        :ok = Hyperlang.AtomUniverse.ensure_started()
        :persistent_term.get(@inflight_key)

      ref ->
        ref
    end
  end

  defp atom_table_ceiling, do: :erlang.system_info(:atom_limit) - atom_table_reserve()

  defp materialize(prefix, count, index)
       when is_integer(index) and index >= 0 and index < count do
    name = prefix <> Integer.to_string(index)

    try do
      {:ok, :erlang.binary_to_existing_atom(name, :utf8)}
    rescue
      ArgumentError -> create(name)
    end
  end

  defp materialize(_prefix, _count, _index), do: {:error, :exhausted}

  defp create(name) do
    if :erlang.system_info(:atom_count) + :atomics.get(inflight_ref(), 1) <
         atom_table_ceiling() do
      {:ok, :erlang.binary_to_atom(name, :utf8)}
    else
      {:error, :atom_table_reserve}
    end
  end

  # Lowering and codegen run inside one compile worker; the throw unwinds to
  # its boundary, which turns it into a compile error.
  defp materialize!(prefix, count, index, kind) do
    case materialize(prefix, count, index) do
      {:ok, atom} -> atom
      {:error, reason} -> throw({:hyperlang_generated_atom, kind, reason})
    end
  end

  defp family_index(name, prefix, count) do
    size = byte_size(prefix)

    case name do
      <<^prefix::binary-size(^size), digits::binary>> -> canonical_index(digits, count)
      _ -> nil
    end
  end

  defp canonical_index("0", count) when count > 0, do: 0

  defp canonical_index(<<first, _::binary>> = digits, count) when first in ?1..?9 do
    case Integer.parse(digits) do
      {index, ""} when index < count -> index
      _ -> nil
    end
  end

  defp canonical_index(_digits, _count), do: nil
end
