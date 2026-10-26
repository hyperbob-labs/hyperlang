defmodule Hyperlang.Manifest do
  @moduledoc false

  @file_export_id_prefix <<0, "hyperlang_file_export", 0>>
  @file_dependency_export_id_prefix <<0, "hyperlang_file_deps", 0>>
  @filesystem_validation_stamp :__hyperlang_filesystem_validated__
  @filesystem_validation_stamp_version 1

  @default_limits %{
    wall_ms: 500,
    heap_words: 1_000_000,
    max_reductions: 5_000_000,
    max_source_bytes: 50_000,
    max_line_count: 2_000,
    max_tokens: 10_000,
    max_forms: 1_000,
    max_ast_nodes: 20_000,
    max_compile_reductions: 200_000_000,
    max_compile_ms: 30_000,
    max_heap_words: nil,
    max_literal_bytes: 1_000_000,
    max_integer_digits: 4_096,
    max_atom_count: 1_000,
    max_nesting_depth: 256,
    max_functions: 256,
    max_clauses: 1_024,
    max_function_arity: 16,
    max_pattern_splits: 256,
    max_term_depth: 64,
    max_binary_bytes: 1_000_000,
    max_input_bytes: 1_000_000,
    max_output_bytes: 1_000_000,
    max_integer_bits: 4_096,
    max_tuple_size: 1_000,
    max_list_length: 10_000,
    max_map_size: 1_000,
    max_total_words: 2_000_000,
    max_stdout_bytes: 1_000_000,
    max_stdout_chunk_bytes: 64_000,
    max_stdout_chunks: 1_000,
    max_template_tags: 10_000,
    max_template_section_depth: 64,
    max_template_data_bytes: 1_000_000,
    max_template_data_words: 2_000_000,
    rate: nil,
    ceiling: nil,
    max_procs: nil
  }

  @base_terms %{
    allowed_atoms:
      MapSet.new([true, false, nil, :ok, :error, :DOWN, :EXIT, :process, :trap_exit, :undefined]),
    nil: nil,
    allow_tuples: true,
    allow_atoms: true,
    allow_improper_lists: false
  }

  @erlang_terms Map.merge(@base_terms, %{
                  public: :erlang,
                  atom_public: :atom,
                  tuple_public: :tuple,
                  binary_public: :binary,
                  improper_list_public: :reject
                })

  @json_terms Map.merge(@base_terms, %{
                public: :erlang,
                atom_public: :binary,
                tuple_public: :list,
                binary_public: :base64,
                improper_list_public: :reject
              })

  @default_terms %{@json_terms | public: :json}

  @default_stdlib %{
    base: true,
    array: true,
    base64: true,
    dict: true,
    filename: true,
    io: true,
    io_lib: true,
    json: true,
    orddict: true,
    proplists: true,
    rand: true,
    random: true,
    sofs: true,
    timer: true,
    uri_string: true,
    unicode_util: true,
    zlib: true,
    zstd: true,
    erlang: true,
    math: true,
    lists: true,
    maps: true,
    binary: true,
    unicode: true,
    string: true,
    calendar: true,
    re: true,
    sets: true,
    ordsets: true,
    gb_sets: true,
    gb_trees: true,
    graph: true,
    queue: true
  }

  @default_syntax %{
    inert_module_attributes: true,
    inert_export_attributes: true,
    records: false,
    macros: false
  }

  @default_capabilities %{
    nondeterminism: false,
    # OTP gen_server guest port. Default OFF. Enabling it only injects the
    # guest gen_server/gen/proc_lib/sys modules into multi-file source
    # snapshots with modules.enabled=true; a single-source-binary program
    # still rejects gen_server calls because no guest-lib injection happens.
    gen_server: false
  }

  @default_sys %{
    enabled: false,
    channel_element_types: %{}
  }

  @default_modules %{
    enabled: false,
    callback_dispatch: false,
    path: ["/sys/lib"],
    guest_modules: [],
    max_modules: 32,
    max_depth: 8,
    max_doc_chunk_bytes: 262_144
  }

  @default_profile %{name: nil}
  @userland_profiles [
    :filter_command,
    :filesystem_command,
    :namespace_command,
    :shell_opaque_user_process,
    :file_server,
    :device_host
  ]
  @guest_selectable_userland_profiles [
    :filter_command,
    :filesystem_command,
    :namespace_command,
    :file_server
  ]

  @default_filesystem_limits %{
    max_mounts: 64,
    max_path_bytes: 4096,
    max_component_bytes: 255,
    max_read_bytes: 1_000_000,
    max_single_write_bytes: 1_000_000,
    max_write_bytes: 10_000_000,
    max_total_memory_bytes: 10_000_000,
    max_dir_entries: 10_000,
    max_dir_result_bytes: 1_000_000,
    max_total_path_bytes: 1_000_000,
    max_file_count: 100_000,
    max_tombstones: 100_000,
    max_overlay_entries: 100_000,
    max_stat_result_bytes: 64_000,
    max_error_bytes: 8_192,
    max_source_file_bytes: 200_000,
    max_source_count: 256,
    max_loaded_modules: 256,
    max_compiles_per_eval: 16,
    max_wildcard_matches: 10_000,
    max_wildcard_depth: 64
  }

  @default_filesystem %{
    enabled: false,
    backend: :own,
    cwd: "/",
    allow_relative_paths: false,
    file_compat: false,
    filelib_compat: false,
    handle_compat: false,
    loader_compat: false,
    source_compile: false,
    commit_policy: :per_request,
    limits: @default_filesystem_limits,
    mounts: [],
    atom_vocabularies: %{filesystem: false, re: false, loader: false, archive: false}
  }

  @default_table_limits %{
    max_tables: 32,
    max_objects_per_table: 50_000,
    max_memory_bytes_per_table: 8 * 1024 * 1024
  }

  @default_tables %{
    enabled: false,
    limits: @default_table_limits
  }

  @default_exports %{functions: %{}, files: []}
  @export_input_profiles [
    :safe_term,
    :fileserver_read,
    :fileserver_write,
    :fileserver_list,
    :fileserver_stat
  ]
  @export_output_profiles [:safe_term, :bytes, :status, :list, :stat]
  @fileserver_contracts %{
    read: %{input: :fileserver_read, output: :bytes, effects: []},
    write: %{input: :fileserver_write, output: :status, effects: [:bump]},
    list: %{input: :fileserver_list, output: :list, effects: []},
    stat: %{input: :fileserver_stat, output: :stat, effects: []}
  }
  @fileserver_effects [:bump]

  @filesystem_atom_vocab MapSet.new([
                           :ok,
                           :error,
                           :enoent,
                           :eacces,
                           :eisdir,
                           :enotdir,
                           :eexist,
                           :exdev,
                           :eperm,
                           :erofs,
                           :enotempty,
                           :einval,
                           :enospc,
                           :enametoolong,
                           :eoverflow,
                           :enotsup,
                           :ebadf,
                           :ewouldblock,
                           :invalid_path,
                           :badarg,
                           :file,
                           :file_info,
                           :regular,
                           :directory,
                           :symlink,
                           :read,
                           :raw,
                           :binary,
                           :write,
                           :read_write,
                           :none,
                           :append,
                           :exclusive,
                           :delayed_write,
                           :sync,
                           :read_ahead,
                           :eof
                         ])

  @re_atom_vocab MapSet.new([
                   # The wrapped re:compile proxy returns {re_pattern, ...}
                   # terms (pure tuples) that round-trip back into run/
                   # replace/split.
                   :re_pattern,
                   :global,
                   :return,
                   :binary,
                   :list,
                   :index,
                   :capture,
                   :all,
                   :first,
                   :all_names,
                   :all_but_first,
                   :unicode,
                   :anchored,
                   :caseless,
                   :dotall,
                   :multiline,
                   :ungreedy,
                   :extended,
                   :notempty,
                   :notbol,
                   :noteol,
                   :newline,
                   :cr,
                   :lf,
                   :crlf,
                   :anycrlf,
                   :bsr_anycrlf,
                   :bsr_unicode,
                   :dollar_endonly,
                   :dupnames,
                   :ucp,
                   :offset
                 ])

  @loader_atom_vocab MapSet.new([
                       :ok,
                       :error,
                       :module,
                       :nofile,
                       :binary,
                       :return,
                       :report_errors,
                       :report_warnings,
                       :deterministic,
                       :no_docs,
                       :no_auto_import,
                       :from_core,
                       :native
                     ])

  @process_atom_vocab MapSet.new([:DOWN, :EXIT, :process, :trap_exit, :undefined])

  # The `code:` discovery surface return vocabulary:
  # OTP-shaped replies cross the boundary as themselves when
  # modules are enabled, so guests can pattern-match `preloaded`,
  # `{error, nofile}`, `{ok, {docs_v1, ...}}`, and friends by name.
  @modules_atom_vocab MapSet.new([
                        :ok,
                        :error,
                        :module,
                        :file,
                        :preloaded,
                        :non_existing,
                        :nofile,
                        :badfile,
                        :eacces,
                        :missing,
                        :none,
                        :hidden,
                        :docs_v1,
                        :erlang,
                        :function,
                        :badarg
                      ])

  @stdlib_option_atom_vocab MapSet.new([
                              :all,
                              :append,
                              :array,
                              :binary,
                              :bytes,
                              :calendar,
                              :compile,
                              :error,
                              :empty,
                              :first,
                              :global,
                              :graph,
                              :hex,
                              :index,
                              :infinity,
                              :latin1,
                              :leading,
                              :list,
                              :local,
                              :match,
                              :microsecond,
                              :millisecond,
                              :module,
                              :monotonic,
                              :nanosecond,
                              :native,
                              nil,
                              :none,
                              :nomatch,
                              :ok,
                              :pad,
                              :return,
                              :scope,
                              :second,
                              :perf_counter,
                              :trim,
                              :trailing,
                              :unicode,
                              :unit,
                              :universal,
                              :undefined,
                              :utf8,
                              :value
                            ])

  # The hyperbob_os archive / served-fs ADT vocabulary (capability atom
  # vocabularies). The vac/venti archive libraries and the
  # styx/styxservers file-server framework thread atom-keyed ADT maps
  # (File/Page/Sink/Direntry/Entry/Root/Qid/Dir/Sv) and tagged tuples
  # ({score, _}, {root, _}, vmsg_*) OUT to a serving command and BACK IN through
  # an intermediary module that holds them opaquely. Without a shared vocabulary
  # those keys/tags would be per-module pooled and demoted to source-name
  # binaries at the boundary (an opaque round-trip cannot translate a pooled atom
  # the holder never names), breaking the next `maps:get/2` or tuple match.
  #
  # This is a CURATED, FINITE, build-time set — exactly like the filesystem/re/
  # loader vocabularies. Pooling still bounds every other (unbounded, guest-
  # authored) atom; only this fixed application-ADT set crosses by identity. It
  # is gated by `filesystem.atom_vocabularies.archive` and is OFF by default; the
  # library derivation manifest turns it on so a resolved vac/venti/styxservers
  # library compiles its ADT keys as themselves, not pool slots.
  @archive_atom_vocab MapSet.new([
                        # vac File / Page / Sink / MSink / Source internal keys
                        :p,
                        :d,
                        :o,
                        :s,
                        :e,
                        :f,
                        :i,
                        :l,
                        :ms,
                        :me,
                        :nd,
                        :nde,
                        :ne,
                        :dtype,
                        :dsize,
                        :psize,
                        :size,
                        :free,
                        :maxindex,
                        :nindex,
                        :depth,
                        String.to_atom("ses" <> "sion"),
                        # venti / vac Entry + Root + Score ADT keys
                        :version,
                        :name,
                        :rtype,
                        :score,
                        :blocksize,
                        :prev,
                        :nprev,
                        :flags,
                        :gen,
                        :fd,
                        # Direntry / metadata ADT keys
                        :elem,
                        :entry,
                        :mentry,
                        :mgen,
                        :qid,
                        :uid,
                        :gid,
                        :mid,
                        :muid,
                        :mtime,
                        :mcount,
                        :ctime,
                        :atime,
                        :mode,
                        :emode,
                        :qidspace,
                        :qidoff,
                        :qidmax,
                        # vacfs / served-fs Elem + tree keys + value atoms
                        :de,
                        :vd,
                        :vf,
                        :pqid,
                        :offset,
                        :kind,
                        :dir,
                        :file,
                        :length,
                        :path,
                        :vers,
                        :qtype,
                        :dev,
                        :compress,
                        :pathgen,
                        :dfd,
                        :children,
                        :parent,
                        # archfs / tarfs served-fs Dir-tree node keys
                        :child,
                        :sibling,
                        :dir,
                        :hdr,
                        :nexthdr,
                        :canseek,
                        :modestr,
                        # styx / styxservers Qid / Dir / Sv / Fid framework keys
                        :aname,
                        :c,
                        :doffset,
                        :fids,
                        :id,
                        :isopen,
                        :mod,
                        :msize,
                        :parked,
                        :reply,
                        :uname,
                        :is_stream,
                        # archive container tuple tags
                        :root,
                        :too_small,
                        :vacstore,
                        :vmsg_thello,
                        :vmsg_rhello,
                        :vmsg_tping,
                        :vmsg_rping,
                        :vmsg_tread,
                        :vmsg_rread,
                        :vmsg_twrite,
                        :vmsg_rwrite,
                        :vmsg_tsync,
                        :vmsg_rsync,
                        :vmsg_tgoodbye,
                        :vmsg_rerror
                      ])

  def defaults do
    %{
      result: %{name: "result", arity: 1},
      bindings: %{},
      stdlib: @default_stdlib,
      limits: @default_limits,
      terms: @default_terms,
      syntax: @default_syntax,
      capabilities: @default_capabilities,
      profile: @default_profile,
      code_pool: %{size: default_code_pool_size(), lifecycle: :reference_counted},
      sys: @default_sys,
      modules: @default_modules,
      filesystem: @default_filesystem,
      tables: @default_tables,
      exports: @default_exports
    }
  end

  def reserved_internal_name?(value) when is_atom(value),
    do: value |> Atom.to_string() |> reserved_internal_atom_name?()

  def reserved_internal_name?(value) when is_binary(value),
    do: reserved_internal_atom_name?(value)

  def reserved_internal_name?(_value), do: false

  def file_export_id(%{path: path, op: op}) when is_binary(path) and is_atom(op) do
    file_export_id(path, op)
  end

  def file_export_id(path, op) when is_binary(path) and is_atom(op) do
    @file_export_id_prefix <> Atom.to_string(op) <> <<0>> <> path
  end

  def file_dependency_export_id(%{path: path, deps: %{type: :dynamic}})
      when is_binary(path) do
    @file_dependency_export_id_prefix <> path
  end

  def dynamic_file_deps?(%{deps: %{type: :dynamic}}), do: true
  def dynamic_file_deps?(_file), do: false

  def file_dependency_export(%{deps: %{type: :dynamic, function: function, arity: arity}} = file) do
    {:ok, file_dependency_export_id(file), %{function: function, arity: arity}}
  end

  def file_dependency_export(_file), do: :none

  def normalize(manifest) when is_map(manifest) do
    with {:ok, manifest} <-
           normalize_known_key_map(
             manifest,
             [
               :entry,
               :result,
               :exports,
               :bindings,
               :limits,
               :terms,
               :stdlib,
               :syntax,
               :capabilities,
               :profile,
               :code_pool,
               :sys,
               :modules,
               :filesystem,
               :tables,
               :atom_universe
             ],
             "manifest"
           ),
         {:ok, manifest} <- apply_entry_alias(manifest),
         {:ok, result} <- normalize_result(get(manifest, :result, %{})),
         {:ok, exports} <- normalize_exports(get(manifest, :exports, %{})),
         {:ok, bindings} <- normalize_bindings(get(manifest, :bindings, %{})),
         {:ok, limits} <- normalize_limits(get(manifest, :limits, %{})),
         {:ok, terms0} <- normalize_terms(get(manifest, :terms, %{})),
         {:ok, stdlib} <- normalize_stdlib(get(manifest, :stdlib, %{})),
         {:ok, syntax} <- normalize_syntax(get(manifest, :syntax, %{})),
         {:ok, capabilities} <- normalize_capabilities(get(manifest, :capabilities, %{})),
         {:ok, profile} <- normalize_userland_profile(get(manifest, :profile, %{})),
         :ok <- validate_nondeterministic_bindings(bindings, capabilities),
         {:ok, code_pool} <- normalize_code_pool(get(manifest, :code_pool, %{})),
         {:ok, sys} <- normalize_sys(get(manifest, :sys, %{})),
         {:ok, modules} <- normalize_modules(get(manifest, :modules, %{})),
         {:ok, filesystem} <- normalize_filesystem(get(manifest, :filesystem, %{})),
         {:ok, tables} <- normalize_tables(get(manifest, :tables, %{})),
         {:ok, atom_universe} <- normalize_atom_universe(get(manifest, :atom_universe, nil)) do
      terms = merge_capability_atom_vocabularies(terms0, stdlib, filesystem, modules)

      {:ok,
       %{
         atom_universe: atom_universe,
         result: result,
         bindings: bindings,
         stdlib: stdlib,
         limits: limits,
         terms: terms,
         syntax: syntax,
         capabilities: capabilities,
         profile: profile,
         code_pool: code_pool,
         sys: sys,
         modules: modules,
         filesystem: filesystem,
         tables: tables,
         exports: exports,
         result_explicit?: explicit_key?(manifest, :result)
       }}
    end
  end

  def normalize(_), do: {:error, Hyperlang.Error.new(:manifest, "manifest must be a map")}

  def with_atom_universe(manifest, atom_universe) when is_map(manifest) do
    %{manifest | atom_universe: atom_universe}
  end

  def public_manifest(manifest) do
    manifest
    |> Map.drop([:result_explicit?])
    |> strip_manifest_filesystem_validation_stamp()
    |> update_in([:terms, :allowed_atoms], &Enum.sort/1)
  end

  def public_filesystem(filesystem) when is_map(filesystem) do
    Map.update(filesystem, :mounts, [], fn mounts ->
      Enum.map(mounts, &public_filesystem_mount/1)
    end)
    |> strip_filesystem_validation_stamp()
  end

  def public_filesystem(_filesystem), do: %{}

  defp public_filesystem_mount(%{} = mount) do
    Map.update(mount, :backend, nil, fn
      {:host, _path} -> :host
      backend -> backend
    end)
  end

  defp strip_filesystem_validation_stamp(%{} = filesystem),
    do: Map.delete(filesystem, @filesystem_validation_stamp)

  defp strip_filesystem_validation_stamp(filesystem), do: filesystem

  defp strip_manifest_filesystem_validation_stamp(%{} = manifest) do
    case Map.fetch(manifest, :filesystem) do
      {:ok, filesystem} ->
        Map.put(manifest, :filesystem, strip_filesystem_validation_stamp(filesystem))

      :error ->
        manifest
    end
  end

  def validate_filesystem(%{filesystem: filesystem}), do: validate_filesystem(filesystem)

  def validate_filesystem(%{mounts: mounts} = filesystem) when is_list(mounts) do
    case validate_stamped_filesystem(filesystem) do
      :ok -> :ok
      :fallback -> validate_filesystem_mounts(mounts)
      {:error, error} -> {:error, error}
    end
  end

  def validate_filesystem(_filesystem), do: :ok

  defp validate_filesystem_mounts(mounts) when is_list(mounts) do
    Enum.reduce_while(mounts, :ok, fn
      %{backend: {:host, path}}, :ok ->
        case canonical_host_path(path, 0) do
          {:ok, ^path} ->
            {:cont, :ok}

          {:ok, _changed_path} ->
            {:halt,
             {:error,
              Hyperlang.Error.new(
                :manifest,
                "host filesystem mount path changed after canonicalization"
              )}}

          {:error, error} ->
            {:halt, {:error, error}}
        end

      _mount, :ok ->
        {:cont, :ok}
    end)
  end

  defp validate_stamped_filesystem(
         %{
           @filesystem_validation_stamp => {@filesystem_validation_stamp_version, expected}
         } = filesystem
       )
       when is_list(expected) do
    with {:ok, actual} <- host_mount_identities(filesystem) do
      if actual == expected do
        :ok
      else
        {:error, host_mount_changed_error()}
      end
    end
  end

  defp validate_stamped_filesystem(%{}), do: :fallback

  defp stamp_validated_filesystem(%{} = filesystem) do
    with {:ok, identities} <- host_mount_identities(filesystem) do
      {:ok,
       Map.put(
         filesystem,
         @filesystem_validation_stamp,
         {@filesystem_validation_stamp_version, identities}
       )}
    end
  end

  defp host_mount_identities(%{mounts: mounts}) when is_list(mounts) do
    Enum.reduce_while(mounts, {:ok, []}, fn
      %{backend: {:host, path}}, {:ok, acc} ->
        case host_mount_identity(path) do
          {:ok, identity} -> {:cont, {:ok, [identity | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end

      _mount, {:ok, acc} ->
        {:cont, {:ok, acc}}
    end)
    |> case do
      {:ok, identities} -> {:ok, Enum.reverse(identities)}
      {:error, error} -> {:error, error}
    end
  end

  defp host_mount_identities(_filesystem), do: {:ok, []}

  defp host_mount_identity(path) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        {:ok, {path, stat.major_device, stat.inode}}

      {:ok, _stat} ->
        {:error, host_mount_changed_error()}

      {:error, _reason} ->
        {:error,
         Hyperlang.Error.new(
           :manifest,
           "host filesystem mount path must be an existing directory"
         )}
    end
  end

  defp host_mount_identity(_path) do
    {:error, Hyperlang.Error.new(:manifest, "host filesystem mount path must be a string")}
  end

  defp host_mount_changed_error do
    Hyperlang.Error.new(:manifest, "host filesystem mount path changed after canonicalization")
  end

  def merge_limits(%{limits: defaults}, options) do
    case get_option(options, :limits, :__hyperlang_no_limit_overrides__) do
      :__hyperlang_no_limit_overrides__ ->
        {:ok, defaults}

      limits when is_map(limits) and map_size(limits) == 0 ->
        {:ok, defaults}

      limits ->
        limits = Map.merge(defaults, limits, fn _, _, v -> v end)
        normalize_limits(limits)
    end
  end

  def merge_terms(%{terms: defaults}, options) do
    case get_option(options, :terms, :__hyperlang_no_term_overrides__) do
      :__hyperlang_no_term_overrides__ ->
        {:ok, defaults}

      terms when is_map(terms) and map_size(terms) == 0 ->
        {:ok, defaults}

      terms ->
        merge_term_overrides(defaults, terms)
    end
  end

  defp merge_term_overrides(defaults, terms) do
    with {:ok, overrides} <-
           normalize_known_key_map(terms, Map.keys(@default_terms), "term policy") do
      terms =
        if Map.has_key?(overrides, :public) do
          defaults
          |> Map.drop([
            :public,
            :atom_public,
            :tuple_public,
            :binary_public,
            :improper_list_public
          ])
          |> Map.merge(overrides, fn _, _, v -> v end)
        else
          Map.merge(defaults, overrides, fn _, _, v -> v end)
        end

      with {:ok, merged} <- normalize_terms(terms),
           :ok <- narrow_allowed_atoms(defaults, merged) do
        {:ok, merged}
      end
    end
  end

  # The program's `terms.allowed_atoms` is the atom universe a run may use.
  # A run policy may narrow it (`policy.atoms`) but never widen it.
  defp narrow_allowed_atoms(%{allowed_atoms: program}, %{allowed_atoms: run}) do
    case run |> MapSet.difference(program) |> MapSet.to_list() do
      [] ->
        :ok

      extra ->
        {:error,
         Hyperlang.Error.new(:manifest, "run policy atoms must narrow the program allowed_atoms",
           details: %{atoms: Enum.sort(extra)}
         )}
    end
  end

  def capability_atom_vocabularies do
    %{
      filesystem: @filesystem_atom_vocab,
      re: @re_atom_vocab,
      loader: @loader_atom_vocab,
      stdlib_options: @stdlib_option_atom_vocab,
      modules: @modules_atom_vocab,
      archive: @archive_atom_vocab
    }
  end

  # Resolve the run spec's `bindings` against the program's pinned binding
  # set. The supplied map must name exactly the declared bindings, each as
  # `{module, state}` with the module the program was compiled against. The
  # MFA set itself never comes from the run: it was fixed by `normalize/1`.
  def bind_bindings(%{bindings: declared}, supplied) when is_map(supplied) do
    declared_names = declared |> Map.keys() |> Enum.sort()
    supplied_names = supplied |> Map.keys() |> Enum.sort()
    missing = declared_names -- supplied_names
    undeclared = supplied_names -- declared_names

    mismatched =
      Enum.reject(declared_names -- missing, fn name ->
        case Map.fetch!(supplied, name) do
          {module, _state} -> module == declared[name].module and binding_module?(module)
          _other -> false
        end
      end)

    cond do
      missing != [] ->
        {:error,
         [
           Hyperlang.Error.new(:manifest, "missing binding implementations",
             details: %{bindings: missing}
           )
         ]}

      undeclared != [] ->
        {:error,
         [
           Hyperlang.Error.new(:manifest, "run supplies bindings the program does not declare",
             details: %{bindings: undeclared}
           )
         ]}

      mismatched != [] ->
        {:error,
         [
           Hyperlang.Error.new(
             :manifest,
             "binding implementations must be {module, state} with the declared module",
             details: %{bindings: mismatched}
           )
         ]}

      true ->
        {:ok, supplied}
    end
  end

  def bind_bindings(_manifest, _supplied),
    do: {:error, [Hyperlang.Error.new(:api, "spec bindings must be a map")]}

  def binding_for_call(manifest, {module, function, arity}),
    do: binding_for_call(manifest, module, function, arity)

  def binding_for_call(%{bindings: bindings}, module, function, arity) do
    case Map.fetch(bindings, to_string(module)) do
      {:ok, %{exports: exports}} -> Map.get(exports, {to_string(function), arity})
      :error -> nil
    end
  end

  def binding_for_call(_manifest, _module, _function, _arity), do: nil

  def stdlib_enabled?(%{stdlib: stdlib}, module) do
    Map.get(stdlib, module, false) || Map.get(stdlib, to_string(module), false)
  end

  def nondeterminism_enabled?(%{capabilities: %{nondeterminism: enabled}}),
    do: truthy?(enabled)

  def nondeterminism_enabled?(_manifest), do: false

  def gen_server_enabled?(%{capabilities: %{gen_server: enabled}}),
    do: truthy?(enabled)

  def gen_server_enabled?(_manifest), do: false

  defp merge_capability_atom_vocabularies(terms, stdlib, filesystem, modules) do
    vocab =
      @process_atom_vocab
      |> maybe_union(filesystem_enabled?(filesystem), @filesystem_atom_vocab)
      |> maybe_union(loader_atoms_enabled?(filesystem), @loader_atom_vocab)
      |> maybe_union(re_atoms_enabled?(stdlib, filesystem), @re_atom_vocab)
      |> maybe_union(stdlib_atoms_enabled?(stdlib), @stdlib_option_atom_vocab)
      |> maybe_union(modules_atoms_enabled?(modules), @modules_atom_vocab)
      |> maybe_union(archive_atoms_enabled?(filesystem), @archive_atom_vocab)

    update_in(terms.allowed_atoms, &MapSet.union(&1, vocab))
  end

  defp archive_atoms_enabled?(%{atom_vocabularies: vocab}),
    do: truthy?(Map.get(vocab, :archive, false))

  defp archive_atoms_enabled?(_filesystem), do: false

  defp modules_atoms_enabled?(%{enabled: enabled}), do: truthy?(enabled)
  defp modules_atoms_enabled?(_modules), do: false

  defp filesystem_enabled?(%{enabled: enabled}), do: truthy?(enabled)
  defp filesystem_enabled?(_filesystem), do: false

  defp loader_atoms_enabled?(%{atom_vocabularies: vocab} = filesystem) do
    truthy?(Map.get(vocab, :loader, false)) or truthy?(Map.get(filesystem, :loader_compat, false)) or
      truthy?(Map.get(filesystem, :source_compile, false))
  end

  defp loader_atoms_enabled?(_filesystem), do: false

  defp re_atoms_enabled?(stdlib, %{atom_vocabularies: vocab}) do
    truthy?(Map.get(vocab, :re, false)) or truthy?(Map.get(stdlib, :re, false))
  end

  defp re_atoms_enabled?(stdlib, _filesystem), do: truthy?(Map.get(stdlib, :re, false))

  defp stdlib_atoms_enabled?(stdlib) when is_map(stdlib),
    do: Enum.any?(stdlib, &match?({_k, true}, &1))

  defp stdlib_atoms_enabled?(_stdlib), do: false

  defp maybe_union(set, true, vocab), do: MapSet.union(set, vocab)
  defp maybe_union(set, _enabled, _vocab), do: set

  defp normalize_result(raw_result) do
    name = raw_result |> get(:name, get(raw_result, :function, "result")) |> to_string()
    arity = raw_result |> get(:arity, 1) |> to_int()

    cond do
      reserved_internal_name?(name) ->
        {:error,
         Hyperlang.Error.new(:manifest, "result root uses reserved Hyperlang internal name")}

      # arity 1: the classic single-input result root.
      # arity 2: Inferno-style command entry `init(Ctxt, Argv)`. The harness
      # supplies `Ctxt = nil` (console) and threads the eval input in as `Argv`,
      # so the host still drives the guest with one sanitized input term.
      arity in [1, 2] ->
        result = %{
          name: name,
          arity: arity,
          input: get(raw_result, :input, %{}),
          output: get(raw_result, :output, %{})
        }

        result =
          case get(raw_result, :span, nil) do
            nil -> result
            span -> Map.put(result, :span, span)
          end

        {:ok, result}

      true ->
        {:error, Hyperlang.Error.new(:manifest, "result root must have arity 1 or 2")}
    end
  end

  defp normalize_exports(value) when value in [nil, %{}], do: {:ok, @default_exports}

  defp normalize_exports(value) when is_map(value) do
    with {:ok, raw} <-
           normalize_known_key_map(value, [:functions, :fileserver], "exports"),
         {:ok, functions} <- normalize_export_functions(get(raw, :functions, %{})),
         {:ok, files} <- normalize_export_fileserver(get(raw, :fileserver, %{}), functions) do
      {:ok, %{functions: functions, files: files}}
    end
  end

  defp normalize_exports(_value),
    do: {:error, Hyperlang.Error.new(:manifest, "exports must be a map")}

  defp normalize_export_functions(value) when value in [nil, %{}], do: {:ok, %{}}

  defp normalize_export_functions(functions) when is_map(functions) do
    functions
    |> Enum.reduce_while({:ok, %{}, MapSet.new(), MapSet.new()}, fn {id, spec},
                                                                    {:ok, acc, seen_ids,
                                                                     seen_calls} ->
      with {:ok, id} <- normalize_export_id(id),
           :ok <- reject_duplicate_export_id(id, seen_ids),
           {:ok, normalized} <- normalize_export_function_spec(id, spec),
           :ok <- reject_duplicate_export_call(normalized, seen_calls) do
        {:cont,
         {:ok, Map.put(acc, id, normalized), MapSet.put(seen_ids, id),
          MapSet.put(seen_calls, {normalized.function, normalized.arity})}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized, _seen_ids, _seen_calls} -> {:ok, normalized}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_export_functions(_functions),
    do: {:error, Hyperlang.Error.new(:manifest, "exports.functions must be a map")}

  defp normalize_export_function_spec(id, spec) when is_map(spec) do
    with {:ok, raw} <-
           normalize_known_key_map(
             spec,
             [:function, :arity, :input, :output],
             "exports.functions entry"
           ),
         {:ok, function} <- normalize_export_function_name(get(raw, :function, id)),
         {:ok, arity} <- normalize_export_arity(get(raw, :arity, nil)),
         {:ok, input} <-
           normalize_export_profile(get(raw, :input, %{}), "input", @export_input_profiles),
         {:ok, output} <-
           normalize_export_profile(get(raw, :output, %{}), "output", @export_output_profiles) do
      {:ok, %{id: id, function: function, arity: arity, input: input, output: output}}
    end
  end

  defp normalize_export_function_spec(_id, _spec),
    do: {:error, Hyperlang.Error.new(:manifest, "exports.functions entries must be maps")}

  defp normalize_export_fileserver(value, _functions) when value in [nil, %{}], do: {:ok, []}

  defp normalize_export_fileserver(value, functions) when is_map(value) do
    with {:ok, raw} <- normalize_known_key_map(value, [:root, :files], "exports.fileserver"),
         {:ok, root} <-
           normalize_virtual_path(
             get(raw, :root, @default_filesystem.cwd),
             @default_filesystem_limits
           ),
         :ok <- require_fileserver_root(root),
         {:ok, files} <- normalize_fileserver_files(get(raw, :files, []), functions) do
      {:ok, files}
    end
  end

  defp normalize_export_fileserver(_value, _functions),
    do: {:error, Hyperlang.Error.new(:manifest, "exports.fileserver must be a map")}

  defp require_fileserver_root("/"), do: :ok

  defp require_fileserver_root(_root),
    do: {:error, Hyperlang.Error.new(:manifest, "exports.fileserver root must be /")}

  defp normalize_fileserver_files(value, _functions) when value in [nil, []], do: {:ok, []}

  defp normalize_fileserver_files(files, functions) when is_list(files) do
    files
    |> Enum.reduce_while({:ok, [], MapSet.new(), MapSet.new()}, fn spec,
                                                                   {:ok, acc, seen_ops,
                                                                    seen_paths} ->
      with {:ok, normalized} <- normalize_fileserver_file(spec, functions),
           :ok <- reject_duplicate_fileserver_node(normalized, seen_paths),
           :ok <- reject_duplicate_fileserver_ops(normalized, seen_ops) do
        seen_ops =
          Enum.reduce(normalized, seen_ops, fn file, seen_ops ->
            MapSet.put(seen_ops, {file.path, file.op})
          end)

        seen_paths =
          Enum.reduce(normalized, seen_paths, fn file, seen_paths ->
            MapSet.put(seen_paths, file.path)
          end)

        {:cont, {:ok, Enum.reverse(normalized) ++ acc, seen_ops, seen_paths}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized, _seen_ops, _seen_paths} ->
        normalized = Enum.reverse(normalized)

        with :ok <- reject_overlapping_fileserver_paths(normalized) do
          {:ok, normalized}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp normalize_fileserver_files(_files, _functions),
    do: {:error, Hyperlang.Error.new(:manifest, "exports.fileserver.files must be a list")}

  defp normalize_fileserver_file(spec, functions) when is_map(spec) do
    with {:ok, raw} <-
           normalize_known_key_map(
             spec,
             [
               :path,
               :type,
               :rights,
               :read,
               :write,
               :list,
               :stat,
               :callbacks,
               :metadata,
               :content_type,
               :reactive,
               :reactive_policy,
               :deps,
               :effects
             ],
             "exports.fileserver.files entry"
           ),
         path when is_binary(path) <- get(raw, :path, nil),
         {:ok, path} <- normalize_virtual_path(path, @default_filesystem_limits),
         {:ok, type} <- normalize_fileserver_type(get(raw, :type, nil), raw),
         :ok <- reject_invalid_fileserver_path(path, type),
         {:ok, rights} <- normalize_export_file_rights(get(raw, :rights, [])),
         {:ok, metadata} <- normalize_fileserver_metadata(raw),
         {:ok, reactive_policy} <-
           normalize_fileserver_reactive_policy(
             get(raw, :reactive_policy, get(raw, :reactive, nil))
           ),
         {:ok, deps} <- normalize_export_file_deps(get(raw, :deps, [])),
         {:ok, callbacks} <- normalize_fileserver_callbacks(raw, type, functions),
         {:ok, effects} <- normalize_fileserver_effects(get(raw, :effects, nil)),
         :ok <- reject_unusable_fileserver_effects(callbacks, effects),
         :ok <- require_fileserver_callbacks(path, type, callbacks) do
      normalize_fileserver_callback_contracts(%{
        callbacks: callbacks,
        deps: deps,
        effects: effects,
        metadata: metadata,
        path: path,
        reactive_policy: reactive_policy,
        rights: rights,
        type: type
      })
    else
      nil -> {:error, Hyperlang.Error.new(:manifest, "exports.fileserver.files path is required")}
      other -> other
    end
  end

  defp normalize_fileserver_file(_spec, _functions),
    do: {:error, Hyperlang.Error.new(:manifest, "exports.fileserver.files entries must be maps")}

  defp reject_invalid_fileserver_path("/", :file),
    do: {:error, Hyperlang.Error.new(:manifest, "exports.fileserver file path cannot be /")}

  defp reject_invalid_fileserver_path(_path, _type), do: :ok

  defp reject_duplicate_fileserver_node([], _seen), do: :ok

  defp reject_duplicate_fileserver_node([%{path: path} | _rest], seen) do
    if MapSet.member?(seen, path) do
      {:error,
       Hyperlang.Error.new(:manifest, "duplicate exports.fileserver.files node",
         details: %{path: path}
       )}
    else
      :ok
    end
  end

  defp reject_duplicate_fileserver_ops(files, seen) do
    files
    |> Enum.find(fn file -> MapSet.member?(seen, {file.path, file.op}) end)
    |> case do
      nil ->
        :ok

      file ->
        {:error,
         Hyperlang.Error.new(:manifest, "duplicate exports.fileserver.files callback",
           details: %{path: file.path, op: file.op}
         )}
    end
  end

  defp reject_overlapping_fileserver_paths(files) do
    nodes =
      files
      |> Enum.group_by(& &1.path)
      |> Enum.map(fn {path, entries} ->
        types = entries |> Enum.map(& &1.type) |> Enum.uniq()
        %{path: path, types: types}
      end)

    with :ok <- reject_conflicting_fileserver_node_types(nodes) do
      reject_fileserver_file_ancestors(nodes)
    end
  end

  defp reject_conflicting_fileserver_node_types(nodes) do
    nodes
    |> Enum.find(fn %{types: types} -> length(types) > 1 end)
    |> case do
      nil ->
        :ok

      %{path: path} ->
        {:error,
         Hyperlang.Error.new(:manifest, "overlapping exports.fileserver.files node",
           details: %{path: path}
         )}
    end
  end

  defp reject_fileserver_file_ancestors(nodes) do
    paths = MapSet.new(Enum.map(nodes, & &1.path))

    nodes
    |> Enum.find(fn
      %{path: "/", types: [:file]} ->
        true

      %{path: file_path, types: [:file]} ->
        paths
        |> Enum.any?(fn path ->
          path != file_path and String.starts_with?(path, file_path <> "/")
        end)

      _node ->
        false
    end)
    |> case do
      nil ->
        :ok

      %{path: path} ->
        {:error,
         Hyperlang.Error.new(:manifest, "overlapping exports.fileserver.files path",
           details: %{path: path}
         )}
    end
  end

  defp normalize_fileserver_type(nil, raw) do
    if fileserver_callback_present?(raw, :list), do: {:ok, :dir}, else: {:ok, :file}
  end

  defp normalize_fileserver_type(type, _raw) do
    case normalize_known_atom(type, [:file, :dir]) do
      {:ok, type} ->
        {:ok, type}

      {:error, _error} ->
        {:error, Hyperlang.Error.new(:manifest, "invalid exports.fileserver type")}
    end
  end

  defp normalize_fileserver_metadata(raw) do
    metadata = get(raw, :metadata, %{})

    metadata =
      case get(raw, :content_type, nil) do
        nil -> metadata
        content_type -> Map.put(metadata || %{}, :content_type, content_type)
      end

    if safe_fileserver_metadata?(metadata) do
      {:ok, metadata || %{}}
    else
      {:error, Hyperlang.Error.new(:manifest, "invalid exports.fileserver metadata")}
    end
  rescue
    _error -> {:error, Hyperlang.Error.new(:manifest, "invalid exports.fileserver metadata")}
  end

  defp safe_fileserver_metadata?(value)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
              is_nil(value),
       do: true

  defp safe_fileserver_metadata?(value) when is_atom(value), do: true

  defp safe_fileserver_metadata?(values) when is_list(values),
    do: Enum.all?(values, &safe_fileserver_metadata?/1)

  defp safe_fileserver_metadata?(map) when is_map(map) do
    Enum.all?(map, fn
      {key, value} when is_atom(key) or is_binary(key) -> safe_fileserver_metadata?(value)
      _other -> false
    end)
  end

  defp safe_fileserver_metadata?(_value), do: false

  defp normalize_fileserver_reactive_policy(nil), do: {:ok, nil}
  defp normalize_fileserver_reactive_policy(false), do: {:ok, :none}
  defp normalize_fileserver_reactive_policy(true), do: {:ok, :fid_generation}

  defp normalize_fileserver_reactive_policy(value) do
    case normalize_known_atom(value, [:none, :fid_generation]) do
      {:ok, policy} ->
        {:ok, policy}

      {:error, _error} ->
        {:error, Hyperlang.Error.new(:manifest, "invalid exports.fileserver reactive policy")}
    end
  end

  defp normalize_fileserver_callbacks(raw, type, functions) do
    with {:ok, callback_map} <- normalize_fileserver_callback_map(get(raw, :callbacks, %{})),
         :ok <- reject_ambiguous_fileserver_callbacks(raw, callback_map) do
      [:read, :write, :list, :stat]
      |> Enum.reduce_while({:ok, []}, fn op, {:ok, acc} ->
        value = Map.get(callback_map, op, get(raw, op, nil))

        case normalize_fileserver_callback(op, value, type, functions) do
          {:ok, nil} -> {:cont, {:ok, acc}}
          {:ok, callback} -> {:cont, {:ok, [callback | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, callbacks} -> {:ok, Enum.reverse(callbacks)}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp normalize_fileserver_callback_map(value) when value in [nil, %{}], do: {:ok, %{}}

  defp normalize_fileserver_callback_map(value) when is_map(value) do
    normalize_known_key_map(value, [:read, :write, :list, :stat], "exports.fileserver callbacks")
  end

  defp normalize_fileserver_callback_map(_value),
    do: {:error, Hyperlang.Error.new(:manifest, "exports.fileserver callbacks must be a map")}

  defp reject_ambiguous_fileserver_callbacks(raw, callbacks) do
    [:read, :write, :list, :stat]
    |> Enum.find(&(fileserver_callback_present?(raw, &1) and Map.has_key?(callbacks, &1)))
    |> case do
      nil ->
        :ok

      op ->
        {:error,
         Hyperlang.Error.new(:manifest, "ambiguous exports.fileserver callback",
           details: %{op: op}
         )}
    end
  end

  defp fileserver_callback_present?(raw, op), do: explicit_key?(raw, op)

  defp normalize_fileserver_callback(_op, nil, _type, _functions), do: {:ok, nil}

  defp normalize_fileserver_callback(:list, :declared, :dir, _functions),
    do: {:ok, {:declared_dir, :declared}}

  defp normalize_fileserver_callback(:list, "declared", :dir, _functions),
    do: {:ok, {:declared_dir, :declared}}

  defp normalize_fileserver_callback(:list, value, :file, _functions) when not is_nil(value),
    do: {:error, Hyperlang.Error.new(:manifest, "file exports cannot declare list callbacks")}

  defp normalize_fileserver_callback(op, _value, :dir, _functions) when op in [:read, :write],
    do:
      {:error,
       Hyperlang.Error.new(:manifest, "directory exports cannot declare read/write callbacks")}

  defp normalize_fileserver_callback(op, value, _type, functions) do
    with {:ok, id} <- normalize_export_string(value, "exports.fileserver callback id"),
         {:ok, export} <- fetch_fileserver_callback(id, functions) do
      {:ok, {op, export}}
    end
  end

  defp fetch_fileserver_callback(id, functions) do
    case Map.fetch(functions, id) do
      {:ok, export} ->
        {:ok, export}

      :error ->
        {:error,
         Hyperlang.Error.new(:manifest, "exports.fileserver callback id is not declared",
           details: %{id: id}
         )}
    end
  end

  defp require_fileserver_callbacks(_path, :dir, callbacks) do
    if callbacks == [] do
      {:error,
       Hyperlang.Error.new(:manifest, "exports.fileserver directory requires list or stat")}
    else
      :ok
    end
  end

  defp require_fileserver_callbacks(_path, :file, callbacks) do
    if callbacks == [] do
      {:error, Hyperlang.Error.new(:manifest, "exports.fileserver file requires a callback")}
    else
      :ok
    end
  end

  defp normalize_fileserver_effects(nil), do: {:ok, :default}
  defp normalize_fileserver_effects([]), do: {:ok, []}

  defp normalize_fileserver_effects(effects) when is_list(effects) do
    effects
    |> Enum.reduce_while({:ok, []}, fn effect, {:ok, acc} ->
      case normalize_known_atom(effect, @fileserver_effects) do
        {:ok, effect} ->
          {:cont, {:ok, [effect | acc]}}

        {:error, _error} ->
          {:halt, {:error, Hyperlang.Error.new(:manifest, "invalid exports.fileserver effect")}}
      end
    end)
    |> case do
      {:ok, effects} -> {:ok, effects |> Enum.reverse() |> Enum.uniq()}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_fileserver_effects(_effects),
    do: {:error, Hyperlang.Error.new(:manifest, "exports.fileserver effects must be a list")}

  defp reject_unusable_fileserver_effects(_callbacks, :default), do: :ok
  defp reject_unusable_fileserver_effects(_callbacks, []), do: :ok

  defp reject_unusable_fileserver_effects(callbacks, _effects) do
    if Enum.any?(callbacks, &match?({:write, _export}, &1)) do
      :ok
    else
      {:error,
       Hyperlang.Error.new(:manifest, "exports.fileserver effects require write callback")}
    end
  end

  defp normalize_fileserver_callback_contracts(attrs) do
    attrs.callbacks
    |> Enum.reduce_while({:ok, []}, fn callback, {:ok, acc} ->
      case fileserver_callback_contract(callback, attrs) do
        {:ok, file} -> {:cont, {:ok, [file | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      {:error, error} -> {:error, error}
    end
  end

  defp fileserver_callback_contract({:declared_dir, :declared}, attrs) do
    {:ok,
     %{
       path: attrs.path,
       type: :dir,
       op: :dir,
       rights: attrs.rights,
       deps: [],
       metadata: attrs.metadata,
       reactive_policy: attrs.reactive_policy
     }}
  end

  defp fileserver_callback_contract({op, export}, attrs) do
    contract = Map.fetch!(@fileserver_contracts, op)

    with :ok <- require_fileserver_callback_arity("exports.fileserver", op, export.arity),
         :ok <- require_fileserver_profile(export, op, :input, contract.input),
         :ok <- require_fileserver_profile(export, op, :output, contract.output) do
      {:ok,
       %{
         path: attrs.path,
         type: attrs.type,
         op: op,
         function: export.function,
         arity: export.arity,
         input: %{profile: contract.input},
         output: %{profile: contract.output},
         effects: fileserver_effects_for(op, attrs.effects, contract.effects),
         rights: attrs.rights,
         deps: if(op == :read, do: attrs.deps, else: []),
         metadata: attrs.metadata,
         reactive_policy: attrs.reactive_policy
       }}
    end
  end

  defp require_fileserver_profile(export, op, direction, expected) do
    profile =
      export
      |> Map.get(direction, %{})
      |> Map.get(:profile)

    if profile in [nil, expected] do
      :ok
    else
      {:error,
       Hyperlang.Error.new(
         :manifest,
         "exports.fileserver #{op} callback #{direction} profile must be #{expected}",
         details: %{op: op, direction: direction, expected: expected, actual: profile}
       )}
    end
  end

  defp fileserver_effects_for(:write, :default, effects), do: effects
  defp fileserver_effects_for(:write, effects, _default) when is_list(effects), do: effects
  defp fileserver_effects_for(_op, _effects, _default), do: []

  defp require_fileserver_callback_arity(_scope, _op, arity) when arity in 0..3, do: :ok

  defp require_fileserver_callback_arity(scope, op, arity) do
    {:error,
     Hyperlang.Error.new(
       :manifest,
       "#{scope} #{op} callback arity must be 0..3",
       details: %{scope: scope, op: op, arity: arity, supported_arities: [0, 1, 2, 3]}
     )}
  end

  defp normalize_export_id(id), do: normalize_export_string(id, "exports.functions id")

  defp normalize_export_function_name(name),
    do: normalize_export_string(name, "exports function name")

  defp normalize_export_string(value, label) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_export_string(label)

  defp normalize_export_string(value, label) when is_binary(value) do
    cond do
      value == "" ->
        {:error, Hyperlang.Error.new(:manifest, "#{label} must not be empty")}

      byte_size(value) > 255 ->
        {:error, Hyperlang.Error.new(:manifest, "#{label} exceeds 255 bytes")}

      String.contains?(value, <<0>>) ->
        {:error, Hyperlang.Error.new(:manifest, "#{label} contains null byte")}

      reserved_internal_atom_name?(value) ->
        {:error, Hyperlang.Error.new(:manifest, "#{label} uses reserved Hyperlang internal name")}

      true ->
        {:ok, value}
    end
  end

  defp normalize_export_string(_value, label),
    do: {:error, Hyperlang.Error.new(:manifest, "#{label} must be a string or atom")}

  defp normalize_export_arity(nil),
    do: {:error, Hyperlang.Error.new(:manifest, "exports function arity is required")}

  defp normalize_export_arity(value) do
    arity = to_int(value)

    if arity >= 0 and arity <= 255 do
      {:ok, arity}
    else
      {:error, Hyperlang.Error.new(:manifest, "exports function arity must be 0..255")}
    end
  rescue
    ArgumentError ->
      {:error, Hyperlang.Error.new(:manifest, "exports function arity must be an integer")}
  end

  defp normalize_export_profile(value, _label, _profiles) when value in [nil, %{}], do: {:ok, %{}}

  defp normalize_export_profile(value, label, profiles) when is_map(value) do
    with {:ok, raw} <- normalize_known_key_map(value, [:profile], "exports #{label} profile"),
         {:ok, profile} <- normalize_export_profile_name(get(raw, :profile, nil), label, profiles) do
      {:ok, %{profile: profile}}
    end
  end

  defp normalize_export_profile(_value, label, _profiles),
    do: {:error, Hyperlang.Error.new(:manifest, "exports #{label} profile must be a map")}

  defp normalize_export_profile_name(nil, _label, _profiles), do: {:ok, nil}

  defp normalize_export_profile_name(value, label, profiles) do
    case normalize_known_atom(value, profiles) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, profile} ->
        {:ok, profile}

      {:error, _error} ->
        {:error, Hyperlang.Error.new(:manifest, "invalid exports #{label} profile")}
    end
  end

  defp normalize_export_file_rights(rights) when is_list(rights) do
    rights
    |> Enum.reduce_while({:ok, []}, fn right, {:ok, acc} ->
      case normalize_known_atom(right, [:read, :write, :list, :stat, :watch]) do
        {:ok, right} ->
          {:cont, {:ok, [right | acc]}}

        {:error, _error} ->
          {:halt,
           {:error, Hyperlang.Error.new(:manifest, "invalid exports.fileserver.files right")}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, normalized |> Enum.reverse() |> Enum.uniq()}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_export_file_rights(_rights),
    do: {:error, Hyperlang.Error.new(:manifest, "exports.fileserver.files rights must be a list")}

  defp normalize_export_file_deps(value) when value in [nil, []], do: {:ok, []}

  defp normalize_export_file_deps(deps) when is_list(deps) do
    deps
    |> Enum.reduce_while({:ok, []}, fn dep, {:ok, acc} ->
      case normalize_export_file_dep(dep) do
        {:ok, dep} -> {:cont, {:ok, [dep | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, deps} -> {:ok, deps |> Enum.reverse() |> Enum.uniq()}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_export_file_deps(%{} = deps) do
    with {:ok, raw} <-
           normalize_known_key_map(
             deps,
             [:function, :arity],
             "exports.fileserver.files deps callback"
           ),
         {:ok, function} <- normalize_export_function_name(get(raw, :function, nil)),
         {:ok, arity} <- normalize_export_dep_arity(get(raw, :arity, nil)) do
      {:ok, %{type: :dynamic, function: function, arity: arity}}
    else
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_export_file_deps(_deps),
    do:
      {:error,
       Hyperlang.Error.new(
         :manifest,
         "exports.fileserver.files deps must be a list or callback descriptor"
       )}

  defp normalize_export_file_dep(path) when is_binary(path) do
    with {:ok, path} <- normalize_virtual_path(path, @default_filesystem_limits) do
      {:ok, path}
    else
      {:error, _error} ->
        {:error, Hyperlang.Error.new(:manifest, "invalid exports.fileserver.files dep")}
    end
  end

  defp normalize_export_file_dep(%{} = dep) do
    with {:ok, raw} <- normalize_known_key_map(dep, [:path], "exports.fileserver.files dep"),
         path when is_binary(path) <- get(raw, :path, nil) do
      normalize_export_file_dep(path)
    else
      nil ->
        {:error, Hyperlang.Error.new(:manifest, "exports.fileserver.files dep path is required")}

      {:error, error} ->
        {:error, error}
    end
  end

  defp normalize_export_file_dep(_dep),
    do: {:error, Hyperlang.Error.new(:manifest, "invalid exports.fileserver.files dep")}

  defp normalize_export_dep_arity(nil),
    do:
      {:error,
       Hyperlang.Error.new(:manifest, "exports.fileserver.files deps callback arity is required")}

  defp normalize_export_dep_arity(value) do
    arity = to_int(value)

    if arity in [0, 1] do
      {:ok, arity}
    else
      {:error,
       Hyperlang.Error.new(
         :manifest,
         "exports.fileserver.files deps callback arity must be 0 or 1"
       )}
    end
  rescue
    ArgumentError ->
      {:error,
       Hyperlang.Error.new(
         :manifest,
         "exports.fileserver.files deps callback arity must be an integer"
       )}
  end

  defp reject_duplicate_export_id(id, seen_ids) do
    if MapSet.member?(seen_ids, id) do
      {:error, Hyperlang.Error.new(:manifest, "duplicate exports.functions id")}
    else
      :ok
    end
  end

  defp reject_duplicate_export_call(%{function: function, arity: arity}, seen_calls) do
    if MapSet.member?(seen_calls, {function, arity}) do
      {:error, Hyperlang.Error.new(:manifest, "ambiguous exports.functions function/arity")}
    else
      :ok
    end
  end

  # `bindings: %{"kv" => MyHost.KV}`. Each module implements
  # `Hyperlang.Binding`; its `exports/0` list is read here, once, and the
  # derived `{name, function, arity}` set becomes part of the normalized
  # manifest (and therefore the program hash). Nothing about the set is
  # resolved at run time.
  defp normalize_bindings(bindings) when is_map(bindings) do
    bindings
    |> Enum.reduce_while({:ok, %{}}, fn {name, module}, {:ok, acc} ->
      with :ok <- validate_binding_name(name),
           :ok <- reject_reserved_binding(name),
           :ok <- validate_binding_module(name, module),
           {:ok, exports} <- normalize_binding_exports(name, module) do
        {:cont, {:ok, Map.put(acc, name, %{module: module, exports: exports})}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_bindings(_),
    do: {:error, Hyperlang.Error.new(:manifest, "bindings must be a map")}

  defp validate_binding_name(name) when is_binary(name) do
    if Regex.match?(~r/^[a-z][a-zA-Z0-9_]*$/, name) do
      :ok
    else
      {:error,
       Hyperlang.Error.new(:manifest, "binding name must be a lowercase Erlang module name",
         details: %{binding: name}
       )}
    end
  end

  defp validate_binding_name(name),
    do:
      {:error,
       Hyperlang.Error.new(:manifest, "binding name must be a string", details: %{binding: name})}

  defp reject_reserved_binding(name) do
    if Hyperlang.Stdlib.reserved_import_module?(name) or reserved_internal_atom_name?(name) do
      {:error,
       Hyperlang.Error.new(
         :manifest,
         "binding #{name} uses reserved authority module #{name}; use an application-owned binding name"
       )}
    else
      :ok
    end
  end

  defp validate_binding_module(name, module) do
    if binding_module?(module) do
      :ok
    else
      {:error,
       Hyperlang.Error.new(:manifest, "binding module must implement Hyperlang.Binding",
         details: %{binding: name}
       )}
    end
  end

  defp binding_module?(module) when is_atom(module) and module not in [nil, true, false] do
    Code.ensure_loaded?(module) and function_exported?(module, :exports, 0) and
      function_exported?(module, :call, 3)
  end

  defp binding_module?(_module), do: false

  defp normalize_binding_exports(name, module) do
    case module.exports() do
      exports when is_list(exports) ->
        exports
        |> Enum.reduce_while({:ok, %{}}, fn export, {:ok, acc} ->
          with {:ok, function, arity, opts} <- binding_export_shape(name, export),
               key = {Atom.to_string(function), arity},
               :ok <- reject_duplicate_binding_export(name, key, acc),
               {:ok, meta} <- normalize_binding_export_meta(name, function, arity, opts) do
            {:cont, {:ok, Map.put(acc, key, meta)}}
          else
            {:error, error} -> {:halt, {:error, error}}
          end
        end)

      _other ->
        {:error,
         Hyperlang.Error.new(:manifest, "binding exports/0 must return a list",
           details: %{binding: name}
         )}
    end
  end

  defp binding_export_shape(_name, {function, arity})
       when is_atom(function) and is_integer(arity) and arity >= 0,
       do: {:ok, function, arity, %{}}

  defp binding_export_shape(_name, {function, arity, opts})
       when is_atom(function) and is_integer(arity) and arity >= 0 and
              (is_map(opts) or is_list(opts)),
       do: {:ok, function, arity, Map.new(opts)}

  defp binding_export_shape(name, export) do
    {:error,
     Hyperlang.Error.new(
       :manifest,
       "binding export must be {function, arity} or {function, arity, opts}",
       details: %{binding: name, export: inspect(export)}
     )}
  end

  defp reject_duplicate_binding_export(name, {function, arity} = key, acc) do
    if Map.has_key?(acc, key) do
      {:error,
       Hyperlang.Error.new(:manifest, "duplicate binding export",
         details: %{binding: name, function: function, arity: arity}
       )}
    else
      :ok
    end
  end

  defp normalize_binding_export_meta(name, function, arity, opts) do
    unknown = Map.keys(opts) -- [:limits, :nondeterministic, :effects, :docs]

    with :ok <- reject_unknown_binding_options(name, unknown),
         {:ok, limits} <- normalize_limits(Map.get(opts, :limits, %{})) do
      {:ok,
       %{
         binding: name,
         function: function,
         call: {name, Atom.to_string(function), arity},
         limits: limits,
         effects: Map.get(opts, :effects, []),
         nondeterministic: Map.get(opts, :nondeterministic, false),
         docs: Map.get(opts, :docs, %{})
       }}
    end
  end

  defp reject_unknown_binding_options(_name, []), do: :ok

  defp reject_unknown_binding_options(name, unknown) do
    {:error,
     Hyperlang.Error.new(:manifest, "unknown binding export options",
       details: %{binding: name, options: Enum.map(unknown, &inspect/1)}
     )}
  end

  defp validate_nondeterministic_bindings(_bindings, %{nondeterminism: true}), do: :ok

  defp validate_nondeterministic_bindings(bindings, _capabilities) do
    nondeterministic =
      for {_name, %{exports: exports}} <- bindings,
          {_key, meta} <- exports,
          truthy?(meta.nondeterministic),
          do: meta.call

    if nondeterministic == [] do
      :ok
    else
      {:error,
       Hyperlang.Error.new(
         :manifest,
         "nondeterministic bindings require capabilities.nondeterminism",
         details: %{calls: Enum.sort(nondeterministic)}
       )}
    end
  end

  defp normalize_limits(limits) when is_map(limits) do
    with {:ok, overrides} <- normalize_known_key_map(limits, Map.keys(@default_limits), "limit") do
      merged = Map.merge(@default_limits, overrides, fn _, _, v -> v end)

      invalid =
        merged
        |> Enum.filter(fn
          {k, nil}
          when k in [
                 :max_reductions,
                 :max_heap_words,
                 :rate,
                 :ceiling,
                 :max_procs
               ] ->
            false

          {:rate, {quota, period}}
          when is_integer(quota) and quota > 0 and is_integer(period) and period > 0 ->
            false

          {:rate, %{quota: quota, period_ms: period}}
          when is_integer(quota) and quota > 0 and is_integer(period) and period > 0 ->
            false

          {:ceiling, :infinity} ->
            false

          {_k, nil} ->
            true

          {:wall_ms, :infinity} ->
            false

          {k, v}
          when k in [
                 :wall_ms,
                 :heap_words,
                 :max_compile_reductions,
                 :max_compile_ms,
                 :max_heap_words
               ] ->
            not (is_integer(v) and v > 0)

          {_k, v} ->
            not (is_integer(v) and v >= 0)
        end)

      cond do
        invalid != [] ->
          {:error,
           Hyperlang.Error.new(
             :manifest,
             "limits must be non-negative integers; runtime-critical limits must be positive",
             details: %{invalid: invalid}
           )}

        merged.max_atom_count > Hyperlang.GeneratedAtoms.max_source_atoms() ->
          {:error,
           Hyperlang.Error.new(:manifest, "max_atom_count exceeds Hyperlang fixed atom pool",
             details: %{
               limit: merged.max_atom_count,
               max: Hyperlang.GeneratedAtoms.max_source_atoms()
             }
           )}

        merged.max_functions > Hyperlang.GeneratedAtoms.max_functions() ->
          {:error,
           Hyperlang.Error.new(
             :manifest,
             "max_functions exceeds Hyperlang fixed function atom pool",
             details: %{
               limit: merged.max_functions,
               max: Hyperlang.GeneratedAtoms.max_functions()
             }
           )}

        merged.max_pattern_splits > Hyperlang.GeneratedAtoms.max_pattern_splits() ->
          {:error,
           Hyperlang.Error.new(
             :manifest,
             "max_pattern_splits exceeds Hyperlang fixed compiler name set",
             details: %{
               limit: merged.max_pattern_splits,
               max: Hyperlang.GeneratedAtoms.max_pattern_splits()
             }
           )}

        merged.max_tokens > Hyperlang.GeneratedAtoms.max_variables() ->
          {:error,
           Hyperlang.Error.new(:manifest, "max_tokens exceeds Hyperlang fixed variable atom pool",
             details: %{limit: merged.max_tokens, max: Hyperlang.GeneratedAtoms.max_variables()}
           )}

        true ->
          {:ok, merged}
      end
    end
  end

  defp normalize_limits(_), do: {:error, Hyperlang.Error.new(:manifest, "limits must be a map")}

  defp normalize_atom_universe(nil), do: {:ok, nil}

  defp normalize_atom_universe(value) do
    if safe_atom_universe_id?(value) do
      {:ok, value}
    else
      {:error, Hyperlang.Error.new(:manifest, "atom_universe must be an opaque serializable id")}
    end
  end

  defp safe_atom_universe_id?(value)
       when is_binary(value) or is_integer(value) or is_atom(value) or is_boolean(value) or
              is_nil(value),
       do: true

  defp safe_atom_universe_id?(value) when is_list(value),
    do: Enum.all?(value, &safe_atom_universe_id?/1)

  defp safe_atom_universe_id?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.all?(&safe_atom_universe_id?/1)

  defp safe_atom_universe_id?(value) when is_map(value) do
    Enum.all?(value, fn {key, item} ->
      safe_atom_universe_id?(key) and safe_atom_universe_id?(item)
    end)
  end

  defp safe_atom_universe_id?(_value), do: false

  defp normalize_terms(terms) when is_map(terms) do
    with {:ok, raw} <- normalize_known_key_map(terms, Map.keys(@default_terms), "term policy") do
      do_normalize_terms(raw)
    end
  end

  defp normalize_terms(_), do: {:error, Hyperlang.Error.new(:manifest, "terms must be a map")}

  defp do_normalize_terms(raw) do
    public = normalize_public_profile(Map.get(raw, :public, @default_terms.public))

    defaults =
      case public do
        :json -> @default_terms
        :erlang -> @erlang_terms
      end

    merged = Map.merge(defaults, raw, fn _, _, v -> v end)

    with {:ok, atoms} <- normalize_allowed_atoms(Map.get(merged, :allowed_atoms, [])),
         {:ok, public} <- normalize_public(merged.public),
         {:ok, atom_public} <- normalize_public_atom_mapping(merged.atom_public),
         {:ok, tuple_public} <- normalize_public_tuple_mapping(merged.tuple_public),
         {:ok, binary_public} <- normalize_public_binary_mapping(merged.binary_public),
         {:ok, improper_list_public} <-
           normalize_public_improper_list_mapping(merged.improper_list_public) do
      {:ok,
       %{
         merged
         | allowed_atoms: atoms,
           public: public,
           atom_public: atom_public,
           tuple_public: tuple_public,
           binary_public: binary_public,
           improper_list_public: improper_list_public
       }}
    end
  end

  defp normalize_allowed_atoms(values) do
    values =
      if match?(%MapSet{}, values), do: MapSet.to_list(values), else: values

    values =
      values
      |> List.wrap()
      |> Enum.reduce_while({:ok, MapSet.new([true, false, nil])}, fn value, {:ok, set} ->
        cond do
          reserved_internal_atom?(value) ->
            {:halt,
             {:error,
              Hyperlang.Error.new(:manifest, "allowed atom uses reserved Hyperlang internal name",
                details: %{atom: value}
              )}}

          is_atom(value) ->
            {:cont, {:ok, MapSet.put(set, value)}}

          is_binary(value) ->
            try do
              atom = String.to_existing_atom(value)

              if reserved_internal_atom?(atom) do
                {:halt,
                 {:error,
                  Hyperlang.Error.new(
                    :manifest,
                    "allowed atom uses reserved Hyperlang internal name",
                    details: %{atom: value}
                  )}}
              else
                {:cont, {:ok, MapSet.put(set, atom)}}
              end
            rescue
              ArgumentError ->
                {:halt,
                 {:error,
                  Hyperlang.Error.new(:manifest, "allowed atom must already exist",
                    details: %{atom: value}
                  )}}
            end

          true ->
            {:halt,
             {:error,
              Hyperlang.Error.new(:manifest, "allowed atoms must be atoms or existing atom names")}}
        end
      end)

    values
  end

  defp reserved_internal_atom?(value), do: reserved_internal_name?(value)

  defp reserved_internal_atom_name?(value) when is_binary(value),
    do:
      Regex.match?(~r/^hyperlang_(atom|kernel_atom|slot)_\d+$/, value) or
        Regex.match?(~r/^safe_f_\d+$/, value) or
        value in [
          "$safe_entry",
          "$safe_export",
          "$hyperlang_msg",
          "safe_result",
          "safe_snapshot_apply",
          "hyperlang_pending_slot",
          "hyperlang_pending_version"
        ]

  defp normalize_public_profile(value) do
    case normalize_known_atom(value, [:erlang, :json]) do
      {:ok, public} -> public
      {:error, _} -> @default_terms.public
    end
  end

  defp normalize_public(value), do: normalize_known_atom(value, [:erlang, :json])

  defp normalize_public_atom_mapping(value), do: normalize_known_atom(value, [:atom, :binary])

  defp normalize_public_tuple_mapping(value), do: normalize_known_atom(value, [:tuple, :list])

  defp normalize_public_binary_mapping(value),
    do: normalize_known_atom(value, [:binary, :base64])

  defp normalize_public_improper_list_mapping(value), do: normalize_known_atom(value, [:reject])

  defp normalize_known_atom(value, allowed) when is_atom(value) do
    if value in allowed do
      {:ok, value}
    else
      {:error,
       Hyperlang.Error.new(:manifest, "invalid terms public mapping",
         details: %{value: value, allowed: allowed}
       )}
    end
  end

  defp normalize_known_atom(value, allowed) when is_binary(value) do
    allowed
    |> Enum.find(&(Atom.to_string(&1) == value))
    |> case do
      nil ->
        {:error,
         Hyperlang.Error.new(:manifest, "invalid terms public mapping",
           details: %{value: value, allowed: allowed}
         )}

      atom ->
        {:ok, atom}
    end
  end

  defp normalize_known_atom(value, allowed) do
    {:error,
     Hyperlang.Error.new(:manifest, "invalid terms public mapping",
       details: %{value: inspect(value), allowed: allowed}
     )}
  end

  defp normalize_stdlib(stdlib) when stdlib in [nil, %{}], do: {:ok, @default_stdlib}

  defp normalize_stdlib(stdlib) when is_map(stdlib) do
    with {:ok, overrides} <- normalize_known_key_map(stdlib, Map.keys(@default_stdlib), "stdlib") do
      {:ok, Map.merge(@default_stdlib, overrides, fn _, _, v -> truthy?(v) end)}
    end
  end

  defp normalize_stdlib(list) when is_list(list) do
    {:ok, Map.new(@default_stdlib, fn {k, _} -> {k, k in list or Atom.to_string(k) in list} end)}
  end

  defp normalize_stdlib(_),
    do: {:error, Hyperlang.Error.new(:manifest, "stdlib must be a map or list")}

  defp normalize_capabilities(capabilities) when capabilities in [nil, %{}],
    do: {:ok, @default_capabilities}

  defp normalize_capabilities(capabilities) when is_map(capabilities) do
    allowed = [:nondeterminism, :non_determinism, :gen_server]

    with {:ok, raw} <- normalize_known_key_map(capabilities, allowed, "capability") do
      enabled = get(raw, :nondeterminism, get(raw, :non_determinism, false))
      gen_server = get(raw, :gen_server, false)

      {:ok, %{nondeterminism: truthy?(enabled), gen_server: truthy?(gen_server)}}
    end
  end

  defp normalize_capabilities(capabilities) when is_list(capabilities) do
    capabilities
    |> Enum.reduce_while({:ok, @default_capabilities}, fn capability, {:ok, acc} ->
      case normalize_known_atom(capability, [
             :nondeterminism,
             :non_determinism,
             :gen_server
           ]) do
        {:ok, :nondeterminism} ->
          {:cont, {:ok, %{acc | nondeterminism: true}}}

        {:ok, :non_determinism} ->
          {:cont, {:ok, %{acc | nondeterminism: true}}}

        {:ok, :gen_server} ->
          {:cont, {:ok, %{acc | gen_server: true}}}

        {:error, _error} ->
          {:halt, {:error, Hyperlang.Error.new(:manifest, "invalid capability")}}
      end
    end)
  end

  defp normalize_capabilities(_),
    do: {:error, Hyperlang.Error.new(:manifest, "capabilities must be a map or list")}

  defp normalize_userland_profile(value) when value in [nil, %{}],
    do: {:ok, @default_profile}

  defp normalize_userland_profile(value) when is_atom(value) or is_binary(value) do
    normalize_userland_profile(%{name: value})
  end

  defp normalize_userland_profile(value) when is_map(value) do
    with {:ok, raw} <- normalize_known_key_map(value, Map.keys(@default_profile), "profile"),
         {:ok, name} <- normalize_userland_profile_name(get(raw, :name, nil)) do
      {:ok, %{name: name}}
    end
  end

  defp normalize_userland_profile(_value),
    do:
      {:error,
       Hyperlang.Error.new(:manifest, "profile must be an atom, string, or map",
         details: %{allowed: @userland_profiles}
       )}

  defp normalize_userland_profile_name(nil), do: {:ok, nil}

  defp normalize_userland_profile_name(value) do
    case normalize_known_atom(value, @userland_profiles) do
      {:ok, name} when name in @guest_selectable_userland_profiles ->
        {:ok, name}

      {:ok, name} ->
        {:error,
         Hyperlang.Error.new(:manifest, "profile requires trusted host selection",
           details: %{
             profile: name,
             allowed: @guest_selectable_userland_profiles,
             host_only: @userland_profiles -- @guest_selectable_userland_profiles
           }
         )}

      {:error, _error} ->
        {:error,
         Hyperlang.Error.new(:manifest, "invalid profile",
           details: %{profile: value, allowed: @userland_profiles}
         )}
    end
  end

  defp normalize_syntax(syntax) when syntax in [nil, %{}], do: {:ok, @default_syntax}

  defp normalize_syntax(syntax) when is_map(syntax) do
    with {:ok, overrides} <- normalize_known_key_map(syntax, Map.keys(@default_syntax), "syntax") do
      {:ok, Map.merge(@default_syntax, overrides)}
    end
  end

  defp normalize_syntax(_), do: {:error, Hyperlang.Error.new(:manifest, "syntax must be a map")}

  # The default per-guest code-pool ceiling tracks the configured CodeServer pool
  # (`:code_pool_size`, 8192 on a large-test host) so a guest's `free_slot` search
  # uses the WHOLE allocated pool. A hardcoded 128 defeated it: guests crammed
  # into slots 1..128 of an 8192-slot pool → "no generated code slots available"
  # under a long shared-BEAM run while 8064 slots sat idle (#70). 128 stays the
  # no-config fallback (the @default_size the CodeServer also falls back to).
  defp default_code_pool_size, do: Application.get_env(:hyperlang, :code_pool_size, 128)

  defp normalize_code_pool(pool) when pool in [nil, %{}],
    do: {:ok, %{size: default_code_pool_size(), lifecycle: :reference_counted}}

  defp normalize_code_pool(pool) when is_map(pool) do
    with {:ok, pool} <- normalize_known_key_map(pool, [:size, :lifecycle], "code_pool") do
      do_normalize_code_pool(pool)
    end
  end

  defp normalize_code_pool(_),
    do: {:error, Hyperlang.Error.new(:manifest, "code_pool must be a map")}

  defp do_normalize_code_pool(pool) do
    size = pool |> get(:size, default_code_pool_size()) |> to_int()

    with true <- size > 0,
         {:ok, lifecycle} <-
           normalize_known_atom(get(pool, :lifecycle, :reference_counted), [:reference_counted]) do
      {:ok, %{size: size, lifecycle: lifecycle}}
    else
      false -> {:error, Hyperlang.Error.new(:manifest, "code_pool size must be positive")}
      {:error, _error} -> {:error, Hyperlang.Error.new(:manifest, "invalid code_pool lifecycle")}
    end
  end

  defp normalize_filesystem(value) when value in [nil, %{}],
    do: stamp_validated_filesystem(@default_filesystem)

  defp normalize_filesystem(value) when is_map(value) do
    with {:ok, raw} <-
           normalize_known_key_map(value, Map.keys(@default_filesystem), "filesystem"),
         {:ok, limits} <- normalize_filesystem_limits(get(raw, :limits, %{})),
         {:ok, atom_vocabularies} <-
           normalize_filesystem_atom_vocabularies(get(raw, :atom_vocabularies, %{})),
         {:ok, commit_policy} <-
           normalize_known_atom(
             get(raw, :commit_policy, @default_filesystem.commit_policy),
             [:per_request, :on_eval_success, :manual]
           ),
         {:ok, mounts} <- normalize_filesystem_mounts(get(raw, :mounts, []), limits),
         {:ok, backend} <-
           normalize_known_atom(
             get(raw, :backend, @default_filesystem.backend),
             [:own, :host]
           ),
         {:ok, cwd} <- normalize_virtual_path(get(raw, :cwd, @default_filesystem.cwd), limits) do
      %{
        @default_filesystem
        | enabled: truthy?(get(raw, :enabled, @default_filesystem.enabled)),
          backend: backend,
          cwd: cwd,
          allow_relative_paths:
            truthy?(get(raw, :allow_relative_paths, @default_filesystem.allow_relative_paths)),
          file_compat: truthy?(get(raw, :file_compat, @default_filesystem.file_compat)),
          filelib_compat: truthy?(get(raw, :filelib_compat, @default_filesystem.filelib_compat)),
          handle_compat: truthy?(get(raw, :handle_compat, @default_filesystem.handle_compat)),
          loader_compat: truthy?(get(raw, :loader_compat, @default_filesystem.loader_compat)),
          source_compile: truthy?(get(raw, :source_compile, @default_filesystem.source_compile)),
          commit_policy: commit_policy,
          limits: limits,
          mounts: mounts,
          atom_vocabularies: atom_vocabularies
      }
      |> stamp_validated_filesystem()
    else
      {:error, %{message: "invalid terms public mapping"} = _error} ->
        {:error, Hyperlang.Error.new(:manifest, "invalid filesystem commit_policy")}

      other ->
        other
    end
  end

  defp normalize_filesystem(_),
    do: {:error, Hyperlang.Error.new(:manifest, "filesystem must be a map")}

  defp normalize_tables(value) when value in [nil, %{}], do: {:ok, @default_tables}

  defp normalize_tables(value) when is_map(value) do
    with {:ok, raw} <-
           normalize_known_key_map(value, Map.keys(@default_tables), "table service"),
         {:ok, limits} <- normalize_table_limits(get(raw, :limits, %{})) do
      {:ok,
       %{
         enabled: truthy?(get(raw, :enabled, @default_tables.enabled)),
         limits: limits
       }}
    end
  end

  defp normalize_tables(_value),
    do: {:error, Hyperlang.Error.new(:manifest, "tables must be a map")}

  defp normalize_table_limits(value) when value in [nil, %{}],
    do: {:ok, @default_table_limits}

  defp normalize_table_limits(value) when is_map(value) do
    with {:ok, overrides} <-
           normalize_known_key_map(
             value,
             Map.keys(@default_table_limits),
             "table limit"
           ) do
      limits =
        Map.merge(@default_table_limits, overrides, fn _key, _default, override ->
          to_int(override)
        end)

      invalid =
        Enum.filter(limits, fn {_key, limit} ->
          not (is_integer(limit) and limit >= 0)
        end)

      if invalid == [] do
        {:ok, limits}
      else
        {:error,
         Hyperlang.Error.new(:manifest, "table limits must be non-negative integers",
           details: %{invalid: invalid}
         )}
      end
    end
  rescue
    _error ->
      {:error, Hyperlang.Error.new(:manifest, "table limits must be non-negative integers")}
  end

  defp normalize_table_limits(_value),
    do: {:error, Hyperlang.Error.new(:manifest, "table limits must be a map")}

  defp normalize_sys(value) when value in [nil, %{}], do: {:ok, @default_sys}

  defp normalize_sys(value) when is_map(value) do
    with {:ok, raw} <- normalize_known_key_map(value, Map.keys(@default_sys), "sys"),
         {:ok, channel_element_types} <-
           normalize_channel_element_types(
             get(raw, :channel_element_types, @default_sys.channel_element_types)
           ) do
      {:ok,
       %{
         enabled: truthy?(get(raw, :enabled, @default_sys.enabled)),
         channel_element_types: channel_element_types
       }}
    end
  end

  defp normalize_sys(_),
    do: {:error, Hyperlang.Error.new(:manifest, "sys must be a map")}

  defp normalize_channel_element_types(value) when value in [nil, %{}], do: {:ok, %{}}

  defp normalize_channel_element_types(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, acc} ->
      with {:ok, key, type} <- normalize_channel_element_type_entry(entry) do
        {:cont, {:ok, Map.put(acc, key, Hyperlang.ChannelTypes.classify(type))}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_channel_element_types(entries) when is_map(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key, type}, {:ok, acc} ->
      with {:ok, key} <- normalize_channel_element_type_key(key) do
        {:cont, {:ok, Map.put(acc, key, Hyperlang.ChannelTypes.classify(type))}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_channel_element_types(_value) do
    {:error, Hyperlang.Error.new(:manifest, "sys.channel_element_types must be a map or list")}
  end

  defp normalize_channel_element_type_entry(entry) when is_map(entry) do
    with {:ok, function} <-
           normalize_channel_element_function(get(entry, :function, get(entry, :name, nil))),
         {:ok, arity} <- normalize_non_neg_int(get(entry, :arity, nil), "sys.channel arity"),
         {:ok, index} <-
           normalize_non_neg_int(
             get(entry, :index, get(entry, :call_index, get(entry, :ordinal, nil))),
             "sys.channel index"
           ) do
      type = get(entry, :type, get(entry, :element_type, get(entry, :element, nil)))
      {:ok, {function, arity, index}, type}
    end
  end

  defp normalize_channel_element_type_entry(_entry) do
    {:error, Hyperlang.Error.new(:manifest, "sys.channel_element_types entries must be maps")}
  end

  defp normalize_channel_element_type_key({function, arity, index}) do
    with {:ok, function} <- normalize_channel_element_function(function),
         {:ok, arity} <- normalize_non_neg_int(arity, "sys.channel arity"),
         {:ok, index} <- normalize_non_neg_int(index, "sys.channel index") do
      {:ok, {function, arity, index}}
    end
  end

  defp normalize_channel_element_type_key(key) when is_binary(key) do
    case Regex.run(~r/^([^\/#]+)\/([0-9]+)#([0-9]+)$/, key) do
      [_all, function, arity, index] ->
        normalize_channel_element_type_key({function, arity, index})

      _other ->
        {:error,
         Hyperlang.Error.new(:manifest, "invalid sys.channel_element_types key",
           details: %{key: key}
         )}
    end
  end

  defp normalize_channel_element_type_key(_key) do
    {:error, Hyperlang.Error.new(:manifest, "invalid sys.channel_element_types key")}
  end

  defp normalize_channel_element_function(function)
       when is_binary(function) and byte_size(function) > 0,
       do: {:ok, function}

  defp normalize_channel_element_function(function)
       when is_atom(function) and function not in [nil, true, false],
       do: {:ok, Atom.to_string(function)}

  defp normalize_channel_element_function(_function),
    do: {:error, Hyperlang.Error.new(:manifest, "sys.channel function must be a name")}

  defp normalize_non_neg_int(value, _label) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp normalize_non_neg_int(value, label) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 ->
        {:ok, integer}

      _other ->
        {:error, Hyperlang.Error.new(:manifest, "#{label} must be a non-negative integer")}
    end
  end

  defp normalize_non_neg_int(_value, label),
    do: {:error, Hyperlang.Error.new(:manifest, "#{label} must be a non-negative integer")}

  defp normalize_modules(value) when value in [nil, %{}], do: {:ok, @default_modules}

  defp normalize_modules(value) when is_map(value) do
    with {:ok, raw} <- normalize_known_key_map(value, Map.keys(@default_modules), "modules"),
         {:ok, path} <- normalize_modules_path(get(raw, :path, @default_modules.path)),
         {:ok, guest_modules} <-
           normalize_modules_guest_modules(
             get(raw, :guest_modules, @default_modules.guest_modules)
           ),
         {:ok, max_modules} <-
           normalize_modules_pos_int(:max_modules, get(raw, :max_modules, nil)),
         {:ok, max_depth} <- normalize_modules_pos_int(:max_depth, get(raw, :max_depth, nil)),
         {:ok, max_doc_chunk_bytes} <-
           normalize_modules_pos_int(:max_doc_chunk_bytes, get(raw, :max_doc_chunk_bytes, nil)) do
      {:ok,
       %{
         enabled: truthy?(get(raw, :enabled, @default_modules.enabled)),
         callback_dispatch:
           truthy?(get(raw, :callback_dispatch, @default_modules.callback_dispatch)),
         path: path,
         guest_modules: guest_modules,
         max_modules: max_modules,
         max_depth: max_depth,
         max_doc_chunk_bytes: max_doc_chunk_bytes
       }}
    end
  end

  defp normalize_modules(_),
    do: {:error, Hyperlang.Error.new(:manifest, "modules must be a map")}

  # An explicit empty path remains useful for compile-time-only guest module
  # injection.  The compatibility default is /sys/lib, but callers may still
  # opt out of runtime code-path lookup without disabling `guest_modules`.
  defp normalize_modules_path([]), do: {:ok, []}

  defp normalize_modules_path(paths) when is_list(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      cond do
        not is_binary(path) ->
          {:halt,
           {:error, Hyperlang.Error.new(:manifest, "modules path entries must be strings")}}

        not String.starts_with?(path, "/") ->
          {:halt,
           {:error, Hyperlang.Error.new(:manifest, "modules path entries must be absolute")}}

        path != "/" and String.ends_with?(path, "/") ->
          {:halt, {:error, Hyperlang.Error.new(:manifest, "modules path entry is invalid")}}

        String.contains?(path, [<<0>>, "//", "/./", "/../"]) or
            String.ends_with?(path, ["/.", "/.."]) ->
          {:halt, {:error, Hyperlang.Error.new(:manifest, "modules path entry is invalid")}}

        true ->
          {:cont, {:ok, [path | acc]}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_modules_path(_paths),
    do: {:error, Hyperlang.Error.new(:manifest, "modules path must be a list")}

  defp normalize_modules_guest_modules(value) when value in [nil, []], do: {:ok, []}

  defp normalize_modules_guest_modules(value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn
      module, {:ok, acc} when is_binary(module) or is_atom(module) ->
        name = to_string(module)

        # Snapshot module identities are source atoms, not just unquoted Erlang
        # identifiers.  Ports must be able to retain exact upstream names such
        # as '8bit_stob' and 'euc-jp_btos' without inventing aliases.  Keep the
        # accepted alphabet deliberately finite; normalization still produces
        # strings and the snapshot atom universe remains bounded.
        if Regex.match?(~r/\A[a-z0-9][A-Za-z0-9_-]*\z/, name) do
          {:cont, {:ok, [name | acc]}}
        else
          {:halt,
           {:error,
            Hyperlang.Error.new(
              :manifest,
              "modules guest_modules entries must be valid module names"
            )}}
        end

      _module, {:ok, _acc} ->
        {:halt,
         {:error, Hyperlang.Error.new(:manifest, "modules guest_modules entries must be strings")}}
    end)
    |> case do
      {:ok, names} -> {:ok, names |> Enum.uniq() |> Enum.sort()}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_modules_guest_modules(_value),
    do: {:error, Hyperlang.Error.new(:manifest, "modules guest_modules must be a list")}

  defp normalize_modules_pos_int(key, nil), do: {:ok, Map.fetch!(@default_modules, key)}

  defp normalize_modules_pos_int(key, value) do
    case to_int(value) do
      int when is_integer(int) and int > 0 ->
        {:ok, int}

      _other ->
        {:error, Hyperlang.Error.new(:manifest, "modules #{key} must be a positive integer")}
    end
  rescue
    _error ->
      {:error, Hyperlang.Error.new(:manifest, "modules #{key} must be a positive integer")}
  end

  defp normalize_filesystem_limits(value) when value in [nil, %{}],
    do: {:ok, @default_filesystem_limits}

  defp normalize_filesystem_limits(value) when is_map(value) do
    with {:ok, overrides} <-
           normalize_known_key_map(
             value,
             Map.keys(@default_filesystem_limits),
             "filesystem limit"
           ) do
      merged = Map.merge(@default_filesystem_limits, overrides, fn _, _, v -> to_int(v) end)

      invalid =
        merged
        |> Enum.filter(fn {_key, val} -> not (is_integer(val) and val >= 0) end)

      if invalid == [] do
        {:ok, merged}
      else
        {:error,
         Hyperlang.Error.new(:manifest, "filesystem limits must be non-negative integers",
           details: %{invalid: invalid}
         )}
      end
    end
  rescue
    ArgumentError ->
      {:error, Hyperlang.Error.new(:manifest, "filesystem limits must be non-negative integers")}
  end

  defp normalize_filesystem_limits(_),
    do: {:error, Hyperlang.Error.new(:manifest, "filesystem limits must be a map")}

  defp normalize_filesystem_atom_vocabularies(value) when value in [nil, %{}],
    do: {:ok, @default_filesystem.atom_vocabularies}

  defp normalize_filesystem_atom_vocabularies(value) when is_map(value) do
    with {:ok, overrides} <-
           normalize_known_key_map(
             value,
             Map.keys(@default_filesystem.atom_vocabularies),
             "filesystem atom vocabulary"
           ) do
      {:ok,
       Map.merge(@default_filesystem.atom_vocabularies, overrides, fn _, _, v -> truthy?(v) end)}
    end
  end

  defp normalize_filesystem_atom_vocabularies(_),
    do: {:error, Hyperlang.Error.new(:manifest, "filesystem atom_vocabularies must be a map")}

  defp normalize_filesystem_mounts(value, _limits) when value in [nil, []], do: {:ok, []}

  defp normalize_filesystem_mounts(mounts, limits) when is_list(mounts) do
    if length(mounts) > limits.max_mounts do
      {:error,
       Hyperlang.Error.new(:manifest, "filesystem mount count exceeds max_mounts",
         details: %{count: length(mounts), max: limits.max_mounts}
       )}
    else
      mounts
      |> Enum.reduce_while({:ok, [], MapSet.new()}, fn mount, {:ok, acc, roots} ->
        with {:ok, normalized} <- normalize_filesystem_mount(mount, limits),
             :ok <- reject_duplicate_mount(normalized.virtual, roots) do
          {:cont, {:ok, [normalized | acc], MapSet.put(roots, normalized.virtual)}}
        else
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, normalized, _roots} -> {:ok, Enum.reverse(normalized)}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp normalize_filesystem_mounts(_mounts, _limits),
    do: {:error, Hyperlang.Error.new(:manifest, "filesystem mounts must be a list")}

  defp normalize_filesystem_mount(mount, limits) when is_map(mount) do
    with {:ok, raw} <-
           normalize_known_key_map(
             mount,
             [
               :virtual,
               :backend,
               :mode,
               :allow,
               :host_path,
               :limits,
               :files,
               :dirs,
               :symlinks
             ],
             "filesystem mount"
           ),
         {:ok, virtual} <- normalize_virtual_path(get(raw, :virtual, nil), limits),
         {:ok, mode} <-
           normalize_known_atom(get(raw, :mode, :read_only), [
             :read_only,
             :read_write,
             :memory,
             :overlay,
             :snapshot
           ]),
         {:ok, allow} <- normalize_mount_allow(get(raw, :allow, [])),
         {:ok, backend} <- normalize_mount_backend(get(raw, :backend, nil), raw, mode),
         {:ok, mount_limits} <- normalize_mount_limits(get(raw, :limits, %{}), limits),
         {:ok, seed} <- normalize_memory_seed(raw, backend, mount_limits) do
      validate_mount_backend_mode!(backend, mode)

      {:ok,
       %{
         virtual: virtual,
         backend: backend,
         mode: mode,
         allow: allow,
         overlay: overlay_state(mode, backend),
         limits: mount_limits,
         seed: seed
       }}
    else
      {:error, %{message: "invalid terms public mapping"} = _error} ->
        {:error, Hyperlang.Error.new(:manifest, "invalid filesystem mount enum")}

      other ->
        other
    end
  rescue
    error in RuntimeError ->
      {:error, Hyperlang.Error.new(:manifest, Exception.message(error))}
  end

  defp normalize_filesystem_mount(_mount, _limits),
    do: {:error, Hyperlang.Error.new(:manifest, "filesystem mount must be a map")}

  defp normalize_mount_limits(value, parent_limits) when value in [nil, %{}],
    do: {:ok, parent_limits}

  defp normalize_mount_limits(value, parent_limits) when is_map(value) do
    with {:ok, raw} <-
           normalize_known_key_map(
             value,
             Map.keys(@default_filesystem_limits),
             "filesystem limit"
           ) do
      overrides = Map.new(raw, fn {key, value} -> {key, to_int(value)} end)
      merged = Map.merge(parent_limits, overrides)

      if Enum.all?(merged, fn {_key, value} -> is_integer(value) and value >= 0 end) do
        {:ok, merged}
      else
        {:error,
         Hyperlang.Error.new(:manifest, "filesystem limits must be non-negative integers",
           details: %{limits: merged}
         )}
      end
    end
  rescue
    ArgumentError ->
      {:error, Hyperlang.Error.new(:manifest, "filesystem limits must be non-negative integers")}
  end

  defp normalize_mount_limits(_value, _parent_limits),
    do: {:error, Hyperlang.Error.new(:manifest, "filesystem limits must be a map")}

  defp normalize_mount_allow(value) do
    permissions =
      value
      |> List.wrap()
      |> Enum.reduce_while({:ok, MapSet.new()}, fn permission, {:ok, set} ->
        case normalize_known_atom(permission, [
               :read,
               :write,
               :rename,
               :delete,
               :mkdir,
               :list,
               :stat,
               :lstat
             ]) do
          {:ok, atom} ->
            {:cont, {:ok, MapSet.put(set, atom)}}

          {:error, _error} ->
            {:halt,
             {:error, Hyperlang.Error.new(:manifest, "invalid filesystem mount permission")}}
        end
      end)

    case permissions do
      {:ok, set} -> {:ok, set |> MapSet.to_list() |> Enum.sort()}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_memory_seed(raw, :memory, limits) do
    with {:ok, dirs} <- normalize_seed_dirs(get(raw, :dirs, []), limits),
         {:ok, files} <- normalize_seed_files(get(raw, :files, []), limits),
         {:ok, symlinks} <- normalize_seed_symlinks(get(raw, :symlinks, []), limits) do
      {:ok, %{dirs: dirs, files: files, symlinks: symlinks}}
    end
  end

  defp normalize_memory_seed(raw, _backend, _limits) do
    if get(raw, :dirs, []) in [nil, []] and get(raw, :files, []) in [nil, []] and
         get(raw, :symlinks, []) in [nil, []] do
      {:ok, %{dirs: [], files: [], symlinks: []}}
    else
      {:error, Hyperlang.Error.new(:manifest, "seeded filesystem entries require a memory mount")}
    end
  end

  defp normalize_seed_dirs(value, _limits) when value in [nil, []], do: {:ok, []}

  defp normalize_seed_dirs(value, limits) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn
      path, {:ok, acc} when is_binary(path) ->
        normalize_seed_dir_path(path, limits, acc)

      %{path: path}, {:ok, acc} ->
        normalize_seed_dir_path(path, limits, acc)

      _other, {:ok, _acc} ->
        {:halt,
         {:error, Hyperlang.Error.new(:manifest, "filesystem seed dirs must contain paths")}}
    end)
    |> case do
      {:ok, dirs} -> {:ok, Enum.reverse(dirs)}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_seed_dirs(_value, _limits),
    do: {:error, Hyperlang.Error.new(:manifest, "filesystem seed dirs must be a list")}

  defp normalize_seed_dir_path(path, limits, acc) do
    case normalize_virtual_path(path, limits) do
      {:ok, path} -> {:cont, {:ok, [path | acc]}}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp normalize_seed_files(value, _limits) when value in [nil, []], do: {:ok, []}

  defp normalize_seed_files(value, limits) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn file, {:ok, acc} ->
      with {:ok, seed} <- normalize_seed_file(file, limits) do
        {:cont, {:ok, [seed | acc]}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_seed_files(_value, _limits),
    do: {:error, Hyperlang.Error.new(:manifest, "filesystem seed files must be a list")}

  defp normalize_seed_file(file, limits) when is_map(file) do
    with {:ok, raw} <-
           normalize_known_key_map(file, [:path, :content, :mode], "filesystem seed file"),
         {:ok, path} <- normalize_virtual_path(get(raw, :path, nil), limits),
         {:ok, content} <- normalize_seed_content(get(raw, :content, <<>>), limits),
         {:ok, mode} <- normalize_seed_mode(get(raw, :mode, 0o644)) do
      {:ok, %{path: path, content: content, mode: mode}}
    end
  end

  defp normalize_seed_file(_file, _limits),
    do: {:error, Hyperlang.Error.new(:manifest, "filesystem seed files must be maps")}

  defp normalize_seed_symlinks(value, _limits) when value in [nil, []], do: {:ok, []}

  defp normalize_seed_symlinks(value, limits) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn link, {:ok, acc} ->
      with {:ok, seed} <- normalize_seed_symlink(link, limits) do
        {:cont, {:ok, [seed | acc]}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, symlinks} -> {:ok, Enum.reverse(symlinks)}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_seed_symlinks(_value, _limits),
    do: {:error, Hyperlang.Error.new(:manifest, "filesystem seed symlinks must be a list")}

  defp normalize_seed_symlink(link, limits) when is_map(link) do
    with {:ok, raw} <-
           normalize_known_key_map(link, [:path, :target, :escape], "filesystem seed symlink"),
         {:ok, path} <- normalize_virtual_path(get(raw, :path, nil), limits),
         {:ok, target} <- normalize_seed_symlink_target(get(raw, :target, nil), limits) do
      {:ok, %{path: path, target: target, escape: truthy?(get(raw, :escape, false))}}
    end
  end

  defp normalize_seed_symlink(_link, _limits),
    do: {:error, Hyperlang.Error.new(:manifest, "filesystem seed symlinks must be maps")}

  defp normalize_seed_symlink_target(nil, _limits), do: {:ok, nil}

  defp normalize_seed_symlink_target(target, limits) when is_binary(target),
    do: normalize_virtual_path(target, limits)

  defp normalize_seed_symlink_target(_target, _limits),
    do: {:error, Hyperlang.Error.new(:manifest, "filesystem seed symlink target must be a path")}

  defp normalize_seed_content(content, limits) do
    case :erlang.iolist_size(content) do
      size when size <= limits.max_single_write_bytes ->
        {:ok, IO.iodata_to_binary(content)}

      _size ->
        {:error, Hyperlang.Error.new(:manifest, "filesystem seed file exceeds write limit")}
    end
  rescue
    ArgumentError ->
      {:error, Hyperlang.Error.new(:manifest, "filesystem seed content must be iodata")}
  end

  defp normalize_seed_mode(mode) do
    mode = to_int(mode)

    if mode >= 0 do
      {:ok, mode}
    else
      {:error, Hyperlang.Error.new(:manifest, "filesystem seed mode must be non-negative")}
    end
  rescue
    ArgumentError ->
      {:error, Hyperlang.Error.new(:manifest, "filesystem seed mode must be an integer")}
  end

  defp normalize_mount_backend(nil, raw, mode) when mode in [:memory],
    do: reject_host_path_for_memory(raw, :memory)

  defp normalize_mount_backend(:memory, raw, _mode), do: reject_host_path_for_memory(raw, :memory)

  defp normalize_mount_backend("memory", raw, _mode),
    do: reject_host_path_for_memory(raw, :memory)

  defp normalize_mount_backend({:host, path}, _raw, _mode), do: canonical_host_backend(path)
  defp normalize_mount_backend({"host", path}, _raw, _mode), do: canonical_host_backend(path)

  defp normalize_mount_backend(%{} = backend, raw, _mode) do
    with {:ok, backend} <-
           normalize_known_key_map(
             backend,
             [:type, :kind, :path],
             "filesystem mount backend"
           ) do
      do_normalize_mount_backend_map(backend, raw)
    end
  end

  defp normalize_mount_backend(nil, raw, _mode) do
    case get(raw, :host_path, nil) do
      nil -> {:error, Hyperlang.Error.new(:manifest, "filesystem mount backend is required")}
      path -> canonical_host_backend(path)
    end
  end

  defp normalize_mount_backend(_backend, _raw, _mode),
    do: {:error, Hyperlang.Error.new(:manifest, "invalid filesystem mount backend")}

  defp do_normalize_mount_backend_map(backend, raw) do
    case get(backend, :type, nil) || get(backend, :kind, nil) do
      :host -> canonical_host_backend(get(backend, :path, nil))
      "host" -> canonical_host_backend(get(backend, :path, nil))
      :memory -> reject_host_path_for_memory(memory_backend_path_map(raw, backend), :memory)
      "memory" -> reject_host_path_for_memory(memory_backend_path_map(raw, backend), :memory)
      _ -> {:error, Hyperlang.Error.new(:manifest, "invalid filesystem mount backend")}
    end
  end

  defp reject_host_path_for_memory(raw, backend) do
    if get(raw, :host_path, nil) do
      {:error,
       Hyperlang.Error.new(:manifest, "memory filesystem mounts must not specify host_path")}
    else
      {:ok, backend}
    end
  end

  defp memory_backend_path_map(raw, backend) do
    if get(raw, :host_path, nil) || get(backend, :path, nil) do
      Map.put(raw, :host_path, get(raw, :host_path, nil) || get(backend, :path, nil))
    else
      raw
    end
  end

  defp canonical_host_backend(path) when is_binary(path) do
    case canonical_host_path(path, 0) do
      {:ok, real_path} ->
        {:ok, {:host, real_path}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp canonical_host_backend(_path),
    do: {:error, Hyperlang.Error.new(:manifest, "host filesystem mount path must be a string")}

  defp canonical_host_path(_path, depth) when depth > 16 do
    {:error, Hyperlang.Error.new(:manifest, "host filesystem mount symlink depth exceeded")}
  end

  defp canonical_host_path(path, depth) do
    expanded = Path.expand(path)
    parts = expanded |> Path.split() |> Enum.reject(&(&1 == "/"))

    canonical_host_path_component("/", parts, depth)
  end

  defp canonical_host_path_component(current, [], _depth) do
    case File.lstat(current) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, current}

      {:ok, _stat} ->
        {:error,
         Hyperlang.Error.new(
           :manifest,
           "host filesystem mount path must be an existing directory"
         )}

      {:error, _reason} ->
        {:error,
         Hyperlang.Error.new(
           :manifest,
           "host filesystem mount path must be an existing directory"
         )}
    end
  end

  defp canonical_host_path_component(current, [part | rest], depth) when depth <= 16 do
    path = Path.join(current, part)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        canonical_host_path_component(path, rest, depth)

      {:ok, %File.Stat{type: :symlink}} ->
        case File.read_link(path) do
          {:ok, target} ->
            target =
              if Path.type(target) == :relative do
                Path.expand(target, Path.dirname(path))
              else
                Path.expand(target)
              end

            target = Enum.reduce(rest, target, fn component, acc -> Path.join(acc, component) end)

            canonical_host_path(target, depth + 1)

          {:error, _reason} ->
            {:error,
             Hyperlang.Error.new(
               :manifest,
               "host filesystem mount path must be an existing directory"
             )}
        end

      {:ok, _stat} ->
        {:error,
         Hyperlang.Error.new(
           :manifest,
           "host filesystem mount path must be an existing directory"
         )}

      {:error, _reason} ->
        {:error,
         Hyperlang.Error.new(
           :manifest,
           "host filesystem mount path must be an existing directory"
         )}
    end
  end

  defp canonical_host_path_component(_current, _parts, _depth) do
    {:error, Hyperlang.Error.new(:manifest, "host filesystem mount symlink depth exceeded")}
  end

  defp validate_mount_backend_mode!(:memory, mode)
       when mode in [:memory, :read_write, :read_only],
       do: :ok

  defp validate_mount_backend_mode!(:memory, :overlay),
    do: raise("overlay filesystem mounts require a canonical host directory")

  defp validate_mount_backend_mode!({:host, _path}, mode)
       when mode in [:read_only, :read_write, :overlay, :snapshot],
       do: :ok

  defp validate_mount_backend_mode!(_backend, _mode),
    do: raise("filesystem mount backend and mode are incompatible")

  defp reject_duplicate_mount(virtual, roots) do
    if MapSet.member?(roots, virtual) do
      {:error,
       Hyperlang.Error.new(:manifest, "duplicate filesystem mount virtual root",
         details: %{virtual: virtual}
       )}
    else
      :ok
    end
  end

  defp overlay_state(:overlay, {:host, _path}), do: :memory
  defp overlay_state(_mode, _backend), do: nil

  defp normalize_virtual_path(path, limits) when is_binary(path) do
    cond do
      byte_size(path) == 0 ->
        {:error, Hyperlang.Error.new(:manifest, "filesystem path must not be empty")}

      byte_size(path) > limits.max_path_bytes ->
        {:error, Hyperlang.Error.new(:manifest, "filesystem path exceeds max_path_bytes")}

      String.contains?(path, <<0>>) ->
        {:error, Hyperlang.Error.new(:manifest, "filesystem path contains null byte")}

      String.contains?(path, "\\") ->
        {:error, Hyperlang.Error.new(:manifest, "filesystem path must use POSIX separators")}

      not String.starts_with?(path, "/") ->
        {:error, Hyperlang.Error.new(:manifest, "filesystem path must be absolute")}

      path != "/" and String.contains?(path, "//") ->
        {:error, Hyperlang.Error.new(:manifest, "filesystem path contains empty components")}

      path != "/" and String.ends_with?(path, "/") ->
        {:error, Hyperlang.Error.new(:manifest, "filesystem path must be normalized")}

      true ->
        parts = String.split(path, "/", trim: true)

        cond do
          Enum.any?(parts, &(&1 in [".", ".."])) ->
            {:error, Hyperlang.Error.new(:manifest, "filesystem path must be normalized")}

          Enum.any?(parts, &(byte_size(&1) > limits.max_component_bytes)) ->
            {:error,
             Hyperlang.Error.new(
               :manifest,
               "filesystem path component exceeds max_component_bytes"
             )}

          true ->
            {:ok, "/" <> Enum.join(parts, "/")}
        end
    end
  end

  defp normalize_virtual_path(_path, _limits),
    do: {:error, Hyperlang.Error.new(:manifest, "filesystem path must be a string")}

  defp normalize_known_key_map(map, allowed_keys, label) when is_map(map) do
    case Map.keys(map) -- allowed_keys do
      [] ->
        {:ok, map}

      [key | _rest] ->
        {:error,
         Hyperlang.Error.new(:manifest, "unknown #{label} key",
           details: %{
             key: key,
             allowed: allowed_keys |> Enum.map(&Atom.to_string/1) |> Enum.sort()
           }
         )}
    end
  end

  # `entry` is the manifest alias for the result root: `entry: %{function:
  # "main"}` runs the exported main/1 per eval. Absent entry (and absent
  # result) keeps expression-program behavior unchanged.
  defp apply_entry_alias(manifest) do
    case get(manifest, :entry, nil) do
      nil ->
        {:ok, manifest}

      entry when is_map(entry) ->
        cond do
          explicit_key?(manifest, :result) ->
            {:error, Hyperlang.Error.new(:manifest, "entry and result are aliases; set only one")}

          true ->
            name = entry |> get(:function, get(entry, :name, nil))

            if is_binary(name) or (is_atom(name) and name not in [nil, true, false]) do
              {:ok, Map.put(manifest, :result, %{name: to_string(name), arity: 1})}
            else
              {:error, Hyperlang.Error.new(:manifest, "entry function must be a name")}
            end
        end

      _other ->
        {:error, Hyperlang.Error.new(:manifest, "entry must be a map")}
    end
  end

  defp get(map, key, default) when is_map(map), do: Map.get(map, key, default)

  defp explicit_key?(map, key) when is_map(map), do: Map.has_key?(map, key)

  defp get_option(options, key, default) when is_map(options), do: get(options, key, default)

  defp get_option(options, key, default) when is_list(options),
    do: Keyword.get(options, key, default)

  defp get_option(_, _, default), do: default

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_binary(value), do: String.to_integer(value)
  defp to_int(value) when is_atom(value), do: value |> Atom.to_string() |> String.to_integer()

  defp truthy?(value), do: value in [true, 1, "true", true]
end
