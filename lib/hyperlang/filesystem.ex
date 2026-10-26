defmodule Hyperlang.Filesystem do
  @moduledoc false

  alias Hyperlang.Filesystem.OtpFacade

  defmodule Handle do
    @moduledoc false
    @type t :: %__MODULE__{id: reference(), owned?: boolean()}

    defstruct [:id, owned?: true]
  end

  @guest_handle_registry :hyperlang_guest_file_handles
  @max_path_arg_codepoints 65_536

  @resolver_modes %{
    read_file: :read_existing_follow_final,
    read_file_info: :stat_existing_follow_final,
    read_link_info: :lstat_existing_no_follow_final,
    write_file: :create_parent_no_follow,
    delete: :delete_parent_no_follow,
    list_dir: :list_names_only,
    rename: :rename_source_lstat,
    make_dir: :recursive_mkdir_checked_ancestors
  }

  @wildcard_bridge Hyperlang.Filesystem.WildcardBridge

  @file_calls %{
    {"file", "consult", 1} => :consult,
    {"file", "path_consult", 2} => :path_consult,
    {"file", "read_file", 1} => :read_file,
    {"file", "write_file", 2} => :write_file,
    {"file", "write_file", 3} => :write_file,
    {"file", "list_dir", 1} => :list_dir,
    {"file", "make_dir", 1} => :make_dir,
    {"file", "del_dir", 1} => :del_dir,
    {"file", "delete", 1} => :delete,
    {"file", "rename", 2} => :rename,
    {"file", "read_file_info", 1} => :read_file_info,
    {"file", "read_link_info", 1} => :read_link_info,
    {"file", "get_cwd", 0} => :get_cwd,
    {"file", "get_cwd", 1} => :get_cwd,
    {"file", "set_cwd", 1} => :set_cwd
  }

  @file_handle_calls %{
    {"file", "open", 2} => :open,
    {"file", "close", 1} => :close,
    {"file", "read", 2} => :handle_read,
    {"file", "write", 2} => :handle_write
  }

  @filelib_calls %{
    {"filelib", "is_file", 1} => :is_file,
    {"filelib", "is_dir", 1} => :is_dir,
    {"filelib", "ensure_dir", 1} => :ensure_dir,
    {"filelib", "wildcard", 1} => :wildcard,
    {"filelib", "wildcard", 2} => :wildcard,
    {"filelib", "wildcard", 3} => :wildcard
  }

  # The three MFA maps above are the single source for the supported
  # `file:`/`filelib:` surface: the classifier resolves calls through them, the
  # codegen lowers the operation atom they yield, and docs/tests read this list.
  def supported_mfas do
    (Map.keys(@file_calls) ++
       Map.keys(@file_handle_calls) ++
       Map.keys(@filelib_calls) ++
       Hyperlang.Sys.supported_sys_mfas())
    |> Enum.sort()
  end

  def call_target(%{sys: sys} = manifest, "sys" = module, function, arity) do
    if sys_enabled?(sys) and sys_nondeterminism_allowed?(manifest, function, arity),
      do: Hyperlang.Sys.call_target(module, function, arity),
      else: :error
  end

  def call_target(%{filesystem: filesystem}, module, function, arity),
    do: call_target(filesystem, module, function, arity)

  def call_target(%{enabled: true} = filesystem, module, function, arity) do
    cond do
      filesystem.file_compat and file_call_enabled?(filesystem, module, function, arity) ->
        Map.fetch!(@file_calls, {module, function, arity})

      filesystem.file_compat and filesystem.handle_compat and
          Map.has_key?(@file_handle_calls, {module, function, arity}) ->
        Map.fetch!(@file_handle_calls, {module, function, arity})

      filesystem.filelib_compat and Map.has_key?(@filelib_calls, {module, function, arity}) ->
        Map.fetch!(@filelib_calls, {module, function, arity})

      true ->
        :error
    end
  end

  def call_target(_filesystem, _module, _function, _arity), do: :error

  defp file_call_enabled?(filesystem, module, function, arity) do
    Map.has_key?(@file_calls, {module, function, arity}) and
      (not loader_file_call?(module, function, arity) or filesystem.loader_compat)
  end

  defp loader_file_call?("file", function, arity),
    do: {function, arity} in [{"consult", 1}, {"path_consult", 2}]

  defp loader_file_call?(_module, _function, _arity), do: false

  def call_diagnostic(%{sys: sys} = manifest, "sys" = module, function, arity) do
    cond do
      call_target(manifest, module, function, arity) != :error ->
        nil

      sys_enabled?(sys) and not sys_nondeterminism_allowed?(manifest, function, arity) ->
        filesystem_call_error(
          module,
          function,
          arity,
          :nondeterminism_disabled,
          "reads a live clock and requires capabilities.nondeterminism"
        )

      # There is no `sys:spawn` (Inferno's real Sys has no spawn; Limbo
      # `spawn f(args)` is a Dis language statement). Reject such call sites at COMPILE time with a message that
      # points at the native replacement, rather than letting them fall through to
      # the generic "unsupported Sys call" error.
      function == "spawn" and arity in [2, 3] ->
        filesystem_call_error(
          module,
          function,
          arity,
          :sys_spawn_removed,
          "sys:spawn is not a Sys call — use the native spawn(fun() -> f(args) end) profile"
        )

      Hyperlang.Sys.known_call?(module, function, arity) and not sys_enabled?(sys) ->
        filesystem_call_error(
          module,
          function,
          arity,
          :sys_disabled,
          "Sys is disabled"
        )

      true ->
        filesystem_call_error(
          module,
          function,
          arity,
          :unsupported_sys_mfa,
          "Sys call is not supported by Hyperlang"
        )
    end
  end

  def call_diagnostic(%{filesystem: filesystem}, module, function, arity),
    do: call_diagnostic(filesystem, module, function, arity)

  def call_diagnostic(%{enabled: true} = filesystem, module, function, arity)
      when module in ["file", "filelib"] do
    call = {module, function, arity}

    cond do
      call_target(filesystem, module, function, arity) != :error ->
        nil

      module == "file" and Map.has_key?(@file_handle_calls, call) and
          not filesystem.handle_compat ->
        filesystem_call_error(
          module,
          function,
          arity,
          :handle_compat_disabled,
          "standard Erlang file handle compatibility is disabled; use file:read_file/1, file:write_file/2, or enable filesystem handle compatibility"
        )

      module == "file" and Map.has_key?(@file_calls, call) and
        loader_file_call?(module, function, arity) and not filesystem.loader_compat ->
        filesystem_call_error(
          module,
          function,
          arity,
          :loader_compat_disabled,
          "standard Erlang loader/evaluator compatibility is disabled"
        )

      module == "file" and Map.has_key?(@file_calls, call) and not filesystem.file_compat ->
        filesystem_call_error(
          module,
          function,
          arity,
          :file_compat_disabled,
          "standard Erlang file compatibility is disabled"
        )

      module == "filelib" and Map.has_key?(@filelib_calls, call) and not filesystem.filelib_compat ->
        filesystem_call_error(
          module,
          function,
          arity,
          :filelib_compat_disabled,
          "standard Erlang filelib compatibility is disabled"
        )

      module == "file" ->
        filesystem_call_error(
          module,
          function,
          arity,
          :unsupported_filesystem_mfa,
          "standard Erlang filesystem call is not supported by Hyperlang"
        )

      module == "filelib" ->
        filesystem_call_error(
          module,
          function,
          arity,
          :unsupported_filesystem_mfa,
          "standard Erlang filelib call is not supported by Hyperlang"
        )
    end
  end

  def call_diagnostic(_filesystem, module, function, arity) when module in ["file", "filelib"] do
    filesystem_call_error(
      module,
      function,
      arity,
      :filesystem_disabled,
      "standard Erlang filesystem compatibility is disabled"
    )
  end

  def call_diagnostic(_filesystem, _module, _function, _arity), do: nil

  defp sys_enabled?(%{enabled: enabled}), do: enabled == true
  defp sys_enabled?(_sys), do: false

  defp sys_nondeterminism_allowed?(manifest, function, arity),
    do:
      not Hyperlang.Sys.nondeterministic_call?(function, arity) or
        Hyperlang.Manifest.nondeterminism_enabled?(manifest)

  def reason_diagnostic(reason) when is_atom(reason) do
    {kind, message} =
      case reason do
        :enoent ->
          {:not_found, "filesystem path was not found or no mount matched"}

        :eacces ->
          {:permission_denied, "filesystem mount permission denied"}

        :eisdir ->
          {:type_mismatch, "filesystem path is a directory"}

        :enotdir ->
          {:type_mismatch, "filesystem path is not a directory"}

        :eexist ->
          {:existing_path, "filesystem path already exists"}

        :erofs ->
          {:read_only_mount, "filesystem mount is read-only"}

        :enotempty ->
          {:non_empty_directory, "filesystem directory is not empty"}

        :exdev ->
          {:cross_mount_rename, "filesystem rename crosses mount boundary"}

        :enametoolong ->
          {:path_too_long, "filesystem path exceeds configured limit"}

        :invalid_path ->
          {:invalid_path, "filesystem path is invalid"}

        :einval ->
          {:invalid_operation, "filesystem operation is invalid for this path"}

        :enospc ->
          {:quota_failure, "filesystem quota would be exceeded"}

        :eoverflow ->
          {:quota_failure, "filesystem result would exceed configured limit"}

        :enotsup ->
          {:unsupported_mount_operation,
           "filesystem mount backend does not support this operation"}

        _ ->
          {:filesystem_error, "filesystem operation failed"}
      end

    Hyperlang.Error.new(:filesystem, message, details: %{reason: reason, kind: kind})
  end

  def reason_diagnostic(_reason) do
    Hyperlang.Error.new(:filesystem, "filesystem operation failed",
      details: %{reason: :unsafe_error_term, kind: :filesystem_error}
    )
  end

  def start(filesystem, opts \\ []) when is_map(filesystem) do
    id = make_ref()

    with {:ok, pid} <- start_server(filesystem, opts) do
      register_handle(id, pid)
      {:ok, %Handle{id: id, owned?: Keyword.get(opts, :owned?, true)}}
    end
  end

  def attach(%Handle{} = handle) do
    case server_info(handle) do
      {:ok, _info} -> {:ok, %{handle | owned?: false}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Deregistration has one owner: the registry's DOWN monitor. Stopping the
  # server is enough — nothing here unregisters the handle as well.
  def stop(%Handle{} = handle) do
    with {:ok, pid} <- lookup_handle(handle) do
      GenServer.stop(pid, :normal)
    else
      {:error, _reason} -> :ok
    end
  end

  def read_file(handle, path), do: path_request(handle, :read_file, path)
  def source_read_file(handle, path), do: path_request(handle, :source_read_file, path)

  def seed(%Handle{} = handle, entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, :ok}, fn entry, {:ok, :ok} ->
      case seed(handle, entry) do
        {:ok, :ok} -> {:cont, {:ok, :ok}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def seed(%Handle{} = handle, %{path: path, type: type}) when type in [:dir, :directory],
    do: seed_dir(handle, path)

  def seed(%Handle{} = handle, %{"path" => path, "type" => type})
      when type in ["dir", "directory"],
      do: seed_dir(handle, path)

  def seed(%Handle{} = handle, %{path: path, content: content}), do: seed(handle, path, content)

  def seed(%Handle{} = handle, %{"path" => path, "content" => content}),
    do: seed(handle, path, content)

  def seed(%Handle{} = handle, path, content) do
    with {:ok, path} <- path_arg(path),
         {:ok, _size} <- iodata_size(content) do
      request(handle, {:seed_file, path, content})
    end
  end

  def seed_dir(%Handle{} = handle, path) do
    with {:ok, path} <- path_arg(path) do
      request(handle, {:seed_dir, path})
    end
  end

  def write_file(%Handle{} = handle, path, content) do
    with {:ok, path} <- path_arg(path),
         {:ok, size} <- iodata_size(content),
         {:ok, limit} <- request(handle, {:write_limit, path}),
         :ok <- check_iodata_limit(size, limit) do
      request(handle, {:write_file, path, content})
    end
  end

  def list_dir(handle, path), do: path_request(handle, :list_dir, path)
  def make_dir(handle, path), do: path_request(handle, :make_dir, path)
  def ensure_dir(handle, path), do: path_request(handle, :ensure_dir, path)
  def del_dir(handle, path), do: path_request(handle, :del_dir, path)
  def delete(handle, path), do: path_request(handle, :delete, path)
  def stat(handle, path), do: path_request(handle, :stat, path)
  def link_stat(handle, path), do: path_request(handle, :link_stat, path)
  def rename(handle, from, to), do: two_path_request(handle, :rename, from, to)
  def limits(handle), do: request(handle, :limits)
  def tree(handle), do: request(handle, :tree)
  def snapshot(handle), do: request(handle, :snapshot)
  def export(handle, opts \\ [])

  def export(handle, opts) when is_list(opts) do
    with {:ok, exported} <- request(handle, :export) do
      case Keyword.fetch(opts, :materialize_to) do
        {:ok, root} -> materialize_export(exported, root)
        :error -> {:ok, exported}
      end
    end
  end

  def server_info(handle), do: request(handle, :server_info)
  def inject_stale_reply(handle, request_id), do: request(handle, {:stale_reply, request_id})

  def close_call_handles(handle, call_id) when is_integer(call_id),
    do: request(handle, {:close_call_handles, call_id})

  def close_call_handles(_handle, _call_id), do: {:error, :missing_call_id}

  def begin_eval(handle, call_id, owner_pid \\ nil)

  def begin_eval(handle, call_id, owner_pid) when is_integer(call_id),
    do: request(handle, {:begin_eval, call_id, owner_pid})

  def begin_eval(_handle, _call_id, _owner_pid), do: {:error, :missing_call_id}

  def finish_eval(handle, call_id, outcome) when is_integer(call_id),
    do: request(handle, {:finish_eval, call_id, outcome})

  def finish_eval(_handle, _call_id, _outcome), do: {:error, :missing_call_id}
  def diff(handle), do: request(handle, :diff)
  def commit(handle), do: request(handle, :commit)
  def rollback(handle), do: request(handle, :rollback)

  # dispatch/3 serves only the operations that carry no per-call transaction:
  # the filelib predicates and wildcard, which read through the same server but
  # write nothing. Every mutating and cwd-bearing operation goes through
  # dispatch/4, which runs inside the caller's eval transaction.
  def dispatch(handle, :is_file, [path]), do: filelib_predicate(handle, path, :is_file)
  def dispatch(handle, :is_dir, [path]), do: filelib_predicate(handle, path, :is_dir)

  def dispatch(handle, :ensure_dir, [path]),
    do: OtpFacade.status_reply(ensure_dir_request(handle, path))

  def dispatch(handle, :wildcard, [pattern]), do: filelib_wildcard(handle, pattern)
  def dispatch(handle, :wildcard, [pattern, cwd]), do: filelib_wildcard(handle, pattern, cwd)

  def dispatch(handle, :wildcard, [pattern, cwd, mod]),
    do: filelib_wildcard(handle, pattern, cwd, mod)

  def dispatch(_handle, operation, args),
    do: {:error, {:unsupported_filesystem_call, operation, length(args)}}

  def dispatch(handle, :read_file, [path], ctx),
    do: eval_otp_reply(handle, ctx, {:read_file, path})

  def dispatch(handle, :consult, [path], ctx), do: eval_consult_reply(handle, ctx, path)

  def dispatch(handle, :path_consult, [path, file], ctx),
    do: eval_path_consult_reply(handle, ctx, path, file)

  def dispatch(handle, :write_file, [path, content], ctx),
    do: eval_status_reply(handle, ctx, {:write_file, path, content})

  def dispatch(handle, :write_file, [path, content, modes], ctx) do
    case OtpFacade.write_operation(modes) do
      {:ok, :write} -> eval_status_reply(handle, ctx, {:write_file, path, content})
      {:ok, :append} -> eval_status_reply(handle, ctx, {:append_file, path, content})
      {:ok, :exclusive} -> eval_status_reply(handle, ctx, {:exclusive_write_file, path, content})
      {:error, reason} -> {:ok, {:error, reason}}
    end
  end

  def dispatch(handle, :list_dir, [path], ctx),
    do: eval_list_dir_reply(handle, ctx, {:list_dir, path})

  def dispatch(handle, :make_dir, [path], ctx),
    do: eval_status_reply(handle, ctx, {:make_dir, path})

  def dispatch(handle, :del_dir, [path], ctx),
    do: eval_status_reply(handle, ctx, {:del_dir, path})

  def dispatch(handle, :delete, [path], ctx), do: eval_status_reply(handle, ctx, {:delete, path})

  def dispatch(handle, :read_file_info, [path], ctx),
    do: eval_file_info_reply(handle, ctx, {:stat, path})

  def dispatch(handle, :read_link_info, [path], ctx),
    do: eval_file_info_reply(handle, ctx, {:link_stat, path})

  def dispatch(handle, :rename, [from, to], ctx),
    do: eval_status_reply(handle, ctx, {:rename, from, to})

  def dispatch(handle, :get_cwd, [], ctx), do: eval_get_cwd_reply(handle, ctx)
  def dispatch(handle, :get_cwd, [drive], _ctx), do: get_cwd_drive_reply(handle, drive)

  def dispatch(handle, :set_cwd, [path], ctx),
    do: eval_status_reply(handle, ctx, {:set_cwd, path})

  def dispatch(handle, :open, [path, modes], ctx),
    do: OtpFacade.open_reply(open_request(handle, path, modes, ctx))

  def dispatch(handle, :close, [io], ctx),
    do: OtpFacade.status_reply(handle_close_request(handle, io, ctx))

  def dispatch(handle, :handle_read, [io, count], ctx),
    do: OtpFacade.otp_or_atom_reply(handle_read_request(handle, io, count, ctx))

  def dispatch(handle, :handle_write, [io, content], ctx),
    do: OtpFacade.status_reply(handle_write_request(handle, io, content, ctx))

  def dispatch(handle, operation, args, _ctx), do: dispatch(handle, operation, args)

  def make_guest_handle, do: make_guest_handle(:manual)

  def make_guest_handle(call_id) do
    handle = make_ref()
    :ets.insert(@guest_handle_registry, {handle, call_id})
    handle
  end

  # The single guest-file-handle boundary predicate. A guest handle is minted
  # either by the own VFS server (the ETS registry below) or by the host
  # backend (worker-local fd metadata); both are opaque references the term
  # boundary must let through, so one predicate answers for both.
  def guest_handle?(value) when is_reference(value) do
    :ets.member(@guest_handle_registry, value) or
      Hyperlang.Filesystem.HostBackend.guest_handle?(value)
  end

  def guest_handle?(_value), do: false

  def release_guest_handles(call_id) do
    :ets.match_delete(@guest_handle_registry, {:"$1", call_id})
    :ok
  end

  # The guest-handle table is created once at application start and owned by
  # the application master, so it outlives every server, worker and registry
  # restart. There is no lazy creation path.
  def create_guest_handle_registry do
    :ets.new(@guest_handle_registry, [:named_table, :public, read_concurrency: true])
  end

  def file_info_tuple(%{type: _type, size: _size, mode: _mode} = stat),
    do: OtpFacade.file_info_tuple(stat)

  def cwd(%{cwd: cwd}), do: {:ok, cwd}

  def cwd(_filesystem),
    do:
      {:error,
       Hyperlang.Error.new(:filesystem, "invalid filesystem cwd",
         details: %{reason: :invalid_path}
       )}

  def set_cwd(%{} = filesystem, path) do
    with {:ok, cwd} <- normalize_request_path(filesystem, path) do
      {:ok, %{filesystem | cwd: cwd}}
    end
  end

  def resolver_mode_for(operation) do
    case Map.fetch(@resolver_modes, operation) do
      {:ok, mode} ->
        {:ok, mode}

      :error ->
        {:error,
         Hyperlang.Error.new(:filesystem, "unsupported filesystem resolver operation",
           details: %{operation: operation, reason: :einval}
         )}
    end
  end

  def operation_resolver_modes, do: @resolver_modes

  def resolve_mount(%{mounts: mounts, limits: _limits} = filesystem, path)
      when is_list(mounts) and is_binary(path) do
    with {:ok, path} <- normalize_request_path(filesystem, path),
         {:ok, mount} <- longest_prefix_mount(mounts, path) do
      {:ok,
       %{
         mount: mount,
         path: path,
         relative_path: relative_path(mount.virtual, path)
       }}
    end
  end

  def resolve_mount(_filesystem, _path),
    do:
      {:error,
       Hyperlang.Error.new(:filesystem, "invalid filesystem mount table",
         details: %{reason: :invalid_path}
       )}

  def resolve_operation(filesystem, path, operation) do
    with {:ok, mode} <- resolver_mode_for(operation),
         {:ok, resolved} <- resolve_mount(filesystem, path) do
      {:ok, Map.put(resolved, :resolver_mode, mode)}
    end
  end

  def authorize_data_operation(filesystem, path, operation) do
    authorize(filesystem, path, operation)
  end

  def authorize_source_compile_read(filesystem, path) do
    authorize(filesystem, path, :read)
  end

  def authorize(filesystem, path, operation, opts \\ []) do
    with {:ok, resolved} <- resolve_mount(filesystem, path),
         :ok <- authorize_permission(resolved.mount, operation, opts) do
      {:ok, Map.put(resolved, :operation, operation)}
    end
  end

  defp request(%Handle{} = handle, request) do
    with {:ok, pid} <- lookup_handle(handle) do
      GenServer.call(pid, {:filesystem_request, make_ref(), request})
    end
  end

  defp eval_request(handle, ctx, request) do
    with {:ok, call_id} <- call_id(ctx) do
      request(handle, {:eval_request, call_id, request})
    end
  end

  defp eval_otp_reply(handle, ctx, {operation, path}) do
    case path_arg(path) do
      {:ok, path} -> OtpFacade.otp_reply(eval_request(handle, ctx, {operation, path}))
      {:error, reason} -> OtpFacade.otp_reply({:error, reason})
    end
  end

  defp eval_consult_reply(handle, ctx, path) do
    with {:ok, path} <- path_arg(path),
         {:ok, source} <- eval_request(handle, ctx, {:read_file, path}),
         {:ok, terms} <- Hyperlang.Consult.parse(source, ctx) do
      {:ok, {:ok, terms}}
    else
      {:error, reason} when is_atom(reason) -> {:ok, {:error, reason}}
      {:error, %Hyperlang.Error{}} -> {:ok, {:error, :badarg}}
      {:error, %{category: _category}} -> {:ok, {:error, :badarg}}
      {:error, _reason} -> {:ok, {:error, :badarg}}
    end
  end

  defp eval_path_consult_reply(handle, ctx, path, file) do
    with {:ok, dirs} <- path_list_arg(path),
         {:ok, file} <- path_arg(file) do
      path_consult_dirs(handle, ctx, dirs, file)
    else
      {:error, reason} when is_atom(reason) -> {:ok, {:error, reason}}
      {:error, _reason} -> {:ok, {:error, :badarg}}
    end
  end

  defp path_consult_dirs(_handle, _ctx, [], _file), do: {:ok, {:error, :enoent}}

  defp path_consult_dirs(handle, ctx, [dir | rest], file) do
    candidate = path_join(dir, file)

    case eval_consult_reply(handle, ctx, candidate) do
      {:ok, {:ok, terms}} ->
        {:ok, {:ok, terms, String.to_charlist(candidate)}}

      {:ok, {:error, reason}} when reason in [:enoent, :enotdir] ->
        path_consult_dirs(handle, ctx, rest, file)

      {:ok, {:error, reason}} ->
        {:ok, {:error, reason}}
    end
  end

  defp eval_status_reply(handle, ctx, {operation, path}) do
    case path_arg(path) do
      {:ok, path} -> OtpFacade.status_reply(eval_request(handle, ctx, {operation, path}))
      {:error, reason} -> OtpFacade.status_reply({:error, reason})
    end
  end

  defp eval_status_reply(handle, ctx, {:write_file, path, content}) do
    with {:ok, path} <- path_arg(path),
         {:ok, _size} <- iodata_size(content) do
      OtpFacade.status_reply(eval_request(handle, ctx, {:write_file, path, content}))
    else
      {:error, reason} -> OtpFacade.status_reply({:error, reason})
    end
  end

  defp eval_status_reply(handle, ctx, {operation, path, content})
       when operation in [:append_file, :exclusive_write_file] do
    with {:ok, path} <- path_arg(path),
         {:ok, _size} <- iodata_size(content) do
      OtpFacade.status_reply(eval_request(handle, ctx, {operation, path, content}))
    else
      {:error, reason} -> OtpFacade.status_reply({:error, reason})
    end
  end

  defp eval_status_reply(handle, ctx, {:rename, from, to}) do
    with {:ok, from} <- path_arg(from),
         {:ok, to} <- path_arg(to) do
      OtpFacade.status_reply(eval_request(handle, ctx, {:rename, from, to}))
    else
      {:error, reason} -> OtpFacade.status_reply({:error, reason})
    end
  end

  defp eval_list_dir_reply(handle, ctx, {operation, path}) do
    case path_arg(path) do
      {:ok, path} -> OtpFacade.list_dir_reply(eval_request(handle, ctx, {operation, path}))
      {:error, reason} -> OtpFacade.list_dir_reply({:error, reason})
    end
  end

  defp eval_file_info_reply(handle, ctx, {operation, path}) do
    case path_arg(path) do
      {:ok, path} -> OtpFacade.file_info_reply(eval_request(handle, ctx, {operation, path}))
      {:error, reason} -> OtpFacade.file_info_reply({:error, reason})
    end
  end

  defp eval_get_cwd_reply(handle, ctx) do
    with {:ok, cwd} <- eval_request(handle, ctx, :get_cwd) do
      {:ok, {:ok, String.to_charlist(cwd)}}
    end
  end

  defp path_request(handle, operation, path) do
    with {:ok, path} <- path_arg(path) do
      request(handle, {operation, path})
    end
  end

  defp iodata_size(content) do
    {:ok, :erlang.iolist_size(content)}
  rescue
    ArgumentError -> {:error, :badarg}
  end

  defp check_iodata_limit(size, limit)
       when is_integer(size) and is_integer(limit) and size <= limit,
       do: :ok

  defp check_iodata_limit(size, limit) when is_integer(size) and is_integer(limit),
    do: {:error, :enospc}

  defp check_iodata_limit(_size, _limit), do: {:error, :badarg}

  defp two_path_request(handle, operation, from, to) do
    with {:ok, from} <- path_arg(from),
         {:ok, to} <- path_arg(to) do
      request(handle, {operation, from, to})
    end
  end

  defp get_cwd_reply(handle) do
    with {:ok, cwd} <- request(handle, :get_cwd) do
      {:ok, {:ok, String.to_charlist(cwd)}}
    end
  end

  defp get_cwd_drive_reply(handle, []), do: get_cwd_reply(handle)
  defp get_cwd_drive_reply(handle, <<>>), do: get_cwd_reply(handle)
  defp get_cwd_drive_reply(_handle, drive) when is_binary(drive), do: {:ok, {:error, :badarg}}
  defp get_cwd_drive_reply(_handle, drive) when is_list(drive), do: {:ok, {:error, :enotsup}}
  defp get_cwd_drive_reply(_handle, _drive), do: {:ok, {:error, :badarg}}

  defp materialize_export(exported, root) when is_binary(root) do
    root = Path.expand(root)
    File.mkdir_p!(root)

    Enum.each(exported.directories, fn path ->
      File.mkdir_p!(Path.join(root, relative_export_path(path)))
    end)

    Enum.each(exported.files, fn %{path: path, content: content} ->
      target = Path.join(root, relative_export_path(path))
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, content)
    end)

    {:ok, Map.put(exported, :materialized_to, root)}
  rescue
    _exception -> {:error, :eacces}
  end

  defp materialize_export(_exported, _root), do: {:error, :badarg}

  defp relative_export_path("/"), do: "."

  defp relative_export_path(path) when is_binary(path) do
    path
    |> String.trim_leading("/")
    |> case do
      "" -> "."
      relative -> relative
    end
  end

  defp open_request(handle, path, modes, ctx) do
    with {:ok, path} <- path_arg(path),
         {:ok, operation} <- OtpFacade.open_operation(modes),
         {:ok, call_id} <- call_id(ctx) do
      request(handle, {:eval_request, call_id, {:open, path, operation, call_id}})
    end
  end

  defp handle_close_request(handle, io, ctx) do
    with {:ok, call_id} <- call_id(ctx) do
      request(handle, {:eval_request, call_id, {:handle_close, io, call_id}})
    end
  end

  defp handle_read_request(handle, io, count, ctx) do
    with {:ok, call_id} <- call_id(ctx) do
      request(handle, {:eval_request, call_id, {:handle_read, io, count, call_id}})
    end
  end

  defp handle_write_request(handle, io, content, ctx) do
    with {:ok, size} <- iodata_size(content),
         {:ok, call_id} <- call_id(ctx),
         {:ok, limit} <-
           request(handle, {:eval_request, call_id, {:handle_write_limit, io, call_id}}),
         :ok <- check_iodata_limit(size, limit) do
      request(handle, {:eval_request, call_id, {:handle_write, io, content, call_id}})
    end
  end

  defp ensure_dir_request(handle, path) do
    with {:ok, target} <- ensure_dir_target(path) do
      ensure_dir(handle, target)
    end
  end

  # The own VFS namespace has symlinks, so `:stat` and `:lstat` are two
  # different server operations: `stat/2` follows the final symlink and
  # `link_stat/2` reports the link itself.
  defp wildcard_callbacks(handle) do
    %{
      stat: fn path -> stat(handle, path) end,
      lstat: fn path -> link_stat(handle, path) end,
      list_dir: fn path -> list_dir(handle, path) end
    }
  end

  defp filelib_predicate(handle, path, predicate) do
    with {:ok, value} <-
           @wildcard_bridge.with_callbacks(wildcard_callbacks(handle), fn ->
             case predicate do
               :is_file -> :filelib.is_file(path, @wildcard_bridge)
               :is_dir -> :filelib.is_dir(path, @wildcard_bridge)
             end
           end) do
      {:ok, value}
    end
  end

  defp filelib_wildcard(handle, pattern) do
    filelib_wildcard(handle, pattern, ~c".", :file)
  end

  defp filelib_wildcard(handle, pattern, mod) when is_atom(mod) do
    filelib_wildcard(handle, pattern, ~c".", mod)
  end

  defp filelib_wildcard(handle, pattern, cwd) do
    filelib_wildcard(handle, pattern, cwd, :file)
  end

  defp filelib_wildcard(handle, pattern, cwd, :file) when is_list(pattern) and is_list(cwd) do
    with {:ok, limits} <- limits(handle) do
      filelib_wildcard_with_limits(handle, pattern, cwd, limits)
    end
  end

  defp filelib_wildcard(_handle, _pattern, _cwd, _mod), do: {:error, :badarg}

  defp filelib_wildcard_with_limits(handle, pattern, cwd, limits) do
    try do
      with {:ok, matches} <-
             @wildcard_bridge.with_callbacks(wildcard_callbacks(handle), limits, fn ->
               :filelib.wildcard(pattern, cwd, @wildcard_bridge)
             end),
           :ok <- check_wildcard_matches(matches, limits) do
        {:ok, matches}
      end
    catch
      {:hyperlang_wildcard_error, reason} -> {:error, reason}
    end
  end

  defp call_id(%{call_id: call_id}) when is_integer(call_id), do: {:ok, call_id}
  defp call_id(_ctx), do: {:error, :missing_call_id}

  defp path_arg(path) when is_binary(path), do: {:ok, path}

  defp path_arg(path) when is_list(path), do: path_charlist_arg(path)

  defp path_arg(_path), do: {:error, :badarg}

  defp path_join(dir, file) do
    :filename.join(String.to_charlist(dir), String.to_charlist(file))
    |> List.to_string()
  end

  defp ensure_dir_target("/"), do: {:ok, "/"}
  defp ensure_dir_target(path) when is_binary(path), do: {:ok, :filename.dirname(path)}

  defp ensure_dir_target(path) when is_list(path),
    do: with({:ok, path} <- path_charlist_arg(path), do: {:ok, :filename.dirname(path)})

  defp ensure_dir_target(_path), do: {:error, :badarg}

  defp path_charlist_arg(path) do
    if path_charlist?(path), do: {:ok, List.to_string(path)}, else: {:error, :badarg}
  rescue
    ArgumentError -> {:error, :badarg}
  end

  defp path_list_arg(paths) when is_list(paths) do
    if path_charlist?(paths) do
      {:error, :badarg}
    else
      Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
        case path_arg(path) do
          {:ok, path} -> {:cont, {:ok, [path | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, paths} -> {:ok, Enum.reverse(paths)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp path_list_arg(_paths), do: {:error, :badarg}

  defp path_charlist?(path), do: path_charlist?(path, 0)

  defp path_charlist?([], count), do: count <= @max_path_arg_codepoints

  defp path_charlist?([codepoint | rest], count)
       when count < @max_path_arg_codepoints and is_integer(codepoint) and codepoint >= 0 and
              codepoint <= 0x10FFFF,
       do: path_charlist?(rest, count + 1)

  defp path_charlist?(_path, _count), do: false

  defp check_wildcard_matches(matches, limits) do
    result_bytes =
      Enum.reduce(matches, 0, fn match, acc ->
        acc + IO.iodata_length(match)
      end)

    cond do
      length(matches) > limits.max_wildcard_matches -> {:error, :eoverflow}
      result_bytes > limits.max_dir_result_bytes -> {:error, :eoverflow}
      true -> :ok
    end
  end

  # Servers only ever start under the application's DynamicSupervisor: there is
  # no unsupervised fallback, so the `rest_for_one` guarantee holds.
  defp start_server(filesystem, opts) do
    DynamicSupervisor.start_child(
      Hyperlang.Filesystem.Supervisor,
      {Hyperlang.Filesystem.Server, {filesystem, opts}}
    )
  end

  defp lookup_handle(%Handle{id: id}) do
    Hyperlang.Filesystem.Registry.lookup(id)
  end

  defp register_handle(id, pid) do
    Hyperlang.Filesystem.Registry.register(id, pid)
  end

  defp filesystem_call_error(module, function, arity, reason, message) do
    Hyperlang.Error.new(:verify, "#{module}:#{function}/#{arity}: #{message}",
      details: %{
        capability: :filesystem,
        module: module,
        function: function,
        arity: arity,
        reason: reason
      }
    )
  end

  defp longest_prefix_mount(mounts, path) do
    mounts
    |> Enum.sort_by(fn mount -> byte_size(mount.virtual) end, :desc)
    |> Enum.find(&mount_matches?(&1.virtual, path))
    |> case do
      nil ->
        {:error,
         Hyperlang.Error.new(:filesystem, "no matching filesystem mount",
           details: %{path: path, reason: :eacces}
         )}

      mount ->
        {:ok, mount}
    end
  end

  # The single mount-containment predicate and the single mount-relative path
  # projection. The server resolves against the same two rules.
  def mount_matches?("/", _path), do: true
  def mount_matches?(root, path), do: path == root or String.starts_with?(path, root <> "/")

  def relative_path("/", path), do: path

  def relative_path(root, path) do
    case binary_part(path, byte_size(root), byte_size(path) - byte_size(root)) do
      "" -> "/"
      suffix -> suffix
    end
  end

  # The single mount permission engine: read-only enforcement first (a
  # read-only mount refuses mutations even when `allow` lists them), then the
  # mount's allow list. `skip_allow: true` suspends BOTH checks and exists for
  # mount setup (seeding), which writes the mount's own declared contents
  # before the mount is exposed to a caller.
  defp authorize_permission(_mount, _operation, skip_allow: true), do: :ok

  defp authorize_permission(%{mode: :read_only} = mount, operation, _opts)
       when operation in [:write, :delete, :mkdir, :rename] do
    {:error,
     Hyperlang.Error.new(:filesystem, "filesystem mount is read-only",
       details: %{virtual: mount.virtual, operation: operation, reason: :erofs}
     )}
  end

  defp authorize_permission(mount, operation, _opts) do
    if operation in mount.allow do
      :ok
    else
      {:error,
       Hyperlang.Error.new(:filesystem, "filesystem mount permission denied",
         details: %{
           virtual: mount.virtual,
           operation: operation,
           allowed: mount.allow,
           reason: :eacces
         }
       )}
    end
  end

  # Every confinement failure carries its POSIX reason atom in `details.reason`;
  # callers classify on the atom, never on the message prose.
  defp normalize_request_path(filesystem, path) do
    limits = Map.fetch!(filesystem, :limits)

    cond do
      byte_size(path) == 0 ->
        {:error, path_error("filesystem path must not be empty", :invalid_path)}

      byte_size(path) > limits.max_path_bytes ->
        {:error, path_error("filesystem path exceeds max_path_bytes", :enametoolong)}

      not String.valid?(path) ->
        {:error, path_error("filesystem path is not valid UTF-8", :invalid_path)}

      String.contains?(path, <<0>>) ->
        {:error, path_error("filesystem path contains null byte", :invalid_path)}

      String.contains?(path, "\\") ->
        {:error, path_error("filesystem path must use POSIX separators", :invalid_path)}

      not String.starts_with?(path, "/") ->
        normalize_relative_path(filesystem, path, limits)

      path != "/" and String.contains?(path, "//") ->
        {:error, path_error("filesystem path contains empty components", :invalid_path)}

      path != "/" and String.ends_with?(path, "/") ->
        {:error, path_error("filesystem path must be normalized", :invalid_path)}

      true ->
        normalize_absolute_path(path, limits)
    end
  end

  defp path_error(message, reason),
    do: Hyperlang.Error.new(:filesystem, message, details: %{reason: reason})

  defp normalize_relative_path(%{allow_relative_paths: true, cwd: cwd}, path, limits) do
    normalize_absolute_path(Path.join(cwd, path), limits)
  end

  defp normalize_relative_path(_filesystem, _path, _limits) do
    {:error, path_error("relative filesystem paths are disabled", :invalid_path)}
  end

  defp normalize_absolute_path(path, limits) do
    parts = String.split(path, "/", trim: true)

    with :ok <- check_components(parts, limits) do
      path =
        parts
        |> Enum.reduce([], &normalize_path_component/2)
        |> Enum.reverse()
        |> case do
          [] -> "/"
          normalized -> "/" <> Enum.join(normalized, "/")
        end

      if byte_size(path) > limits.max_path_bytes do
        {:error, path_error("filesystem path exceeds max_path_bytes", :enametoolong)}
      else
        {:ok, path}
      end
    end
  end

  defp check_components(parts, limits) do
    if Enum.any?(parts, &(byte_size(&1) > limits.max_component_bytes)) do
      {:error, path_error("filesystem path component exceeds max_component_bytes", :enametoolong)}
    else
      :ok
    end
  end

  defp normalize_path_component(".", acc), do: acc
  defp normalize_path_component("..", []), do: []
  defp normalize_path_component("..", [_head | tail]), do: tail
  defp normalize_path_component(part, acc), do: [part | acc]
end
