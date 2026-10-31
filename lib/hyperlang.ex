defmodule Hyperlang do
  @moduledoc """
  Compile and run untrusted Erlang-shaped guest programs.

  The public API is four functions and one callback module:

    * `program/1` compiles an immutable source value into a
      `Hyperlang.Program`. The manifest, the binding MFA set, the export set
      and the atom universe are fixed here and enter the program hash.
    * `program/2` returns a program cached under a caller-owned key and calls
      the loader only on a miss.
    * `run/4` runs one declared export with exactly the authority in its
      spec.
    * `load/1` loads a program into the code pool ahead of its first use.
    * `Hyperlang.Actor` is the `GenServer` callback module that runs a
      program's OTP callbacks
      (`GenServer.start(Hyperlang.Actor, {spec, program, arg})`). Every
      callback goes through `run/4`.

  Errors are sanitized maps whose `:category` comes from a closed taxonomy;
  see `doc/SECURITY_SPECIFICATION.md`.
  """

  alias Hyperlang.{
    Codegen,
    CodeServer,
    Compiler,
    Manifest,
    Program,
    Runtime,
    Terms,
    Worker
  }

  @compiler_version "0.1.18"
  @stdlib_version "hyperlang_stdlib/0.3"
  @gen_server_guest_lib_modules ~w(gen_server gen proc_lib otp_sys supervisor gen_statem gen_event)
  @gen_server_guest_lib_root Path.expand("../priv/guest_lib", __DIR__)
  @gen_server_guest_lib_virtual_root "/__hyperlang_guest_lib__"

  @type source_bundle :: binary() | %{optional(atom() | binary()) => term()}
  @type manifest :: map()
  @type errors :: [map()]

  @doc """
  Compile an immutable, closed-world source value.

  Source maps use `%{entry: "name.erl", files: %{"name.erl" => source}}` and
  may carry a compiler manifest under `:manifest`. A binary is the compact
  single-source form.
  """
  @spec program(binary() | map()) :: {:ok, Program.t()} | {:error, errors()}
  def program(code)

  def program(code) when is_binary(code) do
    case compile(code, %{}) do
      {:error, errors} when is_list(errors) -> {:error, errors}
      {:error, error} -> {:error, [Hyperlang.Error.normalize(error)]}
      result -> result
    end
  end

  def program(%{} = code) do
    case closed_source(code) do
      {:program, {:error, errors}} when is_list(errors) -> {:error, errors}
      {:program, {:error, error}} -> {:error, [Hyperlang.Error.normalize(error)]}
      {:program, result} -> result
      {:error, error} -> {:error, [Hyperlang.Error.normalize(error)]}
    end
  end

  def program(_code), do: {:error, [Hyperlang.Error.new(:api, "invalid program source value")]}

  @doc """
  Return a program cached under a caller-owned key, compiling the loader's
  source value on a miss.
  """
  @spec program(term(), (-> binary() | map() | {:ok, binary() | map()} | {:error, term()})) ::
          {:ok, Program.t()} | {:error, errors()}
  def program(key, loader_fn) when is_function(loader_fn, 0) do
    cache_key = {:caller, key}

    case Hyperlang.Cache.get_program(cache_key) do
      {:ok, %Program{} = program} ->
        {:ok, program}

      :miss ->
        result =
          case loader_fn.() do
            {:ok, code} -> program(code)
            {:error, diagnostics} when is_list(diagnostics) -> {:error, diagnostics}
            {:error, diagnostic} -> {:error, [Hyperlang.Error.normalize(diagnostic)]}
            code -> program(code)
          end

        case result do
          {:ok, %Program{} = program} ->
            case Hyperlang.Cache.put_program(cache_key, program) do
              :ok -> {:ok, program}
              {:cached, cached} -> {:ok, cached}
            end

          error ->
            error
        end
    end
  end

  def program(_key, _loader_fn),
    do: {:error, [Hyperlang.Error.new(:api, "program loader must be an arity-zero function")]}

  @doc """
  Load an immutable program value into the code pool ahead of its first use.

  Loading is optional: `run/4` and a `Hyperlang.Actor` load a program that
  is not loaded. A host calls `load/1` to pay the compile and load cost
  at a time of its choosing (for example at boot, outside a request). The
  loaded code is not pinned; the pool may reclaim it later, and the next use
  loads it again.

  Returns `:ok`, or `{:error, error}` with a sanitized error map (for
  example `category: :code_pool` when every slot of the program's window is
  pinned or still running).
  """
  @spec load(Program.t()) :: :ok | {:error, term()}
  def load(program) do
    case load_program(program) do
      {:ok, _slot} -> :ok
      {:error, error} -> {:error, Hyperlang.Terms.sanitize_error(error)}
    end
  end

  @doc """
  Run a declared export using only the authority present in `spec`.

  `spec` is `%{bindings: %{name => {module, state}}, policy: map}` plus an
  optional `syscall` host door. `bindings` must name exactly the bindings the
  program's manifest declares, with the same modules. `export` is `:entry`
  (the manifest result root, called with `hd(args)`), an atom, or an
  `"name/arity"` export id.

  Success returns `{:ok, value, meta}` where `meta` is
  `%{stdout: [binary], reductions: non_neg_integer, wall_us: non_neg_integer}`:
  the sanitized guest stdout chunks in order, the reductions the guest call
  consumed in its own process, and the wall time of the call in
  microseconds. Failure returns `{:error, error}` with a sanitized error map.
  """
  @spec run(map(), Program.t(), atom() | binary(), list()) ::
          {:ok, term(),
           %{stdout: [binary()], reductions: non_neg_integer(), wall_us: non_neg_integer()}}
          | {:error, term()}
  def run(spec, %Program{} = program, export, args) when is_map(spec) and is_list(args) do
    policy = Map.get(spec, :policy, %{})

    scope =
      if is_map(policy),
        do: Map.get(policy, :scope) || Hyperlang.Scope.current(),
        else: Hyperlang.Scope.current()

    # An in-caller run is admitted by its worker, which attaches in the same
    # call (`Hyperlang.Scope.acquire_run/4`).
    in_caller? = is_map(policy) and Map.get(policy, :run_in_caller?, false) not in [nil, false]

    Hyperlang.Scope.blocking(fn ->
      Hyperlang.Scope.with_scope(scope, fn ->
        case if(in_caller?, do: :in_caller, else: Hyperlang.Scope.acquire(scope)) do
          :in_caller ->
            do_run(spec, program, export, args)

          {:ok, lease} ->
            previous = Hyperlang.Scope.offer_lease(scope, lease)

            try do
              do_run(spec, program, export, args)
            after
              Hyperlang.Scope.release_offered(lease, previous)
            end

          {:error, error} ->
            {:error, Hyperlang.Terms.sanitize_error(error)}
        end
      end)
    end)
  end

  def run(_spec, _program, _export, _args),
    do: {:error, Hyperlang.Terms.sanitize_error(%{category: :api, reason: :bad_run})}

  defp do_run(spec, program, export, args) do
    started = System.monotonic_time(:microsecond)

    with {:ok, bindings, options, worker_opts} <- normalize_door_spec(spec),
         {:ok, stored} <- prepare_run_state(program, bindings, options) do
      reply =
        try do
          case export do
            :entry ->
              Worker.run_entry(stored, List.first(args), worker_opts)

            export when is_atom(export) ->
              Worker.run_export(stored, Atom.to_string(export), args, worker_opts)

            export when is_binary(export) ->
              Worker.run_export(stored, export, args, worker_opts)

            _ ->
              {:error, Hyperlang.Terms.sanitize_error(%{category: :api, reason: :bad_export})}
          end
        after
          stop_run_resources(stored)
          release_limits_group(stored.limits_group)
        end

      case reply do
        {:ok, %{result: result, stdout: stdout} = envelope} ->
          {:ok, result,
           %{
             stdout: stdout,
             reductions: Map.get(envelope, :reductions, 0),
             wall_us: System.monotonic_time(:microsecond) - started
           }}

        other ->
          other
      end
    else
      {:error, errors} when is_list(errors) ->
        {:error, errors |> List.first() |> Hyperlang.Terms.sanitize_error()}

      {:error, error} ->
        {:error, Hyperlang.Terms.sanitize_error(error)}
    end
  end

  defp compiler_fingerprint do
    %{
      compiler_version: @compiler_version,
      stdlib_version: @stdlib_version,
      codegen_options: Codegen.options_hash(),
      code_server_compile_options: CodeServer.compile_options_hash()
    }
  end

  defp compile(source, manifest) when is_binary(source) do
    with {:ok, normalized} <- Manifest.normalize(manifest),
         :ok <- validate_source_hash_limits(source, normalized) do
      Compiler.run_bounded(normalized.limits, fn ->
        source_hash = Program.sha256_hex(source)
        normalized = ensure_atom_universe(normalized, source_hash)
        manifest_hash = cache_manifest_hash(normalized)
        cache_key = program_cache_key(source_hash, manifest_hash)

        with {:ok, compiled} <- Compiler.compile(source, normalized),
             normalized = ensure_callback_exports(normalized, compiled),
             {:ok, forms, metadata} <-
               Compiler.run_bounded(normalized.limits, fn ->
                 Codegen.to_forms(compiled, normalized)
               end) do
          build_program(
            forms,
            normalized,
            compiled,
            metadata,
            source_hash,
            manifest_hash,
            cache_key,
            %{}
          )
        else
          {:error, errors} when is_list(errors) -> {:error, errors}
          {:error, error} -> {:error, [Hyperlang.Error.normalize(error)]}
        end
      end)
    else
      {:error, errors} when is_list(errors) -> {:error, errors}
      {:error, error} -> {:error, [Hyperlang.Error.normalize(error)]}
    end
  end

  defp build_program(
         forms,
         normalized,
         compiled,
         metadata,
         source_hash,
         manifest_hash,
         cache_key,
         extra_metadata
       ) do
    normalized = %{normalized | exports: compiled_exports(compiled, normalized)}

    public_metadata =
      metadata
      |> safe_metadata()
      |> Map.merge(%{
        atom_universe: normalized.atom_universe,
        derived_capabilities: Hyperlang.Capabilities.derive(compiled),
        source_format: compiled.source_format,
        frontend: compiled.frontend,
        result: public_result(normalized, compiled),
        sys: normalized.sys,
        filesystem: Manifest.public_filesystem(normalized.filesystem),
        exports: normalized.exports,
        public_exports: public_exports_from_exports(normalized.exports),
        module_metadata: Map.get(compiled.core.metadata, :module_metadata, %{})
      })
      |> Map.merge(extra_metadata)

    atom_pool = Map.get(compiled.core.metadata, :atom_pool, %{})

    # The program's manifest and public metadata are not repeated here: the
    # run state takes them from the program (`runtime_artifact/2`), so the
    # program value holds each once.
    runtime_artifact = %{
      stack_map: Map.get(metadata, :stack_map, %{}),
      atom_pool: Map.get(atom_pool, :pool_to_source, %{}),
      atom_allowed: Map.get(atom_pool, :allowed_source_atoms, MapSet.new()),
      compat_source_atoms: Map.get(atom_pool, :compat_source_atoms, MapSet.new()),
      atom_universe: normalized.atom_universe,
      source_snapshot_modules:
        source_snapshot_modules(
          public_metadata,
          Map.get(atom_pool, :pool_to_source, %{}),
          normalized.terms
        )
    }

    program = %Program{
      content_hash: cache_key,
      source_hash: source_hash,
      manifest_hash: manifest_hash,
      compiler_version: @compiler_version,
      stdlib_version: @stdlib_version,
      metadata: public_metadata,
      artifact: %{
        forms: forms,
        manifest: normalized,
        metadata: metadata,
        runtime: runtime_artifact
      }
    }

    {:ok, program}
  end

  defp compiled_exports(
         %{core: %{metadata: %{exports: exports}}},
         %{exports: normalized_exports}
       ) do
    %{
      exports
      | functions: Map.merge(exports.functions, normalized_exports.functions)
    }
  end

  defp compiled_exports(_compiled, %{exports: exports}), do: exports

  @otp_callbacks [
    {"init", 1},
    {"handle_call", 3},
    {"handle_cast", 2},
    {"handle_info", 2},
    {"handle_continue", 2},
    {"terminate", 2},
    {"code_change", 3},
    {"format_status", 1}
  ]

  defp ensure_callback_exports(%{exports: exports} = normalized, %{core: core}) do
    functions =
      Enum.reduce(@otp_callbacks, exports.functions, fn {name, arity}, acc ->
        if Map.has_key?(core.functions, {name, arity}) do
          id = name <> "/" <> Integer.to_string(arity)

          Map.put_new(acc, id, %{
            id: id,
            function: name,
            arity: arity,
            input: %{},
            output: %{}
          })
        else
          acc
        end
      end)

    %{normalized | exports: %{exports | functions: functions}}
  end

  defp source_snapshot_metadata(snapshot, source_hash) do
    %{
      source_snapshot: snapshot.public,
      source_snapshot_hash: source_hash
    }
  end

  defp inject_gen_server_guest_lib(snapshot, normalized) do
    if Hyperlang.Manifest.gen_server_enabled?(normalized) and normalized.modules.enabled do
      do_inject_gen_server_guest_lib(snapshot, normalized)
    else
      {:ok, snapshot, normalized}
    end
  end

  defp do_inject_gen_server_guest_lib(snapshot, normalized) do
    # The pinned OTP supervisor is a trusted virtual source module. Its full
    # executable form is larger than the general-purpose single-file defaults,
    # so the gen_server capability carries a bounded compilation floor.
    normalized =
      update_in(normalized.limits, fn limits ->
        limits
        |> Map.update!(:max_source_bytes, &max(&1, 250_000))
        |> Map.update!(:max_line_count, &max(&1, 7_000))
        |> Map.update!(:max_tokens, &max(&1, 45_000))
        |> Map.update!(:max_ast_nodes, &max(&1, 120_000))
        |> Map.update!(:max_functions, &max(&1, 512))
        |> Map.update!(:max_clauses, &max(&1, 2_048))
        |> Map.update!(:max_compile_reductions, &max(&1, 400_000_000))
      end)

    user_modules = MapSet.new(Enum.map(snapshot.files, & &1.module))

    case Enum.find(@gen_server_guest_lib_modules, &MapSet.member?(user_modules, &1)) do
      nil ->
        with {:ok, injected} <- gen_server_guest_lib_files(normalized),
             :ok <- validate_injected_source_limits(snapshot.files, injected, normalized) do
          files = snapshot.files ++ injected

          public_sources =
            Enum.map(files, fn file ->
              %{
                path: file.path,
                module: file.module,
                hash: file.hash,
                byte_size: file.byte_size,
                generation: nil
              }
            end)

          normalized =
            put_in(normalized.modules.guest_modules, gen_server_guest_modules(normalized))

          {:ok, %{snapshot | files: files, public: %{snapshot.public | sources: public_sources}},
           normalized}
        end

      module ->
        {:error,
         Hyperlang.Error.new(:source, "source module collides with injected gen_server guest lib",
           details: %{module: module}
         )}
    end
  end

  defp gen_server_guest_lib_files(normalized) do
    @gen_server_guest_lib_modules
    |> Enum.reduce_while({:ok, []}, fn module, {:ok, files} ->
      path = Path.join(@gen_server_guest_lib_root, module <> ".erl")

      case File.read(path) do
        {:ok, source} ->
          with :ok <- check_source_file_size(source, normalized.filesystem.limits) do
            virtual_path = Path.join(@gen_server_guest_lib_virtual_root, module <> ".erl")

            file = %{
              path: virtual_path,
              entry?: false,
              module: module,
              language: :erlang,
              source: source,
              hash: Program.sha256_hex(source),
              byte_size: byte_size(source)
            }

            {:cont, {:ok, [file | files]}}
          else
            {:error, error} -> {:halt, {:error, error}}
          end

        {:error, reason} ->
          {:halt,
           {:error,
            Hyperlang.Error.new(:source, "gen_server guest lib source read failed",
              details: %{module: module, reason: reason}
            )}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_injected_source_limits(user_files, injected_files, normalized) do
    source_count = length(user_files) + length(injected_files)
    source_bytes = Enum.sum(Enum.map(user_files ++ injected_files, & &1.byte_size))

    cond do
      source_count > normalized.filesystem.limits.max_source_count ->
        {:error, Hyperlang.Error.new(:source, "source count exceeds filesystem limit")}

      source_bytes > normalized.limits.max_source_bytes ->
        {:error, Hyperlang.Error.new(:source, "source bundle byte size exceeds limit")}

      true ->
        :ok
    end
  end

  defp gen_server_guest_modules(normalized) do
    normalized.modules.guest_modules
    |> Kernel.++(@gen_server_guest_lib_modules)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp parse_source_snapshot(snapshot, manifest) do
    snapshot.files
    |> Enum.reduce_while({:ok, []}, fn file, {:ok, files} ->
      case parse_source_snapshot_file(file, manifest) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | files]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, files} ->
        files = Enum.reverse(files)

        with :ok <- validate_source_modules(files) do
          {:ok, %{snapshot | files: files}}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp parse_source_snapshot_file(file, manifest) do
    with {:ok, module} <- source_module_identity(file.path, file.source, manifest),
         :ok <- check_path_module_match(file.path, module),
         {:ok, ast} <- Hyperlang.OtpFrontend.parse(file.source, manifest) do
      {:ok, file |> Map.put(:module, module) |> Map.put(:ast, ast)}
    end
  end

  defp check_source_file_size(source, limits) do
    if byte_size(source) <= limits.max_source_file_bytes do
      :ok
    else
      {:error, Hyperlang.Error.new(:source, "source file byte size exceeds limit")}
    end
  end

  defp source_module_identity(path, source, manifest) do
    case Hyperlang.OtpFrontend.source_module_names(source, manifest) do
      {:ok, [module]} ->
        validate_source_module_name(path, module)

      {:ok, []} ->
        path
        |> Path.basename()
        |> Path.rootname()
        |> then(&validate_source_module_name(path, &1))

      {:ok, _multiple} ->
        {:error,
         Hyperlang.Error.new(:source, "source file has multiple -module attributes",
           details: %{path: path}
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  defp validate_source_module_name(path, module) do
    if Program.reserved_module_name?(module) do
      {:error,
       Hyperlang.Error.new(:source, "source module name uses reserved Hyperlang internal name",
         details: %{path: path, module: module}
       )}
    else
      {:ok, module}
    end
  end

  defp check_path_module_match(path, module) do
    case Program.module_name_from_basename(path) do
      {:ok, ^module} ->
        :ok

      {:ok, _other} ->
        {:error,
         Hyperlang.Error.new(:source, "source path/module-name mismatch",
           details: %{path: path, module: module}
         )}

      # A path whose basename implies no module name constrains nothing; the
      # `-module` attribute itself is validated by validate_source_module_name/2.
      :error ->
        :ok
    end
  end

  defp validate_source_modules(files) do
    modules = Enum.map(files, & &1.module)

    cond do
      length(modules) != length(Enum.uniq(modules)) ->
        {:error, Hyperlang.Error.new(:source, "duplicate source module identity")}

      true ->
        :ok
    end
  end

  defp build_source_snapshot_ast(snapshot, manifest) do
    entry = Enum.find(snapshot.files, & &1.entry?)
    module_names = MapSet.new(Enum.map(snapshot.files, & &1.module))
    dynamic_module_names = source_snapshot_dynamic_module_names(snapshot.files, manifest)

    function_index =
      snapshot.files
      |> Enum.flat_map(fn file ->
        Enum.map(file.ast.functions, fn function ->
          {{file.module, function.name, function.arity},
           snapshot_function_name(file.module, entry.module, function.name)}
        end)
      end)
      |> Map.new()

    functions =
      snapshot.files
      |> Enum.flat_map(fn file ->
        Enum.map(file.ast.functions, fn function ->
          rewrite_source_function(function, file.module, module_names, function_index)
        end)
      end)

    with :ok <- validate_snapshot_record_definitions(snapshot.files),
         {:ok, functions} <-
           link_snapshot_dynamic_calls(functions, dynamic_module_names, function_index) do
      dangling_calls = dangling_snapshot_module_calls(functions, module_names)

      cond do
        generated_snapshot_name_collision?(functions) ->
          {:error, Hyperlang.Error.new(:source, "duplicate generated source function identity")}

        dangling_calls != [] ->
          dangling_snapshot_module_call_error(hd(dangling_calls))

        true ->
          ast = %{
            type: :function_program,
            functions: functions,
            records:
              snapshot.files
              |> Enum.flat_map(&Map.get(&1.ast, :records, []))
              |> Enum.uniq_by(& &1.name),
            source_contract: source_snapshot_contract(snapshot, entry)
          }

          result_key = {manifest.result.name, manifest.result.arity}

          cond do
            Enum.any?(functions, &({&1.name, &1.arity} == result_key)) ->
              {:ok, ast}

            export_only_result_optional?(manifest) ->
              {:ok, ast}

            true ->
              {:error,
               Hyperlang.Error.new(:source, "source snapshot entry result root not found")}
          end
      end
    end
  end

  defp validate_snapshot_record_definitions(files) do
    files
    |> Enum.flat_map(&Map.get(&1.ast, :records, []))
    |> Enum.group_by(& &1.name)
    |> Enum.find(fn {_name, definitions} -> length(Enum.uniq(definitions)) > 1 end)
    |> case do
      nil ->
        :ok

      {name, _definitions} ->
        {:error,
         Hyperlang.Error.new(:source, "conflicting record definitions across snapshot modules",
           details: %{record: name}
         )}
    end
  end

  defp public_result(_normalized, %{core: %{result: nil}}), do: nil
  defp public_result(normalized, _compiled), do: normalized.result

  defp export_only_result_optional?(manifest) do
    not Map.get(manifest, :result_explicit?, false) and has_declared_exports?(manifest)
  end

  defp has_declared_exports?(%{exports: %{functions: functions, files: files}}) do
    map_size(functions) > 0 or files != []
  end

  defp has_declared_exports?(_manifest), do: false

  defp source_snapshot_contract(snapshot, entry) do
    contract = %{
      module_form: true,
      synthetic_module: false,
      filesystem_snapshot: true,
      entry_path: snapshot.entry,
      module: entry.module
    }

    behaviours = get_in(entry.ast, [:source_contract, :behaviours]) || []

    if behaviours == [] do
      contract
    else
      Map.put(contract, :behaviours, behaviours)
    end
  end

  defp snapshot_function_name(module, entry_module, function) when module == entry_module,
    do: function

  defp snapshot_function_name(module, _entry_module, function), do: module <> "$" <> function

  defp generated_snapshot_name_collision?(functions) do
    keys = Enum.map(functions, &{&1.name, &1.arity})
    length(keys) != length(Enum.uniq(keys))
  end

  defp source_snapshot_dynamic_module_names(files, %{
         modules: %{enabled: true, guest_modules: guests}
       })
       when is_list(guests) do
    guest_modules = MapSet.new(guests)

    files
    |> Enum.map(& &1.module)
    |> Enum.filter(&MapSet.member?(guest_modules, &1))
  end

  defp source_snapshot_dynamic_module_names(_files, _manifest), do: []

  defp link_snapshot_dynamic_calls(functions, dynamic_module_names, function_index) do
    functions
    |> Enum.reduce_while({:ok, []}, fn function, {:ok, acc} ->
      case link_snapshot_dynamic_function(function, dynamic_module_names, function_index) do
        {:ok, function} -> {:cont, {:ok, [function | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, functions} -> {:ok, Enum.reverse(functions)}
      {:error, error} -> {:error, error}
    end
  end

  defp link_snapshot_dynamic_function(function, dynamic_module_names, function_index) do
    function.clauses
    |> Enum.reduce_while({:ok, []}, fn clause, {:ok, clauses} ->
      env = %{}

      with {:ok, guard, _env} <-
             link_snapshot_dynamic_expr(clause.guard, env, dynamic_module_names, function_index),
           {:ok, body, _env} <-
             link_snapshot_dynamic_expr(clause.body, env, dynamic_module_names, function_index) do
        {:cont, {:ok, [%{clause | guard: guard, body: body} | clauses]}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, clauses} -> {:ok, %{function | clauses: Enum.reverse(clauses)}}
      {:error, error} -> {:error, error}
    end
  end

  defp link_snapshot_dynamic_expr(nil, env, _dynamic_module_names, _function_index),
    do: {:ok, nil, env}

  defp link_snapshot_dynamic_expr(
         %{node: :dynamic_remote_call, module: module, function: function, args: args} = expr,
         env,
         dynamic_module_names,
         function_index
       )
       when is_binary(function) do
    arity = length(args)

    with {:ok, module, _module_env} <-
           link_snapshot_dynamic_expr(module, env, dynamic_module_names, function_index),
         {:ok, args, _args_env} <-
           link_snapshot_dynamic_exprs_keep_env(args, env, dynamic_module_names, function_index) do
      literal_module = literal_snapshot_module(module, env)

      candidates =
        dynamic_snapshot_candidates(dynamic_module_names, function_index, function, arity)

      candidates = exact_dynamic_snapshot_candidates(candidates, literal_module)

      case candidates do
        [] ->
          dynamic_snapshot_call_error(function, arity)

        candidates ->
          {:ok,
           Map.merge(expr, %{
             node: :dynamic_snapshot_call,
             module: module,
             function: function,
             arity: arity,
             args: args,
             candidates: candidates
           }), env}
      end
    end
  end

  defp link_snapshot_dynamic_expr(
         %{node: :dynamic_remote_call} = expr,
         env,
         dynamic_module_names,
         function_index
       ) do
    with {:ok, expr, _env} <-
           link_snapshot_dynamic_expr_map(expr, env, dynamic_module_names, function_index) do
      {:ok, expr, env}
    end
  end

  defp link_snapshot_dynamic_expr(
         %{node: :match, pattern: pattern, expr: rhs} = expr,
         env,
         dynamic_module_names,
         function_index
       ) do
    with {:ok, rhs, _rhs_env} <-
           link_snapshot_dynamic_expr(rhs, env, dynamic_module_names, function_index) do
      next_env = bind_literal_snapshot_modules(pattern, rhs, env)
      {:ok, %{expr | expr: rhs}, next_env}
    end
  end

  defp link_snapshot_dynamic_expr(
         %{node: :block, exprs: exprs} = expr,
         env,
         dynamic_module_names,
         function_index
       ) do
    with {:ok, exprs, env} <-
           link_snapshot_dynamic_exprs(exprs, env, dynamic_module_names, function_index) do
      {:ok, %{expr | exprs: exprs}, env}
    end
  end

  defp link_snapshot_dynamic_expr(
         %{node: :case, expr: case_expr, clauses: clauses} = expr,
         env,
         dynamic_module_names,
         function_index
       ) do
    with {:ok, case_expr, _case_env} <-
           link_snapshot_dynamic_expr(case_expr, env, dynamic_module_names, function_index),
         {:ok, clauses} <-
           link_snapshot_dynamic_clauses(clauses, env, dynamic_module_names, function_index) do
      {:ok, %{expr | expr: case_expr, clauses: clauses}, env}
    end
  end

  defp link_snapshot_dynamic_expr(
         %{node: :receive, clauses: clauses} = expr,
         env,
         dynamic_module_names,
         function_index
       ) do
    with {:ok, clauses} <-
           link_snapshot_dynamic_clauses(clauses, env, dynamic_module_names, function_index),
         {:ok, timeout, _timeout_env} <-
           link_snapshot_dynamic_expr(
             Map.get(expr, :timeout),
             env,
             dynamic_module_names,
             function_index
           ),
         {:ok, after_body, _after_env} <-
           link_snapshot_dynamic_expr(
             Map.get(expr, :after_body),
             env,
             dynamic_module_names,
             function_index
           ) do
      expr =
        expr
        |> Map.put(:clauses, clauses)
        |> maybe_put_expr(:timeout, timeout)
        |> maybe_put_expr(:after_body, after_body)

      {:ok, expr, env}
    end
  end

  defp link_snapshot_dynamic_expr(
         %{node: :if, clauses: clauses} = expr,
         env,
         dynamic_module_names,
         function_index
       ) do
    with {:ok, clauses} <-
           link_snapshot_dynamic_clauses(clauses, env, dynamic_module_names, function_index) do
      {:ok, %{expr | clauses: clauses}, env}
    end
  end

  defp link_snapshot_dynamic_expr(
         %{node: node, clauses: clauses} = expr,
         env,
         dynamic_module_names,
         function_index
       )
       when node in [:fun, :named_fun] do
    with {:ok, clauses} <-
           link_snapshot_dynamic_clauses(clauses, env, dynamic_module_names, function_index) do
      {:ok, %{expr | clauses: clauses}, env}
    end
  end

  defp link_snapshot_dynamic_expr(%{} = expr, env, dynamic_module_names, function_index) do
    link_snapshot_dynamic_expr_map(expr, env, dynamic_module_names, function_index)
  end

  defp link_snapshot_dynamic_expr(values, env, dynamic_module_names, function_index)
       when is_list(values) do
    link_snapshot_dynamic_exprs_keep_env(values, env, dynamic_module_names, function_index)
  end

  defp link_snapshot_dynamic_expr(value, env, _dynamic_module_names, _function_index),
    do: {:ok, value, env}

  defp link_snapshot_dynamic_expr_map(expr, env, dynamic_module_names, function_index) do
    expr
    |> Enum.reduce_while({:ok, %{}}, fn
      {key, value}, {:ok, acc} when key in [:function, :name] ->
        {:cont, {:ok, Map.put(acc, key, value)}}

      {key, value}, {:ok, acc} ->
        case link_snapshot_dynamic_expr(value, env, dynamic_module_names, function_index) do
          {:ok, value, _value_env} -> {:cont, {:ok, Map.put(acc, key, value)}}
          {:error, error} -> {:halt, {:error, error}}
        end
    end)
    |> case do
      {:ok, expr} -> {:ok, expr, env}
      {:error, error} -> {:error, error}
    end
  end

  defp link_snapshot_dynamic_exprs(values, env, dynamic_module_names, function_index) do
    values
    |> Enum.reduce_while({:ok, [], env}, fn value, {:ok, acc, env} ->
      case link_snapshot_dynamic_expr(value, env, dynamic_module_names, function_index) do
        {:ok, value, env} -> {:cont, {:ok, [value | acc], env}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, values, env} -> {:ok, Enum.reverse(values), env}
      {:error, error} -> {:error, error}
    end
  end

  defp link_snapshot_dynamic_exprs_keep_env(values, env, dynamic_module_names, function_index) do
    with {:ok, values, _env} <-
           link_snapshot_dynamic_exprs(values, env, dynamic_module_names, function_index) do
      {:ok, values, env}
    end
  end

  defp link_snapshot_dynamic_clauses(clauses, env, dynamic_module_names, function_index) do
    clauses
    |> Enum.reduce_while({:ok, []}, fn clause, {:ok, acc} ->
      with {:ok, guard, _guard_env} <-
             link_snapshot_dynamic_expr(clause.guard, env, dynamic_module_names, function_index),
           {:ok, body, _body_env} <-
             link_snapshot_dynamic_expr(clause.body, env, dynamic_module_names, function_index) do
        {:cont, {:ok, [%{clause | guard: guard, body: body} | acc]}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, clauses} -> {:ok, Enum.reverse(clauses)}
      {:error, error} -> {:error, error}
    end
  end

  defp maybe_put_expr(expr, _key, nil), do: expr
  defp maybe_put_expr(expr, key, value), do: Map.put(expr, key, value)

  defp bind_literal_snapshot_modules(%{node: :var_pattern, name: name}, rhs, env),
    do: bind_literal_snapshot_module(name, literal_snapshot_module(rhs, env), env)

  defp bind_literal_snapshot_modules(%{node: :var, name: name}, rhs, env),
    do: bind_literal_snapshot_module(name, literal_snapshot_module(rhs, env), env)

  defp bind_literal_snapshot_modules(_pattern, _rhs, env), do: env

  defp bind_literal_snapshot_module("_", _module, env), do: env
  defp bind_literal_snapshot_module(_name, nil, env), do: env
  defp bind_literal_snapshot_module(name, module, env), do: Map.put(env, name, module)

  defp literal_snapshot_module(%{node: :atom, value: module}, _env), do: module
  defp literal_snapshot_module(%{node: :var, name: name}, env), do: Map.get(env, name)
  defp literal_snapshot_module(_expr, _env), do: nil

  defp dynamic_snapshot_candidates(dynamic_module_names, function_index, function, arity) do
    dynamic_module_names
    |> Enum.flat_map(fn module ->
      case Map.fetch(function_index, {module, function, arity}) do
        {:ok, mapped} -> [%{module: module, function: mapped, arity: arity}]
        :error -> []
      end
    end)
  end

  defp exact_dynamic_snapshot_candidates(candidates, nil), do: candidates

  defp exact_dynamic_snapshot_candidates(candidates, module) do
    Enum.filter(candidates, &(&1.module == module))
  end

  defp dynamic_snapshot_call_error(function, arity) do
    {:error,
     Hyperlang.Error.new(
       :source,
       "source snapshot dynamic module call #{function}/#{arity} is not linked"
     )}
  end

  defp dangling_snapshot_module_calls(functions, module_names) do
    functions
    |> Enum.flat_map(fn function ->
      Enum.flat_map(function.clauses, fn clause ->
        dangling_snapshot_expr(clause.guard, module_names) ++
          dangling_snapshot_expr(clause.body, module_names)
      end)
    end)
    |> Enum.uniq()
  end

  defp dangling_snapshot_expr(nil, _module_names), do: []

  defp dangling_snapshot_expr(
         %{node: :remote_call, module: module, function: function, args: args},
         module_names
       ) do
    current =
      if MapSet.member?(module_names, module) do
        [{:remote, module, function, length(args)}]
      else
        []
      end

    current ++ dangling_snapshot_expr(args, module_names)
  end

  defp dangling_snapshot_expr(%{} = expr, module_names) do
    expr
    |> Map.values()
    |> dangling_snapshot_expr(module_names)
  end

  defp dangling_snapshot_expr(values, module_names) when is_list(values) do
    Enum.flat_map(values, &dangling_snapshot_expr(&1, module_names))
  end

  defp dangling_snapshot_expr(_value, _module_names), do: []

  defp dangling_snapshot_module_call_error({:remote, module, function, arity}) do
    {:error,
     Hyperlang.Error.new(
       :source,
       "source snapshot linked module call #{module}:#{function}/#{arity} is not exported"
     )}
  end

  defp rewrite_source_function(function, module, module_names, function_index) do
    mapped_name = Map.fetch!(function_index, {module, function.name, function.arity})

    %{
      function
      | name: mapped_name,
        clauses:
          Enum.map(function.clauses, fn clause ->
            %{
              clause
              | guard: rewrite_snapshot_expr(clause.guard, module, module_names, function_index),
                body: rewrite_snapshot_expr(clause.body, module, module_names, function_index)
            }
          end)
    }
  end

  defp rewrite_snapshot_expr(nil, _module, _module_names, _function_index), do: nil

  defp rewrite_snapshot_expr(
         %{node: :local_call, function: "apply", args: [target, function, args]},
         module,
         module_names,
         function_index
       ) do
    candidates =
      for {{candidate_module, source_function, arity}, mapped} <- function_index,
          MapSet.member?(module_names, candidate_module) do
        %{
          module: candidate_module,
          source_function: source_function,
          function: mapped,
          arity: arity
        }
      end

    %{
      node: :snapshot_apply,
      target: rewrite_snapshot_expr(target, module, module_names, function_index),
      function: rewrite_snapshot_expr(function, module, module_names, function_index),
      args: rewrite_snapshot_expr(args, module, module_names, function_index),
      candidates: candidates
    }
  end

  defp rewrite_snapshot_expr(
         %{node: :local_call, function: function, args: args} = expr,
         module,
         module_names,
         function_index
       ) do
    arity = length(args)
    args = rewrite_snapshot_exprs(args, module, module_names, function_index)

    case Map.fetch(function_index, {module, function, arity}) do
      {:ok, mapped} -> %{expr | function: mapped, args: args}
      :error -> %{expr | args: args}
    end
  end

  defp rewrite_snapshot_expr(
         %{node: :remote_call, module: remote, function: function, args: args} = expr,
         module,
         module_names,
         function_index
       ) do
    arity = length(args)
    args = rewrite_snapshot_exprs(args, module, module_names, function_index)

    expr = %{
      expr
      | args: rewrite_snapshot_spawn_target(remote, function, args, module, function_index)
    }

    if MapSet.member?(module_names, remote) and
         not preserve_snapshot_remote_call?(remote, function, args) do
      case Map.fetch(function_index, {remote, function, arity}) do
        {:ok, mapped} -> %{node: :local_call, function: mapped, args: args}
        :error -> expr
      end
    else
      expr
    end
  end

  defp rewrite_snapshot_expr(
         %{node: :dynamic_remote_call, module: dynamic_module, args: args} = expr,
         module,
         module_names,
         function_index
       ) do
    %{
      expr
      | module: rewrite_snapshot_expr(dynamic_module, module, module_names, function_index),
        args: rewrite_snapshot_exprs(args, module, module_names, function_index)
    }
  end

  defp rewrite_snapshot_expr(
         %{node: :block, exprs: exprs} = expr,
         module,
         module_names,
         function_index
       ) do
    %{expr | exprs: rewrite_snapshot_exprs(exprs, module, module_names, function_index)}
  end

  defp rewrite_snapshot_expr(
         %{node: :local_fun_ref, function: function, arity: arity} = expr,
         module,
         _module_names,
         function_index
       ) do
    case Map.fetch(function_index, {module, function, arity}) do
      {:ok, mapped} -> %{expr | function: mapped}
      :error -> expr
    end
  end

  defp rewrite_snapshot_expr(%{} = expr, module, module_names, function_index) do
    Map.new(expr, fn
      {key, value} when key in [:function, :module, :name] ->
        {key, value}

      {key, value} ->
        {key, rewrite_snapshot_expr(value, module, module_names, function_index)}
    end)
  end

  defp rewrite_snapshot_expr(values, module, module_names, function_index) when is_list(values),
    do: rewrite_snapshot_exprs(values, module, module_names, function_index)

  defp rewrite_snapshot_expr(value, _module, _module_names, _function_index), do: value

  defp rewrite_snapshot_exprs(values, module, module_names, function_index) do
    Enum.map(values, &rewrite_snapshot_expr(&1, module, module_names, function_index))
  end

  defp rewrite_snapshot_spawn_target("sys", "spawn", args, module, function_index) do
    case args do
      [%{node: :atom, value: function} = target, %{node: :list, items: spawn_args} = argv | rest] ->
        case Map.fetch(function_index, {module, function, length(spawn_args)}) do
          {:ok, mapped} -> [%{target | value: mapped}, argv | rest]
          :error -> args
        end

      [%{node: :atom, value: function} = target, argv | rest] ->
        case unique_snapshot_function_name(function_index, module, function) do
          {:ok, mapped} -> [%{target | value: mapped}, argv | rest]
          :error -> args
        end

      _other ->
        args
    end
  end

  defp rewrite_snapshot_spawn_target(_remote, _function, args, _module, _function_index), do: args

  defp unique_snapshot_function_name(function_index, module, function) do
    matches =
      function_index
      |> Enum.flat_map(fn
        {{^module, ^function, _arity}, mapped} -> [mapped]
        _other -> []
      end)
      |> Enum.uniq()

    case matches do
      [mapped] -> {:ok, mapped}
      _other -> :error
    end
  end

  defp preserve_snapshot_remote_call?(_module, _function, _args), do: false

  defp build_instance_state(program, stored, supplied_bindings, options) do
    # Optional `:caller_manifest` overlay: a spawned child rebuilds its
    # program from that program's stored (verification-tier) manifest. For a
    # code-path LIBRARY that manifest is the narrow derivation default
    # (filesystem `backend: :own`, `modules.path` `/sys/lib`) — as a BINDING the
    # library executes under the caller's manifest, but a SPAWNED child
    # rebuilt standalone would lose that. The host re-attaches the
    # spawning Prog's already-granted runtime manifest surface (filesystem
    # facade + widened code path) so the child runs exactly as the spawning Prog
    # did and a same-package `Module:fn` callback hatch resolves across the spawn
    # boundary. Every derived capability is still gated by the caller's manifest,
    # so the child can reach nothing the spawning Prog could not. A non-map (or
    # absent) value leaves the stored manifest untouched. `limits`/`terms`/
    # bindings stay the library's own (the overlay touches only the runtime
    # filesystem facade and the module code-path search set).
    instance_manifest =
      overlay_caller_manifest(stored.manifest, get_option(options, :caller_manifest, nil))

    with :ok <- Manifest.validate_filesystem(instance_manifest),
         {:ok, bindings} <- Manifest.bind_bindings(stored.manifest, supplied_bindings),
         {:ok, limits} <- Manifest.merge_limits(stored.manifest, options),
         {:ok, terms} <- Manifest.merge_terms(stored.manifest, options),
         terms = merge_compat_source_atoms(terms, stored),
         {:ok, filesystem} <-
           maybe_start_filesystem(instance_manifest.filesystem, options, stored),
         {:ok, table_service} <- maybe_start_table_service(instance_manifest.tables),
         {:ok, syscall} <- maybe_attach_syscall(options) do
      errstr = get_option(options, :errstr, nil)
      token = :erlang.unique_integer([:positive, :monotonic])

      limits_group = acquire_limits_group(limits, get_option(options, :run_in_caller?, false))

      runtime = %{
        token: token,
        bindings: bindings,
        manifest: instance_manifest,
        limits: limits,
        terms: terms,
        slot_module: stored.slot.module,
        slot_version: stored.slot.version,
        source_module: runtime_source_module(stored.metadata),
        stack_map: Map.get(stored, :stack_map, %{}),
        atom_pool: Map.get(stored, :atom_pool, %{}),
        atom_allowed: Map.get(stored, :atom_allowed, MapSet.new()),
        atom_universe: Map.get(stored, :atom_universe, Map.get(stored.manifest, :atom_universe)),
        host_scope: get_option(options, :scope, nil) || Hyperlang.Scope.current(),
        host_owner: self(),
        filesystem: filesystem,
        table_service: table_service,
        syscall: syscall,
        errstr: errstr,
        source_snapshot_modules: source_snapshot_modules(stored, terms)
      }

      # `limits` and `terms` are the outputs of Manifest's closed normalizers
      # above, and `token` is the fresh integer we just created. Stamp that
      # kernel-built policy directly so every entry uses the validated-runtime
      # identity check instead of recursively walking policy maps per instance.
      runtime = Terms.stamp_prevalidated_runtime(runtime)

      with {:ok, context_template} <- Runtime.build_context_template(runtime) do
        runtime = Map.put(runtime, :context_template, context_template)

        {:ok,
         %{
           program_key: program.content_hash,
           program: program,
           slot: stored.slot,
           bindings: bindings,
           limits: limits,
           limits_group: limits_group,
           terms: terms,
           token: token,
           runtime: runtime,
           filesystem: filesystem,
           table_service: table_service,
           syscall: syscall
         }}
      else
        error ->
          maybe_stop_filesystem(filesystem)
          maybe_stop_table_service(table_service)
          release_limits_group(limits_group)
          error
      end
    end
  end

  defp merge_compat_source_atoms(terms, stored) do
    compat_atoms = Map.get(stored, :compat_source_atoms, MapSet.new())
    Map.update!(terms, :allowed_atoms, &MapSet.union(&1, compat_atoms))
  end

  defp source_snapshot_modules(stored, terms) do
    case Map.fetch(stored, :source_snapshot_modules) do
      {:ok, modules} when is_map(modules) ->
        modules

      _ ->
        source_snapshot_modules(
          Map.get(stored, :metadata, %{}),
          Map.get(stored, :atom_pool, %{}),
          terms
        )
    end
  end

  defp source_snapshot_modules(metadata, atom_pool, terms) do
    source_to_pool =
      Map.new(atom_pool || %{}, fn {pool, source} -> {source, pool} end)

    allowed_atoms = Map.get(terms, :allowed_atoms, MapSet.new())

    metadata
    |> get_in([:source_snapshot, :sources])
    |> case do
      sources when is_list(sources) ->
        sources
        |> Enum.reduce(%{}, fn source, acc ->
          module = Map.get(source, :module) || Map.get(source, "module")

          case source_module_atom(module, source_to_pool, allowed_atoms) do
            {:ok, atom} when is_binary(module) ->
              Map.put(acc, module, %{
                atom: atom,
                path: Map.get(source, :path) || Map.get(source, "path"),
                source_hash: Map.get(source, :hash) || Map.get(source, "hash"),
                source: :snapshot
              })

            _ ->
              acc
          end
        end)

      _ ->
        %{}
    end
  end

  defp source_module_atom(module, source_to_pool, allowed_atoms) when is_binary(module) do
    case Map.fetch(source_to_pool, module) do
      {:ok, atom} ->
        {:ok, atom}

      :error ->
        allowed_source_module_atom(module, allowed_atoms)
    end
  end

  defp source_module_atom(_module, _source_to_pool, _allowed_atoms), do: :error

  defp allowed_source_module_atom(module, %MapSet{} = allowed_atoms) do
    case existing_atom(module) do
      {:ok, atom} ->
        if MapSet.member?(allowed_atoms, atom) or MapSet.member?(allowed_atoms, module) do
          {:ok, atom}
        else
          :error
        end

      :error ->
        :error
    end
  end

  defp allowed_source_module_atom(_module, _allowed_atoms), do: :error

  defp existing_atom(source) when is_binary(source) do
    {:ok, String.to_existing_atom(source)}
  rescue
    ArgumentError -> :error
  end

  defp runtime_source_module(metadata) do
    get_in(metadata || %{}, [:source_contract, :module]) ||
      source_snapshot_entry_module(metadata)
  end

  defp source_snapshot_entry_module(%{source_snapshot: %{entry: entry, sources: sources}})
       when is_binary(entry) and is_list(sources) do
    Enum.find_value(sources, fn
      %{path: ^entry, module: module} when is_binary(module) -> module
      %{"path" => ^entry, "module" => module} when is_binary(module) -> module
      _other -> nil
    end)
  end

  defp source_snapshot_entry_module(_metadata), do: nil

  defp public_exports_from_exports(exports) do
    %{
      functions:
        exports
        |> Map.get(:functions, Map.get(exports, "functions", %{}))
        |> public_function_exports(),
      files:
        exports
        |> Map.get(:files, Map.get(exports, "files", []))
        |> public_file_exports()
    }
  end

  defp public_function_exports(functions) when is_map(functions) do
    Map.new(functions, fn {id, export} ->
      {id,
       %{
         id: export_field(export, :id),
         function: export_field(export, :function),
         arity: export_field(export, :arity),
         input: export_field(export, :input, %{}),
         output: export_field(export, :output, %{})
       }}
    end)
  end

  defp public_function_exports(_functions), do: %{}

  defp public_file_exports(files) when is_list(files) do
    Enum.map(files, fn file ->
      export = %{
        path: export_field(file, :path),
        op: export_field(file, :op),
        rights: export_field(file, :rights, [])
      }

      export
      |> maybe_put_export_field(file, :type)
      |> maybe_put_export_field(file, :function)
      |> maybe_put_export_field(file, :arity)
      |> maybe_put_export_field(file, :input)
      |> maybe_put_export_field(file, :output)
      |> maybe_put_export_field(file, :effects)
      |> maybe_put_export_field(file, :metadata)
      |> maybe_put_export_field(file, :reactive_policy)
      |> maybe_put_export_deps(file)
    end)
  end

  defp public_file_exports(_files), do: []

  defp maybe_put_export_field(export, file, field) do
    case export_field(file, field, nil) do
      nil -> export
      value -> Map.put(export, field, value)
    end
  end

  defp maybe_put_export_deps(export, file) do
    case export_field(file, :deps, []) do
      [] -> export
      deps -> Map.put(export, :deps, deps)
    end
  end

  defp export_field(map, field, default \\ nil)

  defp export_field(map, field, default) when is_map(map) do
    case Map.fetch(map, field) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(field), default)
    end
  end

  defp export_field(_map, _field, default), do: default

  defp safe_metadata(metadata),
    do: Map.drop(metadata || %{}, [:generated_exports, :stack_map, :public_exports])

  defp closed_source(code) do
    entry = Map.get(code, :entry) || Map.get(code, "entry")
    files = Map.get(code, :files) || Map.get(code, "files")
    manifest = Map.get(code, :manifest) || Map.get(code, "manifest") || %{}

    cond do
      not is_binary(entry) or entry == "" ->
        {:error, Hyperlang.Error.new(:source, "program entry must be a source basename")}

      Path.basename(entry) != entry ->
        {:error, Hyperlang.Error.new(:source, "program entry must not contain a path")}

      not is_map(files) or map_size(files) == 0 ->
        {:error, Hyperlang.Error.new(:source, "program files must be a non-empty map")}

      not Map.has_key?(files, entry) ->
        {:error, Hyperlang.Error.new(:source, "program entry is missing from files")}

      true ->
        {:program, compile_closed_snapshot(entry, files, manifest)}
    end
  rescue
    ArgumentError -> {:error, Hyperlang.Error.new(:source, "invalid program source value")}
  end

  defp compile_closed_snapshot(entry, files, manifest) do
    with {:ok, normalized} <- Manifest.normalize(manifest) do
      Compiler.run_bounded(normalized.limits, fn ->
        with {:ok, kind} <- closed_source_kind(entry, files, normalized) do
          case kind do
            {:standalone, source} -> compile_closed_standalone(entry, files, source, normalized)
            :snapshot -> compile_closed_module_snapshot(entry, files, normalized)
          end
        end
      end)
    end
  end

  defp closed_source_kind(entry, files, _normalized) when map_size(files) == 1 do
    case Map.fetch(files, entry) do
      {:ok, source} when is_binary(source) ->
        if Regex.match?(~r/(?:^|\n)\s*-module\s*\(/, source),
          do: {:ok, :snapshot},
          else: {:ok, {:standalone, source}}

      _other ->
        {:ok, :snapshot}
    end
  end

  defp closed_source_kind(_entry, _files, _normalized), do: {:ok, :snapshot}

  defp compile_closed_standalone(entry, files, source, normalized) do
    source_hash = Program.sha256_hex(%{entry: entry, files: files})
    normalized = ensure_atom_universe(normalized, source_hash)
    manifest_hash = cache_manifest_hash(normalized)
    cache_key = program_cache_key(source_hash, manifest_hash)

    with {:ok, compiled} <- Compiler.compile(source, normalized),
         normalized = ensure_callback_exports(normalized, compiled),
         {:ok, forms, metadata} <-
           Compiler.run_bounded(normalized.limits, fn ->
             Codegen.to_forms(compiled, normalized)
           end) do
      build_program(
        forms,
        normalized,
        compiled,
        metadata,
        source_hash,
        manifest_hash,
        cache_key,
        %{
          source_snapshot_hash: source_hash,
          source_snapshot: %{
            entry: entry,
            sources: [%{path: entry, hash: Program.sha256_hex(source)}]
          }
        }
      )
    end
  end

  defp compile_closed_module_snapshot(entry, files, normalized) do
    with {:ok, snapshot} <- closed_snapshot(entry, files, normalized),
         {:ok, snapshot, normalized} <- inject_gen_server_guest_lib(snapshot, normalized),
         source_hash = Program.sha256_hex(snapshot.public),
         normalized = ensure_atom_universe(normalized, source_hash),
         {:ok, snapshot} <- parse_source_snapshot(snapshot, normalized),
         {:ok, ast} <- build_source_snapshot_ast(snapshot, normalized),
         {:ok, compiled} <- Compiler.compile_ast(ast, normalized),
         normalized = ensure_callback_exports(normalized, compiled),
         {:ok, forms, metadata} <-
           Compiler.run_bounded(normalized.limits, fn ->
             Codegen.to_forms(compiled, normalized)
           end) do
      manifest_hash = cache_manifest_hash(normalized)
      cache_key = program_cache_key(source_hash, manifest_hash)

      build_program(
        forms,
        normalized,
        compiled,
        metadata,
        source_hash,
        manifest_hash,
        cache_key,
        source_snapshot_metadata(snapshot, source_hash)
      )
    end
  end

  defp closed_snapshot(entry, files, normalized) do
    files =
      Enum.reduce_while(files, {:ok, []}, fn {name, source}, {:ok, acc} ->
        name = to_string(name)

        cond do
          Path.basename(name) != name ->
            {:halt, {:error, Hyperlang.Error.new(:source, "program files must be basenames")}}

          not is_binary(source) ->
            {:halt, {:error, Hyperlang.Error.new(:source, "program source must be binary")}}

          true ->
            path = "/" <> name

            case source_module_identity(path, source, normalized) do
              {:ok, module} ->
                if Path.rootname(name) == module do
                  file = %{
                    path: path,
                    entry?: name == entry,
                    module: module,
                    language: :erlang,
                    source: source,
                    hash: Program.sha256_hex(source),
                    byte_size: byte_size(source)
                  }

                  {:cont, {:ok, [file | acc]}}
                else
                  {:halt,
                   {:error,
                    Hyperlang.Error.new(:source, "source basename must equal its module name",
                      details: %{file: name}
                    )}}
                end

              {:error, error} ->
                {:halt, {:error, error}}
            end
        end
      end)

    case files do
      {:ok, reversed} ->
        files = Enum.reverse(reversed)

        public = %{
          entry: "/" <> entry,
          sources:
            Enum.map(files, fn file ->
              Map.take(file, [:path, :module, :hash, :byte_size]) |> Map.put(:generation, nil)
            end)
        }

        {:ok, %{entry: "/" <> entry, files: files, public: public}}

      error ->
        error
    end
  end

  defp load_program(%Program{content_hash: hash, artifact: artifact} = program)
       when is_binary(hash) and is_map(artifact) do
    CodeServer.load(program)
  end

  defp load_program(_program),
    do: {:error, Hyperlang.Error.new(:api, "invalid immutable program value")}

  # The run uses the slot's canonical program literal, not the caller's heap
  # copy: everything the run state and its worker capture from the program is
  # then shared, never copied per run.
  defp prepare_run_state(program, bindings, options) do
    with {:ok, %{program: program} = slot} <- load_program(program) do
      program
      |> runtime_artifact(slot)
      |> then(&build_instance_state(program, &1, bindings, options))
    end
  end

  defp runtime_artifact(%Program{artifact: %{runtime: runtime} = artifact} = program, slot) do
    runtime
    |> Map.put(:manifest, artifact.manifest)
    |> Map.put(:metadata, program.metadata)
    |> Map.put(:program, program)
    |> Map.put(:slot, slot)
  end

  defp normalize_door_spec(spec) do
    bindings = Map.get(spec, :bindings, %{})
    syscall = Map.get(spec, :syscall)
    policy = Map.get(spec, :policy, %{})

    obsolete_spec? = Enum.any?(["bindings", "syscall", "policy"], &Map.has_key?(spec, &1))

    obsolete_policy? =
      is_map(policy) and
        Enum.any?(
          [:budget, :cpu_max, :reduction_rate, :reduction_budget],
          &Map.has_key?(policy, &1)
        )

    if is_map(bindings) and is_map(policy) and not obsolete_spec? and not obsolete_policy? do
      limits =
        policy
        |> Map.get(:limits, %{})
        |> Map.merge(
          Map.take(policy, [
            :wall_ms,
            :heap_words,
            :max_heap_words,
            :ceiling,
            :rate,
            :max_reductions,
            :max_procs
          ])
        )

      terms =
        policy
        |> Map.get(:terms, %{})
        |> maybe_put_atoms(Map.get(policy, :atoms))

      options = %{
        limits: limits,
        terms: terms,
        syscall: syscall,
        scope: Map.get(policy, :scope),
        filesystem: Map.get(policy, :filesystem, []),
        errstr: Map.get(policy, :errstr),
        caller_manifest: Map.get(policy, :caller_manifest),
        run_in_caller?: Map.get(policy, :run_in_caller?, false),
        skip_unused_filesystem_server?: Map.get(policy, :skip_unused_filesystem_server?, false)
      }

      worker_opts =
        [run_in_caller?: Map.get(policy, :run_in_caller?, false)]
        |> Keyword.put(:keep_bindings, Map.get(policy, :keep_bindings, true))
        |> maybe_worker_option(:host_state, policy)
        |> maybe_worker_option(:wall_timeout, policy)
        |> maybe_worker_option(:guest_dictionary_frame_id, policy)
        |> maybe_worker_option(:guest_dictionary_entries, policy)
        |> maybe_worker_option(:restore_guest_dictionary_entries?, policy)

      {:ok, bindings, options, worker_opts}
    else
      {:error,
       Hyperlang.Error.new(
         :api,
         "spec requires atom keys and canonical limits; bindings and policy must be maps"
       )}
    end
  end

  defp maybe_put_atoms(terms, nil), do: terms
  defp maybe_put_atoms(terms, atoms) when is_map(terms), do: Map.put(terms, :allowed_atoms, atoms)

  defp maybe_worker_option(options, key, policy) do
    if Map.has_key?(policy, key),
      do: Keyword.put(options, key, Map.fetch!(policy, key)),
      else: options
  end

  defp program_cache_key(source_hash, manifest_hash) when is_binary(manifest_hash) do
    Program.sha256_hex(%{
      source_hash: source_hash,
      manifest_hash: manifest_hash,
      artifact: compiler_fingerprint()
    })
  end

  defp ensure_atom_universe(%{atom_universe: nil} = normalized, source_hash) do
    verification_hash =
      normalized
      |> Map.put(:atom_universe, nil)
      |> cache_manifest_hash()

    Manifest.with_atom_universe(
      normalized,
      {:hyperlang_program_graph, source_hash, verification_hash}
    )
  end

  defp ensure_atom_universe(%{atom_universe: _universe} = normalized, _source_hash),
    do: normalized

  defp cache_manifest_hash(normalized) do
    normalized
    |> cache_manifest()
    |> Program.sha256_hex()
  end

  defp cache_manifest(normalized) do
    normalized
    |> Manifest.public_manifest()
    |> Map.put(:result_explicit?, Map.get(normalized, :result_explicit?, false))
  end

  defp validate_source_hash_limits(source, %{limits: limits}) when is_binary(source) do
    cond do
      byte_size(source) > limits.max_source_bytes ->
        {:error, Hyperlang.Error.new(:lexer, "source byte size exceeds limit")}

      source_line_count(source) > limits.max_line_count ->
        {:error, Hyperlang.Error.new(:lexer, "source line count exceeds limit")}

      true ->
        :ok
    end
  end

  defp source_line_count(source),
    do: source |> :binary.matches("\n") |> length() |> Kernel.+(1)

  defp get_option(options, key, default) when is_map(options) do
    Map.get(options, key, Map.get(options, Atom.to_string(key), default))
  end

  defp get_option(options, key, default) when is_list(options),
    do: Keyword.get(options, key, default)

  defp get_option(_, _, default), do: default

  # Re-attach a spawning Prog's already-granted runtime filesystem surface onto a
  # freshly built child manifest. Only one runtime-execution field moves:
  #
  #   * `filesystem` — the spawning Prog's facade (e.g. host `backend: :host`),
  #     so the child reads through the same door/namespace the caller used. A
  #     code-path library's stored facade is the narrow derivation default
  #     (`backend: :own`); without this the child cannot read its package files.
  #
  # Everything else (limits, terms, exports, atom universe, capabilities) stays
  # as the child program's own stored manifest. A non-map overlay (nil/absent)
  # is a no-op. The overlay never enables a disabled filesystem subsystem:
  # filesystem is adopted only if the caller's is enabled.
  defp overlay_caller_manifest(manifest, %{} = caller) do
    overlay_caller_filesystem(manifest, Map.get(caller, :filesystem))
  end

  defp overlay_caller_manifest(manifest, _caller), do: manifest

  defp overlay_caller_filesystem(manifest, %{enabled: true} = caller_fs),
    do: Map.put(manifest, :filesystem, caller_fs)

  defp overlay_caller_filesystem(manifest, _caller_fs), do: manifest

  defp maybe_start_filesystem(%{enabled: true} = filesystem, options, stored) do
    cond do
      Map.get(filesystem, :backend) == :host ->
        {:ok, nil}

      explicit_filesystem_attach?(options) ->
        start_filesystem_server(filesystem, options)

      skip_unused_filesystem_server?(options) and
          not stored_runtime_filesystem_server_required?(stored) ->
        {:ok, nil}

      true ->
        start_filesystem_server(filesystem, options)
    end
  end

  defp maybe_start_filesystem(_filesystem, _options, _stored), do: {:ok, nil}

  defp maybe_start_table_service(%{enabled: true} = tables), do: Hyperlang.Table.start(tables)
  defp maybe_start_table_service(_tables), do: {:ok, nil}

  defp explicit_filesystem_attach?(options) do
    case get_option(options, :filesystem, []) do
      value when is_list(value) -> Keyword.has_key?(value, :attach)
      _value -> false
    end
  end

  defp skip_unused_filesystem_server?(options),
    do: get_option(options, :skip_unused_filesystem_server?, false) == true

  defp stored_runtime_filesystem_server_required?(%{derived_capabilities: capabilities}),
    do: capabilities_require_filesystem_server?(capabilities)

  defp stored_runtime_filesystem_server_required?(%{
         metadata: %{derived_capabilities: capabilities}
       }),
       do: capabilities_require_filesystem_server?(capabilities)

  defp stored_runtime_filesystem_server_required?(%{}), do: true

  defp capabilities_require_filesystem_server?(capabilities) when is_map(capabilities) do
    Enum.any?(Map.get(capabilities, :facades, []), &filesystem_server_facade?/1) or
      Map.get(capabilities, :code, []) != []
  end

  defp capabilities_require_filesystem_server?(_capabilities), do: true

  defp filesystem_server_facade?({"file", _function, _arity}), do: true
  defp filesystem_server_facade?({"filelib", _function, _arity}), do: true
  defp filesystem_server_facade?(_facade), do: false

  defp start_filesystem_server(filesystem, options) do
    filesystem_options =
      case get_option(options, :filesystem, []) do
        value when is_list(value) -> value
        _value -> []
      end

    case Keyword.get(filesystem_options, :attach) do
      nil ->
        Hyperlang.Filesystem.start(filesystem, filesystem_options)

      %Hyperlang.Filesystem.Handle{} = handle ->
        case Hyperlang.Filesystem.attach(handle) do
          {:ok, attached} ->
            {:ok, attached}

          {:error, reason} ->
            {:error,
             Hyperlang.Error.new(:filesystem, "attached filesystem server is unavailable",
               details: %{reason: reason}
             )}
        end

      _other ->
        {:error,
         Hyperlang.Error.new(:filesystem, "invalid attached filesystem handle",
           details: %{reason: :invalid_filesystem_handle}
         )}
    end
  end

  defp maybe_attach_syscall(options) do
    case get_option(options, :syscall, nil) do
      nil ->
        {:ok, nil}

      fun when is_function(fun, 2) or is_function(fun, 3) ->
        {:ok, fun}

      {module, _state} = host when is_atom(module) and not is_nil(module) ->
        {:ok, host}

      _other ->
        {:error,
         Hyperlang.Error.new(:api, "invalid syscall callback",
           details: %{reason: :invalid_syscall_callback}
         )}
    end
  end

  defp maybe_stop_filesystem(%Hyperlang.Filesystem.Handle{owned?: false}), do: :ok

  defp maybe_stop_filesystem(%Hyperlang.Filesystem.Handle{} = filesystem),
    do: Hyperlang.Filesystem.stop(filesystem)

  defp maybe_stop_filesystem(_filesystem), do: :ok

  defp maybe_stop_table_service(%Hyperlang.Table.Handle{} = table_service),
    do: Hyperlang.Table.stop(table_service)

  defp maybe_stop_table_service(_table_service), do: :ok

  # Door-owned per-run resources: a run that started its own filesystem server
  # or table service stops it when the run returns.
  defp stop_run_resources(%{} = run_state) do
    maybe_stop_filesystem(Map.get(run_state, :filesystem))
    maybe_stop_table_service(Map.get(run_state, :table_service))
    :ok
  end

  defp acquire_limits_group(limits, in_caller?) do
    group_limits = Map.drop(limits, [:wall_ms, :heap_words, :max_heap_words])

    if in_caller? not in [nil, false],
      do: Hyperlang.Limits.in_caller_group(group_limits),
      else: Hyperlang.Limits.run_group(group_limits)
  end

  defp release_limits_group(group) do
    Hyperlang.Limits.delete(group)
  end
end
