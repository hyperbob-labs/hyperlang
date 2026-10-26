defmodule HyperlangVfsCodeSurfaceTest do
  # The `code:` discovery surface, EEP-48 docs
  # chunks per tier, the `:docs` reply boundary and chunk size cap, and the
  # errstr-through-door best effort.
  use ExUnit.Case, async: true

  @myjson_source """
  -module(myjson).
  -vsn(1).
  -moduledoc "JSON parsing and encoding.".
  -export([parse/1, encode/1, info/0]).

  -doc "Parse a JSON binary.".
  -spec parse(Bytes :: binary()) -> {ok, term()} | {error, atom()}.
  parse(Bytes) -> {ok, Bytes}.

  -spec encode(term()) -> binary().
  encode(_Value) -> <<"null">>.

  info() -> ok.
  """

  defp manifest(files, opts \\ []) do
    ensure_file_atoms!(files)

    %{
      terms: Map.merge(%{public: :erlang}, Keyword.get(opts, :terms, %{})),
      bindings: Keyword.get(opts, :bindings, %{}),
      modules: Keyword.get(opts, :modules, %{enabled: true}),
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
    ensure_source_atoms!(source)
    {impls, opts} = Keyword.pop(opts, :impls, %{})
    {:ok, program} = Hyperlang.Test.program(source, manifest)

    Hyperlang.Test.run(program, :entry, [:ok], bindings: impls, policy: Map.new(opts))
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

    for [_, module] <-
          Regex.scan(
            ~r/\bcode:(?:which|ensure_loaded|is_loaded|get_doc)\(([a-z][a-zA-Z0-9_]*)\)/,
            source
          ) do
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

  ## code:get_path/0 ---------------------------------------------------------

  test "code:get_path() returns the manifest code path as charlists" do
    assert {:ok, [~c"/sys/lib"], _} = eval!("code:get_path().", manifest([]))
  end

  test "code: calls are compile errors with modules disabled, exactly like today" do
    for source <- [
          "code:get_path().",
          "code:which(lists).",
          "code:all_available().",
          "code:get_doc(lists)."
        ] do
      assert {:error, errors} =
               Hyperlang.Test.program(source, manifest([], modules: %{enabled: false}))

      assert is_list(errors)
    end
  end

  ## code:which/1 ------------------------------------------------------------

  test "code:which resolves code-path modules, sticky surface, and non_existing" do
    files = [lib_file("myjson", @myjson_source)]

    assert {:ok, ~c"/sys/lib/myjson", _} =
             eval!("code:which(myjson).", manifest(files))

    # Facades are preloaded; enabled stdlib is preloaded; sticky names are
    # never shadowed by a same-named code-path file.
    for sticky <- ["file", "filelib", "io", "code", "lists", "erlang"] do
      assert {:ok, :preloaded, _} =
               eval!("code:which(#{sticky}).", manifest([lib_file("lists", "-module(lists).")]))
    end

    assert {:ok, :non_existing, _} =
             eval!("code:which(nosuchmodule).", manifest(files))
  end

  test "code:which is namespace-dependent: a different bound /sys/lib gives a different answer" do
    lib = unique_lib("nsdep", "-export([f/0]).\nf() -> 1.\n")
    with_lib = manifest([lib_file("nsdep", lib)])
    without_lib = manifest([])

    assert {:ok, ~c"/sys/lib/nsdep", _} = eval!("code:which(nsdep).", with_lib)
    assert {:ok, :non_existing, _} = eval!("code:which(nsdep).", without_lib)
  end

  test "code:which raises Erlang's own badarg for a non-atom argument" do
    source = ~S"""
    try code:which(<<"myjson">>) catch error:badarg -> caught end.
    """

    assert {:ok, "caught", _} = eval!(source, manifest([]))
  end

  ## code:is_loaded/1 and code:ensure_loaded/1 -------------------------------

  test "code:is_loaded reports remaining sticky surfaces as preloaded" do
    assert {:ok, {:file, :preloaded}, _} = eval!("code:is_loaded(io).", manifest([]))
  end

  test "code:ensure_loaded returns {module, Mod} for sticky modules" do
    assert {:ok, {:module, "lists"}, _} =
             eval!("code:ensure_loaded(lists).", manifest([]))
  end

  test "code:ensure_loaded still reaches legacy loader-compat modules when nothing is on the path" do
    files = [
      %{path: "/src/legacy.erl", content: "-module(legacy).\n-export([f/0]).\nf() -> 1.\n"}
    ]

    m = manifest(files, loader_compat: true, source_compile: true, file_compat: true)

    source = """
    {ok, legacy} = compile:file("/src/legacy.erl"),
    code:ensure_loaded(legacy).
    """

    assert {:ok, {:module, "legacy"}, _} = eval!(source, m)
  end

  ## code:all_available/0 ----------------------------------------------------

  test "code:all_available reflects the bound namespace and tolerates unreadable path dirs" do
    lib_a = unique_lib("only_a", "-export([f/0]).\nf() -> 1.\n")
    lib_b = unique_lib("only_b", "-export([f/0]).\nf() -> 2.\n")

    source = """
    [Name || {Name, Path, _} <- code:all_available(), Path =/= preloaded].
    """

    assert {:ok, [~c"only_a"], _} = eval!(source, manifest([lib_file("only_a", lib_a)]))
    assert {:ok, [~c"only_b"], _} = eval!(source, manifest([lib_file("only_b", lib_b)]))

    # A code-path directory nothing is mounted at contributes nothing.
    unreadable =
      manifest([lib_file("only_a", lib_a)],
        modules: %{enabled: true, path: ["/sys/lib", "/nope"]}
      )

    assert {:ok, [~c"only_a"], _} = eval!(source, unreadable)
  end

  test "disabled stdlib modules are absent from the catalog and non_existing to which" do
    m = manifest([])
    m = put_in(m, [:terms], %{public: :erlang})
    m = Map.put(m, :stdlib, %{lists: false})

    source = """
    {code:which(lists), [N || {"lists", _, _} = N <- code:all_available()]}.
    """

    assert {:ok, {:non_existing, []}, _} = eval!(source, m)
  end

  ## code:get_doc/1 — library tier --------------------------------------------

  test "get_doc returns non_existing for unresolved and broken modules" do
    files = [lib_file("broken", "-module(broken).\n-export([f/0]).\nf() -> erlang:halt().\n")]
    m = manifest(files)

    assert {:ok, {:error, :non_existing}, _} = eval!("code:get_doc(nosuch).", m)
    assert {:ok, {:error, :non_existing}, _} = eval!("code:get_doc(broken).", m)
  end

  test "behaviour-contract module without exports still yields its moduledoc" do
    contract = """
    -module(codecdoc).
    -moduledoc "The codec contract.".
    -callback encode(term()) -> binary().
    """

    source = ~S"""
    {ok, {docs_v1, _, erlang, _, #{<<"en">> := MDoc}, _, Entries}} = code:get_doc(codecdoc),
    {MDoc, Entries}.
    """

    assert {:ok, {"The codec contract.", []}, _} =
             eval!(source, manifest([lib_file("codecdoc", contract)]))
  end

  test "facade get_doc is generated from the gate tables and respects the manifest" do
    source = """
    {ok, {docs_v1, _, erlang, <<"text/plain">>, _, _, Entries}} = code:get_doc(code),
    [{F, A} || {{function, F, A}, _, _, _, _} <- Entries].
    """

    assert {:ok, entries, _} = eval!(source, manifest([]))

    assert Enum.sort(entries) == [
             {"all_available", 0},
             {"ensure_loaded", 1},
             {"get_doc", 1},
             {"get_path", 0},
             {"is_loaded", 1},
             {"which", 1}
           ]
  end

  test "facade docs chunks and the call gate share one source and cannot drift" do
    {:ok, full} =
      Hyperlang.Manifest.normalize(%{
        modules: %{enabled: true},
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
    for module <- Hyperlang.Docs.facade_modules(),
        Hyperlang.Docs.facade_mfas(module) != [],
        Enum.any?(Hyperlang.Docs.facade_mfas(module), fn {f, a} ->
          Hyperlang.Docs.facade_gate_admits?(full, module, f, a)
        end) do
      {:docs_v1, _, :erlang, _, _, _, entries} = Hyperlang.Docs.facade_chunk(full, module)
      chunk_set = MapSet.new(for {{:function, f, a}, _, _, _, _} <- entries, do: {f, a})
      assert chunk_set == MapSet.new(Hyperlang.Docs.facade_mfas(module))
    end
  end

  ## code:get_doc/1 — sticky OTP stdlib tier ----------------------------------

  test "stdlib get_doc filters the real OTP chunk to the allowlisted set" do
    {:ok, normalized} = Hyperlang.Manifest.normalize(%{modules: %{enabled: true}})

    assert {:ok, {:docs_v1, _, :erlang, _, _module_doc, meta, entries}} =
             Hyperlang.Docs.stdlib_chunk(normalized, "erlang")

    # All metadata stripped: nothing can name a host path.
    assert meta == %{}

    for {{:function, function, arity}, anno, _signature, _doc, entry_meta} <- entries do
      assert Hyperlang.Stdlib.allowed?(normalized, "erlang", Atom.to_string(function), arity)
      assert entry_meta == %{}

      assert is_integer(anno) or
               (is_tuple(anno) and tuple_size(anno) == 2 and
                  anno |> Tuple.to_list() |> Enum.all?(&is_integer/1))
    end

    # The host chunk has entries the verifier rejects; none of them survive.
    {:ok, {:docs_v1, _, _, _, _, _, host_entries}} = :code.get_doc(:erlang)

    host_set =
      MapSet.new(for {{:function, f, a}, _, _, _, _} <- host_entries, do: {Atom.to_string(f), a})

    filtered_set =
      MapSet.new(for {{:function, f, a}, _, _, _, _} <- entries, do: {Atom.to_string(f), a})

    rejected = MapSet.difference(host_set, filtered_set)
    assert MapSet.size(rejected) > 0

    for {function, arity} <- rejected do
      refute Hyperlang.Stdlib.allowed?(normalized, "erlang", function, arity)
    end
  end

  test "guest get_doc never sees a non-allowlisted stdlib entry and sees allowlisted ones" do
    source = """
    {ok, {docs_v1, _, erlang, _, _, _, Lists}} = code:get_doc(lists),
    {ok, {docs_v1, _, erlang, _, _, _, Erl}} = code:get_doc(erlang),
    Map = [X || {{function, map, 2}, _, _, _, _} = X <- Lists],
    Halt = [X || {{function, halt, A}, _, _, _, _} = X <- Erl, A >= 0],
    Spawn = [X || {{function, spawn, A}, _, _, _, _} = X <- Erl, A >= 0],
    {Map =/= [], Halt, Spawn}.
    """

    assert {:ok, {true, [], []}, _} = eval!(source, manifest([]))
  end

  test "unknown userland libraries are not Hyperlang stdlib chunks" do
    {:ok, normalized} = Hyperlang.Manifest.normalize(%{modules: %{enabled: true}})

    assert Hyperlang.Docs.stdlib_chunk(normalized, "guest_store") == {:error, :missing}
    assert Hyperlang.Docs.stdlib_chunk(normalized, "guest_pages") == {:error, :missing}
    assert Hyperlang.Docs.stdlib_gate_mfas("guest_store") == []
    assert Hyperlang.Docs.stdlib_gate_mfas("guest_pages") == []
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
             eval!(
               source,
               manifest([], bindings: kv_bindings()),
               impls: kv_bindings()
             )
  end

  test "import get_doc: docs metadata moduledoc, doc, signature, and Doc none defaults" do
    source = ~S"""
    {ok, {docs_v1, _, erlang, <<"text/plain">>, #{<<"en">> := MDoc}, _, Entries}} =
      code:get_doc(kv),
    [GetSig] = [S || {{function, get, 1}, _, [S], #{<<"en">> := _}, _} <- Entries],
    [GetDoc] = [D || {{function, get, 1}, _, _, #{<<"en">> := D}, _} <- Entries],
    [PutSig] = [S || {{function, put, 2}, _, [S], none, _} <- Entries],
    {MDoc, GetSig, GetDoc, PutSig, length(Entries)}.
    """

    assert {:ok, result, _} =
             eval!(source, manifest([], bindings: kv_bindings()), impls: kv_bindings())

    assert result == {
             "Host key-value store.",
             "get(Key)",
             "Get a value by key.",
             "put(Arg1, Arg2)",
             2
           }
  end

  test "import get_doc suggests the nearest import module for unknown names" do
    source = """
    code:get_doc(kvv).
    """

    assert {:ok, {:error, message}, _} =
             eval!(
               source,
               manifest([], bindings: kv_bindings(), terms: %{allowed_atoms: [:kvv]}),
               impls: kv_bindings()
             )

    assert message == "unknown module 'kvv'; did you mean 'kv'?"
  end

  test "imports without docs metadata still resolve with ModuleDoc none" do
    bindings = %{"plain" => %{f: fn -> :ok end}}

    source = """
    {ok, {docs_v1, _, erlang, _, ModuleDoc, _, Entries}} = code:get_doc(plain),
    Avail = [E || {"plain", _, _} = E <- code:all_available()],
    {ModuleDoc, Entries, Avail}.
    """

    assert {:ok, result, _} =
             eval!(source, manifest([], bindings: bindings), impls: bindings)

    assert {:none, [{{:function, "f", 0}, 1, ["f()"], :none, %{}}],
            [{~c"plain", ~c"import", true}]} = result
  end

  test "an import module shadows a same-named code-path file in discovery" do
    lib = unique_lib("kv", "-export([f/0]).\nf() -> 1.\n")
    files = [lib_file("kv", lib)]

    source = """
    {ok, {docs_v1, _, erlang, _, _, _, Entries}} = code:get_doc(kv),
    Avail = [E || {"kv", _, _} = E <- code:all_available()],
    {[{F, A} || {{function, F, A}, _, _, _, _} <- Entries], Avail}.
    """

    assert {:ok, result, _} =
             eval!(source, manifest(files, bindings: kv_bindings()), impls: kv_bindings())

    assert {[{"get", 1}, {"put", 2}], [{~c"kv", ~c"import", true}]} = result
  end

  test "oversized import get_doc reply is the same stable module error" do
    m =
      manifest([],
        bindings: kv_bindings(),
        modules: %{enabled: true, max_doc_chunk_bytes: 16}
      )

    assert {:error, error} = eval!("code:get_doc(kv).", m, impls: kv_bindings())
    assert error.category == :module
    assert error.details["reason"] == "doc_chunk_too_large"
  end

  test "code: calls stay compile errors with modules disabled even when imports exist" do
    m = manifest([], bindings: kv_bindings(), modules: %{enabled: false})

    for source <- ["code:get_doc(kv).", "code:all_available()."] do
      assert {:error, errors} = Hyperlang.Test.program(source, m)
      assert is_list(errors)
    end
  end

  ## Derived capabilities and the code: surface in libraries -------------------
end
