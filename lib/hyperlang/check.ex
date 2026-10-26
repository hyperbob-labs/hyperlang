defmodule Hyperlang.Check do
  @moduledoc """
  Static whole-image checking for multi-module guest programs.

  `run/2` is host-side tooling, not a guest surface. The image is a map of
  absolute virtual paths to source binaries, or a host directory that is read
  with `File`. Every command and library in the image goes through the
  standard compile pipeline under the image's own code-path resolution.

  Findings are maps with `:file`, `:line`, `:kind` and `:message`. The kinds
  are:

    * `:invalid_image`: the image is not a path map or an existing directory.
    * `:read_error`, `:wrong_module`, `:compile_error`: the standard pipeline
      rejected a source. Compile errors carry the line and span when the
      compiler attached one.
    * `:capability_not_granted`: a library's derived capability set exceeds
      the image manifest. The module loader applies the same gate.
    * `:unresolved_module`: a code-path call names a module with no file in
      any code-path directory of the image.
    * `:undefined_function`: a code-path call targets an existing library at
      a function and arity it does not export.
    * `:docs_missing`: an enabled sticky stdlib module whose OTP docs chunk
      cannot be produced host-side. Libraries are covered by construction,
      because every verified artifact carries a docs chunk.

  Module support is forced on for the pass. Checking an image under a
  modules-disabled manifest would reject every code-path call as undeclared.
  """

  alias Hyperlang.{Compiler, Docs, Manifest, ModuleLoader, OtpFrontend}

  @doc """
  Check every source in `image` against `manifest`.

  Returns `{:ok, []}` when the image is clean, or `{:error, findings}`.
  """
  @spec run(%{optional(String.t()) => binary()} | Path.t(), map()) ::
          {:ok, []} | {:error, [map()]}
  def run(image, manifest) do
    with {:ok, files} <- normalize_image(image),
         {:ok, normalized} <- normalize_manifest(manifest) do
      normalized = ensure_image_atom_universe(normalized, files)
      path_dirs = normalized.modules.path
      {library_files, command_files} = split_files(files, path_dirs)
      libraries = analyze_libraries(library_files, normalized)

      findings =
        Enum.flat_map(libraries, & &1.findings) ++
          Enum.flat_map(libraries, &resolution_findings(&1.path, &1.calls, libraries)) ++
          Enum.flat_map(command_files, &check_command(&1, libraries, normalized)) ++
          docs_coverage_findings(normalized)

      case findings do
        [] -> {:ok, []}
        findings -> {:error, findings}
      end
    end
  end

  ## Image input -------------------------------------------------------------

  defp normalize_image(image) when is_map(image) do
    if Enum.all?(image, fn {path, source} ->
         is_binary(path) and String.starts_with?(path, "/") and is_binary(source)
       end) do
      {:ok, Enum.sort(image)}
    else
      {:error,
       [
         finding(nil, nil, :invalid_image, "image must map absolute paths to source binaries")
       ]}
    end
  end

  defp normalize_image(root) when is_binary(root) do
    if File.dir?(root) do
      files =
        root
        |> list_image_files()
        |> Enum.flat_map(fn host_path ->
          virtual = "/" <> Path.relative_to(host_path, root)

          case File.read(host_path) do
            {:ok, source} -> [{virtual, source}]
            {:error, _reason} -> []
          end
        end)
        |> Enum.sort()

      {:ok, files}
    else
      {:error, [finding(nil, nil, :invalid_image, "image root directory not found: #{root}")]}
    end
  end

  defp normalize_image(_image),
    do:
      {:error,
       [finding(nil, nil, :invalid_image, "image must be a path->source map or a directory")]}

  defp list_image_files(root) do
    root
    |> File.ls!()
    |> Enum.flat_map(fn name ->
      path = Path.join(root, name)

      cond do
        File.dir?(path) -> list_image_files(path)
        File.regular?(path) -> [path]
        true -> []
      end
    end)
  end

  defp normalize_manifest(manifest) when is_map(manifest) do
    modules =
      manifest
      |> map_get(:modules, %{})
      |> Map.new(fn {key, value} -> {key, value} end)
      |> put_default_modules_path()
      |> Map.put(:enabled, true)

    case Manifest.normalize(Map.put(manifest, :modules, modules)) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, error} -> {:error, [error_finding(nil, error)]}
    end
  end

  defp normalize_manifest(_manifest),
    do: {:error, [finding(nil, nil, :invalid_manifest, "manifest must be a map")]}

  defp ensure_image_atom_universe(%{atom_universe: nil} = normalized, files) do
    Manifest.with_atom_universe(normalized, {:hyperlang_check_image, image_hash(files)})
  end

  defp ensure_image_atom_universe(normalized, _files), do: normalized

  defp image_hash(files), do: Hyperlang.Program.sha256_hex(files)

  defp map_get(map, key, default),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp put_default_modules_path(modules) do
    if Map.has_key?(modules, :path) or Map.has_key?(modules, "path") do
      modules
    else
      Map.put(modules, :path, ["/sys/lib"])
    end
  end

  defp split_files(files, path_dirs) do
    Enum.split_with(files, fn {path, _source} ->
      Path.dirname(path) in path_dirs
    end)
  end

  ## Libraries ---------------------------------------------------------------

  defp analyze_libraries(library_files, normalized) do
    Enum.map(library_files, &analyze_library(&1, normalized))
  end

  defp analyze_library({path, source}, normalized) do
    name = Path.basename(path)

    with :ok <- check_module_name(path, source, name, normalized),
         {:ok, exports} <- source_exports(path, source, normalized) do
      case exports do
        [] ->
          # Behaviour-contract module: parses, exports nothing, never
          # compiled or bound — nothing further to check statically.
          %{name: name, path: path, exports: MapSet.new(), calls: [], findings: []}

        exports ->
          compile_library(path, name, source, exports, normalized)
      end
    else
      {:finding, finding} ->
        %{name: name, path: path, exports: MapSet.new(), calls: [], findings: [finding]}
    end
  end

  defp check_module_name(path, source, name, normalized) do
    case OtpFrontend.source_module_names(source, normalized) do
      {:ok, [^name]} ->
        :ok

      {:ok, names} ->
        {:finding,
         finding(
           path,
           nil,
           :wrong_module,
           "-module #{inspect(names)} does not match file name #{inspect(name)}"
         )}

      {:error, error} ->
        {:finding, error_finding(path, error)}
    end
  end

  defp source_exports(path, source, normalized) do
    case OtpFrontend.source_export_names(source, normalized) do
      {:ok, exports} -> {:ok, Enum.uniq(exports)}
      {:error, error} -> {:finding, error_finding(path, error)}
    end
  end

  defp compile_library(path, name, source, exports, normalized) do
    case Compiler.compile(source, ModuleLoader.library_manifest(exports, normalized)) do
      {:ok, compiled} ->
        capabilities = Hyperlang.Capabilities.derive(compiled)

        capability_findings =
          case ModuleLoader.capability_violations(normalized, capabilities) do
            [] ->
              []

            violations ->
              [
                finding(
                  path,
                  nil,
                  :capability_not_granted,
                  "derived capabilities exceed the image manifest: " <>
                    describe_violations(violations)
                )
              ]
          end

        %{
          name: name,
          path: path,
          exports: MapSet.new(exports),
          calls: code_path_calls(compiled),
          findings: capability_findings
        }

      {:error, errors} ->
        %{
          name: name,
          path: path,
          exports: MapSet.new(exports),
          calls: [],
          findings: Enum.map(List.wrap(errors), &error_finding(path, &1))
        }
    end
  end

  defp describe_violations(violations) do
    Enum.map_join(violations, ", ", fn
      {module, function, arity} -> "#{module}:#{function}/#{arity}"
      module when is_binary(module) -> "code path module #{module}"
      other -> inspect(other)
    end)
  end

  defp code_path_calls(%{core: %{calls: calls}}) do
    for {:code_path, module, function, arity} <- calls, do: {module, function, arity}
  end

  ## Commands ----------------------------------------------------------------

  defp check_command({path, source}, libraries, normalized) do
    case Compiler.compile(source, normalized) do
      {:ok, compiled} ->
        resolution_findings(path, code_path_calls(compiled), libraries)

      {:error, errors} ->
        Enum.map(List.wrap(errors), &error_finding(path, &1))
    end
  end

  # Cross-module resolution over recorded export tables: every code-path
  # call must name a library present in the image, exported at that
  # function/arity. Libraries get the same pass over their own transitive
  # code-path calls.
  defp resolution_findings(path, calls, libraries) do
    index = Map.new(libraries, fn library -> {library.name, library} end)

    calls
    |> Enum.uniq()
    |> Enum.flat_map(fn {module, function, arity} ->
      case Map.fetch(index, module) do
        :error ->
          [
            finding(
              path,
              nil,
              :unresolved_module,
              "code-path call #{module}:#{function}/#{arity} resolves to no file on the code path"
            )
          ]

        {:ok, library} ->
          if MapSet.member?(library.exports, {function, arity}) do
            []
          else
            [
              finding(
                path,
                nil,
                :undefined_function,
                "code-path call #{module}:#{function}/#{arity} is not exported by #{library.path}"
              )
            ]
          end
      end
    end)
  end

  ## Docs coverage -----------------------------------------------------------

  # The docs-coverage assertion over the `code:all_available/0` catalog:
  # facades generate chunks by construction; verified libraries carry chunks
  # by construction (their failures are already findings); the sticky stdlib
  # tier depends on host OTP Docs chunks, so assert each enabled module's
  # chunk extracts.
  defp docs_coverage_findings(normalized) do
    Hyperlang.Code.sticky_modules(normalized)
    |> Enum.reject(&Docs.facade_module?/1)
    |> Enum.flat_map(fn module ->
      case Docs.stdlib_chunk(normalized, module) do
        {:ok, _chunk} ->
          []

        {:error, :missing} ->
          [
            finding(
              nil,
              nil,
              :docs_missing,
              "no OTP Docs chunk for enabled stdlib module #{module}; " <>
                "code:get_doc(#{module}) would return {error, missing}"
            )
          ]
      end
    end)
  end

  ## Findings ----------------------------------------------------------------

  defp error_finding(path, %Hyperlang.Error{} = error) do
    normalized = Hyperlang.Error.normalize(error)

    finding(
      path,
      get_in(normalized, [:span, :line]),
      :compile_error,
      normalized.message || to_string(normalized.category)
    )
  end

  defp error_finding(path, %{} = error) do
    finding(
      path,
      get_in(error, [:span, :line]) || map_get(error, :line, nil),
      :compile_error,
      map_get(error, :message, nil) || inspect(error)
    )
  end

  defp error_finding(path, error), do: finding(path, nil, :compile_error, inspect(error))

  defp finding(file, line, kind, message) do
    %{file: file, line: line, kind: kind, message: message}
  end
end
