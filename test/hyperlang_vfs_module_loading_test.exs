defmodule HyperlangVfsModuleLoadingTest do
  # Module loading: library attributes, derived capability
  # gating, and impl_hash-keyed artifact sharing. Libraries are pre-seeded
  # into the memory filesystem mount, so caller manifests stay minimal.
  use ExUnit.Case, async: true

  defp manifest(files, opts \\ []) do
    ensure_file_atoms!(files)

    base = %{
      terms: %{public: :erlang},
      modules: %{enabled: true},
      bindings: Keyword.get(opts, :bindings, %{}),
      filesystem: %{
        enabled: true,
        file_compat: Keyword.get(opts, :file_compat, false),
        mounts: [
          %{
            virtual: "/sys/lib",
            backend: "memory",
            mode: :memory,
            allow: [:read, :list, :stat],
            files: Enum.filter(files, &String.starts_with?(&1.path, "/sys/lib/"))
          },
          %{
            virtual: "/data",
            backend: "memory",
            mode: :memory,
            allow: [:read, :list, :stat],
            files: Enum.reject(files, &String.starts_with?(&1.path, "/sys/lib/"))
          }
        ]
      }
    }

    base =
      case Keyword.get(opts, :limits) do
        nil -> base
        limits -> Map.put(base, :limits, limits)
      end

    case Keyword.get(opts, :exports, []) do
      [] -> base
      exports -> Map.put(base, :exports, %{functions: export_specs(exports)})
    end
  end

  defp export_specs(exports) do
    Map.new(exports, fn {name, arity} ->
      id = name <> "/" <> Integer.to_string(arity)
      {id, %{function: name, arity: arity, input: %{}, output: %{}}}
    end)
  end

  defp eval!(source, manifest, input \\ :ok) do
    ensure_source_atoms!(source)
    {:ok, program} = Hyperlang.Test.program(source, manifest)

    Hyperlang.Test.run(program, :entry, [input])
  end

  defp lib_file(name, source), do: %{path: "/sys/lib/" <> name, content: source}

  defp ensure_file_atoms!(files) do
    Enum.each(files, fn file ->
      file.path
      |> Path.basename()
      |> ensure_atom!()

      for [_, module] <- Regex.scan(~r/-module\(([^)]+)\)/, file.content || "") do
        ensure_atom!(module)
      end

      ensure_source_atom_tokens!(file.content || "")
    end)
  end

  defp ensure_source_atoms!(source) do
    for [_, module] <- Regex.scan(~r/\b([a-z][a-zA-Z0-9_]*)\s*:/, source) do
      ensure_atom!(module)
    end

    for [_, module] <- Regex.scan(~r/-module\(([^)]+)\)/, source) do
      ensure_atom!(module)
    end
  end

  defp ensure_source_atom_tokens!(source) do
    for [atom] <- Regex.scan(~r/\b[a-z][a-zA-Z0-9_]*\b/, source) do
      ensure_atom!(atom)
    end
  end

  defp ensure_atom!(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.trim("'")
    |> case do
      name when byte_size(name) <= 128 -> String.to_atom(name)
      _name -> :ok
    end
  end

  defp unique_lib(name, body) do
    suffix = "%% #{:erlang.unique_integer([:positive])}\n"
    "-module(#{name}).\n" <> body <> suffix
  end

  test "library with a banned construct fails verification, not the capability gate" do
    lib = unique_lib("banned", "-export([f/0]).\nf() -> erlang:halt().\n")
    files = [lib_file("banned", lib)]

    assert {:error, error} = eval!("banned:f().", manifest(files))
    assert error.category == :module
    assert error.details["reason"] == "verification_failed"
  end

  test "library with a syntax error fails verification" do
    lib = "-module(broken).\n-export([f/0]).\nf() -> case of end end.\n"
    files = [lib_file("broken", lib)]

    assert {:error, error} = eval!("broken:f().", manifest(files))
    assert error.category == :module
    assert error.details["reason"] == "verification_failed"
  end

  test "calling into an export-less behaviour-contract module raises undef" do
    contract =
      "-module(codec).\n-callback encode(term()) -> binary().\n" <>
        "-callback decode(binary()) -> {ok, term()} | {error, atom()}.\n"

    files = [lib_file("codec", contract)]

    assert {:error, error} = eval!(~S|codec:encode(1).|, manifest(files))
    assert error.details["reason"] == "undef"
  end

  test "unknown attributes keep today's rejection" do
    source = """
    -module(prog).
    -compile(export_all).
    result(X) -> X.
    """

    assert {:error, [error]} =
             Hyperlang.Test.program(source, %{terms: %{public: :erlang}})

    assert error.category == :parse
    assert error.message =~ "not supported"
  end

  test "callback dispatch syntax is not available in regular programs" do
    assert {:error, [error]} =
             Hyperlang.Test.program("Module = Input, Module:answer().", manifest([]))

    assert error.category == :verify
    assert error.message =~ "dynamic remote calls are forbidden"
  end

  test "own-module remote call dispatches to the local function" do
    source = """
    -module(selfy).
    result(X) -> selfy:helper(X).
    helper(X) -> X + 1.
    """

    assert {:ok, 5, _} = eval!(source, manifest([]), 4)
  end

  test "own module wins over a same-named code-path file" do
    shadow = "-module(selfy).\n-export([helper/1]).\nhelper(X) -> X + 1000.\n"
    files = [lib_file("selfy", shadow)]

    source = """
    -module(selfy).
    result(X) -> selfy:helper(X).
    helper(X) -> X + 1.
    """

    assert {:ok, 5, _} = eval!(source, manifest(files), 4)
  end

  test "own-module remote call works without modules enabled" do
    source = """
    -module(selfy).
    result(X) -> selfy:helper(X).
    helper(X) -> X + 1.
    """

    {:ok, program} = Hyperlang.Test.program(source, %{terms: %{public: :erlang}})

    assert {:ok, 5, _} = Hyperlang.Test.run(program, :entry, [4])
  end

  test "export-only eval still enforces input sanitization before no-result error" do
    source = "-module(export_only_input).\n-export([visible/0]).\nvisible() -> ok.\n"

    {:ok, program} =
      Hyperlang.Test.program(source, manifest([], exports: [{"visible", 0}]))

    assert {:error, error} =
             Hyperlang.Test.run(program, :entry, [self()], policy: [run_in_caller?: true])

    # No result entry exists, so canonical Hyperlang rejects eval before its
    # unused host input crosses into guest code.
    assert error.category == :eval
  end
end
