defmodule HyperlangCodeSurfaceTest do
  # The `code:` discovery surface, EEP-48 docs
  # chunks per tier, the `:docs` reply boundary and chunk size cap, and the
  # errstr-through-door best effort.
  use ExUnit.Case, async: true

  defp manifest(files, opts \\ []) do
    modules =
      %{enabled: true, path: ["/sys/lib"]}
      |> Map.merge(Keyword.get(opts, :modules, %{}))

    %{
      terms: %{public: :erlang},
      bindings: Keyword.get(opts, :bindings, %{}),
      modules: modules,
      atom_universe: Keyword.get(opts, :atom_universe),
      sys: %{enabled: Keyword.get(opts, :sys, false)},
      capabilities: %{nondeterminism: Keyword.get(opts, :nondeterminism, false)},
      filesystem: %{
        enabled: true,
        file_compat: Keyword.get(opts, :file_compat, false),
        loader_compat: Keyword.get(opts, :loader_compat, false),
        source_compile: Keyword.get(opts, :source_compile, false),
        mounts: [
          %{
            virtual: "/sys/lib",
            backend: "memory",
            mode: :memory,
            allow: [:read, :list, :stat],
            files: Enum.filter(files, &String.starts_with?(&1.path, "/sys/lib/"))
          },
          %{
            virtual: "/src",
            backend: "memory",
            mode: :memory,
            allow: [:read, :list, :stat],
            files: Enum.reject(files, &String.starts_with?(&1.path, "/sys/lib/"))
          }
        ]
      }
    }
  end

  defp eval!(source, manifest, opts \\ []) do
    {impls, opts} = Keyword.pop(opts, :impls, %{})
    {:ok, program} = Hyperlang.Test.program(source, manifest)

    Hyperlang.Test.run(program, :entry, [:ok], bindings: impls, policy: Map.new(opts))
  end

  defp lib_file(name, source), do: %{path: "/sys/lib/" <> name, content: source}

  ## code:which/1 ------------------------------------------------------------

  test "code:which raises badarg for invalid module-name atoms" do
    source = ~S"""
    try code:which('Bad-Name') catch error:badarg -> caught end.
    """

    assert {:ok, "caught", _} = eval!(source, manifest([]))
  end

  ## code:is_loaded/1 and code:ensure_loaded/1 -------------------------------

  test "code:is_loaded reports the sticky surface as preloaded" do
    assert {:ok, {:file, :preloaded}, _} = eval!("code:is_loaded(io).", manifest([]))
    assert {:ok, {:file, :preloaded}, _} = eval!("code:is_loaded(sys).", manifest([]))
  end

  ## code:get_doc/1 — no runtime code path tier -------------------------------

  test "get_doc does not inspect runtime code-path source files" do
    files = [lib_file("broken", "-module(broken).\n-export([f/0]).\nf() -> erlang:halt().\n")]
    m = manifest(files)

    assert {:ok, {:error, :non_existing}, _} = eval!("code:get_doc(myjson).", m)
    assert {:ok, {:error, :non_existing}, _} = eval!("code:get_doc(nosuch).", m)
    assert {:ok, {:error, :non_existing}, _} = eval!("code:get_doc(broken).", m)
  end

  test "oversized get_doc reply is a stable module error" do
    m = manifest([], modules: %{enabled: true, max_doc_chunk_bytes: 16})

    assert {:error, error} = eval!("code:get_doc(code).", m)
    assert error.category == :module
    assert error.details["reason"] == "doc_chunk_too_large"
  end

  ## code:get_doc/1 — facade tier ---------------------------------------------

  test "facade docs chunks and the call gate share one source and cannot drift" do
    {:ok, full} =
      Hyperlang.Manifest.normalize(%{
        modules: %{enabled: true},
        sys: %{enabled: true},
        tables: %{enabled: true},
        capabilities: %{nondeterminism: true},
        filesystem: %{
          enabled: true,
          file_compat: true,
          filelib_compat: true,
          handle_compat: true,
          loader_compat: true,
          source_compile: true
        }
      })

    {:ok, restricted} =
      Hyperlang.Manifest.normalize(%{
        modules: %{enabled: true},
        sys: %{enabled: false},
        filesystem: %{enabled: true, file_compat: true}
      })

    for manifest <- [full, restricted], module <- Hyperlang.Docs.facade_modules() do
      {:docs_v1, _, :erlang, _, _, _, entries} = Hyperlang.Docs.facade_chunk(manifest, module)
      chunk_set = MapSet.new(for {{:function, f, a}, _, _, _, _} <- entries, do: {f, a})

      gate_set =
        MapSet.new(
          for {f, a} <- Hyperlang.Docs.facade_mfas(module),
              Hyperlang.Docs.facade_gate_admits?(manifest, module, f, a),
              do: {f, a}
        )

      assert chunk_set == gate_set,
             "facade #{module} docs/gate drift: " <>
               inspect(
                 {MapSet.difference(chunk_set, gate_set), MapSet.difference(gate_set, chunk_set)}
               )
    end

    # Under the fully-enabled manifest the gate admits the whole canonical
    # table, so chunk == table: every gated {function, arity} is documented
    # and vice versa.
    for module <- Hyperlang.Docs.facade_modules() do
      {:docs_v1, _, :erlang, _, _, _, entries} = Hyperlang.Docs.facade_chunk(full, module)
      chunk_set = MapSet.new(for {{:function, f, a}, _, _, _, _} <- entries, do: {f, a})
      assert chunk_set == MapSet.new(Hyperlang.Docs.facade_mfas(module))
    end
  end

  ## code:get_doc/1 — sticky OTP stdlib tier ----------------------------------

  test "hyperbob_os fs and webfs libraries are not Hyperlang stdlib chunks" do
    {:ok, normalized} = Hyperlang.Manifest.normalize(%{modules: %{enabled: true}})

    assert Hyperlang.Docs.stdlib_chunk(normalized, "fs") == {:error, :missing}
    assert Hyperlang.Docs.stdlib_chunk(normalized, "webfs") == {:error, :missing}
    assert Hyperlang.Docs.stdlib_gate_mfas("fs") == []
    assert Hyperlang.Docs.stdlib_gate_mfas("webfs") == []
  end

  ## code:get_doc/1 and code:all_available/0 — binding tier ---------------------

  # `kv:get/1` carries docs metadata; `kv:put/2` carries none.
  defp kv_bindings do
    %{
      "kv" => %{
        get:
          {fn _key -> :ok end,
           docs: %{
             moduledoc: "Host key-value store.",
             doc: "Get a value by key.",
             signature: "get(Key)"
           }},
        put: fn _key, _value -> :ok end
      }
    }
  end

  test "import modules appear in code:all_available with the import marker" do
    source = """
    [E || {"kv", _, _} = E <- code:all_available()].
    """

    assert {:ok, [{~c"kv", ~c"import", true}], _} =
             eval!(source, manifest([], bindings: kv_bindings()), impls: kv_bindings())
  end

  ## Derived capabilities and the code: surface in libraries -------------------

  test "code: surface calls still record derived capabilities" do
    {:ok, program} = Hyperlang.Test.program("code:which(lists).", manifest([]))

    assert Map.from_struct(program).metadata.derived_capabilities.code == [
             {"code", "which", 1}
           ]
  end
end
