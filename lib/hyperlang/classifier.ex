defmodule Hyperlang.Classifier do
  @moduledoc false

  alias Hyperlang.{Core, Manifest, Stdlib}

  @forbidden_remote %{
    "erlang" =>
      ~w(halt open_port load_nif system_flag spawn spawn_link spawn_monitor spawn_opt self link unlink monitor demonitor process_flag process_info register unregister whereis group_leader put get erase send_after start_timer trace trace_pattern port_command port_close port_control port_call apply binary_to_term term_to_binary list_to_atom binary_to_atom list_to_existing_atom binary_to_existing_atom module_loaded function_exported),
    "code" => :all,
    "compile" => :all,
    "erl_eval" => :all,
    "init" => :all,
    "os" => :all,
    "file" => :all,
    "file_server" => :all,
    "prim_file" => :all,
    "gen_tcp" => :all,
    "gen_udp" => :all,
    "ssl" => :all,
    "inet" => :all,
    "ets" => :all,
    "hyperlang_table" => :all,
    "dets" => :all,
    "mnesia" => :all,
    "persistent_term" => :all,
    "rpc" => :all,
    "net_kernel" => :all,
    "global" => :all,
    "pg" => :all
  }

  @forbidden_locals %{
    "halt" => [0, 1, 2],
    "open_port" => [2],
    "load_nif" => [2],
    "system_flag" => [2],
    "spawn" => [1, 2, 3, 4],
    "spawn_link" => [1, 2, 3, 4],
    "spawn_monitor" => [1, 3],
    "spawn_opt" => [2, 4, 5],
    "self" => [0],
    "link" => [1],
    "unlink" => [1],
    "monitor" => [2],
    "demonitor" => [1, 2],
    "process_flag" => [2, 3],
    "process_info" => [1, 2],
    "register" => [2],
    "unregister" => [1],
    "whereis" => [1],
    "group_leader" => [0, 2],
    # put/get/erase (process dictionary) intentionally NOT forbidden — process-
    # LOCAL memory (no authority/cross-process reach), the home for Limbo module-
    # level globals in the ported Inferno userland. Each Prog is one fresh-spawned
    # guest process (worker.ex), so the dict starts empty and dies with the Prog —
    # no leak across Progs/tenants. Process-AUTHORITY ops stay forbidden; Limbo
    # spawn/chan/alt are host-provided via the syscall door.
    "send_after" => [3, 4],
    "start_timer" => [3, 4],
    "cancel_timer" => [1],
    "read_timer" => [1],
    "trace" => [3],
    "trace_pattern" => [2, 3],
    "port_command" => [2, 3],
    "port_close" => [1],
    "port_control" => [3],
    "port_call" => [2, 3],
    "apply" => [2, 3],
    "binary_to_term" => [1, 2],
    "term_to_binary" => [1, 2],
    "list_to_atom" => [1],
    "binary_to_atom" => [1, 2],
    "list_to_existing_atom" => [1],
    "binary_to_existing_atom" => [1, 2],
    "module_loaded" => [1],
    "function_exported" => [3]
  }

  def classify(%Core{} = core, manifest) do
    context = %{
      functions: core.functions,
      manifest: manifest,
      own_module: own_module(core),
      source_snapshot?: source_snapshot?(core),
      calls: []
    }

    with {:ok, functions, context} <- classify_functions(core, context),
         {:ok, records, context} <- classify_records(core.metadata[:records] || [], context) do
      metadata = Map.put(core.metadata, :records, records)

      {:ok,
       %{core | functions: functions, metadata: metadata, calls: Enum.reverse(context.calls)}}
    end
  end

  defp classify_records(records, context) do
    Enum.reduce_while(records, {:ok, [], context}, fn record, {:ok, acc, context} ->
      Enum.reduce_while(record.fields, {:ok, [], context}, fn field, {:ok, fields, context} ->
        case field.default do
          nil ->
            {:cont, {:ok, [field | fields], context}}

          default ->
            case classify_expr(default, context) do
              {:ok, default, context} ->
                {:cont, {:ok, [%{field | default: default} | fields], context}}

              {:error, error} ->
                {:halt, {:error, error}}
            end
        end
      end)
      |> case do
        {:ok, fields, context} ->
          {:cont, {:ok, [%{record | fields: Enum.reverse(fields)} | acc], context}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, records, context} -> {:ok, Enum.reverse(records), context}
      error -> error
    end
  end

  defp classify_functions(core, context) do
    Enum.reduce_while(core.function_order, {:ok, %{}, context}, fn key, {:ok, acc, context} ->
      fun = Map.fetch!(core.functions, key)

      case classify_function(fun, context) do
        {:ok, fun, context} -> {:cont, {:ok, Map.put(acc, key, fun), context}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp classify_function(%Core.Function{} = fun, context) do
    with {:ok, clauses, context} <- classify_clauses(fun.clauses, context) do
      {:ok, %{fun | clauses: clauses}, context}
    end
  end

  defp classify_clauses(clauses, context) do
    Enum.reduce_while(clauses, {:ok, [], context}, fn clause, {:ok, acc, context} ->
      with {:ok, patterns, context} <- classify_patterns(clause.patterns, context),
           {:ok, guard, context} <- classify_optional_expr(clause.guard, context),
           {:ok, body, context} <- classify_expr(clause.body, context) do
        {:cont, {:ok, [%{clause | patterns: patterns, guard: guard, body: body} | acc], context}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, acc, context} -> {:ok, Enum.reverse(acc), context}
      error -> error
    end
  end

  defp classify_patterns(patterns, context) do
    Enum.reduce_while(patterns, {:ok, [], context}, fn pattern, {:ok, acc, context} ->
      case classify_pattern(pattern, context) do
        {:ok, pattern, context} -> {:cont, {:ok, [pattern | acc], context}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, acc, context} -> {:ok, Enum.reverse(acc), context}
      error -> error
    end
  end

  defp classify_pattern(%{node: :tuple_pattern, items: items} = pattern, context) do
    with {:ok, items, context} <- classify_patterns(items, context) do
      {:ok, %{pattern | items: items}, context}
    end
  end

  defp classify_pattern(%{node: :list_pattern, items: items} = pattern, context) do
    with {:ok, items, context} <- classify_patterns(items, context) do
      {:ok, %{pattern | items: items}, context}
    end
  end

  defp classify_pattern(%{node: :alias_pattern, left: left, right: right} = pattern, context) do
    with {:ok, left, context} <- classify_pattern(left, context),
         {:ok, right, context} <- classify_pattern(right, context) do
      {:ok, %{pattern | left: left, right: right}, context}
    end
  end

  defp classify_pattern(%{node: :cons_pattern, head: head, tail: tail} = pattern, context) do
    with {:ok, head, context} <- classify_pattern(head, context),
         {:ok, tail, context} <- classify_pattern(tail, context) do
      {:ok, %{pattern | head: head, tail: tail}, context}
    end
  end

  defp classify_pattern(%{node: :map_pattern, fields: fields} = pattern, context) do
    Enum.reduce_while(fields, {:ok, [], context}, fn field, {:ok, acc, context} ->
      with {:ok, key, context} <- classify_expr(field.key, context),
           {:ok, value, context} <- classify_pattern(field.value, context) do
        {:cont, {:ok, [%{field | key: key, value: value} | acc], context}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, acc, context} -> {:ok, %{pattern | fields: Enum.reverse(acc)}, context}
      error -> error
    end
  end

  defp classify_pattern(%{node: :record_pattern, fields: fields} = pattern, context) do
    fields
    |> Enum.reduce_while({:ok, [], context}, fn field, {:ok, acc, context} ->
      case classify_pattern(field.value, context) do
        {:ok, value, context} -> {:cont, {:ok, [%{field | value: value} | acc], context}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, fields, context} -> {:ok, %{pattern | fields: Enum.reverse(fields)}, context}
      error -> error
    end
  end

  defp classify_pattern(%{node: :binary, parts: parts} = pattern, context) do
    with {:ok, parts, context} <- classify_bit_segment_patterns(parts, context, :pattern) do
      {:ok, %{pattern | parts: parts}, context}
    end
  end

  defp classify_pattern(%{node: :bit_segment, expr: expr, size: size} = segment, context) do
    with {:ok, expr, context} <- classify_pattern(expr, context),
         {:ok, size, context} <- classify_segment_size(size, context) do
      {:ok, %{segment | expr: expr, size: size}, context}
    end
  end

  defp classify_pattern(pattern, context), do: {:ok, pattern, context}

  defp classify_optional_expr(nil, context), do: {:ok, nil, context}
  defp classify_optional_expr(expr, context), do: classify_expr(expr, context)

  defp classify_expr(%{node: node} = expr, context)
       when node in [:int, :float, :string, :atom, :bool, :var],
       do: {:ok, expr, context}

  defp classify_expr(%{node: :unary, expr: inner} = expr, context) do
    with {:ok, inner, context} <- classify_expr(inner, context) do
      {:ok, %{expr | expr: inner}, context}
    end
  end

  defp classify_expr(%{node: :binary_op, left: left, right: right} = expr, context) do
    with {:ok, left, context} <- classify_expr(left, context),
         {:ok, right, context} <- classify_expr(right, context) do
      {:ok, %{expr | left: left, right: right}, context}
    end
  end

  defp classify_expr(%{node: :send, target: target, message: message} = expr, context) do
    with {:ok, target, context} <- classify_expr(target, context),
         {:ok, message, context} <- classify_expr(message, context) do
      {:ok, %{expr | target: target, message: message}, context}
    end
  end

  defp classify_expr(%{node: :match, pattern: pattern, expr: rhs} = expr, context) do
    with {:ok, pattern, context} <- classify_match_pattern(pattern, context),
         {:ok, rhs, context} <- classify_expr(rhs, context) do
      {:ok, %{expr | pattern: pattern, expr: rhs}, context}
    end
  end

  defp classify_expr(%{node: :block, exprs: exprs} = expr, context) do
    with {:ok, exprs, context} <- classify_exprs(exprs, context) do
      {:ok, %{expr | exprs: exprs}, context}
    end
  end

  defp classify_expr(%{node: :list, items: items} = expr, context) do
    with {:ok, items, context} <- classify_exprs(items, context) do
      {:ok, %{expr | items: items}, context}
    end
  end

  defp classify_expr(%{node: :cons, head: head, tail: tail} = expr, context) do
    with {:ok, head, context} <- classify_expr(head, context),
         {:ok, tail, context} <- classify_expr(tail, context) do
      {:ok, %{expr | head: head, tail: tail}, context}
    end
  end

  defp classify_expr(%{node: :tuple, items: items} = expr, context) do
    with {:ok, items, context} <- classify_exprs(items, context) do
      {:ok, %{expr | items: items}, context}
    end
  end

  defp classify_expr(%{node: :binary, parts: parts} = expr, context) do
    with {:ok, parts, context} <- classify_exprs(parts, context) do
      {:ok, %{expr | parts: parts}, context}
    end
  end

  defp classify_expr(%{node: :bit_segment, expr: expr, size: size} = segment, context) do
    with {:ok, expr, context} <- classify_expr(expr, context),
         {:ok, size, context} <- classify_segment_size(size, context) do
      {:ok, %{segment | expr: expr, size: size}, context}
    end
  end

  defp classify_expr(%{node: :map, fields: fields} = expr, context) do
    Enum.reduce_while(fields, {:ok, [], context}, fn field, {:ok, acc, context} ->
      with {:ok, key, context} <- classify_expr(field.key, context),
           {:ok, value, context} <- classify_expr(field.value, context) do
        {:cont, {:ok, [%{field | key: key, value: value} | acc], context}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, acc, context} -> {:ok, %{expr | fields: Enum.reverse(acc)}, context}
      error -> error
    end
  end

  defp classify_expr(%{node: :map_update, base: base, fields: fields} = expr, context) do
    with {:ok, base, context} <- classify_expr(base, context) do
      Enum.reduce_while(fields, {:ok, [], context}, fn field, {:ok, acc, context} ->
        with {:ok, key, context} <- classify_expr(field.key, context),
             {:ok, value, context} <- classify_expr(field.value, context) do
          {:cont, {:ok, [%{field | key: key, value: value} | acc], context}}
        else
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, acc, context} -> {:ok, %{expr | base: base, fields: Enum.reverse(acc)}, context}
        error -> error
      end
    end
  end

  defp classify_expr(%{node: :local_call, function: function, args: args}, context) do
    arity = length(args)

    cond do
      function == "module_info" ->
        {:error, Hyperlang.Error.new(:verify, "module_info is forbidden")}

      local_fun = local_function(context.functions, function, arity) ->
        classify_call_args(args, context, fn args, context ->
          call = %{
            node: :safe_local_call,
            source_function: function,
            function: local_fun.safe_name,
            arity: arity,
            args: args
          }

          {:ok, call, track_call(context, {:local, function, arity})}
        end)

      native_process_call?("erlang", function, arity) ->
        classify_native_process(function, args, context)

      forbidden_local?(function, arity) ->
        {:error, Hyperlang.Error.new(:verify, "forbidden local call #{function}/#{arity}")}

      (target = Stdlib.call_target("erlang", function, arity)) != :error ->
        classify_call_args(args, context, fn args, context ->
          call = %{
            node: :safe_stdlib_call,
            module: "erlang",
            function: function,
            arity: arity,
            target: target,
            args: args
          }

          {:ok, call, track_call(context, {:stdlib, "erlang", function, arity})}
        end)

      true ->
        {:error, Hyperlang.Error.new(:verify, "unknown local call #{function}/#{arity}")}
    end
  end

  defp classify_expr(
         %{node: :remote_call, module: module, function: function, args: args},
         context
       ) do
    arity = length(args)

    cond do
      # Resolution tier 1: a remote
      # call to the program's own module dispatches to the local function,
      # exactly like an unqualified local call. The own module wins over the
      # sticky surface, imports, and the code path, so a same-named
      # code-path file can never shadow it.
      own_module_call?(context, module) ->
        classify_own_module_call(function, args, arity, context)

      # The `code:` discovery surface: a sticky facade,
      # active only when the manifest enables modules.
      (operation = Hyperlang.Code.call_target(context.manifest, module, function, arity)) !=
          :error ->
        classify_call_args(args, context, fn args, context ->
          call = %{
            node: :safe_code_call,
            module: module,
            function: function,
            arity: arity,
            operation: operation,
            args: args
          }

          {:ok, call, track_call(context, {:code, module, function, arity})}
        end)

      (operation = Hyperlang.Filesystem.call_target(context.manifest, module, function, arity)) !=
          :error ->
        classify_call_args(args, context, fn args, context ->
          call = %{
            node: :safe_filesystem_call,
            module: module,
            function: function,
            arity: arity,
            operation: operation,
            args: args
          }

          {:ok, call, track_call(context, {:filesystem, module, function, arity})}
        end)

      (operation = Hyperlang.Loader.call_target(context.manifest, module, function, arity)) !=
          :error ->
        classify_call_args(args, context, fn args, context ->
          call = %{
            node: :safe_loader_call,
            module: module,
            function: function,
            arity: arity,
            operation: operation,
            args: args
          }

          {:ok, call, track_call(context, {:loader, module, function, arity})}
        end)

      (operation = Hyperlang.Table.call_target(context.manifest, module, function, arity)) !=
          :error ->
        classify_call_args(args, context, fn args, context ->
          call = %{
            node: :safe_table_call,
            module: module,
            function: function,
            arity: arity,
            operation: operation,
            args: args
          }

          {:ok, call, track_call(context, {:table, module, function, arity})}
        end)

      error = Hyperlang.Loader.call_diagnostic(context.manifest, module, function, arity) ->
        {:error, error}

      error = Hyperlang.Filesystem.call_diagnostic(context.manifest, module, function, arity) ->
        {:error, error}

      native_process_call?(module, function, arity) ->
        classify_native_process(function, args, context)

      native_timer_call?(module, function, arity) ->
        classify_native_timer(function, args, context)

      forbidden_remote?(module, function) ->
        {:error,
         Hyperlang.Error.new(:verify, "forbidden remote call #{module}:#{function}/#{arity}")}

      function == "module_info" ->
        {:error, Hyperlang.Error.new(:verify, "module_info is forbidden")}

      # A unit-compiled guest graph may explicitly claim an OTP-like module
      # name. That graph link wins over the sticky stdlib tier, while facade
      # and reserved internal names remain unshadowable.
      not source_snapshot?(context) and guest_code_path_module?(context.manifest, module) ->
        classify_module_call(module, function, args, arity, context)

      # Resolution tier 2 (sticky surface) before tier 3 (manifest imports):
      # undeclared stdlib names can never be shadowed by imports — the manifest
      # already rejects imports on reserved stdlib modules.
      (target = Stdlib.call_target(module, function, arity)) != :error ->
        classify_call_args(args, context, fn args, context ->
          call = %{
            node: :safe_stdlib_call,
            module: module,
            function: function,
            arity: arity,
            target: target,
            args: args
          }

          {:ok, call, track_call(context, {:stdlib, module, function, arity})}
        end)

      Manifest.binding_for_call(context.manifest, module, function, arity) ->
        classify_call_args(args, context, fn args, context ->
          call = %{
            node: :safe_import_call,
            module: module,
            function: function,
            arity: arity,
            import_name: {module, function, arity},
            args: args
          }

          {:ok, call, track_call(context, {:import, {module, function, arity}})}
        end)

      not source_snapshot?(context) and code_path_call?(context.manifest, module) ->
        classify_module_call(module, function, args, arity, context)

      true ->
        {:error,
         Hyperlang.Error.new(
           :verify,
           "remote call #{module}:#{function}/#{arity} is not declared"
         )}
    end
  end

  defp classify_expr(
         %{node: :dynamic_remote_call, module: module, function: function, args: args},
         context
       ) do
    arity = length(args)

    if behaviour_callback?(context, module, function, arity) do
      with {:ok, module, context} <- classify_expr(module, context),
           {:ok, args, context} <- classify_exprs(args, context) do
        call = %{
          node: :safe_behaviour_callback,
          function: function,
          arity: arity,
          module: module,
          args: args
        }

        {:ok, call,
         track_call(context, {:behaviour_callback, context.own_module, function, arity})}
      end
    else
      {:error, Hyperlang.Error.new(:verify, "dynamic remote calls are forbidden")}
    end
  end

  defp classify_expr(
         %{node: :dynamic_snapshot_call, module: module, args: args, candidates: candidates} =
           expr,
         context
       ) do
    arity = length(args)

    with :ok <- require_source_snapshot_dynamic(context),
         {:ok, candidates} <- classify_dynamic_snapshot_candidates(candidates, arity, context),
         {:ok, module, context} <- classify_expr(module, context),
         {:ok, args, context} <- classify_exprs(args, context) do
      {:ok,
       %{
         expr
         | node: :safe_dynamic_snapshot_call,
           module: module,
           args: args,
           candidates: candidates
       }, track_call(context, {:dynamic_snapshot, expr.function, arity})}
    end
  end

  defp classify_expr(
         %{
           node: :snapshot_apply,
           target: target,
           function: function,
           args: args,
           candidates: candidates
         },
         context
       ) do
    with :ok <- require_source_snapshot_dynamic(context),
         {:ok, candidates} <- classify_apply_candidates(candidates, context),
         {:ok, target, context} <- classify_expr(target, context),
         {:ok, function, context} <- classify_expr(function, context),
         {:ok, args, context} <- classify_expr(args, context) do
      {:ok,
       %{
         node: :safe_snapshot_apply,
         target: target,
         function: function,
         args: args,
         candidates: candidates
       }, track_call(context, {:snapshot_apply, 3})}
    end
  end

  defp classify_expr(%{node: :case, expr: case_expr, clauses: clauses} = expr, context) do
    with {:ok, case_expr, context} <- classify_expr(case_expr, context),
         {:ok, clauses, context} <- classify_clauses(clauses, context) do
      {:ok, %{expr | expr: case_expr, clauses: clauses}, context}
    end
  end

  defp classify_expr(%{node: :record_create, fields: fields} = expr, context) do
    classify_record_fields(expr, fields, context)
  end

  defp classify_expr(%{node: :record_update, base: base, fields: fields} = expr, context) do
    with {:ok, base, context} <- classify_expr(base, context),
         {:ok, expr, context} <- classify_record_fields(expr, fields, context) do
      {:ok, %{expr | base: base}, context}
    end
  end

  defp classify_expr(%{node: :record_access, base: base} = expr, context) do
    with {:ok, base, context} <- classify_expr(base, context),
         do: {:ok, %{expr | base: base}, context}
  end

  defp classify_expr(%{node: :record_index} = expr, context), do: {:ok, expr, context}
  defp classify_expr(%{node: :record_info} = expr, context), do: {:ok, expr, context}

  defp classify_expr(%{node: :receive, clauses: clauses, timeout: timeout} = expr, context) do
    with {:ok, clauses, context} <- classify_clauses(clauses, context),
         {:ok, timeout, context} <- classify_optional_expr(timeout, context),
         {:ok, after_body, context} <- classify_optional_expr(Map.get(expr, :after_body), context) do
      {:ok, %{expr | clauses: clauses, timeout: timeout, after_body: after_body}, context}
    end
  end

  defp classify_expr(%{node: :receive, clauses: clauses} = expr, context) do
    with {:ok, clauses, context} <- classify_clauses(clauses, context) do
      {:ok, %{expr | clauses: clauses}, context}
    end
  end

  defp classify_expr(%{node: :if, clauses: clauses} = expr, context) do
    with {:ok, clauses, context} <- classify_if_clauses(clauses, context) do
      {:ok, %{expr | clauses: clauses}, context}
    end
  end

  defp classify_expr(%{node: :fun, clauses: clauses} = expr, context) do
    with {:ok, clauses, context} <- classify_clauses(clauses, context) do
      {:ok, %{expr | clauses: clauses}, context}
    end
  end

  defp classify_expr(%{node: :named_fun, clauses: clauses} = expr, context) do
    with {:ok, clauses, context} <- classify_clauses(clauses, context) do
      {:ok, %{expr | clauses: clauses}, context}
    end
  end

  defp classify_expr(%{node: :local_fun_ref, function: function, arity: arity}, context) do
    cond do
      function == "module_info" ->
        {:error, Hyperlang.Error.new(:verify, "module_info is forbidden")}

      local_fun = local_function(context.functions, function, arity) ->
        capture = %{
          node: :safe_local_fun_ref,
          source_function: function,
          function: local_fun.safe_name,
          arity: arity
        }

        {:ok, capture, track_call(context, {:local_capture, function, arity})}

      forbidden_local?(function, arity) ->
        {:error, Hyperlang.Error.new(:verify, "forbidden local fun capture #{function}/#{arity}")}

      true ->
        {:error, Hyperlang.Error.new(:verify, "unknown local fun capture #{function}/#{arity}")}
    end
  end

  defp classify_expr(%{node: :fun_call, callee: callee, args: args} = expr, context) do
    with {:ok, callee, context} <- classify_expr(callee, context),
         {:ok, args, context} <- classify_exprs(args, context) do
      {:ok, %{expr | callee: callee, args: args}, context}
    end
  end

  defp classify_expr(
         %{node: :try, body: body, of_clauses: of_clauses, catch_clauses: catch_clauses} = expr,
         context
       ) do
    with {:ok, body, context} <- classify_expr(body, context),
         {:ok, of_clauses, context} <- classify_clauses(of_clauses, context),
         {:ok, catch_clauses, context} <- classify_clauses(catch_clauses, context) do
      {:ok, %{expr | body: body, of_clauses: of_clauses, catch_clauses: catch_clauses}, context}
    end
  end

  defp classify_expr(%{node: :list_comp, expr: body, qualifiers: qualifiers} = expr, context) do
    with {:ok, body, context} <- classify_expr(body, context),
         {:ok, qualifiers, context} <- classify_qualifiers(qualifiers, context) do
      {:ok, %{expr | expr: body, qualifiers: qualifiers}, context}
    end
  end

  defp classify_expr(
         %{node: :map_comp, key: key, value: value, qualifiers: qualifiers} = expr,
         context
       ) do
    with {:ok, key, context} <- classify_expr(key, context),
         {:ok, value, context} <- classify_expr(value, context),
         {:ok, qualifiers, context} <- classify_qualifiers(qualifiers, context) do
      {:ok, %{expr | key: key, value: value, qualifiers: qualifiers}, context}
    end
  end

  defp classify_expr(%{node: :binary_comp, expr: body, qualifiers: qualifiers} = expr, context) do
    with {:ok, body, context} <- classify_expr(body, context),
         {:ok, qualifiers, context} <- classify_qualifiers(qualifiers, context) do
      {:ok, %{expr | expr: body, qualifiers: qualifiers}, context}
    end
  end

  defp classify_expr(_expr, _context),
    do: {:error, Hyperlang.Error.new(:verify, "unsupported expression")}

  defp classify_record_fields(expr, fields, context) do
    fields
    |> Enum.reduce_while({:ok, [], context}, fn field, {:ok, acc, context} ->
      case classify_expr(field.value, context) do
        {:ok, value, context} -> {:cont, {:ok, [%{field | value: value} | acc], context}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, fields, context} -> {:ok, %{expr | fields: Enum.reverse(fields)}, context}
      error -> error
    end
  end

  defp classify_segment_size(:default, context), do: {:ok, :default, context}
  defp classify_segment_size(size, context), do: classify_expr(size, context)

  defp classify_if_clauses(clauses, context) do
    Enum.reduce_while(clauses, {:ok, [], context}, fn clause, {:ok, acc, context} ->
      with {:ok, guard, context} <- classify_expr(clause.guard, context),
           {:ok, body, context} <- classify_expr(clause.body, context) do
        {:cont, {:ok, [%{clause | guard: guard, body: body} | acc], context}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, acc, context} -> {:ok, Enum.reverse(acc), context}
      error -> error
    end
  end

  defp classify_qualifiers(qualifiers, context) do
    Enum.reduce_while(qualifiers, {:ok, [], context}, fn qualifier, {:ok, acc, context} ->
      case qualifier do
        %{node: node, pattern: pattern, expr: expr} = qualifier
        when node in [:generator, :b_generator] ->
          with {:ok, pattern, context} <- classify_pattern(pattern, context),
               {:ok, expr, context} <- classify_expr(expr, context) do
            {:cont, {:ok, [%{qualifier | pattern: pattern, expr: expr} | acc], context}}
          else
            {:error, error} -> {:halt, {:error, error}}
          end

        %{node: :filter, expr: expr} ->
          with {:ok, expr, context} <- classify_expr(expr, context) do
            {:cont, {:ok, [%{qualifier | expr: expr} | acc], context}}
          else
            {:error, error} -> {:halt, {:error, error}}
          end
      end
    end)
    |> case do
      {:ok, acc, context} -> {:ok, Enum.reverse(acc), context}
      error -> error
    end
  end

  defp classify_exprs(exprs, context) do
    Enum.reduce_while(exprs, {:ok, [], context}, fn expr, {:ok, acc, context} ->
      case classify_expr(expr, context) do
        {:ok, expr, context} -> {:cont, {:ok, [expr | acc], context}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, acc, context} -> {:ok, Enum.reverse(acc), context}
      error -> error
    end
  end

  defp classify_match_pattern(%{node: :var} = expr, context),
    do: {:ok, %{node: :var_pattern, name: expr.name}, context}

  defp classify_match_pattern(%{node: :wild_pattern} = pattern, context),
    do: {:ok, pattern, context}

  defp classify_match_pattern(%{node: :alias, left: left, right: right}, context) do
    with {:ok, left, context} <- classify_match_pattern(left, context),
         {:ok, right, context} <- classify_match_pattern(right, context) do
      {:ok, %{node: :alias_pattern, left: left, right: right}, context}
    end
  end

  defp classify_match_pattern(%{node: :atom} = expr, context),
    do: {:ok, %{node: :literal_pattern, literal: expr}, context}

  defp classify_match_pattern(%{node: node} = expr, context)
       when node in [:int, :float, :string, :bool],
       do: {:ok, %{node: :literal_pattern, literal: expr}, context}

  defp classify_match_pattern(%{node: :tuple, items: items}, context) do
    with {:ok, items, context} <- classify_match_patterns(items, context) do
      {:ok, %{node: :tuple_pattern, items: items}, context}
    end
  end

  defp classify_match_pattern(%{node: :list, items: items}, context) do
    with {:ok, items, context} <- classify_match_patterns(items, context) do
      {:ok, %{node: :list_pattern, items: items}, context}
    end
  end

  defp classify_match_pattern(%{node: :cons, head: head, tail: tail}, context) do
    with {:ok, head, context} <- classify_match_pattern(head, context),
         {:ok, tail, context} <- classify_match_pattern(tail, context) do
      {:ok, %{node: :cons_pattern, head: head, tail: tail}, context}
    end
  end

  defp classify_match_pattern(%{node: :map, fields: fields}, context) do
    Enum.reduce_while(fields, {:ok, [], context}, fn field, {:ok, acc, context} ->
      with {:ok, key, context} <- classify_expr(field.key, context),
           {:ok, value, context} <- classify_match_pattern(field.value, context) do
        {:cont, {:ok, [%{key: key, value: value} | acc], context}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, acc, context} -> {:ok, %{node: :map_pattern, fields: Enum.reverse(acc)}, context}
      error -> error
    end
  end

  defp classify_match_pattern(%{node: :record_pattern} = pattern, context),
    do: classify_pattern(pattern, context)

  defp classify_match_pattern(%{node: :binary, parts: parts} = expr, context) do
    with {:ok, parts, context} <- classify_bit_segment_patterns(parts, context, :match) do
      {:ok, %{expr | parts: parts}, context}
    end
  end

  defp classify_match_pattern(_expr, _context),
    do: {:error, Hyperlang.Error.new(:verify, "match left side must be a safe pattern")}

  defp classify_bit_segment_patterns(parts, context, mode) do
    Enum.reduce_while(parts, {:ok, [], context}, fn segment, {:ok, acc, context} ->
      case classify_bit_segment_pattern(segment, context, mode) do
        {:ok, segment, context} -> {:cont, {:ok, [segment | acc], context}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, acc, context} -> {:ok, Enum.reverse(acc), context}
      error -> error
    end
  end

  defp classify_bit_segment_pattern(
         %{node: :bit_segment, expr: expr, size: size} = segment,
         context,
         mode
       ) do
    with {:ok, expr, context} <- classify_segment_pattern_expr(expr, context, mode),
         {:ok, size, context} <- classify_segment_size(size, context) do
      {:ok, %{segment | expr: expr, size: size}, context}
    end
  end

  defp classify_segment_pattern_expr(expr, context, :pattern), do: classify_pattern(expr, context)

  defp classify_segment_pattern_expr(expr, context, :match),
    do: classify_match_pattern(expr, context)

  defp classify_match_patterns(patterns, context) do
    Enum.reduce_while(patterns, {:ok, [], context}, fn pattern, {:ok, acc, context} ->
      case classify_match_pattern(pattern, context) do
        {:ok, pattern, context} -> {:cont, {:ok, [pattern | acc], context}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, acc, context} -> {:ok, Enum.reverse(acc), context}
      error -> error
    end
  end

  defp classify_call_args(args, context, callback) do
    with {:ok, args, context} <- classify_exprs(args, context) do
      callback.(args, context)
    end
  end

  defp classify_native_spawn(args, context) do
    classify_call_args(args, context, fn [fun], context ->
      {:ok, %{node: :native_spawn, fun: fun}, track_call(context, {:native_spawn, 1})}
    end)
  end

  defp classify_native_process("spawn", args, context), do: classify_native_spawn(args, context)

  defp classify_native_process("make_ref", [], context) do
    {:ok, %{node: :native_make_ref}, track_call(context, {:native_make_ref, 0})}
  end

  defp classify_native_process("is_process_alive", args, context) do
    classify_call_args(args, context, fn [target], context ->
      {:ok, %{node: :native_is_process_alive, target: target},
       track_call(context, {:native_is_process_alive, 1})}
    end)
  end

  defp classify_native_process("process_info", args, context) do
    case args do
      [%{node: :local_call, function: "self", args: []}, %{node: :atom, value: "links"}] ->
        {:ok, %{node: :native_process_info_links},
         track_call(context, {:native_process_info_links, 2})}

      _ ->
        {:error, Hyperlang.Error.new(:verify, "process_info: only (self(), links) is supported")}
    end
  end

  defp classify_native_process("exit", args, context) do
    classify_call_args(args, context, fn [target, reason], context ->
      {:ok, %{node: :native_exit, target: target, reason: reason},
       track_call(context, {:native_exit, 2})}
    end)
  end

  defp classify_native_process("send_after", args, context) do
    classify_call_args(args, context, fn [time, target, message], context ->
      {:ok, %{node: :native_send_after, time: time, target: target, message: message},
       track_call(context, {:native_send_after, 3})}
    end)
  end

  defp classify_native_process("start_timer", args, context) do
    classify_call_args(args, context, fn [time, target, message], context ->
      {:ok, %{node: :native_start_timer, time: time, target: target, message: message},
       track_call(context, {:native_start_timer, 3})}
    end)
  end

  defp classify_native_process("cancel_timer", args, context) do
    classify_call_args(args, context, fn [ref], context ->
      {:ok, %{node: :native_cancel_timer, ref: ref},
       track_call(context, {:native_cancel_timer, 1})}
    end)
  end

  defp classify_native_process("read_timer", args, context) do
    classify_call_args(args, context, fn [ref], context ->
      {:ok, %{node: :native_read_timer, ref: ref}, track_call(context, {:native_read_timer, 1})}
    end)
  end

  defp classify_native_process("spawn_link", args, context) do
    classify_call_args(args, context, fn [fun], context ->
      {:ok, %{node: :native_spawn_link, fun: fun}, track_call(context, {:native_spawn_link, 1})}
    end)
  end

  defp classify_native_process("spawn_monitor", args, context) do
    classify_call_args(args, context, fn [fun], context ->
      {:ok, %{node: :native_spawn_monitor, fun: fun},
       track_call(context, {:native_spawn_monitor, 1})}
    end)
  end

  defp classify_native_process("register", args, context) do
    case args do
      [name, target] ->
        classify_call_args([name, target], context, fn [name, target], context ->
          {:ok, %{node: :native_register, name: name, target: target},
           track_call(context, {:native_register, 2})}
        end)
    end
  end

  defp classify_native_process("whereis", args, context) do
    case args do
      [name] ->
        classify_call_args([name], context, fn [name], context ->
          {:ok, %{node: :native_whereis, name: name}, track_call(context, {:native_whereis, 1})}
        end)
    end
  end

  defp classify_native_process("unregister", args, context) do
    case args do
      [name] ->
        classify_call_args([name], context, fn [name], context ->
          {:ok, %{node: :native_unregister, name: name},
           track_call(context, {:native_unregister, 1})}
        end)
    end
  end

  defp classify_native_process("link", args, context) do
    classify_call_args(args, context, fn [target], context ->
      {:ok, %{node: :native_link, target: target}, track_call(context, {:native_link, 1})}
    end)
  end

  defp classify_native_process("unlink", args, context) do
    classify_call_args(args, context, fn [target], context ->
      {:ok, %{node: :native_unlink, target: target}, track_call(context, {:native_unlink, 1})}
    end)
  end

  defp classify_native_process("monitor", args, context) do
    case args do
      [%{node: :atom, value: "process"}, target] ->
        classify_call_args([target], context, fn [target], context ->
          {:ok, %{node: :native_monitor, target: target},
           track_call(context, {:native_monitor, 2})}
        end)

      _other ->
        {:error, Hyperlang.Error.new(:verify, "monitor/2 only supports process targets")}
    end
  end

  defp classify_native_process("demonitor", args, context) do
    case args do
      [ref] ->
        classify_call_args([ref], context, fn [ref], context ->
          {:ok, %{node: :native_demonitor, ref: ref, options: nil},
           track_call(context, {:native_demonitor, 1})}
        end)

      [ref, options] ->
        classify_call_args([ref, options], context, fn [ref, options], context ->
          {:ok, %{node: :native_demonitor, ref: ref, options: options},
           track_call(context, {:native_demonitor, 2})}
        end)
    end
  end

  defp classify_native_process("process_flag", args, context) do
    case args do
      [%{node: :atom, value: "trap_exit"} = flag, bool] ->
        classify_call_args([bool], context, fn [bool], context ->
          {:ok, %{node: :native_process_flag, flag: flag, value: bool},
           track_call(context, {:native_process_flag, 2})}
        end)

      _other ->
        {:error, Hyperlang.Error.new(:verify, "process_flag/2 only supports trap_exit")}
    end
  end

  defp classify_native_timer("sleep", args, context) do
    classify_call_args(args, context, fn [time], context ->
      {:ok, %{node: :native_timer_sleep, time: time},
       track_call(context, {:native_timer_sleep, 1})}
    end)
  end

  defp local_function(functions, function, arity) do
    case Map.fetch(functions, {function, arity}) do
      {:ok, fun} -> fun
      _ -> nil
    end
  end

  @doc """
  The single forbidden-call policy, shared by both validation passes.

  `Hyperlang.Verifier` (pass 2) and `Hyperlang.CompatibilityAudit` read these
  tables instead of restating them: one policy, three readers.
  """
  def forbidden_remote_table, do: @forbidden_remote

  @doc false
  def forbidden_local_table, do: @forbidden_locals

  @doc false
  def forbidden_remote?(module, function) do
    case Map.get(@forbidden_remote, module) do
      :all -> true
      list when is_list(list) -> function in list
      _ -> false
    end
  end

  @doc false
  def forbidden_local?(function, arity),
    do: arity in Map.get(@forbidden_locals, function, [])

  defp native_process_call?("erlang", "exit", 2), do: true
  defp native_process_call?("erlang", "make_ref", 0), do: true
  defp native_process_call?("erlang", "is_process_alive", 1), do: true
  defp native_process_call?("erlang", "process_info", 2), do: true
  defp native_process_call?("erlang", "send_after", 3), do: true
  defp native_process_call?("erlang", "start_timer", 3), do: true
  defp native_process_call?("erlang", "cancel_timer", 1), do: true
  defp native_process_call?("erlang", "read_timer", 1), do: true
  defp native_process_call?("erlang", "spawn", 1), do: true
  defp native_process_call?("erlang", "spawn_link", 1), do: true
  defp native_process_call?("erlang", "spawn_monitor", 1), do: true
  defp native_process_call?("erlang", "register", 2), do: true
  defp native_process_call?("erlang", "unregister", 1), do: true
  defp native_process_call?("erlang", "whereis", 1), do: true
  defp native_process_call?("erlang", "link", 1), do: true
  defp native_process_call?("erlang", "unlink", 1), do: true
  defp native_process_call?("erlang", "monitor", 2), do: true
  defp native_process_call?("erlang", "demonitor", 1), do: true
  defp native_process_call?("erlang", "demonitor", 2), do: true
  defp native_process_call?("erlang", "process_flag", 2), do: true
  defp native_process_call?(_module, _function, _arity), do: false

  defp native_timer_call?("timer", "sleep", 1), do: true
  defp native_timer_call?(_module, _function, _arity), do: false

  defp track_call(context, call), do: %{context | calls: [call | context.calls]}

  defp require_source_snapshot_dynamic(%{
         source_snapshot?: true,
         manifest: %{modules: %{enabled: true}}
       }),
       do: :ok

  defp require_source_snapshot_dynamic(_context),
    do: {:error, Hyperlang.Error.new(:verify, "dynamic remote calls are forbidden")}

  defp classify_dynamic_snapshot_candidates(candidates, arity, context)
       when is_list(candidates) and candidates != [] do
    candidates
    |> Enum.reduce_while({:ok, []}, fn candidate, {:ok, acc} ->
      case classify_dynamic_snapshot_candidate(candidate, arity, context) do
        {:ok, candidate} -> {:cont, {:ok, [candidate | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, candidates} -> {:ok, Enum.reverse(candidates)}
      {:error, error} -> {:error, error}
    end
  end

  defp classify_dynamic_snapshot_candidates(_candidates, _arity, _context),
    do: {:error, Hyperlang.Error.new(:verify, "invalid dynamic snapshot call")}

  defp classify_dynamic_snapshot_candidate(
         %{module: module, function: function, arity: arity},
         arity,
         context
       )
       when is_binary(module) and is_binary(function) do
    guest_modules =
      context.manifest
      |> Map.get(:modules, %{})
      |> Map.get(:guest_modules, [])
      |> MapSet.new()

    with true <- MapSet.member?(guest_modules, module),
         %{} = fun <- local_function(context.functions, function, arity) do
      {:ok, %{module: module, function: fun.safe_name}}
    else
      _other -> {:error, Hyperlang.Error.new(:verify, "invalid dynamic snapshot call")}
    end
  end

  defp classify_dynamic_snapshot_candidate(_candidate, _arity, _context),
    do: {:error, Hyperlang.Error.new(:verify, "invalid dynamic snapshot call")}

  defp classify_apply_candidates(candidates, context) when is_list(candidates) do
    guest_modules = MapSet.new(context.manifest.modules.guest_modules)

    candidates
    |> Enum.reduce_while({:ok, []}, fn candidate, {:ok, acc} ->
      case candidate do
        %{module: module, source_function: source, function: mapped, arity: arity}
        when is_binary(module) and is_binary(source) and is_binary(mapped) and is_integer(arity) ->
          case {MapSet.member?(guest_modules, module),
                local_function(context.functions, mapped, arity)} do
            {true, %{} = fun} ->
              {:cont,
               {:ok,
                [
                  %{
                    module: module,
                    source_function: source,
                    function: fun.safe_name,
                    arity: arity
                  }
                  | acc
                ]}}

            _ ->
              {:cont, {:ok, acc}}
          end

        _ ->
          {:halt, {:error, Hyperlang.Error.new(:verify, "invalid snapshot apply candidate")}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp own_module(%Core{metadata: %{source_contract: %{module: module}}})
       when is_binary(module),
       do: module

  defp own_module(%Core{}), do: nil

  defp source_snapshot?(%Core{
         metadata: %{source_contract: %{filesystem_snapshot: true}}
       }),
       do: true

  defp source_snapshot?(%{source_snapshot?: value}), do: value == true
  defp source_snapshot?(_core_or_context), do: false

  defp own_module_call?(%{own_module: own_module}, module),
    do: is_binary(own_module) and module == own_module

  defp behaviour_callback?(
         %{manifest: %{modules: %{callback_dispatch: true}}},
         %{node: :var, name: "Module"},
         function,
         arity
       ),
       do: is_binary(function) and is_integer(arity) and arity >= 0

  defp behaviour_callback?(_context, _module, _function, _arity), do: false

  # An own-module remote call resolves like the unqualified local call: a
  # defined function dispatches locally (and is tracked as a local call, so
  # it never lands in a library's derived capability set); anything else is
  # the same compile-time failure an unqualified call would be. The fixed
  # resolution order means there is no fallthrough to later tiers.
  defp classify_own_module_call(function, args, arity, context) do
    cond do
      function == "module_info" ->
        {:error, Hyperlang.Error.new(:verify, "module_info is forbidden")}

      local_fun = local_function(context.functions, function, arity) ->
        classify_call_args(args, context, fn args, context ->
          call = %{
            node: :safe_local_call,
            source_function: function,
            function: local_fun.safe_name,
            arity: arity,
            args: args
          }

          {:ok, call, track_call(context, {:local, function, arity})}
        end)

      forbidden_local?(function, arity) ->
        {:error, Hyperlang.Error.new(:verify, "forbidden local call #{function}/#{arity}")}

      true ->
        {:error, Hyperlang.Error.new(:verify, "unknown local call #{function}/#{arity}")}
    end
  end

  defp classify_module_call(module, function, args, arity, context) do
    classify_call_args(args, context, fn args, context ->
      call = %{
        node: :safe_module_call,
        module: module,
        function: function,
        arity: arity,
        args: args
      }

      {:ok, call, track_call(context, {:code_path, module, function, arity})}
    end)
  end

  # Otherwise-unknown static calls resolve lazily from the runtime code path
  # only when the module loader is explicitly enabled. Sticky facades and
  # internal generated names can never be shadowed.
  def code_path_call?(manifest, module) do
    Map.get(manifest, :modules, %{}) |> Map.get(:enabled, false) and
      valid_code_path_module_name?(module) and
      (guest_code_path_module?(manifest, module) or not Hyperlang.Code.sticky?(manifest, module)) and
      not Manifest.reserved_internal_name?(module)
  end

  defp valid_code_path_module_name?(module) when is_binary(module),
    do: Regex.match?(~r/\A[a-z][A-Za-z0-9_]*\z/, module)

  defp valid_code_path_module_name?(_module), do: false

  defp guest_code_path_module?(manifest, module) do
    modules = Map.get(manifest, :modules, %{})

    Map.get(modules, :enabled, false) and
      module in Map.get(modules, :guest_modules, []) and
      valid_code_path_module_name?(module) and
      not Hyperlang.Docs.facade_module?(module) and
      module not in ["compile", "erl_eval", "handle"] and
      not Manifest.reserved_internal_name?(module)
  end
end
