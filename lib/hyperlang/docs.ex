defmodule Hyperlang.Docs do
  # EEP-48 documentation chunks for the `code:get_doc/1` discovery surface.
  #
  # Four tiers, all producing
  # `{:docs_v1, Anno, :erlang, <<"text/markdown">>, ModuleDoc, Meta, Entries}`:
  #
  #   * library tier — built at verification from `-moduledoc`/`-doc`/`-spec`
  #     metadata and stored in the artifact;
  #   * facade tier (`sys`/`file`/`filelib`/`io`/`code`) — generated from the
  #     same canonical call tables that gate classification, so docs and gate
  #     share one source and cannot drift;
  #   * sticky OTP stdlib tier — the module's real OTP Docs chunk, extracted
  #     host-side and filtered to the allowlisted `{function, arity}` set,
  #     with all metadata (which names host paths) stripped;
  #   * binding tier — synthesized from the manifest's pinned binding exports
  #     and the host-supplied `docs` option each export may carry, so every
  #     module the binding resolution tier can answer for is also discoverable.
  #
  # Function names inside library and facade chunks are stored as **binaries**,
  # never atoms: chunk contents are derived from guest-controlled source, and
  # Hyperlang never converts guest strings into host atoms. `Hyperlang.Code`
  # translates the names into the calling program's pooled atoms at the reply
  # boundary when (and only when) the caller names them.
  @moduledoc false

  # EEP-48 permits arbitrary MIME formats; the compatibility contract uses
  # plain text because binding docs are generated prose rather than Markdown.
  @doc_format <<"text/plain">>
  @facade_modules ~w(code file filelib io hyperlang_table sys)

  def facade_modules, do: @facade_modules
  def facade_module?(module), do: module in @facade_modules

  ## Library tier ------------------------------------------------------------

  # Build a docs chunk straight from parsed module metadata (used for
  # export-less behaviour-contract modules, which are never compiled).
  def metadata_chunk(meta, exports, span_for \\ fn _key -> nil end) do
    meta = meta || empty_module_metadata()

    entries =
      Enum.map(exports, fn {name, arity} ->
        signature =
          spec_signature(name, arity, Map.get(meta.specs, {name, arity})) ||
            default_signature(name, arity)

        {{:function, name, arity}, span_anno(span_for.({name, arity})), [signature],
         doc_value(Map.get(meta.docs, {name, arity})), %{}}
      end)

    {:docs_v1, 1, :erlang, @doc_format, module_doc_value(meta.moduledoc), %{}, entries}
  end

  defp empty_module_metadata,
    do: %{vsn: nil, moduledoc: nil, docs: %{}, specs: %{}, callbacks: %{}, behaviours: []}

  defp module_doc_value(nil), do: :none
  defp module_doc_value(:hidden), do: :hidden
  defp module_doc_value(doc) when is_binary(doc), do: %{<<"en">> => doc}
  defp module_doc_value(_other), do: :none

  defp doc_value(nil), do: :none
  defp doc_value(:hidden), do: :hidden
  defp doc_value(doc) when is_binary(doc), do: %{<<"en">> => doc}
  defp doc_value(_other), do: :none

  defp span_anno(%{line: line, col: col}) when is_integer(line) and is_integer(col),
    do: {line, col}

  defp span_anno(%{line: line}) when is_integer(line), do: line
  defp span_anno(_span), do: 1

  # Synthesize `parse(Args, NoArg, WithArg)` from `-spec` argument names;
  # unnamed positions fall back to `ArgN`.
  defp spec_signature(_name, _arity, nil), do: nil

  defp spec_signature(name, arity, %{raw: types}) when is_list(types) do
    case Enum.find_value(types, &fun_arg_names(&1, arity)) do
      nil -> nil
      names -> name <> "(" <> Enum.join(names, ", ") <> ")"
    end
  end

  defp spec_signature(_name, _arity, _spec), do: nil

  defp fun_arg_names({:type, _anno, :bounded_fun, [fun | _constraints]}, arity),
    do: fun_arg_names(fun, arity)

  defp fun_arg_names({:type, _anno, :fun, [{:type, _panno, :product, args}, _return]}, arity)
       when length(args) == arity do
    args
    |> Enum.with_index(1)
    |> Enum.map(&arg_name/1)
  end

  defp fun_arg_names(_type, _arity), do: nil

  defp arg_name({{:ann_type, _anno, [{:var, _vanno, var} | _type]}, _index}), do: var_name(var)
  defp arg_name({_type, index}), do: "Arg" <> Integer.to_string(index)

  defp var_name(var) when is_atom(var), do: Atom.to_string(var)
  defp var_name(var) when is_binary(var), do: var
  defp var_name(var) when is_list(var), do: List.to_string(var)

  defp default_signature(name, 0), do: name <> "()"

  defp default_signature(name, arity) do
    args = Enum.map_join(1..arity, ", ", &("Arg" <> Integer.to_string(&1)))
    name <> "(" <> args <> ")"
  end

  ## Facade tier -------------------------------------------------------------

  # The full canonical `{function, arity}` table for one facade module — the
  # exact set the classifier gates through (`Hyperlang.Sys` tables, the
  # filesystem compat MFA lists, the stdlib `io` matrices, and the
  # `Hyperlang.Code` table). The parity test pins chunk == gate on this set.
  def facade_mfas("sys") do
    Hyperlang.Sys.supported_sys_mfas()
    |> Enum.map(fn {"sys", function, arity} -> {function, arity} end)
    |> Enum.sort()
  end

  def facade_mfas(module) when module in ["file", "filelib"] do
    Hyperlang.Filesystem.supported_mfas()
    |> Enum.flat_map(fn
      {^module, function, arity} -> [{function, arity}]
      _other -> []
    end)
    |> Enum.sort()
  end

  def facade_mfas("io"), do: stdlib_gate_mfas("io")

  def facade_mfas("code") do
    Hyperlang.Code.supported_mfas()
    |> Enum.map(fn {"code", function, arity} -> {function, arity} end)
    |> Enum.sort()
  end

  def facade_mfas("hyperlang_table") do
    Hyperlang.Table.supported_mfas()
    |> Enum.map(fn {"hyperlang_table", function, arity} -> {function, arity} end)
    |> Enum.sort()
  end

  # Whether the manifest's call gate admits one facade call — the same
  # predicates the classifier uses, so per-manifest docs are always a subset
  # of what the gate would admit.
  def facade_gate_admits?(manifest, "io", function, arity),
    do: Hyperlang.Stdlib.allowed?(manifest, "io", function, arity)

  def facade_gate_admits?(manifest, "code", function, arity),
    do: Hyperlang.Code.call_target(manifest, "code", function, arity) != :error

  def facade_gate_admits?(manifest, "hyperlang_table", function, arity),
    do: Hyperlang.Table.call_target(manifest, "hyperlang_table", function, arity) != :error

  def facade_gate_admits?(manifest, module, function, arity)
      when module in ["sys", "file", "filelib"],
      do: Hyperlang.Filesystem.call_target(manifest, module, function, arity) != :error

  def facade_gate_admits?(_manifest, _module, _function, _arity), do: false

  def facade_chunk(manifest, module) when module in @facade_modules do
    entries =
      for {function, arity} <- facade_mfas(module),
          facade_gate_admits?(manifest, module, function, arity) do
        doc = %{
          <<"en">> =>
            "Hyperlang " <>
              module <>
              " facade call " <>
              module <>
              ":" <>
              function <>
              "/" <>
              Integer.to_string(arity) <> "."
        }

        {{:function, function, arity}, 1, [default_signature(function, arity)], doc, %{}}
      end

    {:docs_v1, 1, :erlang, @doc_format, facade_module_doc(module), %{}, entries}
  end

  defp facade_module_doc("sys"),
    do: %{<<"en">> => "Plan 9/Inferno-shaped Hyperlang system call facade."}

  defp facade_module_doc("file"),
    do: %{<<"en">> => "Hyperlang mirror of the Erlang file module, gated by the manifest."}

  defp facade_module_doc("filelib"),
    do: %{<<"en">> => "Hyperlang mirror of the Erlang filelib module, gated by the manifest."}

  defp facade_module_doc("io"),
    do: %{<<"en">> => "Hyperlang captured-io mirror of the Erlang io module."}

  defp facade_module_doc("code"),
    do: %{<<"en">> => "Read-only Hyperlang code path discovery surface."}

  defp facade_module_doc("hyperlang_table"),
    do: %{<<"en">> => "Per-instance, quota-capped Hyperlang table service."}

  ## Binding tier --------------------------------------------------------------

  # Every binding name the manifest declares, in sorted order — the binding
  # module catalog for the `code:` surface. Names are binaries, normalized by
  # `Hyperlang.Manifest.normalize/1`.
  def import_modules(manifest) do
    manifest
    |> Map.get(:bindings, %{})
    |> Map.keys()
    |> Enum.sort()
  end

  def import_module?(manifest, name), do: name in import_modules(manifest)

  # Build the docs chunk for a binding: one function entry per pinned export,
  # sorted by `{function, arity}`. Doc text comes from the export's `docs`
  # option (`%{moduledoc, doc, signature}`); the host is trusted, but the
  # shape is normalized defensively — anything missing or mis-shaped is
  # simply absent (Doc `:none`, default signature). ModuleDoc is the first non-nil moduledoc among the binding's
  # exports. Function names are **binaries**, exactly like the library and
  # facade tiers; `Hyperlang.Code` translates them into the caller's pooled
  # atoms at the reply boundary.
  def import_chunk(manifest, module) do
    imports =
      manifest
      |> Map.get(:bindings, %{})
      |> Map.get(module, %{exports: %{}})
      |> Map.fetch!(:exports)
      |> Enum.sort_by(fn {{function, arity}, _meta} -> {function, arity} end)

    module_doc =
      imports
      |> Enum.find_value(fn {_call, meta} ->
        case meta_value(import_docs(meta), :moduledoc) do
          moduledoc when is_binary(moduledoc) -> moduledoc
          _other -> nil
        end
      end)
      |> module_doc_value()

    entries =
      Enum.map(imports, fn {{function, arity}, meta} ->
        docs = import_docs(meta)

        signature =
          case meta_value(docs, :signature) do
            signature when is_binary(signature) -> signature
            _other -> default_signature(function, arity)
          end

        doc =
          case meta_value(docs, :doc) do
            doc when is_binary(doc) -> %{<<"en">> => doc}
            _other -> :none
          end

        {{:function, function, arity}, 1, [signature], doc, %{}}
      end)

    {:docs_v1, 1, :erlang, @doc_format, module_doc, %{}, entries}
  end

  # The export's `docs` option, or `%{}` when absent/invalid.
  defp import_docs(meta) do
    case meta_value(meta, :docs) do
      docs when is_map(docs) -> docs
      _other -> %{}
    end
  end

  defp meta_value(map, key) when is_map(map), do: Map.get(map, key)

  defp meta_value(_map, _key), do: nil

  ## Sticky OTP stdlib tier --------------------------------------------------

  # Extract the real OTP Docs chunk host-side and filter its entries to the
  # `{function, arity}` set the stdlib gate admits under this manifest.
  # Non-function entries (types, callbacks) are dropped, all metadata maps are
  # stripped (OTP metadata names host source paths), and annotations are
  # normalized to line/column integers.
  #
  # Hyperlang-implemented stdlib-surface modules with no OTP chunk fall back to a
  # chunk synthesized from the same gate matrices, exactly like facades, so
  # `code:get_doc/1` stays total over the `code:all_available/0` catalog.
  # `missing` is reserved for names with neither an OTP chunk nor gate entries.
  def stdlib_chunk(manifest, module) when is_binary(module) do
    case host_filtered_chunk(manifest, module) do
      {:ok, chunk} -> {:ok, chunk}
      :error -> synthesized_stdlib_chunk(manifest, module)
    end
  end

  defp host_filtered_chunk(manifest, module) do
    with {:ok, module_atom} <- existing_module_atom(module),
         {:ok, {:docs_v1, anno, _lang, format, module_doc, _meta, entries}} <-
           host_get_doc(module_atom) do
      filtered =
        for {{:function, function, arity}, entry_anno, signature, doc, _entry_meta} <- entries,
            Hyperlang.Stdlib.allowed?(manifest, module, Atom.to_string(function), arity) do
          {{:function, function, arity}, clean_anno(entry_anno), signature, doc, %{}}
        end

      {:ok, {:docs_v1, clean_anno(anno), :erlang, format, module_doc, %{}, filtered}}
    end
  end

  defp synthesized_stdlib_chunk(manifest, module) do
    case stdlib_gate_mfas(module) do
      [] ->
        {:error, :missing}

      mfas ->
        entries =
          for {function, arity} <- mfas,
              Hyperlang.Stdlib.allowed?(manifest, module, function, arity) do
            doc = %{
              <<"en">> =>
                "Hyperlang stdlib surface call " <>
                  module <> ":" <> function <> "/" <> Integer.to_string(arity) <> "."
            }

            {{:function, function, arity}, 1, [default_signature(function, arity)], doc, %{}}
          end

        module_doc = %{
          <<"en">> => "Hyperlang-implemented stdlib surface module " <> module <> "."
        }

        {:ok, {:docs_v1, 1, :erlang, @doc_format, module_doc, %{}, entries}}
    end
  end

  # Every `{function, arity}` the stdlib gate knows for one module, from the
  # canonical classification matrices.
  def stdlib_gate_mfas(module) do
    [
      Hyperlang.Stdlib.captured_matrix(),
      Hyperlang.Stdlib.direct_matrix(),
      Hyperlang.Stdlib.wrapped_matrix()
    ]
    |> Enum.flat_map(fn matrix ->
      for {function, arities} <- Map.get(matrix, module, %{}), arity <- arities do
        {function, arity}
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp existing_module_atom(module) do
    {:ok, String.to_existing_atom(module)}
  rescue
    ArgumentError -> :error
  end

  defp host_get_doc(module_atom) do
    case :code.get_doc(module_atom) do
      {:ok, {:docs_v1, _anno, _lang, _format, _doc, _meta, _entries} = chunk} -> {:ok, chunk}
      _other -> :error
    end
  end

  defp clean_anno(anno) when is_integer(anno) and anno >= 0, do: anno

  defp clean_anno({line, col}) when is_integer(line) and is_integer(col) and line >= 0,
    do: {line, col}

  defp clean_anno(anno) do
    case :erl_anno.location(anno) do
      location when is_integer(location) and location >= 0 -> location
      {line, col} when is_integer(line) and is_integer(col) -> {line, col}
      _other -> 1
    end
  rescue
    _error -> 1
  end
end
