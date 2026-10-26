defmodule Hyperlang.Compiler do
  @moduledoc false

  @bounded_key {__MODULE__, :bounded}
  @reduction_sample_ms 5

  alias Hyperlang.{Classifier, Core, OtpFrontend, Verifier}

  def compile(source, manifest) do
    manifest = assert_atom_universe!(manifest)

    run_bounded(manifest.limits, fn ->
      with {:ok, compiled} <- compile_core_unbounded(source, manifest) do
        materialize_unbounded(compiled, manifest)
      end
    end)
  end

  def compile_ast(ast, manifest) when is_map(ast) do
    manifest = assert_atom_universe!(manifest)

    run_bounded(manifest.limits, fn ->
      with {:ok, compiled} <- compile_ast_core_unbounded(ast, manifest) do
        materialize_unbounded(compiled, manifest)
      end
    end)
  end

  def verify_module_source(source, manifest) when is_binary(source) do
    manifest = assert_atom_universe!(manifest)

    run_bounded(manifest.limits, fn ->
      verify_module_source_unbounded(source, manifest)
    end)
  end

  defp verify_module_source_unbounded(source, manifest) do
    try do
      with {:ok, ast} <- OtpFrontend.parse(source, manifest),
           {:ok, core} <- lower_verification_module(ast, manifest),
           {:ok, core} <- attach_atom_sources(core, manifest),
           :ok <- Verifier.verify(core, manifest),
           {:ok, core} <- Classifier.classify(core, manifest),
           :ok <- Verifier.verify(core, manifest) do
        {:ok, core}
      end
    catch
      {:hyperlang_parse_limit, limit} ->
        {:error, Hyperlang.Error.new(:parse, "parse limit exceeded", details: %{limit: limit})}
    end
  end

  defp compile_core_unbounded(source, manifest) do
    try do
      with {:ok, ast} <- OtpFrontend.parse(source, manifest) do
        compile_ast_core_unbounded(ast, manifest)
      end
    catch
      {:hyperlang_parse_limit, limit} ->
        {:error, Hyperlang.Error.new(:parse, "parse limit exceeded", details: %{limit: limit})}
    end
  end

  defp compile_ast_core_unbounded(ast, manifest) do
    with {:ok, core} <- lower(ast, manifest),
         :ok <- validate_declared_export_functions(core, manifest),
         {:ok, core} <- attach_export_metadata(core, manifest),
         {:ok, core} <- attach_atom_sources(core, manifest),
         :ok <- Verifier.verify(core, manifest),
         {:ok, core} <- Classifier.classify(core, manifest),
         :ok <- Verifier.verify(core, manifest) do
      {:ok, %{source_format: ast.type, core: core, frontend: OtpFrontend.frontend()}}
    end
  end

  defp materialize_unbounded(%{core: %Core{} = core} = compiled, manifest) do
    with {:ok, core} <- attach_atom_pool(core, manifest) do
      {:ok, %{compiled | core: core}}
    end
  end

  # Every entry point is reached with a normalized manifest, which carries an
  # atom universe. An unseeded manifest is a caller defect, not a case to seed
  # around silently: a third seeding scheme here would mint atoms in a
  # namespace no artifact identity accounts for.
  defp assert_atom_universe!(%{atom_universe: nil}) do
    raise ArgumentError,
          "compiler entered with an unseeded atom universe; normalize the manifest first"
  end

  defp assert_atom_universe!(%{} = manifest), do: manifest

  # One compile worker runs the whole parse, verify, classify, codegen and OTP
  # compile path. Its budget is `limits.max_compile_reductions`, the reductions
  # the worker itself executes; OTP compilation runs in the worker
  # (`no_spawn_compiler_process`) and is charged. Reductions do not depend on
  # host load, so admission of a given program is the same on an idle and on a
  # saturated node. `limits.max_compile_ms` is a wall-clock backstop for work
  # that does not execute reductions (blocking, non-yielding native code).
  # The heap allowance is the current scope's `compile_heap_words`.
  def run_bounded(limits, fun),
    do:
      run_bounded(
        limits,
        Hyperlang.Scope.policy(Hyperlang.Scope.current()).compile_heap_words,
        fun
      )

  def run_bounded(%{max_compile_ms: _, max_compile_reductions: _} = limits, heap_words, fun) do
    if Process.get(@bounded_key, false) do
      fun.()
    else
      acquire_compile_worker(limits, heap_words, fun)
    end
  end

  defp acquire_compile_worker(limits, heap_words, fun) do
    scope = Hyperlang.Scope.current()

    case Hyperlang.Scope.acquire(scope, :compile) do
      {:ok, lease} ->
        try do
          run_compile_worker(limits, heap_words, scope, fun)
        after
          Hyperlang.Scope.release(lease)
        end

      {:error, error} ->
        {:error, Hyperlang.Error.new(:busy, "compilation busy", details: %{reason: error.reason})}
    end
  end

  defp run_compile_worker(limits, heap_words, scope, fun) do
    parent = self()
    ref = make_ref()
    fault = :atomics.new(1, [])

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          :ok = Hyperlang.Scope.attach(scope, self(), :compile, heap_words, parent, fault)

          result =
            Hyperlang.Scope.with_scope(scope, fn ->
              Process.put(@bounded_key, true)

              try do
                fun.()
              catch
                :throw, {:hyperlang_generated_atom, _kind, :atom_table_reserve} ->
                  {:error, Hyperlang.GeneratedAtoms.reserve_error()}

                :throw, {:hyperlang_generated_atom, kind, :exhausted} ->
                  {:error,
                   Hyperlang.Error.new(:codegen, "generated atom pool exhausted",
                     details: %{pool: kind}
                   )}

                class, reason ->
                  {:error,
                   Hyperlang.Error.new(
                     :internal_compile,
                     "internal compiler error",
                     details: %{
                       class: class,
                       reason: inspect(reason),
                       stack: stack_summary(__STACKTRACE__)
                     }
                   )}
              end
            end)

          :ok = Hyperlang.Scope.detach(scope, self())
          {:reductions, used} = Process.info(self(), :reductions)
          send(parent, {ref, result, used})
        end,
        [
          :monitor,
          {:priority, Hyperlang.Scope.priority(scope)},
          {:message_queue_data, :on_heap},
          {:max_heap_size,
           %{
             size: heap_words,
             kill: true,
             error_logger: false,
             include_shared_binaries: true
           }}
        ]
      )

    deadline = System.monotonic_time(:millisecond) + limits.max_compile_ms
    await_compile_worker(pid, monitor, ref, fault, limits.max_compile_reductions, deadline)
  end

  # The reduction budget is checked every `@reduction_sample_ms`, which bounds
  # the overshoot of a stopped worker to one sample period. A worker that
  # finishes reports its own total, and a total over budget is rejected too,
  # so the decision does not depend on how fast the worker ran.
  defp await_compile_worker(pid, monitor, ref, fault, max_reductions, deadline) do
    wait_ms = min(@reduction_sample_ms, max(0, deadline - System.monotonic_time(:millisecond)))

    receive do
      {^ref, _result, used} when used > max_reductions ->
        Process.demonitor(monitor, [:flush])

        {:error,
         Hyperlang.Error.new(:compile_budget, "compile reduction budget exceeded",
           details: %{limit: max_reductions}
         )}

      {^ref, result, _used} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        case Hyperlang.Scope.fault_reason(fault) do
          {:error, error} ->
            {:error,
             Hyperlang.Error.new(:busy, "compilation scope terminated",
               details: %{reason: error.reason}
             )}

          :ok ->
            {:error,
             Hyperlang.Error.new(:compile, "compile worker exited",
               details: %{reason: inspect(reason)}
             )}
        end
    after
      wait_ms ->
        cond do
          worker_reductions(pid) > max_reductions ->
            stop_compile_worker(pid, monitor, ref)

            {:error,
             Hyperlang.Error.new(:compile_budget, "compile reduction budget exceeded",
               details: %{limit: max_reductions}
             )}

          System.monotonic_time(:millisecond) >= deadline ->
            stop_compile_worker(pid, monitor, ref)
            {:error, Hyperlang.Error.new(:compile_timeout, "compile wall time exceeded")}

          true ->
            await_compile_worker(pid, monitor, ref, fault, max_reductions, deadline)
        end
    end
  end

  defp worker_reductions(pid) do
    case Process.info(pid, :reductions) do
      {:reductions, reductions} -> reductions
      nil -> 0
    end
  end

  # A result sent between the last check and the kill is dropped with the
  # worker: the budget decision stands.
  defp stop_compile_worker(pid, monitor, ref) do
    Process.exit(pid, :kill)
    Process.demonitor(monitor, [:flush])

    receive do
      {^ref, _result, _used} -> :ok
    after
      0 -> :ok
    end
  end

  defp stack_summary(stack) do
    stack
    |> Enum.take(8)
    |> Enum.map(&stack_entry/1)
  end

  defp stack_entry({module, function, arity_or_args, location}) do
    %{
      module: inspect(module),
      function: function,
      arity: stack_arity(arity_or_args),
      file: location |> Keyword.get(:file) |> file_to_string(),
      line: Keyword.get(location, :line)
    }
  end

  defp stack_entry(other), do: %{entry: inspect(other)}

  defp stack_arity(arity) when is_integer(arity), do: arity
  defp stack_arity(args) when is_list(args), do: length(args)
  defp stack_arity(_), do: nil

  defp file_to_string(nil), do: nil
  defp file_to_string(file) when is_list(file), do: List.to_string(file)
  defp file_to_string(file), do: inspect(file)

  defp lower(%{type: :expression_bundle, expr: expr} = ast, manifest) do
    result_name = manifest.result.name
    safe_name = :safe_result

    clause = %Core.Clause{patterns: [%{node: :var_pattern, name: "Input"}], body: expr, vars: %{}}

    fun = %Core.Function{
      source_name: result_name,
      safe_name: safe_name,
      arity: 1,
      span: Map.get(manifest.result, :span),
      clauses: [clause]
    }

    {:ok,
     %Core{
       result: %{
         source_name: result_name,
         safe_name: safe_name,
         arity: 1,
         span: Map.get(manifest.result, :span)
       },
       functions: %{{result_name, 1} => fun},
       function_order: [{result_name, 1}],
       metadata: Map.merge(%{source_format: :expression_bundle}, source_contract_metadata(ast))
     }}
  end

  defp lower(%{type: :function_program, functions: functions} = ast, manifest) do
    max_functions = manifest.limits.max_functions
    function_order = Enum.map(functions, &function_key/1)

    cond do
      length(functions) > max_functions ->
        {:error, Hyperlang.Error.new(:verify, "function count exceeds limit")}

      length(function_order) != length(Enum.uniq(function_order)) ->
        {:error, Hyperlang.Error.new(:verify, "duplicate function name/arity")}

      reserved_source_function?(functions) ->
        {:error,
         Hyperlang.Error.new(:verify, "function name uses reserved Hyperlang internal name")}

      true ->
        indexed =
          functions
          |> Enum.with_index()
          |> Map.new(fn {fun, idx} ->
            {function_key(fun),
             %Core.Function{
               source_name: fun.name,
               safe_name: Hyperlang.GeneratedAtoms.function!(idx),
               arity: fun.arity,
               span: Map.get(fun, :span),
               clauses: Enum.map(fun.clauses, &lower_clause/1)
             }}
          end)

        {indexed, function_order} =
          maybe_adapt_zero_arity_result(indexed, function_order, manifest)

        result_name = manifest.result.name
        result_key = {result_name, manifest.result.arity}

        case Map.fetch(indexed, result_key) do
          {:ok, result_fun} ->
            {:ok,
             %Core{
               result: %{
                 source_name: result_name,
                 safe_name: result_fun.safe_name,
                 arity: result_fun.arity,
                 span: result_fun.span
               },
               functions: indexed,
               function_order: function_order,
               metadata:
                 Map.merge(%{source_format: :function_program}, source_contract_metadata(ast))
             }}

          :error ->
            cond do
              Enum.any?(indexed, fn {{name, _arity}, _fun} -> name == result_name end) ->
                {:error, Hyperlang.Error.new(:verify, "result root has wrong arity")}

              export_only_result_optional?(manifest) ->
                {:ok,
                 %Core{
                   result: nil,
                   functions: indexed,
                   function_order: function_order,
                   metadata:
                     Map.merge(%{source_format: :function_program}, source_contract_metadata(ast))
                 }}

              true ->
                {:error,
                 Hyperlang.Error.new(:verify, "result root #{inspect(result_name)} not found")}
            end
        end
    end
  end

  defp lower_verification_module(%{type: :function_program, functions: functions} = ast, manifest) do
    max_functions = manifest.limits.max_functions
    function_order = Enum.map(functions, &function_key/1)

    cond do
      length(functions) > max_functions ->
        {:error, Hyperlang.Error.new(:verify, "function count exceeds limit")}

      length(function_order) != length(Enum.uniq(function_order)) ->
        {:error, Hyperlang.Error.new(:verify, "duplicate function name/arity")}

      reserved_source_function?(functions) ->
        {:error,
         Hyperlang.Error.new(:verify, "function name uses reserved Hyperlang internal name")}

      true ->
        indexed =
          functions
          |> Enum.with_index()
          |> Map.new(fn {fun, idx} ->
            {function_key(fun),
             %Core.Function{
               source_name: fun.name,
               safe_name: Hyperlang.GeneratedAtoms.function!(idx),
               arity: fun.arity,
               span: Map.get(fun, :span),
               clauses: Enum.map(fun.clauses, &lower_clause/1)
             }}
          end)

        {:ok,
         %Core{
           result: nil,
           functions: indexed,
           function_order: function_order,
           metadata:
             Map.merge(
               %{source_format: :loader_module_verification},
               source_contract_metadata(ast)
             )
         }}
    end
  end

  defp lower_verification_module(_ast, _manifest) do
    {:error, Hyperlang.Error.new(:verify, "loader source must contain Erlang functions")}
  end

  defp validate_declared_export_functions(%Core{} = core, %{exports: exports}) do
    exports
    |> declared_export_targets()
    |> Enum.reduce_while(:ok, fn export, :ok ->
      key = {export.function, export.arity}

      cond do
        Map.has_key?(core.functions, key) ->
          {:cont, :ok}

        Enum.any?(core.functions, fn {{name, _arity}, _fun} -> name == export.function end) ->
          {:halt,
           {:error, Hyperlang.Error.new(:verify, "declared export function has wrong arity")}}

        true ->
          {:halt, {:error, Hyperlang.Error.new(:verify, "declared export function not found")}}
      end
    end)
  end

  defp validate_declared_export_functions(%Core{}, _manifest), do: :ok

  defp declared_export_targets(%{functions: functions, files: files}) do
    Map.values(functions) ++
      declared_file_export_targets(files) ++
      declared_file_dependency_targets(files)
  end

  defp declared_export_targets(_exports), do: []

  defp declared_file_export_targets(files) when is_list(files) do
    Enum.filter(files, fn
      %{function: function, arity: arity} -> is_binary(function) and is_integer(arity)
      _file -> false
    end)
  end

  defp declared_file_export_targets(_files), do: []

  defp declared_file_dependency_targets(files) when is_list(files) do
    Enum.flat_map(files, fn file ->
      case Hyperlang.Manifest.file_dependency_export(file) do
        {:ok, _id, export} -> [export]
        :none -> []
      end
    end)
  end

  defp export_only_result_optional?(manifest) do
    not Map.get(manifest, :result_explicit?, false) and has_declared_exports?(manifest)
  end

  defp has_declared_exports?(%{exports: %{functions: functions, files: files}}) do
    map_size(functions) > 0 or files != []
  end

  defp has_declared_exports?(_manifest), do: false

  defp reserved_source_function?(functions) do
    Enum.any?(functions, fn fun -> Hyperlang.Manifest.reserved_internal_name?(fun.name) end)
  end

  defp attach_export_metadata(%Core{} = core, %{exports: exports}) do
    {:ok, %{core | metadata: Map.put(core.metadata, :exports, exports)}}
  end

  defp attach_export_metadata(%Core{} = core, _manifest), do: {:ok, core}

  defp function_key(%{name: name, arity: arity}), do: {name, arity}

  defp maybe_adapt_zero_arity_result(indexed, function_order, manifest) do
    result_name = manifest.result.name
    result_key = {result_name, manifest.result.arity}
    zero_key = {result_name, 0}

    if manifest.result.arity == 1 and not Map.has_key?(indexed, result_key) and
         Map.has_key?(indexed, zero_key) do
      %Core.Function{} = fun = Map.fetch!(indexed, zero_key)

      indexed =
        indexed
        |> Map.delete(zero_key)
        |> Map.put(result_key, %Core.Function{
          fun
          | arity: 1,
            clauses: Enum.map(fun.clauses, &ignore_result_input/1)
        })

      function_order =
        Enum.map(function_order, fn
          ^zero_key -> result_key
          key -> key
        end)

      {indexed, function_order}
    else
      {indexed, function_order}
    end
  end

  defp ignore_result_input(%Core.Clause{} = clause) do
    %{clause | patterns: [%{node: :wild_pattern} | clause.patterns]}
  end

  defp source_contract_metadata(ast) do
    %{}
    |> maybe_put_ast_metadata(:source_contract, ast)
    |> maybe_put_ast_metadata(:module_metadata, ast)
    |> maybe_put_ast_metadata(:records, ast)
  end

  defp maybe_put_ast_metadata(metadata, key, ast) do
    case Map.get(ast, key) do
      nil -> metadata
      value -> Map.put(metadata, key, value)
    end
  end

  defp lower_clause(clause) do
    %Core.Clause{
      patterns: clause.patterns,
      guard: clause.guard,
      body: clause.body,
      vars: %{}
    }
  end

  defp attach_atom_sources(%Core{} = core, manifest) do
    function_atoms =
      core.functions
      |> Map.values()
      |> Enum.flat_map(&function_atoms/1)

    record_atoms =
      core.metadata
      |> Map.get(:records, [])
      |> Enum.flat_map(fn record ->
        [
          record.name
          | Enum.flat_map(record.fields, fn field -> [field.name | expr_atoms(field.default)] end)
        ]
      end)

    source_atoms =
      (function_atoms ++ record_atoms)
      |> Enum.uniq()

    allowed = allowed_atom_names(manifest)
    compat_atoms = compatible_existing_source_atoms(source_atoms, manifest)
    compat_names = MapSet.new(compat_atoms, &Atom.to_string/1)

    pooled =
      Enum.reject(source_atoms, fn source ->
        MapSet.member?(allowed, source) or MapSet.member?(compat_names, source)
      end)

    cond do
      "$hyperlang_msg" in source_atoms ->
        {:error,
         Hyperlang.Error.new(:verify, "atom literal uses reserved Hyperlang internal name")}

      length(pooled) > manifest.limits.max_atom_count ->
        {:error, Hyperlang.Error.new(:verify, "source atom pool exceeds limit")}

      true ->
        metadata =
          Map.put(core.metadata, :atom_pool, %{
            source_atoms: pooled,
            source_to_pool: Map.new(pooled, &{&1, nil}),
            pool_to_source: %{},
            allowed_source_atoms: MapSet.union(allowed, compat_names),
            compat_source_atoms: compat_atoms
          })

        {:ok, %{core | metadata: metadata}}
    end
  end

  defp attach_atom_pool(%Core{} = core, manifest) do
    atom_pool = Map.get(core.metadata || %{}, :atom_pool, %{})

    source_atoms =
      Map.get(atom_pool, :source_atoms, Map.keys(Map.get(atom_pool, :source_to_pool, %{})))

    with {:ok, source_to_pool, pool_to_source} <-
           Hyperlang.AtomUniverse.reserve(Map.get(manifest, :atom_universe), source_atoms) do
      metadata =
        Map.put(core.metadata, :atom_pool, %{
          source_atoms: source_atoms,
          source_to_pool: source_to_pool,
          pool_to_source: pool_to_source,
          allowed_source_atoms:
            Map.get(atom_pool, :allowed_source_atoms, allowed_atom_names(manifest)),
          compat_source_atoms: Map.get(atom_pool, :compat_source_atoms, MapSet.new()),
          atom_universe: Map.get(manifest, :atom_universe)
        })

      {:ok, %{core | metadata: metadata}}
    else
      {:error, :missing_atom_universe} ->
        {:error, Hyperlang.Error.new(:verify, "atom universe is required for materialization")}

      {:error, :atom_universe_exhausted} ->
        {:error, Hyperlang.Error.new(:verify, "Hyperlang atom universe exhausted")}

      {:error, :atom_table_reserve} ->
        {:error, Hyperlang.GeneratedAtoms.reserve_error()}

      {:error, reason} ->
        {:error,
         Hyperlang.Error.new(:verify, "atom universe reservation failed",
           details: %{reason: reason}
         )}
    end
  end

  defp allowed_atom_names(manifest) do
    manifest.terms.allowed_atoms
    |> Enum.map(&Atom.to_string/1)
    |> MapSet.new()
  end

  # Compatibility profile used by binding-driven tool programs (notably
  # ash_hyperlang): the host has deliberately pre-interned schema atoms before
  # compilation and expects those source literals to preserve identity at the
  # Erlang term boundary. Ordinary HyperBEAM programs keep the opaque atom
  # universe and therefore retain its no-existing-atom-leak guarantee.
  defp compatible_existing_source_atoms(source_atoms, manifest) do
    if manifest.terms.public == :erlang and manifest.modules.enabled and
         map_size(manifest.bindings) > 0 do
      Enum.reduce(source_atoms, MapSet.new(), fn source, acc ->
        cond do
          # Generated-family names (`v_N`, ...) exist only once some program
          # materialized them; deciding by existence would let one guest
          # observe another's pool use, so they always stay pooled.
          Hyperlang.Manifest.reserved_internal_name?(source) or
              Hyperlang.GeneratedAtoms.family_name?(source) ->
            acc

          true ->
            case existing_atom(source) do
              {:ok, atom} -> MapSet.put(acc, atom)
              :error -> acc
            end
        end
      end)
    else
      MapSet.new()
    end
  end

  defp existing_atom(source) when is_binary(source) do
    {:ok, String.to_existing_atom(source)}
  rescue
    ArgumentError -> :error
  end

  defp function_atoms(%Core.Function{} = function) do
    Enum.flat_map(function.clauses, &clause_atoms/1)
  end

  defp clause_atoms(%Core.Clause{} = clause) do
    [clause.guard, clause.body | clause.patterns]
    |> Enum.flat_map(&expr_atoms/1)
  end

  defp clause_atoms(%{patterns: patterns, guard: guard, body: body}) do
    [guard, body | patterns]
    |> Enum.flat_map(&expr_atoms/1)
  end

  defp clause_atoms(%{guard: guard, body: body}) do
    expr_atoms(guard) ++ expr_atoms(body)
  end

  defp expr_atoms(nil), do: []
  defp expr_atoms(%{node: :atom, value: value}), do: [value]
  defp expr_atoms(%{node: :literal_pattern, literal: literal}), do: expr_atoms(literal)

  defp expr_atoms(%{node: :alias_pattern, left: left, right: right}),
    do: expr_atoms(left) ++ expr_atoms(right)

  defp expr_atoms(%{node: :alias, left: left, right: right}),
    do: expr_atoms(left) ++ expr_atoms(right)

  defp expr_atoms(%{node: :tuple_pattern, items: items}), do: Enum.flat_map(items, &expr_atoms/1)
  defp expr_atoms(%{node: :list_pattern, items: items}), do: Enum.flat_map(items, &expr_atoms/1)

  defp expr_atoms(%{node: :cons_pattern, head: head, tail: tail}),
    do: expr_atoms(head) ++ expr_atoms(tail)

  defp expr_atoms(%{node: :map_pattern, fields: fields}) do
    Enum.flat_map(fields, fn field -> expr_atoms(field.key) ++ expr_atoms(field.value) end)
  end

  defp expr_atoms(%{node: :record_pattern, name: name, fields: fields}) do
    [name | Enum.flat_map(fields, fn field -> [field.name | expr_atoms(field.value)] end)]
  end

  defp expr_atoms(%{node: :tuple, items: items}), do: Enum.flat_map(items, &expr_atoms/1)
  defp expr_atoms(%{node: :list, items: items}), do: Enum.flat_map(items, &expr_atoms/1)
  defp expr_atoms(%{node: :block, exprs: exprs}), do: Enum.flat_map(exprs, &expr_atoms/1)

  defp expr_atoms(%{node: :cons, head: head, tail: tail}),
    do: expr_atoms(head) ++ expr_atoms(tail)

  defp expr_atoms(%{node: :binary, parts: parts}), do: Enum.flat_map(parts, &expr_atoms/1)

  defp expr_atoms(%{node: :bit_segment, expr: expr, size: :default}), do: expr_atoms(expr)

  defp expr_atoms(%{node: :bit_segment, expr: expr, size: size}),
    do: expr_atoms(expr) ++ expr_atoms(size)

  defp expr_atoms(%{node: :map, fields: fields}) do
    Enum.flat_map(fields, fn field -> expr_atoms(field.key) ++ expr_atoms(field.value) end)
  end

  defp expr_atoms(%{node: :map_update, base: base, fields: fields}) do
    expr_atoms(base) ++
      Enum.flat_map(fields, fn field -> expr_atoms(field.key) ++ expr_atoms(field.value) end)
  end

  defp expr_atoms(%{node: :record_create, name: name, fields: fields}) do
    [name | Enum.flat_map(fields, fn field -> [field.name | expr_atoms(field.value)] end)]
  end

  defp expr_atoms(%{node: :record_update, base: base, name: name, fields: fields}) do
    [
      name
      | expr_atoms(base) ++
          Enum.flat_map(fields, fn field -> [field.name | expr_atoms(field.value)] end)
    ]
  end

  defp expr_atoms(%{node: :record_access, base: base, name: name, field: field}),
    do: [name, field | expr_atoms(base)]

  defp expr_atoms(%{node: :record_index, name: name, field: field}), do: [name, field]
  defp expr_atoms(%{node: :record_info, item: item, name: name}), do: [item, name]

  defp expr_atoms(%{node: :match, pattern: pattern, expr: expr}),
    do: expr_atoms(pattern) ++ expr_atoms(expr)

  defp expr_atoms(%{node: :unary, expr: expr}), do: expr_atoms(expr)

  defp expr_atoms(%{node: :binary_op, left: left, right: right}),
    do: expr_atoms(left) ++ expr_atoms(right)

  defp expr_atoms(%{node: :send, target: target, message: message}),
    do: expr_atoms(target) ++ expr_atoms(message)

  defp expr_atoms(%{node: :native_spawn, fun: fun}), do: expr_atoms(fun)
  defp expr_atoms(%{node: :native_spawn_link, fun: fun}), do: expr_atoms(fun)
  defp expr_atoms(%{node: :native_spawn_monitor, fun: fun}), do: expr_atoms(fun)

  defp expr_atoms(%{node: :native_register, name: name, target: target}),
    do: expr_atoms(name) ++ expr_atoms(target)

  defp expr_atoms(%{node: :native_whereis, name: name}), do: expr_atoms(name)
  defp expr_atoms(%{node: :native_unregister, name: name}), do: expr_atoms(name)
  defp expr_atoms(%{node: :native_monitor, target: target}), do: expr_atoms(target)

  defp expr_atoms(%{node: node, target: target}) when node in [:native_link, :native_unlink],
    do: expr_atoms(target)

  defp expr_atoms(%{node: :native_demonitor, ref: ref, options: nil}), do: expr_atoms(ref)

  defp expr_atoms(%{node: :native_demonitor, ref: ref, options: options}),
    do: expr_atoms(ref) ++ expr_atoms(options)

  defp expr_atoms(%{node: :native_process_flag, flag: flag, value: value}),
    do: expr_atoms(flag) ++ expr_atoms(value)

  defp expr_atoms(%{node: :local_call, args: args}), do: Enum.flat_map(args, &expr_atoms/1)
  defp expr_atoms(%{node: :remote_call, args: args}), do: Enum.flat_map(args, &expr_atoms/1)

  defp expr_atoms(%{node: :dynamic_remote_call, args: args} = expr),
    do: expr_atoms(Map.get(expr, :module)) ++ Enum.flat_map(args, &expr_atoms/1)

  defp expr_atoms(%{node: node, module: module, args: args, candidates: candidates})
       when node in [:dynamic_snapshot_call, :safe_dynamic_snapshot_call] do
    expr_atoms(module) ++
      Enum.flat_map(args, &expr_atoms/1) ++
      Enum.flat_map(candidates, fn
        %{module: module} when is_binary(module) -> [module]
        _candidate -> []
      end)
  end

  defp expr_atoms(%{node: :safe_local_call, args: args}), do: Enum.flat_map(args, &expr_atoms/1)
  defp expr_atoms(%{node: :safe_import_call, args: args}), do: Enum.flat_map(args, &expr_atoms/1)
  defp expr_atoms(%{node: :safe_stdlib_call, args: args}), do: Enum.flat_map(args, &expr_atoms/1)

  defp expr_atoms(%{node: :safe_filesystem_call, args: args}),
    do: Enum.flat_map(args, &expr_atoms/1)

  defp expr_atoms(%{node: :safe_code_call, args: args}),
    do: Enum.flat_map(args, &expr_atoms/1)

  defp expr_atoms(%{node: :safe_table_call, args: args}),
    do: Enum.flat_map(args, &expr_atoms/1)

  defp expr_atoms(%{
         node: :safe_snapshot_apply,
         target: target,
         function: function,
         args: args,
         candidates: _candidates
       }) do
    expr_atoms(target) ++ expr_atoms(function) ++ expr_atoms(args)
  end

  defp expr_atoms(%{node: :fun, clauses: clauses}), do: Enum.flat_map(clauses, &clause_atoms/1)

  defp expr_atoms(%{node: :named_fun, clauses: clauses}),
    do: Enum.flat_map(clauses, &clause_atoms/1)

  defp expr_atoms(%{node: node}) when node in [:local_fun_ref, :safe_local_fun_ref], do: []

  defp expr_atoms(%{node: :fun_call, callee: callee, args: args}),
    do: expr_atoms(callee) ++ Enum.flat_map(args, &expr_atoms/1)

  defp expr_atoms(%{node: :case, expr: expr, clauses: clauses}),
    do: expr_atoms(expr) ++ Enum.flat_map(clauses, &clause_atoms/1)

  defp expr_atoms(%{node: :receive, clauses: clauses, timeout: timeout} = expr) do
    Enum.flat_map(clauses, &clause_atoms/1) ++
      expr_atoms(timeout) ++ expr_atoms(Map.get(expr, :after_body))
  end

  defp expr_atoms(%{node: :receive, clauses: clauses}),
    do: Enum.flat_map(clauses, &clause_atoms/1)

  defp expr_atoms(%{node: :if, clauses: clauses}), do: Enum.flat_map(clauses, &clause_atoms/1)

  defp expr_atoms(%{
         node: :try,
         body: body,
         of_clauses: of_clauses,
         catch_clauses: catch_clauses
       }),
       do:
         expr_atoms(body) ++
           Enum.flat_map(of_clauses, &clause_atoms/1) ++
           Enum.flat_map(catch_clauses, &clause_atoms/1)

  defp expr_atoms(%{node: :list_comp, expr: expr, qualifiers: qualifiers}),
    do: expr_atoms(expr) ++ Enum.flat_map(qualifiers, &qualifier_atoms/1)

  defp expr_atoms(%{node: :map_comp, key: key, value: value, qualifiers: qualifiers}),
    do: expr_atoms(key) ++ expr_atoms(value) ++ Enum.flat_map(qualifiers, &qualifier_atoms/1)

  defp expr_atoms(%{node: :binary_comp, expr: expr, qualifiers: qualifiers}),
    do: expr_atoms(expr) ++ Enum.flat_map(qualifiers, &qualifier_atoms/1)

  defp expr_atoms(_expr), do: []

  defp qualifier_atoms(%{pattern: pattern, expr: expr}),
    do: expr_atoms(pattern) ++ expr_atoms(expr)

  defp qualifier_atoms(%{expr: expr}), do: expr_atoms(expr)
end
