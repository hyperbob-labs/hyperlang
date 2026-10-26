defmodule Hyperlang.CompatibilityAudit do
  @moduledoc false

  @compatibility_modules [
    Hyperlang.Filesystem.WildcardBridge
  ]

  @process_context_calls MapSet.new([
                           {Process, :delete, 1},
                           {Process, :get, 1},
                           {Process, :get, 2},
                           {Process, :put, 2}
                         ])

  @allowed_internal_calls %{
    Hyperlang.Filesystem.WildcardBridge => @process_context_calls
  }

  # One forbidden-call policy: the classifier owns the table (pass 1), the
  # verifier re-checks it (pass 2), this audit reads the same source for the
  # host-side compatibility modules. Only the audit-local extras are declared
  # here — Elixir facades and the BEAM-only calls a guest can never reach.
  @remote_policy Hyperlang.Classifier.forbidden_remote_table()

  @forbidden_modules @remote_policy
                     |> Map.keys()
                     # `erlang` is function-scoped below, not module-scoped.
                     |> Enum.reject(&(&1 == "erlang"))
                     |> Enum.map(&String.to_atom/1)
                     |> Enum.concat([
                       Code,
                       File,
                       Node,
                       Port,
                       Process,
                       System,
                       :filelib,
                       :socket,
                       :prim_inet
                     ])
                     |> MapSet.new()

  @forbidden_erlang_functions @remote_policy
                              |> Map.fetch!("erlang")
                              |> Enum.map(&String.to_atom/1)
                              |> Enum.concat([
                                :port_connect,
                                :send,
                                :spawn_request,
                                :spawn_request_abandon
                              ])
                              |> MapSet.new()

  def compatibility_modules, do: @compatibility_modules

  def audit_default_modules, do: audit_modules(@compatibility_modules)

  def audit_modules(modules) when is_list(modules) do
    modules
    |> Enum.flat_map(fn module ->
      case audit_module(module) do
        :ok -> []
        {:error, findings} -> findings
      end
    end)
    |> reply()
  end

  def audit_module(module) when is_atom(module) do
    with {:ok, path} <- module_beam_path(module),
         {:ok, abstract_forms} <- module_abstract_forms(module, path),
         :ok <- audit_abstract_forms(abstract_forms),
         :ok <- audit_beam_file(path) do
      :ok
    else
      {:error, findings} when is_list(findings) -> {:error, findings}
      {:error, reason} -> {:error, [%{layer: :module, module: module, reason: reason}]}
    end
  end

  def audit_abstract_forms(forms) do
    audited_module = abstract_module(forms)

    forms
    |> collect_abstract_findings(audited_module)
    |> reply()
  end

  def audit_beam_file(path) do
    path
    |> beam_term()
    |> collect_beam_findings()
    |> reply()
  end

  def forbidden_module?(module), do: MapSet.member?(@forbidden_modules, module)

  def forbidden_erlang_function?(function) do
    function = normalize_spawn_function(function)
    MapSet.member?(@forbidden_erlang_functions, function)
  end

  defp module_beam_path(module) do
    case :code.which(module) do
      path when is_list(path) -> {:ok, path}
      :preloaded -> {:error, :preloaded_module}
      :non_existing -> {:error, :module_not_found}
      other -> {:error, {:unexpected_beam_path, other}}
    end
  end

  defp module_abstract_forms(module, path) do
    case :beam_lib.chunks(path, [:abstract_code]) do
      {:ok, {^module, [abstract_code: {:raw_abstract_v1, forms}]}} ->
        {:ok, forms}

      {:ok, {^module, [abstract_code: {:debug_info_v1, _backend, data}]}} ->
        debug_info_abstract_forms(module, data)

      {:ok, {^module, [abstract_code: :no_abstract_code]}} ->
        {:error, :no_abstract_code}

      {:ok, {_other, [abstract_code: abstract]}} ->
        {:error, {:unsupported_abstract_code, abstract_kind(abstract)}}

      {:error, _module, reason} ->
        {:error, reason}
    end
  end

  defp debug_info_abstract_forms(module, {:elixir_v1, _map, specs}) do
    case :elixir_erl.debug_info(:erlang_v1, module, specs, []) do
      {:ok, forms} -> {:ok, forms}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :debug_info_unavailable}
  end

  defp debug_info_abstract_forms(_module, _data), do: {:error, :unsupported_debug_info}

  defp abstract_kind({kind, _}), do: kind
  defp abstract_kind(kind), do: kind

  defp beam_term(path) do
    case :beam_disasm.file(path) do
      {:beam_file, _module, _exports, _attributes, _compile_info, _functions} = beam -> beam
      other -> other
    end
  end

  defp collect_abstract_findings(forms, audited_module),
    do: walk(forms, [], &abstract_finding(&1, audited_module))

  defp collect_beam_findings(
         {:beam_file, module, _exports, _attributes, _compile_info, functions}
       ) do
    Enum.flat_map(functions, fn function ->
      walk(function, [], &beam_finding(&1, module))
    end)
  end

  defp collect_beam_findings(other), do: [%{layer: :beam, reason: {:unexpected_beam, other}}]

  defp abstract_finding(
         {:call, anno, {:remote, _, module_ast, function_ast}, args},
         audited_module
       ) do
    case {literal_atom(module_ast), literal_atom(function_ast)} do
      {{:ok, module}, {:ok, function}} ->
        mfa_finding(:abstract, audited_module, module, function, length(args), anno)

      _dynamic ->
        finding(:abstract, :erlang, :apply, length(args) + 2, anno)
    end
  end

  defp abstract_finding({:call, anno, {:atom, _, function}, args}, _audited_module) do
    if forbidden_erlang_function?(function) do
      %{
        layer: :abstract,
        module: :erlang,
        function: normalize_spawn_function(function),
        arity: length(args),
        location: location(anno)
      }
    end
  end

  defp abstract_finding({:op, anno, :!, _left, _right}, _audited_module) do
    %{layer: :abstract, module: :erlang, function: :send, arity: 2, location: location(anno)}
  end

  defp abstract_finding(_term, _audited_module), do: nil

  defp beam_finding({:extfunc, module, function, arity}, audited_module) do
    mfa_finding(:beam, audited_module, module, function, arity, nil)
  end

  defp beam_finding({:bif, function, _fail, args, _dest}, _audited_module) when is_list(args) do
    if forbidden_erlang_function?(function) do
      %{
        layer: :beam,
        module: :erlang,
        function: normalize_spawn_function(function),
        arity: length(args)
      }
    end
  end

  defp beam_finding(:send, _audited_module),
    do: %{layer: :beam, module: :erlang, function: :send, arity: 2}

  defp beam_finding(term, _audited_module) when is_tuple(term) and tuple_size(term) > 0 do
    op = elem(term, 0)

    cond do
      op == :send ->
        %{layer: :beam, module: :erlang, function: :send, arity: 2}

      op in [:apply, :apply_last, :apply_only] ->
        %{layer: :beam, module: :erlang, function: :apply, arity: dynamic_apply_arity(term)}

      true ->
        nil
    end
  end

  defp beam_finding(_term, _audited_module), do: nil

  defp mfa_finding(layer, audited_module, module, function, arity, anno) do
    cond do
      allowed_internal_call?(audited_module, module, function, arity) ->
        nil

      forbidden_module?(module) ->
        finding(layer, module, function, arity, anno)

      module == :erlang and forbidden_erlang_function?(function) ->
        finding(layer, module, normalize_spawn_function(function), arity, anno)

      true ->
        nil
    end
  end

  defp literal_atom({:atom, _anno, atom}) when is_atom(atom), do: {:ok, atom}
  defp literal_atom(_ast), do: :error

  defp abstract_module(forms) do
    Enum.find_value(forms, fn
      {:attribute, _anno, :module, module} when is_atom(module) -> module
      _form -> nil
    end)
  end

  defp allowed_internal_call?(nil, _module, _function, _arity), do: false

  defp allowed_internal_call?(audited_module, module, function, arity) do
    @allowed_internal_calls
    |> Map.get(audited_module, MapSet.new())
    |> MapSet.member?({module, function, arity})
  end

  defp dynamic_apply_arity(term) when tuple_size(term) > 1 do
    case elem(term, 1) do
      arity when is_integer(arity) and arity >= 0 -> arity + 2
      _other -> :dynamic
    end
  end

  defp dynamic_apply_arity(_term), do: :dynamic

  defp finding(:abstract, module, function, arity, anno) do
    %{
      layer: :abstract,
      module: module,
      function: function,
      arity: arity,
      location: location(anno)
    }
  end

  defp finding(:beam, module, function, arity, _anno) do
    %{layer: :beam, module: module, function: function, arity: arity}
  end

  defp normalize_spawn_function(function)
       when function in [:spawn, :spawn_link, :spawn_monitor, :spawn_opt],
       do: function

  defp normalize_spawn_function(function), do: function

  defp location(anno) do
    cond do
      is_list(anno) ->
        case Keyword.get(anno, :location) do
          {line, col} -> %{line: line, col: col}
          line when is_integer(line) -> %{line: line}
          _ -> nil
        end

      is_integer(anno) ->
        %{line: anno}

      true ->
        nil
    end
  end

  defp walk(term, findings, callback) do
    findings =
      case callback.(term) do
        nil -> findings
        finding -> [finding | findings]
      end

    cond do
      is_tuple(term) ->
        term
        |> Tuple.to_list()
        |> Enum.reduce(findings, &walk(&1, &2, callback))

      is_list(term) ->
        Enum.reduce(term, findings, &walk(&1, &2, callback))

      true ->
        findings
    end
  end

  defp reply([]), do: :ok
  defp reply(findings), do: {:error, Enum.reverse(findings)}
end
