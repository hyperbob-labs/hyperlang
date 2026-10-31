defmodule Hyperlang.Codegen do
  @moduledoc false

  alias Hyperlang.{Core, FormTools, Manifest}

  @runtime Hyperlang.Runtime
  @table_runtime Hyperlang.Table
  @msg_runtime :hyperlang_msg
  @sys_facade Hyperlang.Sys
  @entry :"$safe_entry"
  @export :"$safe_export"
  @raw_export :"$safe_raw_export"
  @pending_version :hyperlang_pending_version
  @constant_tuple_tag :"$hyperlang_constant_tuple"
  @snapshot_apply :safe_snapshot_apply
  @lc_append :safe_lc_append
  @lift_key {__MODULE__, :lift}
  @guest_process_dictionary_frame_key :"$hyperlang_guest_process_dictionary_frame"
  @guest_process_dictionary_namespaces_key :"$hyperlang_guest_process_dictionary_namespaces"
  @guest_process_dictionary_index_key :"$hyperlang_guest_process_dictionary_index"
  @guest_process_dictionary_value_tag :"$hyperlang_guest_process_dictionary_value"
  @segment_modifiers %{
    "integer" => :integer,
    "float" => :float,
    "binary" => :binary,
    "bytes" => :bytes,
    "bitstring" => :bitstring,
    "bits" => :bits,
    "utf8" => :utf8,
    "utf16" => :utf16,
    "utf32" => :utf32,
    "signed" => :signed,
    "unsigned" => :unsigned,
    "big" => :big,
    "little" => :little,
    "native" => :native
  }

  def to_forms(%{core: %Core{} = core}, manifest) do
    to_forms(core, manifest)
  end

  def to_forms(%Core{} = core, manifest) do
    try do
      module = :hyperlang_pending_slot
      {forms, lifted_meta} = generate(module, core, manifest)

      with :ok <- verify_generated_forms(forms),
           :ok <- verify_pattern_splits(forms, lifted_meta, core, manifest) do
        guest_dictionary_used? = guest_dictionary_used?(core)
        host_boundary_used? = host_boundary_used?(core)

        {:ok, forms,
         %{
           generated_exports: [
             @entry,
             @export,
             @raw_export
           ],
           helper_count: map_size(core.functions),
           atom_pool_size: atom_pool_size(core),
           guest_dictionary_used?: guest_dictionary_used?,
           host_boundary_used?: host_boundary_used?,
           direct_readonly_safe?: not guest_dictionary_used? and not host_boundary_used?,
           source_contract: Map.get(core.metadata, :source_contract),
           exports: Map.get(core.metadata, :exports, %{functions: %{}, files: []}),
           stack_map: Map.merge(stack_map(core), lifted_meta),
           stdlib_profile: manifest.stdlib
         }
         |> Map.merge(core_module_metadata(core))}
      end
    rescue
      # Generated-atom pool exhaustion is a throw handled at the compile
      # worker boundary; this catches the remaining bad-argument failures.
      e in ArgumentError ->
        {:error,
         Hyperlang.Error.new(:codegen, "code generation failed",
           details: %{message: Exception.message(e)}
         )}
    end
  end

  @doc false
  def options_hash do
    %{
      guest_dictionary_frame_namespace: 1,
      entry_input_runtime_sanitizer: 1,
      resident_export_removed: 1,
      resident_raw_entry_removed: 1,
      resident_raw_export_removed: 1,
      native_gen_server_removed: 1,
      guest_dictionary_process_only: 1,
      guest_fun_opaque_apply: 1,
      typed_newchan_classification: 1,
      native_send_receive_lowering: 5,
      native_exit_timer_lowering: 1,
      host_actor_status: 1,
      snapshot_apply_dispatcher: 1,
      lifted_compiler_named_constructs: 1,
      record_lowering: 1,
      total_function_clauses: 1,
      single_export_thunk: 1
    }
  end

  def forms_for(module, core, manifest), do: module |> generate(core, manifest) |> elem(0)

  # One generation run. Every construct the OTP compiler names after its
  # enclosing function (funs, comprehensions, receive wait funs) is lifted
  # into its own `safe_f_N/2` function while the guest functions compile; the
  # lift state lives in the process dictionary for the run only, so a
  # construct nested anywhere in an expression registers its function no
  # matter which path discards the expression env.
  defp generate(module, core, manifest) do
    previous = Process.put(@lift_key, new_lift_state(core))

    try do
      base = [
        FormTools.module_attribute(module),
        FormTools.export_attribute([{@entry, 3}, {@export, 4}, {@raw_export, 3}]),
        entry_function(core),
        export_function(core, manifest),
        raw_export_function(core, manifest)
      ]

      helpers = helper_functions(core, manifest)
      state = Process.get(@lift_key)

      forms =
        (base ++ helpers ++ Enum.reverse(state.functions) ++ lc_append_function(state))
        |> Enum.map(&close_function_clauses/1)

      {forms, state.meta}
    after
      if previous == nil,
        do: Process.delete(@lift_key),
        else: Process.put(@lift_key, previous)
    end
  end

  def replace_module(forms, module),
    do: replace_module_and_version(forms, module, @pending_version)

  def replace_module_and_version(forms, module, version) do
    Enum.map(forms, fn
      {:attribute, anno, :module, _} -> {:attribute, anno, :module, module}
      form -> replace_pending_version(form, version)
    end)
  end

  defp core_module_metadata(%Core{metadata: %{module_metadata: meta}}) when is_map(meta),
    do: %{module_metadata: meta}

  defp core_module_metadata(_core), do: %{}

  defp stack_map(%Core{} = core) do
    base =
      core.functions
      |> Map.values()
      |> Map.new(fn fun ->
        {fun.safe_name,
         %{
           function: fun.source_name,
           arity: fun.arity,
           span: fun.span
         }}
      end)
      |> Map.put(@export, %{
        function: "$safe_export",
        arity: 4,
        span: nil
      })
      |> Map.put(@raw_export, %{
        function: "$safe_raw_export",
        arity: 3,
        span: nil
      })

    case core.result do
      nil ->
        Map.put(base, @entry, %{
          function: "$safe_entry",
          arity: 3,
          span: nil
        })

      result ->
        Map.put(base, @entry, %{
          function: result.source_name,
          arity: result.arity,
          span: Map.get(result, :span)
        })
    end
  end

  defp entry_function(%Core{result: nil}) do
    token = var(:token)
    runtime = var(:runtime)
    ctx = var(:ctx)
    err = var(:err)

    new_ctx = remote_call(@runtime, :new_context, [token, runtime, atom(@pending_version)])

    no_result_error =
      abstract_term({:error, %{category: :eval, reason: :no_result_export_only_program}})

    sanitize_eval_error = remote_call(@runtime, :safe_export, [ctx, thunk(no_result_error)])
    sanitize_runtime_error = remote_call(@runtime, :safe_export, [runtime, thunk(err)])

    body =
      {:case, 0, new_ctx,
       [
         {:clause, 0, [tuple([atom(:ok), ctx])], [], [sanitize_eval_error]},
         {:clause, 0, [err], [], [sanitize_runtime_error]}
       ]}

    {:function, 0, @entry, 3, [{:clause, 0, [token, var(:_), runtime], [], [body]}]}
  end

  defp entry_function(core) do
    token = var(:token)
    input = var(:input)
    runtime = var(:runtime)
    ctx = var(:ctx)
    safe_input = var(:safe_input)
    err = var(:err)

    new_ctx = remote_call(@runtime, :new_context, [token, runtime, atom(@pending_version)])
    sanitize_input = remote_call(@runtime, :entry_input, [ctx, input])
    # The generated guest function always takes the safe `ctx` as its leading
    # argument. An arity-1 result root is `name(ctx, Input)`. An arity-2 result
    # root is an Inferno command entry `init(ctx, Ctxt, Argv)`: the host supplies
    # `Ctxt = nil` (console context) and threads the sanitized eval input in as
    # the `Argv` argument, so a single host input still drives the guest.
    result_args =
      case core.result.arity do
        2 -> [ctx, atom(nil), safe_input]
        _ -> [ctx, safe_input]
      end

    result_call = {:call, 0, {:atom, 0, core.result.safe_name}, result_args}
    finish_output = remote_call(@runtime, :finish_output, [ctx, result_call])

    body =
      {:case, 0, new_ctx,
       [
         {:clause, 0, [tuple([atom(:ok), ctx])], [],
          [
            {:case, 0, sanitize_input,
             [
               {:clause, 0, [tuple([atom(:ok), safe_input])], [], [finish_output]},
               {:clause, 0, [err], [], [err]}
             ]}
          ]},
         {:clause, 0, [err], [], [err]}
       ]}

    {:function, 0, @entry, 3, [{:clause, 0, [token, input, runtime], [], [body]}]}
  end

  defp export_function(%Core{} = core, manifest) do
    token = var(:token)
    export_id = var(:export_id)
    args = var(:args)
    runtime = var(:runtime)
    ctx = var(:ctx)
    safe_args = var(:safe_args)
    err = var(:err)

    new_ctx = remote_call(@runtime, :new_context, [token, runtime, atom(@pending_version)])
    sanitize_args = remote_call(@runtime, :export_args, [ctx, export_id, args])
    dispatch = export_dispatch_case(core, manifest, ctx, export_id, safe_args)
    sanitize_ctx_error = remote_call(@runtime, :safe_export, [ctx, thunk(err)])
    sanitize_runtime_error = remote_call(@runtime, :safe_export, [runtime, thunk(err)])

    body =
      {:case, 0, new_ctx,
       [
         {:clause, 0, [tuple([atom(:ok), ctx])], [],
          [
            {:case, 0, sanitize_args,
             [
               {:clause, 0, [tuple([atom(:ok), safe_args])], [], [dispatch]},
               {:clause, 0, [err], [], [sanitize_ctx_error]}
             ]}
          ]},
         {:clause, 0, [err], [], [sanitize_runtime_error]}
       ]}

    {:function, 0, @export, 4, [{:clause, 0, [token, export_id, args, runtime], [], [body]}]}
  end

  defp raw_export_function(%Core{} = core, manifest) do
    ctx = var(:ctx)
    export_id = var(:export_id)
    args = var(:args)
    body = raw_export_dispatch_case(core, manifest, ctx, export_id, args)

    {:function, 0, @raw_export, 3, [{:clause, 0, [ctx, export_id, args], [], [body]}]}
  end

  # One thunk around the whole dispatch: the OTP compiler names each fun after
  # `$safe_export/4` and a counter, so a thunk per export would make that
  # name set grow with the export count.
  defp export_dispatch_case(%Core{} = core, manifest, ctx, export_id, safe_args) do
    clauses =
      core
      |> callable_exports(manifest)
      |> Enum.sort_by(fn {id, _export} -> id end)
      |> Enum.map(fn {id, export} ->
        fun = Map.fetch!(core.functions, {export.function, export.arity})
        args = export_arg_vars(export.arity)
        call = {:call, 0, {:atom, 0, fun.safe_name}, [ctx | args]}
        finish = remote_call(@runtime, :finish_output, [ctx, call])

        {:clause, 0, [tuple([abstract_term(id), list(args)])], [], [finish]}
      end)
      |> Kernel.++([
        {:clause, 0, [var(:_)], [],
         [abstract_term({:error, %{category: :export, reason: :unknown_export}})]}
      ])

    remote_call(@runtime, :safe_export, [
      ctx,
      thunk({:case, 0, tuple([export_id, safe_args]), clauses})
    ])
  end

  defp raw_export_dispatch_case(%Core{} = core, manifest, ctx, export_id, args_value) do
    clauses =
      core
      |> callable_exports(manifest)
      |> Enum.sort_by(fn {id, _export} -> id end)
      |> Enum.map(fn {id, export} ->
        fun = Map.fetch!(core.functions, {export.function, export.arity})
        args = export_arg_vars(export.arity)
        call = {:call, 0, {:atom, 0, fun.safe_name}, [ctx | args]}

        {:clause, 0, [tuple([abstract_term(id), list(args)])], [], [call]}
      end)
      |> Kernel.++([
        {:clause, 0, [var(:_)], [], [remote_call(:erlang, :error, [atom(:undef)])]}
      ])

    {:case, 0, tuple([export_id, args_value]), clauses}
  end

  defp callable_exports(%Core{} = core, manifest) do
    exports = Map.get(core.metadata, :exports, %{functions: %{}, files: []})

    function_exports =
      Map.merge(Map.get(exports, :functions, %{}), manifest.exports.functions)
      |> Enum.map(fn {id, export} -> {id, export} end)

    file_exports =
      exports
      |> Map.get(:files, [])
      |> Enum.filter(&callable_file_export?/1)
      |> Enum.map(fn file -> {Manifest.file_export_id(file), file} end)

    dependency_exports =
      exports
      |> Map.get(:files, [])
      |> Enum.flat_map(fn file ->
        case Manifest.file_dependency_export(file) do
          {:ok, id, export} -> [{id, export}]
          :none -> []
        end
      end)

    function_exports ++ file_exports ++ dependency_exports
  end

  defp callable_file_export?(%{function: function, arity: arity})
       when is_binary(function) and is_integer(arity),
       do: true

  defp callable_file_export?(_file), do: false

  defp export_arg_vars(0), do: []

  defp export_arg_vars(arity) do
    Enum.map(0..(arity - 1)//1, fn index ->
      var(Hyperlang.GeneratedAtoms.variable!(index))
    end)
  end

  defp thunk(body) do
    {:fun, 0, {:clauses, [{:clause, 0, [], [], [body]}]}}
  end

  defp compile_patterns(patterns, env) do
    Enum.map_reduce(patterns, env, &compile_pattern/2)
  end

  defp compile_pattern(%{node: :wild_pattern}, env), do: {{:var, 0, :_}, env}

  defp compile_pattern(%{node: :var_pattern, name: name}, env) do
    {name, env} = var_name(name, env)
    {var(name), env}
  end

  defp compile_pattern(%{node: :literal_pattern, literal: literal}, env) do
    {form, env} = compile_expr(literal, env)
    {form, env}
  end

  defp compile_pattern(%{node: :alias_pattern, left: left, right: right}, env) do
    {left, env} = compile_pattern(left, env)
    {right, env} = compile_pattern(right, env)
    {{:match, 0, left, right}, env}
  end

  defp compile_pattern(%{node: :tuple_pattern, items: items}, env) do
    {items, env} = compile_patterns(items, env)
    {{:tuple, 0, items}, env}
  end

  defp compile_pattern(%{node: :list_pattern, items: items}, env) do
    {items, env} = compile_patterns(items, env)
    {list(items), env}
  end

  defp compile_pattern(%{node: :cons_pattern, head: head, tail: tail}, env) do
    {head, env} = compile_pattern(head, env)
    {tail, env} = compile_pattern(tail, env)
    {{:cons, 0, head, tail}, env}
  end

  defp compile_pattern(%{node: :map_pattern, fields: fields}, env) do
    {fields, env} =
      Enum.map_reduce(fields, env, fn field, env ->
        {key, env} = compile_expr(field.key, env)
        {value, env} = compile_pattern(field.value, env)
        {{:map_field_exact, 0, key, value}, env}
      end)

    {{:map, 0, fields}, env}
  end

  defp compile_pattern(%{node: :record_pattern, name: name, fields: fields}, env) do
    {fields, env} =
      Enum.map_reduce(fields, env, fn field, env ->
        {value, env} = compile_pattern(field.value, env)
        {{field.name, value}, env}
      end)

    wildcard =
      Enum.find_value(fields, var(:_), fn {field, value} -> field == "_" && value end)

    elements =
      env
      |> record_definition(name)
      |> Enum.map(fn definition ->
        case List.keyfind(fields, definition.name, 0) do
          {_field, value} -> value
          nil -> wildcard
        end
      end)

    {tuple([atom(atom_literal(name, env)) | elements]), env}
  end

  defp compile_pattern(%{node: :binary, parts: parts}, env) do
    compile_binary(parts, env, :pattern)
  end

  defp compile_guard(nil, env), do: {[], env}

  defp compile_guard(expr, env) do
    previous_mode = Map.get(env, :mode, :expr)
    {form, env} = compile_expr(expr, %{env | mode: :guard})
    {[[form]], %{env | mode: previous_mode}}
  end

  defp atom_pool_size(%Core{} = core) do
    core.metadata
    |> Map.get(:atom_pool, %{})
    |> Map.get(:source_to_pool, %{})
    |> map_size()
  end

  defp guest_dictionary_used?(%Core{} = core) do
    Enum.any?(core.functions, fn {_key, function} ->
      guest_dictionary_used_in?(function)
    end)
  end

  defp guest_dictionary_used_in?(%{
         node: :safe_stdlib_call,
         target: {:wrapped, :erlang, function}
       })
       when function in [:get, :put, :erase],
       do: true

  defp guest_dictionary_used_in?(%{} = term) do
    term
    |> Map.values()
    |> Enum.any?(&guest_dictionary_used_in?/1)
  end

  defp guest_dictionary_used_in?(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.any?(&guest_dictionary_used_in?/1)
  end

  defp guest_dictionary_used_in?(term) when is_list(term),
    do: Enum.any?(term, &guest_dictionary_used_in?/1)

  defp guest_dictionary_used_in?(_term), do: false

  defp host_boundary_used?(%Core{} = core) do
    Enum.any?(core.functions, fn {_key, function} ->
      host_boundary_used_in?(function)
    end)
  end

  defp host_boundary_used_in?(%{node: node})
       when node in [
              :safe_code_call,
              :safe_filesystem_call,
              :safe_import_call,
              :safe_loader_call,
              :safe_module_call,
              :safe_table_call
            ],
       do: true

  defp host_boundary_used_in?(%{} = term) do
    term
    |> Map.values()
    |> Enum.any?(&host_boundary_used_in?/1)
  end

  defp host_boundary_used_in?(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.any?(&host_boundary_used_in?/1)
  end

  defp host_boundary_used_in?(term) when is_list(term),
    do: Enum.any?(term, &host_boundary_used_in?/1)

  defp host_boundary_used_in?(_term), do: false

  defp compile_expr(%{node: :int, value: value}, env), do: {{:integer, 0, value}, env}
  defp compile_expr(%{node: :float, value: value}, env), do: {{:float, 0, value}, env}
  defp compile_expr(%{node: :bool, value: value}, env), do: {atom(value), env}
  defp compile_expr(%{node: :string, value: value}, env), do: {charlist(value), env}

  defp compile_expr(%{node: :atom, value: value}, env) do
    {atom(atom_literal(value, env)), env}
  end

  defp compile_expr(%{node: :var, name: name}, env) do
    {name, env} = var_name(name, env)
    {var(name), env}
  end

  defp compile_expr(%{node: :unary, op: op, expr: expr}, env) do
    {expr, env} = compile_expr(expr, env)
    {{:op, 0, op_atom(op), expr}, env}
  end

  defp compile_expr(%{node: :binary_op, op: op, left: left, right: right}, env) do
    {left, env} = compile_expr(left, env)
    {right, env} = compile_expr(right, env)
    {{:op, 0, op_atom(op), left, right}, env}
  end

  defp compile_expr(%{node: :send, target: target, message: message}, env) do
    {target, env} = compile_expr(target, env)
    {message, env} = compile_expr(message, env)
    {remote_call(@msg_runtime, :send, [target, message]), env}
  end

  defp compile_expr(%{node: :native_spawn, fun: fun}, env) do
    {fun, env} = compile_expr(fun, env)
    {remote_call(@msg_runtime, :spawn, [fun]), env}
  end

  defp compile_expr(%{node: :native_exit, target: target, reason: reason}, env) do
    {target, env} = compile_expr(target, env)
    {reason, env} = compile_expr(reason, env)
    {remote_call(@msg_runtime, :exit, [target, reason]), env}
  end

  defp compile_expr(%{node: node, time: time, target: target, message: message}, env)
       when node in [:native_send_after, :native_start_timer] do
    {time, env} = compile_expr(time, env)
    {target, env} = compile_expr(target, env)
    {message, env} = compile_expr(message, env)

    function = if node == :native_send_after, do: :send_after, else: :start_timer
    {remote_call(@msg_runtime, function, [time, target, message]), env}
  end

  defp compile_expr(%{node: :native_cancel_timer, ref: ref}, env) do
    {ref, env} = compile_expr(ref, env)
    {remote_call(@msg_runtime, :cancel_timer, [ref]), env}
  end

  defp compile_expr(%{node: :native_read_timer, ref: ref}, env) do
    {ref, env} = compile_expr(ref, env)
    {remote_call(@msg_runtime, :read_timer, [ref]), env}
  end

  defp compile_expr(%{node: :native_timer_sleep, time: time}, env) do
    {time, env} = compile_expr(time, env)

    sleep_call = remote_call(@sys_facade, :sleep, [var(:ctx), time])

    {{:case, 0, sleep_call,
      [
        {:clause, 0, [{:integer, 0, 0}], [], [atom(:ok)]},
        {:clause, 0, [var(:_)], [], [remote_call(:erlang, :error, [atom(:badarg)])]}
      ]}, env}
  end

  defp compile_expr(%{node: :native_spawn_link, fun: fun}, env) do
    {fun, env} = compile_expr(fun, env)
    {remote_call(@msg_runtime, :spawn_link, [fun]), env}
  end

  defp compile_expr(%{node: :native_spawn_monitor, fun: fun}, env) do
    {fun, env} = compile_expr(fun, env)
    {remote_call(@msg_runtime, :spawn_monitor, [fun]), env}
  end

  defp compile_expr(%{node: :native_register, name: name, target: target}, env) do
    {name, env} = compile_expr(name, env)
    {target, env} = compile_expr(target, env)
    {remote_call(@msg_runtime, :register, [name, target]), env}
  end

  defp compile_expr(%{node: :native_whereis, name: name}, env) do
    {name, env} = compile_expr(name, env)
    {remote_call(@msg_runtime, :whereis, [name]), env}
  end

  defp compile_expr(%{node: :native_unregister, name: name}, env) do
    {name, env} = compile_expr(name, env)
    {remote_call(@msg_runtime, :unregister, [name]), env}
  end

  defp compile_expr(%{node: :native_monitor, target: target}, env) do
    {target, env} = compile_expr(target, env)
    {remote_call(@msg_runtime, :monitor, [target]), env}
  end

  defp compile_expr(%{node: :native_make_ref}, env),
    do: {remote_call(@msg_runtime, :make_ref, []), env}

  defp compile_expr(%{node: :native_is_process_alive, target: target}, env) do
    {target, env} = compile_expr(target, env)
    {remote_call(@msg_runtime, :is_process_alive, [target]), env}
  end

  defp compile_expr(%{node: :native_process_info_links}, env),
    do: {remote_call(@msg_runtime, :process_info_links, []), env}

  defp compile_expr(%{node: :native_link, target: target}, env) do
    {target, env} = compile_expr(target, env)
    {remote_call(@msg_runtime, :link, [target]), env}
  end

  defp compile_expr(%{node: :native_unlink, target: target}, env) do
    {target, env} = compile_expr(target, env)
    {remote_call(@msg_runtime, :unlink, [target]), env}
  end

  defp compile_expr(%{node: :native_demonitor, ref: ref, options: nil}, env) do
    {ref, env} = compile_expr(ref, env)
    {remote_call(@msg_runtime, :demonitor, [ref]), env}
  end

  defp compile_expr(%{node: :native_demonitor, ref: ref, options: options}, env) do
    {ref, env} = compile_expr(ref, env)
    {options, env} = compile_expr(options, env)
    {remote_call(@msg_runtime, :demonitor, [ref, options]), env}
  end

  defp compile_expr(%{node: :native_process_flag, flag: flag, value: value}, env) do
    {flag, env} = compile_expr(flag, env)
    {value, env} = compile_expr(value, env)
    {remote_call(@msg_runtime, :process_flag, [flag, value]), env}
  end

  defp compile_expr(%{node: :match, pattern: pattern, expr: rhs}, env) do
    {rhs, env} = compile_expr(rhs, env)
    {pattern, env} = compile_pattern(pattern, env)
    {{:match, 0, pattern, rhs}, env}
  end

  defp compile_expr(%{node: :block, exprs: exprs}, env) do
    {exprs, env} = Enum.map_reduce(exprs, env, &compile_expr/2)
    {{:block, 0, exprs}, env}
  end

  defp compile_expr(%{node: :list, items: items}, env) do
    {items, env} = Enum.map_reduce(items, env, &compile_expr/2)
    {list(items), env}
  end

  defp compile_expr(%{node: :cons, head: head, tail: tail}, env) do
    {head, env} = compile_expr(head, env)
    {tail, env} = compile_expr(tail, env)
    {{:cons, 0, head, tail}, env}
  end

  defp compile_expr(%{node: :tuple, items: items}, env) do
    {items, env} = Enum.map_reduce(items, env, &compile_expr/2)
    {{:tuple, 0, items}, env}
  end

  defp compile_expr(%{node: :map, fields: fields}, env) do
    {fields, env} =
      Enum.map_reduce(fields, env, fn field, env ->
        {key, env} = compile_expr(field.key, env)
        {value, env} = compile_expr(field.value, env)
        {{:map_field_assoc, 0, key, value}, env}
      end)

    {{:map, 0, fields}, env}
  end

  defp compile_expr(%{node: :map_update, base: base, fields: fields}, env) do
    {base, env} = compile_expr(base, env)

    {fields, env} =
      Enum.map_reduce(fields, env, fn field, env ->
        {key, env} = compile_expr(field.key, env)
        {value, env} = compile_expr(field.value, env)
        {map_field(field, key, value), env}
      end)

    {{:map, 0, base, fields}, env}
  end

  # Records lower to tuple operations here, exactly as `erl_expand_records`
  # expands them, but with variables from the bounded `v_N` family: that
  # pass names its variables `recN` from a module-wide counter.
  defp compile_expr(%{node: :record_create, name: name, fields: fields}, env) do
    {fields, env} = compile_record_fields(fields, env)
    wildcard = Enum.find_value(fields, fn {field, value} -> field == "_" && value end)

    {inits, env} =
      env
      |> record_definition(name)
      |> Enum.map_reduce(env, fn definition, env ->
        case List.keyfind(fields, definition.name, 0) do
          {_field, value} -> {value, env}
          nil when wildcard != nil -> {wildcard, env}
          nil -> record_default(definition, env)
        end
      end)

    {tuple([atom(atom_literal(name, env)) | inits]), env}
  end

  defp compile_expr(%{node: :record_update, base: base, name: name, fields: fields}, env) do
    {base, env} = compile_expr(base, env)
    {fields, env} = compile_record_fields(fields, env)
    definitions = record_definition(env, name)
    record_atom = atom(atom_literal(name, env))

    # Update values that are not variables or literal terms are evaluated
    # first, then the record expression once.
    {pre, fields, env} =
      Enum.reduce(fields, {[], [], env}, fn {field, value}, {pre, fields, env} ->
        if simple_value?(value) do
          {pre, [{field, value} | fields], env}
        else
          {[bound], env} = fresh_vars(1, env)
          {[{:match, 0, bound, value} | pre], [{field, bound} | fields], env}
        end
      end)

    {[record], env} = fresh_vars(1, env)
    fail = {:clause, 0, [var(:_)], [], [record_error(record)]}

    wildcards = Enum.map(definitions, fn _ -> var(:_) end)

    # `R#r{}` checks the record and yields an equal term, as the rebuilt
    # tuple of `erl_expand_records` does.
    {update, env} =
      case fields do
        [] ->
          {{:case, 0, record,
            [{:clause, 0, [tuple([record_atom | wildcards])], [], [record]}, fail]}, env}

        _ ->
          setel =
            fields
            |> Enum.map(fn {field, value} -> {record_field_index(definitions, field), value} end)
            |> Enum.sort()
            |> List.foldr(record, fn {index, value}, acc ->
              remote_call(:erlang, :setelement, [{:integer, 0, index}, acc, value])
            end)

          {{:case, 0, record,
            [{:clause, 0, [tuple([record_atom | wildcards])], [], [setel]}, fail]}, env}
      end

    {{:block, 0, Enum.reverse(pre) ++ [{:match, 0, record, base}, update]}, env}
  end

  defp compile_expr(%{node: :record_access, base: base, name: name, field: field}, env) do
    {base, env} = compile_expr(base, env)
    definitions = record_definition(env, name)
    index = record_field_index(definitions, field)
    record_atom = atom(atom_literal(name, env))

    if env.mode == :guard or env.record_guard do
      # Guard context: `element/2` behind the exact-size record test. A
      # failed test raises (`false + I`), which fails the guard test the
      # same way the `(is_record(..) orelse fail) and ..` conjunct does.
      # (`erlang:is_record/3` itself is not a guard call erl_lint accepts
      # under `no_auto_import`; this is its definition.)
      is_record =
        guard_and([
          remote_call(:erlang, :is_tuple, [base]),
          {:op, 0, :"=:=", remote_call(:erlang, :tuple_size, [base]),
           {:integer, 0, length(definitions) + 1}},
          {:op, 0, :"=:=", remote_call(:erlang, :element, [{:integer, 0, 1}, base]), record_atom}
        ])

      checked =
        {:op, 0, :+, {:integer, 0, index}, {:op, 0, :andalso, is_record, {:integer, 0, 0}}}

      {remote_call(:erlang, :element, [checked, base]), %{env | record_accessed: true}}
    else
      {[value], env} = fresh_vars(1, env)

      pattern =
        tuple([
          record_atom
          | Enum.map(definitions, fn definition ->
              if definition.name == field, do: value, else: var(:_)
            end)
        ])

      {{:case, 0, base,
        [
          {:clause, 0, [pattern], [], [value]},
          {:clause, 0, [value], [], [record_error(value)]}
        ]}, %{env | record_accessed: true}}
    end
  end

  defp compile_expr(%{node: :record_index, name: name, field: field}, env) do
    {{:integer, 0, record_field_index(record_definition(env, name), field)}, env}
  end

  defp compile_expr(%{node: :record_info, item: "fields", name: name}, env) do
    fields = Enum.map(record_definition(env, name), &atom(atom_literal(&1.name, env)))
    {list(fields), env}
  end

  defp compile_expr(%{node: :record_info, name: name}, env) do
    {{:integer, 0, length(record_definition(env, name)) + 1}, env}
  end

  defp compile_expr(%{node: :binary, parts: parts}, env) do
    compile_binary(parts, env, :expr)
  end

  defp compile_expr(%{node: :safe_local_call} = call, env) do
    case constant_table_local_call(call, env) do
      {:ok, expr, env} ->
        {expr, env}

      :error ->
        case rune_local_call(call, env) do
          {:ok, expr, env} ->
            {expr, env}

          :error ->
            case inline_local_call(call, env) do
              {:ok, expr, env} ->
                {expr, env}

              :error ->
                %{function: function, args: args} = call
                {args, env} = Enum.map_reduce(args, env, &compile_expr/2)
                {{:call, 0, {:atom, 0, function}, [var(:ctx) | args]}, env}
            end
        end
    end
  end

  defp compile_expr(%{node: :safe_import_call, import_name: import_name, args: args}, env) do
    {args, env} = Enum.map_reduce(args, env, &compile_expr/2)
    call = remote_call(@runtime, :import, [var(:ctx), abstract_term(import_name), list(args)])
    {call, env}
  end

  defp compile_expr(
         %{
           node: :safe_filesystem_call,
           module: "sys",
           function: "newchan",
           operation: :sys_newchan_chan,
           args: [size]
         },
         env
       ) do
    {size, env} = compile_expr(size, env)
    {classification, env} = newchan_classification(env)
    {remote_call(@sys_facade, :newchan, [var(:ctx), size, atom(classification)]), env}
  end

  defp compile_expr(
         %{node: :safe_filesystem_call, module: "sys", function: function, args: args},
         env
       ) do
    {args, env} = Enum.map_reduce(args, env, &compile_expr/2)
    {remote_call(@sys_facade, String.to_existing_atom(function), [var(:ctx) | args]), env}
  end

  # `file:`/`filelib:` lower straight onto the runtime filesystem entry with the
  # operation atom the MFA tables in `Hyperlang.Filesystem` resolved, exactly
  # like the code and loader lowerings below.
  defp compile_expr(
         %{node: :safe_filesystem_call, operation: operation, args: args},
         env
       ) do
    {args, env} = Enum.map_reduce(args, env, &compile_expr/2)
    {remote_call(@runtime, :filesystem, [var(:ctx), atom(operation), list(args)]), env}
  end

  defp compile_expr(%{node: :safe_code_call, operation: operation, args: args}, env) do
    {args, env} = Enum.map_reduce(args, env, &compile_expr/2)
    call = remote_call(@runtime, :code, [var(:ctx), atom(operation), list(args)])
    {call, env}
  end

  defp compile_expr(%{node: :safe_loader_call, operation: operation, args: args}, env) do
    {args, env} = Enum.map_reduce(args, env, &compile_expr/2)
    call = remote_call(@runtime, :loader, [var(:ctx), atom(operation), list(args)])
    {call, env}
  end

  defp compile_expr(
         %{node: :safe_module_call, module: module, function: function, args: args},
         env
       ) do
    {args, env} = Enum.map_reduce(args, env, &compile_expr/2)

    call =
      remote_call(@runtime, :module_call, [
        var(:ctx),
        abstract_term(module),
        abstract_term(function),
        list(args)
      ])

    {call, env}
  end

  defp compile_expr(
         %{node: :safe_behaviour_callback, module: module, function: function, args: args},
         env
       ) do
    {module, env} = compile_expr(module, env)
    {args, env} = Enum.map_reduce(args, env, &compile_expr/2)

    call =
      remote_call(@runtime, :behaviour_callback, [
        var(:ctx),
        module,
        abstract_term(function),
        list(args)
      ])

    {call, env}
  end

  defp compile_expr(%{node: :safe_table_call, operation: operation, args: args}, env) do
    {args, env} = Enum.map_reduce(args, env, &compile_expr/2)
    call = remote_call(@table_runtime, :dispatch, [var(:ctx), atom(operation), list(args)])
    {call, env}
  end

  defp compile_expr(
         %{node: :safe_dynamic_snapshot_call, module: module, args: args, candidates: candidates},
         env
       ) do
    {module, env} = compile_expr(module, env)
    {args, env} = Enum.map_reduce(args, env, &compile_expr/2)
    {[module_var | arg_vars], env} = fresh_vars(1 + length(args), env)

    arg_matches =
      Enum.zip(arg_vars, args)
      |> Enum.map(fn {arg_var, arg} -> {:match, 0, arg_var, arg} end)

    matches = [{:match, 0, module_var, module} | arg_matches]

    clauses =
      Enum.map(candidates, fn %{module: module, function: function} ->
        module_atom = atom_literal(module, env)
        call = {:call, 0, {:atom, 0, function}, [var(:ctx) | arg_vars]}

        {:clause, 0, [atom(module_atom)], [], [call]}
      end) ++
        [{:clause, 0, [var(:_)], [], [remote_call(:erlang, :error, [atom(:undef)])]}]

    {{:block, 0, matches ++ [{:case, 0, module_var, clauses}]}, env}
  end

  # Every `apply/3` site calls the module's one shared snapshot dispatcher
  # (`snapshot_apply_function/2`). The match block keeps the source evaluation
  # order of target, function and arguments.
  defp compile_expr(
         %{node: :safe_snapshot_apply, target: target, function: function, args: args},
         env
       ) do
    {target, env} = compile_expr(target, env)
    {function, env} = compile_expr(function, env)
    {args, env} = compile_expr(args, env)
    {[target_var, function_var, args_var], env} = fresh_vars(3, env)

    matches = [
      {:match, 0, target_var, target},
      {:match, 0, function_var, function},
      {:match, 0, args_var, args}
    ]

    call =
      {:call, 0, atom(@snapshot_apply), [var(:ctx), target_var, function_var, args_var]}

    {{:block, 0, matches ++ [call]}, env}
  end

  defp compile_expr(
         %{node: :safe_stdlib_call, target: {:direct, :erlang, :is_record}, args: args},
         env
       ) do
    {args, env} = Enum.map_reduce(args, env, &compile_expr/2)
    compile_is_record(args, env)
  end

  defp compile_expr(
         %{node: :safe_stdlib_call, target: {:direct, :maps, :get}, args: [key, map]},
         env
       ) do
    {key, env} = compile_expr(key, env)
    {map, env} = compile_expr(map, env)
    {remote_call(:erlang, :map_get, [key, map]), env}
  end

  defp compile_expr(
         %{node: :safe_stdlib_call, target: {:direct, :maps, :put}, args: [key, value, map]},
         %{mode: mode} = env
       )
       when mode != :guard do
    {key, env} = compile_expr(key, env)
    {value, env} = compile_expr(value, env)
    {map, env} = compile_expr(map, env)
    {{:map, 0, map, [{:map_field_assoc, 0, key, value}]}, env}
  end

  defp compile_expr(
         %{node: :safe_stdlib_call, target: {:wrapped, :erlang, :get}, args: []},
         env
       ) do
    {remote_call(@runtime, :guest_dictionary_get_all, [var(:ctx)]), env}
  end

  defp compile_expr(
         %{node: :safe_stdlib_call, target: {:wrapped, :erlang, :get}, args: [key]},
         env
       ) do
    {key, env} = compile_expr(key, env)
    guest_dictionary_get_expr(key, env)
  end

  defp compile_expr(
         %{node: :safe_stdlib_call, target: {:wrapped, :erlang, :put}, args: [key, value]},
         env
       ) do
    {key, env} = compile_expr(key, env)
    {value, env} = compile_expr(value, env)
    guest_dictionary_put_expr(key, value, env)
  end

  defp compile_expr(
         %{node: :safe_stdlib_call, target: {:wrapped, :erlang, :erase}, args: []},
         env
       ) do
    {remote_call(@runtime, :guest_dictionary_erase_all, [var(:ctx)]), env}
  end

  defp compile_expr(
         %{node: :safe_stdlib_call, target: {:wrapped, :erlang, :erase}, args: [key]},
         env
       ) do
    {key, env} = compile_expr(key, env)
    guest_dictionary_erase_expr(key, env)
  end

  defp compile_expr(
         %{
           node: :safe_stdlib_call,
           target: {:wrapped, :unicode, :characters_to_binary},
           args: args
         },
         env
       )
       when length(args) in 1..3 do
    {args, env} = Enum.map_reduce(args, env, &compile_expr/2)
    {remote_call(@runtime, :unicode_characters_to_binary, [var(:ctx) | args]), env}
  end

  defp compile_expr(
         %{
           node: :safe_stdlib_call,
           target: {:wrapped, :unicode, :characters_to_list},
           args: args
         },
         env
       )
       when length(args) in 1..2 do
    {args, env} = Enum.map_reduce(args, env, &compile_expr/2)
    {remote_call(@runtime, :unicode_characters_to_list, [var(:ctx) | args]), env}
  end

  defp compile_expr(
         %{node: :safe_stdlib_call, target: {:wrapped, :binary, :copy}, args: args},
         env
       )
       when length(args) in 1..2 do
    {args, env} = Enum.map_reduce(args, env, &compile_expr/2)
    {remote_call(@runtime, :binary_copy, [var(:ctx) | args]), env}
  end

  defp compile_expr(
         %{node: :safe_stdlib_call, target: {:wrapped, :binary, :split}, args: args},
         env
       )
       when length(args) in 2..3 do
    {args, env} = Enum.map_reduce(args, env, &compile_expr/2)
    {remote_call(@runtime, :binary_split, [var(:ctx) | args]), env}
  end

  defp compile_expr(
         %{node: :safe_stdlib_call, target: {:wrapped, :binary, :matches}, args: args},
         env
       )
       when length(args) in 2..3 do
    {args, env} = Enum.map_reduce(args, env, &compile_expr/2)
    {remote_call(@runtime, :binary_matches, [var(:ctx) | args]), env}
  end

  defp compile_expr(
         %{node: :safe_stdlib_call, target: {:wrapped, :erlang, :iolist_to_binary}, args: [arg]},
         env
       ) do
    {arg, env} = compile_expr(arg, env)
    {remote_call(@runtime, :iolist_to_binary, [var(:ctx), arg]), env}
  end

  defp compile_expr(
         %{node: :safe_stdlib_call, target: {:direct, mod, fun}, args: args},
         %{mode: :guard} = env
       ) do
    {args, env} = Enum.map_reduce(args, env, &compile_expr/2)
    {{:call, 0, {:remote, 0, atom(mod), atom(fun)}, args}, env}
  end

  defp compile_expr(%{node: :safe_stdlib_call, target: target, args: args}, env) do
    {args, env} = Enum.map_reduce(args, env, &compile_expr/2)
    compile_stdlib_call(target, args, env)
  end

  defp compile_expr(%{node: :case, expr: expr, clauses: clauses}, env) do
    outer_vars = env.vars
    {expr, env} = compile_expr(expr, env)
    env = %{env | vars: outer_vars}
    {clauses, env} = compile_case_clauses(clauses, env)
    {{:case, 0, expr, clauses}, env}
  end

  defp compile_expr(%{node: :receive, clauses: clauses, timeout: timeout} = expr, env) do
    outer_vars = env.vars
    {clauses, env} = compile_receive_clauses(clauses, env)
    env = %{env | vars: outer_vars}
    {timeout, env} = compile_expr(timeout, env)
    env = %{env | vars: outer_vars}
    {after_body, env} = compile_expr(Map.get(expr, :after_body), env)

    compile_receive_selection(clauses, timeout, after_body, %{env | vars: outer_vars})
  end

  defp compile_expr(%{node: :receive, clauses: clauses}, env) do
    outer_vars = env.vars
    {clauses, env} = compile_receive_clauses(clauses, env)
    compile_receive_selection(clauses, atom(:infinity), atom(nil), %{env | vars: outer_vars})
  end

  defp compile_expr(%{node: :if, clauses: clauses}, env) do
    {clauses, env} =
      Enum.map_reduce(clauses, env, fn clause, env ->
        clause_env = %{env | vars: env.vars}
        previous_mode = Map.get(env, :mode, :expr)
        {guard, clause_env} = compile_expr(clause.guard, %{clause_env | mode: :guard})
        clause_env = %{clause_env | mode: previous_mode}
        {body, clause_env} = compile_expr(clause.body, clause_env)
        {{:clause, 0, [], [[guard]], [body]}, %{clause_env | vars: env.vars}}
      end)

    {{:if, 0, clauses}, env}
  end

  defp compile_expr(%{node: :fun, clauses: clauses}, env) do
    {clauses, env} = compile_fun_clauses(clauses, env)
    fun = {:fun, 0, {:clauses, clauses}}
    {lift(:fun, captured_vars(fun, env.vars), fn _self -> fun end, env), env}
  end

  # A named fun is a lifted fun whose name is bound to a fresh closure over
  # the same captures. Erlang fun equality compares code and environment, so
  # the rebuilt closure equals the one the caller holds. A native `named_fun`
  # would make the compiler name a letrec after the guest's arity.
  defp compile_expr(%{node: :named_fun, name: name, clauses: clauses}, env) do
    {self_var, fun_env, outer_env} = named_fun_name(name, env)
    {clauses, fun_env} = compile_fun_clauses(clauses, fun_env)
    captured = captured_vars({:clauses, clauses}, env.vars)

    call =
      lift(
        :fun,
        captured,
        fn self_call -> named_fun_body(clauses, self_var, self_call, fun_env) end,
        outer_env
      )

    {call, outer_env}
  end

  # One lifted closure per local function reference: `fun f/1` evaluated twice
  # in one context yields equal funs, as in Erlang.
  defp compile_expr(%{node: :safe_local_fun_ref, function: function, arity: arity}, env) do
    {local_fun_ref(function, arity, env), env}
  end

  defp compile_expr(%{node: :fun_call, callee: callee, args: args}, env) do
    {callee, env} = compile_expr(callee, env)
    {args, env} = Enum.map_reduce(args, env, &compile_expr/2)
    {remote_call(@runtime, :apply_guest_fun, [var(:ctx), callee, list(args)]), env}
  end

  defp compile_expr(
         %{node: :try, body: body, of_clauses: of_clauses, catch_clauses: catch_clauses},
         env
       ) do
    original_env = env
    {body, body_env} = compile_expr(body, env)
    {of_clauses, of_env} = compile_case_clauses(of_clauses, body_env)
    catch_env = %{of_env | vars: original_env.vars}
    {catch_clauses, env} = compile_catch_clauses(catch_clauses, catch_env)
    {{:try, 0, [body], of_clauses, catch_clauses, []}, env}
  end

  defp compile_expr(%{node: :list_comp, expr: expr, qualifiers: qualifiers}, env) do
    compile_comprehension(:lc, qualifiers, &compile_expr(expr, &1), env)
  end

  defp compile_expr(%{node: :map_comp, key: key, value: value, qualifiers: qualifiers}, env) do
    compile_comprehension(
      :mc,
      qualifiers,
      fn env ->
        {key, env} = compile_expr(key, env)
        {value, env} = compile_expr(value, env)
        {tuple([key, value]), env}
      end,
      env
    )
  end

  defp compile_expr(%{node: :binary_comp, expr: expr, qualifiers: qualifiers}, env) do
    compile_comprehension(:bc, qualifiers, &compile_expr(expr, &1), env)
  end

  defp compile_record_fields(fields, env) do
    Enum.map_reduce(fields, env, fn field, env ->
      {value, env} = compile_expr(field.value, env)
      {{field.name, value}, env}
    end)
  end

  defp compile_binary(parts, env, mode) do
    {parts, env} = Enum.map_reduce(parts, env, &compile_bit_segment(&1, &2, mode))
    {{:bin, 0, List.flatten(parts)}, env}
  end

  defp compile_bit_segment(%{node: :bit_segment, size: size, types: types} = segment, env, mode) do
    case unicode_string_segment_value(segment.expr) do
      {:ok, value} ->
        cond do
          unicode_segment_types?(types) ->
            compile_unicode_string_segment(value, size, types, env)

          size == :default and not explicit_type_segment?(types) ->
            # Bare string segments are guest text. Encode them as UTF-8 rather
            # than silently truncating every non-ASCII codepoint to its low
            # byte. Explicit type or size modifiers retain Erlang's exact
            # per-character segment semantics.
            compile_unicode_string_segment(value, :default, ["utf8"], env)

          true ->
            compile_single_bit_segment(segment, env, mode)
        end

      _ ->
        compile_single_bit_segment(segment, env, mode)
    end
  end

  defp compile_unicode_string_segment(value, size, types, env) do
    {size, env} = compile_segment_size(size, env)
    types = compile_segment_types(types)

    parts =
      value
      |> String.to_charlist()
      |> Enum.map(fn codepoint ->
        {:bin_element, 0, {:integer, 0, codepoint}, size, types}
      end)

    {parts, env}
  end

  defp compile_single_bit_segment(
         %{node: :bit_segment, expr: expr, size: size, types: types},
         env,
         mode
       ) do
    {expr, env} = compile_segment_expr(expr, env, mode)
    {size, env} = compile_segment_size(size, env)
    {{:bin_element, 0, expr, size, compile_segment_types(types)}, env}
  end

  defp unicode_string_segment_value(%{node: :string, value: value}), do: {:ok, value}

  defp unicode_string_segment_value(%{
         node: :literal_pattern,
         literal: %{node: :string, value: value}
       }),
       do: {:ok, value}

  defp unicode_string_segment_value(_expr), do: :error

  defp unicode_segment_types?(types) when is_list(types),
    do: Enum.any?(types, &(&1 in ["utf8", "utf16", "utf32"]))

  defp unicode_segment_types?(_types), do: false

  defp explicit_type_segment?(:default), do: false

  defp explicit_type_segment?(types) when is_list(types) do
    Enum.any?(types, fn
      {_name, _value} -> true
      name -> name in ["integer", "float", "binary", "bytes", "bitstring", "bits"]
    end)
  end

  defp compile_segment_expr(%{node: :string, value: value}, env, :expr),
    do: {{:string, 0, String.to_charlist(value)}, env}

  defp compile_segment_expr(
         %{node: :literal_pattern, literal: %{node: :string, value: value}},
         env,
         :pattern
       ),
       do: {{:string, 0, String.to_charlist(value)}, env}

  defp compile_segment_expr(expr, env, :expr), do: compile_expr(expr, env)
  defp compile_segment_expr(expr, env, :pattern), do: compile_pattern(expr, env)

  defp compile_segment_size(:default, env), do: {:default, env}

  defp compile_segment_size(size, env), do: compile_expr(size, env)

  defp compile_segment_types(:default), do: :default

  defp compile_segment_types(types) when is_list(types) do
    Enum.map(types, fn
      {"unit", value} -> {:unit, value}
      modifier -> Map.fetch!(@segment_modifiers, modifier)
    end)
  end

  defp compile_stdlib_call(target, args, env) do
    case target do
      {:direct, mod, fun} ->
        if Hyperlang.Stdlib.direct_codegen_allowed?(mod, fun, length(args)) do
          {{:call, 0, {:remote, 0, atom(mod), atom(fun)}, args}, env}
        else
          {remote_call(@runtime, :stdlib, [var(:ctx), atom(mod), atom(fun), list(args)]), env}
        end

      {:wrapped, mod, fun} ->
        {remote_call(@runtime, :stdlib, [var(:ctx), atom(mod), atom(fun), list(args)]), env}

      {:captured_io, _mod, fun} ->
        {remote_call(@runtime, :capture_io, [var(:ctx), atom(fun), list(args)]), env}
    end
  end

  defp newchan_classification(
         %{
           manifest: %{sys: %{channel_element_types: channel_element_types}},
           current_function: {function, arity},
           newchan_index: index
         } = env
       ) do
    # This proof relies on trusted Limbo-derived channel metadata naming the
    # exact generated call site and on the Limbo verifier enforcing `chan of T`
    # endpoint types. Missing, dynamic, unknown, or channel-bearing T is stored
    # as `:may_contain_handles`, so only a closed recursively handle-free type
    # can produce the traversal skip bit.
    classification =
      Map.get(channel_element_types, {function, arity, index}, :may_contain_handles)

    {classification, %{env | newchan_index: index + 1}}
  end

  defp newchan_classification(%{newchan_index: index} = env),
    do: {:may_contain_handles, %{env | newchan_index: index + 1}}

  defp compile_case_clauses(clauses, env) do
    Enum.map_reduce(clauses, env, fn clause, env ->
      clause_vars = env.vars
      {patterns, clause_env} = compile_patterns(clause.patterns, env)
      {guard, clause_env} = compile_guard(clause.guard, clause_env)
      {body, clause_env} = compile_expr(clause.body, clause_env)
      {{:clause, 0, patterns, guard, [body]}, %{clause_env | vars: clause_vars}}
    end)
  end

  defp compile_receive_selection(clauses, timeout, after_body, env) do
    # Return a small tagged payload, then dispatch the guest body once.
    # No matched-body closure or duplicate nested receive body is generated.
    selected = var(:receive_selected)

    selectors =
      Enum.map(clauses, fn
        {:clause, line, [{:tuple, ta, [tag, sender, pattern]}], guards, _body} ->
          envelope = {:tuple, ta, [tag, sender, {:match, 0, selected, pattern}]}
          {:clause, line, [envelope], guards, [tuple([{:integer, 0, 0}, selected])]}
      end)

    dispatch =
      Enum.map(clauses, fn
        {:clause, line, [{:tuple, _, [_, _, pattern]}], guards, body} ->
          {:clause, line, [tuple([{:integer, 0, 0}, pattern])], guards, body}
      end)

    wait =
      {:fun, 0,
       {:clauses,
        [
          {:clause, 0, [var(:receive_timeout)], [],
           [
             {:receive, 0, selectors, var(:receive_timeout),
              [atom(:"$hyperlang_receive_timeout")]}
           ]}
        ]}}

    wait = lift(:receive, captured_vars(wait, env.vars), fn _self -> wait end, env)
    selected = remote_call(@msg_runtime, :receive_select, [wait, timeout])
    after_clause = {:clause, 0, [atom(:"$hyperlang_receive_timeout")], [], [after_body]}
    {{:case, 0, selected, dispatch ++ [after_clause]}, env}
  end

  defp compile_receive_clauses(clauses, env) do
    Enum.map_reduce(clauses, env, fn clause, env ->
      clause_vars = env.vars
      {patterns, clause_env} = compile_patterns(clause.patterns, env)
      {guard, clause_env} = compile_guard(clause.guard, clause_env)
      {body, clause_env} = compile_expr(clause.body, clause_env)
      patterns = Enum.map(patterns, &message_envelope_pattern/1)
      {{:clause, 0, patterns, guard, [body]}, %{clause_env | vars: clause_vars}}
    end)
  end

  defp message_envelope_pattern(pattern) do
    tuple([atom(:"$hyperlang_msg"), var(:_), pattern])
  end

  # A try/catch clause pattern is the exception 3-tuple `{Class, Reason, Stack}`.
  # `Class` is one of the control-flow keywords `throw`/`error`/`exit`, NOT a
  # data atom — it MUST be emitted as the literal Erlang atom so it matches the
  # real exception class. Running it through the normal atom path pools it to a
  # `hyperlang_atom_N` guest atom, so the native catch never matches a real
  # `throw`/`error`/`exit` and every guest try/catch silently fails to catch.
  # Compile each catch clause normally, then rewrite the class element of the
  # compiled exception tuple back to its raw source atom.
  defp compile_catch_clauses(clauses, env) do
    Enum.map_reduce(clauses, env, fn clause, env ->
      raw_class = catch_class_atom(clause.patterns)
      clause_vars = env.vars
      {patterns, clause_env} = compile_patterns(clause.patterns, env)
      {guard, clause_env} = compile_guard(clause.guard, clause_env)
      {body, clause_env} = compile_expr(clause.body, clause_env)
      patterns = rewrite_catch_class(patterns, raw_class)
      {{:clause, 0, patterns, guard, [body]}, %{clause_env | vars: clause_vars}}
    end)
  end

  # The literal class atom from the source catch pattern `{Class, Reason, Stack}`
  # (first item of the exception tuple_pattern), or nil if not in that shape.
  defp catch_class_atom([%{node: :tuple_pattern, items: [class | _]}]) do
    case class do
      %{node: :literal_pattern, literal: %{node: :atom, value: value}} ->
        String.to_existing_atom(value)

      %{node: :atom, value: value} ->
        String.to_existing_atom(value)

      _ ->
        nil
    end
  end

  defp catch_class_atom(_patterns), do: nil

  # Replace the class element (first of the compiled exception tuple pattern)
  # with the raw class atom. Only fires for the canonical 3-tuple catch pattern;
  # any other shape (e.g. a lone variable) is left untouched.
  defp rewrite_catch_class(patterns, nil), do: patterns

  defp rewrite_catch_class([{:tuple, anno, [_class, reason, stack]}], raw_class) do
    [{:tuple, anno, [atom(raw_class), reason, stack]}]
  end

  defp rewrite_catch_class(patterns, _raw_class), do: patterns

  defp compile_fun_clauses(clauses, env) do
    {clauses, _env} =
      Enum.map_reduce(clauses, env, fn clause, env ->
        shadowed = pattern_var_names(clause.patterns)
        clause_env = %{env | vars: Map.drop(env.vars, shadowed)}
        {patterns, clause_env} = compile_patterns(clause.patterns, clause_env)
        {guard, clause_env} = compile_guard(clause.guard, clause_env)
        {body, _clause_env} = compile_expr(clause.body, clause_env)
        {{:clause, 0, patterns, guard, [body]}, env}
      end)

    {clauses, env}
  end

  # Lifting. A lifted construct becomes `safe_f_N(Ctx, {C1, ..., Ck})` whose
  # whole body is the construct, with `N` past every guest function index.
  # The OTP compiler then names it `-safe_f_N/2-fun-0-`,
  # `-safe_f_N/2-lc$^0/1-0-` or `-safe_f_N/2-lbc$^0/2-0-`: one name per
  # family index, whatever the guest wrote.
  defp new_lift_state(%Core{} = core) do
    last =
      core.functions
      |> Map.values()
      |> Enum.flat_map(fn %Core.Function{safe_name: name} ->
        case Atom.to_string(name) do
          "safe_f_" <> index -> [String.to_integer(index)]
          _fixed_name -> []
        end
      end)
      |> Enum.max(fn -> -1 end)

    %{next: last + 1, functions: [], meta: %{}, ordinals: %{}, fun_refs: %{}, append?: false}
  end

  defp lift(kind, captured, build, env) do
    state = Process.get(@lift_key)
    name = Hyperlang.GeneratedAtoms.function!(state.next)
    captures = tuple(Enum.map(captured, &var/1))
    call = {:call, 0, {:atom, 0, name}, [var(:ctx), captures]}
    body = build.(call)
    ctx = if MapSet.member?(form_vars(body), :ctx), do: var(:ctx), else: var(:_)
    form = {:function, 0, name, 2, [{:clause, 0, [ctx, captures], [], [body]}]}
    owner = env.current_function || {"guest", 0}
    {source, arity} = owner
    ordinal = Map.get(state.ordinals, owner, 0)

    meta = %{
      function: "-#{source}/#{arity}-#{kind}-#{ordinal}-",
      arity: arity,
      span: env.current_span,
      lifted: true
    }

    Process.put(@lift_key, %{
      state
      | next: state.next + 1,
        functions: [form | state.functions],
        meta: Map.put(state.meta, name, meta),
        ordinals: Map.put(state.ordinals, owner, ordinal + 1)
    })

    call
  end

  # The variables a construct takes from its enclosing scope: those it uses
  # that are bound outside it. Inner bindings and shadowing fun-head variables
  # always get fresh `v_N` names, so name equality is binding equality.
  defp captured_vars(form, %MapSet{} = bound) do
    form
    |> form_vars()
    |> MapSet.intersection(bound)
    |> MapSet.difference(MapSet.new([:ctx, :_]))
    |> Enum.sort()
  end

  defp captured_vars(form, vars) when is_map(vars), do: captured_vars(form, bound_vars(vars))

  defp bound_vars(vars), do: MapSet.new(Map.values(vars))

  defp form_vars(term), do: collect_form_vars(term, MapSet.new())

  defp collect_form_vars({:var, _anno, name}, acc), do: MapSet.put(acc, name)

  defp collect_form_vars(term, acc) when is_tuple(term),
    do: term |> Tuple.to_list() |> collect_form_vars(acc)

  defp collect_form_vars(term, acc) when is_list(term),
    do: Enum.reduce(term, acc, &collect_form_vars/2)

  defp collect_form_vars(_term, acc), do: acc

  # The name is bound in each clause body that uses it. A guard that uses it
  # needs it before matching, so those funs bind it first and match the
  # clauses in a case (fun-head variables are fresh names, so no case pattern
  # can collide with an earlier binding).
  defp named_fun_body(clauses, self_var, self_call, env) do
    bind = {:match, 0, var(self_var), self_call}

    if Enum.any?(clauses, fn {:clause, _, _, guards, _} ->
         MapSet.member?(form_vars(guards), self_var)
       end) do
      [{:clause, _, patterns, _, _} | _] = clauses
      {args, _env} = fresh_vars(length(patterns), env)

      case_clauses =
        Enum.map(clauses, fn {:clause, anno, patterns, guards, body} ->
          {:clause, anno, [tuple(patterns)], guards, body}
        end)

      no_match =
        {:clause, 0, [var(:_)], [],
         [remote_call(:erlang, :error, [atom(:function_clause), list(args)])]}

      {:fun, 0,
       {:clauses,
        [{:clause, 0, args, [], [bind, {:case, 0, tuple(args), case_clauses ++ [no_match]}]}]}}
    else
      {:fun, 0,
       {:clauses,
        Enum.map(clauses, fn {:clause, anno, patterns, guards, body} = clause ->
          if MapSet.member?(form_vars(body), self_var),
            do: {:clause, anno, patterns, guards, [bind | body]},
            else: clause
        end)}}
    end
  end

  defp local_fun_ref(function, arity, env) do
    case Map.fetch(Process.get(@lift_key).fun_refs, {function, arity}) do
      {:ok, call} ->
        call

      :error ->
        args = Enum.map(0..(arity - 1)//1, &var(Hyperlang.GeneratedAtoms.variable!(&1)))
        body = {:call, 0, {:atom, 0, function}, [var(:ctx) | args]}
        fun = {:fun, 0, {:clauses, [{:clause, 0, args, [], [body]}]}}

        owner =
          Enum.find_value(env.local_functions, env.current_function, fn {key, safe_name} ->
            safe_name == function && key
          end)

        call = lift(:fun, [], fn _self -> fun end, %{env | current_function: owner})
        state = Process.get(@lift_key)

        Process.put(@lift_key, %{
          state
          | fun_refs: Map.put(state.fun_refs, {function, arity}, call)
        })

        call
    end
  end

  # Comprehensions keep the native OTP semantics: each generator level is one
  # lifted function holding a single-generator comprehension, so the compiler
  # makes exactly one letrec name per lifted function. An outer level appends
  # (lists) or concatenates (binaries) the results of the level inside it, in
  # the same order and with the same errors as the nested generators.
  defp compile_comprehension(kind, qualifiers, compile_template, env) do
    outer_vars = env.vars

    {prefix, levels, env} =
      Enum.reduce(qualifiers, {[], [], env}, fn
        %{node: node, pattern: pattern, expr: gen}, {prefix, levels, env}
        when node in [:generator, :b_generator] ->
          bound = bound_vars(env.vars)
          {pattern, env} = compile_pattern(pattern, env)
          {gen, env} = compile_expr(gen, env)
          tag = if node == :generator, do: :generate, else: :b_generate
          level = %{bound: bound, generator: {tag, 0, pattern, gen}, filters: []}
          {prefix, [level | levels], env}

        %{node: :filter, expr: filter}, {prefix, levels, env} ->
          {filter, env} = compile_filter(filter, env)

          case levels do
            [] -> {[filter | prefix], levels, env}
            [level | rest] -> {prefix, [%{level | filters: [filter | level.filters]} | rest], env}
          end
      end)

    {template, env} = compile_template.(env)
    levels = levels |> Enum.reverse() |> Enum.map(&%{&1 | filters: Enum.reverse(&1.filters)})
    outer = bound_vars(outer_vars)
    prefix = Enum.reverse(prefix)

    call =
      case {kind, levels} do
        {:mc, [_, _ | _]} ->
          list = comprehension_levels(:lc, prefix, levels, template, outer, env)
          {[key, value], env} = fresh_vars(2, env)
          generator = {:generate, 0, tuple([key, value]), list}
          mc = {:mc, 0, {:map_field_assoc, 0, key, value}, [generator]}
          lift(:mc, captured_vars(mc, outer), fn _self -> mc end, env)

        _ ->
          comprehension_levels(kind, prefix, levels, template, outer, env)
      end

    {call, %{env | vars: outer_vars}}
  end

  defp comprehension_levels(kind, prefix, [], template, outer, env) do
    form = comprehension_form(kind, template, prefix)
    lift(kind, captured_vars(form, outer), fn _self -> form end, env)
  end

  defp comprehension_levels(kind, prefix, levels, template, outer, env) do
    [innermost | outer_levels] = Enum.reverse(levels)

    {innermost_qualifiers, innermost_bound} =
      if outer_levels == [], do: {prefix, outer}, else: {[], innermost.bound}

    inner =
      kind
      |> comprehension_form(
        template,
        innermost_qualifiers ++ [innermost.generator | innermost.filters]
      )
      |> then(&lift(kind, captured_vars(&1, innermost_bound), fn _self -> &1 end, env))

    outer_levels
    |> Enum.with_index(1)
    |> Enum.reduce(inner, fn {level, position}, inner ->
      qualifiers =
        if(position == length(outer_levels), do: prefix, else: []) ++
          [level.generator | level.filters]

      form =
        case kind do
          :bc ->
            {:bc, 0, {:bin, 0, [{:bin_element, 0, inner, :default, [:bitstring]}]}, qualifiers}

          _lc ->
            state = Process.get(@lift_key)
            Process.put(@lift_key, %{state | append?: true})
            {:call, 0, {:atom, 0, @lc_append}, [{:lc, 0, inner, qualifiers}]}
        end

      bound = if position == length(outer_levels), do: outer, else: level.bound
      lift(kind, captured_vars(form, bound), fn _self -> form end, env)
    end)
  end

  defp comprehension_form(:lc, template, qualifiers), do: {:lc, 0, template, qualifiers}
  defp comprehension_form(:bc, template, qualifiers), do: {:bc, 0, template, qualifiers}

  defp comprehension_form(:mc, {:tuple, _, [key, value]}, qualifiers),
    do: {:mc, 0, {:map_field_assoc, 0, key, value}, qualifiers}

  # A comprehension filter that is a guard test runs as a guard (an exception
  # skips the element); any other filter is an expression. Record access is
  # the one construct whose lowering depends on that choice, so a filter that
  # uses it is first lowered guard-style and kept only if the result is a
  # guard test, the way `erl_expand_records` decides.
  defp compile_filter(expr, env) do
    lift_state = Process.get(@lift_key)

    {filter, guard_env} =
      compile_expr(expr, %{env | record_guard: true, record_accessed: false})

    accessed? = guard_env.record_accessed

    guard_env = %{
      guard_env
      | record_guard: env.record_guard,
        record_accessed: env.record_accessed or accessed?
    }

    if not accessed? or :erl_lint.is_guard_test(filter) do
      {filter, guard_env}
    else
      Process.put(@lift_key, lift_state)
      {filter, env} = compile_expr(expr, env)
      {filter, %{env | record_accessed: true}}
    end
  end

  defp lc_append_function(%{append?: false}), do: []

  defp lc_append_function(%{append?: true}) do
    [
      {:function, 0, @lc_append, 1,
       [
         {:clause, 0, [{:cons, 0, var(:lc_head), var(:lc_tail)}], [],
          [{:op, 0, :++, var(:lc_head), {:call, 0, atom(@lc_append), [var(:lc_tail)]}}]},
         {:clause, 0, [{nil, 0}], [], [{nil, 0}]}
       ]}
    ]
  end

  # Every generated function and fun ends in a clause that matches anything:
  # when the guest clauses can fail, an explicit `function_clause` error with
  # the same arguments. Without it the OTP compiler names the fallback after
  # the function (`-inlined-safe_f_N/A-`, `-safe_f_N/2-inlined-K-`).
  defp close_function_clauses({:function, anno, name, arity, clauses}) do
    {:function, anno, name, arity, clauses |> close_funs() |> close_clauses(arity)}
  end

  defp close_function_clauses(form), do: form

  defp close_funs({:fun, anno, {:clauses, [{:clause, _, patterns, _, _} | _] = clauses}}),
    do: {:fun, anno, {:clauses, clauses |> close_funs() |> close_clauses(length(patterns))}}

  defp close_funs(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> close_funs() |> List.to_tuple()

  defp close_funs(term) when is_list(term), do: Enum.map(term, &close_funs/1)
  defp close_funs(term), do: term

  defp close_clauses(clauses, arity) do
    if total_clause?(List.last(clauses)) do
      clauses
    else
      args = Enum.map(0..(arity - 1)//1, &var(Hyperlang.GeneratedAtoms.variable!(&1)))
      error = remote_call(:erlang, :error, [atom(:function_clause), list(args)])
      clauses ++ [{:clause, 0, args, [], [error]}]
    end
  end

  defp total_clause?({:clause, _anno, patterns, [], _body}) do
    names = for {:var, _, name} <- patterns, name != :_, do: name

    Enum.all?(patterns, &match?({:var, _, _}, &1)) and
      length(names) == length(Enum.uniq(names))
  end

  defp total_clause?(_clause), do: false

  defp record_definition(env, name), do: Map.fetch!(env.records, name)

  defp record_field_index(definitions, field),
    do: Enum.find_index(definitions, &(&1.name == field)) + 2

  defp record_default(%{default: nil}, env), do: {atom(:undefined), env}
  defp record_default(%{default: default}, env), do: compile_expr(default, env)

  defp record_error(value),
    do: remote_call(:erlang, :error, [tuple([atom(:badrecord), value])])

  defp simple_value?({:var, _anno, _name}), do: true

  defp simple_value?(form) do
    _ = :erl_parse.normalise(form)
    true
  rescue
    _ -> false
  end

  defp named_fun_name(name, env) do
    safe_name = Hyperlang.GeneratedAtoms.variable!(env.next_var)
    fun_env = %{env | vars: Map.put(env.vars, name, safe_name), next_var: env.next_var + 1}
    outer_env = %{fun_env | vars: env.vars}
    {safe_name, fun_env, outer_env}
  end

  defp new_env do
    %{
      vars: %{},
      next_var: 0,
      local_functions: %{},
      inline_functions: %{},
      inline_stack: [],
      constant_list_functions: %{},
      constant_nth_helpers: %{},
      constant_length_helpers: %{},
      rune_helpers: %{},
      manifest: nil,
      atom_pool: %{},
      records: %{},
      record_guard: false,
      record_accessed: false,
      guest_dictionary_namespace: :frame,
      current_function: nil,
      current_span: nil,
      newchan_index: 0,
      mode: :expr
    }
  end

  defp helper_functions(core, manifest) do
    local_functions =
      core.functions
      |> Map.new(fn {{source, arity}, fun} -> {{source, arity}, fun.safe_name} end)

    inline_functions = inline_functions(core)
    constant_list_functions = constant_list_functions(core)
    constant_nth_helpers = constant_nth_helpers(core)
    constant_length_helpers = constant_length_helpers(core)
    rune_helpers = rune_helpers(core)
    atom_pool = Map.get(core.metadata[:atom_pool] || %{}, :source_to_pool, %{})
    guest_dictionary_namespace = :frame
    records = Map.new(core.metadata[:records] || [], &{&1.name, &1.fields})

    helpers =
      core.function_order
      |> Enum.map(&Map.fetch!(core.functions, &1))
      |> Enum.map(
        &helper_function(
          &1,
          manifest,
          local_functions,
          inline_functions,
          constant_list_functions,
          constant_nth_helpers,
          constant_length_helpers,
          rune_helpers,
          atom_pool,
          guest_dictionary_namespace,
          records
        )
      )

    helpers ++
      constant_tuple_helper_functions(
        core,
        manifest,
        local_functions,
        inline_functions,
        atom_pool,
        guest_dictionary_namespace
      ) ++ snapshot_apply_function(core, atom_pool)
  end

  # The one dispatcher behind every guest `apply/3` site of a source snapshot.
  # Each site's candidate set is the whole snapshot function index, so all
  # sites share one set. Inlining the dispatch at every site emitted one
  # case of several hundred clauses per site (three in the gen_server
  # facades, each inside a guest `try`), and `beam_ssa_opt` on those copies
  # took about three quarters of the module's OTP compile time.
  defp snapshot_apply_function(core, atom_pool) do
    case core.functions |> snapshot_apply_candidates([]) |> Enum.uniq() do
      [] ->
        []

      [candidates] ->
        env = %{new_env() | atom_pool: atom_pool}
        {[target, function, args], env} = fresh_vars(3, env)

        clauses =
          candidates
          |> Enum.filter(fn candidate ->
            atom_literal_available?(candidate.module, env) and
              atom_literal_available?(candidate.source_function, env)
          end)
          |> Enum.map(fn candidate ->
            {arg_vars, _env} = fresh_vars(candidate.arity, env)
            module_atom = atom_literal(candidate.module, env)
            function_atom = atom_literal(candidate.source_function, env)
            call = {:call, 0, atom(candidate.function), [var(:ctx) | arg_vars]}

            {:clause, 0, [var(:ctx), atom(module_atom), atom(function_atom), list(arg_vars)], [],
             [call]}
          end)

        fallback =
          {:clause, 0, [var(:ctx), target, function, args], [],
           [remote_call(@runtime, :dynamic_apply_stdlib, [var(:ctx), target, function, args])]}

        [{:function, 0, @snapshot_apply, 4, clauses ++ [fallback]}]

      _divergent ->
        raise "snapshot apply sites carry divergent candidate sets"
    end
  end

  defp snapshot_apply_candidates(
         %{node: :safe_snapshot_apply, candidates: candidates} = term,
         acc
       ),
       do:
         term
         |> Map.delete(:candidates)
         |> Map.values()
         |> snapshot_apply_candidates([candidates | acc])

  defp snapshot_apply_candidates(%{} = term, acc),
    do: term |> Map.values() |> snapshot_apply_candidates(acc)

  defp snapshot_apply_candidates(term, acc) when is_tuple(term),
    do: term |> Tuple.to_list() |> snapshot_apply_candidates(acc)

  defp snapshot_apply_candidates(term, acc) when is_list(term),
    do: Enum.reduce(term, acc, &snapshot_apply_candidates/2)

  defp snapshot_apply_candidates(_term, acc), do: acc

  defp helper_function(
         %Core.Function{} = fun,
         manifest,
         local_functions,
         inline_functions,
         constant_list_functions,
         constant_nth_helpers,
         constant_length_helpers,
         rune_helpers,
         atom_pool,
         guest_dictionary_namespace,
         records
       ) do
    {clauses, _newchan_index} =
      Enum.map_reduce(fun.clauses, 0, fn clause, newchan_index ->
        env = %{
          new_env()
          | local_functions: local_functions,
            inline_functions: inline_functions,
            constant_list_functions: constant_list_functions,
            constant_nth_helpers: constant_nth_helpers,
            constant_length_helpers: constant_length_helpers,
            rune_helpers: rune_helpers,
            manifest: manifest,
            atom_pool: atom_pool,
            records: records,
            guest_dictionary_namespace: guest_dictionary_namespace,
            current_function: {fun.source_name, fun.arity},
            current_span: fun.span,
            newchan_index: newchan_index
        }

        {patterns, env} = compile_patterns(clause.patterns, env)
        {guard, env} = compile_guard(clause.guard, env)
        {body, env} = compile_expr(clause.body, env)
        {{:clause, 0, [var(:ctx) | patterns], guard, [body]}, env.newchan_index}
      end)

    {:function, 0, fun.safe_name, fun.arity + 1, clauses}
  end

  defp constant_list_functions(%Core{} = core) do
    core.functions
    |> Enum.flat_map(fn
      {{source, 0} = key, %Core.Function{} = fun} ->
        case constant_list_items(fun) do
          {:ok, items} ->
            [
              {key,
               %{source: source, safe_name: fun.safe_name, items: items, length: length(items)}}
            ]

          :error ->
            []
        end

      _other ->
        []
    end)
    |> Map.new()
  end

  defp constant_tuple_helper_functions(
         core,
         manifest,
         local_functions,
         inline_functions,
         atom_pool,
         guest_dictionary_namespace
       ) do
    constant_lists = constant_list_functions(core)

    core.function_order
    |> Enum.flat_map(fn key ->
      case Map.fetch(constant_lists, key) do
        {:ok, %{source: source, safe_name: safe_name, items: items}} ->
          env = %{
            new_env()
            | local_functions: local_functions,
              inline_functions: inline_functions,
              constant_list_functions: constant_lists,
              manifest: manifest,
              atom_pool: atom_pool,
              guest_dictionary_namespace: guest_dictionary_namespace,
              current_function: {source, 0},
              newchan_index: 0
          }

          {tuple_body, _env} = compile_expr(%{node: :tuple, items: items}, env)

          [
            {:function, 0, safe_name, 2,
             [
               {:clause, 0, [var(:ctx), atom(@constant_tuple_tag)], [], [tuple_body]}
             ]}
          ]

        :error ->
          []
      end
    end)
  end

  defp constant_nth_helpers(%Core{} = core) do
    core.functions
    |> Enum.flat_map(fn {key, fun} ->
      case constant_nth_helper(fun) do
        {:ok, spec} -> [{key, spec}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  defp constant_nth_helper(%Core.Function{
         clauses: [
           %Core.Clause{
             patterns: patterns,
             guard: nil,
             body: %{
               node: :safe_stdlib_call,
               target: {:direct, :lists, :nth},
               args: [index_expr, %{node: :var, name: table_name}]
             }
           }
         ]
       }) do
    with {:ok, params} <- parameter_names(patterns),
         {:ok, index_name, index_offset} <- nth_index_expr(index_expr),
         {:ok, table_position} <- parameter_position(params, table_name),
         {:ok, index_position} <- parameter_position(params, index_name) do
      {:ok, %{table_arg: table_position, index_arg: index_position, index_offset: index_offset}}
    end
  end

  defp constant_nth_helper(_fun), do: :error

  defp constant_length_helpers(%Core{} = core) do
    core.functions
    |> Enum.flat_map(fn {key, fun} ->
      case constant_length_helper(fun) do
        {:ok, spec} -> [{key, spec}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  defp constant_length_helper(%Core.Function{
         clauses: [
           %Core.Clause{
             patterns: patterns,
             guard: nil,
             body: %{
               node: :safe_stdlib_call,
               target: {:direct, :erlang, :length},
               args: [%{node: :var, name: table_name}]
             }
           }
         ]
       }) do
    with {:ok, params} <- parameter_names(patterns),
         {:ok, table_position} <- parameter_position(params, table_name) do
      {:ok, %{table_arg: table_position}}
    end
  end

  defp constant_length_helper(_fun), do: :error

  defp rune_helpers(%Core{} = core) do
    rune_views = rune_view_functions(core)
    rune_binaries = rune_binary_functions(core)

    core.functions
    |> Enum.flat_map(fn {key, fun} ->
      case rune_helper(fun, rune_views, rune_binaries) do
        {:ok, spec} -> [{key, spec}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  defp rune_view_functions(%Core{} = core) do
    core.functions
    |> Enum.flat_map(fn
      {{_source, 1} = key, %Core.Function{} = fun} ->
        if rune_view_function?(fun), do: [key], else: []

      _other ->
        []
    end)
    |> MapSet.new()
  end

  defp rune_view_function?(%Core.Function{
         clauses: [
           nil_clause,
           empty_binary_clause,
           binary_clause,
           list_clause
         ]
       }) do
    rune_nil_clause?(nil_clause) and
      rune_empty_binary_clause?(empty_binary_clause) and
      rune_binary_clause?(binary_clause) and
      rune_list_clause?(list_clause)
  end

  defp rune_view_function?(_fun), do: false

  defp rune_nil_clause?(%Core.Clause{
         patterns: [%{node: :literal_pattern, literal: %{node: :atom, value: "nil"}}],
         guard: nil,
         body: %{node: :list, items: []}
       }),
       do: true

  defp rune_nil_clause?(_clause), do: false

  defp rune_empty_binary_clause?(%Core.Clause{
         patterns: [%{node: :binary, parts: parts}],
         guard: nil,
         body: %{node: :list, items: []}
       }) do
    empty_binary_pattern_parts?(parts)
  end

  defp rune_empty_binary_clause?(_clause), do: false

  defp empty_binary_pattern_parts?([]), do: true

  defp empty_binary_pattern_parts?([
         %{
           node: :bit_segment,
           expr: %{node: :literal_pattern, literal: %{node: :string, value: ""}}
         }
       ]),
       do: true

  defp empty_binary_pattern_parts?(_parts), do: false

  defp rune_binary_clause?(%Core.Clause{
         patterns: [%{node: :var_pattern, name: name}],
         guard: %{
           node: :safe_stdlib_call,
           target: {:direct, :erlang, :is_binary},
           args: [%{node: :var, name: name}]
         },
         body: %{
           node: :safe_stdlib_call,
           target: {:wrapped, :unicode, :characters_to_list},
           args: [%{node: :var, name: name}]
         }
       }),
       do: true

  defp rune_binary_clause?(_clause), do: false

  defp rune_list_clause?(%Core.Clause{
         patterns: [%{node: :var_pattern, name: name}],
         guard: %{
           node: :safe_stdlib_call,
           target: {:direct, :erlang, :is_list},
           args: [%{node: :var, name: name}]
         },
         body: %{node: :var, name: name}
       }),
       do: true

  defp rune_list_clause?(_clause), do: false

  defp rune_binary_functions(%Core{} = core) do
    core.functions
    |> Enum.flat_map(fn
      {{_source, 1} = key, %Core.Function{} = fun} ->
        if rune_binary_function?(fun), do: [key], else: []

      _other ->
        []
    end)
    |> MapSet.new()
  end

  defp rune_binary_function?(%Core.Function{
         clauses: [
           %Core.Clause{
             patterns: [%{node: :var_pattern, name: name}],
             guard: nil,
             body: %{
               node: :safe_stdlib_call,
               target: {:wrapped, :unicode, :characters_to_binary},
               args: [%{node: :var, name: name}]
             }
           }
         ]
       }),
       do: true

  defp rune_binary_function?(_fun), do: false

  defp rune_helper(%Core.Function{} = fun, rune_views, rune_binaries) do
    Enum.find_value(
      [
        &rune_len_helper(&1, rune_views),
        &rune_at_helper(&1, rune_views),
        &rune_tail_helper(&1, rune_views, rune_binaries),
        &rune_slice_helper(&1, rune_views, rune_binaries)
      ],
      :error,
      fn recognizer ->
        case recognizer.(fun) do
          {:ok, spec} -> {:ok, spec}
          :error -> nil
        end
      end
    )
  end

  defp rune_len_helper(
         %Core.Function{
           clauses: [
             %Core.Clause{
               patterns: patterns,
               guard: nil,
               body: %{
                 node: :safe_stdlib_call,
                 target: {:direct, :erlang, :length},
                 args: [runes_expr]
               }
             }
           ]
         },
         rune_views
       ) do
    with {:ok, params} <- parameter_names(patterns),
         {:ok, source_name} <- rune_view_arg(runes_expr, rune_views),
         {:ok, source_arg} <- parameter_position(params, source_name) do
      {:ok, %{kind: :rune_len, source_arg: source_arg}}
    end
  end

  defp rune_len_helper(_fun, _rune_views), do: :error

  defp rune_at_helper(
         %Core.Function{
           clauses: [
             %Core.Clause{
               patterns: patterns,
               guard: nil,
               body: %{
                 node: :safe_stdlib_call,
                 target: {:direct, :lists, :nth},
                 args: [index_expr, runes_expr]
               }
             }
           ]
         },
         rune_views
       ) do
    with {:ok, params} <- parameter_names(patterns),
         {:ok, index_name, 1} <- nth_index_expr(index_expr),
         {:ok, source_name} <- rune_view_arg(runes_expr, rune_views),
         {:ok, source_arg} <- parameter_position(params, source_name),
         {:ok, index_arg} <- parameter_position(params, index_name) do
      {:ok, %{kind: :rune_at, source_arg: source_arg, index_arg: index_arg}}
    end
  end

  defp rune_at_helper(_fun, _rune_views), do: :error

  defp rune_tail_helper(
         %Core.Function{
           clauses: [
             %Core.Clause{
               patterns: patterns,
               guard: nil,
               body: binary_expr
             }
           ]
         },
         rune_views,
         rune_binaries
       ) do
    with {:ok, inner} <- rune_binary_arg(binary_expr, rune_binaries),
         %{
           node: :safe_stdlib_call,
           target: {:direct, :lists, :nthtail},
           args: [%{node: :var, name: index_name}, runes_expr]
         } <- inner,
         {:ok, params} <- parameter_names(patterns),
         {:ok, source_name} <- rune_view_arg(runes_expr, rune_views),
         {:ok, source_arg} <- parameter_position(params, source_name),
         {:ok, index_arg} <- parameter_position(params, index_name) do
      {:ok, %{kind: :rune_tail, source_arg: source_arg, index_arg: index_arg}}
    else
      _ -> :error
    end
  end

  defp rune_tail_helper(_fun, _rune_views, _rune_binaries), do: :error

  defp rune_slice_helper(
         %Core.Function{
           clauses: [
             %Core.Clause{
               patterns: patterns,
               guard: nil,
               body: binary_expr
             }
           ]
         },
         rune_views,
         rune_binaries
       ) do
    with {:ok, inner} <- rune_binary_arg(binary_expr, rune_binaries),
         %{
           node: :safe_stdlib_call,
           target: {:direct, :lists, :sublist},
           args: [runes_expr, start_expr, length_expr]
         } <- inner,
         {:ok, start_name, 1} <- nth_index_expr(start_expr),
         {:ok, stop_name, ^start_name} <- rune_slice_length_expr(length_expr),
         {:ok, params} <- parameter_names(patterns),
         {:ok, source_name} <- rune_view_arg(runes_expr, rune_views),
         {:ok, source_arg} <- parameter_position(params, source_name),
         {:ok, start_arg} <- parameter_position(params, start_name),
         {:ok, stop_arg} <- parameter_position(params, stop_name) do
      {:ok,
       %{kind: :rune_slice, source_arg: source_arg, start_arg: start_arg, stop_arg: stop_arg}}
    else
      _ -> :error
    end
  end

  defp rune_slice_helper(_fun, _rune_views, _rune_binaries), do: :error

  defp rune_view_arg(
         %{
           node: :safe_local_call,
           source_function: source,
           arity: 1,
           args: [%{node: :var, name: name}]
         },
         rune_views
       ) do
    if MapSet.member?(rune_views, {source, 1}), do: {:ok, name}, else: :error
  end

  defp rune_view_arg(_expr, _rune_views), do: :error

  defp rune_binary_arg(
         %{node: :safe_local_call, source_function: source, arity: 1, args: [inner]},
         rune_binaries
       ) do
    if MapSet.member?(rune_binaries, {source, 1}), do: {:ok, inner}, else: :error
  end

  defp rune_binary_arg(_expr, _rune_binaries), do: :error

  defp rune_slice_length_expr(%{
         node: :binary_op,
         op: "-",
         left: %{node: :var, name: stop_name},
         right: %{node: :var, name: start_name}
       }),
       do: {:ok, stop_name, start_name}

  defp rune_slice_length_expr(_expr), do: :error

  defp constant_list_items(%Core.Function{
         clauses: [%Core.Clause{patterns: [], guard: nil, body: %{node: :list, items: items}}]
       }) do
    if Enum.all?(items, &constant_literal_expr?/1), do: {:ok, items}, else: :error
  end

  defp constant_list_items(_fun), do: :error

  defp constant_literal_expr?(%{node: node})
       when node in [:int, :float, :bool, :string, :atom],
       do: true

  defp constant_literal_expr?(%{node: :list, items: items}),
    do: Enum.all?(items, &constant_literal_expr?/1)

  defp constant_literal_expr?(%{node: :tuple, items: items}),
    do: Enum.all?(items, &constant_literal_expr?/1)

  defp constant_literal_expr?(%{node: :unary, op: op, expr: %{node: node}})
       when op in ["+", "-"] and node in [:int, :float],
       do: true

  defp constant_literal_expr?(%{node: :map, fields: fields}) do
    Enum.all?(fields, fn field ->
      constant_literal_expr?(field.key) and constant_literal_expr?(field.value)
    end)
  end

  defp constant_literal_expr?(_expr), do: false

  defp parameter_names(patterns) do
    Enum.reduce_while(patterns, {:ok, []}, fn
      %{node: :var_pattern, name: name}, {:ok, names} -> {:cont, {:ok, [name | names]}}
      _pattern, _acc -> {:halt, :error}
    end)
    |> case do
      {:ok, names} -> {:ok, Enum.reverse(names)}
      :error -> :error
    end
  end

  defp parameter_position(params, name) do
    case Enum.find_index(params, &(&1 == name)) do
      nil -> :error
      index -> {:ok, index}
    end
  end

  defp nth_index_expr(%{node: :var, name: name}), do: {:ok, name, 0}

  defp nth_index_expr(%{
         node: :binary_op,
         op: "+",
         left: %{node: :var, name: name},
         right: %{node: :int, value: offset}
       })
       when is_integer(offset),
       do: {:ok, name, offset}

  defp nth_index_expr(%{
         node: :binary_op,
         op: "+",
         left: %{node: :int, value: offset},
         right: %{node: :var, name: name}
       })
       when is_integer(offset),
       do: {:ok, name, offset}

  defp nth_index_expr(_expr), do: :error

  defp constant_table_local_call(%{node: :safe_local_call}, %{mode: :guard}),
    do: :error

  defp constant_table_local_call(
         %{node: :safe_local_call, source_function: source, arity: arity, args: args},
         env
       ) do
    key = {source, arity}

    cond do
      Map.has_key?(env.constant_nth_helpers, key) ->
        constant_nth_local_call(args, Map.fetch!(env.constant_nth_helpers, key), env)

      Map.has_key?(env.constant_length_helpers, key) ->
        constant_length_local_call(args, Map.fetch!(env.constant_length_helpers, key), env)

      true ->
        :error
    end
  end

  defp constant_table_local_call(_call, _env), do: :error

  defp rune_local_call(%{node: :safe_local_call}, %{mode: :guard}), do: :error

  defp rune_local_call(
         %{node: :safe_local_call, source_function: source, arity: arity, args: args},
         env
       ) do
    case Map.fetch(env.rune_helpers, {source, arity}) do
      {:ok, spec} -> compile_rune_local_call(args, spec, env)
      :error -> :error
    end
  end

  defp rune_local_call(_call, _env), do: :error

  defp compile_rune_local_call(args, %{kind: :rune_len, source_arg: source_arg}, env) do
    with {:ok, source} <- Enum.fetch(args, source_arg) do
      {source, env} = compile_expr(source, env)
      {:ok, remote_call(@runtime, :rune_len, [var(:ctx), source]), env}
    else
      _ -> :error
    end
  end

  defp compile_rune_local_call(
         args,
         %{kind: :rune_at, source_arg: source_arg, index_arg: index_arg},
         env
       ) do
    with {:ok, source} <- Enum.fetch(args, source_arg),
         {:ok, index} <- Enum.fetch(args, index_arg) do
      {source, env} = compile_expr(source, env)
      {index, env} = compile_expr(index, env)
      {:ok, remote_call(@runtime, :rune_at, [var(:ctx), source, index]), env}
    else
      _ -> :error
    end
  end

  defp compile_rune_local_call(
         args,
         %{kind: :rune_tail, source_arg: source_arg, index_arg: index_arg},
         env
       ) do
    with {:ok, source} <- Enum.fetch(args, source_arg),
         {:ok, index} <- Enum.fetch(args, index_arg) do
      {source, env} = compile_expr(source, env)
      {index, env} = compile_expr(index, env)
      {:ok, remote_call(@runtime, :rune_tail, [var(:ctx), source, index]), env}
    else
      _ -> :error
    end
  end

  defp compile_rune_local_call(
         args,
         %{kind: :rune_slice, source_arg: source_arg, start_arg: start_arg, stop_arg: stop_arg},
         env
       ) do
    with {:ok, source} <- Enum.fetch(args, source_arg),
         {:ok, start} <- Enum.fetch(args, start_arg),
         {:ok, stop} <- Enum.fetch(args, stop_arg) do
      {source, env} = compile_expr(source, env)
      {start, env} = compile_expr(start, env)
      {stop, env} = compile_expr(stop, env)
      {:ok, remote_call(@runtime, :rune_slice, [var(:ctx), source, start, stop]), env}
    else
      _ -> :error
    end
  end

  defp inline_local_call(%{node: :safe_local_call}, %{mode: :guard}), do: :error

  defp inline_local_call(
         %{node: :safe_local_call, source_function: source, arity: arity, args: args},
         env
       ) do
    key = {source, arity}

    with false <- key in env.inline_stack,
         {:ok, spec} <- Map.fetch(env.inline_functions, key),
         true <- inline_args_safe?(args) do
      body = substitute_inline_expr(spec.body, Map.new(Enum.zip(spec.params, args)))

      compile_expr(body, %{env | inline_stack: [key | env.inline_stack]})
      |> then(fn {expr, env} -> {:ok, expr, %{env | inline_stack: tl(env.inline_stack)}} end)
    else
      _ -> :error
    end
  end

  defp inline_local_call(_call, _env), do: :error

  defp inline_functions(%Core{} = core) do
    core.functions
    |> Enum.flat_map(fn {key, fun} ->
      case inline_function(fun) do
        {:ok, spec} -> [{key, spec}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  defp inline_function(%Core.Function{clauses: [%Core.Clause{} = clause]}) do
    with true <- inline_guard_empty?(clause.guard),
         {:ok, params} <- inline_params(clause.patterns),
         true <- inline_body_safe?(clause.body) do
      {:ok, %{params: params, body: clause.body}}
    else
      _ -> :error
    end
  end

  defp inline_function(_fun), do: :error

  defp inline_guard_empty?(guard), do: guard in [nil, []]

  defp inline_params(patterns) do
    Enum.reduce_while(patterns, {:ok, []}, fn
      %{node: :var_pattern, name: name}, {:ok, names} when name != "_" ->
        if name in names do
          {:halt, :error}
        else
          {:cont, {:ok, [name | names]}}
        end

      _pattern, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, names} -> {:ok, Enum.reverse(names)}
      :error -> :error
    end
  end

  defp inline_args_safe?(args), do: Enum.all?(args, &inline_arg_safe?/1)

  defp inline_arg_safe?(%{node: node}) when node in [:var, :int, :float, :bool, :atom, :string],
    do: true

  defp inline_arg_safe?(%{node: :list, items: items}), do: Enum.all?(items, &inline_arg_safe?/1)
  defp inline_arg_safe?(%{node: :tuple, items: items}), do: Enum.all?(items, &inline_arg_safe?/1)
  defp inline_arg_safe?(%{node: :binary, parts: parts}), do: Enum.all?(parts, &inline_arg_safe?/1)

  defp inline_arg_safe?(%{node: :bit_segment, expr: expr, size: size}),
    do: inline_arg_safe?(expr) and inline_size_safe(size)

  defp inline_arg_safe?(_expr), do: false

  defp inline_body_safe?(%{node: node}) when node in [:var, :int, :float, :bool, :atom, :string],
    do: true

  defp inline_body_safe?(%{node: :list, items: items}), do: Enum.all?(items, &inline_body_safe?/1)

  defp inline_body_safe?(%{node: :tuple, items: items}),
    do: Enum.all?(items, &inline_body_safe?/1)

  defp inline_body_safe?(%{node: :binary, parts: parts}),
    do: Enum.all?(parts, &inline_body_safe?/1)

  defp inline_body_safe?(%{node: :bit_segment, expr: expr, size: size}),
    do: inline_body_safe?(expr) and inline_size_safe(size)

  defp inline_body_safe?(%{node: :unary, expr: expr}), do: inline_body_safe?(expr)

  defp inline_body_safe?(%{node: :binary_op, left: left, right: right}),
    do: inline_body_safe?(left) and inline_body_safe?(right)

  defp inline_body_safe?(%{node: :map, fields: fields}), do: inline_fields_safe?(fields)

  defp inline_body_safe?(%{node: :map_update, base: base, fields: fields}),
    do: inline_body_safe?(base) and inline_fields_safe?(fields)

  defp inline_body_safe?(%{node: :safe_local_call, args: args}), do: inline_body_safe?(args)
  defp inline_body_safe?(%{node: :safe_stdlib_call, args: args}), do: inline_body_safe?(args)

  defp inline_body_safe?(exprs) when is_list(exprs), do: Enum.all?(exprs, &inline_body_safe?/1)
  defp inline_body_safe?(_expr), do: false

  defp inline_fields_safe?(fields) do
    Enum.all?(fields, fn field ->
      inline_body_safe?(field.key) and inline_body_safe?(field.value)
    end)
  end

  defp substitute_inline_expr(%{node: :var, name: name} = expr, bindings),
    do: Map.get(bindings, name, expr)

  defp substitute_inline_expr(%{node: :list, items: items} = expr, bindings),
    do: %{expr | items: Enum.map(items, &substitute_inline_expr(&1, bindings))}

  defp substitute_inline_expr(%{node: :tuple, items: items} = expr, bindings),
    do: %{expr | items: Enum.map(items, &substitute_inline_expr(&1, bindings))}

  defp substitute_inline_expr(%{node: :binary, parts: parts} = expr, bindings),
    do: %{expr | parts: Enum.map(parts, &substitute_inline_expr(&1, bindings))}

  defp substitute_inline_expr(%{node: :bit_segment, expr: inner, size: size} = expr, bindings),
    do: %{
      expr
      | expr: substitute_inline_expr(inner, bindings),
        size: substitute_inline_size(size, bindings)
    }

  defp substitute_inline_expr(%{node: :unary, expr: inner} = expr, bindings),
    do: %{expr | expr: substitute_inline_expr(inner, bindings)}

  defp substitute_inline_expr(%{node: :binary_op, left: left, right: right} = expr, bindings),
    do: %{
      expr
      | left: substitute_inline_expr(left, bindings),
        right: substitute_inline_expr(right, bindings)
    }

  defp substitute_inline_expr(%{node: :map, fields: fields} = expr, bindings),
    do: %{expr | fields: substitute_inline_fields(fields, bindings)}

  defp substitute_inline_expr(%{node: :map_update, base: base, fields: fields} = expr, bindings),
    do: %{
      expr
      | base: substitute_inline_expr(base, bindings),
        fields: substitute_inline_fields(fields, bindings)
    }

  defp substitute_inline_expr(%{node: :safe_local_call, args: args} = expr, bindings),
    do: %{expr | args: Enum.map(args, &substitute_inline_expr(&1, bindings))}

  defp substitute_inline_expr(%{node: :safe_stdlib_call, args: args} = expr, bindings),
    do: %{expr | args: Enum.map(args, &substitute_inline_expr(&1, bindings))}

  defp substitute_inline_expr(expr, _bindings), do: expr

  defp inline_size_safe(:default), do: true
  defp inline_size_safe(size), do: inline_body_safe?(size)

  defp substitute_inline_size(:default, _bindings), do: :default
  defp substitute_inline_size(size, bindings), do: substitute_inline_expr(size, bindings)

  defp substitute_inline_fields(fields, bindings) do
    Enum.map(fields, fn field ->
      %{
        field
        | key: substitute_inline_expr(field.key, bindings),
          value: substitute_inline_expr(field.value, bindings)
      }
    end)
  end

  defp constant_nth_local_call(args, %{table_arg: table_arg, index_arg: index_arg} = spec, env) do
    with {:ok, table} <- Enum.fetch(args, table_arg),
         {:ok, index} <- Enum.fetch(args, index_arg),
         {:ok, constant_table} <- constant_table_call(table, env) do
      {index_expr, env} = compile_expr(index, env)
      index_expr = add_index_offset(index_expr, Map.fetch!(spec, :index_offset))
      {expr, env} = constant_tuple_nth_expr(index_expr, constant_table, env)
      {:ok, expr, env}
    else
      _ -> :error
    end
  end

  defp constant_length_local_call(args, %{table_arg: table_arg}, env) do
    with {:ok, table} <- Enum.fetch(args, table_arg),
         {:ok, %{length: length}} <- constant_table_call(table, env) do
      {:ok, {:integer, 0, length}, env}
    else
      _ -> :error
    end
  end

  defp constant_table_call(
         %{node: :safe_local_call, source_function: source, arity: 0, args: []},
         env
       ) do
    Map.fetch(env.constant_list_functions, {source, 0})
  end

  defp constant_table_call(_expr, _env), do: :error

  defp add_index_offset(index_expr, 0), do: index_expr

  defp add_index_offset(index_expr, offset) when is_integer(offset),
    do: {:op, 0, :+, index_expr, {:integer, 0, offset}}

  defp constant_tuple_nth_expr(index_expr, %{safe_name: table_fun}, env) do
    {[index, tuple], env} = fresh_vars(2, env)
    tuple_call = {:call, 0, {:atom, 0, table_fun}, [var(:ctx), atom(@constant_tuple_tag)]}
    list_call = {:call, 0, {:atom, 0, table_fun}, [var(:ctx)]}

    valid_index? =
      {:op, 0, :andalso, remote_call(:erlang, :is_integer, [index]),
       {:op, 0, :andalso, {:op, 0, :>=, index, {:integer, 0, 1}},
        {:op, 0, :"=<", index, remote_call(:erlang, :tuple_size, [tuple])}}}

    result =
      {:case, 0, valid_index?,
       [
         {:clause, 0, [atom(true)], [], [remote_call(:erlang, :element, [index, tuple])]},
         {:clause, 0, [atom(false)], [],
          [
            remote_call(@runtime, :stdlib, [
              var(:ctx),
              atom(:lists),
              atom(:nth),
              list([index, list_call])
            ])
          ]}
       ]}

    {{:block, 0,
      [
        {:match, 0, index, index_expr},
        {:match, 0, tuple, tuple_call},
        result
      ]}, env}
  end

  defp var_name("_", env), do: {:_, env}

  defp var_name(name, env) do
    case env.vars do
      %{^name => var} ->
        {var, env}

      _ ->
        var = Hyperlang.GeneratedAtoms.variable!(env.next_var)
        {var, %{env | vars: Map.put(env.vars, name, var), next_var: env.next_var + 1}}
    end
  end

  defp var(name), do: {:var, 0, name}
  defp atom(name), do: {:atom, 0, name}
  defp tuple(items), do: {:tuple, 0, items}
  defp charlist(value), do: {:string, 0, String.to_charlist(value)}

  defp map_field(%{op: ":="}, key, value), do: {:map_field_exact, 0, key, value}
  defp map_field(%{op: "=>"}, key, value), do: {:map_field_assoc, 0, key, value}
  defp map_field(_field, key, value), do: {:map_field_assoc, 0, key, value}

  defp compile_is_record(args, %{mode: :guard} = env), do: {is_record_expr(args), env}

  defp compile_is_record(args, env) do
    {vars, env} = fresh_vars(length(args), env)

    {{:case, 0, tuple(args), [{:clause, 0, [tuple(vars)], [], [is_record_expr(vars)]}]}, env}
  end

  defp is_record_expr([term, name]) do
    guard_and([
      remote_call(:erlang, :is_atom, [name]),
      remote_call(:erlang, :is_tuple, [term]),
      {:op, 0, :>=, remote_call(:erlang, :tuple_size, [term]), {:integer, 0, 1}},
      {:op, 0, :"=:=", remote_call(:erlang, :element, [{:integer, 0, 1}, term]), name}
    ])
  end

  defp is_record_expr([term, name, size]) do
    guard_and([
      remote_call(:erlang, :is_atom, [name]),
      remote_call(:erlang, :is_integer, [size]),
      {:op, 0, :>=, size, {:integer, 0, 1}},
      remote_call(:erlang, :is_tuple, [term]),
      {:op, 0, :"=:=", remote_call(:erlang, :tuple_size, [term]), size},
      {:op, 0, :"=:=", remote_call(:erlang, :element, [{:integer, 0, 1}, term]), name}
    ])
  end

  defp guard_and([expr]), do: expr
  defp guard_and([left | rest]), do: {:op, 0, :andalso, left, guard_and(rest)}

  defp guest_dictionary_get_expr(key, env) do
    {[compiled_key, storage_key, matched], env} = fresh_vars(3, env)

    process_body =
      {:block, 0,
       [
         {:match, 0, storage_key, guest_dictionary_storage_key(env, compiled_key)},
         {:case, 0, remote_call(:erlang, :get, [storage_key]),
          [
            {:clause, 0, [tuple([atom(@guest_process_dictionary_value_tag), matched])], [],
             [matched]},
            {:clause, 0, [var(:_)], [], [atom(:undefined)]}
          ]}
       ]}

    {{:block, 0, [{:match, 0, compiled_key, key}, process_body]}, env}
  end

  defp guest_dictionary_put_expr(key, value, env) do
    {[compiled_key, compiled_value, storage_key, previous], env} = fresh_vars(4, env)
    {index_update, env} = guest_dictionary_add_index_expr(env, compiled_key)

    dependencies_update =
      guest_dictionary_store_dependencies_expr(env, compiled_key, compiled_value)

    value_tuple = tuple([atom(@guest_process_dictionary_value_tag), compiled_value])

    process_body =
      {:block, 0,
       [
         {:match, 0, storage_key, guest_dictionary_storage_key(env, compiled_key)},
         {:case, 0, remote_call(:erlang, :get, [storage_key]),
          [
            {:clause, 0, [tuple([atom(@guest_process_dictionary_value_tag), previous])], [],
             [
               remote_call(:erlang, :put, [storage_key, value_tuple]),
               dependencies_update,
               previous
             ]},
            {:clause, 0, [var(:_)], [],
             [
               index_update,
               remote_call(:erlang, :put, [storage_key, value_tuple]),
               dependencies_update,
               atom(:undefined)
             ]}
          ]}
       ]}

    {
      {:block, 0,
       [{:match, 0, compiled_key, key}, {:match, 0, compiled_value, value}, process_body]},
      env
    }
  end

  defp guest_dictionary_erase_expr(key, env) do
    {[compiled_key, storage_key, previous], env} = fresh_vars(3, env)
    {index_update, env} = guest_dictionary_delete_index_expr(env, compiled_key)
    dependencies_delete = guest_dictionary_delete_dependencies_expr(env, compiled_key)

    process_body =
      {:block, 0,
       [
         {:match, 0, storage_key, guest_dictionary_storage_key(env, compiled_key)},
         {:case, 0, remote_call(:erlang, :get, [storage_key]),
          [
            {:clause, 0, [tuple([atom(@guest_process_dictionary_value_tag), previous])], [],
             [
               remote_call(:erlang, :erase, [storage_key]),
               index_update,
               dependencies_delete,
               previous
             ]},
            {:clause, 0, [var(:_)], [], [atom(:undefined)]}
          ]}
       ]}

    {{:block, 0, [{:match, 0, compiled_key, key}, process_body]}, env}
  end

  defp guest_dictionary_storage_key(%{guest_dictionary_namespace: namespace}, key)
       when not is_nil(namespace),
       do:
         tuple([
           atom(@guest_process_dictionary_value_tag),
           guest_dictionary_namespace_expr(namespace),
           key
         ])

  defp guest_dictionary_storage_key(_env, key),
    do: tuple([atom(@guest_process_dictionary_value_tag), key])

  defp guest_dictionary_index_key(%{guest_dictionary_namespace: namespace})
       when not is_nil(namespace),
       do:
         tuple([
           atom(@guest_process_dictionary_index_key),
           guest_dictionary_namespace_expr(namespace)
         ])

  defp guest_dictionary_index_key(_env), do: atom(@guest_process_dictionary_index_key)

  defp guest_dictionary_store_dependencies_expr(env, key, value) do
    remote_call(@runtime, :guest_dictionary_store_dependencies, [
      guest_dictionary_namespace_value(env),
      key,
      value
    ])
  end

  defp guest_dictionary_delete_dependencies_expr(env, key) do
    remote_call(@runtime, :guest_dictionary_delete_dependencies, [
      guest_dictionary_namespace_value(env),
      key
    ])
  end

  defp guest_dictionary_namespace_value(%{guest_dictionary_namespace: namespace})
       when not is_nil(namespace),
       do: guest_dictionary_namespace_expr(namespace)

  defp guest_dictionary_namespace_value(_env), do: atom(nil)

  defp guest_dictionary_add_index_expr(%{guest_dictionary_namespace: namespace} = env, key) do
    index_key = guest_dictionary_index_key(env)
    {[index], env} = fresh_vars(1, env)
    {index_expr, env} = guest_dictionary_index_expr(index_key, env)
    {namespace_exprs, env} = guest_dictionary_add_namespace_expr(namespace, env)

    expressions =
      [
        {:match, 0, index, index_expr},
        remote_call(:erlang, :put, [index_key, maps_put_expr(key, atom(true), index)])
      ] ++ namespace_exprs

    {{:block, 0, expressions}, env}
  end

  defp guest_dictionary_delete_index_expr(%{guest_dictionary_namespace: namespace} = env, key) do
    index_key = guest_dictionary_index_key(env)
    {[updated], env} = fresh_vars(1, env)
    {index_expr, env} = guest_dictionary_index_expr(index_key, env)
    {namespace_exprs, env} = guest_dictionary_delete_namespace_expr(namespace, env)

    empty_update =
      [remote_call(:erlang, :erase, [index_key])] ++ namespace_exprs

    {
      {:block, 0,
       [
         {:match, 0, updated, remote_call(:maps, :remove, [key, index_expr])},
         {:case, 0, remote_call(:erlang, :map_size, [updated]),
          [
            {:clause, 0, [{:integer, 0, 0}], [], empty_update},
            {:clause, 0, [var(:_)], [], [remote_call(:erlang, :put, [index_key, updated])]}
          ]}
       ]},
      env
    }
  end

  defp guest_dictionary_index_expr(index_key, env) do
    {[value], env} = fresh_vars(1, env)

    {
      {:case, 0, remote_call(:erlang, :get, [index_key]),
       [
         {:clause, 0, [value], [[remote_call(:erlang, :is_map, [value])]], [value]},
         {:clause, 0, [var(:_)], [], [abstract_term(%{})]}
       ]},
      env
    }
  end

  defp guest_dictionary_add_namespace_expr(namespace, env) when not is_nil(namespace) do
    {namespaces_expr, env} = guest_dictionary_namespaces_expr(env)
    namespace_expr = guest_dictionary_namespace_expr(namespace)

    {
      [
        remote_call(:erlang, :put, [
          atom(@guest_process_dictionary_namespaces_key),
          maps_put_expr(
            namespace_expr,
            atom(true),
            namespaces_expr
          )
        ])
      ],
      env
    }
  end

  defp guest_dictionary_add_namespace_expr(_namespace, env), do: {[], env}

  defp guest_dictionary_delete_namespace_expr(namespace, env) when not is_nil(namespace) do
    {[updated], env} = fresh_vars(1, env)
    {namespaces_expr, env} = guest_dictionary_namespaces_expr(env)
    namespace_expr = guest_dictionary_namespace_expr(namespace)

    {
      [
        {:match, 0, updated,
         remote_call(:maps, :remove, [
           namespace_expr,
           namespaces_expr
         ])},
        {:case, 0, remote_call(:erlang, :map_size, [updated]),
         [
           {:clause, 0, [{:integer, 0, 0}], [],
            [remote_call(:erlang, :erase, [atom(@guest_process_dictionary_namespaces_key)])]},
           {:clause, 0, [var(:_)], [],
            [
              remote_call(:erlang, :put, [atom(@guest_process_dictionary_namespaces_key), updated])
            ]}
         ]}
      ],
      env
    }
  end

  defp guest_dictionary_delete_namespace_expr(_namespace, env), do: {[], env}

  defp guest_dictionary_namespaces_expr(env) do
    {[value], env} = fresh_vars(1, env)

    {
      {:case, 0, remote_call(:erlang, :get, [atom(@guest_process_dictionary_namespaces_key)]),
       [
         {:clause, 0, [value], [[remote_call(:erlang, :is_map, [value])]], [value]},
         {:clause, 0, [var(:_)], [], [abstract_term(%{})]}
       ]},
      env
    }
  end

  defp guest_dictionary_namespace_expr(:frame),
    do: remote_call(:erlang, :get, [atom(@guest_process_dictionary_frame_key)])

  defp maps_put_expr(key, value, map),
    do: {:map, 0, map, [{:map_field_assoc, 0, key, value}]}

  defp fresh_vars(count, env) do
    if count == 0 do
      {[], env}
    else
      fresh_nonzero_vars(count, env)
    end
  end

  defp fresh_nonzero_vars(count, env) do
    Enum.map_reduce(1..count//1, env, fn _index, env ->
      name = Hyperlang.GeneratedAtoms.variable!(env.next_var)
      {var(name), %{env | next_var: env.next_var + 1}}
    end)
  end

  defp atom_literal(value, env) do
    Map.get(env.atom_pool, value) || String.to_existing_atom(value)
  end

  defp atom_literal_available?(value, env) do
    Map.has_key?(env.atom_pool, value) or existing_atom?(value)
  end

  defp existing_atom?(value) do
    _ = String.to_existing_atom(value)
    true
  rescue
    ArgumentError -> false
  end

  defp pattern_var_names(patterns) when is_list(patterns) do
    patterns
    |> Enum.flat_map(&pattern_var_names/1)
    |> Enum.reject(&(&1 == "_"))
    |> Enum.uniq()
  end

  defp pattern_var_names(%{node: :var_pattern, name: name}), do: [name]

  defp pattern_var_names(%{node: :alias_pattern, left: left, right: right}),
    do: pattern_var_names([left, right])

  defp pattern_var_names(%{node: :tuple_pattern, items: items}), do: pattern_var_names(items)
  defp pattern_var_names(%{node: :list_pattern, items: items}), do: pattern_var_names(items)

  defp pattern_var_names(%{node: :cons_pattern, head: head, tail: tail}),
    do: pattern_var_names([head, tail])

  defp pattern_var_names(%{node: :map_pattern, fields: fields}) do
    Enum.flat_map(fields, &pattern_var_names(&1.value))
  end

  defp pattern_var_names(%{node: :binary, parts: parts}), do: pattern_var_names(parts)
  defp pattern_var_names(%{node: :bit_segment, expr: expr}), do: pattern_var_names(expr)

  defp pattern_var_names(_pattern), do: []

  defp list(items) do
    Enum.reduce(Enum.reverse(items), {nil, 0}, fn item, acc -> {:cons, 0, item, acc} end)
  end

  defp remote_call(module, function, args) do
    {:call, 0, {:remote, 0, atom(module), atom(function)}, args}
  end

  defp abstract_term(term) do
    case term do
      value when is_integer(value) ->
        {:integer, 0, value}

      value when is_float(value) ->
        {:float, 0, value}

      value when is_boolean(value) ->
        atom(value)

      nil ->
        atom(nil)

      value when is_atom(value) ->
        atom(value)

      value when is_binary(value) ->
        {:bin, 0,
         [{:bin_element, 0, {:string, 0, String.to_charlist(value)}, :default, :default}]}

      value when is_list(value) ->
        list(Enum.map(value, &abstract_term/1))

      value when is_tuple(value) ->
        tuple(value |> Tuple.to_list() |> Enum.map(&abstract_term/1))

      value when is_map(value) ->
        {:map, 0,
         Enum.map(value, fn {k, v} ->
           {:map_field_assoc, 0, abstract_term(k), abstract_term(v)}
         end)}
    end
  end

  defp op_atom("andalso"), do: :andalso
  defp op_atom("orelse"), do: :orelse
  defp op_atom("div"), do: :div
  defp op_atom("rem"), do: :rem
  defp op_atom("not"), do: :not
  defp op_atom(op), do: String.to_existing_atom(op)

  def verify_generated_forms(forms, module \\ :hyperlang_pending_slot) do
    with :ok <- verify_generated_attributes(forms),
         :ok <- verify_generated_module(forms, module),
         :ok <- verify_generated_syntax(forms),
         :ok <- verify_compiler_named_constructs(forms),
         :ok <- FormTools.ensure_revertible(forms),
         :ok <- verify_generated_calls(forms) do
      :ok
    end
  end

  # The OTP compiler names funs, comprehensions and receive loops after their
  # enclosing function and a per-function counter. Generated code keeps each
  # such construct as the whole body of its own lifted `safe_f_N/2`; only the
  # fixed entry functions hold zero-arity thunks. Anything else would let a
  # guest grow the compiler's name set.
  defp verify_compiler_named_constructs(forms) do
    bad =
      for {:function, _anno, name, arity, clauses} <- forms,
          not compiler_named_constructs_allowed?(name, arity, clauses),
          do: {name, arity}

    if bad == [] do
      :ok
    else
      {:error,
       Hyperlang.Error.new(
         :generated_form_verify,
         "generated forms contain a compiler-named construct outside a lifted function",
         details: %{functions: bad}
       )}
    end
  end

  defp compiler_named_constructs_allowed?(name, 2, [{:clause, _, _, [], [body]} | rest]) do
    lifted? =
      String.match?(Atom.to_string(name), ~r/^safe_f_\d+$/) and
        case body do
          {:fun, _, {:clauses, clauses}} ->
            named_constructs(clauses) in [[], [:receive]]

          {:call, _, {:atom, _, @lc_append}, [{:lc, _, template, qualifiers}]} ->
            named_constructs([template, qualifiers]) == []

          {kind, _, template, qualifiers} when kind in [:lc, :bc, :mc] ->
            named_constructs([template, qualifiers]) == []

          _other ->
            false
        end

    (lifted? and named_constructs(rest) == []) or named_constructs([body | rest]) == []
  end

  defp compiler_named_constructs_allowed?(name, _arity, clauses)
       when name in [@entry, @export] do
    clauses
    |> thunk_bodies([])
    |> Enum.all?(&(named_constructs(&1) == []))
  end

  defp compiler_named_constructs_allowed?(_name, _arity, clauses),
    do: named_constructs(clauses) == []

  # Zero-arity thunks are replaced by their bodies; any other construct stays.
  defp thunk_bodies({:fun, _, {:clauses, [{:clause, _, [], [], body}]}}, acc), do: [body | acc]

  defp thunk_bodies(term, acc) when is_tuple(term) do
    if named_construct(term) != nil,
      do: [[term] | acc],
      else: term |> Tuple.to_list() |> thunk_bodies(acc)
  end

  defp thunk_bodies(term, acc) when is_list(term), do: Enum.reduce(term, acc, &thunk_bodies/2)
  defp thunk_bodies(_term, acc), do: acc

  defp named_constructs(term) when is_tuple(term) do
    case named_construct(term) do
      nil -> term |> Tuple.to_list() |> named_constructs()
      kind -> [kind | term |> Tuple.to_list() |> named_constructs()]
    end
  end

  defp named_constructs(term) when is_list(term), do: Enum.flat_map(term, &named_constructs/1)
  defp named_constructs(_term), do: []

  defp named_construct({:fun, _, {:clauses, _}}), do: :fun
  defp named_construct({:named_fun, _, _, _}), do: :named_fun
  defp named_construct({kind, _, _, _}) when kind in [:lc, :bc, :mc], do: kind
  defp named_construct({:receive, _, _}), do: :receive
  defp named_construct({:receive, _, _, _, _}), do: :receive
  defp named_construct(_term), do: nil

  # The OTP compiler names the clause-split labels of a function `label^K`
  # with a per-function counter. Bounding the split points per function
  # bounds that name set to `label^0..label^(max - 1)`.
  defp verify_pattern_splits(forms, lifted_meta, core, manifest) do
    limit = manifest.limits.max_pattern_splits

    owners =
      Map.merge(
        Map.new(core.functions, fn {{source, arity}, fun} -> {fun.safe_name, {source, arity}} end),
        Map.new(lifted_meta, fn {name, meta} -> {name, meta.function} end)
      )

    over =
      for {:function, _anno, name, arity, clauses} <- forms,
          Hyperlang.GeneratedAtoms.pattern_split_weight(clauses) > limit,
          do: Map.get(owners, name, {name, arity})

    if over == [] do
      :ok
    else
      {:error,
       Hyperlang.Error.new(:codegen, "binary pattern split limit exceeded",
         details: %{limit: limit, functions: Enum.map(over, &inspect/1)}
       )}
    end
  end

  defp verify_generated_attributes(forms) do
    bad =
      Enum.filter(forms, fn
        {:attribute, _anno, :module, module} ->
          not is_atom(module)

        {:attribute, _anno, :export, exports} ->
          not valid_generated_exports?(exports)

        {:attribute, _anno, _name, _value} ->
          true

        {:function, _anno, _name, _arity, _clauses} ->
          false

        _ ->
          true
      end)

    if bad == [] do
      :ok
    else
      {:error,
       Hyperlang.Error.new(
         :generated_form_verify,
         "generated forms contain unexpected attributes"
       )}
    end
  end

  defp valid_generated_exports?(exports) when is_list(exports) do
    MapSet.new(exports) == MapSet.new([{@entry, 3}, {@export, 4}, {@raw_export, 3}])
  end

  defp valid_generated_exports?(_exports), do: false

  defp verify_generated_module(forms, allowed_module) do
    valid? =
      Enum.any?(forms, fn
        {:attribute, _anno, :module, ^allowed_module} -> true
        _ -> false
      end)

    if valid? do
      :ok
    else
      {:error,
       Hyperlang.Error.new(:generated_form_verify, "generated module attribute is invalid")}
    end
  end

  defp verify_generated_syntax(forms) do
    forbidden = walk_forbidden_syntax(forms, [])

    if forbidden == [] do
      :ok
    else
      {:error,
       Hyperlang.Error.new(:generated_form_verify, "generated forms contain forbidden syntax",
         details: %{forms: forbidden}
       )}
    end
  end

  # Attribute payloads are intentionally validated by verify_generated_attributes/1;
  # keep that allowlist tight if new generated attribute kinds are introduced.
  defp verify_generated_calls(forms) do
    calls = walk_forms(forms, [])
    bad = Enum.filter(calls, &(not generated_call_allowed?(&1)))

    if bad == [] do
      :ok
    else
      {:error,
       Hyperlang.Error.new(:generated_form_verify, "generated forms contain forbidden calls",
         details: %{calls: bad}
       )}
    end
  end

  defp walk_forms(term, acc) when is_tuple(term) do
    acc =
      case term do
        {:call, _a, {:remote, _ra, {:atom, _ma, m}, {:atom, _fa, f}}, args} ->
          [{m, f, length(args)} | acc]

        {:call, _a, {:atom, _fa, f}, args} ->
          [{:local, f, length(args)} | acc]

        _ ->
          acc
      end

    term |> Tuple.to_list() |> Enum.reduce(acc, &walk_forms/2)
  end

  defp walk_forms(list, acc) when is_list(list), do: Enum.reduce(list, acc, &walk_forms/2)
  defp walk_forms(_term, acc), do: acc

  defp walk_forbidden_syntax({:attribute, _anno, _name, _value}, acc), do: acc

  defp walk_forbidden_syntax(term, acc) when is_tuple(term) do
    acc =
      case term do
        {:call, _anno, {:remote, _ra, {:atom, _ma, _m}, {:atom, _fa, _f}}, _args} ->
          acc

        {:call, _anno, {:atom, _fa, _f}, _args} ->
          acc

        {:call, anno, _callee, _args} ->
          [{:dynamic_call, anno} | acc]

        {:op, anno, :!, _left, _right} ->
          [{:send, anno} | acc]

        # Every generated receive must have envelope-wrapped clause patterns
        # ({'$hyperlang_msg', _, P}). compile_receive_clauses is the single wrapping
        # choke point today; this check makes a future codegen path that emits
        # a bare receive a hard verifier failure instead of a silent kernel-
        # message exposure.
        {:receive, anno, clauses} ->
          if bare_receive_clause?(clauses), do: [{:bare_receive, anno} | acc], else: acc

        {:receive, anno, clauses, _timeout, _body} ->
          if bare_receive_clause?(clauses), do: [{:bare_receive, anno} | acc], else: acc

        {:fun, anno, {:function, _function, _arity}} ->
          [{:external_fun, anno} | acc]

        {:fun, anno, {:function, _module, _function, _arity}} ->
          [{:external_fun, anno} | acc]

        tuple ->
          if generated_tuple_shape?(tuple) do
            acc
          else
            [{:unknown_tuple, elem(tuple, 0)} | acc]
          end
      end

    term |> Tuple.to_list() |> Enum.reduce(acc, &walk_forbidden_syntax/2)
  end

  defp walk_forbidden_syntax(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &walk_forbidden_syntax/2)

  defp walk_forbidden_syntax(_term, acc), do: acc

  defp generated_tuple_shape?({:function, _anno, _name, _arity, _clauses}), do: true
  defp generated_tuple_shape?({:clause, _anno, _patterns, _guards, _body}), do: true
  defp generated_tuple_shape?({:var, _anno, _name}), do: true
  defp generated_tuple_shape?({:atom, _anno, _value}), do: true
  defp generated_tuple_shape?({:integer, _anno, _value}), do: true
  defp generated_tuple_shape?({:float, _anno, _value}), do: true
  defp generated_tuple_shape?({:char, _anno, _value}), do: true
  defp generated_tuple_shape?({:string, _anno, _value}), do: true
  defp generated_tuple_shape?({nil, _anno}), do: true
  defp generated_tuple_shape?({:cons, _anno, _head, _tail}), do: true
  defp generated_tuple_shape?({:tuple, _anno, _items}), do: true
  defp generated_tuple_shape?({:map, _anno, _fields}), do: true
  defp generated_tuple_shape?({:map, _anno, _base, _fields}), do: true
  defp generated_tuple_shape?({:map_field_assoc, _anno, _key, _value}), do: true
  defp generated_tuple_shape?({:map_field_exact, _anno, _key, _value}), do: true
  defp generated_tuple_shape?({:bin, _anno, _elements}), do: true
  defp generated_tuple_shape?({:bin_element, _anno, _expr, _size, _types}), do: true
  defp generated_tuple_shape?({:unit, _size}), do: true

  defp generated_tuple_shape?({:op, _anno, _op, _expr}), do: true
  defp generated_tuple_shape?({:op, _anno, _op, _left, _right}), do: true
  defp generated_tuple_shape?({:match, _anno, _pattern, _expr}), do: true
  defp generated_tuple_shape?({:block, _anno, _exprs}), do: true
  defp generated_tuple_shape?({:remote, _anno, _module, _function}), do: true
  defp generated_tuple_shape?({:case, _anno, _expr, _clauses}), do: true
  defp generated_tuple_shape?({:if, _anno, _clauses}), do: true
  defp generated_tuple_shape?({:fun, _anno, {:clauses, _clauses}}), do: true
  defp generated_tuple_shape?({:clauses, _clauses}), do: true
  defp generated_tuple_shape?({:try, _anno, _body, _of_clauses, _catch_clauses, _after}), do: true
  defp generated_tuple_shape?({:lc, _anno, _expr, _qualifiers}), do: true
  defp generated_tuple_shape?({:mc, _anno, _expr, _qualifiers}), do: true
  defp generated_tuple_shape?({:bc, _anno, _expr, _qualifiers}), do: true
  defp generated_tuple_shape?({:generate, _anno, _pattern, _expr}), do: true
  defp generated_tuple_shape?({:b_generate, _anno, _pattern, _expr}), do: true
  defp generated_tuple_shape?(_tuple), do: false

  defp bare_receive_clause?(clauses) when is_list(clauses) do
    Enum.any?(clauses, fn
      {:clause, _anno, [{:tuple, _ta, [{:atom, _aa, :"$hyperlang_msg"}, _from, _pattern]}],
       _guards, _body} ->
        false

      _other ->
        true
    end)
  end

  defp bare_receive_clause?(_), do: true

  defp generated_call_allowed?({:local, function, _arity}) do
    function in [:safe_result, @snapshot_apply, @lc_append] or
      String.match?(Atom.to_string(function), ~r/^safe_f_\d+$/)
  end

  # Every non-local generated call is admitted by the ONE gate table in
  # Hyperlang.Stdlib. Codegen does not keep a parallel list.
  defp generated_call_allowed?({module, function, arity}),
    do: Hyperlang.Stdlib.generated_call_allowed?(module, function, arity)

  defp replace_pending_version({:atom, anno, @pending_version}, version)
       when is_integer(version),
       do: {:integer, anno, version}

  defp replace_pending_version(tuple, version) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&replace_pending_version(&1, version))
    |> List.to_tuple()
  end

  defp replace_pending_version(list, version) when is_list(list),
    do: Enum.map(list, &replace_pending_version(&1, version))

  defp replace_pending_version(term, _version), do: term
end
