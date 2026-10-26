defmodule Hyperlang.ModuleLoader do
  # Code-path module loading.
  #
  # Per eval, lazily, on the first call into each module: resolve the
  # extensionless source `Mod` through the manifest code path via the guest
  # read path, compile and verify it once per `{impl_hash, atom_universe}`, gate
  # its derived capability set against the loading program's manifest, bind it
  # for the rest of the eval, and dispatch through the generated `$safe_export`
  # ABI. Missing file, wrong `-module`, and unexported functions are
  # Erlang-shaped `undef`.
  #
  # Verification runs under a fixed derivation manifest — the full guest
  # surface (all allowlisted stdlib, filesystem facades, sys, modules) with no
  # caller bindings. The installed artifact is a pure function of the source
  # bytes, derivation shape, compiler options, and caller's opaque atom universe.
  # It is cached by `{impl_hash, atom_universe}` in the internal artifact cache,
  # with no separate verified-core/materialized-BEAM cache. Verification
  # records the artifact's derived capability set (stdlib MFAs, facade MFAs,
  # loader MFAs, referenced code-path modules); at bind time every derived
  # capability must be granted by the loading program's manifest or the load
  # fails with a `:capability_not_granted` module error. The bound library then
  # executes under the caller's manifest, limits, terms, and syscall context:
  # loading grants no authority.
  #
  # Behaviour-contract modules: a library that exports nothing — for
  # example a module carrying only `-callback` specs — still parses (the
  # attributes are accepted and recorded), but it is never compiled or bound;
  # a call into it raises Erlang's own `undef`, exactly like calling an
  # unexported function. `-behaviour(...)` references never load the named
  # module, so contract modules cost nothing until someone mistakenly calls
  # into one.
  @moduledoc false

  alias Hyperlang.{Cache, CodeServer, KernelAtomPool, Manifest, Terms}

  @bindings_key :"$hyperlang_module_bindings"
  @depth_key :"$hyperlang_module_depth"
  @chain_key :"$hyperlang_module_chain"

  # Fixed derivation manifest: the
  # full guest surface enabled and no caller bindings, so a library resolves
  # only its own module, the sticky surface, and the code path. The installed
  # artifact is keyed by source identity plus the caller's opaque atom universe;
  # this deliberately favors one simple safe artifact cache over a split
  # verified-core/materialized-BEAM cache.
  @derivation_manifest %{
    modules: %{enabled: true, callback_dispatch: true},
    sys: %{enabled: true},
    capabilities: %{nondeterminism: true},
    terms: %{public: :erlang},
    # Libraries verify under command-tier derivation budgets, not evaluator
    # defaults: /sys/lib modules can be as large as commands, and these limits
    # are anti-DoS bounds, not capabilities. Runtime execution still uses the
    # caller's manifest.
    limits: %{
      max_source_bytes: 2_000_000,
      max_line_count: 80_000,
      max_tokens: 131_072,
      max_forms: 40_000,
      max_functions: 8_192,
      max_ast_nodes: 2_000_000,
      max_compile_reductions: 3_000_000_000,
      max_compile_ms: 120_000,
      max_literal_bytes: 64_000_000,
      max_binary_bytes: 64_000_000
    },
    filesystem: %{
      enabled: true,
      file_compat: true,
      filelib_compat: true,
      handle_compat: true,
      loader_compat: true,
      atom_vocabularies: %{filesystem: true, re: true, loader: true, archive: true}
    }
  }

  def call(ctx, module, function, args)
      when is_binary(module) and is_binary(function) and is_list(args) do
    modules = Map.get(ctx.manifest, :modules, %{})

    if not Map.get(modules, :enabled, false) do
      :erlang.error(:undef)
    end

    bindings = Process.get(@bindings_key, %{})

    case Map.fetch(bindings, module) do
      {:ok, binding} ->
        binding = refresh_binding(ctx, module, binding, bindings)
        invoke_at_depth(ctx, binding, function, args, modules)

      :error ->
        resolve_and_invoke(ctx, module, function, args, modules)
    end
  end

  @doc false
  # `code:ensure_loaded/1`: run
  # load-semantics steps 1-7 — resolution, verification, capability gate,
  # binding — without invoking anything. Failures come back in OTP's own
  # vocabulary: `:nofile` (nothing resolved on the path), `:badfile`
  # (verification failure, wrong `-module`, or an unbindable export-less
  # module), `:eacces` (the derived-capability gate refused it). Loader
  # policy failures (cycle, binding table full) stay `:module`-category
  # sandbox errors, exactly as on the call path.
  def ensure_loaded(ctx, module) when is_binary(module) do
    modules = Map.get(ctx.manifest, :modules, %{})
    bindings = Process.get(@bindings_key, %{})

    cond do
      not Map.get(modules, :enabled, false) ->
        {:error, :nofile}

      Map.has_key?(bindings, module) ->
        :ok

      map_size(bindings) >= Map.fetch!(modules, :max_modules) ->
        module_error(ctx, :too_many_modules)

      true ->
        case resolve_binding(ctx, module, Map.fetch!(modules, :path)) do
          {:ok, binding} ->
            Process.put(@bindings_key, Map.put(bindings, module, binding))
            :ok

          {:error, :nofile} ->
            {:error, :nofile}

          {:error, reason} when reason in [:wrong_module, :no_exports] ->
            {:error, :badfile}

          {:error, {:module_error, :verification_failed}} ->
            {:error, :badfile}

          {:error, {:module_error, :capability_not_granted}} ->
            {:error, :eacces}

          {:error, {:module_error, reason}} ->
            module_error(ctx, reason)
        end
    end
  end

  @doc false
  # Live per-eval bindings as `module name -> resolved file path`, for
  # `code:is_loaded/1` and `code:all_available/0`.
  def binding_paths do
    Process.get(@bindings_key, %{})
    |> Map.new(fn {module, binding} -> {module, Map.get(binding, :path)} end)
  end

  @doc false
  # `code:get_doc/1`, library tier: resolution and verification without
  # registering a call binding (artifact-store hits make repeats free). An
  # export-less module (a behaviour contract) is never compiled, so its
  # chunk is built straight from parsed metadata. Sources that fail
  # verification have no docs to give: `:non_existing`.
  def doc_chunk(ctx, module) when is_binary(module) do
    modules = Map.get(ctx.manifest, :modules, %{})

    with true <- Map.get(modules, :enabled, false),
         {:ok, _file, source} <- resolve_source(ctx, module, Map.fetch!(modules, :path)),
         :ok <- check_module_name(ctx, module, source) do
      case Cache.lookup_library(library_cache_key(ctx, impl_hash(source))) do
        {:ok, _program} -> parsed_doc_chunk(ctx, source)
        :miss -> verify_doc_chunk(ctx, source)
      end
    else
      _miss -> {:error, :non_existing}
    end
  end

  defp verify_doc_chunk(ctx, source) do
    case source_exports(ctx, source) do
      {:ok, []} -> parsed_doc_chunk(ctx, source)
      {:ok, exports} -> verified_doc_chunk(ctx, source, exports)
      {:error, _reason} -> {:error, :non_existing}
    end
  end

  defp verified_doc_chunk(ctx, source, exports) do
    case verify_library(ctx, source, impl_hash(source), exports) do
      {:ok, _program} -> parsed_doc_chunk(ctx, source)
      {:error, {:module_error, :too_many_modules}} -> module_error(ctx, :too_many_modules)
      {:error, _reason} -> {:error, :non_existing}
    end
  end

  defp parsed_doc_chunk(_ctx, source) do
    manifest = library_manifest([], nil)

    case Hyperlang.OtpFrontend.source_module_metadata(source, manifest) do
      {:ok, meta} -> {:ok, Hyperlang.Docs.metadata_chunk(meta, [])}
      {:error, _error} -> {:error, :non_existing}
    end
  end

  @doc false
  # Called by the worker when an eval finishes (normal or rescued paths).
  # Program values are immutable data, so only process-local bindings need
  # clearing.
  def release_bindings(opts \\ []) do
    clear_guest_dictionary? = Keyword.get(opts, :clear_guest_dictionary?, true)

    Process.delete(@bindings_key)
    Process.delete(@depth_key)
    Process.delete(@chain_key)
    KernelAtomPool.clear()

    if clear_guest_dictionary? do
      Hyperlang.Runtime.clear_guest_dictionary()
    end

    :ok
  end

  @doc false
  def current_bindings, do: Process.get(@bindings_key, %{})

  @doc false
  def with_bindings(bindings, fun) when is_map(bindings) and is_function(fun, 0) do
    previous_bindings = Process.get(@bindings_key, :undefined)
    previous_depth = Process.get(@depth_key, :undefined)
    previous_chain = Process.get(@chain_key, :undefined)
    previous_kernel_atom_pool = KernelAtomPool.snapshot()

    Process.put(@bindings_key, bindings)
    Process.delete(@depth_key)
    Process.delete(@chain_key)
    KernelAtomPool.clear()

    try do
      fun.()
    after
      restore_process_value(@bindings_key, previous_bindings)
      restore_process_value(@depth_key, previous_depth)
      restore_process_value(@chain_key, previous_chain)
      KernelAtomPool.restore(previous_kernel_atom_pool)
    end
  end

  @doc false
  def release_binding_map(bindings) when is_map(bindings) do
    :ok
  end

  defp restore_process_value(key, :undefined), do: Process.delete(key)
  defp restore_process_value(key, value), do: Process.put(key, value)

  @doc false
  # A code-path library may call back into the caller through the host-export
  # ABI. While that callback is running, the callback body must be able to call
  # helper functions on the library that invoked it. Expose only that active
  # caller runtime as a temporary module binding; ordinary library-to-library
  # resolution still uses the normal commit-after-call rule above.
  def with_callback_binding(%{source_module: module} = runtime, fun)
      when is_binary(module) and is_function(fun, 0) do
    bindings = Process.get(@bindings_key, %{})
    binding = runtime_binding(runtime)

    Process.put(@bindings_key, Map.put_new(bindings, module, binding))

    try do
      fun.()
    after
      # In a long-lived serving process (keep_bindings), KEEP the code-path
      # module bindings (webfs/fs/...) that resolved during this call so the
      # next Styx op reuses them instead of re-resolving + re-parsing the
      # source. Drop only the temporary caller binding this function injected
      # (when the caller module was not already bound). Otherwise restore the
      # pre-call binding table exactly (one-shot eval semantics).
      if Process.get(:"$hyperlang_keep_bindings", false) do
        current = Process.get(@bindings_key, %{})
        kept = if Map.has_key?(bindings, module), do: current, else: Map.delete(current, module)
        Process.put(@bindings_key, kept)
      else
        Process.put(@bindings_key, bindings)
      end
    end
  end

  def with_callback_binding(_runtime, fun) when is_function(fun, 0), do: fun.()

  defp refresh_binding(
         ctx,
         module,
         %{program: %Hyperlang.Program{} = program} = binding,
         bindings
       ) do
    refreshed =
      binding
      |> Map.put(:runtime, refresh_binding_runtime(ctx, binding.runtime, program))
      |> Map.put(:program, program)

    Process.put(@bindings_key, Map.put(bindings, module, refreshed))
    refreshed
  end

  defp refresh_binding(_ctx, _module, binding, _bindings), do: binding

  defp refresh_binding_runtime(ctx, runtime, _program) do
    runtime
    |> Map.put(:limits, ctx.limits)
    |> Map.put(:terms, Map.delete(ctx.terms, :atom_pool))
    |> Map.put(:host_scope, ctx.host_scope)
    |> Map.put(:filesystem, Map.get(ctx, :filesystem))
    # Retarget the door's executing-program identity to the CALLEE (Inferno R.M
    # on a module call) so a sys:spawn inside this library resolves in the
    # library, not the spawner's top program. up/capabilities preserved.
    |> Map.put(:syscall, Map.get(ctx, :syscall))
    |> Map.put(:call_id, Map.get(ctx, :call_id))
    |> Map.put(:callback_runtime, callback_runtime(ctx))
    |> Map.put(
      :atom_universe,
      Map.get(ctx, :atom_universe, Map.get(ctx.manifest, :atom_universe))
    )
    |> Terms.stamp_validated_runtime()
  end

  # Load-semantics step 9: the binding commits only when the call that
  # resolved it completes, and the impl_hash stays on the active resolution
  # chain until then. A mutual source dependency therefore forces a
  # re-resolve mid-resolve and fails fast as a load cycle, while call-time
  # mutual recursion between already-committed bindings never re-resolves
  # and stays legal up to the depth cap.
  defp resolve_and_invoke(ctx, module, function, args, modules) do
    if map_size(Process.get(@bindings_key, %{})) >= Map.fetch!(modules, :max_modules) do
      module_error(ctx, :too_many_modules)
    end

    binding = load(ctx, module, Map.fetch!(modules, :path))

    chain = Process.get(@chain_key, [])
    Process.put(@chain_key, [binding.impl_hash | chain])

    try do
      invoke_at_depth(ctx, binding, function, args, modules)
    after
      Process.put(@chain_key, chain)
      Process.put(@bindings_key, Map.put(Process.get(@bindings_key, %{}), module, binding))
    end
  end

  defp invoke_at_depth(ctx, binding, function, args, modules) do
    depth = Process.get(@depth_key, 0)

    if depth >= Map.fetch!(modules, :max_depth) do
      module_error(ctx, :load_cycle)
    end

    Process.put(@depth_key, depth + 1)

    # The Terms.Opaque opaque round-trip fast path (positional State arg/return
    # slots) is meaningful ONLY at the OUTERMOST library crossing the serving
    # host drives (depth 0 here = the host's `call_module` into webfs). It must
    # NOT leak into NESTED guest-initiated crossings (webfs->fs->messages, depth
    # >= 1): those have State at no fixed slot, so applying the directive there
    # could mis-box a nested return. Strip it for nested calls.
    ctx =
      if depth == 0 do
        ctx
      else
        ctx
        |> Map.put(:opaque_state, nil)
        |> Map.put(:opaque_fixed_points, [])
      end

    try do
      invoke(ctx, binding, function, args)
    after
      Process.put(@depth_key, depth)
    end
  end

  # The call path keeps Erlang-shaped failures: missing file,
  # wrong `-module`, and unbindable export-less modules are `undef`;
  # everything else is a `:module`-category sandbox error.
  defp load(ctx, module, path) do
    case resolve_binding(ctx, module, path) do
      {:ok, binding} ->
        binding

      {:error, reason} when reason in [:nofile, :wrong_module, :no_exports] ->
        :erlang.error(:undef)

      {:error, {:module_error, reason}} ->
        module_error(ctx, reason)
    end
  end

  # Load-semantics steps 1-6 plus binding construction, with failures as
  # data so `call` (undef-shaped) and `code:ensure_loaded/1` (OTP error
  # vocabulary) can each map them.
  defp resolve_binding(ctx, module, path) do
    with {:ok, file, source} <- resolve_source(ctx, module, path),
         :ok <- check_module_name(ctx, module, source),
         impl_hash = impl_hash(source),
         :ok <- check_resolution_cycle(impl_hash),
         {:ok, artifact} <- lookup_or_verify(module, ctx, source, impl_hash) do
      case capability_violations(ctx.manifest, artifact) do
        [] ->
          {:ok,
           ctx
           |> build_binding(artifact)
           |> Map.put(:impl_hash, impl_hash)
           |> Map.put(:path, file)}

        _violations ->
          {:error, {:module_error, :capability_not_granted}}
      end
    end
  end

  # A resolve that re-enters an impl_hash already on the active resolution
  # chain is a load cycle; fail before touching the artifact store.
  defp check_resolution_cycle(impl_hash) do
    if impl_hash in Process.get(@chain_key, []),
      do: {:error, {:module_error, :load_cycle}},
      else: :ok
  end

  defp lookup_or_verify(module, ctx, source, impl_hash) do
    case Cache.lookup_library(library_cache_key(ctx, impl_hash)) do
      {:ok, program} ->
        check_cached_module_name(module, program)

      :miss ->
        with {:ok, exports} <- source_exports(ctx, source) do
          if exports == [] do
            {:error, :no_exports}
          else
            verify_library(ctx, source, impl_hash, exports)
          end
        end
    end
  end

  defp check_cached_module_name(module, artifact) do
    case cached_source_module(artifact) do
      ^module ->
        {:ok, artifact}

      _other ->
        {:error, :wrong_module}
    end
  end

  defp cached_source_module(%{metadata: %{source_contract: %{module: module}}})
       when is_binary(module),
       do: module

  defp cached_source_module(_program), do: nil

  defp verify_library(ctx, source, impl_hash, exports) do
    cache_key = library_cache_key(ctx, impl_hash)

    manifest = library_manifest(exports, ctx)
    {:ok, [module]} = Hyperlang.OtpFrontend.source_module_names(source, manifest)

    case Hyperlang.program(%{
           entry: module <> ".erl",
           files: %{(module <> ".erl") => source},
           manifest: manifest
         }) do
      {:ok, program} ->
        :ok = Cache.register_library(cache_key, program, CodeServer.code_pool_size())
        {:ok, program}

      {:error, errors} ->
        if Enum.any?(errors, &(Map.get(&1, :category) == :code_pool)) do
          {:error, {:module_error, :too_many_modules}}
        else
          {:error, {:module_error, :verification_failed}}
        end
    end
  end

  defp resolve_source(ctx, module, path) do
    # Read through the same dispatch the guest `file:` mirror uses, so
    # resolution sees exactly the caller's namespace on every backend
    # (own-VFS standalone, or a host syscall door).
    Enum.find_value(path, {:error, :nofile}, fn dir ->
      file = if dir == "/", do: "/" <> module, else: dir <> "/" <> module

      try do
        case Hyperlang.Runtime.filesystem(ctx, :read_file, [file]) do
          {:ok, source} when is_binary(source) -> {:ok, file, source}
          _other -> nil
        end
      rescue
        _error -> nil
      end
    end)
  end

  defp check_module_name(ctx, module, source) do
    # Lexes the LIBRARY source — library derivation limits apply, not the
    # caller's evaluator limits (same rule as source_exports below).
    case Hyperlang.OtpFrontend.source_module_names(source, library_manifest([], ctx)) do
      {:ok, [^module]} -> :ok
      {:ok, _names} -> {:error, :wrong_module}
      {:error, _error} -> {:error, {:module_error, :verification_failed}}
    end
  end

  defp source_exports(ctx, source) do
    # Export extraction lexes the LIBRARY source, so it runs under the
    # library derivation manifest (its token budget), not the caller's
    # evaluator limits — same rule as parsed_doc_chunk and verify_library.
    # Export discovery is source-only; compiled artifacts also include the
    # caller's atom universe.
    case Hyperlang.OtpFrontend.source_export_names(source, library_manifest([], ctx)) do
      {:ok, exports} -> {:ok, Enum.uniq(exports)}
      {:error, _error} -> {:error, {:module_error, :verification_failed}}
    end
  end

  @doc false
  # The normalized library derivation manifest with the library's exports
  # substituted. Shared with `Hyperlang.Check`, which runs the same pipeline
  # statically over a whole image.
  def library_manifest(exports, ctx_or_manifest \\ nil) do
    {:ok, base} = Manifest.normalize(@derivation_manifest)
    atom_universe = inherited_atom_universe(ctx_or_manifest)
    guest_modules = inherited_guest_modules(ctx_or_manifest)

    functions =
      Map.new(exports, fn {name, arity} ->
        id = name <> "/" <> Integer.to_string(arity)
        {id, %{id: id, function: name, arity: arity, input: %{}, output: %{}}}
      end)

    base
    |> Map.put(:atom_universe, atom_universe)
    |> put_in([:modules, :guest_modules], guest_modules)
    |> Map.put(:exports, %{functions: functions, files: []})
    |> Map.put(:result_explicit?, false)
  end

  defp inherited_atom_universe(%{atom_universe: atom_universe}), do: atom_universe
  defp inherited_atom_universe(%{manifest: %{atom_universe: atom_universe}}), do: atom_universe
  defp inherited_atom_universe(_ctx_or_manifest), do: nil

  defp inherited_guest_modules(%{modules: %{guest_modules: guest_modules}})
       when is_list(guest_modules),
       do: guest_modules

  defp inherited_guest_modules(%{manifest: %{modules: %{guest_modules: guest_modules}}})
       when is_list(guest_modules),
       do: guest_modules

  defp inherited_guest_modules(_ctx_or_manifest), do: []

  defp library_cache_key(ctx, impl_hash),
    do: {impl_hash, inherited_atom_universe(ctx)}

  # Load step 6: every derived capability must be granted
  # by the loading program's manifest. Each category re-checks through the
  # same canonical gate used at classification, so the gate and the
  # classifier cannot drift.
  def capability_violations(manifest, %Hyperlang.Program{} = program),
    do: capability_violations(manifest, Map.get(program.metadata, :derived_capabilities) || %{})

  @doc false
  # Also the static gate for `Hyperlang.check/2`, which passes a derived
  # capability map directly.
  def capability_violations(manifest, capabilities) when is_map(capabilities) do
    stdlib =
      capabilities
      |> Map.get(:stdlib, [])
      |> Enum.reject(fn {m, f, a} -> Hyperlang.Stdlib.allowed?(manifest, m, f, a) end)

    facades =
      capabilities
      |> Map.get(:facades, [])
      |> Enum.reject(fn {m, f, a} ->
        Hyperlang.Filesystem.call_target(manifest, m, f, a) != :error
      end)

    loader =
      capabilities
      |> Map.get(:loader, [])
      |> Enum.reject(fn {m, f, a} ->
        Hyperlang.Loader.call_target(manifest, m, f, a) != :error
      end)

    code =
      capabilities
      |> Map.get(:code, [])
      |> Enum.reject(fn {m, f, a} -> Hyperlang.Code.call_target(manifest, m, f, a) != :error end)

    modules =
      case Map.get(capabilities, :modules, []) do
        [] -> []
        names -> if modules_enabled?(manifest), do: [], else: names
      end

    stdlib ++ facades ++ loader ++ code ++ modules
  end

  defp modules_enabled?(manifest),
    do: Map.get(manifest, :modules, %{}) |> Map.get(:enabled, false)

  defp build_binding(ctx, %Hyperlang.Program{} = program) do
    case CodeServer.load(program) do
      {:ok, %{program: program} = slot} ->
        artifact = program.artifact
        metadata = program.metadata

        build_binding(ctx, %{
          program: program,
          exports: Map.get(artifact.manifest, :exports, %{functions: %{}, files: []}),
          slot: slot,
          source_module: get_in(metadata, [:source_contract, :module]),
          stack_map: Map.get(artifact.metadata, :stack_map, %{}),
          atom_pool: artifact.runtime.atom_pool,
          atom_allowed: artifact.runtime.atom_allowed,
          atom_universe: artifact.manifest.atom_universe,
          profiles: get_in(metadata, [:module_metadata, :specs]) || %{}
        })

      {:error, error} ->
        module_error(ctx, {:library_error, error})
    end
  end

  defp build_binding(ctx, %{program: %Hyperlang.Program{} = program, slot: slot} = artifact) do
    exports = Map.get(artifact, :exports, %{functions: %{}, files: []})

    # The library executes under the caller's manifest (with the library's
    # own exports substituted), limits, terms, and syscall door: same token, no
    # capability moves. The ONE thing that follows the callee is the door's
    # executing-program identity (Inferno R.M on a module call) — see the
    # `with_executing_program` retarget on `:syscall` below — so a sys:spawn the
    # library issues resolves the spawned export in the library, not the caller.
    runtime_manifest =
      ctx.manifest
      |> Map.put(:exports, exports)
      |> Map.put(:result_explicit?, false)

    token = :erlang.unique_integer([:positive, :monotonic])

    runtime = %{
      token: token,
      bindings: %{},
      manifest: runtime_manifest,
      limits: ctx.limits,
      terms: Map.delete(ctx.terms, :atom_pool),
      slot_module: slot.module,
      slot_version: slot.version,
      source_module: Map.get(artifact, :source_module),
      stack_map: Map.get(artifact, :stack_map, %{}),
      atom_pool: Map.get(artifact, :atom_pool, %{}),
      atom_allowed: Map.get(artifact, :atom_allowed, MapSet.new()),
      atom_universe: Map.get(artifact, :atom_universe),
      host_scope: ctx.host_scope,
      filesystem: Map.get(ctx, :filesystem),
      # HyperBEAM's current syscall door deliberately carries no mutable
      # executing-program identity. A loaded library inherits the caller's
      # already-normalized door unchanged, so loading grants no authority.
      syscall: Map.get(ctx, :syscall),
      call_id: Map.get(ctx, :call_id),
      loader_modules: %{},
      source_snapshot_modules: %{},
      table_service: Map.get(ctx, :table_service),
      callback_runtime: callback_runtime(ctx),
      # Marks the `$safe_export` entry as a module-call boundary: the
      # library-side passes use the `:module_args`/`:module_return`
      # categories instead of the host-facing input/output policies.
      module_entry: true
    }

    # Stamp this host-built library runtime once (validate-at-introduction): the
    # binding is cached in the process dictionary and its token/limits/terms are
    # immutable, so every later `new_context`/`$safe_export` crossing of this same
    # runtime can honor the stamp and skip the redundant per-crossing re-scan. A
    # forbidden primitive in token/limits/terms still raises here (never stamped).
    runtime = Terms.stamp_validated_runtime(runtime)

    context =
      case Hyperlang.Runtime.new_context(token, runtime, slot.version) do
        {:ok, context} -> context
        {:error, reason} -> module_error(ctx, {:library_error, reason})
      end

    %{
      program: program,
      token: token,
      slot_module: slot.module,
      runtime: runtime,
      context: context,
      export_ids: functions_to_ids(runtime_manifest),
      profiles: Map.get(artifact, :profiles, %{})
    }
  end

  defp callback_runtime(ctx) do
    %{
      token: ctx.token,
      bindings: ctx.bindings,
      manifest: ctx.manifest,
      limits: ctx.limits,
      terms: Map.delete(ctx.terms, :atom_pool),
      slot_module: ctx.slot_module,
      slot_version: ctx.slot_version,
      source_module: ctx.source_module,
      stack_map: ctx.stack_map,
      atom_pool: ctx.atom_pool,
      atom_allowed: Map.get(ctx, :atom_allowed, MapSet.new()),
      atom_universe: Map.get(ctx, :atom_universe, Map.get(ctx.manifest, :atom_universe)),
      host_scope: ctx.host_scope,
      filesystem: Map.get(ctx, :filesystem),
      syscall: Map.get(ctx, :syscall),
      call_id: Map.get(ctx, :call_id),
      loader_modules: Map.get(ctx, :loader_modules, %{}),
      callback_runtime: Map.get(ctx, :callback_runtime),
      module_entry: true
    }
  end

  defp functions_to_ids(%{exports: %{functions: functions}}), do: MapSet.new(Map.keys(functions))

  defp runtime_binding(%{manifest: manifest} = runtime) do
    %{
      program: nil,
      token: runtime.token,
      slot_module: runtime.slot_module,
      runtime: runtime,
      context: nil,
      export_ids: functions_to_ids(manifest),
      profiles: %{}
    }
  end

  defp impl_hash(source), do: Hyperlang.Program.sha256_hex(source)

  # The module term boundary: same-universe guest module
  # calls are raw Erlang calls because codegen materializes every linked module
  # against the same append-only atom universe. Host-driven `call_module` entry
  # still uses the sanitizer perimeter, and different universes still remap by
  # source name. When the library carries a -spec for the exported function, the
  # corresponding coarse profile is applied to arguments and return; a violation
  # raises Erlang's own contract failure, function_clause, at the call site.
  defp invoke(ctx, binding, function, args) do
    arity = length(args)
    export_id = function <> "/" <> Integer.to_string(arity)

    if not MapSet.member?(binding.export_ids, export_id) do
      :erlang.error(:undef)
    end

    profile = boundary_profile(binding, function, arity)
    opaque_terms = opaque_arg_terms(ctx, args)

    raw_boundary? = raw_module_boundary?(ctx, binding)
    args = module_call_args(ctx, binding, args, raw_boundary?)

    :ok = check_profile_args(profile, args)
    return_ctx = Map.put(ctx, :opaque_fixed_points, opaque_terms)

    if raw_boundary? and raw_export_available?(binding) do
      result = apply(binding.slot_module, :"$safe_raw_export", [binding.context, export_id, args])
      check_profile_return(result, profile)
    else
      case apply(binding.slot_module, :"$safe_export", [
             binding.token,
             export_id,
             args,
             binding.runtime
           ]) do
        {:ok, %{result: result}} ->
          module_call_return(return_ctx, binding, result, raw_boundary?)
          |> check_profile_return(profile)

        {:error, %{reason: :undef}} ->
          :erlang.error(:undef)

        {:error, %{details: %{"reason" => "undef"}}} ->
          :erlang.error(:undef)

        # Loader-policy errors (load cycle, capability gate, ...) raised below
        # a nested boundary keep their reason instead of being re-wrapped as a
        # library error at every level. The reply is already host-sanitized, so
        # the reason arrives as a string inside the door error's `details`.
        {:error, %{category: :module, details: %{"reason" => reason}} = error}
        when is_binary(reason) ->
          case module_reason(reason) do
            reason
            when reason in [
                   :verification_failed,
                   :capability_not_granted,
                   :load_cycle,
                   :too_many_modules
                 ] ->
              module_error(ctx, reason)

            _other ->
              module_error(ctx, {:library_error, error})
          end

        {:error, %{} = error} ->
          module_error(ctx, {:library_error, error})

        other ->
          other
      end
    end
  end

  defp raw_export_available?(%{slot_module: module, context: context})
       when is_atom(module) and is_map(context),
       do: function_exported?(module, :"$safe_raw_export", 3)

  defp raw_export_available?(_binding), do: false

  defp module_call_args(_ctx, _binding, args, true), do: args

  defp module_call_args(ctx, binding, args, false),
    do: sanitize_boundary(ctx, Terms.sanitize_module_args(args, ctx, binding.runtime))

  defp module_call_return(_ctx, _binding, result, true), do: result

  defp module_call_return(ctx, binding, result, false),
    do: sanitize_boundary(ctx, Terms.sanitize_module_return(result, ctx, binding.runtime))

  defp raw_module_boundary?(%{host_module_entry: true}, _binding), do: false

  defp raw_module_boundary?(ctx, binding) do
    same_atom_universe?(Map.get(ctx, :atom_universe), Map.get(binding.runtime, :atom_universe))
  end

  defp same_atom_universe?(nil, _callee), do: false
  defp same_atom_universe?(_caller, nil), do: false
  defp same_atom_universe?(universe, universe), do: true
  defp same_atom_universe?(_caller, _callee), do: false

  defp sanitize_boundary(_ctx, {:ok, safe}), do: safe
  defp sanitize_boundary(ctx, {:error, reason}), do: module_error(ctx, {:boundary_error, reason})

  defp opaque_arg_terms(ctx, args) do
    args
    |> Enum.flat_map(fn arg ->
      case Terms.opaque_term(arg, ctx) do
        {:ok, term} -> [term]
        :error -> []
      end
    end)
  end

  defp boundary_profile(binding, function, arity) do
    case Map.get(binding.profiles, {function, arity}) do
      %{profile: %{args: _, return: _} = profile} -> profile
      _other -> nil
    end
  end

  defp check_profile_args(nil, _args), do: :ok

  defp check_profile_args(%{args: kinds}, args) when length(kinds) == length(args) do
    kinds
    |> Enum.zip(args)
    |> Enum.all?(fn {kind, value} -> profile_match?(kind, value) end)
    |> case do
      true -> :ok
      false -> :erlang.error(:function_clause)
    end
  end

  defp check_profile_args(_profile, _args), do: :ok

  defp check_profile_return(result, nil), do: result

  defp check_profile_return(result, %{return: kind}) do
    if profile_match?(kind, result), do: result, else: :erlang.error(:function_clause)
  end

  defp profile_match?(:term, _value), do: true
  defp profile_match?(:binary, value), do: is_binary(value)
  defp profile_match?(:integer, value), do: is_integer(value)
  defp profile_match?(:float, value), do: is_float(value)
  defp profile_match?(:boolean, value), do: is_boolean(value)
  defp profile_match?(:atom, value), do: is_atom(value)
  defp profile_match?(:list, value), do: is_list(value)
  defp profile_match?(:map, value), do: is_map(value)
  defp profile_match?(:tuple, value), do: is_tuple(value)
  defp profile_match?(_kind, _value), do: true

  # Loader reasons are a fixed host vocabulary; anything else stays a
  # generic module error.
  defp module_reason(reason) when is_binary(reason) do
    String.to_existing_atom(reason)
  rescue
    ArgumentError -> :module_error
  end

  # Loader-specific failures set stable Plan 9-style errstr text. When a
  # syscall door is present in the context, the text is best-effort posted through the door's werrstr
  # operation before raising, so a parent shell observing the failure reads
  # the stable string. Door errors are swallowed: errstr is advisory.
  @errstr_text %{
    verification_failed: "module verification failed",
    capability_not_granted: "module capability not granted",
    load_cycle: "module load cycle",
    too_many_modules: "too many loaded modules"
  }

  @doc false
  def module_error(ctx, reason) do
    post_errstr(ctx, Map.get(@errstr_text, reason))
    :erlang.error({:sandbox, :module_error, reason})
  end

  defp post_errstr(_ctx, nil), do: :ok

  defp post_errstr(ctx, text) when is_map(ctx) do
    case Map.get(ctx, :host) do
      {_module, _state} ->
        Hyperlang.Runtime.host_call(ctx, :werrstr, [text])
        :ok

      _other ->
        :ok
    end
  rescue
    _error -> :ok
  catch
    _class, _reason -> :ok
  end

  defp post_errstr(_ctx, _text), do: :ok
end
