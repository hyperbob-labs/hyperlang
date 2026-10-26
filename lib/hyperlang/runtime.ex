defmodule Hyperlang.Runtime do
  @moduledoc false

  @runtime_limit_keys [
    :max_term_depth,
    :max_binary_bytes,
    :max_input_bytes,
    :max_output_bytes,
    :max_integer_bits,
    :max_tuple_size,
    :max_list_length,
    :max_map_size,
    :max_total_words,
    :max_stdout_bytes,
    :max_stdout_chunk_bytes,
    :max_stdout_chunks
  ]
  @runtime_term_keys [
    :allowed_atoms,
    :allow_atoms,
    :allow_tuples,
    :public,
    :atom_public,
    :tuple_public,
    :binary_public,
    :improper_list_public
  ]
  @re_handle_key :hyperlang_re_patterns
  @guest_process_dictionary_key :"$hyperlang_guest_process_dictionary"
  @guest_process_dictionary_namespaces_key :"$hyperlang_guest_process_dictionary_namespaces"
  @guest_process_dictionary_index_key :"$hyperlang_guest_process_dictionary_index"
  @guest_process_dictionary_dependency_index_key :"$hyperlang_guest_process_dictionary_dependencies"
  @guest_process_dictionary_value_tag :"$hyperlang_guest_process_dictionary_value"
  @guest_process_dictionary_frame_key :"$hyperlang_guest_process_dictionary_frame"
  @guest_process_dictionary_dependency_scan_count_key {__MODULE__,
                                                       :guest_dictionary_dependency_scan_count}
  @non_ascii_pattern_key {__MODULE__, :non_ascii_pattern}
  @non_ascii_bytes for byte <- 128..255, do: <<byte>>
  @fixed_no_arg_syscalls [:finit, :newns, :pipe]
  @fixed_one_int_arg_syscalls [
    :close,
    :dirread,
    :fd2path,
    :fildes,
    :fstat,
    :iounit
  ]
  @fixed_int_return_syscalls [
    :bind,
    :chdir,
    :close,
    :create,
    :dup,
    :export,
    :fildes,
    :finit,
    :fwstat,
    :iounit,
    :newns,
    :open,
    :pctl,
    :pwrite,
    :remove,
    :seek,
    :spawn,
    :stream,
    :werrstr,
    :write,
    :wstat
  ]
  @dir_binary_keys [
    <<"name">>,
    <<"uid">>,
    <<"gid">>,
    <<"muid">>
  ]
  @dir_int_keys [
    <<"mode">>,
    <<"atime">>,
    <<"mtime">>,
    <<"length">>,
    <<"dtype">>,
    <<"type">>,
    <<"dev">>
  ]
  @qid_int_keys [
    <<"path">>,
    <<"vers">>,
    <<"version">>,
    <<"type">>,
    <<"qtype">>
  ]
  @dir_known_keys MapSet.new(@dir_binary_keys ++ @dir_int_keys ++ [<<"qid">>])
  @qid_known_keys MapSet.new(@qid_int_keys)

  def new_context(token, runtime, slot_version) when is_map(runtime) do
    with ^token <- Map.get(runtime, :token),
         ^slot_version <- Map.get(runtime, :slot_version),
         {:ok, context} <- build_context_from_runtime(runtime) do
      {:ok, context}
    else
      {:error, error} -> {:error, error}
      _other -> {:error, %{category: :runtime, reason: :invalid_token}}
    end
  end

  def new_context(_token, _runtime, _slot_version),
    do: {:error, %{category: :runtime, reason: :invalid_token}}

  @doc false
  def build_context_template(runtime) when is_map(runtime) do
    with {:ok, context} <- build_context(runtime) do
      {:ok,
       %{
         context: context,
         token: Map.fetch!(runtime, :token),
         bindings: Map.fetch!(runtime, :bindings),
         manifest: Map.fetch!(runtime, :manifest),
         limits: Map.fetch!(runtime, :limits),
         terms: Map.fetch!(runtime, :terms),
         slot_module: Map.fetch!(runtime, :slot_module),
         stack_map: Map.fetch!(runtime, :stack_map),
         host_scope: Map.fetch!(runtime, :host_scope),
         filesystem: Map.get(runtime, :filesystem),
         table_service: Map.get(runtime, :table_service),
         slot_version: Map.get(runtime, :slot_version),
         source_module: Map.get(runtime, :source_module),
         source_snapshot_modules: Map.get(runtime, :source_snapshot_modules, %{}),
         errstr: Map.get(runtime, :errstr),
         atom_pool: Map.get(runtime, :atom_pool, %{}),
         atom_allowed: Map.get(runtime, :atom_allowed, MapSet.new()),
         atom_universe:
           Map.get(runtime, :atom_universe, Map.get(runtime.manifest, :atom_universe))
       }}
    end
  end

  def build_context_template(_runtime),
    do: {:error, %{category: :runtime, reason: :invalid_runtime}}

  defp build_context_from_runtime(%{context_template: template} = runtime) do
    if context_template_matches_runtime?(template, runtime) do
      build_context_from_template(template, runtime)
    else
      build_context(runtime)
    end
  end

  defp build_context_from_runtime(runtime), do: build_context(runtime)

  defp context_template_matches_runtime?(
         %{
           token: token,
           bindings: bindings,
           manifest: manifest,
           limits: limits,
           terms: terms,
           slot_module: slot_module,
           stack_map: stack_map,
           host_scope: host_scope,
           filesystem: filesystem,
           table_service: table_service,
           slot_version: slot_version,
           source_module: source_module,
           source_snapshot_modules: source_snapshot_modules,
           errstr: errstr,
           atom_pool: atom_pool,
           atom_allowed: atom_allowed,
           atom_universe: atom_universe
         },
         runtime
       ) do
    token === Map.get(runtime, :token) and
      bindings === Map.get(runtime, :bindings) and
      manifest === Map.get(runtime, :manifest) and
      limits === Map.get(runtime, :limits) and
      terms === Map.get(runtime, :terms) and
      slot_module === Map.get(runtime, :slot_module) and
      stack_map === Map.get(runtime, :stack_map) and
      host_scope === Map.get(runtime, :host_scope) and
      filesystem === Map.get(runtime, :filesystem) and
      table_service === Map.get(runtime, :table_service) and
      slot_version === Map.get(runtime, :slot_version) and
      source_module === Map.get(runtime, :source_module) and
      source_snapshot_modules === Map.get(runtime, :source_snapshot_modules, %{}) and
      errstr === Map.get(runtime, :errstr) and
      atom_pool === Map.get(runtime, :atom_pool, %{}) and
      atom_allowed === Map.get(runtime, :atom_allowed, MapSet.new()) and
      atom_universe === Map.get(runtime, :atom_universe, Map.get(manifest, :atom_universe))
  end

  defp context_template_matches_runtime?(_template, _runtime), do: false

  defp build_context_from_template(%{context: context}, runtime) do
    with :ok <- validate_opaque_state(Map.get(runtime, :opaque_state)) do
      host = Hyperlang.SyscallHost.normalize(Map.get(runtime, :syscall), context.host_scope)
      guest_dictionary_frame_id = current_guest_dictionary_frame_id()

      {:ok,
       %{
         context
         | syscall: Map.get(runtime, :syscall),
           host: host,
           host_opaque_spawn_args?: opaque_host_spawn_args?(host),
           call_id: Map.get(runtime, :call_id),
           errstr: Map.get(runtime, :errstr),
           guest_dictionary_frame_id: guest_dictionary_frame_id,
           guest_dictionary_namespace: guest_dictionary_frame_id,
           loader_modules: Map.get(runtime, :loader_modules, %{}),
           callback_runtime: Map.get(runtime, :callback_runtime),
           module_entry: Map.get(runtime, :module_entry, false),
           opaque_entry_args: Map.get(runtime, :opaque_entry_args, false),
           opaque_state: Map.get(runtime, :opaque_state)
       }}
    else
      :error -> {:error, %{category: :runtime, reason: :invalid_runtime}}
    end
  end

  defp build_context_from_template(_template, _runtime),
    do: {:error, %{category: :runtime, reason: :invalid_runtime}}

  defp build_context(
         %{
           token: token,
           bindings: bindings,
           manifest: manifest,
           limits: limits,
           terms: terms,
           slot_module: slot_module,
           stack_map: stack_map,
           host_scope: host_scope
         } = runtime
       ) do
    with :ok <- validate_runtime_shape(runtime, limits, terms) do
      atom_universe = Map.get(runtime, :atom_universe, Map.get(manifest, :atom_universe))
      host = Hyperlang.SyscallHost.normalize(Map.get(runtime, :syscall), host_scope)

      guest_dictionary_frame_id = current_guest_dictionary_frame_id()
      source_module = Map.get(runtime, :source_module)

      context = %{
        token: token,
        bindings: bindings,
        manifest: manifest,
        limits: limits,
        terms:
          terms
          |> Map.put(:atom_pool, Map.get(runtime, :atom_pool, %{}))
          |> Map.put(:atom_universe, atom_universe),
        atom_pool: Map.get(runtime, :atom_pool, %{}),
        atom_allowed: Map.get(runtime, :atom_allowed, MapSet.new()),
        atom_universe: atom_universe,
        slot_module: slot_module,
        stack_map: stack_map,
        host_scope: host_scope,
        filesystem: Map.get(runtime, :filesystem),
        table_service: Map.get(runtime, :table_service),
        syscall: Map.get(runtime, :syscall),
        slot_version: Map.get(runtime, :slot_version),
        source_module: source_module,
        guest_dictionary_frame_id: guest_dictionary_frame_id,
        guest_dictionary_namespace: guest_dictionary_frame_id,
        host: host,
        host_opaque_spawn_args?: opaque_host_spawn_args?(host),
        call_id: Map.get(runtime, :call_id),
        errstr: Map.get(runtime, :errstr),
        source_snapshot_modules: Map.get(runtime, :source_snapshot_modules, %{}),
        loader_modules: Map.get(runtime, :loader_modules, %{}),
        callback_runtime: Map.get(runtime, :callback_runtime),
        module_entry: Map.get(runtime, :module_entry, false),
        opaque_entry_args: Map.get(runtime, :opaque_entry_args, false),
        # Terms.Opaque opaque round-trip directive for long-lived serving hosts.
        # Names the return State slot; absent => no fast path.
        # See Hyperlang.Terms.Opaque.
        opaque_state: Map.get(runtime, :opaque_state)
      }

      {:ok, Hyperlang.Terms.stamp_prevalidated_runtime(context)}
    end
  end

  defp build_context(_runtime), do: {:error, %{category: :runtime, reason: :invalid_runtime}}

  defp opaque_host_spawn_args?({module, state}) when is_atom(module) do
    if :erlang.function_exported(module, :opaque_spawn_args?, 1) do
      module.opaque_spawn_args?(state) == true
    else
      false
    end
  rescue
    _ -> false
  end

  defp opaque_host_spawn_args?(_host), do: false

  defp validate_runtime_shape(runtime, limits, terms) do
    with :ok <- require_integer_map_keys(limits, @runtime_limit_keys),
         :ok <- require_term_policy(terms),
         :ok <- validate_opaque_state(Map.get(runtime, :opaque_state)),
         :ok <- validate_runtime_terms(runtime) do
      :ok
    else
      :error -> {:error, %{category: :runtime, reason: :invalid_runtime}}
    end
  end

  defp require_integer_map_keys(map, keys) when is_map(map) do
    if Enum.all?(keys, fn key -> is_integer(Map.get(map, key)) end), do: :ok, else: :error
  end

  defp require_integer_map_keys(_map, _keys), do: :error

  defp require_term_policy(%{} = terms) do
    cond do
      not Enum.all?(@runtime_term_keys, &Map.has_key?(terms, &1)) ->
        :error

      not match?(%MapSet{}, Map.get(terms, :allowed_atoms)) ->
        :error

      Map.get(terms, :allow_atoms) not in [true, false] ->
        :error

      Map.get(terms, :allow_tuples) not in [true, false] ->
        :error

      Map.get(terms, :public) not in [:json, :erlang] ->
        :error

      Map.get(terms, :atom_public) not in [:atom, :binary] ->
        :error

      Map.get(terms, :tuple_public) not in [:tuple, :list] ->
        :error

      Map.get(terms, :binary_public) not in [:binary, :base64] ->
        :error

      Map.get(terms, :improper_list_public) != :reject ->
        :error

      true ->
        :ok
    end
  end

  defp require_term_policy(_terms), do: :error

  defp validate_opaque_state(nil), do: :ok

  defp validate_opaque_state(%{return_state: index})
       when is_integer(index) and index >= 0,
       do: :ok

  defp validate_opaque_state(_opaque_state), do: :error

  defp validate_runtime_terms(runtime) do
    Hyperlang.Terms.validate_runtime(runtime)
    :ok
  rescue
    ArgumentError -> :error
    KeyError -> :error
  end

  def export_args(ctx, export_id, args) when is_binary(export_id) and is_list(args) do
    with {:ok, export} <- fetch_export(ctx, export_id),
         :ok <- require_export_arity(export, args),
         {:ok, safe_args} <- sanitize_entry_args(ctx, args) do
      {:ok, safe_args}
    end
  end

  def export_args(_ctx, export_id, _args) when not is_binary(export_id),
    do: {:error, %{category: :export, reason: :invalid_export_id}}

  def export_args(_ctx, _export_id, _args),
    do: {:error, %{category: :export, reason: :invalid_export_args}}

  def entry_input(ctx, input), do: sanitize_entry_args(ctx, input)

  # Internal kernel launches, such as a host scheduler's spawn, may feed an export
  # with the exact args that just crossed and passed the syscall boundary.
  # External host callers never set this flag.
  defp sanitize_entry_args(%{opaque_entry_args: true}, args), do: {:ok, args}

  # ModuleLoader has already applied the caller -> callee boundary and source
  # atom translation before invoking a library export.
  defp sanitize_entry_args(%{module_entry: true}, args), do: {:ok, args}

  defp sanitize_entry_args(ctx, args), do: Hyperlang.Terms.sanitize_input(args, ctx)

  def safe_export(ctx, fun) when is_function(fun, 0) do
    reply =
      try do
        fun.()
      rescue
        _e in UndefinedFunctionError ->
          {:error, trim_error(:error, :undef, __STACKTRACE__, ctx)}

        e in MatchError ->
          {:error,
           trim_error(
             :error,
             {:badmatch, Map.get(e, :term, :badmatch)},
             __STACKTRACE__,
             ctx
           )}

        e in ErlangError ->
          {:error, trim_error(:error, Map.get(e, :original, e), __STACKTRACE__, ctx)}

        e ->
          {:error,
           trim_error(
             :error,
             {:exception, e.__struct__},
             __STACKTRACE__,
             ctx
           )
           |> Map.put(:exception, e.__struct__)}
      catch
        :throw, {:hyperlang_scope_busy, _} = fault ->
          throw(fault)

        :throw, {:hyperlang_exits, _status} = exits ->
          # E2: sys:exits/1 ends the eval from any
          # depth — one trust domain per program. The signal passes through
          # every export/module-call boundary untouched and is finished by
          # the worker's top-level handler.
          throw(exits)

        class, reason ->
          {:error, trim_error(class, reason, __STACKTRACE__, ctx)}
      end

    Hyperlang.Terms.sanitize_reply(reply, ctx, fn sanitized, _envelope -> sanitized end)
  end

  def import(ctx, import_name, args) do
    meta = Hyperlang.Manifest.binding_for_call(ctx.manifest, import_name)

    if meta == nil do
      :erlang.error({:sandbox, :unknown_import, import_name})
    else
      {module, state} = Map.fetch!(ctx.bindings, meta.binding)

      with {:ok, safe_args} <- Hyperlang.Terms.sanitize_import_args(args, ctx, meta),
           {:ok, value} <- invoke_binding(module, state, meta.function, safe_args),
           {:ok, safe_value} <- Hyperlang.Terms.sanitize_import_return(value, ctx, meta) do
        safe_value
      else
        {:error, reason} -> :erlang.error({:sandbox, :import_error, meta.call, reason})
      end
    end
  end

  def trim_error(class, reason, stack, runtime_or_ctx \\ nil) do
    %{
      category: error_category(reason),
      class: class,
      reason: error_reason(reason, runtime_or_ctx),
      stack: trim_stack(stack, stack_map(runtime_or_ctx))
    }
    |> maybe_put(:details, error_details(reason))
  end

  def exec_lowering_args(ctx, target, argv, opts, include_opts?) when is_boolean(include_opts?) do
    with {:ok, safe_args} <- sanitize_exec_args(ctx, target, argv, opts, include_opts?),
         {:ok, host_args} <- normalize_exec_lowering_args(ctx, safe_args, include_opts?) do
      case host_args do
        [path, argv] -> {:ok, {path, argv, %{}}}
        [path, argv, opts] -> {:ok, {path, argv, opts}}
      end
    end
  end

  def scope(ctx), do: ctx.host_scope

  def filesystem(ctx, operation, args) when is_atom(operation) and is_list(args) do
    with {:ok, safe_args} <- Hyperlang.Terms.sanitize_filesystem_args(args, ctx),
         {:ok, value} <- dispatch_filesystem(ctx, operation, safe_args),
         {:ok, safe_value} <- Hyperlang.Terms.sanitize_filesystem_return(value, ctx) do
      safe_value
    else
      {:error, reason} -> :erlang.error({:sandbox, :filesystem_error, reason})
    end
  end

  # Sanitizing syscall entry: syscall arguments are host-visible payloads and
  # cross the filesystem/syscall boundary here before the host sees them.
  def syscall(ctx, operation, args) when is_atom(operation) and is_list(args) do
    with {:ok, safe_args} <- sanitize_syscall_args(ctx, operation, args),
         {:ok, host_args} <- normalize_syscall_args(ctx, operation, safe_args),
         {:ok, value} <- host_call(ctx, operation, host_args) do
      with {:ok, safe_value} <- sanitize_syscall_return(operation, value, ctx) do
        {:ok, safe_value}
      end
    end
  end

  defp sanitize_syscall_args(%{host_opaque_spawn_args?: true} = ctx, :spawn, [target, argv])
       when is_list(argv) do
    opaque_spawn_args(ctx, target, argv, %{}, false)
  end

  defp sanitize_syscall_args(ctx, :spawn, [target, argv]) when is_list(argv) do
    sanitize_spawn_args(ctx, target, argv, %{}, false)
  end

  defp sanitize_syscall_args(
         %{host_opaque_spawn_args?: true} = ctx,
         :spawn,
         [target, argv, opts]
       )
       when is_list(argv) do
    opaque_spawn_args(ctx, target, argv, opts, true)
  end

  defp sanitize_syscall_args(ctx, :spawn, [target, argv, opts]) when is_list(argv) do
    sanitize_spawn_args(ctx, target, argv, opts, true)
  end

  defp sanitize_syscall_args(ctx, operation, args) do
    case sanitize_fixed_syscall_args(ctx, operation, args) do
      {:ok, safe_args} -> {:ok, safe_args}
      {:error, reason} -> {:error, reason}
      :fallback -> Hyperlang.Terms.sanitize_filesystem_args(args, ctx)
    end
  end

  defp sanitize_fixed_syscall_args(ctx, operation, [])
       when operation in @fixed_no_arg_syscalls do
    fixed_list_ok(ctx, [], 0, 0, :filesystem_args)
  end

  defp sanitize_fixed_syscall_args(ctx, operation, [value])
       when operation in @fixed_one_int_arg_syscalls do
    with {:ok, value} <- safe_sys_int(ctx, value, :filesystem_args) do
      fixed_list_ok(ctx, [value], 1, 1, :filesystem_args)
    end
  end

  defp sanitize_fixed_syscall_args(ctx, operation, [path])
       when operation in [:chdir, :remove, :stat] do
    with {:ok, path} <- safe_sys_binary(ctx, path, :filesystem_args) do
      fixed_list_ok(ctx, [path], 1, 1, :filesystem_args)
    end
  end

  defp sanitize_fixed_syscall_args(ctx, :open, [path, mode]) do
    with {:ok, path} <- safe_sys_binary(ctx, path, :filesystem_args),
         {:ok, mode} <- safe_sys_int(ctx, mode, :filesystem_args) do
      fixed_list_ok(ctx, [path, mode], 2, 2, :filesystem_args)
    end
  end

  defp sanitize_fixed_syscall_args(ctx, :create, [path, mode, perm]) do
    with {:ok, path} <- safe_sys_binary(ctx, path, :filesystem_args),
         {:ok, mode} <- safe_sys_int(ctx, mode, :filesystem_args),
         {:ok, perm} <- safe_sys_int(ctx, perm, :filesystem_args) do
      fixed_list_ok(ctx, [path, mode, perm], 3, 3, :filesystem_args)
    end
  end

  defp sanitize_fixed_syscall_args(ctx, operation, [fd, buf, count])
       when operation in [:read, :write] do
    with {:ok, fd} <- safe_sys_int(ctx, fd, :filesystem_args),
         {:ok, buf} <- safe_sys_binary(ctx, buf, :filesystem_args),
         {:ok, count} <- safe_sys_int(ctx, count, :filesystem_args) do
      fixed_list_ok(ctx, [fd, buf, count], 3, 3, :filesystem_args)
    end
  end

  defp sanitize_fixed_syscall_args(ctx, operation, [fd, buf, count, offset])
       when operation in [:pread, :pwrite] do
    with {:ok, fd} <- safe_sys_int(ctx, fd, :filesystem_args),
         {:ok, buf} <- safe_sys_binary(ctx, buf, :filesystem_args),
         {:ok, count} <- safe_sys_int(ctx, count, :filesystem_args),
         {:ok, offset} <- safe_sys_int(ctx, offset, :filesystem_args) do
      fixed_list_ok(ctx, [fd, buf, count, offset], 4, 4, :filesystem_args)
    end
  end

  defp sanitize_fixed_syscall_args(ctx, :bind, [source, target, flags]) do
    with {:ok, source} <- safe_sys_binary(ctx, source, :filesystem_args),
         {:ok, target} <- safe_sys_binary(ctx, target, :filesystem_args),
         {:ok, flags} <- safe_sys_int(ctx, flags, :filesystem_args) do
      fixed_list_ok(ctx, [source, target, flags], 3, 3, :filesystem_args)
    end
  end

  defp sanitize_fixed_syscall_args(ctx, operation, [a, b])
       when operation in [:dup] do
    with {:ok, a} <- safe_sys_int(ctx, a, :filesystem_args),
         {:ok, b} <- safe_sys_int(ctx, b, :filesystem_args) do
      fixed_list_ok(ctx, [a, b], 2, 2, :filesystem_args)
    end
  end

  defp sanitize_fixed_syscall_args(ctx, operation, [a, b, c])
       when operation in [:seek, :stream] do
    with {:ok, a} <- safe_sys_int(ctx, a, :filesystem_args),
         {:ok, b} <- safe_sys_int(ctx, b, :filesystem_args),
         {:ok, c} <- safe_sys_int(ctx, c, :filesystem_args) do
      fixed_list_ok(ctx, [a, b, c], 3, 3, :filesystem_args)
    end
  end

  defp sanitize_fixed_syscall_args(ctx, operation, [fd, path])
       when operation in [:fauth, :unmount] do
    with {:ok, fd} <- safe_sys_int_or_binary_or_nil(ctx, fd, :filesystem_args),
         {:ok, path} <- safe_sys_binary(ctx, path, :filesystem_args) do
      fixed_list_ok(ctx, [fd, path], 2, 2, :filesystem_args)
    end
  end

  defp sanitize_fixed_syscall_args(ctx, :fwstat, [fd, dir]) do
    with {:ok, fd} <- safe_sys_int(ctx, fd, :filesystem_args),
         {:ok, dir, dir_words} <- safe_dir_map(ctx, dir, :filesystem_args) do
      fixed_list_ok(ctx, [fd, dir], 2, 2 + dir_words, :filesystem_args)
    end
  end

  defp sanitize_fixed_syscall_args(ctx, :wstat, [path, dir]) do
    with {:ok, path} <- safe_sys_binary(ctx, path, :filesystem_args),
         {:ok, dir, dir_words} <- safe_dir_map(ctx, dir, :filesystem_args) do
      fixed_list_ok(ctx, [path, dir], 2, 2 + dir_words, :filesystem_args)
    end
  end

  defp sanitize_fixed_syscall_args(ctx, :export, [fd, dir, flag]) do
    with {:ok, fd} <- safe_sys_int(ctx, fd, :filesystem_args),
         {:ok, dir} <- safe_sys_binary(ctx, dir, :filesystem_args),
         {:ok, flag} <- safe_sys_int(ctx, flag, :filesystem_args) do
      fixed_list_ok(ctx, [fd, dir, flag], 3, 3, :filesystem_args)
    end
  end

  defp sanitize_fixed_syscall_args(ctx, :mount, [fd, afd, target, flags, spec]) do
    with {:ok, fd} <- safe_sys_int(ctx, fd, :filesystem_args),
         {:ok, afd} <- safe_sys_int_or_nil(ctx, afd, :filesystem_args),
         {:ok, target} <- safe_sys_binary(ctx, target, :filesystem_args),
         {:ok, flags} <- safe_sys_int(ctx, flags, :filesystem_args),
         {:ok, spec} <- safe_sys_binary(ctx, spec, :filesystem_args) do
      fixed_list_ok(
        ctx,
        [fd, afd, target, flags, spec],
        5,
        5,
        :filesystem_args
      )
    end
  end

  defp sanitize_fixed_syscall_args(ctx, :pctl, [flags, movefd]) do
    with {:ok, flags} <- safe_sys_int(ctx, flags, :filesystem_args),
         {:ok, movefd, words} <- safe_sys_int_list_or_nil(ctx, movefd, :filesystem_args) do
      fixed_list_ok(ctx, [flags, movefd], 2, 2 + words, :filesystem_args)
    end
  end

  defp sanitize_fixed_syscall_args(ctx, :postnote, [who, pid, note]) do
    with {:ok, who} <- safe_sys_int(ctx, who, :filesystem_args),
         {:ok, pid} <- safe_sys_int(ctx, pid, :filesystem_args),
         {:ok, note} <- safe_sys_binary(ctx, note, :filesystem_args) do
      fixed_list_ok(ctx, [who, pid, note], 3, 3, :filesystem_args)
    end
  end

  defp sanitize_fixed_syscall_args(ctx, :werrstr, [message]) do
    with {:ok, message} <- safe_sys_binary(ctx, message, :filesystem_args) do
      fixed_list_ok(ctx, [message], 1, 1, :filesystem_args)
    end
  end

  defp sanitize_fixed_syscall_args(_ctx, _operation, _args), do: :fallback

  defp opaque_spawn_args(ctx, target, argv, opts, include_opts?) do
    with {:ok, target} <- sanitize_syscall_name_arg(ctx, target),
         {:ok, argv} <- opaque_spawn_argv(ctx, argv),
         {:ok, opts} <- opaque_spawn_opts(ctx, opts) do
      if include_opts? do
        {:ok, [target, argv, opts]}
      else
        {:ok, [target, argv]}
      end
    end
  end

  defp opaque_spawn_argv(ctx, argv) do
    cond do
      not proper_list?(argv) ->
        {:error, %{category: :filesystem_args, reason: :improper_list}}

      length(argv) > ctx.limits.max_list_length ->
        {:error, %{category: :filesystem_args, reason: :list_length}}

      true ->
        {:ok, argv}
    end
  end

  defp opaque_spawn_opts(_ctx, %{} = opts) when map_size(opts) == 0, do: {:ok, opts}
  defp opaque_spawn_opts(_ctx, nil), do: {:ok, nil}
  defp opaque_spawn_opts(_ctx, []), do: {:ok, []}

  defp opaque_spawn_opts(ctx, opts) do
    with {:ok, [opts]} <- Hyperlang.Terms.sanitize_filesystem_args([opts], ctx) do
      {:ok, opts}
    end
  end

  defp sanitize_spawn_args(ctx, target, argv, opts, include_opts?) do
    with {:ok, target} <- sanitize_syscall_name_arg(ctx, target),
         {:ok, argv, argv_words} <- sanitize_exec_argv(ctx, argv),
         {:ok, opts, opts_words} <- sanitize_exec_opts(ctx, opts),
         {:ok, args} <- exec_args(target, argv, opts, include_opts?),
         {:ok, args} <-
           fixed_list_ok(
             ctx,
             args,
             length(args),
             length(args) + argv_words + opts_words,
             :filesystem_args
           ) do
      {:ok, args}
    end
  end

  defp sanitize_exec_args(ctx, target, argv, opts, include_opts?) do
    with {:ok, target} <- sanitize_syscall_name_arg(ctx, target),
         {:ok, argv, argv_words} <- sanitize_exec_argv(ctx, argv),
         {:ok, opts, opts_words} <- sanitize_exec_opts(ctx, opts),
         {:ok, args} <- exec_args(target, argv, opts, include_opts?),
         {:ok, args} <-
           fixed_list_ok(
             ctx,
             args,
             length(args),
             length(args) + argv_words + opts_words,
             :filesystem_args
           ) do
      {:ok, args}
    end
  end

  defp sanitize_exec_argv(ctx, argv) when is_list(argv) do
    cond do
      not proper_list?(argv) ->
        {:error, %{category: :filesystem_args, reason: :improper_list}}

      length(argv) > ctx.limits.max_list_length ->
        {:error, %{category: :filesystem_args, reason: :list_length}}

      true ->
        argv
        |> Enum.reduce_while({:ok, [], 0}, fn arg, {:ok, acc, words} ->
          case sanitize_syscall_name_arg(ctx, arg) do
            {:ok, arg} -> {:cont, {:ok, [arg | acc], words + 1}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, argv, words} -> {:ok, Enum.reverse(argv), words}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp sanitize_exec_argv(_ctx, _argv),
    do: {:error, %{category: :filesystem_args, reason: :improper_list}}

  defp sanitize_exec_opts(_ctx, %{} = opts) when map_size(opts) == 0, do: {:ok, opts, 0}
  defp sanitize_exec_opts(_ctx, nil), do: {:ok, nil, 0}
  defp sanitize_exec_opts(_ctx, []), do: {:ok, [], 0}

  defp sanitize_exec_opts(ctx, opts) do
    with {:ok, [opts]} <- Hyperlang.Terms.sanitize_filesystem_args([opts], ctx) do
      {:ok, opts, 1}
    end
  end

  defp exec_args(target, argv, _opts, false), do: {:ok, [target, argv]}
  defp exec_args(target, argv, opts, true), do: {:ok, [target, argv, opts]}

  defp sanitize_syscall_name_arg(ctx, value) when is_binary(value) do
    if byte_size(value) <= ctx.limits.max_binary_bytes do
      {:ok, value}
    else
      {:error, %{category: :filesystem_args, reason: :binary_bytes}}
    end
  end

  defp sanitize_syscall_name_arg(ctx, value) when is_atom(value) do
    cond do
      is_binary(source = mapped_atom_source(value, ctx)) ->
        bounded_syscall_name(source, ctx)

      MapSet.member?(ctx.terms.allowed_atoms, value) ->
        value
        |> Atom.to_string()
        |> bounded_syscall_name(ctx)

      true ->
        {:error, %{category: :filesystem_args, reason: {:atom_not_allowed, value}}}
    end
  end

  defp sanitize_syscall_name_arg(ctx, value) when is_list(value) do
    cond do
      not proper_list?(value) ->
        {:error, %{category: :filesystem_args, reason: :improper_list}}

      length(value) > ctx.limits.max_list_length ->
        {:error, %{category: :filesystem_args, reason: :list_length}}

      printable_charlist?(value) ->
        value
        |> IO.iodata_to_binary()
        |> bounded_syscall_name(ctx)

      true ->
        {:error, %{category: :filesystem_args, reason: :syscall_name}}
    end
  end

  defp sanitize_syscall_name_arg(_ctx, _value),
    do: {:error, %{category: :filesystem_args, reason: :syscall_name}}

  defp bounded_syscall_name(source, ctx) when is_binary(source) do
    if byte_size(source) <= ctx.limits.max_binary_bytes do
      {:ok, source}
    else
      {:error, %{category: :filesystem_args, reason: :binary_bytes}}
    end
  end

  defp fixed_list_ok(ctx, value, list_length, words, category) do
    with :ok <- check_fixed_list_length(ctx, list_length, category),
         :ok <- check_fixed_words(ctx, words, category) do
      {:ok, value}
    end
  end

  defp check_fixed_list_length(ctx, length, category) do
    if length <= ctx.limits.max_list_length do
      :ok
    else
      {:error, %{category: category, reason: :list_length}}
    end
  end

  defp check_fixed_words(ctx, words, category) do
    if words <= ctx.limits.max_total_words do
      :ok
    else
      {:error, %{category: category, reason: :total_words}}
    end
  end

  defp safe_sys_int(ctx, value, category) when is_integer(value) do
    if bounded_integer?(value, ctx.limits.max_integer_bits) do
      {:ok, value}
    else
      {:error, %{category: category, reason: :integer_bits}}
    end
  end

  defp safe_sys_int(_ctx, _value, _category), do: :fallback

  defp safe_sys_binary(ctx, value, category) when is_binary(value) do
    if byte_size(value) <= ctx.limits.max_binary_bytes do
      {:ok, value}
    else
      {:error, %{category: category, reason: :binary_bytes}}
    end
  end

  defp safe_sys_binary(_ctx, _value, _category), do: :fallback

  defp safe_sys_int_or_nil(_ctx, nil, _category), do: {:ok, nil}
  defp safe_sys_int_or_nil(ctx, value, category), do: safe_sys_int(ctx, value, category)

  defp safe_sys_int_or_binary_or_nil(_ctx, nil, _category), do: {:ok, nil}

  defp safe_sys_int_or_binary_or_nil(ctx, value, category) when is_integer(value),
    do: safe_sys_int(ctx, value, category)

  defp safe_sys_int_or_binary_or_nil(ctx, value, category) when is_binary(value),
    do: safe_sys_binary(ctx, value, category)

  defp safe_sys_int_or_binary_or_nil(_ctx, _value, _category), do: :fallback

  defp safe_sys_int_list_or_nil(_ctx, nil, _category), do: {:ok, nil, 0}

  defp safe_sys_int_list_or_nil(ctx, list, category) when is_list(list) do
    cond do
      not proper_list?(list) ->
        {:error, %{category: category, reason: :improper_list}}

      length(list) > ctx.limits.max_list_length ->
        {:error, %{category: category, reason: :list_length}}

      true ->
        list
        |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
          case safe_sys_int(ctx, value, category) do
            {:ok, value} -> {:cont, {:ok, [value | acc]}}
            :fallback -> {:halt, :fallback}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, acc} -> {:ok, Enum.reverse(acc), length(list)}
          other -> other
        end
    end
  end

  defp safe_sys_int_list_or_nil(_ctx, _value, _category), do: :fallback

  defp bounded_integer?(_value, max_bits) when max_bits < 1, do: false
  defp bounded_integer?(0, _max_bits), do: true

  defp bounded_integer?(value, max_bits) when is_integer(value) do
    integer_bits(value) <= max_bits
  end

  defp integer_bits(0), do: 1

  defp integer_bits(value) when is_integer(value) do
    bytes = value |> abs() |> :binary.encode_unsigned()
    <<first, _rest::binary>> = bytes
    byte_size(bytes) * 8 - leading_zero_bits(first)
  end

  defp leading_zero_bits(byte) when byte >= 128, do: 0
  defp leading_zero_bits(byte) when byte >= 64, do: 1
  defp leading_zero_bits(byte) when byte >= 32, do: 2
  defp leading_zero_bits(byte) when byte >= 16, do: 3
  defp leading_zero_bits(byte) when byte >= 8, do: 4
  defp leading_zero_bits(byte) when byte >= 4, do: 5
  defp leading_zero_bits(byte) when byte >= 2, do: 6
  defp leading_zero_bits(_byte), do: 7

  @sys_open_modes %{
    "read" => 0,
    "oread" => 0,
    "write" => 1,
    "owrite" => 1,
    "rdwr" => 2,
    "ordwr" => 2,
    "trunc" => 16,
    "otrunc" => 16,
    "cexec" => 32,
    "ocexec" => 32,
    "rclose" => 64,
    "orclose" => 64,
    "excl" => 0x1000,
    "oexcl" => 0x1000
  }

  @sys_mount_flags %{
    "repl" => 0,
    "mrepl" => 0,
    "before" => 1,
    "mbefore" => 1,
    "after" => 2,
    "mafter" => 2,
    "create" => 4,
    "mcreate" => 4,
    "cache" => 16,
    "mcache" => 16
  }

  @sys_pctl_flags %{
    "newfd" => 1,
    "forkfd" => 2,
    "newns" => 4,
    "rfcnameg" => 4,
    "forkns" => 8,
    ("new" <> "p" <> "grp") => 16,
    "nodevs" => 32,
    "newenv" => 64,
    "forkenv" => 128
  }

  @sys_seek_modes %{
    "start" => 0,
    "seekstart" => 0,
    "set" => 0,
    "relative" => 1,
    "rela" => 1,
    "seekrela" => 1,
    "current" => 1,
    "cur" => 1,
    "end" => 2,
    "seekend" => 2
  }

  @sys_note_targets %{
    "proc" => 1,
    "pnproc" => 1,
    "group" => 2,
    "pngroup" => 2
  }

  @sys_export_flags %{
    "wait" => 0,
    "expwait" => 0,
    "async" => 1,
    "expasync" => 1
  }

  defp normalize_syscall_args(ctx, :spawn, [target, argv, opts]),
    do: normalize_spawn(ctx, target, argv, opts)

  defp normalize_syscall_args(ctx, :spawn, [target, argv]),
    do: normalize_spawn(ctx, target, argv, %{})

  defp normalize_syscall_args(ctx, :open, [path, mode]) do
    with {:ok, mode} <- normalize_sys_flags(ctx, mode, @sys_open_modes) do
      {:ok, [path, mode]}
    end
  end

  defp normalize_syscall_args(ctx, :create, [path, mode, perm]) do
    with {:ok, mode} <- normalize_sys_flags(ctx, mode, @sys_open_modes) do
      {:ok, [path, mode, perm]}
    end
  end

  defp normalize_syscall_args(ctx, :bind, [source, target, flags]) do
    with {:ok, flags} <- normalize_sys_flags(ctx, flags, @sys_mount_flags) do
      {:ok, [source, target, flags]}
    end
  end

  defp normalize_syscall_args(ctx, :mount, [fd, afd, target, flags, spec]) do
    with {:ok, flags} <- normalize_sys_flags(ctx, flags, @sys_mount_flags) do
      {:ok, [fd, afd, target, flags, spec]}
    end
  end

  defp normalize_syscall_args(ctx, :pctl, [flags, movefd]) do
    with {:ok, flags} <- normalize_sys_flags(ctx, flags, @sys_pctl_flags) do
      {:ok, [flags, movefd]}
    end
  end

  defp normalize_syscall_args(ctx, :seek, [fd, off, whence]) do
    with {:ok, whence} <- normalize_sys_flags(ctx, whence, @sys_seek_modes) do
      {:ok, [fd, off, whence]}
    end
  end

  defp normalize_syscall_args(ctx, :postnote, [who, pid, note]) do
    with {:ok, who} <- normalize_sys_flags(ctx, who, @sys_note_targets) do
      {:ok, [who, pid, note]}
    end
  end

  defp normalize_syscall_args(ctx, :export, [fd, dir, flag]) do
    with {:ok, flag} <- normalize_sys_flags(ctx, flag, @sys_export_flags) do
      {:ok, [fd, dir, flag]}
    end
  end

  defp normalize_syscall_args(_ctx, _operation, args), do: {:ok, args}

  defp normalize_spawn(ctx, target, argv, opts) when is_list(argv) do
    with {:ok, target} <- syscall_name(ctx, target) do
      {:ok, [target, argv, opts]}
    end
  end

  defp normalize_spawn(_ctx, _target, _argv, _opts), do: {:error, :ebadarg}

  defp normalize_exec(ctx, target, argv, opts, include_opts?) when is_list(argv) do
    with {:ok, target} <- syscall_name(ctx, target) do
      if include_opts? do
        {:ok, [target, argv, opts]}
      else
        {:ok, [target, argv]}
      end
    end
  end

  defp normalize_exec(_ctx, _target, _argv, _opts, _include_opts?), do: {:error, :ebadarg}

  defp normalize_exec_lowering_args(ctx, [target, argv], false),
    do: normalize_exec(ctx, target, argv, %{}, false)

  defp normalize_exec_lowering_args(ctx, [target, argv, opts], true),
    do: normalize_exec(ctx, target, argv, opts, true)

  defp normalize_exec_lowering_args(_ctx, _args, _include_opts?), do: {:error, :ebadarg}

  defp normalize_sys_flags(_ctx, value, _table) when is_integer(value), do: {:ok, value}

  defp normalize_sys_flags(ctx, value, table) when is_list(value) do
    cond do
      value == [] ->
        {:ok, 0}

      printable_charlist?(value) ->
        normalize_sys_flags(ctx, IO.iodata_to_binary(value), table)

      proper_list?(value) ->
        Enum.reduce_while(value, {:ok, 0}, fn item, {:ok, acc} ->
          case normalize_sys_flags(ctx, item, table) do
            {:ok, value} -> {:cont, {:ok, Bitwise.bor(acc, value)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      true ->
        {:error, :ebadarg}
    end
  end

  defp normalize_sys_flags(ctx, value, table) do
    with {:ok, source} <- syscall_name_source(ctx, value),
         {:ok, flag} <- fetch_sys_flag(table, source) do
      {:ok, flag}
    end
  end

  defp fetch_sys_flag(table, source) do
    case Map.fetch(table, source) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :ebadarg}
    end
  end

  defp syscall_name(ctx, value) do
    with {:ok, source} <- syscall_name_source(ctx, value) do
      {:ok, IO.iodata_to_binary(source)}
    end
  end

  defp syscall_name_source(_ctx, value) when is_binary(value), do: {:ok, value}

  defp syscall_name_source(ctx, value) when is_atom(value),
    do: {:ok, atom_name(value, ctx)}

  defp syscall_name_source(_ctx, value) when is_list(value) do
    if printable_charlist?(value), do: {:ok, IO.iodata_to_binary(value)}, else: {:error, :ebadarg}
  end

  defp syscall_name_source(_ctx, _value), do: {:error, :ebadarg}

  defp sanitize_syscall_return(:file2chan, value, ctx) do
    ctx
    |> extend_atom_pool(%{read: "read", write: "write"})
    |> then(&Hyperlang.Terms.sanitize_filesystem_return(value, &1))
  end

  defp sanitize_syscall_return(operation, value, ctx)
       when operation in [:dial, :announce, :listen] do
    ctx
    |> extend_atom_pool(%{dfd: "dfd", cfd: "cfd", dir: "dir"})
    |> then(&Hyperlang.Terms.sanitize_filesystem_return(value, &1))
  end

  defp sanitize_syscall_return(operation, value, ctx) do
    case sanitize_fixed_syscall_return(ctx, operation, value) do
      {:ok, safe_value} -> {:ok, safe_value}
      {:error, reason} -> {:error, reason}
      :fallback -> Hyperlang.Terms.sanitize_filesystem_return(value, ctx)
    end
  end

  defp sanitize_fixed_syscall_return(ctx, operation, value)
       when operation in @fixed_int_return_syscalls do
    with {:ok, value} <- safe_sys_int_or_nil(ctx, value, :filesystem_return) do
      fixed_value_ok(ctx, value, 1, :filesystem_return)
    end
  end

  defp sanitize_fixed_syscall_return(ctx, operation, {count, data})
       when operation in [:read, :pread] do
    with {:ok, count} <- safe_sys_int(ctx, count, :filesystem_return),
         {:ok, data} <- safe_sys_binary(ctx, data, :filesystem_return) do
      fixed_value_ok(ctx, {count, data}, 3, :filesystem_return)
    end
  end

  defp sanitize_fixed_syscall_return(ctx, operation, {code, dir})
       when operation in [:stat, :fstat] do
    with {:ok, code} <- safe_sys_int(ctx, code, :filesystem_return),
         {:ok, dir, words} <- safe_dir_or_nil(ctx, dir, :filesystem_return) do
      fixed_value_ok(ctx, {code, dir}, 2 + words, :filesystem_return)
    end
  end

  defp sanitize_fixed_syscall_return(ctx, :dirread, {count, dirs}) when is_list(dirs) do
    with {:ok, count} <- safe_sys_int(ctx, count, :filesystem_return),
         {:ok, dirs, words} <- safe_dir_list(ctx, dirs, :filesystem_return) do
      fixed_value_ok(ctx, {count, dirs}, 2 + words, :filesystem_return)
    end
  end

  defp sanitize_fixed_syscall_return(ctx, :pipe, {code, [fd0, fd1]}) do
    with {:ok, code} <- safe_sys_int(ctx, code, :filesystem_return),
         {:ok, fd0} <- safe_sys_int(ctx, fd0, :filesystem_return),
         {:ok, fd1} <- safe_sys_int(ctx, fd1, :filesystem_return) do
      fixed_value_ok(ctx, {code, [fd0, fd1]}, 5, :filesystem_return)
    end
  end

  defp sanitize_fixed_syscall_return(ctx, :fd2path, value)
       when is_binary(value) or is_nil(value) do
    with {:ok, value} <- safe_sys_binary_or_nil(ctx, value, :filesystem_return) do
      fixed_value_ok(ctx, value, 1, :filesystem_return)
    end
  end

  defp sanitize_fixed_syscall_return(_ctx, _operation, _value), do: :fallback

  defp fixed_value_ok(ctx, value, words, category) do
    with :ok <- check_fixed_words(ctx, words, category) do
      {:ok, value}
    end
  end

  defp safe_sys_binary_or_nil(_ctx, nil, _category), do: {:ok, nil}
  defp safe_sys_binary_or_nil(ctx, value, category), do: safe_sys_binary(ctx, value, category)

  defp safe_dir_or_nil(_ctx, nil, _category), do: {:ok, nil, 1}

  defp safe_dir_or_nil(ctx, %{} = dir, category), do: safe_dir_map(ctx, dir, category)

  defp safe_dir_or_nil(_ctx, _dir, _category), do: :fallback

  defp safe_dir_list(ctx, dirs, category) do
    cond do
      not proper_list?(dirs) ->
        {:error, %{category: category, reason: :improper_list}}

      length(dirs) > ctx.limits.max_list_length ->
        {:error, %{category: category, reason: :list_length}}

      true ->
        dirs
        |> Enum.reduce_while({:ok, [], 0}, fn dir, {:ok, acc, words} ->
          case safe_dir_map(ctx, dir, category) do
            {:ok, dir, dir_words} -> {:cont, {:ok, [dir | acc], words + dir_words + 1}}
            :fallback -> {:halt, :fallback}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, acc, words} -> {:ok, Enum.reverse(acc), words}
          other -> other
        end
    end
  end

  defp safe_dir_map(ctx, dir, category) when is_map(dir) do
    cond do
      map_size(dir) > ctx.limits.max_map_size ->
        {:error, %{category: category, reason: :map_size}}

      not MapSet.subset?(MapSet.new(Map.keys(dir)), @dir_known_keys) ->
        :fallback

      true ->
        with {:ok, words} <-
               safe_dir_scalar_fields(ctx, dir, @dir_binary_keys, :binary, category, 0),
             {:ok, words} <-
               safe_dir_scalar_fields(ctx, dir, @dir_int_keys, :int, category, words),
             {:ok, words} <- safe_qid_field(ctx, Map.get(dir, <<"qid">>), category, words) do
          {:ok, dir, words}
        end
    end
  end

  defp safe_dir_map(_ctx, _dir, _category), do: :fallback

  defp safe_dir_scalar_fields(ctx, dir, keys, type, category, words) do
    Enum.reduce_while(keys, {:ok, words}, fn key, {:ok, words} ->
      case Map.fetch(dir, key) do
        :error ->
          {:cont, {:ok, words}}

        {:ok, value} ->
          check =
            case type do
              :binary -> safe_sys_binary(ctx, value, category)
              :int -> safe_sys_int(ctx, value, category)
            end

          case check do
            {:ok, _value} -> {:cont, {:ok, words + 2}}
            :fallback -> {:halt, :fallback}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp safe_qid_field(_ctx, nil, _category, words), do: {:ok, words}

  defp safe_qid_field(ctx, %{} = qid, category, words) do
    cond do
      map_size(qid) > ctx.limits.max_map_size ->
        {:error, %{category: category, reason: :map_size}}

      not MapSet.subset?(MapSet.new(Map.keys(qid)), @qid_known_keys) ->
        :fallback

      true ->
        safe_dir_scalar_fields(ctx, qid, @qid_int_keys, :int, category, words + 2)
    end
  end

  defp safe_qid_field(_ctx, _qid, _category, _words), do: :fallback

  defp extend_atom_pool(ctx, extra) when is_map(ctx) and is_map(extra) do
    pool =
      ctx
      |> Map.get(:atom_pool, Map.get(Map.get(ctx, :terms, %{}), :atom_pool, %{}))
      |> Map.merge(extra)

    terms =
      ctx
      |> Map.get(:terms, %{})
      |> Map.put(:atom_pool, pool)

    ctx
    |> Map.put(:atom_pool, pool)
    |> Map.put(:terms, terms)
  end

  def errstr(%{errstr: errstr}) when not is_nil(errstr), do: normalize_errstr_callback(errstr)

  def errstr(%{host: {module, state}}) when is_atom(module) do
    if :erlang.function_exported(module, :errstr, 1) do
      module.errstr(state)
      |> normalize_errstr_value()
    else
      ""
    end
  rescue
    _ -> ""
  catch
    _class, _reason -> ""
  end

  def errstr(_ctx), do: ""

  defp normalize_errstr_callback(fun) when is_function(fun, 0) do
    fun.()
    |> normalize_errstr_value()
  rescue
    _ -> ""
  catch
    _class, _reason -> ""
  end

  defp normalize_errstr_callback({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args) do
    apply(module, function, args)
    |> normalize_errstr_value()
  rescue
    _ -> ""
  catch
    _class, _reason -> ""
  end

  defp normalize_errstr_callback(_errstr), do: ""

  defp normalize_errstr_value(value) when is_binary(value), do: value
  defp normalize_errstr_value(value) when is_list(value), do: IO.iodata_to_binary(value)
  defp normalize_errstr_value(_value), do: ""

  # Raw door invoke: one static call into the bound SyscallHost module. Used
  # by callers that already sit inside a sanitized boundary (the file:/io:
  # mirror sanitizes at Runtime.filesystem entry/return), so the mirror pays
  # exactly one sanitize pass instead of two.
  def host_call(%{host: nil}, _operation, _args), do: {:error, :syscall_unavailable}

  def host_call(%{host: {module, state}}, operation, args) do
    normalize_syscall_reply(
      Hyperlang.Scope.blocking(fn -> module.syscall(state, operation, args) end)
    )
  rescue
    error -> {:error, {:syscall_exception, error.__struct__}}
  catch
    :throw, {:hyperlang_scope_busy, _} = fault -> throw(fault)
    class, reason -> {:error, {:syscall_exit, class, reason}}
  end

  def host_call(_ctx, _operation, _args), do: {:error, :syscall_unavailable}

  defp normalize_syscall_reply({:hyperlang_syscall_error, reason}), do: {:error, reason}
  defp normalize_syscall_reply(value), do: {:ok, value}

  def module_call(ctx, module, function, args)
      when is_binary(module) and is_binary(function) and is_list(args) do
    Hyperlang.ModuleLoader.call(ctx, module, function, args)
  end

  def behaviour_callback(ctx, module, function, args)
      when (is_atom(module) or is_binary(module)) and is_binary(function) and is_list(args) do
    arity = length(args)

    with :ok <- behaviour_callback_allowed(ctx, function, arity),
         {:ok, module_name} <- callback_module_name(module, ctx),
         {:ok, callback_runtime} <- callback_runtime(ctx, module_name),
         :ok <- callback_exported(callback_runtime, function, arity),
         {:ok, callback_args} <- sanitize_callback_args(ctx, callback_runtime, args),
         {:ok, result} <-
           Hyperlang.ModuleLoader.with_callback_binding(ctx, fn ->
             invoke_behaviour_callback(callback_runtime, function, callback_args)
           end),
         {:ok, callback_result} <- sanitize_callback_return(ctx, callback_runtime, result) do
      callback_result
    else
      {:error, reason} -> :erlang.error({:sandbox, :behaviour_callback_error, reason})
    end
  end

  def behaviour_callback(_ctx, _module, _function, _args),
    do: :erlang.error({:sandbox, :behaviour_callback_error, :badarg})

  def loader(ctx, operation, args) when is_atom(operation) and is_list(args) do
    with {:ok, safe_args} <- Hyperlang.Terms.sanitize(args, ctx, :loader_args),
         {:ok, value} <- Hyperlang.Loader.dispatch(ctx, operation, safe_args),
         {:ok, safe_value} <- Hyperlang.Terms.sanitize(value, ctx, :loader_return) do
      safe_value
    else
      {:error, reason} -> :erlang.error({:sandbox, :loader_error, reason})
    end
  end

  # The `code:` discovery surface. `Hyperlang.Code`
  # owns argument translation and the `:docs` sanitize boundary, so this is
  # a plain delegation.
  def code(ctx, operation, args) when is_atom(operation) and is_list(args) do
    Hyperlang.Code.dispatch(ctx, operation, args)
  end

  def stdlib(ctx, module, function, args)
      when is_atom(module) and is_atom(function) and is_list(args) do
    arity = length(args)

    with {:ok, behaviour, callback_args, profile, nondeterministic?} <-
           Hyperlang.Stdlib.runtime_spec(module, function, arity),
         true <-
           stdlib_profile_allowed?(ctx, profile, nondeterministic?) or
             opaque_gen_server_clock?(ctx, module, function, arity),
         :ok <- validate_stdlib_behaviour(ctx, behaviour, callback_args, args),
         {:ok, safe_args} <- Hyperlang.Terms.sanitize_stdlib_args(args, ctx),
         value <- apply_stdlib(ctx, module, function, safe_args),
         {:ok, safe_value} <- Hyperlang.Terms.sanitize_stdlib_return(value, ctx) do
      safe_value
    else
      :error -> :erlang.error({:sandbox, :stdlib_error, module, function, :forbidden_stdlib_call})
      false -> :erlang.error({:sandbox, :stdlib_error, module, function, :forbidden_stdlib_call})
      {:error, reason} -> :erlang.error({:sandbox, :stdlib_error, module, function, reason})
    end
  end

  defp behaviour_callback_allowed(_ctx, _function, _arity), do: :ok

  defp callback_module_name(module, ctx) when is_atom(module), do: safe_atom_name(module, ctx)
  defp callback_module_name(module, _ctx) when is_binary(module), do: {:ok, module}

  defp callback_runtime(
         %{callback_runtime: %{source_module: source_module} = runtime},
         module_name
       )
       when source_module == module_name,
       do: {:ok, runtime}

  defp callback_runtime(_ctx, _module_name), do: {:error, :unknown_callback_module}

  defp callback_exported(runtime, function, arity) do
    export_id = function <> "/" <> Integer.to_string(arity)

    case fetch_export(runtime, export_id) do
      {:ok, _export} -> :ok
      {:error, _reason} -> {:error, :undef}
    end
  end

  defp sanitize_callback_args(library_ctx, callback_runtime, args),
    do: Hyperlang.Terms.sanitize_module_return(args, callback_runtime, library_ctx)

  defp sanitize_callback_return(library_ctx, callback_runtime, result),
    do: Hyperlang.Terms.sanitize_module_return(result, library_ctx, callback_runtime)

  defp invoke_behaviour_callback(runtime, function, args) do
    export_id = function <> "/" <> Integer.to_string(length(args))

    case apply(runtime.slot_module, :"$safe_export", [runtime.token, export_id, args, runtime]) do
      {:ok, %{result: result}} -> {:ok, result}
      {:error, %{reason: :undef}} -> {:error, :undef}
      {:error, %{details: %{"reason" => "undef"}}} -> {:error, :undef}
      {:error, reason} -> {:error, {:callback_error, reason}}
      other -> {:ok, other}
    end
  end

  defp opaque_gen_server_clock?(
         %{manifest: %{capabilities: %{gen_server: true}}},
         :erlang,
         :monotonic_time,
         1
       ),
       do: true

  defp opaque_gen_server_clock?(_ctx, _module, _function, _arity), do: false

  def dynamic_apply_stdlib(ctx, module, function, args)
      when is_atom(module) and is_atom(function) and is_list(args) do
    module_source = mapped_atom_source(module, ctx) || Atom.to_string(module)
    function_source = mapped_atom_source(function, ctx) || Atom.to_string(function)

    with module_source when is_binary(module_source) <- module_source,
         function_source when is_binary(function_source) <- function_source,
         {:ok, module_atom} <- existing_atom(module_source),
         {:ok, function_atom} <- existing_atom(function_source),
         {:ok, _behaviour, _callback_args, _profile, _nondeterministic?} <-
           Hyperlang.Stdlib.runtime_spec(module_atom, function_atom, length(args)) do
      stdlib(ctx, module_atom, function_atom, args)
    else
      _ -> :erlang.error(:undef)
    end
  end

  def dynamic_apply_stdlib(_ctx, module, function, args) do
    if is_atom(module) and is_atom(function) and is_list(args),
      do: :erlang.error(:undef),
      else: :erlang.error(:badarg)
  end

  defp existing_atom(source) do
    {:ok, String.to_existing_atom(source)}
  rescue
    ArgumentError -> :error
  end

  @doc false
  def binary_copy(ctx, binary) do
    case safe_binary_copy(ctx, [binary]) do
      {:ok, value} ->
        value

      {:error, reason} ->
        :erlang.error({:sandbox, :stdlib_error, :binary, :copy, stdlib_return_error(reason)})
    end
  end

  @doc false
  def binary_copy(ctx, binary, count) do
    case safe_binary_copy(ctx, [binary, count]) do
      {:ok, value} ->
        value

      {:error, reason} ->
        :erlang.error({:sandbox, :stdlib_error, :binary, :copy, stdlib_return_error(reason)})
    end
  end

  @doc false
  def binary_split(ctx, binary, pattern) do
    case safe_binary_list_result(ctx, :split, [binary, pattern]) do
      {:ok, value} ->
        value

      {:error, reason} ->
        :erlang.error({:sandbox, :stdlib_error, :binary, :split, stdlib_return_error(reason)})
    end
  end

  @doc false
  def binary_split(ctx, binary, pattern, options) do
    case safe_binary_list_result(ctx, :split, [binary, pattern, options]) do
      {:ok, value} ->
        value

      {:error, reason} ->
        :erlang.error({:sandbox, :stdlib_error, :binary, :split, stdlib_return_error(reason)})
    end
  end

  @doc false
  def binary_matches(ctx, binary, pattern) do
    case safe_binary_list_result(ctx, :matches, [binary, pattern]) do
      {:ok, value} ->
        value

      {:error, reason} ->
        :erlang.error({:sandbox, :stdlib_error, :binary, :matches, stdlib_return_error(reason)})
    end
  end

  @doc false
  def binary_matches(ctx, binary, pattern, options) do
    case safe_binary_list_result(ctx, :matches, [binary, pattern, options]) do
      {:ok, value} ->
        value

      {:error, reason} ->
        :erlang.error({:sandbox, :stdlib_error, :binary, :matches, stdlib_return_error(reason)})
    end
  end

  @doc false
  def iolist_to_binary(ctx, iodata) do
    case safe_iolist_to_binary(ctx, :erlang, :iolist_to_binary, [iodata]) do
      {:ok, value} ->
        value

      {:error, reason} ->
        :erlang.error(
          {:sandbox, :stdlib_error, :erlang, :iolist_to_binary, stdlib_return_error(reason)}
        )
    end
  end

  @doc false
  def select_guest_dictionary_frame(frame_id) do
    previous = :erlang.get(@guest_process_dictionary_frame_key)

    case frame_id do
      nil -> :erlang.erase(@guest_process_dictionary_frame_key)
      :undefined -> :erlang.erase(@guest_process_dictionary_frame_key)
      id -> :erlang.put(@guest_process_dictionary_frame_key, id)
    end

    previous
  end

  @doc false
  def restore_guest_dictionary_frame(:undefined),
    do: :erlang.erase(@guest_process_dictionary_frame_key)

  def restore_guest_dictionary_frame(nil),
    do: :erlang.erase(@guest_process_dictionary_frame_key)

  def restore_guest_dictionary_frame(frame_id),
    do: :erlang.put(@guest_process_dictionary_frame_key, frame_id)

  @doc false
  def current_guest_dictionary_frame_id,
    do: :erlang.get(@guest_process_dictionary_frame_key)

  @doc false
  def guest_dictionary_get_all(ctx), do: guest_dictionary_entries(guest_dictionary_namespace(ctx))

  def guest_dictionary_get(ctx, key) do
    guest_dictionary_get_ns(guest_dictionary_namespace(ctx), key)
  end

  def guest_dictionary_get_ns(namespace, key) do
    case dictionary_get(guest_dictionary_storage_key(namespace, key)) do
      {@guest_process_dictionary_value_tag, value} -> value
      _other -> :undefined
    end
  end

  def guest_dictionary_put(ctx, key, value) do
    guest_dictionary_put_ns(guest_dictionary_namespace(ctx), key, value)
  end

  def guest_dictionary_put_ns(namespace, key, value) do
    storage_key = guest_dictionary_storage_key(namespace, key)

    case dictionary_get(storage_key) do
      {@guest_process_dictionary_value_tag, previous} ->
        dictionary_put(storage_key, {@guest_process_dictionary_value_tag, value})
        put_guest_dictionary_dependency_key(namespace, key, value)
        previous

      _other ->
        add_guest_dictionary_index_key(namespace, key)
        dictionary_put(storage_key, {@guest_process_dictionary_value_tag, value})
        put_guest_dictionary_dependency_key(namespace, key, value)
        :undefined
    end
  end

  @doc false
  def guest_dictionary_store_dependencies(namespace, key, value) do
    put_guest_dictionary_dependency_key(namespace, key, value)
    :ok
  end

  @doc false
  def guest_dictionary_delete_dependencies(namespace, key) do
    delete_guest_dictionary_dependency_key(namespace, key)
    :ok
  end

  @doc false
  def reset_guest_dictionary_dependency_scan_count do
    dictionary_put(@guest_process_dictionary_dependency_scan_count_key, 0)
    :ok
  end

  @doc false
  def guest_dictionary_dependency_scan_count do
    case dictionary_get(@guest_process_dictionary_dependency_scan_count_key) do
      count when is_integer(count) -> count
      _other -> 0
    end
  end

  @doc false
  def clear_guest_dictionary_dependency_scan_count do
    dictionary_erase(@guest_process_dictionary_dependency_scan_count_key)
    :ok
  end

  def guest_dictionary_erase_all(ctx) do
    namespace = guest_dictionary_namespace(ctx)
    entries = guest_dictionary_entries(namespace)
    clear_guest_dictionary_namespace(namespace)
    entries
  end

  def guest_dictionary_erase(ctx, key) do
    guest_dictionary_erase_ns(guest_dictionary_namespace(ctx), key)
  end

  def guest_dictionary_erase_ns(namespace, key) do
    storage_key = guest_dictionary_storage_key(namespace, key)

    case dictionary_get(storage_key) do
      {@guest_process_dictionary_value_tag, previous} ->
        delete_guest_dictionary_entry(namespace, key, storage_key)
        previous

      _other ->
        :undefined
    end
  end

  @doc false
  def clear_guest_dictionary do
    clear_guest_dictionary_namespace(nil)

    guest_dictionary_namespaces()
    |> Map.keys()
    |> Enum.each(&clear_guest_dictionary_namespace/1)

    :erlang.erase(@guest_process_dictionary_namespaces_key)
    :erlang.erase(@guest_process_dictionary_key)
    :erlang.erase(@guest_process_dictionary_dependency_index_key)
    :ok
  end

  @doc false
  def snapshot_guest_dictionary do
    legacy =
      guest_dictionary_entries(nil)
      |> Enum.map(fn {key, value} -> {nil, key, value} end)

    namespaced =
      guest_dictionary_namespaces()
      |> Map.keys()
      |> Enum.flat_map(fn namespace ->
        namespace
        |> guest_dictionary_entries()
        |> Enum.map(fn {key, value} -> {namespace, key, value} end)
      end)

    legacy ++ namespaced
  end

  @doc false
  def snapshot_guest_dictionary_reachable(roots) do
    {entries, dependencies} = snapshot_guest_dictionary_with_dependencies()
    reachable_guest_dictionary_entries(entries, dependencies, roots)
  end

  @doc false
  def snapshot_guest_dictionary_state do
    {entries, dependencies} = snapshot_guest_dictionary_with_dependencies()
    {:guest_dictionary_snapshot, entries, dependencies}
  end

  @doc false
  def restore_guest_dictionary_snapshot({:guest_dictionary_snapshot, entries, dependencies})
      when is_list(entries) and is_map(dependencies) do
    clear_guest_dictionary()

    restore_guest_dictionary_entries(entries, fn namespace, key, value ->
      case Map.fetch(dependencies, {namespace, key}) do
        {:ok, refs} -> refs
        :error -> guest_dictionary_value_dependencies(value)
      end
    end)
  end

  defp reachable_guest_dictionary_entries(entries, dependencies, roots) do
    handle_entries =
      Enum.reduce(entries, %{}, fn
        {_namespace, key, _value} = entry, acc ->
          if guest_ref_handle_key?(key) do
            Map.update(acc, key, [entry], &[entry | &1])
          else
            acc
          end
      end)

    ordinary_entries =
      Enum.reject(entries, fn {_namespace, key, _value} -> guest_ref_handle_key?(key) end)

    included =
      Map.new(ordinary_entries, fn {namespace, key, _value} = entry ->
        {{namespace, key}, entry}
      end)

    {included, seen_handles} =
      Enum.reduce(ordinary_entries, {included, MapSet.new()}, fn {namespace, key, value},
                                                                 {included, seen_handles} ->
        collect_reachable_guest_dictionary_refs(
          guest_dictionary_entry_dependencies(dependencies, namespace, key, value),
          handle_entries,
          dependencies,
          included,
          seen_handles
        )
      end)

    {included, _seen_handles} =
      collect_reachable_guest_dictionary_refs(
        guest_dictionary_value_dependencies(roots),
        handle_entries,
        dependencies,
        included,
        seen_handles
      )

    Map.values(included)
  end

  @doc false
  def restore_guest_dictionary(entries) when is_list(entries) do
    clear_guest_dictionary()
    restore_guest_dictionary_entries(entries, &guest_dictionary_value_dependencies/3)
  end

  defp restore_guest_dictionary_entries(entries, dependency_fun)
       when is_list(entries) and is_function(dependency_fun, 3) do
    grouped =
      Enum.reduce(entries, %{}, fn
        {namespace, key, value}, acc ->
          refs = dependency_fun.(namespace, key, value)
          Map.update(acc, namespace, [{key, value, refs}], &[{key, value, refs} | &1])

        {key, value}, acc ->
          refs = dependency_fun.(nil, key, value)
          Map.update(acc, nil, [{key, value, refs}], &[{key, value, refs} | &1])
      end)

    Enum.each(grouped, fn {namespace, values} ->
      index = Map.new(values, fn {key, _value, _refs} -> {key, true} end)
      dependency_index = Map.new(values, fn {key, _value, refs} -> {key, refs} end)

      Enum.each(values, fn {key, value, _refs} ->
        dictionary_put(
          guest_dictionary_storage_key(namespace, key),
          {@guest_process_dictionary_value_tag, value}
        )
      end)

      dictionary_put(guest_dictionary_index_key(namespace), index)
      dictionary_put(guest_dictionary_dependency_index_key(namespace), dependency_index)
    end)

    namespaces =
      grouped
      |> Map.keys()
      |> Enum.reduce(%{}, fn
        nil, acc -> acc
        namespace, acc -> Map.put(acc, namespace, true)
      end)

    if map_size(namespaces) > 0 do
      dictionary_put(@guest_process_dictionary_namespaces_key, namespaces)
    else
      dictionary_erase(@guest_process_dictionary_namespaces_key)
    end

    :ok
  end

  defp stdlib_profile_allowed?(
         %{manifest: %{stdlib: stdlib} = manifest},
         profile,
         nondeterministic?
       )
       when is_map(stdlib) do
    Map.get(stdlib, profile, false) == true and
      (not nondeterministic? or Hyperlang.Manifest.nondeterminism_enabled?(manifest))
  end

  defp stdlib_profile_allowed?(_ctx, _profile, nondeterministic?), do: not nondeterministic?

  defp validate_stdlib_behaviour(_ctx, _behaviour, [], _args), do: :ok

  defp validate_stdlib_behaviour(ctx, :callback_intrinsic, callback_args, args) do
    validate_stdlib_callback_args(ctx, callback_args, args)
  end

  defp validate_stdlib_behaviour(ctx, :bounded_wrapper, callback_args, args) do
    validate_stdlib_callback_args(ctx, callback_args, args)
  end

  defp validate_stdlib_behaviour(_ctx, _behaviour, _callback_args, _args), do: :ok

  defp validate_stdlib_callback_args(ctx, callback_args, args) do
    Enum.reduce_while(callback_args, :ok, fn index, :ok ->
      case Enum.fetch(args, index - 1) do
        {:ok, fun} when is_function(fun) ->
          if safe_stdlib_callback_fun?(ctx, fun) do
            {:cont, :ok}
          else
            {:halt, {:error, %{category: :stdlib_args, reason: :forbidden_term}}}
          end

        _ ->
          {:cont, :ok}
      end
    end)
  end

  defp safe_stdlib_callback_fun?(%{slot_module: slot_module}, fun) when is_function(fun) do
    info = :erlang.fun_info(fun)

    Keyword.get(info, :type) == :local and
      Keyword.get(info, :module) == slot_module
  end

  defp safe_stdlib_callback_fun?(_ctx, _fun), do: false

  defp dispatch_filesystem(ctx, operation, safe_args) do
    if host_filesystem_backend?(ctx) do
      Hyperlang.Filesystem.HostBackend.dispatch(ctx, operation, safe_args)
    else
      with {:ok, handle} <- filesystem_handle(ctx) do
        Hyperlang.Filesystem.dispatch(handle, operation, safe_args, ctx)
      end
    end
  end

  defp host_filesystem_backend?(%{manifest: %{filesystem: %{backend: :host}}}),
    do: true

  defp host_filesystem_backend?(_ctx), do: false

  defp fetch_export(%{manifest: %{exports: %{functions: functions, files: files}}}, export_id) do
    case Map.fetch(functions, export_id) do
      {:ok, export} -> {:ok, export}
      :error -> fetch_file_export(files, export_id)
    end
  end

  defp fetch_export(_ctx, _export_id), do: {:error, %{category: :export, reason: :unknown_export}}

  defp fetch_file_export(files, export_id) when is_list(files) do
    case Enum.find(
           files,
           &(callable_file_export?(&1) and Hyperlang.Manifest.file_export_id(&1) == export_id)
         ) do
      nil -> fetch_file_dependency_export(files, export_id)
      export -> {:ok, export}
    end
  end

  defp fetch_file_export(_files, _export_id),
    do: {:error, %{category: :export, reason: :unknown_export}}

  defp callable_file_export?(%{function: function, arity: arity})
       when is_binary(function) and is_integer(arity),
       do: true

  defp callable_file_export?(_file), do: false

  defp fetch_file_dependency_export(files, export_id) do
    Enum.find_value(files, {:error, %{category: :export, reason: :unknown_export}}, fn file ->
      case Hyperlang.Manifest.file_dependency_export(file) do
        {:ok, ^export_id, export} -> {:ok, export}
        _other -> nil
      end
    end)
  end

  defp require_export_arity(%{arity: arity}, args) do
    case proper_length(args) do
      ^arity ->
        :ok

      :improper ->
        {:error, %{category: :export, reason: :invalid_export_args}}

      actual ->
        {:error, %{category: :export, reason: :badarity, expected: arity, actual: actual}}
    end
  end

  defp proper_length(list), do: proper_length(list, 0)
  defp proper_length([], length), do: length
  defp proper_length([_head | tail], length), do: proper_length(tail, length + 1)
  defp proper_length(_other, _length), do: :improper

  @regex_match_limit 100_000
  @regex_match_limit_recursion 100_000
  @regex_pattern_max_bytes 65_536

  defp apply_stdlib(ctx, :re, function, args)
       when function in [:run, :replace, :split] do
    with {:ok, resolved_args} <- resolve_re_pattern_arg(args),
         {:ok, {safe_function, safe_args}} <-
           re_with_match_limits({function, resolved_args}, ctx),
         value <- :erlang.apply(:re, safe_function, safe_args),
         :ok <- check_re_result(ctx, value) do
      value
    else
      {:error, reason} ->
        :erlang.error({:sandbox, :stdlib_error, :re, function, reason})
    end
  end

  # Bounded re:compile proxy in the file-ops handle style: OTP's compiled
  # re_pattern carries a NIF reference, which can never cross the term
  # sanitizers, so the real pattern lives in a process-local handle table
  # and the guest holds an opaque {re_pattern, N} tag that run/replace/
  # split resolve back. Bounds: the pattern source is size-capped before
  # PCRE sees it, the table is capped per instance, and the catastrophic
  # regex costs live at match time, where the injected match_limit
  # options already apply.
  defp apply_stdlib(ctx, :re, :compile, args) do
    case re_compile_bounded(args, ctx) do
      {:ok, safe_args} ->
        case :erlang.apply(:re, :compile, safe_args) do
          {:ok, mp} -> {:ok, store_re_pattern(mp)}
          other -> other
        end

      {:error, reason} ->
        :erlang.error({:sandbox, :stdlib_error, :re, :compile, reason})
    end
  end

  defp apply_stdlib(ctx, :erlang, :atom_to_binary, args) do
    case safe_atom_to_binary(args, ctx) do
      {:ok, binary} ->
        binary

      {:error, reason} ->
        :erlang.error({:sandbox, :stdlib_error, :erlang, :atom_to_binary, reason})
    end
  end

  defp apply_stdlib(ctx, :erlang, :get, []) do
    guest_dictionary_get_all(ctx)
  end

  defp apply_stdlib(ctx, :erlang, :get, [key]) do
    guest_dictionary_get(ctx, key)
  end

  defp apply_stdlib(ctx, :erlang, :put, [key, value]) do
    guest_dictionary_put(ctx, key, value)
  end

  defp apply_stdlib(ctx, :erlang, :erase, []) do
    guest_dictionary_erase_all(ctx)
  end

  defp apply_stdlib(ctx, :erlang, :erase, [key]) do
    guest_dictionary_erase(ctx, key)
  end

  defp apply_stdlib(ctx, :erlang, :raise, [class, reason, stack]) do
    :erlang.raise(class, reason, sanitize_raise_stack(stack, ctx))
  end

  defp apply_stdlib(ctx, :erlang, function, args)
       when function in [:float_to_binary, :float_to_list] do
    case safe_float_format(ctx, function, args) do
      {:ok, value} ->
        value

      {:error, reason} ->
        :erlang.error({:sandbox, :stdlib_error, :erlang, function, float_format_error(reason)})
    end
  end

  defp apply_stdlib(ctx, :binary, :copy, args) do
    case safe_binary_copy(ctx, args) do
      {:ok, binary} ->
        binary

      {:error, reason} ->
        :erlang.error({:sandbox, :stdlib_error, :binary, :copy, stdlib_return_error(reason)})
    end
  end

  defp apply_stdlib(ctx, :binary, :bin_to_list, args) do
    case safe_binary_bin_to_list(ctx, args) do
      {:ok, list} ->
        list

      {:error, reason} ->
        :erlang.error(
          {:sandbox, :stdlib_error, :binary, :bin_to_list, stdlib_return_error(reason)}
        )
    end
  end

  defp apply_stdlib(ctx, :binary, function, args)
       when function in [:matches, :split] do
    case safe_binary_list_result(ctx, function, args) do
      {:ok, list} ->
        list

      {:error, reason} ->
        :erlang.error({:sandbox, :stdlib_error, :binary, function, stdlib_return_error(reason)})
    end
  end

  defp apply_stdlib(ctx, :binary, :replace, args) do
    case safe_binary_replace(ctx, args) do
      {:ok, binary} ->
        binary

      {:error, reason} ->
        :erlang.error({:sandbox, :stdlib_error, :binary, :replace, stdlib_return_error(reason)})
    end
  end

  defp apply_stdlib(ctx, :binary, :decode_unsigned, args) do
    case safe_binary_decode_unsigned(ctx, args) do
      {:ok, integer} ->
        integer

      {:error, reason} ->
        :erlang.error(
          {:sandbox, :stdlib_error, :binary, :decode_unsigned, stdlib_return_error(reason)}
        )
    end
  end

  defp apply_stdlib(ctx, :binary, :encode_unsigned, args) do
    case safe_binary_encode_unsigned(ctx, args) do
      {:ok, binary} ->
        binary

      {:error, reason} ->
        :erlang.error(
          {:sandbox, :stdlib_error, :binary, :encode_unsigned, stdlib_return_error(reason)}
        )
    end
  end

  defp apply_stdlib(ctx, :base64, function, args)
       when function in [
              :decode,
              :decode_to_string,
              :encode,
              :encode_to_string,
              :mime_decode,
              :mime_decode_to_string
            ] do
    case safe_base64(ctx, function, args) do
      {:ok, value} ->
        value

      {:error, reason} ->
        :erlang.error({:sandbox, :stdlib_error, :base64, function, stdlib_return_error(reason)})
    end
  end

  defp apply_stdlib(ctx, :binary, :list_to_bin, args) do
    case safe_iolist_to_binary(ctx, :binary, :list_to_bin, args) do
      {:ok, binary} ->
        binary

      {:error, reason} ->
        :erlang.error(
          {:sandbox, :stdlib_error, :binary, :list_to_bin, stdlib_return_error(reason)}
        )
    end
  end

  defp apply_stdlib(ctx, :binary, :join, args) do
    case safe_binary_join(ctx, args) do
      {:ok, binary} ->
        binary

      {:error, reason} ->
        :erlang.error({:sandbox, :stdlib_error, :binary, :join, stdlib_return_error(reason)})
    end
  end

  defp apply_stdlib(ctx, :binary, :encode_hex, args) do
    case safe_binary_encode_hex(ctx, args) do
      {:ok, binary} ->
        binary

      {:error, reason} ->
        :erlang.error(
          {:sandbox, :stdlib_error, :binary, :encode_hex, stdlib_return_error(reason)}
        )
    end
  end

  defp apply_stdlib(ctx, :erlang, function, args)
       when function in [:list_to_binary, :iolist_to_binary] do
    case safe_iolist_to_binary(ctx, :erlang, function, args) do
      {:ok, binary} ->
        binary

      {:error, reason} ->
        :erlang.error({:sandbox, :stdlib_error, :erlang, function, stdlib_return_error(reason)})
    end
  end

  defp apply_stdlib(ctx, :unicode, function, args)
       when function in [:characters_to_binary, :characters_to_list] do
    checked_unicode_conversion(ctx, function, args)
  end

  defp apply_stdlib(ctx, :string, function, args)
       when function in [:casefold, :lowercase, :titlecase, :to_lower, :to_upper, :uppercase] do
    case safe_string_case(ctx, function, args) do
      {:ok, value} ->
        value

      {:error, reason} ->
        :erlang.error({:sandbox, :stdlib_error, :string, function, stdlib_return_error(reason)})
    end
  end

  defp apply_stdlib(ctx, :string, function, args)
       when function in [:centre, :chars, :concat, :copies, :join, :left, :pad, :right] do
    case safe_string_list_helper(ctx, function, args) do
      {:ok, value} ->
        value

      {:error, reason} ->
        :erlang.error({:sandbox, :stdlib_error, :string, function, stdlib_return_error(reason)})
    end
  end

  defp apply_stdlib(ctx, :string, function, args)
       when function in [:lexemes, :tokens] do
    case safe_string_tokenize(ctx, function, args) do
      {:ok, value} ->
        value

      {:error, reason} ->
        :erlang.error({:sandbox, :stdlib_error, :string, function, stdlib_return_error(reason)})
    end
  end

  defp apply_stdlib(ctx, :string, function, args)
       when function in [:replace, :split] do
    case safe_string_split_replace(ctx, function, args) do
      {:ok, value} ->
        value

      {:error, reason} ->
        :erlang.error({:sandbox, :stdlib_error, :string, function, stdlib_return_error(reason)})
    end
  end

  defp apply_stdlib(ctx, :string, function, args)
       when function in [:reverse, :to_graphemes] do
    case safe_string_to_list(ctx, function, args) do
      {:ok, value} ->
        value

      {:error, reason} ->
        :erlang.error({:sandbox, :stdlib_error, :string, function, stdlib_return_error(reason)})
    end
  end

  defp apply_stdlib(ctx, :io_lib, function, args)
       when function in [:bformat, :bfwrite, :build_text, :format, :fwrite] do
    case safe_io_lib_format(ctx, function, args) do
      {:ok, value} ->
        value

      {:error, reason} ->
        :erlang.error({:sandbox, :stdlib_error, :io_lib, function, io_lib_format_error(reason)})
    end
  end

  # Without an explicit offset, OTP formats the time in the host's local time
  # zone, which is a live host value like `calendar:local_time/0`.
  defp apply_stdlib(ctx, :calendar, :system_time_to_rfc3339, [time, options]) do
    offset = if is_list(options), do: :proplists.get_value(:offset, options, ""), else: ""

    if is_integer(offset) or (is_list(offset) and offset != []) or
         Hyperlang.Manifest.nondeterminism_enabled?(Map.get(ctx, :manifest)) do
      :calendar.system_time_to_rfc3339(time, options)
    else
      :erlang.error(
        {:sandbox, :stdlib_error, :calendar, :system_time_to_rfc3339, :forbidden_stdlib_call}
      )
    end
  end

  # `io_lib:format_prompt/1,2` formats through the same projection as
  # `io_lib:format/2`. OTP recognizes the `{format, Format, Args}` form and the
  # `unicode` encoding by atom identity; guest spellings of them may be pooled.
  defp apply_stdlib(ctx, :io_lib, :format_prompt, [prompt | encoding]) do
    {form, prompt} =
      with {tag, format, args} when is_atom(tag) <- prompt,
           {:ok, "format"} <- safe_atom_name(tag, ctx) do
        {:format, {format, args}}
      else
        _other -> {:prompt, prompt}
      end

    encoding =
      Enum.map(encoding, fn
        encoding when is_atom(encoding) ->
          if safe_atom_name(encoding, ctx) == {:ok, "unicode"}, do: :unicode, else: :latin1

        encoding ->
          encoding
      end)

    case io_lib_public_args(ctx, prompt) do
      {:ok, {format, args}} when form == :format ->
        :erlang.apply(:hyperlang_otp_io_lib, :format_prompt, [{:format, format, args} | encoding])

      {:ok, prompt} ->
        :erlang.apply(:hyperlang_otp_io_lib, :format_prompt, [prompt | encoding])

      {:error, reason} ->
        :erlang.error({:sandbox, :stdlib_error, :io_lib, :format_prompt, reason})
    end
  end

  # Atom-stringifying helpers render an atom argument by its name, so a pool
  # atom would surface as its internal `hyperlang_atom_N` name. Pool atoms are
  # projected to their source names as charlists, which these functions render
  # exactly as they render the atom itself: `filename:*` flattens names deeply,
  # `lists:concat/1` stringifies only the elements of its list.
  defp apply_stdlib(ctx, :filename, function, args),
    do: :erlang.apply(:filename, function, source_atom_chars(args, ctx))

  defp apply_stdlib(ctx, :lists, :concat, [things]) when is_list(things) do
    things
    |> Enum.map(fn thing -> if is_atom(thing), do: source_atom_chars(thing, ctx), else: thing end)
    |> :lists.concat()
  end

  defp apply_stdlib(_ctx, module, function, args), do: :erlang.apply(module, function, args)

  defp source_atom_chars(value, ctx) when is_atom(value) do
    case Hyperlang.Terms.atom_source(value, ctx) do
      source when is_binary(source) -> String.to_charlist(source)
      nil -> value
    end
  end

  defp source_atom_chars([head | tail], ctx) when is_list(tail),
    do: [source_atom_chars(head, ctx) | source_atom_chars(tail, ctx)]

  defp source_atom_chars([head | tail], ctx), do: [source_atom_chars(head, ctx) | tail]
  defp source_atom_chars(value, _ctx), do: value

  defp sanitize_raise_stack(stack, ctx) when is_list(stack) do
    stack
    |> Enum.reduce([], fn frame, acc ->
      case sanitize_raise_frame(frame, ctx) do
        nil -> acc
        safe -> [safe | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.take(8)
  end

  defp sanitize_raise_stack(_stack, _ctx), do: []

  defp sanitize_raise_frame({module, function, args_or_arity, _location}, %{
         slot_module: slot_module,
         stack_map: stack_map
       })
       when module == slot_module and is_atom(function) and is_map(stack_map) do
    if Map.has_key?(stack_map, function) do
      arity =
        cond do
          is_integer(args_or_arity) and args_or_arity >= 0 -> args_or_arity
          is_list(args_or_arity) -> length(args_or_arity)
          true -> 0
        end

      {module, function, arity, []}
    end
  end

  defp sanitize_raise_frame(_frame, _ctx), do: nil

  defp safe_binary_copy(ctx, [binary]) when is_binary(binary) do
    if byte_size(binary) <= ctx.limits.max_binary_bytes do
      {:ok, :binary.copy(binary)}
    else
      {:error, :binary_bytes}
    end
  end

  defp safe_binary_copy(ctx, [binary, count])
       when is_binary(binary) and is_integer(count) and count >= 0 do
    if byte_size(binary) * count <= ctx.limits.max_binary_bytes do
      {:ok, :binary.copy(binary, count)}
    else
      {:error, :binary_bytes}
    end
  end

  defp safe_binary_copy(_ctx, args), do: {:ok, :erlang.apply(:binary, :copy, args)}

  defp safe_binary_decode_unsigned(ctx, [binary]) when is_binary(binary) do
    if byte_size(binary) * 8 <= ctx.limits.max_integer_bits do
      {:ok, :binary.decode_unsigned(binary)}
    else
      {:error, :integer_bits}
    end
  end

  defp safe_binary_decode_unsigned(ctx, [binary, endian]) when is_binary(binary) do
    if byte_size(binary) * 8 <= ctx.limits.max_integer_bits do
      {:ok, :binary.decode_unsigned(binary, endian)}
    else
      {:error, :integer_bits}
    end
  end

  defp safe_binary_decode_unsigned(_ctx, args),
    do: {:ok, :erlang.apply(:binary, :decode_unsigned, args)}

  defp safe_binary_encode_unsigned(ctx, [integer]) when is_integer(integer) and integer >= 0 do
    if unsigned_integer_fits_binary_limit?(integer, ctx.limits.max_binary_bytes) do
      {:ok, :binary.encode_unsigned(integer)}
    else
      {:error, :binary_bytes}
    end
  end

  defp safe_binary_encode_unsigned(ctx, [integer, endian])
       when is_integer(integer) and integer >= 0 do
    if unsigned_integer_fits_binary_limit?(integer, ctx.limits.max_binary_bytes) do
      {:ok, :binary.encode_unsigned(integer, endian)}
    else
      {:error, :binary_bytes}
    end
  end

  defp safe_binary_encode_unsigned(_ctx, args),
    do: {:ok, :erlang.apply(:binary, :encode_unsigned, args)}

  defp unsigned_integer_fits_binary_limit?(_integer, limit)
       when not is_integer(limit) or limit <= 0,
       do: false

  defp unsigned_integer_fits_binary_limit?(0, limit), do: limit >= 1

  defp unsigned_integer_fits_binary_limit?(integer, limit) do
    integer < Bitwise.bsl(1, limit * 8)
  end

  defp safe_binary_bin_to_list(ctx, args) do
    case binary_bin_to_list_size(args) do
      {:ok, size} when size <= ctx.limits.max_list_length ->
        {:ok, :erlang.apply(:binary, :bin_to_list, args)}

      {:ok, _size} ->
        {:error, :list_length}

      :unknown ->
        {:ok, :erlang.apply(:binary, :bin_to_list, args)}
    end
  end

  defp binary_bin_to_list_size([binary]) when is_binary(binary), do: {:ok, byte_size(binary)}

  defp binary_bin_to_list_size([binary, {position, length}])
       when is_binary(binary) and is_integer(position) and is_integer(length) and
              position >= 0 and length >= 0 and position + length <= byte_size(binary),
       do: {:ok, length}

  defp binary_bin_to_list_size([binary, position, length])
       when is_binary(binary) and is_integer(position) and is_integer(length) and
              position >= 0 and length >= 0 and position + length <= byte_size(binary),
       do: {:ok, length}

  defp binary_bin_to_list_size(_args), do: :unknown

  defp safe_binary_list_result(ctx, function, args) do
    check_binary_list_result(ctx, :erlang.apply(:binary, function, args))
  end

  defp check_binary_list_result(ctx, result) when is_list(result) do
    if length(result) <= ctx.limits.max_list_length do
      {:ok, result}
    else
      {:error, :list_length}
    end
  end

  defp check_binary_list_result(_ctx, result), do: {:ok, result}

  defp safe_binary_replace(ctx, args) do
    case binary_replace_result_size(args, ctx) do
      {:ok, size} when size <= ctx.limits.max_binary_bytes ->
        {:ok, :erlang.apply(:binary, :replace, args)}

      {:ok, _size} ->
        {:error, :binary_bytes}

      :unknown ->
        {:ok, :erlang.apply(:binary, :replace, args)}
    end
  end

  defp binary_replace_result_size([binary, pattern, replacement], _ctx)
       when is_binary(binary) and is_binary(replacement) do
    binary_replace_result_size(binary, pattern, replacement, false, 0)
  end

  defp binary_replace_result_size([binary, pattern, replacement, options], ctx)
       when is_binary(binary) and is_binary(replacement) do
    insert_count = binary_insert_replaced_count(options, ctx)

    if is_integer(insert_count) do
      binary_replace_result_size(
        binary,
        pattern,
        replacement,
        binary_option_present?(options, "global", ctx),
        insert_count
      )
    else
      :unknown
    end
  end

  defp binary_replace_result_size(_args, _ctx), do: :unknown

  defp binary_replace_result_size(binary, pattern, replacement, global?, insert_count) do
    case binary_pattern_min_size(pattern) do
      {:ok, pattern_size} when pattern_size > 0 ->
        match_count = if global?, do: div(byte_size(binary), pattern_size), else: 1
        replacement_size = byte_size(replacement) + pattern_size * insert_count

        {:ok, byte_size(binary) + match_count * max(replacement_size - pattern_size, 0)}

      _other ->
        :unknown
    end
  end

  defp binary_pattern_min_size(pattern) when is_binary(pattern), do: {:ok, byte_size(pattern)}

  defp binary_pattern_min_size(patterns) when is_list(patterns) do
    Enum.reduce_while(patterns, :none, fn
      pattern, acc when is_binary(pattern) ->
        size = byte_size(pattern)
        {:cont, if(acc == :none, do: size, else: min(acc, size))}

      _pattern, _acc ->
        {:halt, :unknown}
    end)
    |> case do
      size when is_integer(size) -> {:ok, size}
      _other -> :unknown
    end
  end

  defp binary_pattern_min_size(_pattern), do: :unknown

  defp binary_option_present?(options, name, ctx) when is_list(options) do
    Enum.any?(options, fn
      {key, _value} -> option_key_name(key, ctx) == name
      option -> option_key_name(option, ctx) == name
    end)
  end

  defp binary_option_present?(_options, _name, _ctx), do: false

  defp binary_insert_replaced_count(options, ctx) when is_list(options) do
    Enum.reduce_while(options, 0, fn
      {key, value}, count ->
        if option_key_name(key, ctx) == "insert_replaced" do
          case insert_replaced_count(value) do
            {:ok, inserts} -> {:cont, count + inserts}
            :unknown -> {:halt, :unknown}
          end
        else
          {:cont, count}
        end

      _option, count ->
        {:cont, count}
    end)
  end

  defp binary_insert_replaced_count(_options, _ctx), do: 0

  defp insert_replaced_count(position) when is_integer(position), do: {:ok, 1}

  defp insert_replaced_count(positions) when is_list(positions) do
    if Enum.all?(positions, &is_integer/1), do: {:ok, length(positions)}, else: :unknown
  end

  defp insert_replaced_count(_value), do: :unknown

  defp safe_base64(ctx, function, args) do
    args = normalize_base64_args(args, ctx)

    case base64_result_size(function, args) do
      {:ok, size, :binary} ->
        if size <= ctx.limits.max_binary_bytes do
          {:ok, :erlang.apply(:base64, function, args)}
        else
          {:error, :binary_bytes}
        end

      {:ok, size, :string} ->
        if size <= ctx.limits.max_list_length do
          {:ok, :erlang.apply(:base64, function, args)}
        else
          {:error, :list_length}
        end

      :unknown ->
        {:ok, :erlang.apply(:base64, function, args)}
    end
  end

  defp normalize_base64_args([data, options], ctx) when is_map(options),
    do: [data, normalize_base64_options(options, ctx)]

  defp normalize_base64_args(args, _ctx), do: args

  defp normalize_base64_options(options, ctx) do
    Map.new(options, fn {key, value} ->
      case option_key_name(key, ctx) do
        "padding" ->
          {:padding, value}

        "mode" ->
          {:mode, normalize_base64_mode(value, ctx)}

        _other ->
          {key, value}
      end
    end)
  end

  defp normalize_base64_mode(value, ctx) when is_atom(value) do
    case safe_atom_name(value, ctx) do
      {:ok, "standard"} -> :standard
      {:ok, "urlsafe"} -> :urlsafe
      {:ok, _other} -> value
    end
  end

  defp normalize_base64_mode(value, _ctx), do: value

  defp base64_result_size(function, [data])
       when function in [:encode, :encode_to_string] do
    base64_encoded_size(function, data, true)
  end

  defp base64_result_size(function, [data, options])
       when function in [:encode, :encode_to_string] and is_map(options) do
    base64_encoded_size(function, data, base64_padding?(options))
  end

  defp base64_result_size(function, [data])
       when function in [:decode, :decode_to_string, :mime_decode, :mime_decode_to_string] do
    base64_decoded_size(function, data, true)
  end

  defp base64_result_size(function, [data, options])
       when function in [:decode, :decode_to_string, :mime_decode, :mime_decode_to_string] and
              is_map(options) do
    base64_decoded_size(function, data, base64_padding?(options))
  end

  defp base64_result_size(_function, _args), do: :unknown

  defp base64_encoded_size(function, data, padding?) do
    case safe_iolist_size(data) do
      {:ok, input_size} ->
        {:ok, encoded_size(input_size, padding?), base64_output_kind(function)}

      :error ->
        :unknown
    end
  end

  defp base64_decoded_size(function, data, padding?) do
    mime? = function in [:mime_decode, :mime_decode_to_string]

    case base64_symbol_count(data, mime?) do
      {:ok, symbols, trailing_padding} ->
        {:ok, decoded_size(symbols, trailing_padding, padding?), base64_output_kind(function)}

      :error ->
        :unknown
    end
  end

  defp encoded_size(0, _padding?), do: 0
  defp encoded_size(input_size, true), do: div(input_size + 2, 3) * 4
  defp encoded_size(input_size, false), do: div(input_size * 4 + 2, 3)

  defp decoded_size(symbols, trailing_padding, true) do
    max(div(symbols, 4) * 3 - min(trailing_padding, 2), 0)
  end

  defp decoded_size(symbols, _trailing_padding, false) do
    div(symbols, 4) * 3 +
      case rem(symbols, 4) do
        2 -> 1
        3 -> 2
        _ -> 0
      end
  end

  defp base64_output_kind(function)
       when function in [:encode, :decode, :mime_decode],
       do: :binary

  defp base64_output_kind(_function), do: :string

  defp base64_padding?(options) do
    case Map.fetch(options, :padding) do
      {:ok, false} -> false
      _other -> true
    end
  end

  defp option_key_name(key, ctx) when is_atom(key) do
    case safe_atom_name(key, ctx) do
      {:ok, name} -> name
    end
  end

  defp option_key_name(key, _ctx) when is_binary(key), do: key
  defp option_key_name(_key, _ctx), do: nil

  defp base64_symbol_count(data, mime?) do
    case count_base64_iodata(data, mime?, 0, 0) do
      {:ok, symbols, trailing_padding} -> {:ok, symbols, trailing_padding}
      :error -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp count_base64_iodata(binary, mime?, symbols, trailing_padding) when is_binary(binary) do
    count_base64_binary(binary, mime?, symbols, trailing_padding)
  end

  defp count_base64_iodata(list, mime?, symbols, trailing_padding) when is_list(list) do
    Enum.reduce_while(list, {:ok, symbols, trailing_padding}, fn item,
                                                                 {:ok, symbols, trailing_padding} ->
      case count_base64_iodata(item, mime?, symbols, trailing_padding) do
        {:ok, symbols, trailing_padding} -> {:cont, {:ok, symbols, trailing_padding}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp count_base64_iodata(byte, mime?, symbols, trailing_padding) when is_integer(byte) do
    count_base64_byte(byte, mime?, symbols, trailing_padding)
  end

  defp count_base64_iodata(_other, _mime?, _symbols, _trailing_padding), do: :error

  defp count_base64_binary(binary, mime?, symbols, trailing_padding) do
    for <<byte <- binary>>, reduce: {:ok, symbols, trailing_padding} do
      {:ok, symbols, trailing_padding} ->
        case count_base64_byte(byte, mime?, symbols, trailing_padding) do
          {:ok, symbols, trailing_padding} -> {:ok, symbols, trailing_padding}
          :error -> :error
        end

      :error ->
        :error
    end
  end

  defp count_base64_byte(byte, true, symbols, trailing_padding)
       when byte in [?\s, ?\t, ?\n, ?\r],
       do: {:ok, symbols, trailing_padding}

  defp count_base64_byte(?=, _mime?, symbols, trailing_padding),
    do: {:ok, symbols + 1, trailing_padding + 1}

  defp count_base64_byte(byte, _mime?, symbols, _trailing_padding)
       when is_integer(byte) and byte >= 0 and byte <= 255,
       do: {:ok, symbols + 1, 0}

  defp count_base64_byte(_byte, _mime?, _symbols, _trailing_padding), do: :error

  defp safe_iolist_to_binary(ctx, module, function, [iodata]) do
    case safe_iolist_size(iodata) do
      {:ok, size} ->
        if size <= ctx.limits.max_binary_bytes do
          {:ok, :erlang.apply(module, function, [iodata])}
        else
          {:error, :binary_bytes}
        end

      :error ->
        {:ok, :erlang.apply(module, function, [iodata])}
    end
  end

  defp safe_iolist_to_binary(_ctx, module, function, args),
    do: {:ok, :erlang.apply(module, function, args)}

  defp safe_iolist_size(iodata) do
    {:ok, :erlang.iolist_size(iodata)}
  rescue
    ArgumentError -> :error
  end

  defp safe_binary_join(ctx, [parts, separator]) when is_list(parts) and is_binary(separator) do
    case joined_binary_size(parts, separator) do
      {:ok, size} ->
        if size <= ctx.limits.max_binary_bytes do
          {:ok, :binary.join(parts, separator)}
        else
          {:error, :binary_bytes}
        end

      :error ->
        {:ok, :binary.join(parts, separator)}
    end
  end

  defp safe_binary_join(_ctx, args), do: {:ok, :erlang.apply(:binary, :join, args)}

  defp joined_binary_size(parts, separator) do
    Enum.reduce_while(parts, {:ok, 0, 0}, fn
      part, {:ok, size, count} when is_binary(part) ->
        {:cont, {:ok, size + byte_size(part), count + 1}}

      _part, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, size, count} when count > 0 -> {:ok, size + byte_size(separator) * (count - 1)}
      {:ok, size, 0} -> {:ok, size}
      :error -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp safe_binary_encode_hex(ctx, [binary]) when is_binary(binary) do
    if byte_size(binary) * 2 <= ctx.limits.max_binary_bytes do
      {:ok, :binary.encode_hex(binary)}
    else
      {:error, :binary_bytes}
    end
  end

  defp safe_binary_encode_hex(ctx, [binary, case_option]) when is_binary(binary) do
    if byte_size(binary) * 2 <= ctx.limits.max_binary_bytes do
      {:ok, :binary.encode_hex(binary, case_option)}
    else
      {:error, :binary_bytes}
    end
  end

  defp safe_binary_encode_hex(_ctx, args), do: {:ok, :erlang.apply(:binary, :encode_hex, args)}

  defp stdlib_return_error(reason), do: %{category: :stdlib_return, reason: reason}

  defp safe_string_case(ctx, function, [input]) do
    case string_case_result_size(input) do
      {:ok, size, :binary} ->
        if size <= ctx.limits.max_binary_bytes do
          {:ok, :erlang.apply(:string, function, [input])}
        else
          {:error, :binary_bytes}
        end

      {:ok, size, :list} ->
        if size <= ctx.limits.max_list_length do
          {:ok, :erlang.apply(:string, function, [input])}
        else
          {:error, :list_length}
        end

      :unknown ->
        {:ok, :erlang.apply(:string, function, [input])}
    end
  end

  defp safe_string_case(_ctx, function, args), do: {:ok, :erlang.apply(:string, function, args)}

  defp safe_string_list_helper(ctx, function, args) do
    case string_list_result_size(function, args) do
      {:ok, size} ->
        if size <= ctx.limits.max_list_length do
          {:ok, :erlang.apply(:string, function, args)}
        else
          {:error, :list_length}
        end

      :unknown ->
        {:ok, :erlang.apply(:string, function, args)}
    end
  end

  defp string_list_result_size(:chars, [_character, count])
       when is_integer(count) and count >= 0,
       do: {:ok, count}

  defp string_list_result_size(:chars, [_character, count, tail])
       when is_integer(count) and count >= 0 do
    case unicode_chardata_scalar_bound(tail, 0) do
      {:ok, tail_size} -> {:ok, count + tail_size}
      :unknown -> {:ok, count}
    end
  end

  defp string_list_result_size(:copies, [string, count])
       when is_integer(count) and count >= 0 do
    case unicode_chardata_scalar_bound(string, 0) do
      {:ok, size} -> {:ok, size * count}
      :unknown -> :unknown
    end
  end

  defp string_list_result_size(function, [string, count])
       when function in [:centre, :left, :pad, :right] and is_integer(count) and count >= 0 do
    case unicode_chardata_scalar_bound(string, 0) do
      {:ok, size} -> {:ok, max(size, count)}
      :unknown -> {:ok, count}
    end
  end

  defp string_list_result_size(function, [string, count, _option])
       when function in [:centre, :left, :pad, :right] and is_integer(count) and count >= 0 do
    case unicode_chardata_scalar_bound(string, 0) do
      {:ok, size} -> {:ok, max(size, count)}
      :unknown -> {:ok, count}
    end
  end

  defp string_list_result_size(:pad, [string, count, _direction, _character])
       when is_integer(count) and count >= 0 do
    case unicode_chardata_scalar_bound(string, 0) do
      {:ok, size} -> {:ok, max(size, count)}
      :unknown -> {:ok, count}
    end
  end

  defp string_list_result_size(:concat, [left, right]) do
    with {:ok, left_size} <- unicode_chardata_scalar_bound(left, 0),
         {:ok, right_size} <- unicode_chardata_scalar_bound(right, 0) do
      {:ok, left_size + right_size}
    else
      :unknown -> :unknown
    end
  end

  defp string_list_result_size(:join, [strings, separator]) when is_list(strings) do
    with {:ok, separator_size} <- unicode_chardata_scalar_bound(separator, 0),
         {:ok, strings_size, count} <- joined_string_size(strings) do
      {:ok, strings_size + separator_size * max(count - 1, 0)}
    else
      :unknown -> :unknown
    end
  end

  defp string_list_result_size(_function, _args), do: :unknown

  defp joined_string_size(strings) do
    Enum.reduce_while(strings, {:ok, 0, 0}, fn string, {:ok, size, count} ->
      case unicode_chardata_scalar_bound(string, 0) do
        {:ok, string_size} -> {:cont, {:ok, size + string_size, count + 1}}
        :unknown -> {:halt, :unknown}
      end
    end)
  end

  defp safe_string_tokenize(ctx, function, [string, separators]) do
    case string_token_result_bound(string, separators) do
      {:ok, list_length} when list_length <= ctx.limits.max_list_length ->
        {:ok, :erlang.apply(:string, function, [string, separators])}

      {:ok, _list_length} ->
        {:error, :list_length}

      :unknown ->
        {:ok, :erlang.apply(:string, function, [string, separators])}
    end
  end

  defp safe_string_tokenize(_ctx, function, args),
    do: {:ok, :erlang.apply(:string, function, args)}

  defp string_token_result_bound(string, separators) do
    with {:ok, string_size} <- unicode_chardata_scalar_bound(string, 0),
         {:ok, _separator_size} <- unicode_chardata_scalar_bound(separators, 0) do
      {:ok, string_size}
    else
      _other -> :unknown
    end
  end

  defp safe_string_split_replace(ctx, function, args) do
    args = normalize_string_args(function, args, ctx)

    case string_split_replace_result_size(function, args) do
      {:ok, %{list_length: list_length, output_size: output_size}} ->
        cond do
          list_length > ctx.limits.max_list_length ->
            {:error, :list_length}

          output_size > ctx.limits.max_binary_bytes ->
            {:error, :binary_bytes}

          true ->
            {:ok, :erlang.apply(:string, function, args)}
        end

      :unknown ->
        {:ok, :erlang.apply(:string, function, args)}
    end
  end

  defp normalize_string_args(:split, [string, search_pattern, where], ctx),
    do: [string, search_pattern, normalize_string_where(where, ctx)]

  defp normalize_string_args(:replace, [string, search_pattern, replacement, where], ctx),
    do: [string, search_pattern, replacement, normalize_string_where(where, ctx)]

  defp normalize_string_args(_function, args, _ctx), do: args

  defp normalize_string_where(value, ctx) when is_atom(value) do
    case safe_atom_name(value, ctx) do
      {:ok, "all"} -> :all
      {:ok, "leading"} -> :leading
      {:ok, "trailing"} -> :trailing
      {:ok, _other} -> value
    end
  end

  defp normalize_string_where(value, _ctx), do: value

  defp string_split_replace_result_size(:split, [string, search_pattern]) do
    with {:ok, input_size} <- unicode_chardata_scalar_bound(string, 0),
         {:ok, search_size} when search_size > 0 <-
           unicode_chardata_scalar_bound(search_pattern, 0) do
      {:ok, %{list_length: min(input_size + 1, 2), output_size: input_size}}
    else
      _other -> :unknown
    end
  end

  defp string_split_replace_result_size(:split, [string, search_pattern, where]) do
    with {:ok, input_size} <- unicode_chardata_scalar_bound(string, 0),
         {:ok, search_size} when search_size > 0 <-
           unicode_chardata_scalar_bound(search_pattern, 0) do
      {:ok,
       %{list_length: split_result_count(input_size, search_size, where), output_size: input_size}}
    else
      _other -> :unknown
    end
  end

  defp string_split_replace_result_size(:replace, [string, search_pattern, replacement]) do
    replace_result_size(string, search_pattern, replacement, :leading)
  end

  defp string_split_replace_result_size(:replace, [string, search_pattern, replacement, where]) do
    replace_result_size(string, search_pattern, replacement, where)
  end

  defp string_split_replace_result_size(_function, _args), do: :unknown

  defp split_result_count(input_size, search_size, :all),
    do: div(input_size, max(search_size, 1)) + 1

  defp split_result_count(input_size, _search_size, where)
       when where in [:leading, :trailing],
       do: min(input_size + 1, 2)

  defp split_result_count(_input_size, _search_size, _where), do: 2

  defp replace_result_size(string, search_pattern, replacement, where) do
    with {:ok, input_size} <- unicode_chardata_scalar_bound(string, 0),
         {:ok, search_size} when search_size > 0 <-
           unicode_chardata_scalar_bound(search_pattern, 0),
         {:ok, replacement_size} <- unicode_chardata_scalar_bound(replacement, 0) do
      match_count = replace_match_count(input_size, search_size, where)

      output_size =
        input_size + match_count * max(replacement_size - search_size, 0)

      {:ok, %{list_length: match_count * 2 + 1, output_size: output_size}}
    else
      _other -> :unknown
    end
  end

  defp replace_match_count(input_size, search_size, :all),
    do: div(input_size, max(search_size, 1))

  defp replace_match_count(_input_size, _search_size, where)
       when where in [:leading, :trailing],
       do: 1

  defp replace_match_count(_input_size, _search_size, _where), do: 1

  defp safe_string_to_list(ctx, function, [input]) do
    case unicode_chardata_scalar_bound(input, 0) do
      {:ok, size} when size <= ctx.limits.max_list_length ->
        {:ok, :erlang.apply(:string, function, [input])}

      {:ok, _size} ->
        {:error, :list_length}

      :unknown ->
        {:ok, :erlang.apply(:string, function, [input])}
    end
  end

  defp safe_string_to_list(_ctx, function, args),
    do: {:ok, :erlang.apply(:string, function, args)}

  defp string_case_result_size(input) when is_binary(input) do
    {:ok, unicode_case_binary_bound(input), :binary}
  end

  defp string_case_result_size(input) when is_list(input) do
    case unicode_chardata_scalar_bound(input, 0) do
      {:ok, scalar_count} -> {:ok, scalar_count * 3, :list}
      :unknown -> :unknown
    end
  end

  defp string_case_result_size(_input), do: :unknown

  defp unicode_case_binary_bound(binary), do: byte_size(binary) * 12

  def unicode_characters_to_binary(ctx, data),
    do: checked_unicode_conversion(ctx, :characters_to_binary, [data])

  def unicode_characters_to_binary(ctx, data, in_encoding),
    do: checked_unicode_conversion(ctx, :characters_to_binary, [data, in_encoding])

  def unicode_characters_to_binary(ctx, data, in_encoding, out_encoding),
    do: checked_unicode_conversion(ctx, :characters_to_binary, [data, in_encoding, out_encoding])

  def unicode_characters_to_list(ctx, data),
    do: checked_unicode_conversion(ctx, :characters_to_list, [data])

  def unicode_characters_to_list(ctx, data, in_encoding),
    do: checked_unicode_conversion(ctx, :characters_to_list, [data, in_encoding])

  def rune_len(ctx, value) do
    cond do
      rune_nil?(ctx, value) ->
        0

      is_binary(value) ->
        ensure_rune_binary_list_limit!(ctx, value)

        if ascii_binary?(value) do
          byte_size(value)
        else
          case utf8_count(value, 0) do
            {:ok, count} -> count
            :error -> length(rune_list_value(ctx, value))
          end
        end

      is_list(value) ->
        length(value)

      true ->
        length(rune_list_value(ctx, value))
    end
  end

  def rune_at(ctx, value, index) do
    cond do
      rune_nil?(ctx, value) ->
        rune_at_fallback(ctx, value, index)

      is_binary(value) and is_integer(index) and index >= 0 ->
        ensure_rune_binary_list_limit!(ctx, value)

        if ascii_binary?(value) do
          if index < byte_size(value),
            do: :binary.at(value, index),
            else: rune_at_fallback(ctx, value, index)
        else
          case utf8_count(value, 0) do
            {:ok, count} when index < count ->
              {:ok, codepoint} = utf8_at(value, index)
              codepoint

            {:ok, _count} ->
              rune_at_fallback(ctx, value, index)

            :error ->
              rune_at_fallback(ctx, value, index)
          end
        end

      true ->
        rune_at_fallback(ctx, value, index)
    end
  end

  def rune_tail(ctx, value, index) do
    cond do
      rune_nil?(ctx, value) ->
        rune_tail_fallback(ctx, value, index)

      is_binary(value) and is_integer(index) and index >= 0 ->
        ensure_rune_binary_list_limit!(ctx, value)

        if ascii_binary?(value) do
          if index <= byte_size(value) do
            tail = binary_part(value, index, byte_size(value) - index)
            checked_rune_binary_result!(ctx, tail, :characters_to_binary)
          else
            rune_tail_fallback(ctx, value, index)
          end
        else
          case utf8_count(value, 0) do
            {:ok, count} when index <= count ->
              {:ok, offset} = utf8_byte_offset(value, index)
              tail = binary_part(value, offset, byte_size(value) - offset)
              checked_rune_binary_result!(ctx, tail, :characters_to_binary)

            {:ok, _count} ->
              rune_tail_fallback(ctx, value, index)

            :error ->
              rune_tail_fallback(ctx, value, index)
          end
        end

      true ->
        rune_tail_fallback(ctx, value, index)
    end
  end

  def rune_slice(ctx, value, start_index, stop_index) do
    cond do
      rune_nil?(ctx, value) ->
        rune_slice_fallback(ctx, value, start_index, stop_index)

      is_binary(value) and is_integer(start_index) and is_integer(stop_index) and
        start_index >= 0 and stop_index >= start_index ->
        ensure_rune_binary_list_limit!(ctx, value)

        if ascii_binary?(value) do
          stop_index = min(stop_index, byte_size(value))

          if start_index <= stop_index do
            {:ok, start_index, stop_index}
          else
            :error
          end
        else
          case utf8_count(value, 0) do
            {:ok, count} ->
              stop_index = min(stop_index, count)
              utf8_slice_offsets(value, start_index, stop_index, count)

            :error ->
              :error
          end
        end
        |> case do
          {:ok, start_offset, stop_offset} ->
            slice = binary_part(value, start_offset, stop_offset - start_offset)
            checked_rune_binary_result!(ctx, slice, :characters_to_binary)

          :error ->
            rune_slice_fallback(ctx, value, start_index, stop_index)
        end

      true ->
        rune_slice_fallback(ctx, value, start_index, stop_index)
    end
  end

  defp checked_unicode_conversion(ctx, function, args) do
    case safe_unicode_conversion(ctx, function, args) do
      {:ok, value} ->
        value

      {:error, reason} ->
        :erlang.error({:sandbox, :stdlib_error, :unicode, function, stdlib_return_error(reason)})
    end
  end

  defp safe_unicode_conversion(ctx, :characters_to_binary = function, args) do
    args = normalize_unicode_args(args, ctx)

    :unicode
    |> :erlang.apply(function, args)
    |> check_unicode_binary_result(ctx)
  end

  defp safe_unicode_conversion(ctx, :characters_to_list = function, args) do
    args = normalize_unicode_args(args, ctx)

    case ascii_characters_to_list(args, ctx) do
      {:ok, value} ->
        {:ok, value}

      :fallback ->
        case unicode_result_size(function, args) do
          {:ok, size, :list} ->
            if size <= ctx.limits.max_list_length do
              {:ok, :erlang.apply(:unicode, function, args)}
            else
              {:error, :list_length}
            end

          :unknown ->
            {:ok, :erlang.apply(:unicode, function, args)}
        end
    end
  end

  defp safe_unicode_conversion(ctx, function, args) do
    args = normalize_unicode_args(args, ctx)
    {:ok, :erlang.apply(:unicode, function, args)}
  end

  defp ascii_characters_to_list([binary], ctx) when is_binary(binary),
    do: ascii_characters_to_list(binary, :utf8, ctx)

  defp ascii_characters_to_list([binary, encoding], ctx) when is_binary(binary),
    do: ascii_characters_to_list(binary, unicode_encoding_class(encoding), ctx)

  defp ascii_characters_to_list(_args, _ctx), do: :fallback

  defp ascii_characters_to_list(binary, encoding, ctx) when encoding in [:utf8, :latin1] do
    if ascii_binary?(binary) do
      with {:ok, size, :list} <- unicode_list_bound(binary, encoding),
           true <- size <= ctx.limits.max_list_length do
        {:ok, :binary.bin_to_list(binary)}
      else
        false -> {:error, :list_length}
        :unknown -> :fallback
      end
    else
      :fallback
    end
  end

  defp ascii_characters_to_list(_binary, _encoding, _ctx), do: :fallback

  defp check_unicode_binary_result(result, ctx) when is_binary(result) do
    if byte_size(result) <= ctx.limits.max_binary_bytes do
      {:ok, result}
    else
      {:error, :binary_bytes}
    end
  end

  defp check_unicode_binary_result(result, _ctx), do: {:ok, result}

  defp normalize_unicode_args([data], _ctx), do: [data]

  defp normalize_unicode_args([data, in_encoding], ctx),
    do: [data, normalize_unicode_encoding(in_encoding, ctx)]

  defp normalize_unicode_args([data, in_encoding, out_encoding], ctx),
    do: [
      data,
      normalize_unicode_encoding(in_encoding, ctx),
      normalize_unicode_encoding(out_encoding, ctx)
    ]

  defp normalize_unicode_args(args, _ctx), do: args

  defp normalize_unicode_encoding(value, ctx) when is_atom(value) do
    case safe_atom_name(value, ctx) do
      {:ok, "unicode"} -> :unicode
      {:ok, "utf8"} -> :utf8
      {:ok, "latin1"} -> :latin1
      {:ok, "utf16"} -> :utf16
      {:ok, "utf32"} -> :utf32
      {:ok, "big"} -> :big
      {:ok, "little"} -> :little
      {:ok, _other} -> value
    end
  end

  defp normalize_unicode_encoding({encoding, endian}, ctx),
    do: {normalize_unicode_encoding(encoding, ctx), normalize_unicode_encoding(endian, ctx)}

  defp normalize_unicode_encoding(value, _ctx), do: value

  defp unicode_result_size(:characters_to_list, [data]),
    do: unicode_list_bound(data, :unicode)

  defp unicode_result_size(:characters_to_list, [data, in_encoding]),
    do: unicode_list_bound(data, unicode_encoding_class(in_encoding))

  defp unicode_result_size(_function, _args), do: :unknown

  defp unicode_list_bound(data, in_encoding) do
    case unicode_chardata_list_bound(data, in_encoding, 0) do
      {:ok, size} -> {:ok, size, :list}
      :unknown -> :unknown
    end
  end

  defp unicode_chardata_list_bound(binary, in_encoding, size) when is_binary(binary),
    do: {:ok, size + unicode_binary_to_list_bound(binary, in_encoding)}

  defp unicode_chardata_list_bound(list, in_encoding, size) when is_list(list) do
    Enum.reduce_while(list, {:ok, size}, fn item, {:ok, size} ->
      case unicode_chardata_list_bound(item, in_encoding, size) do
        {:ok, size} -> {:cont, {:ok, size}}
        :unknown -> {:halt, :unknown}
      end
    end)
  end

  defp unicode_chardata_list_bound(codepoint, _in_encoding, size) when is_integer(codepoint),
    do: {:ok, size + 1}

  defp unicode_chardata_list_bound(_other, _in_encoding, _size), do: :unknown

  defp unicode_chardata_scalar_bound(binary, count) when is_binary(binary),
    do: {:ok, count + byte_size(binary)}

  defp unicode_chardata_scalar_bound(list, count) when is_list(list) do
    Enum.reduce_while(list, {:ok, count}, fn item, {:ok, count} ->
      case unicode_chardata_scalar_bound(item, count) do
        {:ok, count} -> {:cont, {:ok, count}}
        :unknown -> {:halt, :unknown}
      end
    end)
  end

  defp unicode_chardata_scalar_bound(codepoint, count) when is_integer(codepoint),
    do: {:ok, count + 1}

  defp unicode_chardata_scalar_bound(_other, _count), do: :unknown

  defp unicode_binary_to_list_bound(binary, :utf16), do: div(byte_size(binary) + 1, 2)
  defp unicode_binary_to_list_bound(binary, :utf32), do: div(byte_size(binary) + 3, 4)
  defp unicode_binary_to_list_bound(binary, _encoding), do: byte_size(binary)

  defp ensure_rune_binary_list_limit!(ctx, binary) do
    if unicode_binary_to_list_bound(binary, :unicode) <= ctx.limits.max_list_length do
      :ok
    else
      :erlang.error(
        {:sandbox, :stdlib_error, :unicode, :characters_to_list,
         stdlib_return_error(:list_length)}
      )
    end
  end

  defp checked_rune_binary_result!(ctx, binary, function) do
    case check_unicode_binary_result(binary, ctx) do
      {:ok, binary} ->
        binary

      {:error, reason} ->
        :erlang.error({:sandbox, :stdlib_error, :unicode, function, stdlib_return_error(reason)})
    end
  end

  defp rune_nil?(ctx, value) when is_atom(value),
    do: value == nil or Hyperlang.Terms.atom_source(value, ctx) == "nil"

  defp rune_nil?(_ctx, _value), do: false

  defp ascii_binary?(binary), do: :binary.match(binary, non_ascii_pattern()) == :nomatch

  defp non_ascii_pattern do
    case :persistent_term.get(@non_ascii_pattern_key, nil) do
      nil ->
        pattern = :binary.compile_pattern(@non_ascii_bytes)
        :persistent_term.put(@non_ascii_pattern_key, pattern)
        pattern

      pattern ->
        pattern
    end
  end

  defp rune_list_value(ctx, value) do
    cond do
      rune_nil?(ctx, value) -> []
      is_binary(value) -> unicode_characters_to_list(ctx, value)
      is_list(value) -> value
      true -> :erlang.error(:function_clause)
    end
  end

  defp rune_at_fallback(ctx, value, index),
    do: :lists.nth(index + 1, rune_list_value(ctx, value))

  defp rune_tail_fallback(ctx, value, index),
    do: unicode_characters_to_binary(ctx, :lists.nthtail(index, rune_list_value(ctx, value)))

  defp rune_slice_fallback(ctx, value, start_index, stop_index) do
    list = rune_list_value(ctx, value)

    unicode_characters_to_binary(
      ctx,
      :lists.sublist(list, start_index + 1, stop_index - start_index)
    )
  end

  defp utf8_count(<<>>, count), do: {:ok, count}

  defp utf8_count(<<_codepoint::utf8, rest::binary>>, count),
    do: utf8_count(rest, count + 1)

  defp utf8_count(_binary, _count), do: :error

  defp utf8_at(<<codepoint::utf8, _rest::binary>>, 0), do: {:ok, codepoint}

  defp utf8_at(<<_codepoint::utf8, rest::binary>>, index) when index > 0,
    do: utf8_at(rest, index - 1)

  defp utf8_at(_binary, _index), do: :error

  defp utf8_byte_offset(binary, target_index),
    do: utf8_byte_offset(binary, target_index, 0)

  defp utf8_byte_offset(_binary, 0, offset), do: {:ok, offset}

  defp utf8_byte_offset(<<codepoint::utf8, rest::binary>>, target_index, offset)
       when target_index > 0 do
    utf8_byte_offset(rest, target_index - 1, offset + utf8_codepoint_bytes(codepoint))
  end

  defp utf8_byte_offset(_binary, _target_index, _offset), do: :error

  defp utf8_slice_offsets(binary, start_index, _stop_index, count) when start_index > count,
    do: {:ok, byte_size(binary), byte_size(binary)}

  defp utf8_slice_offsets(binary, start_index, stop_index, _count) do
    with {:ok, start_offset} <- utf8_byte_offset(binary, start_index),
         {:ok, stop_offset} <- utf8_byte_offset(binary, stop_index) do
      {:ok, start_offset, stop_offset}
    end
  end

  defp utf8_codepoint_bytes(codepoint) when codepoint <= 0x7F, do: 1
  defp utf8_codepoint_bytes(codepoint) when codepoint <= 0x7FF, do: 2
  defp utf8_codepoint_bytes(codepoint) when codepoint <= 0xFFFF, do: 3
  defp utf8_codepoint_bytes(_codepoint), do: 4

  defp unicode_encoding_class({encoding, _endian}), do: unicode_encoding_class(encoding)
  defp unicode_encoding_class(encoding) when encoding in [:unicode, :utf8], do: :utf8
  defp unicode_encoding_class(:latin1), do: :latin1
  defp unicode_encoding_class(:utf16), do: :utf16
  defp unicode_encoding_class(:utf32), do: :utf32
  defp unicode_encoding_class(_encoding), do: :utf8

  defp safe_atom_to_binary([atom], ctx), do: safe_atom_to_binary([atom, :utf8], ctx)

  defp safe_atom_to_binary([atom, encoding], ctx) when is_atom(atom) and is_atom(encoding) do
    with {:ok, source} <- safe_atom_name(atom, ctx),
         {:ok, encoding} <- safe_atom_encoding(encoding, ctx) do
      encode_atom_name(source, encoding)
    end
  end

  defp safe_atom_to_binary(_args, _ctx), do: {:error, :badarg}

  defp guest_dictionary_entries(namespace) do
    guest_dictionary_index(namespace)
    |> Map.keys()
    |> Enum.reduce([], fn key, entries ->
      case dictionary_get(guest_dictionary_storage_key(namespace, key)) do
        {@guest_process_dictionary_value_tag, value} -> [{key, value} | entries]
        _other -> entries
      end
    end)
  end

  defp snapshot_guest_dictionary_with_dependencies do
    {legacy_entries, legacy_dependencies} = snapshot_guest_dictionary_namespace(nil)

    guest_dictionary_namespaces()
    |> Map.keys()
    |> Enum.reduce({legacy_entries, legacy_dependencies}, fn namespace, {entries, dependencies} ->
      {namespace_entries, namespace_dependencies} = snapshot_guest_dictionary_namespace(namespace)
      {entries ++ namespace_entries, Map.merge(dependencies, namespace_dependencies)}
    end)
  end

  defp snapshot_guest_dictionary_namespace(namespace) do
    dependency_index = guest_dictionary_dependency_index(namespace)

    namespace
    |> guest_dictionary_index()
    |> Map.keys()
    |> Enum.reduce({[], %{}}, fn key, {entries, dependencies} ->
      case dictionary_get(guest_dictionary_storage_key(namespace, key)) do
        {@guest_process_dictionary_value_tag, value} ->
          entry = {namespace, key, value}
          refs = guest_dictionary_entry_dependencies(dependency_index, key, value)
          {[entry | entries], Map.put(dependencies, {namespace, key}, refs)}

        _other ->
          {entries, dependencies}
      end
    end)
  end

  defp delete_guest_dictionary_entry(namespace, key, storage_key) do
    dictionary_erase(storage_key)
    delete_guest_dictionary_index_key(namespace, key)
    delete_guest_dictionary_dependency_key(namespace, key)
  end

  defp add_guest_dictionary_index_key(namespace, key) do
    index_key = guest_dictionary_index_key(namespace)
    index = guest_dictionary_index(namespace)
    dictionary_put(index_key, Map.put(index, key, true))
    add_guest_dictionary_namespace(namespace)
    :ok
  end

  defp delete_guest_dictionary_index_key(namespace, key) do
    index_key = guest_dictionary_index_key(namespace)
    updated = Map.delete(guest_dictionary_index(namespace), key)

    if map_size(updated) == 0 do
      dictionary_erase(index_key)
      delete_guest_dictionary_namespace(namespace)
    else
      dictionary_put(index_key, updated)
    end

    :ok
  end

  defp clear_guest_dictionary_namespace(namespace) do
    namespace
    |> guest_dictionary_index()
    |> Map.keys()
    |> Enum.each(fn key ->
      dictionary_erase(guest_dictionary_storage_key(namespace, key))
    end)

    dictionary_erase(guest_dictionary_index_key(namespace))
    dictionary_erase(guest_dictionary_dependency_index_key(namespace))
    delete_guest_dictionary_namespace(namespace)
    :ok
  end

  defp guest_dictionary_index(namespace) do
    case dictionary_get(guest_dictionary_index_key(namespace)) do
      %{} = index -> index
      _other -> %{}
    end
  end

  defp guest_dictionary_index_key(nil), do: @guest_process_dictionary_index_key

  defp guest_dictionary_index_key(namespace) when not is_nil(namespace),
    do: {@guest_process_dictionary_index_key, namespace}

  defp guest_dictionary_dependency_index(namespace) do
    case dictionary_get(guest_dictionary_dependency_index_key(namespace)) do
      %{} = index -> index
      _other -> %{}
    end
  end

  defp guest_dictionary_dependency_index_key(nil),
    do: @guest_process_dictionary_dependency_index_key

  defp guest_dictionary_dependency_index_key(namespace) when not is_nil(namespace),
    do: {@guest_process_dictionary_dependency_index_key, namespace}

  defp put_guest_dictionary_dependency_key(namespace, key, value) do
    case guest_dictionary_value_dependency_metadata(value) do
      :no_dependency_metadata ->
        delete_guest_dictionary_dependency_key(namespace, key)

      {:dependencies, refs} ->
        index_key = guest_dictionary_dependency_index_key(namespace)
        index = guest_dictionary_dependency_index(namespace)
        dictionary_put(index_key, Map.put(index, key, refs))
    end

    :ok
  end

  defp delete_guest_dictionary_dependency_key(namespace, key) do
    index_key = guest_dictionary_dependency_index_key(namespace)
    index = guest_dictionary_dependency_index(namespace)

    if Map.has_key?(index, key) do
      updated = Map.delete(index, key)

      if map_size(updated) == 0 do
        dictionary_erase(index_key)
      else
        dictionary_put(index_key, updated)
      end
    end

    :ok
  end

  defp guest_dictionary_storage_key(nil, key), do: {@guest_process_dictionary_value_tag, key}

  defp guest_dictionary_storage_key(namespace, key) when not is_nil(namespace),
    do: {@guest_process_dictionary_value_tag, namespace, key}

  defp guest_dictionary_namespace(%{guest_dictionary_namespace: namespace}), do: namespace

  defp guest_dictionary_namespace(_ctx), do: current_guest_dictionary_frame_id()

  defp guest_dictionary_namespaces do
    case dictionary_get(@guest_process_dictionary_namespaces_key) do
      %{} = namespaces -> namespaces
      _other -> %{}
    end
  end

  defp add_guest_dictionary_namespace(nil), do: :ok

  defp add_guest_dictionary_namespace(namespace) when not is_nil(namespace) do
    dictionary_put(
      @guest_process_dictionary_namespaces_key,
      Map.put(guest_dictionary_namespaces(), namespace, true)
    )

    :ok
  end

  defp delete_guest_dictionary_namespace(nil), do: :ok

  defp delete_guest_dictionary_namespace(namespace) when not is_nil(namespace) do
    updated = Map.delete(guest_dictionary_namespaces(), namespace)

    if map_size(updated) == 0 do
      dictionary_erase(@guest_process_dictionary_namespaces_key)
    else
      dictionary_put(@guest_process_dictionary_namespaces_key, updated)
    end

    :ok
  end

  defp guest_dictionary_value_dependencies(_namespace, _key, value),
    do: guest_dictionary_value_dependencies(value)

  defp guest_dictionary_entry_dependencies(dependencies, namespace, key, value) do
    case Map.fetch(dependencies, {namespace, key}) do
      {:ok, refs} -> refs
      :error -> guest_dictionary_value_dependencies(value)
    end
  end

  defp guest_dictionary_entry_dependencies(dependency_index, key, value) do
    case Map.fetch(dependency_index, key) do
      {:ok, refs} -> refs
      :error -> guest_dictionary_value_dependencies(value)
    end
  end

  defp guest_dictionary_value_dependencies(value) do
    case guest_dictionary_value_dependency_metadata(value) do
      :no_dependency_metadata -> []
      {:dependencies, refs} -> refs
    end
  end

  defp guest_dictionary_value_dependency_metadata(value) do
    if guest_dictionary_dependency_scalar?(value) do
      :no_dependency_metadata
    else
      {:dependencies, inspect_guest_dictionary_value_dependencies(value)}
    end
  end

  defp inspect_guest_dictionary_value_dependencies(value) do
    count_guest_dictionary_dependency_scan()

    value
    |> collect_guest_dictionary_ref_handles(MapSet.new())
    |> MapSet.to_list()
  end

  defp guest_dictionary_dependency_scalar?(value)
       when is_binary(value) or is_integer(value) or is_atom(value) or is_float(value),
       do: true

  defp guest_dictionary_dependency_scalar?(_value), do: false

  defp count_guest_dictionary_dependency_scan do
    case dictionary_get(@guest_process_dictionary_dependency_scan_count_key) do
      count when is_integer(count) ->
        dictionary_put(@guest_process_dictionary_dependency_scan_count_key, count + 1)

      _other ->
        :ok
    end
  end

  defp collect_guest_dictionary_ref_handles(term, refs) do
    cond do
      guest_dictionary_dependency_scalar?(term) ->
        refs

      guest_ref_handle_key?(term) ->
        MapSet.put(refs, term)

      is_map(term) ->
        Enum.reduce(term, refs, fn {key, value}, refs ->
          refs = collect_guest_dictionary_ref_handles(key, refs)
          collect_guest_dictionary_ref_handles(value, refs)
        end)

      is_tuple(term) ->
        term
        |> Tuple.to_list()
        |> Enum.reduce(refs, fn child, refs ->
          collect_guest_dictionary_ref_handles(child, refs)
        end)

      is_list(term) ->
        collect_guest_dictionary_ref_handles_list(term, refs)

      true ->
        refs
    end
  end

  defp collect_guest_dictionary_ref_handles_list([], refs), do: refs

  defp collect_guest_dictionary_ref_handles_list([head | tail], refs) do
    tail
    |> collect_guest_dictionary_ref_handles_list(collect_guest_dictionary_ref_handles(head, refs))
  end

  defp collect_guest_dictionary_ref_handles_list(tail, refs),
    do: collect_guest_dictionary_ref_handles(tail, refs)

  defp collect_reachable_guest_dictionary_refs(
         refs,
         handle_entries,
         dependencies,
         included,
         seen_handles
       ) do
    Enum.reduce(refs, {included, seen_handles}, fn handle, {included, seen_handles} ->
      collect_guest_ref_handle(handle, handle_entries, dependencies, included, seen_handles)
    end)
  end

  defp collect_guest_ref_handle(
         handle,
         handle_entries,
         dependencies,
         included,
         seen_handles
       ) do
    if MapSet.member?(seen_handles, handle) do
      {included, seen_handles}
    else
      seen_handles = MapSet.put(seen_handles, handle)

      handle_entries
      |> Map.get(handle, [])
      |> Enum.reduce({included, seen_handles}, fn {namespace, key, value} = entry,
                                                  {included, seen_handles} ->
        included = Map.put(included, {namespace, key}, entry)

        refs = guest_dictionary_entry_dependencies(dependencies, namespace, key, value)

        collect_reachable_guest_dictionary_refs(
          refs,
          handle_entries,
          dependencies,
          included,
          seen_handles
        )
      end)
    end
  end

  defp guest_ref_handle_key?({<<"h">>, id}) when is_integer(id), do: true
  defp guest_ref_handle_key?(_term), do: false

  defp dictionary_get(key), do: :erlang.get(key)
  defp dictionary_put(key, value), do: :erlang.put(key, value)
  defp dictionary_erase(key), do: :erlang.erase(key)

  defp safe_atom_name(atom, ctx) when is_atom(atom), do: {:ok, atom_name(atom, ctx)}

  defp atom_name(atom, ctx) when is_atom(atom),
    do: mapped_atom_source(atom, ctx) || Atom.to_string(atom)

  defp mapped_atom_source(atom, ctx) when is_atom(atom) do
    if Hyperlang.GeneratedAtoms.source_atom?(atom) do
      Hyperlang.Terms.atom_source(atom, ctx)
    end
  end

  defp safe_atom_encoding(encoding, ctx) when is_atom(encoding) do
    case safe_atom_name(encoding, ctx) do
      {:ok, encoding} when encoding in ["utf8", "unicode", "latin1"] -> {:ok, encoding}
      {:ok, _encoding} -> {:error, :badarg}
    end
  end

  defp encode_atom_name(source, encoding) when encoding in ["utf8", "unicode"], do: {:ok, source}

  defp encode_atom_name(source, "latin1") do
    case :unicode.characters_to_binary(source, :utf8, :latin1) do
      binary when is_binary(binary) -> {:ok, binary}
      {:error, _encoded, _rest} -> {:error, :badarg}
      {:incomplete, _encoded, _rest} -> {:error, :badarg}
    end
  end

  @io_lib_format_option_max_count 8

  defp safe_io_lib_format(ctx, function, args)
       when function in [:bformat, :bfwrite, :format, :fwrite] do
    with {:ok, args} <- normalize_io_lib_format_args(ctx, args),
         {:ok, result} <- do_io_lib_format(function, args),
         :ok <- check_io_lib_format_result(ctx, function, result) do
      {:ok, result}
    end
  end

  defp safe_io_lib_format(ctx, :build_text, args) do
    with {:ok, args} <- normalize_io_lib_build_text_args(ctx, args),
         {:ok, result} <- do_io_lib_format(:build_text, args),
         :ok <- check_io_lib_format_result(ctx, :build_text, result) do
      {:ok, result}
    end
  end

  defp normalize_io_lib_format_args(ctx, [format, args]) when is_list(args) do
    with {:ok, args} <- io_lib_public_args(ctx, args), do: {:ok, [format, args]}
  end

  defp normalize_io_lib_format_args(ctx, [format, args, options]) when is_list(args) do
    with {:ok, args} <- io_lib_public_args(ctx, args),
         {:ok, options} <- normalize_io_lib_format_options(options, ctx) do
      {:ok, [format, args, options]}
    end
  end

  defp normalize_io_lib_format_args(_ctx, _args), do: {:error, :badarg}

  defp normalize_io_lib_build_text_args(ctx, [format_list]) do
    with {:ok, format_list} <- io_lib_public_args(ctx, format_list), do: {:ok, [format_list]}
  end

  defp normalize_io_lib_build_text_args(ctx, [format_list, options]) do
    with {:ok, format_list} <- io_lib_public_args(ctx, format_list),
         {:ok, options} <- normalize_io_lib_format_options(options, ctx) do
      {:ok, [format_list, options]}
    end
  end

  defp normalize_io_lib_build_text_args(_ctx, _args), do: {:error, :badarg}

  # Guest `io_lib` text helpers format terms like captured stdout: a fun is
  # rejected (the stdlib argument walk admits the guest's own funs, and the
  # formatter would render their generated slot module), and pool atoms are
  # projected to their source names before the vendored formatter sees them.
  defp io_lib_public_args(ctx, terms) do
    case :hyperlang_msg.reject_forbidden_carriers(terms) do
      :ok -> {:ok, stdout_public_args(terms, ctx)}
      {:error, reason} -> {:error, %{category: :stdlib_args, reason: reason}}
    end
  end

  defp normalize_io_lib_format_options(options, ctx) when is_list(options) do
    normalize_io_lib_format_options(options, ctx, 0, [])
  end

  defp normalize_io_lib_format_options(_options, _ctx), do: {:error, :badarg}

  defp normalize_io_lib_format_options([], _ctx, _count, acc), do: {:ok, Enum.reverse(acc)}

  defp normalize_io_lib_format_options(_options, _ctx, count, _acc)
       when count >= @io_lib_format_option_max_count,
       do: {:error, :badarg}

  defp normalize_io_lib_format_options([option | rest], ctx, count, acc) do
    case normalize_io_lib_format_option(option, ctx) do
      {:ok, normalized} ->
        normalize_io_lib_format_options(rest, ctx, count + 1, [normalized | acc])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_io_lib_format_options(_improper, _ctx, _count, _acc), do: {:error, :badarg}

  defp normalize_io_lib_format_option({key, chars_limit}, ctx)
       when is_atom(key) and is_integer(chars_limit) and chars_limit >= -1 do
    case safe_atom_name(key, ctx) do
      {:ok, "chars_limit"} -> {:ok, {:chars_limit, chars_limit}}
      {:ok, _other} -> {:error, :badarg}
    end
  end

  defp normalize_io_lib_format_option(_option, _ctx), do: {:error, :badarg}

  defp do_io_lib_format(function, args) do
    {:ok, :erlang.apply(:hyperlang_otp_io_lib, function, args)}
  rescue
    _exception -> {:error, :badarg}
  catch
    _class, _reason -> {:error, :badarg}
  end

  defp check_io_lib_format_result(ctx, function, result)
       when function in [:bformat, :bfwrite] and is_binary(result) do
    if byte_size(result) <= ctx.limits.max_binary_bytes, do: :ok, else: {:error, :binary_bytes}
  end

  defp check_io_lib_format_result(ctx, function, result)
       when function in [:build_text, :format, :fwrite] and is_list(result) do
    case Hyperlang.Terms.sanitize_stdlib_return(result, ctx) do
      {:ok, _safe_result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_io_lib_format_result(_ctx, _function, _result), do: {:error, :badarg}

  defp io_lib_format_error(:badarg), do: :badarg
  defp io_lib_format_error(%{category: :stdlib_args} = reason), do: reason
  defp io_lib_format_error(reason), do: stdlib_return_error(reason)

  @float_format_option_max_count 8
  @float_format_decimals_max 253
  @float_format_scientific_max 249

  defp safe_float_format(ctx, function, [value]) do
    with {:ok, result} <- do_float_format(function, [value]),
         :ok <- check_float_format_result(ctx, function, result) do
      {:ok, result}
    end
  end

  defp safe_float_format(ctx, function, [value, options]) do
    with {:ok, options} <- normalize_float_format_options(options, ctx),
         {:ok, result} <- do_float_format(function, [value, options]),
         :ok <- check_float_format_result(ctx, function, result) do
      {:ok, result}
    end
  end

  defp safe_float_format(_ctx, _function, _args), do: {:error, :badarg}

  defp normalize_float_format_options(options, ctx) when is_list(options) do
    normalize_float_format_options(options, ctx, 0, [])
  end

  defp normalize_float_format_options(_options, _ctx), do: {:error, :badarg}

  defp normalize_float_format_options([], _ctx, _count, acc), do: {:ok, Enum.reverse(acc)}

  defp normalize_float_format_options(_options, _ctx, count, _acc)
       when count >= @float_format_option_max_count,
       do: {:error, :badarg}

  defp normalize_float_format_options([option | rest], ctx, count, acc) do
    case normalize_float_format_option(option, ctx) do
      {:ok, normalized} ->
        normalize_float_format_options(rest, ctx, count + 1, [normalized | acc])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_float_format_options(_improper, _ctx, _count, _acc), do: {:error, :badarg}

  defp normalize_float_format_option(option, ctx) when is_atom(option) do
    case safe_atom_name(option, ctx) do
      {:ok, "compact"} -> {:ok, :compact}
      {:ok, "short"} -> {:ok, :short}
      {:ok, _other} -> {:error, :badarg}
    end
  end

  defp normalize_float_format_option({key, precision}, ctx)
       when is_atom(key) and is_integer(precision) do
    case safe_atom_name(key, ctx) do
      {:ok, "decimals"}
      when precision >= 0 and precision <= @float_format_decimals_max ->
        {:ok, {:decimals, precision}}

      {:ok, "scientific"}
      when precision >= 0 and precision <= @float_format_scientific_max ->
        {:ok, {:scientific, precision}}

      {:ok, _other} ->
        {:error, :badarg}
    end
  end

  defp normalize_float_format_option(_option, _ctx), do: {:error, :badarg}

  defp do_float_format(function, args) do
    {:ok, :erlang.apply(:erlang, function, args)}
  rescue
    ArgumentError -> {:error, :badarg}
  end

  defp check_float_format_result(ctx, :float_to_binary, result) when is_binary(result) do
    if byte_size(result) <= ctx.limits.max_binary_bytes, do: :ok, else: {:error, :binary_bytes}
  end

  defp check_float_format_result(ctx, :float_to_list, result) when is_list(result) do
    if length(result) <= ctx.limits.max_list_length, do: :ok, else: {:error, :list_length}
  end

  defp check_float_format_result(_ctx, _function, _result), do: {:error, :badarg}

  defp float_format_error(:badarg), do: :badarg
  defp float_format_error(reason), do: stdlib_return_error(reason)

  defp re_with_match_limits({:run, [subject, pattern]}, ctx) do
    atom_pool = Map.get(ctx, :atom_pool, %{})

    with :ok <- check_regex_operand_size(ctx, subject),
         :ok <- check_regex_pattern_size(pattern, ctx) do
      {:ok, {:run, [subject, pattern, regex_limit_options([], atom_pool)]}}
    end
  end

  defp re_with_match_limits({:run, [subject, pattern, options]}, ctx) do
    atom_pool = Map.get(ctx, :atom_pool, %{})

    with :ok <- check_regex_operand_size(ctx, subject),
         :ok <- check_regex_pattern_size(pattern, ctx),
         {:ok, options} <- regex_run_options(options, atom_pool) do
      {:ok, {:run, [subject, pattern, options]}}
    end
  end

  defp re_with_match_limits({:split, [subject, pattern]}, ctx) do
    atom_pool = Map.get(ctx, :atom_pool, %{})

    with :ok <- check_regex_operand_size(ctx, subject),
         :ok <- check_regex_pattern_size(pattern, ctx) do
      {:ok, {:split, [subject, pattern, regex_limit_options([], atom_pool)]}}
    end
  end

  defp re_with_match_limits({:split, [subject, pattern, options]}, ctx) do
    atom_pool = Map.get(ctx, :atom_pool, %{})

    with :ok <- check_regex_operand_size(ctx, subject),
         :ok <- check_regex_pattern_size(pattern, ctx) do
      {:ok, {:split, [subject, pattern, regex_limit_options(options, atom_pool)]}}
    end
  end

  defp re_with_match_limits({:replace, [subject, pattern, replacement]}, ctx) do
    atom_pool = Map.get(ctx, :atom_pool, %{})

    with :ok <- check_regex_operand_size(ctx, subject),
         :ok <- check_regex_pattern_size(pattern, ctx),
         :ok <- check_regex_operand_size(ctx, replacement) do
      {:ok, {:replace, [subject, pattern, replacement, regex_limit_options([], atom_pool)]}}
    end
  end

  defp re_with_match_limits({:replace, [subject, pattern, replacement, options]}, ctx) do
    atom_pool = Map.get(ctx, :atom_pool, %{})

    with :ok <- check_regex_operand_size(ctx, subject),
         :ok <- check_regex_pattern_size(pattern, ctx),
         :ok <- check_regex_operand_size(ctx, replacement) do
      {:ok, {:replace, [subject, pattern, replacement, regex_limit_options(options, atom_pool)]}}
    end
  end

  defp re_with_match_limits({function, args}, _ctx), do: {:ok, {function, args}}

  @re_handle_max 256

  defp store_re_pattern(mp) do
    table = Process.get(@re_handle_key, %{})
    n = map_size(table) + 1

    if n > @re_handle_max do
      :erlang.error({:sandbox, :stdlib_error, :re, :compile, :re_pattern_table_full})
    end

    Process.put(@re_handle_key, Map.put(table, n, mp))
    {:re_pattern, n}
  end

  defp resolve_re_pattern_arg([subject, {:re_pattern, n} | rest]) when is_integer(n) do
    case Process.get(@re_handle_key, %{}) do
      %{^n => mp} -> {:ok, [subject, mp | rest]}
      _missing -> {:error, :invalid_re_pattern_handle}
    end
  end

  defp resolve_re_pattern_arg(args), do: {:ok, args}

  defp re_compile_bounded([pattern], ctx) do
    with :ok <- check_regex_pattern_size(pattern, ctx) do
      {:ok, [pattern]}
    end
  end

  defp re_compile_bounded([pattern, options], ctx) do
    with :ok <- check_regex_pattern_size(pattern, ctx) do
      {:ok, [pattern, options]}
    end
  end

  defp re_compile_bounded(_args, _ctx), do: {:error, :badarg}

  defp check_regex_pattern_size(pattern, ctx) do
    case safe_iolist_size(pattern) do
      {:ok, n} when n > ctx.limits.max_binary_bytes ->
        {:error, :binary_bytes}

      {:ok, n} when n <= @regex_pattern_max_bytes ->
        :ok

      {:ok, _n} ->
        {:error, :regex_pattern_too_large}

      :error ->
        :ok
    end
  end

  defp check_regex_operand_size(ctx, operand) do
    case safe_iolist_size(operand) do
      {:ok, n} when n <= ctx.limits.max_binary_bytes -> :ok
      {:ok, _n} -> {:error, :binary_bytes}
      :error -> :ok
    end
  end

  defp check_re_result(ctx, result), do: check_re_result(ctx, result, 0)

  defp check_re_result(ctx, _result, depth) when depth > ctx.limits.max_term_depth,
    do: {:error, stdlib_return_error(:term_depth)}

  defp check_re_result(ctx, result, _depth) when is_binary(result) do
    if byte_size(result) <= ctx.limits.max_binary_bytes,
      do: :ok,
      else: {:error, stdlib_return_error(:binary_bytes)}
  end

  defp check_re_result(_ctx, result, _depth)
       when is_integer(result) or is_float(result) or is_boolean(result) or is_nil(result),
       do: :ok

  defp check_re_result(_ctx, result, _depth)
       when result in [:match, :nomatch, :undefined],
       do: :ok

  defp check_re_result(ctx, result, depth) when is_tuple(result) do
    result
    |> Tuple.to_list()
    |> Enum.reduce_while(:ok, fn value, :ok ->
      case check_re_result(ctx, value, depth + 1) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp check_re_result(ctx, result, depth) when is_list(result) do
    if length(result) > ctx.limits.max_list_length do
      {:error, stdlib_return_error(:list_length)}
    else
      Enum.reduce_while(result, :ok, fn value, :ok ->
        case check_re_result(ctx, value, depth + 1) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp check_re_result(_ctx, _result, _depth),
    do: {:error, stdlib_return_error(:forbidden_term)}

  defp regex_run_options(options, atom_pool) when is_list(options) do
    if Enum.any?(options, &regex_all_names_capture_option?(&1, atom_pool)) do
      {:error, :unsupported_re_capture_all_names}
    else
      {:ok, regex_limit_options(options, atom_pool)}
    end
  end

  defp regex_run_options(options, atom_pool), do: {:ok, regex_limit_options(options, atom_pool)}

  defp regex_limit_options(options, atom_pool) when is_list(options) do
    options
    |> Enum.reject(&regex_limit_option?(&1, atom_pool))
    |> Kernel.++([
      {:match_limit, @regex_match_limit},
      {:match_limit_recursion, @regex_match_limit_recursion}
    ])
  end

  defp regex_limit_options(options, _atom_pool), do: options

  defp regex_limit_option?({key, _value}, atom_pool), do: regex_limit_option?(key, atom_pool)

  defp regex_limit_option?(key, atom_pool) when is_atom(key) do
    regex_option_name(key, atom_pool) in ["match_limit", "match_limit_recursion"]
  end

  defp regex_limit_option?(_option, _atom_pool), do: false

  defp regex_all_names_capture_option?({capture, target}, atom_pool),
    do: regex_capture_all_names?(capture, target, atom_pool)

  defp regex_all_names_capture_option?({capture, target, _type}, atom_pool),
    do: regex_capture_all_names?(capture, target, atom_pool)

  defp regex_all_names_capture_option?(_option, _atom_pool), do: false

  defp regex_capture_all_names?(capture, target, atom_pool),
    do:
      regex_option_name(capture, atom_pool) == "capture" and
        regex_option_name(target, atom_pool) == "all_names"

  defp regex_option_name(value, atom_pool) when is_atom(value),
    do: atom_name(value, atom_pool)

  defp regex_option_name(value, _atom_pool), do: value

  @stdout_key :"$hyperlang_stdout"

  def capture_io(ctx, function, args) when is_atom(function) and is_list(args) do
    with {:ok, rendered} <- render_io(ctx, function, args),
         :ok <- finish_captured_io(ctx, rendered) do
      :ok
    else
      {:error, reason} -> :erlang.error({:sandbox, :stdout_error, reason})
    end
  end

  def finish_output(ctx, result) do
    stdout = get_stdout()
    erase_stdout()

    with {:ok, safe_stdout} <- Hyperlang.Terms.sanitize_stdout(stdout, ctx) do
      {:ok, %{result: result, stdout: safe_stdout}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def finish_exit(ctx, status) do
    case finish_output(ctx, %{
           <<"stdout">> => <<>>,
           <<"stderr">> => <<>>,
           <<"status">> => status
         }) do
      {:ok, envelope} -> {:ok, Map.put(envelope, :exit_status, status)}
      {:error, reason} -> {:error, reason}
    end
  end

  def apply_guest_fun(ctx, fun, args) when is_function(fun) and is_list(args) do
    arity = length(args)

    cond do
      not safe_guest_fun?(ctx, fun) -> :erlang.error({:sandbox, :badfun, :provenance})
      not is_function(fun, arity) -> :erlang.error({:sandbox, :badfun_arity, arity})
      true -> :erlang.apply(fun, args)
    end
  end

  def apply_guest_fun(_ctx, value, args) when is_list(args) do
    :erlang.error({:sandbox, :badfun, safe_reason(value)})
  end

  defp safe_guest_fun?(%{slot_module: module, slot_version: version, token: token} = ctx, fun)
       when is_atom(module) and is_integer(version) and is_integer(token) do
    safe_stdlib_callback_fun?(ctx, fun) and
      Hyperlang.CodeServer.valid_slot?(module, version) and
      :erlang.fun_info(fun, :new_uniq) == {:new_uniq, module.module_info(:md5)} and
      Hyperlang.Terms.validate_runtime(ctx) == :ok
  rescue
    _ -> false
  end

  defp safe_guest_fun?(_, _), do: false

  defp render_io(ctx, :format, [format]), do: render_format(ctx, format, [])
  defp render_io(ctx, :format, [format, args]), do: render_format(ctx, format, args)

  defp render_io(ctx, :format, [device, format, args]),
    do: with_stdout_device(ctx, device, fn -> render_format(ctx, format, args) end)

  defp render_io(ctx, :fwrite, args), do: render_io(ctx, :format, args)

  defp render_io(ctx, :put_chars, [chars]), do: render_chars(ctx, chars)

  defp render_io(ctx, :put_chars, [device, chars]),
    do: with_stdout_device(ctx, device, fn -> render_chars(ctx, chars) end)

  defp render_io(_ctx, :nl, []), do: {:ok, "\n"}
  defp render_io(ctx, :nl, [device]), do: with_stdout_device(ctx, device, fn -> {:ok, "\n"} end)

  defp render_io(ctx, :write, [term]), do: render_format(ctx, "~p", [term])

  defp render_io(ctx, :write, [device, term]),
    do: with_stdout_device(ctx, device, fn -> render_format(ctx, "~p", [term]) end)

  defp render_io(_ctx, function, args), do: {:error, {:unsupported_io, function, length(args)}}

  defp with_stdout_device(_ctx, :standard_io, fun), do: fun.()

  defp with_stdout_device(ctx, device, fun) do
    cond do
      Hyperlang.Filesystem.guest_handle?(device) ->
        with {:ok, chunk} <- fun.() do
          {:ok, {:filesystem_device_write, device, chunk}}
        end

      host_filesystem_backend?(ctx) and host_io_device?(device) ->
        with {:ok, chunk} <- fun.() do
          {:ok, {:filesystem_device_write, host_io_device(device), chunk}}
        end

      true ->
        unsupported_io_device(ctx, device)
    end
  end

  defp host_io_device?(:standard_error), do: true
  defp host_io_device?(%{"$sys_fd" => fd}) when is_integer(fd) and fd >= 0, do: true
  defp host_io_device?(_device), do: false

  defp host_io_device(:standard_error), do: 2
  defp host_io_device(device), do: device

  defp unsupported_io_device(ctx, device) do
    reason =
      case Hyperlang.Terms.sanitize(device, ctx, :error) do
        {:ok, safe_device} -> safe_device
        {:error, _reason} -> safe_reason(device)
      end

    {:error, {:unsupported_io_device, reason}}
  end

  defp render_format(ctx, format, args) when is_list(args) do
    with {:ok, safe_format} <- Hyperlang.Terms.sanitize(format, ctx, :stdout),
         {:ok, safe_args} <- Hyperlang.Terms.sanitize(args, ctx, :stdout) do
      safe_format
      |> :hyperlang_otp_io_lib.format(stdout_public_args(safe_args, ctx))
      |> formatted_to_binary(safe_format)
    end
  rescue
    _exception -> {:error, %{exception: :stdout_exception, reason: :raised}}
  catch
    _class, _reason -> {:error, %{exception: :stdout_exception, reason: :caught}}
  end

  defp render_format(_ctx, _format, _args), do: {:error, :format_args_must_be_list}

  defp stdout_public_args(args, ctx), do: stdout_public_value(args, ctx)

  defp stdout_public_value(value, ctx) when is_atom(value),
    do: mapped_atom_source(value, ctx) || value

  defp stdout_public_value(value, ctx) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&stdout_public_value(&1, ctx))
    |> List.to_tuple()
  end

  defp stdout_public_value(value, ctx) when is_list(value) do
    if proper_list?(value) do
      Enum.map(value, &stdout_public_value(&1, ctx))
    else
      value
    end
  end

  defp stdout_public_value(value, ctx) when is_map(value) do
    Map.new(value, fn {key, item} ->
      {stdout_public_value(key, ctx), stdout_public_value(item, ctx)}
    end)
  end

  defp stdout_public_value(value, _ctx), do: value

  defp formatted_to_binary(chardata, format) do
    if unicode_format?(format) do
      chardata_to_binary(chardata)
    else
      iodata_or_chardata_to_binary(chardata)
    end
  end

  defp unicode_format?(format) do
    format
    |> IO.iodata_to_binary()
    |> :binary.match("~t")
    |> Kernel.!==(:nomatch)
  rescue
    _ -> false
  end

  defp iodata_or_chardata_to_binary(chardata) do
    {:ok, IO.iodata_to_binary(chardata)}
  rescue
    ArgumentError -> chardata_to_binary(chardata)
  end

  defp chardata_to_binary(chardata) do
    case :unicode.characters_to_binary(chardata) do
      binary when is_binary(binary) -> {:ok, binary}
      {:error, _encoded, _rest} -> {:error, :invalid_chardata}
      {:incomplete, _encoded, _rest} -> {:error, :incomplete_chardata}
    end
  end

  defp render_chars(ctx, chars) do
    with {:ok, safe_chars} <- Hyperlang.Terms.sanitize(chars, ctx, :stdout) do
      chardata_to_binary(safe_chars)
    end
  rescue
    _exception -> {:error, %{exception: :stdout_exception, reason: :raised}}
  catch
    _class, _reason -> {:error, %{exception: :stdout_exception, reason: :caught}}
  end

  defp finish_captured_io(ctx, chunk) when is_binary(chunk) do
    if host_filesystem_backend?(ctx) do
      # Host backend: io output is real output — it goes to the process's
      # fd 1 through the same syscall facade, not to the capture buffer.
      host_device_write(ctx, 1, chunk)
    else
      append_stdout(ctx, chunk)
    end
  end

  defp finish_captured_io(ctx, {:filesystem_device_write, device, chunk}) when is_binary(chunk) do
    case dispatch_filesystem(ctx, :handle_write, [device, chunk]) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, {:filesystem_device_write_failed, reason}}
      {:error, reason} -> {:error, {:filesystem_device_write_failed, reason}}
    end
  end

  defp finish_captured_io(_ctx, _rendered), do: {:error, :invalid_io_render}

  defp host_device_write(ctx, fd, chunk) do
    # The io path enters the door here, so this is its one sanitize pass
    # (HostBackend rides the raw door).
    handle = Hyperlang.Filesystem.HostBackend.handle(fd, true, false)

    try do
      with {:ok, [safe_chunk]} <- Hyperlang.Terms.sanitize_filesystem_args([chunk], ctx),
           {:ok, :ok} <-
             Hyperlang.Filesystem.HostBackend.dispatch(ctx, :write, [handle, safe_chunk]) do
        :ok
      else
        {:ok, {:error, reason}} -> {:error, {:host_io_write_failed, reason}}
        {:error, reason} -> {:error, {:host_io_write_failed, reason}}
      end
    after
      Hyperlang.Filesystem.HostBackend.release_handle(handle)
    end
  end

  defp append_stdout(ctx, chunk) when is_binary(chunk) do
    limits = ctx.limits
    chunks = Process.get(@stdout_key, [])

    cond do
      byte_size(chunk) > limits.max_stdout_chunk_bytes ->
        {:error, :stdout_chunk_bytes}

      length(chunks) + 1 > limits.max_stdout_chunks ->
        {:error, :stdout_chunks}

      stdout_bytes(chunks) + byte_size(chunk) > limits.max_stdout_bytes ->
        {:error, :stdout_bytes}

      true ->
        Process.put(@stdout_key, [chunk | chunks])
        :ok
    end
  end

  defp get_stdout, do: Process.get(@stdout_key, []) |> Enum.reverse()
  defp erase_stdout, do: Process.delete(@stdout_key)

  defp stdout_bytes(chunks),
    do: Enum.reduce(chunks, 0, fn chunk, acc -> acc + byte_size(chunk) end)

  defp filesystem_handle(%{filesystem: %Hyperlang.Filesystem.Handle{} = handle}),
    do: {:ok, handle}

  defp filesystem_handle(_ctx), do: {:error, :filesystem_not_attached}

  # One static call shape per binding call: the module and function were
  # pinned by the program manifest, the state by the run spec.
  defp invoke_binding(module, state, function, args) do
    {:ok, Hyperlang.Scope.blocking(fn -> module.call(state, function, args) end)}
  rescue
    exception ->
      {:error,
       %{
         exception: :import_exception,
         reason: :raised,
         message: Exception.message(exception)
       }}
  catch
    :throw, {:hyperlang_scope_busy, _} = fault -> throw(fault)
    _class, _reason -> {:error, %{exception: :import_exception, reason: :caught}}
  end

  defp safe_reason(reason), do: safe_reason(reason, nil)

  defp safe_reason(reason, _runtime_or_ctx)
       when is_atom(reason) or is_binary(reason) or is_number(reason),
       do: reason

  defp safe_reason(reason, _runtime_or_ctx)
       when is_pid(reason) or is_port(reason) or is_reference(reason) or is_function(reason),
       do: :forbidden_term

  defp safe_reason(reason, runtime_or_ctx) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.map(&safe_reason(&1, runtime_or_ctx))
  end

  defp safe_reason(reason, runtime_or_ctx) when is_list(reason) do
    if proper_list?(reason),
      do: Enum.map(reason, &safe_reason(&1, runtime_or_ctx)),
      else: :improper_error_list
  end

  defp safe_reason(%{__struct__: module} = reason, runtime_or_ctx) do
    %{
      exception: module,
      message: guest_exception_message(reason, runtime_or_ctx)
    }
  end

  defp safe_reason(reason, runtime_or_ctx) when is_map(reason) do
    Map.new(reason, fn {key, value} ->
      {safe_error_key(key, runtime_or_ctx), safe_reason(value, runtime_or_ctx)}
    end)
  end

  defp safe_reason(_reason, _runtime_or_ctx), do: :unsafe_error_term

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_), do: false

  defp printable_charlist?(value) do
    if is_list(value) do
      try do
        case :unicode.characters_to_binary(value) do
          binary when is_binary(binary) -> true
          _other -> false
        end
      rescue
        _exception -> false
      catch
        _class, _reason -> false
      end
    else
      false
    end
  end

  defp safe_error_key(key, _runtime_or_ctx) when is_atom(key) or is_binary(key), do: key
  defp safe_error_key(key, runtime_or_ctx), do: safe_reason(key, runtime_or_ctx)

  # Exception messages are guest-visible text. OTP and Elixir render them from
  # raw host terms, so a message can embed generated slot modules and helper
  # names (inside fun inspections), pooled atom names and host-only terms. A
  # function-clause message names the failing function only when it is a guest
  # function (through the stack map) or a guest-callable stdlib MFA; every other
  # message is projected through `guest_text/2`.
  defp guest_exception_message(
         %FunctionClauseError{module: module, function: function, arity: arity},
         runtime_or_ctx
       ) do
    "no function clause matching in " <> guest_mfa_text(module, function, arity, runtime_or_ctx)
  end

  defp guest_exception_message(exception, runtime_or_ctx) do
    exception
    |> Exception.message()
    |> guest_text(runtime_or_ctx)
  rescue
    _ -> nil
  end

  defp guest_mfa_text(module, function, arity, runtime_or_ctx)
       when is_atom(module) and is_atom(function) and is_integer(arity) do
    cond do
      generated_module?(module) ->
        case guest_function_meta(function, runtime_or_ctx) do
          %{} = meta ->
            "guest:#{Map.get(meta, :function, "unknown")}/#{Map.get(meta, :arity, arity)}"

          nil ->
            "a guest function"
        end

      guest_stdlib_mfa?(module, function, arity) ->
        "#{module}:#{function}/#{arity}"

      true ->
        "an internal function"
    end
  end

  defp guest_mfa_text(_module, _function, _arity, _runtime_or_ctx), do: "an internal function"

  # Generated helpers keep their `safe_f_N` root inside compiler-made names
  # such as `-safe_f_0/2-fun-0-`. A lifted fun, comprehension or receive has
  # its own root, mapped to a name such as `-loop/1-fun-0-`.
  defp guest_function_meta(function, runtime_or_ctx) do
    case Regex.run(~r/safe_f_\d+/, to_string(function)) do
      [root] ->
        Enum.find_value(stack_map(runtime_or_ctx), fn {key, meta} ->
          Atom.to_string(key) == root && meta
        end)

      nil ->
        nil
    end
  end

  defp guest_stdlib_mfa?(module, function, arity),
    do: Hyperlang.Stdlib.call_target(module, function, arity) != :error

  # Guest projection of host-rendered text. The rewritten tokens are exactly the
  # names Hyperlang itself mints (pool atoms, generated slot modules and helper
  # functions, internal entrypoints) and the inspected forms of terms a guest
  # may never observe (funs, pids, refs, ports). Pool atoms map back to their
  # source names; generated helpers map to their guest function names.
  defp guest_text(text, runtime_or_ctx) do
    text
    |> String.replace(~r/#Fun(ction)?<[^>]*>/, "#Fun\\1<guest>")
    |> String.replace(~r/#(PID|Port|Reference)<[^>]*>/, "#\\1<redacted>")
    |> then(
      &Regex.replace(~r/(:?)\bhyperlang_(?:kernel_)?atom_\d+\b/, &1, fn token, colon ->
        guest_atom_text(colon, String.trim_leading(token, ":"), runtime_or_ctx)
      end)
    )
    |> String.replace(~r/\bhyperlang_(slot_\d+|pending_slot|pending_version)\b/, "guest")
    |> guest_helper_text(stack_map(runtime_or_ctx))
    |> String.replace(~r/"?\$(safe_entry|safe_export|hyperlang_msg)"?/, "guest")
    |> String.replace(~r/\bsafe_snapshot_apply\b/, "guest")
  end

  # `safe_f_N` and `safe_f_N/A` become the guest source name and source arity.
  # A compiler-made name around a lifted root (`-safe_f_9/2-fun-0-`) becomes
  # the lifted construct's name as a whole.
  defp guest_helper_text(text, stack_map) do
    ~r/(-?)safe_f_\d+(\/\d+)?((?:-(?:fun|lc\$\^\d+\/\d+|lbc\$\^\d+\/\d+)-\d+-)?)/
    |> Regex.replace(text, fn token, dash, arity_suffix, compiler_suffix ->
      case guest_function_meta(token, %{stack_map: stack_map}) do
        %{lifted: true, function: function} when dash != "" and compiler_suffix != "" ->
          function

        %{lifted: true, function: function} ->
          dash <> function <> compiler_suffix

        %{} = meta when arity_suffix == "" ->
          dash <> Map.get(meta, :function, "guest_function") <> compiler_suffix

        %{} = meta ->
          dash <>
            "#{Map.get(meta, :function, "guest_function")}/#{Map.get(meta, :arity)}" <>
            compiler_suffix

        nil ->
          dash <> "guest_function" <> compiler_suffix
      end
    end)
  end

  defp guest_atom_text(colon, name, runtime_or_ctx) do
    source =
      case existing_atom(name) do
        {:ok, atom} -> Hyperlang.Terms.atom_source(atom, runtime_or_ctx)
        :error -> nil
      end

    cond do
      not is_binary(source) or Hyperlang.Manifest.reserved_internal_name?(source) ->
        colon <> "redacted"

      colon == "" ->
        source

      Regex.match?(~r/^[a-z_][a-zA-Z0-9_@]*[?!]?$/, source) ->
        ":" <> source

      true ->
        ":" <> inspect(source)
    end
  end

  defp error_category({:sandbox, :import_error, _call, _reason}), do: :import
  defp error_category({:sandbox, :unknown_import, _import_name}), do: :import
  defp error_category({:sandbox, :stdout_error, _reason}), do: :stdout
  defp error_category({:sandbox, :filesystem_error, _reason}), do: :filesystem
  defp error_category({:sandbox, :table_error, _reason}), do: :runtime
  defp error_category({:sandbox, :module_error, _reason}), do: :module
  defp error_category({:sandbox, :stdlib_error, _module, _function, _reason}), do: :stdlib
  defp error_category(_reason), do: :runtime

  defp error_reason({:sandbox, :import_error, _call, _reason}, _rc), do: :import_error
  defp error_reason({:sandbox, :unknown_import, _import_name}, _rc), do: :unknown_import
  defp error_reason({:sandbox, :stdout_error, _reason}, _rc), do: :stdout_error
  defp error_reason({:sandbox, :filesystem_error, _reason}, _rc), do: :filesystem_error
  defp error_reason({:sandbox, :table_error, _reason}, _rc), do: :table_error

  defp error_reason({:sandbox, :module_error, reason}, _rc) when is_atom(reason), do: reason
  defp error_reason({:sandbox, :module_error, _reason}, _rc), do: :module_error

  defp error_reason({:sandbox, :stdlib_error, _module, _function, _reason}, _rc),
    do: :stdlib_error

  defp error_reason(reason, runtime_or_ctx), do: safe_reason(reason, runtime_or_ctx)

  defp error_details({:sandbox, :import_error, call, reason}) do
    %{import: call, error: safe_reason(reason)}
  end

  defp error_details({:sandbox, :unknown_import, import_name}) do
    %{import: import_name}
  end

  defp error_details({:sandbox, :stdout_error, reason}) do
    %{error: safe_reason(reason)}
  end

  defp error_details({:sandbox, :filesystem_error, reason}) do
    %{error: safe_reason(reason)}
  end

  defp error_details({:sandbox, :module_error, reason}) do
    %{error: safe_reason(reason)}
  end

  defp error_details({:sandbox, :stdlib_error, module, function, reason}) do
    %{module: module, function: function, error: safe_reason(reason)}
  end

  defp error_details(_reason), do: nil

  defp stack_map(%{stack_map: map}) when is_map(map), do: map
  defp stack_map(_), do: %{}

  defp trim_stack(stack, stack_map) when is_list(stack) do
    stack
    |> Enum.reduce([], fn frame, acc ->
      case trim_frame(frame, stack_map) do
        nil -> acc
        safe_frame -> [safe_frame | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.take(8)
  end

  defp trim_stack(_, _), do: []

  # Positive rule: a frame survives only as a mapped guest source frame or as a
  # call into the guest-callable stdlib surface. Every other frame (Hyperlang
  # runtime modules under any naming scheme, vendored formatters, OTP internals,
  # unmapped generated helpers) is dropped.
  defp trim_frame({module, function, arity, _info}, stack_map) do
    arity = safe_arity(arity)

    cond do
      generated_module?(module) and Map.has_key?(stack_map, function) ->
        source_frame(Map.fetch!(stack_map, function))

      generated_module?(module) ->
        case guest_function_meta(function, %{stack_map: stack_map}) do
          %{lifted: true} = meta ->
            source_frame(meta)

          %{} = meta ->
            meta
            |> source_frame()
            |> Map.put(:function, guest_helper_text(Atom.to_string(function), stack_map))

          nil ->
            nil
        end

      is_atom(module) and is_atom(function) and is_integer(arity) and
          guest_stdlib_mfa?(module, function, arity) ->
        %{module: Atom.to_string(module), function: Atom.to_string(function), arity: arity}

      true ->
        nil
    end
  end

  defp trim_frame({module, function, arity}, stack_map),
    do: trim_frame({module, function, arity, []}, stack_map)

  defp trim_frame(_other, _stack_map), do: nil

  defp source_frame(meta) do
    %{
      module: "guest",
      function: Map.get(meta, :function, "unknown"),
      arity: Map.get(meta, :arity)
    }
    |> maybe_put(:span, Map.get(meta, :span))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp generated_module?(module) do
    module
    |> to_string()
    |> String.starts_with?("hyperlang_slot_")
  end

  defp safe_arity(arity) when is_integer(arity), do: arity
  defp safe_arity(args) when is_list(args), do: length(args)
  defp safe_arity(_other), do: nil
end
