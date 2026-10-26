defmodule Hyperlang.DoorTestSupport do
  @moduledoc false

  # What `Hyperlang.Test` deliberately cannot cover, because the kit uses only
  # the public door:
  #
  #   * `seed_atom_universe/1` — tests that drive the compiler or manifest
  #     internals directly must seed the atom universe the door normally
  #     seeds between `Manifest.normalize/1` and the compiler.
  #   * `build_from_filesystem/3` — tests that stage sources in a
  #     `Hyperlang.Filesystem` server read them back into a source map. The
  #     filesystem server is an internal module, not part of the door.

  alias Hyperlang.{Error, Manifest}

  def seed_atom_universe(normalized) do
    Manifest.with_atom_universe(
      normalized,
      {:hyperlang_test_graph, System.unique_integer([:positive])}
    )
  end

  def build_from_filesystem(filesystem, spec, manifest) when is_map(spec) do
    entry = Map.get(spec, :entry)
    sources = Map.get(spec, :sources)

    cond do
      not is_binary(entry) ->
        {:error, [Error.new(:source, "source snapshot entry path is required")]}

      not is_list(sources) ->
        {:error, [Error.new(:source, "source wildcard discovery is disabled")]}

      length(sources) != length(Enum.uniq(sources)) ->
        {:error, [Error.new(:source, "duplicate source path")]}

      entry not in sources ->
        {:error, [Error.new(:source, "entry path is missing from source paths")]}

      true ->
        with {:ok, files} <- read_source_files(filesystem, sources) do
          Hyperlang.Test.program(%{
            entry: Path.basename(entry),
            files: Map.new(files, fn {path, source} -> {Path.basename(path), source} end),
            manifest: manifest
          })
        end
    end
  end

  defp read_source_files(filesystem, paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, files} ->
      case Hyperlang.Filesystem.read_file(filesystem, path) do
        {:ok, source} when is_binary(source) ->
          {:cont, {:ok, [{path, source} | files]}}

        {:error, reason} ->
          {:halt,
           {:error,
            [
              Error.new(:source, "source file read failed",
                details: %{path: path, reason: reason}
              )
            ]}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  end
end
