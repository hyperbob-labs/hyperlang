defmodule Hyperlang.Verifier do
  @moduledoc false

  alias Hyperlang.Manifest

  @guard_bifs %{
    "abs" => [1],
    "binary_part" => [2, 3],
    "bit_size" => [1],
    "byte_size" => [1],
    "ceil" => [1],
    "element" => [2],
    "float" => [1],
    "floor" => [1],
    "hd" => [1],
    "is_atom" => [1],
    "is_binary" => [1],
    "is_bitstring" => [1],
    "is_boolean" => [1],
    "is_float" => [1],
    "is_function" => [1, 2],
    "is_integer" => [1],
    "is_list" => [1],
    "is_map" => [1],
    "is_map_key" => [2],
    "is_number" => [1],
    "is_pid" => [1],
    "is_port" => [1],
    "is_record" => [2, 3],
    "is_reference" => [1],
    "is_tuple" => [1],
    "length" => [1],
    "map_get" => [2],
    "map_size" => [1],
    # `node`/`self` are deliberately absent: the guard allowlist is intersected
    # with the stdlib allowlist (`allowed_bif?`), which never admits them.
    "round" => [1],
    "size" => [1],
    "tl" => [1],
    "trunc" => [1],
    "tuple_size" => [1]
  }
  @segment_type_modifiers ~w(integer float binary bytes bitstring bits utf8 utf16 utf32)
  @segment_sign_modifiers ~w(signed unsigned)
  @segment_endian_modifiers ~w(big little native)

  def verify(core, manifest) do
    with :ok <- verify_function_limits(core, manifest),
         :ok <- verify_records(core, manifest),
         :ok <- verify_functions(core, manifest),
         :ok <- verify_source_semantics(core, manifest) do
      :ok
    end
  end

  defp verify_records(core, manifest) do
    Enum.reduce_while(core.metadata[:records] || [], :ok, fn record, :ok ->
      case Enum.find(record.fields, &(&1.default != nil)) do
        nil ->
          {:cont, :ok}

        _ ->
          case Enum.reduce_while(record.fields, :ok, fn field, :ok ->
                 case field.default do
                   nil ->
                     {:cont, :ok}

                   value ->
                     case verify_expr(value, core, manifest) do
                       :ok -> {:cont, :ok}
                       error -> {:halt, error}
                     end
                 end
               end) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
      end
    end)
  end

  defp verify_function_limits(core, manifest) do
    cond do
      map_size(core.functions) > manifest.limits.max_functions ->
        {:error, Hyperlang.Error.new(:verify, "function count exceeds limit")}

      Enum.any?(core.functions, fn {_name, fun} ->
        fun.arity > manifest.limits.max_function_arity
      end) ->
        {:error, Hyperlang.Error.new(:verify, "function arity exceeds limit")}

      true ->
        :ok
    end
  end

  defp verify_functions(core, manifest) do
    core.functions
    |> Enum.reduce_while(:ok, fn {_name, fun}, :ok ->
      if length(fun.clauses) > manifest.limits.max_clauses do
        {:halt, {:error, Hyperlang.Error.new(:verify, "clause count exceeds limit")}}
      else
        case verify_clauses(fun.clauses, core, manifest) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end
    end)
  end

  defp verify_clauses(clauses, core, manifest) do
    clauses
    |> Enum.reduce_while(:ok, fn clause, :ok ->
      with :ok <- verify_patterns(clause.patterns, core, manifest),
           :ok <- verify_expr(clause.guard, core, manifest),
           :ok <- verify_expr(clause.body, core, manifest) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp verify_patterns(patterns, core, manifest),
    do:
      Enum.reduce_while(patterns, :ok, fn pat, :ok ->
        step(verify_pattern(pat, core, manifest))
      end)

  defp verify_pattern(nil, _core, _manifest), do: :ok
  defp verify_pattern(%{node: :var_pattern}, _core, _manifest), do: :ok
  defp verify_pattern(%{node: :wild_pattern}, _core, _manifest), do: :ok

  defp verify_pattern(%{node: :literal_pattern, literal: lit}, core, manifest),
    do: verify_literal(lit, core, manifest)

  defp verify_pattern(%{node: :alias_pattern, left: left, right: right}, core, manifest) do
    with :ok <- verify_pattern(left, core, manifest), do: verify_pattern(right, core, manifest)
  end

  defp verify_pattern(%{node: :tuple_pattern, items: items}, core, manifest),
    do: verify_patterns(items, core, manifest)

  defp verify_pattern(%{node: :list_pattern, items: items}, core, manifest),
    do: verify_patterns(items, core, manifest)

  defp verify_pattern(%{node: :cons_pattern, head: head, tail: tail}, core, manifest) do
    with :ok <- verify_pattern(head, core, manifest), do: verify_pattern(tail, core, manifest)
  end

  defp verify_pattern(%{node: :map_pattern, fields: fields}, core, manifest) do
    Enum.reduce_while(fields, :ok, fn field, :ok ->
      with :ok <- verify_map_pattern_key(field.key, core, manifest),
           :ok <- verify_pattern(field.value, core, manifest) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp verify_pattern(%{node: :record_pattern, name: name, fields: fields}, core, manifest) do
    with :ok <- verify_record_fields(core, name, fields) do
      Enum.reduce_while(fields, :ok, fn field, :ok ->
        case verify_pattern(field.value, core, manifest) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp verify_pattern(%{node: :binary, parts: parts}, core, manifest),
    do: verify_bit_segments(parts, core, manifest, :pattern)

  defp verify_pattern(_, _core, _manifest),
    do: {:error, Hyperlang.Error.new(:verify, "unsupported pattern")}

  defp verify_map_pattern_key(%{node: node} = literal, core, manifest)
       when node in [:int, :float, :string, :atom, :bool, :var],
       do: verify_match_pattern(literal, core, manifest)

  defp verify_map_pattern_key(%{node: node} = key, core, manifest)
       when node in [:tuple, :list, :cons, :binary, :map],
       do: verify_match_pattern(key, core, manifest)

  defp verify_map_pattern_key(_key, _core, _manifest),
    do: {:error, Hyperlang.Error.new(:verify, "map pattern keys must be literals or variables")}

  defp verify_record_values(fields, core, manifest) do
    Enum.reduce_while(fields, :ok, fn field, :ok ->
      case verify_expr(field.value, core, manifest) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp verify_record_fields(core, name, fields) do
    case Enum.find(core.metadata[:records] || [], &(&1.name == name)) do
      nil ->
        {:error, Hyperlang.Error.new(:verify, "undeclared record #{name}")}

      record ->
        declared = MapSet.new(Enum.map(record.fields, & &1.name))

        case Enum.find(fields, &(&1.name != "_" and not MapSet.member?(declared, &1.name))) do
          nil ->
            :ok

          field ->
            {:error,
             Hyperlang.Error.new(:verify, "undeclared field #{field.name} for record #{name}")}
        end
    end
  end

  defp verify_record_expr(%{node: :record_create, name: name, fields: fields}, core, manifest) do
    with :ok <- verify_record_fields(core, name, fields),
         do: verify_record_values(fields, core, manifest)
  end

  defp verify_record_expr(
         %{node: :record_update, base: base, name: name, fields: fields},
         core,
         manifest
       ) do
    with :ok <- verify_expr(base, core, manifest),
         :ok <- verify_record_fields(core, name, fields) do
      verify_record_values(fields, core, manifest)
    end
  end

  defp verify_record_expr(
         %{node: :record_access, base: base, name: name, field: field},
         core,
         manifest
       ) do
    with :ok <- verify_record_fields(core, name, [%{name: field}]),
         do: verify_expr(base, core, manifest)
  end

  defp verify_record_expr(%{node: :record_index, name: name, field: field}, core, _manifest),
    do: verify_record_fields(core, name, [%{name: field}])

  defp verify_expr(nil, _core, _manifest), do: :ok

  defp verify_expr(%{node: node} = expr, _core, manifest)
       when node in [:int, :float, :string, :bool],
       do: verify_literal(expr, nil, manifest)

  defp verify_expr(%{node: :atom} = expr, core, manifest),
    do: verify_literal(expr, core, manifest)

  defp verify_expr(%{node: :var}, _core, _manifest), do: :ok

  defp verify_expr(%{node: :unary, expr: expr}, core, manifest),
    do: verify_expr(expr, core, manifest)

  defp verify_expr(%{node: :binary_op, left: left, right: right}, core, manifest) do
    with :ok <- verify_expr(left, core, manifest), do: verify_expr(right, core, manifest)
  end

  defp verify_expr(%{node: :send, target: target, message: message}, core, manifest) do
    with :ok <- verify_expr(target, core, manifest), do: verify_expr(message, core, manifest)
  end

  defp verify_expr(%{node: :match, pattern: pattern, expr: expr}, core, manifest) do
    with :ok <- verify_match_pattern(pattern, core, manifest) do
      verify_expr(expr, core, manifest)
    end
  end

  defp verify_expr(%{node: :block, exprs: exprs}, core, manifest),
    do: verify_exprs(exprs, core, manifest)

  defp verify_expr(%{node: :list, items: items}, core, manifest),
    do: verify_exprs(items, core, manifest)

  defp verify_expr(%{node: :cons, head: head, tail: tail}, core, manifest) do
    with :ok <- verify_expr(head, core, manifest), do: verify_expr(tail, core, manifest)
  end

  defp verify_expr(%{node: :tuple, items: items}, core, manifest),
    do: verify_exprs(items, core, manifest)

  defp verify_expr(%{node: :binary, parts: parts}, core, manifest),
    do: verify_bit_segments(parts, core, manifest, :expr)

  defp verify_expr(%{node: :map, fields: fields}, core, manifest) do
    Enum.reduce_while(fields, :ok, fn field, :ok ->
      with :ok <- verify_expr(field.key, core, manifest),
           :ok <- verify_expr(field.value, core, manifest) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp verify_expr(%{node: :map_update, base: base, fields: fields}, core, manifest) do
    with :ok <- verify_expr(base, core, manifest) do
      Enum.reduce_while(fields, :ok, fn field, :ok ->
        with :ok <- verify_expr(field.key, core, manifest),
             :ok <- verify_expr(field.value, core, manifest) do
          {:cont, :ok}
        else
          error -> {:halt, error}
        end
      end)
    end
  end

  defp verify_expr(%{node: node} = expr, core, manifest)
       when node in [:record_create, :record_update, :record_access, :record_index],
       do: verify_record_expr(expr, core, manifest)

  defp verify_expr(%{node: :record_info, item: item, name: name}, core, _manifest)
       when item in ["fields", "size"],
       do: verify_record_fields(core, name, [])

  defp verify_expr(%{node: :record_info}, _core, _manifest),
    do: {:error, Hyperlang.Error.new(:verify, "record_info item must be fields or size")}

  defp verify_expr(
         %{
           node: :local_call,
           function: "process_info",
           args: [
             %{node: :local_call, function: "self", args: []},
             %{node: :atom, value: "links"}
           ]
         },
         _core,
         _manifest
       ),
       do: :ok

  defp verify_expr(%{node: :local_call, function: "process_info"}, _core, _manifest) do
    {:error, Hyperlang.Error.new(:verify, "process_info: only (self(), links) is supported")}
  end

  defp verify_expr(%{node: :local_call, function: function, args: args}, core, manifest) do
    cond do
      function == "module_info" ->
        {:error, Hyperlang.Error.new(:verify, "module_info is forbidden")}

      Map.has_key?(core.functions || %{}, {function, length(args)}) ->
        verify_exprs(args, core, manifest)

      native_process_call?("erlang", function, length(args)) ->
        verify_exprs(args, core, manifest)

      forbidden_local?(function, length(args)) ->
        {:error, Hyperlang.Error.new(:verify, "forbidden local call #{function}/#{length(args)}")}

      allowed_bif?(function, length(args), manifest) ->
        verify_exprs(args, core, manifest)

      true ->
        {:error, Hyperlang.Error.new(:verify, "unknown local call #{function}/#{length(args)}")}
    end
  end

  defp verify_expr(%{node: :safe_local_call, function: function, args: args}, core, manifest) do
    if generated_helper_atom?(function) do
      verify_exprs(args, core, manifest)
    else
      {:error, Hyperlang.Error.new(:verify, "invalid generated helper call")}
    end
  end

  defp verify_expr(
         %{node: :safe_import_call, import_name: {module, function, arity}, args: args},
         core,
         manifest
       ) do
    if Manifest.binding_for_call(manifest, module, function, arity) != nil and
         length(args) == arity do
      verify_exprs(args, core, manifest)
    else
      {:error, Hyperlang.Error.new(:verify, "invalid classified import call")}
    end
  end

  defp verify_expr(
         %{node: :safe_stdlib_call, module: module, function: function, arity: arity, args: args},
         core,
         manifest
       ) do
    if (Hyperlang.Stdlib.allowed?(manifest, module, function, arity) or
          opaque_supervisor_clock?(core, manifest, module, function, arity)) and
         length(args) == arity do
      verify_exprs(args, core, manifest)
    else
      {:error, Hyperlang.Error.new(:verify, "invalid classified stdlib call")}
    end
  end

  defp verify_expr(
         %{node: :safe_module_call, module: module, function: function, arity: arity, args: args},
         core,
         manifest
       ) do
    if Map.get(manifest, :modules, %{}) |> Map.get(:enabled, false) and
         is_binary(module) and is_binary(function) and length(args) == arity do
      verify_exprs(args, core, manifest)
    else
      {:error, Hyperlang.Error.new(:verify, "invalid classified module call")}
    end
  end

  defp verify_expr(
         %{
           node: :safe_behaviour_callback,
           module: module,
           function: function,
           arity: arity,
           args: args
         },
         core,
         manifest
       ) do
    if behaviour_callback?(manifest, module, function, arity) and length(args) == arity do
      with :ok <- verify_expr(module, core, manifest),
           :ok <- verify_exprs(args, core, manifest) do
        :ok
      end
    else
      {:error, Hyperlang.Error.new(:verify, "invalid classified behaviour callback")}
    end
  end

  defp verify_expr(
         %{
           node: :safe_filesystem_call,
           module: module,
           function: function,
           arity: arity,
           args: args
         },
         core,
         manifest
       ) do
    if Hyperlang.Filesystem.call_target(manifest, module, function, arity) != :error and
         length(args) == arity do
      verify_exprs(args, core, manifest)
    else
      {:error, Hyperlang.Error.new(:verify, "invalid classified filesystem call")}
    end
  end

  defp verify_expr(
         %{
           node: :safe_code_call,
           module: module,
           function: function,
           arity: arity,
           args: args
         },
         core,
         manifest
       ) do
    if Hyperlang.Code.call_target(manifest, module, function, arity) != :error and
         length(args) == arity do
      verify_exprs(args, core, manifest)
    else
      {:error, Hyperlang.Error.new(:verify, "invalid classified code call")}
    end
  end

  defp verify_expr(
         %{
           node: :safe_loader_call,
           module: module,
           function: function,
           arity: arity,
           args: args
         },
         core,
         manifest
       ) do
    if Hyperlang.Loader.call_target(manifest, module, function, arity) != :error and
         length(args) == arity do
      verify_exprs(args, core, manifest)
    else
      {:error, Hyperlang.Error.new(:verify, "invalid classified loader call")}
    end
  end

  defp verify_expr(
         %{
           node: :safe_table_call,
           module: module,
           function: function,
           arity: arity,
           args: args
         },
         core,
         manifest
       ) do
    if Hyperlang.Table.call_target(manifest, module, function, arity) != :error and
         length(args) == arity do
      verify_exprs(args, core, manifest)
    else
      {:error, Hyperlang.Error.new(:verify, "invalid classified table call")}
    end
  end

  defp verify_expr(%{node: :native_spawn, fun: fun}, core, manifest) do
    verify_expr(fun, core, manifest)
  end

  defp verify_expr(%{node: :native_exit, target: target, reason: reason}, core, manifest) do
    with :ok <- verify_expr(target, core, manifest), do: verify_expr(reason, core, manifest)
  end

  defp verify_expr(%{node: node, time: time, target: target, message: message}, core, manifest)
       when node in [:native_send_after, :native_start_timer] do
    with :ok <- verify_expr(time, core, manifest),
         :ok <- verify_expr(target, core, manifest) do
      verify_expr(message, core, manifest)
    end
  end

  defp verify_expr(%{node: node, ref: ref}, core, manifest)
       when node in [:native_cancel_timer, :native_read_timer],
       do: verify_expr(ref, core, manifest)

  defp verify_expr(%{node: :native_timer_sleep, time: time}, core, manifest),
    do: verify_expr(time, core, manifest)

  defp verify_expr(%{node: :native_spawn_link, fun: fun}, core, manifest) do
    verify_expr(fun, core, manifest)
  end

  defp verify_expr(%{node: :native_spawn_monitor, fun: fun}, core, manifest) do
    verify_expr(fun, core, manifest)
  end

  defp verify_expr(%{node: :native_register, name: name, target: target}, core, manifest) do
    with :ok <- verify_literal(name, core, manifest), do: verify_expr(target, core, manifest)
  end

  defp verify_expr(%{node: :native_whereis, name: name}, core, manifest),
    do: verify_literal(name, core, manifest)

  defp verify_expr(%{node: :native_unregister, name: name}, core, manifest),
    do: verify_literal(name, core, manifest)

  defp verify_expr(%{node: :native_monitor, target: target}, core, manifest),
    do: verify_expr(target, core, manifest)

  defp verify_expr(%{node: :native_make_ref}, _core, _manifest), do: :ok
  defp verify_expr(%{node: :native_process_info_links}, _core, _manifest), do: :ok

  defp verify_expr(%{node: :native_is_process_alive, target: target}, core, manifest),
    do: verify_expr(target, core, manifest)

  defp verify_expr(%{node: node, target: target}, core, manifest)
       when node in [:native_link, :native_unlink],
       do: verify_expr(target, core, manifest)

  defp verify_expr(%{node: :native_demonitor, ref: ref, options: nil}, core, manifest),
    do: verify_expr(ref, core, manifest)

  defp verify_expr(%{node: :native_demonitor, ref: ref, options: options}, core, manifest) do
    with :ok <- verify_expr(ref, core, manifest), do: verify_expr(options, core, manifest)
  end

  defp verify_expr(%{node: :native_process_flag, flag: flag, value: value}, core, manifest) do
    with :ok <- verify_literal(flag, core, manifest), do: verify_expr(value, core, manifest)
  end

  defp verify_expr(
         %{node: :remote_call, module: module, function: function, args: args},
         core,
         manifest
       ) do
    arity = length(args)

    cond do
      # Resolution tier 1: a remote call to the
      # program's own module is the local function — admitted here exactly
      # when the local function exists, mirroring the classifier.
      own_module_call?(core, module) ->
        if Map.has_key?(core.functions || %{}, {function, arity}) and
             function != "module_info" and not forbidden_local?(function, arity) do
          verify_exprs(args, core, manifest)
        else
          {:error, Hyperlang.Error.new(:verify, "unknown local call #{function}/#{arity}")}
        end

      Hyperlang.Code.call_target(manifest, module, function, arity) != :error ->
        verify_exprs(args, core, manifest)

      Hyperlang.Filesystem.call_target(manifest, module, function, arity) != :error ->
        verify_exprs(args, core, manifest)

      Hyperlang.Loader.call_target(manifest, module, function, arity) != :error ->
        verify_exprs(args, core, manifest)

      Hyperlang.Table.call_target(manifest, module, function, arity) != :error ->
        verify_exprs(args, core, manifest)

      error = Hyperlang.Loader.call_diagnostic(manifest, module, function, arity) ->
        {:error, error}

      error = Hyperlang.Filesystem.call_diagnostic(manifest, module, function, arity) ->
        {:error, error}

      native_process_call?(module, function, arity) ->
        verify_exprs(args, core, manifest)

      native_timer_call?(module, function, arity) ->
        verify_exprs(args, core, manifest)

      forbidden_remote?(module, function) ->
        {:error,
         Hyperlang.Error.new(:verify, "forbidden remote call #{module}:#{function}/#{arity}")}

      function == "module_info" ->
        {:error, Hyperlang.Error.new(:verify, "module_info is forbidden")}

      # Resolution tier 2 (sticky stdlib surface) before tier 3 (manifest
      # imports), identical to the classifier ladder (classifier.ex
      # `classify_remote_call`). Stdlib wins: the manifest rejects imports on
      # reserved stdlib modules, so the two tiers are disjoint and this pass
      # admits the same calls either way — the order is kept identical so pass 1
      # and pass 2 cannot drift.
      Hyperlang.Stdlib.allowed?(manifest, module, function, arity) ->
        verify_exprs(args, core, manifest)

      Manifest.binding_for_call(manifest, module, function, arity) != nil ->
        verify_exprs(args, core, manifest)

      opaque_supervisor_clock?(core, manifest, module, function, arity) ->
        verify_exprs(args, core, manifest)

      not source_snapshot?(core) and Hyperlang.Classifier.code_path_call?(manifest, module) ->
        verify_exprs(args, core, manifest)

      true ->
        {:error,
         Hyperlang.Error.new(
           :verify,
           "remote call #{module}:#{function}/#{arity} is not declared"
         )}
    end
  end

  defp verify_expr(
         %{node: :dynamic_snapshot_call, module: module, args: args, candidates: candidates},
         core,
         manifest
       ) do
    if source_snapshot_dynamic_enabled?(core, manifest) and
         valid_dynamic_snapshot_candidates?(candidates, core, length(args)) do
      with :ok <- verify_expr(module, core, manifest), do: verify_exprs(args, core, manifest)
    else
      {:error, Hyperlang.Error.new(:verify, "dynamic remote calls are forbidden")}
    end
  end

  defp verify_expr(
         %{node: :safe_dynamic_snapshot_call, module: module, args: args, candidates: candidates},
         core,
         manifest
       ) do
    if source_snapshot_dynamic_enabled?(core, manifest) and
         valid_safe_dynamic_snapshot_candidates?(candidates, manifest) do
      with :ok <- verify_expr(module, core, manifest), do: verify_exprs(args, core, manifest)
    else
      {:error, Hyperlang.Error.new(:verify, "invalid classified dynamic snapshot call")}
    end
  end

  defp verify_expr(
         %{node: :dynamic_remote_call, module: module, function: function, args: args},
         core,
         manifest
       ) do
    arity = length(args)

    if behaviour_callback?(manifest, module, function, arity) do
      with :ok <- verify_expr(module, core, manifest),
           :ok <- verify_exprs(args, core, manifest) do
        :ok
      end
    else
      {:error, Hyperlang.Error.new(:verify, "dynamic remote calls are forbidden")}
    end
  end

  defp verify_expr(
         %{node: :snapshot_apply, target: target, function: function, args: args},
         core,
         manifest
       ) do
    if source_snapshot_dynamic_enabled?(core, manifest) do
      with :ok <- verify_expr(target, core, manifest),
           :ok <- verify_expr(function, core, manifest),
           do: verify_expr(args, core, manifest)
    else
      {:error, Hyperlang.Error.new(:verify, "dynamic apply/3 is forbidden")}
    end
  end

  defp verify_expr(
         %{
           node: :safe_snapshot_apply,
           target: target,
           function: function,
           args: args,
           candidates: candidates
         },
         core,
         manifest
       ) do
    if source_snapshot_dynamic_enabled?(core, manifest) and is_list(candidates) do
      with :ok <- verify_expr(target, core, manifest),
           :ok <- verify_expr(function, core, manifest),
           do: verify_expr(args, core, manifest)
    else
      {:error, Hyperlang.Error.new(:verify, "invalid classified snapshot apply")}
    end
  end

  defp verify_expr(%{node: :case, expr: expr, clauses: clauses}, core, manifest) do
    with :ok <- verify_expr(expr, core, manifest) do
      verify_case_clauses(clauses, core, manifest)
    end
  end

  defp verify_expr(%{node: :receive, clauses: clauses, timeout: timeout} = expr, core, manifest) do
    with :ok <- verify_case_clauses(clauses, core, manifest),
         :ok <- verify_expr(timeout, core, manifest) do
      verify_expr(Map.get(expr, :after_body), core, manifest)
    end
  end

  defp verify_expr(%{node: :receive, clauses: clauses}, core, manifest),
    do: verify_case_clauses(clauses, core, manifest)

  defp verify_expr(%{node: :if, clauses: clauses}, core, manifest),
    do: verify_if_clauses(clauses, core, manifest)

  defp verify_expr(%{node: :fun, clauses: clauses}, core, manifest),
    do: verify_case_clauses(clauses, core, manifest)

  defp verify_expr(%{node: :named_fun, clauses: clauses}, core, manifest),
    do: verify_case_clauses(clauses, core, manifest)

  defp verify_expr(%{node: :local_fun_ref, function: function, arity: arity}, core, manifest) do
    cond do
      function == "module_info" ->
        {:error, Hyperlang.Error.new(:verify, "module_info is forbidden")}

      arity > manifest.limits.max_function_arity ->
        {:error, Hyperlang.Error.new(:verify, "function arity exceeds limit")}

      Map.has_key?(core.functions || %{}, {function, arity}) ->
        :ok

      forbidden_local?(function, arity) ->
        {:error, Hyperlang.Error.new(:verify, "forbidden local fun capture #{function}/#{arity}")}

      true ->
        {:error, Hyperlang.Error.new(:verify, "unknown local fun capture #{function}/#{arity}")}
    end
  end

  defp verify_expr(%{node: :safe_local_fun_ref, function: function}, _core, _manifest) do
    if generated_helper_atom?(function) do
      :ok
    else
      {:error, Hyperlang.Error.new(:verify, "invalid generated helper capture")}
    end
  end

  defp verify_expr(%{node: :external_fun}, _core, _manifest),
    do: {:error, Hyperlang.Error.new(:verify, "external fun construction is forbidden")}

  defp verify_expr(%{node: :fun_call, callee: callee, args: args}, core, manifest) do
    with :ok <- verify_expr(callee, core, manifest) do
      verify_exprs(args, core, manifest)
    end
  end

  defp verify_expr(
         %{node: :try, body: body, of_clauses: of_clauses, catch_clauses: catch_clauses},
         core,
         manifest
       ) do
    with :ok <- verify_expr(body, core, manifest),
         :ok <- verify_case_clauses(of_clauses, core, manifest) do
      verify_case_clauses(catch_clauses, core, manifest)
    end
  end

  defp verify_expr(%{node: :list_comp, expr: expr, qualifiers: quals}, core, manifest) do
    with :ok <- verify_expr(expr, core, manifest) do
      verify_qualifiers(quals, core, manifest)
    end
  end

  defp verify_expr(%{node: :map_comp, key: key, value: value, qualifiers: quals}, core, manifest) do
    with :ok <- verify_expr(key, core, manifest),
         :ok <- verify_expr(value, core, manifest) do
      verify_qualifiers(quals, core, manifest)
    end
  end

  defp verify_expr(%{node: :binary_comp, expr: expr, qualifiers: quals}, core, manifest) do
    with :ok <- verify_expr(expr, core, manifest) do
      verify_qualifiers(quals, core, manifest)
    end
  end

  defp verify_expr(_, _core, _manifest),
    do: {:error, Hyperlang.Error.new(:verify, "unsupported expression")}

  defp verify_case_clauses(clauses, core, manifest) do
    Enum.reduce_while(clauses, :ok, fn clause, :ok ->
      with :ok <- verify_patterns(clause.patterns, core, manifest),
           :ok <- verify_expr(clause.guard, core, manifest),
           :ok <- verify_expr(clause.body, core, manifest) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp verify_if_clauses(clauses, core, manifest) do
    Enum.reduce_while(clauses, :ok, fn clause, :ok ->
      with :ok <- verify_expr(clause.guard, core, manifest),
           :ok <- verify_expr(clause.body, core, manifest) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp verify_exprs(exprs, core, manifest),
    do: Enum.reduce_while(exprs, :ok, fn expr, :ok -> step(verify_expr(expr, core, manifest)) end)

  defp verify_bit_segments(parts, core, manifest, mode) do
    with :ok <- verify_bit_segment_budget(parts, manifest) do
      Enum.reduce_while(parts, :ok, fn segment, :ok ->
        step(verify_bit_segment(segment, core, manifest, mode))
      end)
    end
  end

  defp verify_bit_segment(
         %{node: :bit_segment, expr: expr, size: size, types: types},
         core,
         manifest,
         mode
       ) do
    with :ok <- verify_segment_types(types),
         :ok <- verify_segment_size(size, core, manifest) do
      case mode do
        :expr -> verify_expr(expr, core, manifest)
        :pattern -> verify_match_pattern(expr, core, manifest)
      end
    end
  end

  defp verify_bit_segment(_segment, _core, _manifest, _mode),
    do: {:error, Hyperlang.Error.new(:verify, "invalid bit syntax segment")}

  defp verify_segment_size(:default, _core, _manifest), do: :ok
  defp verify_segment_size(size, core, manifest), do: verify_expr(size, core, manifest)

  defp verify_segment_types(:default), do: :ok

  defp verify_segment_types(types) when is_list(types) do
    Enum.reduce_while(types, %{type: 0, sign: 0, endian: 0, unit: 0}, fn modifier, counts ->
      with {:ok, category} <- segment_modifier_category(modifier),
           {:ok, counts} <- bump_segment_modifier(counts, category) do
        {:cont, counts}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      %{} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp verify_segment_types(_types),
    do: {:error, Hyperlang.Error.new(:verify, "invalid bit syntax type specifier")}

  defp segment_modifier_category({"unit", value})
       when is_integer(value) and value >= 1 and value <= 256,
       do: {:ok, :unit}

  defp segment_modifier_category({"unit", _value}),
    do: {:error, Hyperlang.Error.new(:verify, "bit syntax unit must be an integer from 1 to 256")}

  defp segment_modifier_category(modifier) when modifier in @segment_type_modifiers,
    do: {:ok, :type}

  defp segment_modifier_category(modifier) when modifier in @segment_sign_modifiers,
    do: {:ok, :sign}

  defp segment_modifier_category(modifier) when modifier in @segment_endian_modifiers,
    do: {:ok, :endian}

  defp segment_modifier_category(_modifier),
    do: {:error, Hyperlang.Error.new(:verify, "unsupported bit syntax type specifier")}

  defp bump_segment_modifier(counts, category) do
    next = Map.update!(counts, category, &(&1 + 1))

    if Map.fetch!(next, category) <= 1 do
      {:ok, next}
    else
      {:error, Hyperlang.Error.new(:verify, "duplicate bit syntax type specifier")}
    end
  end

  defp verify_bit_segment_budget(parts, manifest) do
    max_bits = manifest.limits.max_binary_bytes * 8

    Enum.reduce_while(parts, 0, fn segment, acc ->
      case static_segment_bits(segment) do
        {:ok, bits} ->
          next = acc + bits

          if next <= max_bits do
            {:cont, next}
          else
            {:halt,
             {:error,
              Hyperlang.Error.new(:verify, "bit syntax expansion exceeds max_binary_bytes",
                details: %{limit: manifest.limits.max_binary_bytes}
              )}}
          end

        :unknown ->
          {:cont, acc}
      end
    end)
    |> case do
      bits when is_integer(bits) -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp static_segment_bits(%{node: :bit_segment, size: size, types: types, expr: expr}) do
    cond do
      is_integer_literal?(size) ->
        # A sized string emits one segment per codepoint, so account for the
        # complete literal rather than only one segment.
        {:ok, max(0, size.value) * segment_unit(types) * segment_repeat(expr)}

      size == :default ->
        default_static_segment_bits(expr, types)

      true ->
        :unknown
    end
  end

  defp static_segment_bits(_segment), do: :unknown

  defp segment_repeat(%{node: :string, value: value}) when is_binary(value),
    do: length(String.to_charlist(value))

  defp segment_repeat(%{node: :literal_pattern, literal: literal}), do: segment_repeat(literal)
  defp segment_repeat(_expr), do: 1

  defp default_static_segment_bits(%{node: :string, value: value}, _types),
    do: {:ok, byte_size(value) * 8}

  defp default_static_segment_bits(%{node: :literal_pattern, literal: literal}, types),
    do: default_static_segment_bits(literal, types)

  defp default_static_segment_bits(%{node: :int}, types), do: {:ok, default_segment_size(types)}
  defp default_static_segment_bits(%{node: :float}, types), do: {:ok, default_segment_size(types)}

  defp default_static_segment_bits(%{node: :binary, parts: parts}, _types) do
    Enum.reduce_while(parts, 0, fn part, acc ->
      case static_segment_bits(part) do
        {:ok, bits} -> {:cont, acc + bits}
        :unknown -> {:halt, :unknown}
      end
    end)
    |> case do
      bits when is_integer(bits) -> {:ok, bits}
      :unknown -> :unknown
    end
  end

  defp default_static_segment_bits(_expr, _types), do: :unknown

  defp is_integer_literal?(%{node: :int, value: value}) when is_integer(value), do: true
  defp is_integer_literal?(_), do: false

  defp segment_unit(types) do
    case Enum.find(segment_types_list(types), &match?({"unit", _}, &1)) do
      {"unit", value} -> value
      nil -> default_unit(types)
    end
  end

  defp default_unit(types) do
    case segment_primary_type(types) do
      type when type in ["binary", "bytes"] -> 8
      _type -> 1
    end
  end

  defp default_segment_size(types) do
    case segment_primary_type(types) do
      "float" -> 64
      "utf8" -> 32
      "utf16" -> 32
      "utf32" -> 32
      _type -> 8
    end
  end

  defp segment_primary_type(types) do
    Enum.find(segment_types_list(types), "integer", &(&1 in @segment_type_modifiers))
  end

  defp segment_types_list(:default), do: []
  defp segment_types_list(types) when is_list(types), do: types

  defp verify_qualifiers(quals, core, manifest) do
    Enum.reduce_while(quals, :ok, fn
      %{node: node, pattern: pat, expr: gen}, :ok when node in [:generator, :b_generator] ->
        with :ok <- verify_pattern(pat, core, manifest),
             :ok <- verify_expr(gen, core, manifest),
             do: {:cont, :ok},
             else: (error -> {:halt, error})

      %{node: :filter, expr: filter}, :ok ->
        step(verify_expr(filter, core, manifest))
    end)
  end

  defp verify_literal(%{node: :int, value: value}, _core, manifest) do
    if value == 0 or value |> abs() |> :math.log2() |> trunc() < manifest.limits.max_integer_bits do
      :ok
    else
      {:error, Hyperlang.Error.new(:verify, "integer literal exceeds bit limit")}
    end
  rescue
    _ -> :ok
  end

  defp verify_literal(%{node: :string, value: value}, _core, manifest) do
    if byte_size(value) <= manifest.limits.max_binary_bytes,
      do: :ok,
      else: {:error, Hyperlang.Error.new(:verify, "string literal exceeds byte limit")}
  end

  defp verify_literal(%{node: :atom, value: value}, core, _manifest) do
    atom_pool = Map.get(core.metadata || %{}, :atom_pool, %{})
    source_to_pool = Map.get(atom_pool, :source_to_pool, %{})
    allowed = Map.get(atom_pool, :allowed_source_atoms, MapSet.new())

    if Map.has_key?(source_to_pool, value) or MapSet.member?(allowed, value) do
      :ok
    else
      {:error,
       Hyperlang.Error.new(:verify, "atom literal is not in the Hyperlang atom pool",
         details: %{atom: value}
       )}
    end
  end

  defp verify_literal(_literal, _core, _manifest), do: :ok

  defp verify_match_pattern(%{node: node} = pattern, core, manifest)
       when node in [
              :var_pattern,
              :wild_pattern,
              :literal_pattern,
              :alias_pattern,
              :tuple_pattern,
              :list_pattern,
              :cons_pattern,
              :map_pattern,
              :record_pattern
            ],
       do: verify_pattern(pattern, core, manifest)

  defp verify_match_pattern(%{node: :var}, _core, _manifest), do: :ok

  defp verify_match_pattern(%{node: :alias, left: left, right: right}, core, manifest) do
    with :ok <- verify_match_pattern(left, core, manifest),
         do: verify_match_pattern(right, core, manifest)
  end

  defp verify_match_pattern(%{node: node} = literal, core, manifest)
       when node in [:int, :float, :string, :atom, :bool],
       do: verify_literal(literal, core, manifest)

  defp verify_match_pattern(%{node: :tuple, items: items}, core, manifest),
    do:
      Enum.reduce_while(items, :ok, fn item, :ok ->
        step(verify_match_pattern(item, core, manifest))
      end)

  defp verify_match_pattern(%{node: :list, items: items}, core, manifest),
    do:
      Enum.reduce_while(items, :ok, fn item, :ok ->
        step(verify_match_pattern(item, core, manifest))
      end)

  defp verify_match_pattern(%{node: :cons, head: head, tail: tail}, core, manifest) do
    with :ok <- verify_match_pattern(head, core, manifest),
         do: verify_match_pattern(tail, core, manifest)
  end

  defp verify_match_pattern(%{node: :map, fields: fields}, core, manifest) do
    Enum.reduce_while(fields, :ok, fn field, :ok ->
      with :ok <- verify_expr(field.key, core, manifest),
           :ok <- verify_match_pattern(field.value, core, manifest) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp verify_match_pattern(%{node: :binary, parts: parts}, core, manifest),
    do: verify_bit_segments(parts, core, manifest, :pattern)

  defp verify_match_pattern(_pattern, _core, _manifest),
    do: {:error, Hyperlang.Error.new(:verify, "match left side must be a safe pattern")}

  # Pass 2 re-checks the same policy the classifier applied in pass 1. The table
  # itself lives in the classifier (Hyperlang.Classifier.forbidden_remote_table/0);
  # only the re-check is duplicated, which is the point of the two passes.
  defp forbidden_remote?(module, function),
    do: Hyperlang.Classifier.forbidden_remote?(module, function)

  defp forbidden_local?(function, arity),
    do: Hyperlang.Classifier.forbidden_local?(function, arity)

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

  defp own_module_call?(%{metadata: %{source_contract: %{module: own_module}}}, module)
       when is_binary(own_module),
       do: module == own_module

  defp own_module_call?(_core, _module), do: false

  defp source_snapshot?(%{metadata: %{source_contract: %{filesystem_snapshot: true}}}), do: true
  defp source_snapshot?(_core), do: false

  defp behaviour_callback?(
         %{modules: %{callback_dispatch: true}},
         %{node: :var, name: "Module"},
         function,
         arity
       ),
       do: is_binary(function) and is_integer(arity) and arity >= 0

  defp behaviour_callback?(_manifest, _module, _function, _arity), do: false

  defp opaque_supervisor_clock?(
         _core,
         %{capabilities: %{gen_server: true}},
         "erlang",
         "monotonic_time",
         1
       ),
       do: true

  defp opaque_supervisor_clock?(_core, _manifest, _module, _function, _arity), do: false

  defp source_snapshot_dynamic_enabled?(
         %{metadata: %{source_contract: %{filesystem_snapshot: true}}},
         %{modules: %{enabled: true}}
       ),
       do: true

  defp source_snapshot_dynamic_enabled?(_core, _manifest), do: false

  defp valid_dynamic_snapshot_candidates?(candidates, core, arity)
       when is_list(candidates) and candidates != [] do
    Enum.all?(candidates, fn
      %{module: module, function: function, arity: ^arity}
      when is_binary(module) and is_binary(function) ->
        Map.has_key?(core.functions || %{}, {function, arity})

      _candidate ->
        false
    end)
  end

  defp valid_dynamic_snapshot_candidates?(_candidates, _core, _arity), do: false

  defp valid_safe_dynamic_snapshot_candidates?(candidates, manifest)
       when is_list(candidates) and candidates != [] do
    guest_modules =
      manifest
      |> Map.get(:modules, %{})
      |> Map.get(:guest_modules, [])
      |> MapSet.new()

    Enum.all?(candidates, fn
      %{module: module, function: function} when is_binary(module) and is_atom(function) ->
        MapSet.member?(guest_modules, module) and generated_helper_atom?(function)

      _candidate ->
        false
    end)
  end

  defp valid_safe_dynamic_snapshot_candidates?(_candidates, _manifest), do: false

  defp allowed_bif?(function, arity, manifest),
    do: Hyperlang.Stdlib.allowed?(manifest, "erlang", function, arity)

  defp generated_helper_atom?(:safe_result), do: true

  defp generated_helper_atom?(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> String.match?(~r/^safe_f_\d+$/)
  end

  defp generated_helper_atom?(_), do: false

  defp verify_source_semantics(core, manifest) do
    Enum.reduce_while(core.functions, :ok, fn {_key, fun}, :ok ->
      case verify_function_semantics(fun, core, manifest) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp verify_function_semantics(fun, core, manifest) do
    Enum.reduce_while(fun.clauses, :ok, fn clause, :ok ->
      with {:ok, env} <- semantic_clause_patterns(clause.patterns, MapSet.new(), core, manifest),
           {:ok, _env} <- semantic_expr(clause.guard, env, :guard, core, manifest),
           {:ok, _env} <- semantic_expr(clause.body, env, :expr, core, manifest) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp semantic_expr(nil, env, _mode, _core, _manifest), do: {:ok, env}

  defp semantic_expr(%{node: node}, env, _mode, _core, _manifest)
       when node in [:int, :float, :string, :atom, :bool],
       do: {:ok, env}

  defp semantic_expr(%{node: :var, name: "_"}, env, _mode, _core, _manifest), do: {:ok, env}

  defp semantic_expr(%{node: :var, name: name}, env, _mode, _core, _manifest) do
    if MapSet.member?(env, name) do
      {:ok, env}
    else
      {:error,
       Hyperlang.Error.new(:verify, "unbound variable #{name}",
         details: %{variable: name, hint: "bind #{name} before it is used"}
       )}
    end
  end

  defp semantic_expr(%{node: :unary, expr: expr}, env, mode, core, manifest),
    do: semantic_expr(expr, env, mode, core, manifest)

  defp semantic_expr(%{node: :binary_op, left: left, right: right}, env, mode, core, manifest) do
    with {:ok, env} <- semantic_expr(left, env, mode, core, manifest),
         {:ok, env} <- semantic_expr(right, env, mode, core, manifest) do
      {:ok, env}
    end
  end

  defp semantic_expr(
         %{node: :send},
         _env,
         :guard,
         _core,
         _manifest
       ) do
    guard_error("send expressions are not allowed in guards", expression: "send")
  end

  defp semantic_expr(%{node: :send, target: target, message: message}, env, mode, core, manifest) do
    with {:ok, _env} <- semantic_expr(target, env, mode, core, manifest),
         {:ok, _env} <- semantic_expr(message, env, mode, core, manifest) do
      {:ok, env}
    end
  end

  defp semantic_expr(%{node: :match, pattern: pattern, expr: expr}, env, _mode, core, manifest) do
    with {:ok, env} <- semantic_expr(expr, env, :expr, core, manifest),
         :ok <- semantic_pattern_keys(pattern, env, core, manifest) do
      {:ok, bind_pattern(env, pattern)}
    end
  end

  defp semantic_expr(%{node: :block, exprs: exprs}, env, mode, core, manifest),
    do: semantic_exprs(exprs, env, mode, core, manifest)

  defp semantic_expr(%{node: :list, items: items}, env, mode, core, manifest),
    do: semantic_exprs_keep_env(items, env, mode, core, manifest)

  defp semantic_expr(%{node: :cons, head: head, tail: tail}, env, mode, core, manifest) do
    with {:ok, _env} <- semantic_expr(head, env, mode, core, manifest),
         {:ok, _env} <- semantic_expr(tail, env, mode, core, manifest) do
      {:ok, env}
    end
  end

  defp semantic_expr(%{node: :tuple, items: items}, env, mode, core, manifest),
    do: semantic_exprs_keep_env(items, env, mode, core, manifest)

  defp semantic_expr(%{node: :binary, parts: parts}, env, mode, core, manifest),
    do: semantic_bit_segments(parts, env, mode, core, manifest)

  defp semantic_expr(%{node: :bit_segment, expr: expr, size: size}, env, mode, core, manifest) do
    with {:ok, _env} <- semantic_segment_size(size, env, mode, core, manifest),
         {:ok, _env} <- semantic_expr(expr, env, mode, core, manifest) do
      {:ok, env}
    end
  end

  defp semantic_expr(%{node: :map, fields: fields}, env, mode, core, manifest) do
    Enum.reduce_while(fields, {:ok, env}, fn field, {:ok, env} ->
      with {:ok, _env} <- semantic_expr(field.key, env, mode, core, manifest),
           {:ok, _env} <- semantic_expr(field.value, env, mode, core, manifest) do
        {:cont, {:ok, env}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp semantic_expr(%{node: :map_update, base: base, fields: fields}, env, mode, core, manifest) do
    with {:ok, _env} <- semantic_expr(base, env, mode, core, manifest) do
      semantic_expr(%{node: :map, fields: fields}, env, mode, core, manifest)
    end
  end

  defp semantic_expr(%{node: node} = expr, env, mode, core, manifest)
       when node in [:record_create, :record_update, :record_access, :record_index],
       do: semantic_record_expr(expr, env, mode, core, manifest)

  defp semantic_expr(%{node: :record_info}, env, _mode, _core, _manifest), do: {:ok, env}

  defp semantic_expr(
         %{node: :local_call, function: function, args: args},
         env,
         :guard,
         core,
         manifest
       ) do
    cond do
      Map.has_key?(core.functions || %{}, {function, length(args)}) ->
        guard_error("local function #{function}/#{length(args)} cannot be called in a guard",
          function: function,
          arity: length(args)
        )

      guard_bif?(function, length(args), manifest) ->
        semantic_exprs_keep_env(args, env, :guard, core, manifest)

      true ->
        guard_error("call #{function}/#{length(args)} is not allowed in a guard",
          function: function,
          arity: length(args)
        )
    end
  end

  defp semantic_expr(%{node: :local_call, args: args}, env, mode, core, manifest),
    do: semantic_exprs_keep_env(args, env, mode, core, manifest)

  defp semantic_expr(
         %{node: :remote_call, module: module, function: function, args: args},
         env,
         :guard,
         core,
         manifest
       ) do
    if module == "erlang" and guard_bif?(function, length(args), manifest) do
      semantic_exprs_keep_env(args, env, :guard, core, manifest)
    else
      guard_error("remote call #{module}:#{function}/#{length(args)} is not allowed in a guard",
        module: module,
        function: function,
        arity: length(args)
      )
    end
  end

  defp semantic_expr(%{node: :remote_call, args: args}, env, mode, core, manifest),
    do: semantic_exprs_keep_env(args, env, mode, core, manifest)

  defp semantic_expr(%{node: node, args: args}, _env, :guard, _core, _manifest)
       when node in [:dynamic_remote_call, :dynamic_snapshot_call, :safe_dynamic_snapshot_call],
       do: guard_error("dynamic remote calls are not allowed in guards", arity: length(args))

  defp semantic_expr(%{node: :dynamic_remote_call, args: args} = expr, env, mode, core, manifest) do
    with {:ok, _env} <- semantic_optional_expr(Map.get(expr, :module), env, mode, core, manifest) do
      semantic_exprs_keep_env(args, env, mode, core, manifest)
    end
  end

  defp semantic_expr(%{node: :safe_snapshot_apply}, _env, :guard, _core, _manifest),
    do: guard_error("apply/3 is not allowed in guards", expression: "apply/3")

  defp semantic_expr(
         %{node: :safe_snapshot_apply, target: target, function: function, args: args},
         env,
         mode,
         core,
         manifest
       ) do
    with {:ok, env} <- semantic_expr(target, env, mode, core, manifest),
         {:ok, env} <- semantic_expr(function, env, mode, core, manifest) do
      semantic_expr(args, env, mode, core, manifest)
    end
  end

  defp semantic_expr(%{node: node, module: module, args: args}, env, mode, core, manifest)
       when node in [:dynamic_snapshot_call, :safe_dynamic_snapshot_call] do
    with {:ok, _env} <- semantic_expr(module, env, mode, core, manifest) do
      semantic_exprs_keep_env(args, env, mode, core, manifest)
    end
  end

  defp semantic_expr(%{node: :safe_local_call, args: args}, _env, :guard, _core, _manifest),
    do: guard_error("local helper calls are not allowed in guards", arity: length(args))

  defp semantic_expr(%{node: :safe_local_call, args: args}, env, mode, core, manifest),
    do: semantic_exprs_keep_env(args, env, mode, core, manifest)

  defp semantic_expr(%{node: :safe_import_call, args: args}, _env, :guard, _core, _manifest),
    do: guard_error("host imports are not allowed in guards", arity: length(args))

  defp semantic_expr(%{node: :safe_import_call, args: args}, env, mode, core, manifest),
    do: semantic_exprs_keep_env(args, env, mode, core, manifest)

  defp semantic_expr(
         %{node: :safe_stdlib_call, module: module, function: function, arity: arity, args: args},
         env,
         :guard,
         core,
         manifest
       ) do
    if module == "erlang" and guard_bif?(function, arity, manifest) do
      semantic_exprs_keep_env(args, env, :guard, core, manifest)
    else
      guard_error("stdlib call #{module}:#{function}/#{arity} is not allowed in a guard",
        module: module,
        function: function,
        arity: arity
      )
    end
  end

  defp semantic_expr(%{node: :safe_stdlib_call, args: args}, env, mode, core, manifest),
    do: semantic_exprs_keep_env(args, env, mode, core, manifest)

  defp semantic_expr(
         %{
           node: :safe_filesystem_call,
           module: module,
           function: function,
           arity: arity,
           args: args
         },
         _env,
         :guard,
         _core,
         _manifest
       ) do
    guard_error("filesystem call #{module}:#{function}/#{arity} is not allowed in a guard",
      module: module,
      function: function,
      arity: arity,
      arg_count: length(args)
    )
  end

  defp semantic_expr(%{node: :safe_filesystem_call, args: args}, env, mode, core, manifest),
    do: semantic_exprs_keep_env(args, env, mode, core, manifest)

  defp semantic_expr(
         %{
           node: :safe_code_call,
           module: module,
           function: function,
           arity: arity,
           args: args
         },
         _env,
         :guard,
         _core,
         _manifest
       ) do
    guard_error("code call #{module}:#{function}/#{arity} is not allowed in a guard",
      module: module,
      function: function,
      arity: arity,
      arg_count: length(args)
    )
  end

  defp semantic_expr(%{node: :safe_code_call, args: args}, env, mode, core, manifest),
    do: semantic_exprs_keep_env(args, env, mode, core, manifest)

  defp semantic_expr(%{node: node, args: args}, _env, :guard, _core, _manifest)
       when node in [:safe_loader_call, :safe_module_call, :safe_behaviour_callback],
       do: guard_error("module and loader calls are not allowed in guards", arity: length(args))

  defp semantic_expr(
         %{node: :safe_behaviour_callback, module: module, args: args},
         env,
         mode,
         core,
         manifest
       ) do
    with {:ok, _env} <- semantic_expr(module, env, mode, core, manifest) do
      semantic_exprs_keep_env(args, env, mode, core, manifest)
    end
  end

  defp semantic_expr(%{node: node, args: args}, env, mode, core, manifest)
       when node in [:safe_loader_call, :safe_module_call],
       do: semantic_exprs_keep_env(args, env, mode, core, manifest)

  defp semantic_expr(
         %{
           node: :safe_table_call,
           module: module,
           function: function,
           arity: arity,
           args: args
         },
         _env,
         :guard,
         _core,
         _manifest
       ) do
    guard_error("table call #{module}:#{function}/#{arity} is not allowed in a guard",
      module: module,
      function: function,
      arity: arity,
      arg_count: length(args)
    )
  end

  defp semantic_expr(%{node: :safe_table_call, args: args}, env, mode, core, manifest),
    do: semantic_exprs_keep_env(args, env, mode, core, manifest)

  defp semantic_expr(%{node: node}, _env, :guard, _core, _manifest)
       when node in [
              :native_spawn,
              :native_spawn_link,
              :native_spawn_monitor,
              :native_register,
              :native_whereis,
              :native_unregister,
              :native_monitor,
              :native_make_ref,
              :native_is_process_alive,
              :native_process_info_links,
              :native_demonitor,
              :native_link,
              :native_unlink,
              :native_process_flag
            ] do
    guard_error("process calls are not allowed in guards", expression: Atom.to_string(node))
  end

  defp semantic_expr(%{node: :native_spawn, fun: fun}, env, mode, core, manifest),
    do: semantic_expr(fun, env, mode, core, manifest)

  defp semantic_expr(%{node: :native_spawn_link, fun: fun}, env, mode, core, manifest),
    do: semantic_expr(fun, env, mode, core, manifest)

  defp semantic_expr(%{node: :native_spawn_monitor, fun: fun}, env, mode, core, manifest),
    do: semantic_expr(fun, env, mode, core, manifest)

  defp semantic_expr(%{node: :native_register, target: target}, env, mode, core, manifest),
    do: semantic_expr(target, env, mode, core, manifest)

  defp semantic_expr(%{node: node}, env, _mode, _core, _manifest)
       when node in [:native_whereis, :native_unregister],
       do: {:ok, env}

  defp semantic_expr(%{node: :native_monitor, target: target}, env, mode, core, manifest),
    do: semantic_expr(target, env, mode, core, manifest)

  defp semantic_expr(%{node: node}, env, _mode, _core, _manifest)
       when node in [:native_make_ref, :native_process_info_links],
       do: {:ok, env}

  defp semantic_expr(
         %{node: :native_is_process_alive, target: target},
         env,
         mode,
         core,
         manifest
       ),
       do: semantic_expr(target, env, mode, core, manifest)

  defp semantic_expr(%{node: node, target: target}, env, mode, core, manifest)
       when node in [:native_link, :native_unlink],
       do: semantic_expr(target, env, mode, core, manifest)

  defp semantic_expr(
         %{node: :native_demonitor, ref: ref, options: nil},
         env,
         mode,
         core,
         manifest
       ),
       do: semantic_expr(ref, env, mode, core, manifest)

  defp semantic_expr(
         %{node: :native_demonitor, ref: ref, options: options},
         env,
         mode,
         core,
         manifest
       ) do
    with {:ok, _env} <- semantic_expr(ref, env, mode, core, manifest),
         {:ok, _env} <- semantic_expr(options, env, mode, core, manifest) do
      {:ok, env}
    end
  end

  defp semantic_expr(%{node: :native_process_flag, value: value}, env, mode, core, manifest),
    do: semantic_expr(value, env, mode, core, manifest)

  # Erlang guards are guard tests only. These expression forms switch their
  # bodies to expression mode, so admitting them in a guard would let a body
  # call (a stdlib or host call) reach codegen's guard lowering unchecked.
  defp semantic_expr(%{node: node}, _env, :guard, _core, _manifest)
       when node in [
              :case,
              :if,
              :fun,
              :named_fun,
              :try,
              :list_comp,
              :binary_comp,
              :map_comp
            ] do
    guard_error("#{node} expressions are not allowed in guards", expression: Atom.to_string(node))
  end

  defp semantic_expr(%{node: :case, expr: expr, clauses: clauses}, env, _mode, core, manifest) do
    with {:ok, _env} <- semantic_expr(expr, env, :expr, core, manifest),
         :ok <- semantic_clauses(clauses, env, core, manifest) do
      {:ok, env}
    end
  end

  defp semantic_expr(
         %{node: :receive},
         _env,
         :guard,
         _core,
         _manifest
       ) do
    guard_error("receive expressions are not allowed in guards", expression: "receive")
  end

  defp semantic_expr(
         %{node: :receive, clauses: clauses, timeout: timeout} = expr,
         env,
         _mode,
         core,
         manifest
       ) do
    with :ok <- semantic_clauses(clauses, env, core, manifest),
         {:ok, _env} <- semantic_expr(timeout, env, :expr, core, manifest),
         {:ok, _env} <- semantic_expr(Map.get(expr, :after_body), env, :expr, core, manifest) do
      {:ok, env}
    end
  end

  defp semantic_expr(%{node: :receive, clauses: clauses}, env, _mode, core, manifest) do
    with :ok <- semantic_clauses(clauses, env, core, manifest), do: {:ok, env}
  end

  defp semantic_expr(%{node: :if, clauses: clauses}, env, _mode, core, manifest) do
    with :ok <- semantic_if_clauses(clauses, env, core, manifest), do: {:ok, env}
  end

  defp semantic_expr(%{node: :fun, clauses: clauses}, env, _mode, core, manifest) do
    with :ok <- semantic_clauses(clauses, env, core, manifest), do: {:ok, env}
  end

  defp semantic_expr(
         %{node: :named_fun, name: name, clauses: clauses},
         env,
         _mode,
         core,
         manifest
       ) do
    fun_env = MapSet.put(env, name)
    with :ok <- semantic_clauses(clauses, fun_env, core, manifest), do: {:ok, env}
  end

  defp semantic_expr(%{node: :external_fun}, env, _mode, _core, _manifest), do: {:ok, env}

  defp semantic_expr(
         %{node: node, function: function, arity: arity},
         _env,
         :guard,
         _core,
         _manifest
       )
       when node in [:local_fun_ref, :safe_local_fun_ref] do
    guard_error("fun capture #{function}/#{arity} is not allowed in a guard",
      function: function,
      arity: arity
    )
  end

  defp semantic_expr(%{node: node}, env, _mode, _core, _manifest)
       when node in [:local_fun_ref, :safe_local_fun_ref],
       do: {:ok, env}

  defp semantic_expr(
         %{node: :fun_call, callee: _callee, args: args},
         _env,
         :guard,
         _core,
         _manifest
       ) do
    guard_error("fun calls are not allowed in guards",
      arity: length(args),
      hint: "use case ... of true -> ...; false -> ... end outside the guard"
    )
  end

  defp semantic_expr(%{node: :fun_call, callee: callee, args: args}, env, mode, core, manifest) do
    with {:ok, _env} <- semantic_expr(callee, env, mode, core, manifest),
         {:ok, _env} <- semantic_exprs_keep_env(args, env, mode, core, manifest) do
      {:ok, env}
    end
  end

  defp semantic_expr(
         %{node: :try, body: body, of_clauses: of_clauses, catch_clauses: catch_clauses},
         env,
         _mode,
         core,
         manifest
       ) do
    with {:ok, body_env} <- semantic_expr(body, env, :expr, core, manifest),
         :ok <- semantic_clauses(of_clauses, body_env, core, manifest),
         :ok <- semantic_clauses(catch_clauses, env, core, manifest) do
      {:ok, env}
    end
  end

  defp semantic_expr(
         %{node: :list_comp, expr: expr, qualifiers: quals},
         env,
         _mode,
         core,
         manifest
       ) do
    with {:ok, comp_env} <- semantic_qualifiers(quals, env, core, manifest),
         {:ok, _env} <- semantic_expr(expr, comp_env, :expr, core, manifest) do
      {:ok, env}
    end
  end

  defp semantic_expr(
         %{node: :map_comp, key: key, value: value, qualifiers: quals},
         env,
         _mode,
         core,
         manifest
       ) do
    with {:ok, comp_env} <- semantic_qualifiers(quals, env, core, manifest),
         {:ok, _env} <- semantic_expr(key, comp_env, :expr, core, manifest),
         {:ok, _env} <- semantic_expr(value, comp_env, :expr, core, manifest) do
      {:ok, env}
    end
  end

  defp semantic_expr(
         %{node: :binary_comp, expr: expr, qualifiers: quals},
         env,
         _mode,
         core,
         manifest
       ) do
    with {:ok, comp_env} <- semantic_qualifiers(quals, env, core, manifest),
         {:ok, _env} <- semantic_expr(expr, comp_env, :expr, core, manifest) do
      {:ok, env}
    end
  end

  defp semantic_expr(_expr, env, _mode, _core, _manifest), do: {:ok, env}

  defp semantic_record_expr(%{node: :record_create, fields: fields}, env, mode, core, manifest),
    do: semantic_exprs(Enum.map(fields, & &1.value), env, mode, core, manifest)

  defp semantic_record_expr(
         %{node: :record_update, base: base, fields: fields},
         env,
         mode,
         core,
         manifest
       ) do
    with {:ok, env} <- semantic_expr(base, env, mode, core, manifest),
         do: semantic_exprs(Enum.map(fields, & &1.value), env, mode, core, manifest)
  end

  defp semantic_record_expr(%{node: :record_access, base: base}, env, mode, core, manifest),
    do: semantic_expr(base, env, mode, core, manifest)

  defp semantic_record_expr(%{node: :record_index}, env, _mode, _core, _manifest), do: {:ok, env}

  defp semantic_exprs(exprs, env, mode, core, manifest) do
    Enum.reduce_while(exprs, {:ok, env}, fn expr, {:ok, env} ->
      case semantic_expr(expr, env, mode, core, manifest) do
        {:ok, env} -> {:cont, {:ok, env}}
        error -> {:halt, error}
      end
    end)
  end

  defp semantic_exprs_keep_env(exprs, env, mode, core, manifest) do
    Enum.reduce_while(exprs, {:ok, env}, fn expr, {:ok, env} ->
      case semantic_expr(expr, env, mode, core, manifest) do
        {:ok, _env} -> {:cont, {:ok, env}}
        error -> {:halt, error}
      end
    end)
  end

  defp semantic_optional_expr(nil, env, _mode, _core, _manifest), do: {:ok, env}

  defp semantic_optional_expr(expr, env, mode, core, manifest),
    do: semantic_expr(expr, env, mode, core, manifest)

  defp semantic_bit_segments(parts, env, mode, core, manifest) do
    Enum.reduce_while(parts, {:ok, env}, fn segment, {:ok, env} ->
      case semantic_expr(segment, env, mode, core, manifest) do
        {:ok, _env} -> {:cont, {:ok, env}}
        error -> {:halt, error}
      end
    end)
  end

  defp semantic_segment_size(:default, env, _mode, _core, _manifest), do: {:ok, env}

  defp semantic_segment_size(size, env, mode, core, manifest),
    do: semantic_expr(size, env, mode, core, manifest)

  defp semantic_bit_segment_patterns(parts, env, core, manifest) do
    Enum.reduce_while(parts, {:ok, env}, fn
      %{node: :bit_segment, expr: expr, size: size}, {:ok, env} ->
        with {:ok, _env} <- semantic_segment_size(size, env, :expr, core, manifest),
             :ok <- semantic_pattern_keys(expr, env, core, manifest) do
          {:cont, {:ok, bind_pattern(env, expr)}}
        else
          error -> {:halt, error}
        end

      _segment, {:ok, _env} ->
        {:halt, {:error, Hyperlang.Error.new(:verify, "invalid bit syntax segment")}}
    end)
    |> case do
      {:ok, _env} -> :ok
      error -> error
    end
  end

  defp semantic_clauses(clauses, env, core, manifest) do
    Enum.reduce_while(clauses, :ok, fn clause, :ok ->
      with {:ok, clause_env} <- semantic_clause_patterns(clause.patterns, env, core, manifest),
           {:ok, _env} <- semantic_expr(clause.guard, clause_env, :guard, core, manifest),
           {:ok, _env} <- semantic_expr(clause.body, clause_env, :expr, core, manifest) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp semantic_clause_patterns(patterns, env, core, manifest) do
    Enum.reduce_while(patterns, {:ok, env}, fn pattern, {:ok, env} ->
      case semantic_pattern_keys(pattern, env, core, manifest) do
        :ok -> {:cont, {:ok, bind_pattern(env, pattern)}}
        error -> {:halt, error}
      end
    end)
  end

  defp semantic_if_clauses(clauses, env, core, manifest) do
    Enum.reduce_while(clauses, :ok, fn clause, :ok ->
      with {:ok, _env} <- semantic_expr(clause.guard, env, :guard, core, manifest),
           {:ok, _env} <- semantic_expr(clause.body, env, :expr, core, manifest) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp semantic_qualifiers(quals, env, core, manifest) do
    Enum.reduce_while(quals, {:ok, env}, fn
      %{node: node, pattern: pattern, expr: expr}, {:ok, env}
      when node in [:generator, :b_generator] ->
        with {:ok, _env} <- semantic_expr(expr, env, :expr, core, manifest),
             :ok <- semantic_pattern_keys(pattern, env, core, manifest) do
          {:cont, {:ok, bind_pattern(env, pattern)}}
        else
          error -> {:halt, error}
        end

      %{node: :filter, expr: expr}, {:ok, env} ->
        case semantic_expr(expr, env, :expr, core, manifest) do
          {:ok, _env} -> {:cont, {:ok, env}}
          error -> {:halt, error}
        end
    end)
  end

  defp semantic_pattern_keys(%{node: :map_pattern, fields: fields}, env, core, manifest) do
    Enum.reduce_while(fields, :ok, fn field, :ok ->
      case semantic_expr(field.key, env, :expr, core, manifest) do
        {:ok, _env} -> step(semantic_pattern_keys(field.value, env, core, manifest))
        error -> {:halt, error}
      end
    end)
  end

  defp semantic_pattern_keys(%{node: :record_pattern, fields: fields}, env, core, manifest) do
    semantic_pattern_keys(Enum.map(fields, & &1.value), env, core, manifest)
  end

  defp semantic_pattern_keys(%{node: :literal_pattern, literal: literal}, env, core, manifest),
    do: semantic_pattern_keys(literal, env, core, manifest)

  defp semantic_pattern_keys(
         %{node: :alias_pattern, left: left, right: right},
         env,
         core,
         manifest
       ) do
    with :ok <- semantic_pattern_keys(left, env, core, manifest),
         do: semantic_pattern_keys(right, env, core, manifest)
  end

  defp semantic_pattern_keys(%{node: :alias, left: left, right: right}, env, core, manifest) do
    with :ok <- semantic_pattern_keys(left, env, core, manifest),
         do: semantic_pattern_keys(right, env, core, manifest)
  end

  defp semantic_pattern_keys(%{node: :tuple_pattern, items: items}, env, core, manifest),
    do: semantic_pattern_keys(items, env, core, manifest)

  defp semantic_pattern_keys(%{node: :list_pattern, items: items}, env, core, manifest),
    do: semantic_pattern_keys(items, env, core, manifest)

  defp semantic_pattern_keys(%{node: :cons_pattern, head: head, tail: tail}, env, core, manifest) do
    with :ok <- semantic_pattern_keys(head, env, core, manifest),
         do: semantic_pattern_keys(tail, env, core, manifest)
  end

  defp semantic_pattern_keys(%{node: :binary, parts: parts}, env, core, manifest),
    do: semantic_bit_segment_patterns(parts, env, core, manifest)

  defp semantic_pattern_keys(patterns, env, core, manifest) when is_list(patterns) do
    Enum.reduce_while(patterns, :ok, fn pattern, :ok ->
      step(semantic_pattern_keys(pattern, env, core, manifest))
    end)
  end

  defp semantic_pattern_keys(_pattern, _env, _core, _manifest), do: :ok

  defp bind_patterns(env, patterns) when is_list(patterns),
    do: Enum.reduce(patterns, env, &bind_pattern(&2, &1))

  defp bind_pattern(env, %{node: :var, name: name}), do: bind_name(env, name)
  defp bind_pattern(env, %{node: :var_pattern, name: name}), do: bind_name(env, name)
  defp bind_pattern(env, %{node: :wild_pattern}), do: env

  defp bind_pattern(env, %{node: :literal_pattern, literal: literal}),
    do: bind_pattern(env, literal)

  defp bind_pattern(env, %{node: :alias_pattern, left: left, right: right}),
    do: env |> bind_pattern(left) |> bind_pattern(right)

  defp bind_pattern(env, %{node: :alias, left: left, right: right}),
    do: env |> bind_pattern(left) |> bind_pattern(right)

  defp bind_pattern(env, %{node: :tuple, items: items}), do: bind_patterns(env, items)
  defp bind_pattern(env, %{node: :tuple_pattern, items: items}), do: bind_patterns(env, items)
  defp bind_pattern(env, %{node: :list, items: items}), do: bind_patterns(env, items)
  defp bind_pattern(env, %{node: :list_pattern, items: items}), do: bind_patterns(env, items)
  defp bind_pattern(env, %{node: :binary, parts: parts}), do: bind_patterns(env, parts)
  defp bind_pattern(env, %{node: :bit_segment, expr: expr}), do: bind_pattern(env, expr)

  defp bind_pattern(env, %{node: :cons, head: head, tail: tail}),
    do: env |> bind_pattern(head) |> bind_pattern(tail)

  defp bind_pattern(env, %{node: :cons_pattern, head: head, tail: tail}),
    do: env |> bind_pattern(head) |> bind_pattern(tail)

  defp bind_pattern(env, %{node: :map, fields: fields}) do
    Enum.reduce(fields, env, fn field, env -> bind_pattern(env, field.value) end)
  end

  defp bind_pattern(env, %{node: :map_pattern, fields: fields}) do
    Enum.reduce(fields, env, fn field, env -> bind_pattern(env, field.value) end)
  end

  defp bind_pattern(env, %{node: :record_pattern, fields: fields}) do
    Enum.reduce(fields, env, fn field, env -> bind_pattern(env, field.value) end)
  end

  defp bind_pattern(env, _pattern), do: env

  defp bind_name(env, "_"), do: env
  defp bind_name(env, name), do: MapSet.put(env, name)

  defp guard_error(message, details) do
    {:error,
     Hyperlang.Error.new(:verify, message,
       details:
         Map.new(details)
         |> Map.put_new(
           :hint,
           "Erlang if/case/function guards allow only guard-safe BIFs and operators"
         )
     )}
  end

  defp guard_bif?(function, arity, manifest) do
    arity in Map.get(@guard_bifs, function, []) and allowed_bif?(function, arity, manifest)
  end

  defp step(:ok), do: {:cont, :ok}
  defp step(error), do: {:halt, error}
end
