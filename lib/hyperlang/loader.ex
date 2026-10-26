defmodule Hyperlang.Loader do
  @moduledoc false

  @loader_calls %{
    {"compile", "file", 1} => :compile_file,
    {"compile", "file", 2} => :compile_file
  }

  def supported_mfas do
    @loader_calls
    |> Map.keys()
    |> Enum.sort()
  end

  @loader_key :"$hyperlang_loader_modules"
  @compile_count_key :"$hyperlang_loader_compile_count"

  def call_target(%{filesystem: filesystem}, module, function, arity),
    do: call_target(filesystem, module, function, arity)

  def call_target(
        %{enabled: true, file_compat: true, loader_compat: true, source_compile: true},
        "compile",
        "file",
        arity
      )
      when arity in [1, 2],
      do: Map.fetch!(@loader_calls, {"compile", "file", arity})

  def call_target(_filesystem, _module, _function, _arity), do: :error

  @doc false
  # The compile:file module registry, read by the single `code:ensure_loaded/1`
  # owner (`Hyperlang.Code`). Guest source compiled through this loader is
  # registered here and nowhere else, so the discovery surface asks the loader
  # rather than running a second dispatcher over the same registry.
  def registered_module(ctx, module_atom) when is_atom(module_atom) do
    with %{} = filesystem <- Map.get(ctx.manifest, :filesystem),
         true <-
           Map.get(filesystem, :enabled, false) and Map.get(filesystem, :loader_compat, false),
         {:ok, source_name} <- atom_source(ctx, module_atom),
         {:ok, %{atom: ^module_atom}} <- loaded_module(ctx, source_name) do
      {:module, module_atom}
    else
      _other -> {:error, :nofile}
    end
  end

  def call_diagnostic(%{filesystem: filesystem}, module, function, arity),
    do: call_diagnostic(filesystem, module, function, arity)

  def call_diagnostic(%{} = filesystem, module, function, arity)
      when module in ["compile", "code", "erl_eval"] do
    cond do
      call_target(filesystem, module, function, arity) != :error ->
        nil

      module == "compile" and function == "file" and arity in [1, 2] and
          not Map.get(filesystem, :enabled, false) ->
        loader_call_error(
          module,
          function,
          arity,
          :filesystem_disabled,
          "standard Erlang filesystem compatibility is disabled"
        )

      module == "compile" and function == "file" and arity in [1, 2] and
          not Map.get(filesystem, :loader_compat, false) ->
        loader_call_error(
          module,
          function,
          arity,
          :loader_compat_disabled,
          "standard Erlang loader/evaluator compatibility is disabled"
        )

      module == "compile" and function == "file" and arity in [1, 2] and
          not Map.get(filesystem, :source_compile, false) ->
        loader_call_error(
          module,
          function,
          arity,
          :source_compile_disabled,
          "standard Erlang source compilation compatibility is disabled"
        )

      module == "compile" and function == "file" and arity in [1, 2] and
          not Map.get(filesystem, :file_compat, false) ->
        loader_call_error(
          module,
          function,
          arity,
          :file_compat_disabled,
          "standard Erlang file compatibility is disabled"
        )

      module == "code" and function == "ensure_loaded" and arity == 1 and
          not Map.get(filesystem, :enabled, false) ->
        loader_call_error(
          module,
          function,
          arity,
          :filesystem_disabled,
          "standard Erlang filesystem compatibility is disabled"
        )

      module == "code" and function == "ensure_loaded" and arity == 1 and
          not Map.get(filesystem, :loader_compat, false) ->
        loader_call_error(
          module,
          function,
          arity,
          :loader_compat_disabled,
          "standard Erlang loader/evaluator compatibility is disabled"
        )

      module == "erl_eval" ->
        loader_call_error(
          module,
          function,
          arity,
          :evaluator_compat_disabled,
          "standard Erlang evaluator compatibility is disabled"
        )

      true ->
        loader_call_error(
          module,
          function,
          arity,
          :unsupported_loader_mfa,
          "standard Erlang loader/evaluator call is not supported by Hyperlang"
        )
    end
  end

  def call_diagnostic(_filesystem, module, function, arity)
      when module in ["compile", "code", "erl_eval"] do
    loader_call_error(
      module,
      function,
      arity,
      :loader_compat_disabled,
      "standard Erlang loader/evaluator compatibility is disabled"
    )
  end

  def call_diagnostic(_filesystem, _module, _function, _arity), do: nil

  def dispatch(ctx, :compile_file, [path]), do: dispatch(ctx, :compile_file, [path, []])

  def dispatch(ctx, :compile_file, [path, options]) when is_list(options) do
    with :ok <- check_compile_budget(ctx),
         {:ok, handle} <- filesystem_handle(ctx),
         {:ok, source} <- Hyperlang.Filesystem.source_read_file(handle, path),
         :ok <- check_source_size(ctx, source),
         {:ok, source_name} <- source_module_name(source, path, ctx),
         {:ok, module_atom} <- source_atom(ctx, source_name),
         :ok <- verify_source_module(ctx, source),
         :ok <- check_loaded_module_limit(ctx, source_name) do
      put_module(ctx, source_name, %{
        atom: module_atom,
        path: path,
        source_hash: Hyperlang.Program.sha256_hex(source),
        options: options
      })

      {:ok, {:ok, module_atom}}
    else
      {:error, reason} when is_atom(reason) -> {:ok, {:error, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  def dispatch(_ctx, :compile_file, [_path, _options]), do: {:ok, {:error, :badarg}}

  def dispatch(_ctx, operation, args),
    do: {:error, {:unsupported_loader_call, operation, length(args)}}

  defp filesystem_handle(%{filesystem: %Hyperlang.Filesystem.Handle{} = handle}),
    do: {:ok, handle}

  defp filesystem_handle(_ctx), do: {:error, :filesystem_not_attached}

  defp check_compile_budget(ctx) do
    max_compiles = ctx.manifest.filesystem.limits.max_compiles_per_eval
    count = Process.get(@compile_count_key, 0)

    if count < max_compiles do
      Process.put(@compile_count_key, count + 1)
      :ok
    else
      {:error, :enospc}
    end
  end

  defp check_source_size(ctx, source) when is_binary(source) do
    if byte_size(source) <= ctx.manifest.filesystem.limits.max_source_file_bytes do
      :ok
    else
      {:error, :eoverflow}
    end
  end

  defp check_source_size(_ctx, _source), do: {:error, :badarg}

  defp verify_source_module(ctx, source) do
    case Hyperlang.Compiler.verify_module_source(source, ctx.manifest) do
      {:ok, _core} -> :ok
      {:error, _errors} -> {:error, :badarg}
    end
  end

  defp source_module_name(source, path, ctx) when is_binary(source) do
    with {:ok, names} <- Hyperlang.OtpFrontend.source_module_names(source, ctx.manifest) do
      case names do
        # A source with no `-module` attribute takes its name from the path; a
        # basename that names no module is the guest's own `:badarg`.
        [] ->
          case Hyperlang.Program.module_name_from_basename(path) do
            {:ok, name} -> {:ok, name}
            :error -> {:error, :badarg}
          end

        [name] ->
          {:ok, name}

        _multiple ->
          {:error, :badarg}
      end
    end
  end

  defp source_atom(ctx, source_name) do
    cond do
      Hyperlang.Program.reserved_module_name?(source_name) ->
        {:error, :badarg}

      pool_atom = source_to_pool(ctx)[source_name] ->
        {:ok, pool_atom}

      allowed_atom = allowed_existing_atom(ctx, source_name) ->
        {:ok, allowed_atom}

      true ->
        {:error, {:atom_policy, :eoverflow}}
    end
  end

  defp atom_source(ctx, atom) do
    cond do
      source = Hyperlang.Terms.atom_source(atom, ctx) ->
        {:ok, source}

      MapSet.member?(ctx.terms.allowed_atoms, atom) ->
        {:ok, Atom.to_string(atom)}

      true ->
        {:error, :badarg}
    end
  end

  defp source_to_pool(ctx) do
    ctx.atom_pool
    |> Enum.map(fn {pool, source} -> {source, pool} end)
    |> Map.new()
  end

  defp allowed_existing_atom(ctx, source_name) do
    Enum.find(ctx.terms.allowed_atoms, &(Atom.to_string(&1) == source_name))
  end

  defp check_loaded_module_limit(ctx, source_name) do
    modules = current_modules(ctx)
    max_loaded = ctx.manifest.filesystem.limits.max_loaded_modules

    if Map.has_key?(modules, source_name) or map_size(modules) < max_loaded do
      :ok
    else
      {:error, :enospc}
    end
  end

  defp put_module(ctx, source_name, module) do
    Process.put(@loader_key, Map.put(current_modules(ctx), source_name, module))
    :ok
  end

  defp loaded_module(ctx, source_name) do
    case Map.fetch(current_modules(ctx), source_name) do
      {:ok, module} -> {:ok, module}
      :error -> :error
    end
  end

  defp current_modules(ctx) do
    Map.merge(Map.get(ctx, :loader_modules, %{}) || %{}, Process.get(@loader_key, %{}))
  end

  defp loader_call_error(module, function, arity, reason, message) do
    Hyperlang.Error.new(:verify, "#{module}:#{function}/#{arity}: #{message}",
      details: %{
        capability: :loader,
        module: module,
        function: function,
        arity: arity,
        reason: reason
      }
    )
  end
end
