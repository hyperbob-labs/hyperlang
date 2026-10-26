defmodule Hyperlang.Stdlib do
  @moduledoc false

  @whole_module_reject %{
    "argparse" =>
      "Argparse parses arbitrary option specs and can create VM-global atoms; expose argument parsing as a host import if needed.",
    "beam_lib" => "BEAM code introspection exposes code server and filesystem surfaces.",
    "c" => "Shell helper module exposes compile, filesystem, process, and node authority.",
    "dets" => "DETS opens and mutates host files.",
    "dets_server" => "DETS server internals expose process/file authority.",
    "dets_sup" => "Supervisor internals expose process authority.",
    "dets_utils" => "DETS internals expose file authority.",
    "dets_v9" => "DETS internals expose file authority.",
    "digraph" => "digraph creates ETS-backed mutable graph resources.",
    "digraph_utils" => "digraph_utils operates on digraph resources.",
    "edlin" => "Line editor internals expose shell/terminal behavior.",
    "edlin_context" => "Line editor internals are shell support, not data stdlib.",
    "edlin_expand" => "Line editor expansion inspects modules and shell state.",
    "edlin_key" => "Line editor key handling is shell support.",
    "edlin_type_suggestion" => "Type suggestion inspects modules and shell state.",
    "epp" => "Preprocessor opens files and creates atoms from source.",
    "erl_abstract_code" => "Compiler debug-info support is not guest data stdlib.",
    "erl_anno" => "Compiler annotation helpers are not guest data stdlib.",
    "erl_bits" => "Compiler bit-syntax internals are not guest data stdlib.",
    "erl_compile" => "Compiler entrypoints expose code compilation.",
    "erl_error" => "Compiler/runtime formatter can expose function and stack internals.",
    "erl_eval" => "Evaluator entrypoints execute dynamic code.",
    "erl_expand_records" => "Compiler transform support is not guest data stdlib.",
    "erl_features" => "Feature inspection exposes VM/compiler configuration.",
    "erl_internal" => "Compiler internal predicates are not guest data stdlib.",
    "erl_lint" => "Compiler linter is not guest data stdlib.",
    "erl_parse" => "Parser helpers create atoms from untrusted text.",
    "erl_posix_msg" => "POSIX message helper is OS-facing diagnostics.",
    "erl_pp" => "Pretty-printer operates on compiler forms containing atoms.",
    "erl_scan" => "Scanner creates atoms from untrusted text.",
    "erl_stdlib_errors" => "Internal error formatter is not guest data stdlib.",
    "erl_tar" => "Archive module opens and writes host files.",
    "error_logger_file_h" => "Logger file handler exposes file/process authority.",
    "error_logger_tty_h" => "Logger tty handler exposes terminal/process authority.",
    "escript" => "Escript support parses and executes scripts/files.",
    "ets" => "ETS exposes VM-global mutable tables and references.",
    "eval_bits" => "Evaluator bit-syntax internals are not guest data stdlib.",
    "file_sorter" => "File sorter opens host files.",
    "filelib" => "Filelib queries host filesystem state.",
    "gen" => "OTP behavior internals expose process protocol surfaces.",
    "gen_event" => "OTP behavior module exposes process/event-manager authority.",
    "gen_fsm" => "OTP behavior module exposes process authority.",
    "gen_server" => "OTP behavior module exposes process authority.",
    "gen_statem" => "OTP behavior module exposes process authority.",
    "io_lib_format" =>
      "Internal IO formatting scanner/build module; use allowlisted io_lib formatting APIs instead.",
    "io_lib_fread" =>
      "Internal IO read parser support module; guest input/device parsing is unsupported.",
    "io_lib_pretty" =>
      "Internal IO pretty-printer module; use allowlisted io_lib formatting APIs instead.",
    "io_ansi" =>
      "Raw io_ansi calls initialize terminfo-backed persistent mappings and may consult terminal, environment, or IO-device state; expose deterministic ANSI fallback constructors through a Hyperlang wrapper if needed.",
    "log_mf_h" => "Logger handler exposes file/process authority.",
    "man_docs" => "Documentation generation inspects modules and files.",
    "ms_transform" => "Match-spec transform is compiler support.",
    "otp_internal" => "OTP internal metadata is not guest data stdlib.",
    "peer" => "Peer starts and controls nodes/processes.",
    "pool" => "Pool spawns and manages distributed processes.",
    "proc_lib" => "proc_lib spawns and manages processes.",
    "qlc" => "QLC exposes parse transforms, cursors, and evaluator callbacks.",
    "qlc_pt" => "QLC parse transform is compiler support.",
    "records" =>
      "OTP 29 records creates and inspects the new native record term type, which Hyperlang does not yet sanitize across guest boundaries.",
    "shell" => "Shell exposes interactive process and module state.",
    "shell_default" => "Shell helper exposes compile, filesystem, and process authority.",
    "shell_docs" => "Shell docs inspect modules and documentation.",
    "shell_docs_markdown" => "Shell docs support is not guest data stdlib.",
    "shell_docs_test" => "Shell docs test support is not guest data stdlib.",
    "slave" => "Slave starts distributed nodes.",
    "supervisor" => "Supervisor module exposes process authority.",
    "supervisor_bridge" => "Supervisor bridge exposes process authority.",
    "sys" => "sys inspects and mutates OTP process state.",
    "win32reg" => "Windows registry module exposes OS authority.",
    "zip" => "Zip module opens and writes host files."
  }

  @captured_io %{
    "io" => %{
      "format" => [1, 2, 3],
      "fwrite" => [1, 2, 3],
      "nl" => [0, 1],
      "put_chars" => [1, 2],
      "write" => [1, 2]
    }
  }

  @wrapped_stdlib %{
    "base64" => %{
      "decode" => [1, 2],
      "decode_to_string" => [1, 2],
      "encode" => [1, 2],
      "encode_to_string" => [1, 2],
      "mime_decode" => [1, 2],
      "mime_decode_to_string" => [1, 2]
    },
    "binary" => %{
      "bin_to_list" => [1, 2, 3],
      "copy" => [1, 2],
      "decode_unsigned" => [1, 2],
      "encode_hex" => [1, 2],
      "encode_unsigned" => [1, 2],
      "join" => [2],
      "list_to_bin" => [1],
      "matches" => [2, 3],
      "replace" => [3, 4],
      "split" => [2, 3]
    },
    "erlang" => %{
      "atom_to_binary" => [1, 2],
      "erase" => [0, 1],
      "float_to_binary" => [1, 2],
      "float_to_list" => [1, 2],
      "get" => [0, 1],
      "iolist_to_binary" => [1],
      "list_to_binary" => [1],
      "put" => [2],
      "raise" => [3]
    },
    "calendar" => %{"system_time_to_rfc3339" => [2]},
    "filename" => %{
      "absname" => [2],
      "absname_join" => [2],
      "append" => [2],
      "basename" => [1, 2],
      "dirname" => [1],
      "extension" => [1],
      "flatten" => [1],
      "join" => [1, 2],
      "nativename" => [1],
      "pathtype" => [1],
      "rootname" => [1, 2],
      "split" => [1],
      "validate" => [1]
    },
    "io_lib" => %{
      "bformat" => [2, 3],
      "bfwrite" => [2, 3],
      "build_text" => [1, 2],
      "format" => [2, 3],
      "format_prompt" => [1, 2],
      "fwrite" => [2, 3]
    },
    "lists" => %{"concat" => [1]},
    "re" => %{
      "compile" => [1, 2],
      "replace" => [3, 4],
      "run" => [2, 3],
      "split" => [2, 3]
    },
    "string" => %{
      "casefold" => [1],
      "centre" => [2, 3],
      "chars" => [2, 3],
      "concat" => [2],
      "copies" => [2],
      "join" => [2],
      "lexemes" => [2],
      "left" => [2, 3],
      "lowercase" => [1],
      "pad" => [2, 3, 4],
      "replace" => [3, 4],
      "reverse" => [1],
      "right" => [2, 3],
      "split" => [2, 3],
      "titlecase" => [1],
      "to_graphemes" => [1],
      "to_lower" => [1],
      "to_upper" => [1],
      "tokens" => [2],
      "uppercase" => [1]
    },
    "unicode" => %{
      "characters_to_binary" => [1, 2, 3],
      "characters_to_list" => [1, 2]
    }
  }

  @direct_allow Hyperlang.StdlibAllowlist.direct_allow()
                |> Map.update!("erlang", fn functions ->
                  Map.put(functions, "raise", [3])
                end)

  @callback_stdlib %{
    "array" => %{
      "foldl" => %{3 => [1], 5 => [3]},
      "foldr" => %{3 => [1], 5 => [3]},
      "map" => %{2 => [1]},
      "mapfoldl" => %{3 => [1], 5 => [3]},
      "mapfoldr" => %{3 => [1], 5 => [3]},
      "sparse_foldl" => %{3 => [1], 5 => [3]},
      "sparse_foldr" => %{3 => [1], 5 => [3]},
      "sparse_map" => %{2 => [1]},
      "sparse_mapfoldl" => %{3 => [1], 5 => [3]},
      "sparse_mapfoldr" => %{3 => [1], 5 => [3]}
    },
    "dict" => %{
      "filter" => %{2 => [1]},
      "fold" => %{3 => [1]},
      "map" => %{2 => [1]},
      "merge" => %{3 => [1]},
      "update" => %{3 => [2], 4 => [2]}
    },
    "gb_sets" => %{
      "filter" => %{2 => [1]},
      "filtermap" => %{2 => [1]},
      "fold" => %{3 => [1]},
      "map" => %{2 => [1]}
    },
    "gb_trees" => %{
      "map" => %{2 => [1]}
    },
    "graph" => %{
      "fold_vertices" => %{3 => [2]}
    },
    "lists" => %{
      "all" => %{2 => [1]},
      "any" => %{2 => [1]},
      "dropwhile" => %{2 => [1]},
      "filter" => %{2 => [1]},
      "filtermap" => %{2 => [1]},
      "flatmap" => %{2 => [1]},
      "foldl" => %{3 => [1]},
      "foldr" => %{3 => [1]},
      "foreach" => %{2 => [1]},
      "keymap" => %{3 => [1]},
      "map" => %{2 => [1]},
      "mapfoldl" => %{3 => [1]},
      "mapfoldr" => %{3 => [1]},
      "merge" => %{3 => [1]},
      "partition" => %{2 => [1]},
      "rmerge" => %{3 => [1]},
      "rumerge" => %{3 => [1]},
      "search" => %{2 => [1]},
      "sort" => %{2 => [1]},
      "splitwith" => %{2 => [1]},
      "takewhile" => %{2 => [1]},
      "umerge" => %{3 => [1]},
      "uniq" => %{2 => [1]},
      "usort" => %{2 => [1]},
      "zf" => %{2 => [1]},
      "zipwith" => %{3 => [1], 4 => [1]},
      "zipwith3" => %{4 => [1], 5 => [1]}
    },
    "maps" => %{
      "filter" => %{2 => [1]},
      "filtermap" => %{2 => [1]},
      "fold" => %{3 => [1]},
      "foreach" => %{2 => [1]},
      "groups_from_list" => %{2 => [1], 3 => [1, 2]},
      "intersect_with" => %{3 => [1]},
      "map" => %{2 => [1]},
      "merge_with" => %{3 => [1]},
      "update_with" => %{3 => [2], 4 => [2]}
    },
    "orddict" => %{
      "filter" => %{2 => [1]},
      "fold" => %{3 => [1]},
      "map" => %{2 => [1]},
      "merge" => %{3 => [1]},
      "update" => %{3 => [2], 4 => [2]}
    },
    "ordsets" => %{
      "filter" => %{2 => [1]},
      "filtermap" => %{2 => [1]},
      "fold" => %{3 => [1]},
      "map" => %{2 => [1]}
    },
    "queue" => %{
      "all" => %{2 => [1]},
      "any" => %{2 => [1]},
      "delete_with" => %{2 => [1]},
      "delete_with_r" => %{2 => [1]},
      "filter" => %{2 => [1]},
      "filtermap" => %{2 => [1]},
      "fold" => %{3 => [1]}
    },
    "sets" => %{
      "filter" => %{2 => [1]},
      "filtermap" => %{2 => [1]},
      "fold" => %{3 => [1]},
      "map" => %{2 => [1]}
    },
    "sofs" => %{
      "drestriction" => %{3 => [1]},
      "family_specification" => %{2 => [1]},
      "partition" => %{2 => [1], 3 => [1]},
      "partition_family" => %{2 => [1]},
      "projection" => %{2 => [1]},
      "restriction" => %{3 => [1]},
      "specification" => %{2 => [1]},
      "substitution" => %{2 => [1]}
    }
  }

  @nondeterministic_stdlib %{
    "calendar" => %{
      "iso_week_number" => [0],
      "local_time_to_system_time" => [1, 2],
      "local_time_to_universal_time" => [1, 2],
      "local_time_to_universal_time_dst" => [1],
      "local_time" => [0],
      "now_to_local_time" => [1],
      "system_time_to_local_time" => [2],
      "system_time_to_rfc3339" => [1],
      "universal_time_to_local_time" => [1],
      "universal_time" => [0]
    },
    "erlang" => %{
      "date" => [0],
      "localtime" => [0],
      "localtime_to_universaltime" => [1, 2],
      "monotonic_time" => [0, 1],
      "now" => [0],
      "system_time" => [0, 1],
      "time" => [0],
      "time_offset" => [0, 1],
      "timestamp" => [0],
      "universaltime" => [0],
      "universaltime_to_localtime" => [1]
    },
    "rand" => %{
      "mwc59_seed" => [0]
    }
  }

  # Only non-expanding, deterministic calls bypass Runtime.stdlib/4. Every
  # other admitted direct target remains mediated so its return term is checked
  # at the stdlib boundary before guest code can retain or transform it.
  @codegen_direct_stdlib %{
    "binary" => %{
      "at" => [2],
      "first" => [1],
      "last" => [1],
      "longest_common_prefix" => [1],
      "longest_common_suffix" => [1],
      "match" => [2, 3],
      "part" => [2, 3],
      "referenced_byte_size" => [1]
    },
    "erlang" => %{
      "abs" => [1],
      "bit_size" => [1],
      "byte_size" => [1],
      "ceil" => [1],
      "element" => [2],
      "float" => [1],
      "floor" => [1],
      "hd" => [1],
      "is_atom" => [1],
      "is_binary" => [1],
      "is_bitstring" => [1],
      "is_boolean" => [1],
      "is_float" => [1],
      "is_function" => [1, 2],
      "is_integer" => [1],
      "is_list" => [1],
      "is_map" => [1],
      "is_map_key" => [2],
      "is_number" => [1],
      "is_pid" => [1],
      "is_port" => [1],
      "is_reference" => [1],
      "is_record" => [2, 3],
      "is_tuple" => [1],
      "length" => [1],
      "map_get" => [2],
      "map_size" => [1],
      "max" => [2],
      "min" => [2],
      "phash2" => [1, 2],
      "round" => [1],
      # setelement/3 copies a guest-resident tuple with one guest-resident value
      # replaced: same size, no new term kinds, so it needs no return check.
      "setelement" => [3],
      "size" => [1],
      "tl" => [1],
      "trunc" => [1],
      "tuple_size" => [1]
    },
    "lists" => %{
      "all" => [2],
      "any" => [2],
      "foldl" => [3],
      "foldr" => [3],
      "foreach" => [2],
      "keyfind" => [3],
      "keymember" => [3],
      "keysearch" => [3],
      "last" => [1],
      "max" => [1],
      "member" => [2],
      "min" => [1],
      "nth" => [2],
      "prefix" => [2],
      "search" => [2],
      "suffix" => [2],
      "sum" => [1]
    },
    "maps" => %{
      "find" => [2],
      "get" => [2, 3],
      "is_key" => [2],
      "size" => [1],
      "take" => [2]
    },
    "math" => %{
      "acos" => [1],
      "acosh" => [1],
      "asin" => [1],
      "asinh" => [1],
      "atan" => [1],
      "atan2" => [2],
      "atanh" => [1],
      "ceil" => [1],
      "cos" => [1],
      "cosh" => [1],
      "erf" => [1],
      "erfc" => [1],
      "exp" => [1],
      "floor" => [1],
      "fmod" => [2],
      "log" => [1],
      "log10" => [1],
      "log2" => [1],
      "pi" => [0],
      "pow" => [2],
      "sin" => [1],
      "sinh" => [1],
      "sqrt" => [1],
      "tan" => [1],
      "tanh" => [1],
      "tau" => [0]
    },
    "timer" => %{
      "hms" => [3],
      "hours" => [1],
      "minutes" => [1],
      "now_diff" => [2],
      "seconds" => [1]
    }
  }

  @reserved_authority_modules [
    "auth",
    "file",
    "file_server",
    "prim_file",
    "filelib",
    "code",
    "hyperlang_table",
    "compile",
    "disk_log",
    "disk_log_server",
    "disk_log_sup",
    "erl_epmd",
    "erl_eval",
    "erpc",
    "ftp",
    "gen_sctp",
    "http_uri",
    "httpc",
    "httpc_handler",
    "httpc_handler_sup",
    "httpc_manager",
    "httpc_profile_sup",
    "httpc_request",
    "httpc_response",
    "httpc_sup",
    "os",
    "init",
    "inet",
    "inet6_sctp",
    "inet6_tcp",
    "inet6_tcp_dist",
    "inet6_udp",
    "inet_config",
    "inet_db",
    "inet_dns",
    "inet_gethost_native",
    "inet_hosts",
    "inet_parse",
    "inet_res",
    "inet_sctp",
    "inet_tcp",
    "inet_tcp_dist",
    "inet_udp",
    "gen_tcp",
    "gen_udp",
    "ssl",
    "prim_inet",
    "socket",
    "ets",
    "dets",
    "mnesia",
    "persistent_term",
    "rpc",
    "net_kernel",
    "net",
    "net_adm",
    "net_kernel",
    "net_sup",
    "net_ticker",
    "global",
    "global_group",
    "global_name_server",
    "http_transport",
    "public_key",
    "ssh",
    "ssh_connection",
    "ssh_connection_handler",
    "ssh_sftp",
    "ssh_sftpd",
    "ssh_system_sup",
    "tftp",
    "pg"
  ]

  # Direct-allowlist entries Hyperlang still rejects. Everything outside the
  # allowlist is rejected by default and needs no entry here.
  @specific_reject %{
    "rand" => %{"seed_s" => [1, 2]},
    "unicode" => %{
      "characters_to_binary_int" => [2],
      "characters_to_list_int" => [2],
      "characters_to_nfc_binary" => [1],
      "characters_to_nfc_list" => [1],
      "characters_to_nfd_binary" => [1],
      "characters_to_nfd_list" => [1],
      "characters_to_nfkc_binary" => [1],
      "characters_to_nfkc_list" => [1],
      "characters_to_nfkd_binary" => [1],
      "characters_to_nfkd_list" => [1]
    },
    "unicode_util" => %{
      "casefold" => [1],
      "lowercase" => [1],
      "nfc" => [1],
      "nfd" => [1],
      "nfkc" => [1],
      "nfkd" => [1],
      "titlecase" => [1],
      "uppercase" => [1]
    },
    "zstd" => %{"compress" => [1, 2], "decompress" => [1, 2]}
  }

  def otp_release, do: Hyperlang.StdlibAllowlist.otp_release()
  def runtime_otp_release, do: Hyperlang.StdlibAllowlist.runtime_otp_release()
  def supported_otp_release?, do: Hyperlang.StdlibAllowlist.supported_otp_release?()
  def ensure_supported_otp!, do: Hyperlang.StdlibAllowlist.ensure_supported_otp!()

  def allowed?(manifest, module, function, arity) do
    case call_target(module, function, arity) do
      :error ->
        false

      {:captured_io, _, _} ->
        enabled_profile?(manifest, "io") and
          nondeterminism_allowed?(manifest, module, function, arity)

      {:wrapped, mod, _fun} ->
        enabled_profile?(manifest, Atom.to_string(mod)) and
          nondeterminism_allowed?(manifest, module, function, arity)

      {:direct, mod, _fun} ->
        enabled_profile?(manifest, Atom.to_string(mod)) and
          nondeterminism_allowed?(manifest, module, function, arity)
    end
  end

  def call_target(module, function, arity) do
    ensure_supported_otp!()

    module = to_string(module)
    function = to_string(function)

    cond do
      captured_io?(module, function, arity) ->
        {:captured_io, target_atom(module), target_atom(function)}

      wrapped?(module, function, arity) ->
        {:wrapped, target_atom(module), target_atom(function)}

      direct_allowed?(module, function, arity) ->
        {:direct, target_atom(module), target_atom(function)}

      true ->
        :error
    end
  end

  @direct_runtime_specs (for {module, functions} <- @direct_allow,
                             {function, arities} <- functions,
                             arity <- arities,
                             arity not in (get_in(@captured_io, [module, function]) || []),
                             arity not in (get_in(@wrapped_stdlib, [module, function]) || []),
                             arity not in (get_in(@specific_reject, [module, function]) || []) do
                           {module, function, arity, :direct}
                         end)

  @wrapped_runtime_specs (for {module, functions} <- @wrapped_stdlib,
                              {function, arities} <- functions,
                              arity <- arities do
                            {module, function, arity, :wrapped}
                          end)

  @runtime_specs @direct_runtime_specs ++ @wrapped_runtime_specs

  for {module, function, arity, kind} <- @runtime_specs do
    callback_args = get_in(@callback_stdlib, [module, function, arity]) || []

    behaviour =
      cond do
        kind == :wrapped -> :bounded_wrapper
        callback_args != [] -> :callback_intrinsic
        true -> :intrinsic
      end

    nondeterministic? = arity in (get_in(@nondeterministic_stdlib, [module, function]) || [])
    module_atom = String.to_atom(module)
    function_atom = String.to_atom(function)

    def runtime_spec(unquote(module_atom), unquote(function_atom), unquote(arity)) do
      {:ok, unquote(behaviour), unquote(callback_args), unquote(module_atom),
       unquote(nondeterministic?)}
    end
  end

  def runtime_spec(_module, _function, _arity), do: :error

  def direct_matrix do
    @direct_allow
    |> subtract_matrix(@captured_io)
    |> subtract_matrix(@wrapped_stdlib)
    |> subtract_matrix(@specific_reject)
  end

  def captured_matrix, do: @captured_io
  def wrapped_matrix, do: @wrapped_stdlib

  def generated_call_allowed?(:erlang, :get, 1), do: true
  def generated_call_allowed?(:erlang, :put, 2), do: true
  def generated_call_allowed?(:erlang, :erase, 1), do: true
  def generated_call_allowed?(:erlang, :error, 1), do: true
  # The explicit `function_clause` fallback of generated functions and funs.
  def generated_call_allowed?(:erlang, :error, 2), do: true
  def generated_call_allowed?(:erlang, :is_map, 1), do: true
  def generated_call_allowed?(:erlang, :map_get, 2), do: true
  def generated_call_allowed?(:erlang, :map_size, 1), do: true
  def generated_call_allowed?(:maps, :remove, 2), do: true

  # The runtime surfaces codegen lowers guest constructs onto: native messaging,
  # the table service and behaviour-callback dispatch. This is the whole
  # generated-call gate — codegen queries it, it keeps no list of its own.
  def generated_call_allowed?(:hyperlang_msg, function, arity),
    do:
      {function, arity} in [
        send: 2,
        receive_wait: 3,
        receive_select: 2,
        exit: 2,
        send_after: 3,
        start_timer: 3,
        cancel_timer: 1,
        read_timer: 1,
        spawn: 1,
        spawn_link: 1,
        spawn_monitor: 1,
        register: 2,
        whereis: 1,
        unregister: 1,
        monitor: 1,
        make_ref: 0,
        is_process_alive: 1,
        process_info_links: 0,
        demonitor: 1,
        demonitor: 2,
        link: 1,
        unlink: 1,
        process_flag: 2
      ]

  def generated_call_allowed?(Hyperlang.Table, :dispatch, 3), do: true
  def generated_call_allowed?(Hyperlang.Callback, :dispatch, 3), do: true

  def generated_call_allowed?(Hyperlang.Runtime, function, arity),
    do:
      {function, arity} in [
        new_context: 3,
        entry_input: 2,
        export_args: 3,
        safe_export: 2,
        import: 3,
        capture_io: 3,
        finish_output: 2,
        apply_guest_fun: 3,
        filesystem: 3,
        loader: 3,
        code: 3,
        module_call: 4,
        behaviour_callback: 4,
        unicode_characters_to_binary: 2,
        unicode_characters_to_binary: 3,
        unicode_characters_to_binary: 4,
        unicode_characters_to_list: 2,
        unicode_characters_to_list: 3,
        binary_copy: 2,
        binary_copy: 3,
        binary_split: 3,
        binary_split: 4,
        binary_matches: 3,
        binary_matches: 4,
        iolist_to_binary: 2,
        rune_len: 2,
        rune_at: 3,
        rune_tail: 3,
        rune_slice: 4,
        guest_dictionary_get_all: 1,
        guest_dictionary_store_dependencies: 3,
        guest_dictionary_delete_dependencies: 2,
        guest_dictionary_erase_all: 1,
        stdlib: 4,
        dynamic_apply_stdlib: 4
      ]

  def generated_call_allowed?(Hyperlang.Sys, :newchan, 3), do: true

  def generated_call_allowed?(Hyperlang.Sys, function, arity),
    do:
      Hyperlang.Sys.supported_sys_mfas()
      |> Enum.any?(fn {_module, supported_function, supported_arity} ->
        Atom.to_string(function) == supported_function and arity == supported_arity + 1
      end)

  # Direct stdlib calls: codegen emits only the @codegen_direct_stdlib set
  # outside guards, and erlang guard BIFs inside guards.
  def generated_call_allowed?(module, function, arity) when is_atom(module) do
    direct_codegen_allowed?(module, function, arity) or
      (module == :erlang and :erl_internal.guard_bif(function, arity) and
         direct_stdlib?("erlang", Atom.to_string(function), arity))
  end

  def generated_call_allowed?(_module, _function, _arity), do: false

  def direct_codegen_allowed?(module, function, arity) do
    module_name = to_string(module)
    function_name = to_string(function)

    arity in (get_in(@codegen_direct_stdlib, [module_name, function_name]) || []) and
      direct_stdlib?(module_name, function_name, arity)
  end

  defp direct_stdlib?(module_name, function_name, arity) do
    direct_allowed?(module_name, function_name, arity) and
      not captured_io?(module_name, function_name, arity) and
      not wrapped?(module_name, function_name, arity) and
      not nondeterministic?(module_name, function_name, arity)
  end

  defp direct_allowed?(module, function, arity),
    do:
      arity in (get_in(@direct_allow, [module, function]) || []) and
        not specific_reject?(module, function, arity)

  defp specific_reject?(module, function, arity),
    do: arity in (get_in(@specific_reject, [module, function]) || [])

  defp target_atom(name), do: String.to_atom(name)

  defp captured_io?(module, function, arity),
    do: arity in (get_in(@captured_io, [module, function]) || [])

  defp wrapped?(module, function, arity),
    do: arity in (get_in(@wrapped_stdlib, [module, function]) || [])

  def nondeterministic?(module, function, arity) do
    module = to_string(module)
    function = to_string(function)

    arity in (get_in(@nondeterministic_stdlib, [module, function]) || [])
  end

  def reserved_import_module?(module) do
    module = to_string(module)

    module in reserved_import_modules()
  end

  def reserved_import_modules do
    Map.keys(@direct_allow)
    |> Kernel.++(@reserved_authority_modules)
    |> Kernel.++(Map.keys(@whole_module_reject))
    |> Kernel.++(Map.keys(@specific_reject))
    |> Kernel.++(Map.keys(@captured_io))
    |> Kernel.++(Map.keys(@wrapped_stdlib))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp nondeterminism_allowed?(manifest, module, function, arity) do
    not nondeterministic?(module, function, arity) or
      Hyperlang.Manifest.nondeterminism_enabled?(manifest)
  end

  defp enabled_profile?(manifest, "erlang"),
    do: truthy?(manifest.stdlib[:erlang] || manifest.stdlib["erlang"])

  defp enabled_profile?(manifest, module) do
    case existing_module_key(module) do
      {:ok, key} -> truthy?(manifest.stdlib[key] || manifest.stdlib[module])
      :error -> truthy?(manifest.stdlib[module])
    end
  end

  defp truthy?(value), do: value == true

  defp subtract_matrix(matrix, remove) do
    Enum.reduce(remove, matrix, fn {module, functions}, matrix ->
      Enum.reduce(functions, matrix, fn {function, arities}, matrix ->
        case get_in(matrix, [module, function]) do
          nil -> matrix
          existing -> put_in(matrix, [module, function], existing -- arities)
        end
      end)
    end)
    |> prune_empty_matrix()
  end

  defp prune_empty_matrix(matrix) do
    Enum.reduce(matrix, %{}, fn {module, functions}, acc ->
      functions =
        functions
        |> Enum.reject(fn {_function, arities} -> arities in [nil, []] end)
        |> Map.new()

      if map_size(functions) == 0 do
        acc
      else
        Map.put(acc, module, functions)
      end
    end)
  end

  defp existing_module_key(module) do
    {:ok, String.to_existing_atom(module)}
  rescue
    ArgumentError -> :error
  end
end
