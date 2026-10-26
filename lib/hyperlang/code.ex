defmodule Hyperlang.Code do
  # The guest-visible `code:` discovery surface. Read-only, gated by
  # `modules.enabled`, OTP-shaped returns. It reports sticky modules,
  # manifest imports, and source-snapshot modules. It never scans the
  # runtime filesystem or binds new modules.
  #
  # Replies cross the term boundary under the `:docs` sanitize category;
  # `code:get_doc/1` replies are additionally capped by
  # `modules.max_doc_chunk_bytes` — an oversized chunk raises a stable
  # `:module`-category error with reason `:doc_chunk_too_large` (documented
  # choice: the cap is a loader policy limit, not an OTP return value, so it
  # surfaces as a sandbox module error rather than overloading the OTP
  # `non_existing | missing` vocabulary).
  @moduledoc false

  alias Hyperlang.{Docs, ModuleLoader}

  @code_calls %{
    {"get_path", 0} => :get_path,
    {"which", 1} => :which,
    {"is_loaded", 1} => :is_loaded,
    {"ensure_loaded", 1} => :ensure_loaded,
    {"all_available", 0} => :all_available,
    {"get_doc", 1} => :get_doc
  }

  @supported_mfas @code_calls
                  |> Map.keys()
                  |> Enum.map(fn {function, arity} -> {"code", function, arity} end)
                  |> Enum.sort()

  # `\A...\z` (strict end anchor): `$` also matches before a trailing newline, so
  # `^...$` would admit `"foo\n"`. `\z` keeps the `code:` discovery surface's
  # module-name check a true basename (no trailing LF / `/` / `.` / `..`).
  @code_path_module_name ~r/\A[a-z][A-Za-z0-9_]*\z/

  def supported_mfas, do: @supported_mfas

  # `code:ensure_loaded/1` has ONE owner. It answers for the module-loading
  # surface when modules are enabled, and for the loader-compat surface over
  # the `compile:file` registry — so its gate is the union of the two, and the
  # dispatch below walks both tiers in resolution order.
  def call_target(manifest, "code", "ensure_loaded", 1) do
    if modules_enabled?(manifest) or loader_compat?(manifest), do: :ensure_loaded, else: :error
  end

  def call_target(manifest, "code", function, arity) do
    if modules_enabled?(manifest),
      do: Map.get(@code_calls, {function, arity}, :error),
      else: :error
  end

  def call_target(_manifest, _module, _function, _arity), do: :error

  ## Dispatch ----------------------------------------------------------------

  def dispatch(ctx, :get_path, []) do
    reply(ctx, Enum.map(code_path(ctx), &String.to_charlist/1))
  end

  def dispatch(ctx, :which, [module]) do
    name = module_arg(ctx, module)

    value =
      cond do
        sticky?(ctx.manifest, name) -> :preloaded
        path = linked_module_path(ctx, name) -> String.to_charlist(path)
        path = resolve_path(ctx, name) -> String.to_charlist(path)
        true -> :non_existing
      end

    reply(ctx, value)
  end

  def dispatch(ctx, :is_loaded, [module]) do
    name = module_arg(ctx, module)
    bindings = ModuleLoader.binding_paths()

    value =
      cond do
        path = Map.get(bindings, name) -> {:file, String.to_charlist(path)}
        path = linked_module_path(ctx, name) -> {:file, String.to_charlist(path)}
        sticky?(ctx.manifest, name) -> {:file, :preloaded}
        true -> false
      end

    reply(ctx, value)
  end

  def dispatch(ctx, :ensure_loaded, [module]) do
    name = module_arg(ctx, module)

    value =
      cond do
        sticky?(ctx.manifest, name) ->
          {:module, module}

        linked_module?(ctx, name) ->
          {:module, module}

        true ->
          case ModuleLoader.ensure_loaded(ctx, name) do
            :ok -> {:module, module}
            {:error, :nofile} -> Hyperlang.Loader.registered_module(ctx, module)
            {:error, reason} -> {:error, reason}
          end
      end

    reply(ctx, value)
  end

  def dispatch(ctx, :all_available, []) do
    sticky =
      Enum.map(sticky_modules(ctx.manifest), fn name ->
        {String.to_charlist(name), :preloaded, true}
      end)

    # Manifest import modules, in resolution order between the sticky surface
    # and the code path (resolution tiers 2, 3 and 4). Imports
    # have no file on the path and no load step, so the path element is the
    # stable `~c"import"` marker — OTP types Path as charlist |
    # preloaded and reserves `preloaded` for the sticky surface, so a
    # documented charlist marker keeps the OTP shape without claiming a
    # namespace path (OTP leaves this unspecified; documented here) — and
    # loaded is always true.
    import_entries =
      Enum.map(Docs.import_modules(ctx.manifest), fn name ->
        {String.to_charlist(name), ~c"import", true}
      end)

    bindings = ModuleLoader.binding_paths()
    linked = linked_modules(ctx)

    linked_entries =
      Enum.map(linked, fn {name, meta} ->
        {String.to_charlist(name), String.to_charlist(module_path(meta)), true}
      end)

    path_entries =
      for dir <- code_path(ctx), name <- list_dir(ctx, dir) do
        file = join_path(dir, name)
        {String.to_charlist(name), String.to_charlist(file), Map.has_key?(bindings, name)}
      end

    catalog =
      (sticky ++ import_entries ++ linked_entries ++ path_entries)
      |> Enum.uniq_by(fn {name, _path, _loaded} -> name end)

    reply(ctx, catalog)
  end

  def dispatch(ctx, :get_doc, [module]) do
    name = module_arg(ctx, module)

    # Tier order mirrors the callable runtime surface: sticky surface
    # (facades, then enabled stdlib) before manifest imports. Runtime code path
    # docs are intentionally absent; linked graphs are already materialized and
    # no runtime source scan is allowed.
    result =
      cond do
        Docs.facade_module?(name) -> {:ok, Docs.facade_chunk(ctx.manifest, name)}
        enabled_stdlib?(ctx.manifest, name) -> Docs.stdlib_chunk(ctx.manifest, name)
        Docs.import_module?(ctx.manifest, name) -> {:ok, Docs.import_chunk(ctx.manifest, name)}
        true -> ModuleLoader.doc_chunk(ctx, name)
      end

    case result do
      {:ok, chunk} -> reply(ctx, {:ok, guestify_chunk(chunk, ctx)}, doc_chunk: true)
      {:error, :non_existing} -> reply(ctx, get_doc_non_existing(ctx, name))
      {:error, reason} -> reply(ctx, {:error, reason})
    end
  end

  def dispatch(ctx, operation, _args),
    do: ModuleLoader.module_error(ctx, {:unsupported_code_call, operation})

  defp get_doc_non_existing(ctx, name) do
    case nearest_name(name, Docs.import_modules(ctx.manifest)) do
      nil -> {:error, :non_existing}
      suggestion -> {:error, "unknown module '#{name}'; did you mean '#{suggestion}'?"}
    end
  end

  defp nearest_name(_name, []), do: nil

  defp nearest_name(name, candidates) do
    name = String.downcase(to_string(name))
    best = Enum.min_by(candidates, &edit_distance(name, String.downcase(&1)))
    threshold = max(2, div(String.length(name), 3))

    if edit_distance(name, String.downcase(best)) <= threshold, do: best
  end

  defp edit_distance(left, right) do
    target = String.graphemes(right)
    initial = Enum.to_list(0..length(target))

    left
    |> String.graphemes()
    |> Enum.with_index(1)
    |> Enum.reduce(initial, fn {left_char, row_number}, previous ->
      {_left, _diagonal, row} =
        target
        |> Enum.with_index(1)
        |> Enum.reduce({row_number, row_number - 1, [row_number]}, fn {right_char, column},
                                                                      {left_value, diagonal, row} ->
          above = Enum.at(previous, column)
          cost = if left_char == right_char, do: 0, else: 1
          value = min(left_value + 1, min(above + 1, diagonal + cost))
          {value, above, [value | row]}
        end)

      Enum.reverse(row)
    end)
    |> List.last()
  end

  ## Sticky surface ----------------------------------------------------------

  # The sticky surface in resolution order: the five facades, then every
  # stdlib module the manifest enables. The catalog answers "what can this
  # process call", so disabled stdlib modules are absent by design.
  def sticky_modules(manifest) do
    facades =
      Docs.facade_modules()
      |> Enum.reject(&optional_facade_disabled?(manifest, &1))

    facades ++ (enabled_stdlib_modules(manifest) -- Docs.facade_modules())
  end

  def sticky?(manifest, name),
    do: Docs.facade_module?(name) or enabled_stdlib?(manifest, name)

  defp optional_facade_disabled?(manifest, "sys"),
    do: not get_in(manifest, [:sys, :enabled])

  defp optional_facade_disabled?(manifest, "hyperlang_table"),
    do: not get_in(manifest, [:tables, :enabled])

  defp optional_facade_disabled?(_manifest, _name), do: false

  defp enabled_stdlib?(manifest, name), do: name in enabled_stdlib_modules(manifest)

  defp enabled_stdlib_modules(manifest) do
    known = known_stdlib_modules()

    Map.get(manifest, :stdlib, %{})
    |> Enum.filter(fn {_module, enabled} -> enabled == true end)
    |> Enum.map(fn {module, _enabled} -> to_string(module) end)
    |> Enum.filter(&MapSet.member?(known, &1))
    |> Enum.sort()
  end

  defp known_stdlib_modules do
    MapSet.new(
      Hyperlang.StdlibAllowlist.modules() ++
        Map.keys(Hyperlang.Stdlib.captured_matrix()) ++
        Map.keys(Hyperlang.Stdlib.wrapped_matrix())
    )
  end

  ## Resolution helpers ------------------------------------------------------

  defp code_path(ctx) do
    ctx.manifest
    |> Map.get(:modules, %{})
    |> Map.get(:path, [])
  end

  defp modules_enabled?(manifest),
    do: Map.get(manifest, :modules, %{}) |> Map.get(:enabled, false)

  defp loader_compat?(manifest) do
    filesystem = Map.get(manifest, :filesystem, %{})
    Map.get(filesystem, :enabled, false) and Map.get(filesystem, :loader_compat, false)
  end

  defp linked_modules(ctx) do
    case Map.get(ctx, :source_snapshot_modules, %{}) do
      modules when is_map(modules) -> modules
      _other -> %{}
    end
  end

  defp linked_module?(ctx, name), do: Map.has_key?(linked_modules(ctx), name)

  defp linked_module_path(ctx, name) do
    case Map.fetch(linked_modules(ctx), name) do
      {:ok, meta} -> module_path(meta)
      :error -> nil
    end
  end

  # Resolve through the same guest read path the loader uses, so discovery is
  # namespace-dependent on both own-VFS and host-backed filesystems.
  defp resolve_path(ctx, name) do
    Enum.find(Enum.map(code_path(ctx), &join_path(&1, name)), fn file ->
      try do
        match?(
          {:ok, source} when is_binary(source),
          Hyperlang.Runtime.filesystem(ctx, :read_file, [file])
        )
      rescue
        _error -> false
      end
    end)
  end

  defp list_dir(ctx, dir) do
    case Hyperlang.Runtime.filesystem(ctx, :list_dir, [dir]) do
      {:ok, names} when is_list(names) ->
        names
        |> Enum.map(&entry_name/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(&valid_code_path_module_name?/1)
        |> Enum.sort()

      _other ->
        []
    end
  rescue
    _error -> []
  end

  defp entry_name(name) when is_binary(name), do: name

  defp entry_name(name) when is_list(name) do
    List.to_string(name)
  rescue
    _error -> nil
  end

  defp entry_name(_name), do: nil

  defp join_path("/", name), do: "/" <> name
  defp join_path(dir, name), do: dir <> "/" <> name

  defp module_path(%{path: path}) when is_binary(path), do: path
  defp module_path(%{"path" => path}) when is_binary(path), do: path
  defp module_path(_meta), do: "linked"

  ## Argument and reply boundary ---------------------------------------------

  # The module argument arrives as a guest atom: a pooled atom translates to
  # its source name; an allowed atom crosses by name. Anything else is
  # Erlang's own `badarg`.
  defp module_arg(ctx, value) when is_atom(value) do
    name =
      cond do
        source = Hyperlang.Terms.atom_source(value, ctx) -> source
        MapSet.member?(ctx.terms.allowed_atoms, value) -> Atom.to_string(value)
        true -> :erlang.error(:badarg)
      end

    if valid_code_path_module_name?(name) do
      name
    else
      :erlang.error(:badarg)
    end
  end

  defp module_arg(_ctx, _value), do: :erlang.error(:badarg)

  defp valid_code_path_module_name?(name) when is_binary(name) do
    # The `code:` discovery surface (which/ensure_loaded/get_doc) must not be able
    # to resolve/load/doc a RESERVED internal name (hyperlang_atom_N / kernel_atom_N /
    # slot_N): those are Hyperlang's private namespace, never guest-loadable modules.
    Regex.match?(@code_path_module_name, name) and
      not Hyperlang.Manifest.reserved_internal_name?(name)
  end

  defp valid_code_path_module_name?(_name), do: false

  defp ctx_atom_pool(ctx), do: Map.get(ctx, :atom_pool, Map.get(ctx.terms, :atom_pool, %{}))

  # Function names inside docs chunks are stored as binaries (library and
  # facade tiers) or real OTP atoms (stdlib tier). Translate binary names
  # into the caller's pooled atoms when the caller names them — the same
  # rule pooled atoms follow at the module term boundary. Names the caller
  # never names stay binaries (or become binaries via the generic pass).
  defp guestify_chunk({:docs_v1, anno, lang, format, module_doc, meta, entries}, ctx) do
    lookup = atom_lookup(ctx)

    entries =
      Enum.map(entries, fn {{kind, name, arity}, entry_anno, signature, doc, entry_meta} ->
        {{kind, guestify_name(name, lookup), arity}, entry_anno, signature, doc, entry_meta}
      end)

    guestify_term({:docs_v1, anno, lang, format, module_doc, meta, entries}, ctx, lookup)
  end

  defp guestify_chunk(other, ctx), do: guestify_term(other, ctx, atom_lookup(ctx))

  defp guestify_name(name, lookup) when is_binary(name), do: Map.get(lookup, name, name)
  defp guestify_name(name, _lookup), do: name

  defp atom_lookup(ctx) do
    allowed = Map.new(ctx.terms.allowed_atoms, fn atom -> {Atom.to_string(atom), atom} end)
    pooled = Map.new(ctx_atom_pool(ctx), fn {pool, source} -> {source, pool} end)
    Map.merge(allowed, pooled)
  end

  # Generic pass for stray atoms (stdlib chunk function names, OTP doc terms):
  # allowed and caller-pooled atoms pass as themselves; an atom the caller
  # names translates into its pool atom; anything else degrades to its source
  # name as a binary — the unnamed-atom rule of the module term boundary.
  defp guestify_term(value, ctx, lookup) when is_atom(value) do
    cond do
      is_boolean(value) or is_nil(value) -> value
      MapSet.member?(ctx.terms.allowed_atoms, value) -> value
      Map.has_key?(ctx_atom_pool(ctx), value) -> value
      source = Hyperlang.Terms.atom_source(value, ctx) -> source
      true -> Map.get(lookup, Atom.to_string(value), Atom.to_string(value))
    end
  end

  defp guestify_term(value, ctx, lookup) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&guestify_term(&1, ctx, lookup))
    |> List.to_tuple()
  end

  defp guestify_term(value, ctx, lookup) when is_list(value) do
    if proper_list?(value),
      do: Enum.map(value, &guestify_term(&1, ctx, lookup)),
      else: value
  end

  defp guestify_term(value, ctx, lookup) when is_map(value) do
    Map.new(value, fn {key, item} ->
      {guestify_term(key, ctx, lookup), guestify_term(item, ctx, lookup)}
    end)
  end

  defp guestify_term(value, _ctx, _lookup), do: value

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_other), do: false

  defp reply(ctx, value, opts \\ []) do
    max_bytes =
      if Keyword.get(opts, :doc_chunk, false),
        do: Map.get(ctx.manifest, :modules, %{}) |> Map.get(:max_doc_chunk_bytes),
        else: nil

    case Hyperlang.Terms.sanitize_docs(value, ctx, max_bytes) do
      {:ok, safe} ->
        safe

      {:error, %{reason: :docs_bytes}} ->
        ModuleLoader.module_error(ctx, :doc_chunk_too_large)

      {:error, reason} ->
        ModuleLoader.module_error(ctx, {:boundary_error, reason})
    end
  end
end
