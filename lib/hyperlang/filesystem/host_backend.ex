defmodule Hyperlang.Filesystem.HostBackend do
  # `file:`/`filelib:` mirror lowered onto the host Plan 9 syscall facade.
  #
  # When the manifest selects `filesystem.backend: :host`, the Erlang
  # compatibility surface and the Plan 9 `sys:` surface become two skins over
  # the same attached namespace: every operation here lowers onto the same
  # host syscall callback `Hyperlang.Sys` uses. Both skins mint opaque BEAM-
  # reference handles backed by worker-local fd metadata for descriptors that
  # cross into `file:`, so guest code cannot forge file handles from raw fd maps
  # or guessed fd integers.
  #
  # Host syscalls keep Plan 9 C-style returns (-1/nil plus errstr). After a
  # failure this module reads the per-process errstr through the same facade
  # and maps the kernel's stable Plan 9 error strings back to POSIX reasons
  # for OTP-shaped replies.
  @moduledoc false

  import Bitwise

  alias Hyperlang.Filesystem.{OtpFacade, WildcardBridge}

  @host_handles_key :"$hyperlang_host_file_handles"

  @oread 0
  @owrite 1
  @ordwr 2
  @otrunc 16
  @oexcl 0x1000
  @dmdir 1 <<< 31

  @seekend 2

  @read_chunk 65_536
  @max_read_chunks 4_096

  # Reverse map of the kernel's stable errstr strings (Error.@messages) for
  # the file-operation subset. Unknown strings fall back to :eio.
  @errstr_reasons %{
    "permission denied" => :eacces,
    "file does not exist" => :enoent,
    "not a directory" => :enotdir,
    "is a directory" => :eisdir,
    "file exists" => :eexist,
    "is a mount point" => :ebusy,
    "directory not empty" => :enotempty,
    "no space left" => :enospc,
    "file name too long" => :enametoolong,
    "read-only file system" => :erofs,
    "cross-device link" => :exdev,
    "invalid argument" => :einval,
    "invalid path" => :einval,
    "operation not supported" => :enotsup,
    "bad use of fd" => :ebadf,
    "bad fid" => :ebadf,
    "too many open fids" => :emfile,
    "resource busy" => :ebusy,
    "result too large" => :eoverflow,
    "i/o count too small" => :einval,
    "I/O error" => :eio
  }

  def dispatch(ctx, :open, [path, modes]) do
    with {:ok, path} <- path_arg(path),
         {:ok, flags} <- OtpFacade.open_operation(modes) do
      binary? = binary_mode?(modes)

      case open_with_flags(ctx, path, flags) do
        {:ok, fd} ->
          {:ok, {:ok, handle(fd, binary?, flags.append)}}

        {:error, reason} ->
          {:ok, {:error, reason}}
      end
    else
      {:error, reason} -> {:ok, {:error, reason}}
    end
  end

  def dispatch(ctx, :close, [io]) do
    with_fd(ctx, io, fn fd ->
      case sys_int(ctx, :close, [fd]) do
        {:ok, _n} ->
          release_handle(io)
          release_fd(fd)
          {:ok, :ok}

        {:error, reason} ->
          {:ok, {:error, reason}}
      end
    end)
  end

  def dispatch(ctx, :read, [io, count]) when is_integer(count) and count >= 0 do
    with_fd(ctx, io, fn fd ->
      case sys(ctx, :read, [fd, <<>>, count]) do
        {:ok, {0, _bytes}} -> {:ok, :eof}
        {:ok, {n, bytes}} when n > 0 -> {:ok, {:ok, decode_data(io, bytes)}}
        {:ok, _failure} -> {:ok, {:error, posix_reason(ctx)}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def dispatch(ctx, :handle_read, [io, count]), do: dispatch(ctx, :read, [io, count])
  def dispatch(ctx, :handle_write, [io, data]), do: dispatch(ctx, :write, [io, data])

  def dispatch(ctx, :write, [io, data]) do
    with {:ok, bin} <- iodata_arg(data) do
      with_fd(ctx, io, fn fd ->
        with :ok <- maybe_seek_end(ctx, io, fd),
             :ok <- write_all(ctx, fd, bin) do
          {:ok, :ok}
        else
          {:error, reason} -> {:ok, {:error, reason}}
        end
      end)
    else
      {:error, reason} -> {:ok, {:error, reason}}
    end
  end

  def dispatch(ctx, :read_file, [path]) do
    with {:ok, path} <- path_arg(path),
         {:ok, fd} <- open_path(ctx, path, @oread),
         {:ok, bin} <- after_close(ctx, fd, fn -> read_all(ctx, fd) end) do
      {:ok, {:ok, bin}}
    else
      {:error, reason} -> {:ok, {:error, reason}}
    end
  end

  def dispatch(ctx, :write_file, [path, content]),
    do: dispatch(ctx, :write_file, [path, content, []])

  def dispatch(ctx, :write_file, [path, content, modes]) do
    with {:ok, path} <- path_arg(path),
         {:ok, bin} <- iodata_arg(content),
         {:ok, operation} <- OtpFacade.write_operation(modes),
         {:ok, fd} <- open_for_write(ctx, path, operation),
         {:ok, :ok} <- after_close(ctx, fd, fn -> wrap_status(write_all(ctx, fd, bin)) end) do
      {:ok, :ok}
    else
      {:error, reason} -> {:ok, {:error, reason}}
    end
  end

  def dispatch(ctx, :list_dir, [path]) do
    with {:ok, path} <- path_arg(path),
         {:ok, fd} <- open_path(ctx, path, @oread),
         {:ok, names} <- after_close(ctx, fd, fn -> read_dir_names(ctx, fd) end) do
      OtpFacade.list_dir_reply({:ok, names})
    else
      {:error, reason} -> {:ok, {:error, reason}}
    end
  end

  def dispatch(ctx, :make_dir, [path]) do
    with {:ok, path} <- path_arg(path) do
      case sys_fd(ctx, :create, [path, @oread, @dmdir ||| 0o777]) do
        {:ok, fd} ->
          _ = sys_int(ctx, :close, [fd])
          {:ok, :ok}

        {:error, reason} ->
          {:ok, {:error, reason}}
      end
    else
      {:error, reason} -> {:ok, {:error, reason}}
    end
  end

  def dispatch(ctx, :del_dir, [path]), do: remove_reply(ctx, path)
  def dispatch(ctx, :delete, [path]), do: remove_reply(ctx, path)

  def dispatch(ctx, :read_file_info, [path]), do: stat_info_reply(ctx, path)
  def dispatch(ctx, :read_link_info, [path]), do: stat_info_reply(ctx, path)

  def dispatch(ctx, :rename, [from, to]) do
    with {:ok, from} <- path_arg(from),
         {:ok, to} <- path_arg(to) do
      cond do
        Path.dirname(from) != Path.dirname(to) ->
          {:ok, {:error, :exdev}}

        true ->
          case sys_int(ctx, :wstat, [from, %{<<"name">> => Path.basename(to)}]) do
            {:ok, _n} -> {:ok, :ok}
            {:error, reason} -> {:ok, {:error, reason}}
          end
      end
    else
      {:error, reason} -> {:ok, {:error, reason}}
    end
  end

  def dispatch(ctx, :get_cwd, []) do
    with {:ok, fd} <- open_path(ctx, ".", @oread),
         {:ok, path} <- after_close(ctx, fd, fn -> fd_path(ctx, fd) end) do
      {:ok, {:ok, String.to_charlist(path)}}
    else
      {:error, reason} -> {:ok, {:error, reason}}
    end
  end

  def dispatch(_ctx, :get_cwd, [_drive]), do: {:ok, {:error, :enotsup}}

  def dispatch(ctx, :set_cwd, [path]) do
    with {:ok, path} <- path_arg(path) do
      case sys_int(ctx, :chdir, [path]) do
        {:ok, _n} -> {:ok, :ok}
        {:error, reason} -> {:ok, {:error, reason}}
      end
    else
      {:error, reason} -> {:ok, {:error, reason}}
    end
  end

  def dispatch(ctx, :consult, [path]) do
    with {:ok, path} <- path_arg(path),
         {:ok, fd} <- open_path(ctx, path, @oread),
         {:ok, source} <- after_close(ctx, fd, fn -> read_all(ctx, fd) end),
         {:ok, terms} <- consult_parse(source, ctx) do
      {:ok, {:ok, terms}}
    else
      {:error, reason} -> {:ok, {:error, reason}}
    end
  end

  def dispatch(ctx, :path_consult, [dirs, file]) do
    with {:ok, dirs} <- path_list_arg(dirs),
         {:ok, file} <- path_arg(file) do
      path_consult_dirs(ctx, dirs, file)
    else
      {:error, reason} -> {:ok, {:error, reason}}
    end
  end

  def dispatch(ctx, :is_file, [path]), do: filelib_predicate(ctx, path, :is_file)
  def dispatch(ctx, :is_dir, [path]), do: filelib_predicate(ctx, path, :is_dir)

  def dispatch(ctx, :ensure_dir, [path]) do
    with {:ok, path} <- path_arg(path) do
      ensure_parent_dirs(ctx, Path.dirname(path))
    else
      {:error, reason} -> {:ok, {:error, reason}}
    end
  end

  def dispatch(ctx, :wildcard, [pattern]), do: filelib_wildcard(ctx, pattern, nil)
  def dispatch(ctx, :wildcard, [pattern, cwd]), do: filelib_wildcard(ctx, pattern, cwd)
  def dispatch(ctx, :wildcard, [pattern, cwd, _mod]), do: filelib_wildcard(ctx, pattern, cwd)

  def dispatch(_ctx, operation, args),
    do: {:error, {:unsupported_host_filesystem_operation, operation, length(args)}}

  # -- skins interop ---------------------------------------------------------

  def handle(fd, binary?, append?) when is_integer(fd) and fd >= 0 do
    handle = make_ref()
    metadata = %{fd: fd, binary?: binary? == true, append?: append? == true}
    Process.put(@host_handles_key, Map.put(host_handles(), handle, metadata))
    handle
  end

  def guest_handle?(handle) when is_reference(handle), do: Map.has_key?(host_handles(), handle)
  def guest_handle?(_handle), do: false

  def fd_number(handle) when is_reference(handle) do
    case Map.fetch(host_handles(), handle) do
      {:ok, %{fd: fd}} when is_integer(fd) and fd >= 0 -> {:ok, fd}
      _other -> {:error, :ebadf}
    end
  end

  def fd_number(_handle), do: {:error, :ebadf}

  def release_handle(handle) when is_reference(handle) do
    handles = host_handles()

    if Map.has_key?(handles, handle) do
      Process.put(@host_handles_key, Map.put(handles, handle, :closed))
    end

    :ok
  end

  def release_handle(_handle), do: :ok

  def release_fd(fd) when is_integer(fd) and fd >= 0 do
    handles =
      Map.new(host_handles(), fn
        {handle, %{fd: ^fd}} -> {handle, :closed}
        entry -> entry
      end)

    Process.put(@host_handles_key, handles)
    :ok
  end

  def release_fd(_fd), do: :ok

  # -- open ------------------------------------------------------------------

  defp open_with_flags(ctx, path, %{exclusive: true}) do
    sys_fd(ctx, :create, [path, @owrite ||| @oexcl, 0o666])
  end

  defp open_with_flags(ctx, path, %{append: true}) do
    with {:ok, fd} <- open_or_create(ctx, path, @owrite),
         {:ok, _offset} <- seek_end(ctx, fd) do
      {:ok, fd}
    end
  end

  defp open_with_flags(ctx, path, %{read: true, write: true}),
    do: open_or_create(ctx, path, @ordwr)

  defp open_with_flags(ctx, path, %{write: true}),
    do: sys_fd(ctx, :create, [path, @owrite ||| @otrunc, 0o666])

  defp open_with_flags(ctx, path, _flags), do: open_path(ctx, path, @oread)

  defp open_or_create(ctx, path, mode) do
    case open_path(ctx, path, mode) do
      {:ok, fd} -> {:ok, fd}
      {:error, :enoent} -> sys_fd(ctx, :create, [path, mode, 0o666])
      {:error, reason} -> {:error, reason}
    end
  end

  defp open_for_write(ctx, path, :write),
    do: sys_fd(ctx, :create, [path, @owrite ||| @otrunc, 0o666])

  defp open_for_write(ctx, path, :exclusive),
    do: sys_fd(ctx, :create, [path, @owrite ||| @oexcl, 0o666])

  defp open_for_write(ctx, path, :append) do
    with {:ok, fd} <- open_or_create(ctx, path, @owrite),
         {:ok, _offset} <- seek_end(ctx, fd) do
      {:ok, fd}
    end
  end

  defp open_path(ctx, path, mode), do: sys_fd(ctx, :open, [path, mode])

  # -- io --------------------------------------------------------------------

  defp read_all(ctx, fd), do: read_all(ctx, fd, [], 0)

  defp read_all(_ctx, _fd, _acc, chunks) when chunks > @max_read_chunks,
    do: {:error, :eoverflow}

  defp read_all(ctx, fd, acc, chunks) do
    case sys(ctx, :read, [fd, <<>>, @read_chunk]) do
      {:ok, {0, _bytes}} -> {:ok, IO.iodata_to_binary(Enum.reverse(acc))}
      {:ok, {n, bytes}} when n > 0 -> read_all(ctx, fd, [bytes | acc], chunks + 1)
      {:ok, _failure} -> {:error, posix_reason(ctx)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_all(_ctx, _fd, <<>>), do: :ok

  defp write_all(ctx, fd, bin) do
    case sys(ctx, :write, [fd, bin, byte_size(bin)]) do
      {:ok, n} when is_integer(n) and n == byte_size(bin) ->
        :ok

      {:ok, n} when is_integer(n) and n > 0 ->
        rest = binary_part(bin, n, byte_size(bin) - n)
        write_all(ctx, fd, rest)

      {:ok, _failure} ->
        {:error, posix_reason(ctx)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_dir_names(ctx, fd), do: read_dir_names(ctx, fd, [], 0)

  defp read_dir_names(_ctx, _fd, _acc, rounds) when rounds > @max_read_chunks,
    do: {:error, :eoverflow}

  defp read_dir_names(ctx, fd, acc, rounds) do
    case sys(ctx, :dirread, [fd]) do
      {:ok, {0, _entries}} ->
        {:ok, Enum.reverse(acc)}

      {:ok, {n, entries}} when n > 0 and is_list(entries) ->
        names = Enum.map(entries, &Map.get(&1, <<"name">>, <<>>))
        read_dir_names(ctx, fd, Enum.reverse(names, acc), rounds + 1)

      {:ok, _failure} ->
        {:error, posix_reason(ctx)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_seek_end(ctx, io, fd) do
    if handle_append?(io) do
      case seek_end(ctx, fd) do
        {:ok, _offset} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp seek_end(ctx, fd) do
    case sys(ctx, :seek, [fd, 0, @seekend]) do
      {:ok, offset} when is_integer(offset) and offset >= 0 -> {:ok, offset}
      {:ok, _failure} -> {:error, posix_reason(ctx)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fd_path(ctx, fd) do
    case sys(ctx, :fd2path, [fd]) do
      {:ok, path} when is_binary(path) -> {:ok, path}
      {:ok, _failure} -> {:error, posix_reason(ctx)}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- stat ------------------------------------------------------------------

  defp stat_info_reply(ctx, path) do
    with {:ok, path} <- path_arg(path),
         {:ok, dir} <- stat_dir(ctx, path) do
      OtpFacade.file_info_reply({:ok, dir_to_stat(dir)})
    else
      {:error, reason} -> {:ok, {:error, reason}}
    end
  end

  defp stat_dir(ctx, path) do
    case sys(ctx, :stat, [path]) do
      {:ok, {0, dir}} when is_map(dir) -> {:ok, dir}
      {:ok, _failure} -> {:error, posix_reason(ctx)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dir_to_stat(dir) do
    mode = dir_value(dir, "mode", 0)
    type = if band(mode, @dmdir) != 0, do: :dir, else: :file

    %{
      type: type,
      size: dir_value(dir, "length", 0),
      mode: OtpFacade.safe_permission_mode(mode)
    }
  end

  defp dir_value(dir, key, default) do
    Map.get(dir, key, Map.get(dir, :erlang.binary_to_atom(key, :utf8), default))
  end

  # -- filelib ---------------------------------------------------------------

  defp filelib_predicate(ctx, path, predicate) do
    with {:ok, path} <- path_arg(path) do
      case stat_dir(ctx, path) do
        {:ok, dir} ->
          case predicate do
            :is_file -> {:ok, true}
            :is_dir -> {:ok, band(dir_value(dir, "mode", 0), @dmdir) != 0}
          end

        {:error, _reason} ->
          {:ok, false}
      end
    else
      {:error, _reason} -> {:ok, false}
    end
  end

  defp filelib_wildcard(ctx, pattern, cwd) do
    with {:ok, pattern} <- charlist_arg(pattern),
         {:ok, cwd} <- wildcard_cwd(cwd) do
      WildcardBridge.with_callbacks(wildcard_callbacks(ctx), wildcard_limits(ctx), fn ->
        :filelib.wildcard(pattern, cwd, WildcardBridge)
      end)
    else
      {:error, reason} -> {:ok, {:error, reason}}
    end
  catch
    {:hyperlang_wildcard_error, reason} -> {:error, reason}
  end

  # The Plan 9 namespace this backend attaches has no symlinks and the syscall
  # surface has no lstat (`sys:stat`/`sys:fstat` only), so `:stat` and `:lstat`
  # are deliberately the same callback here. The choice is made once, at the
  # supply site, instead of being buried in a private alias.
  defp wildcard_callbacks(ctx) do
    stat = fn path -> host_stat(ctx, path) end

    %{
      stat: stat,
      lstat: stat,
      list_dir: fn path -> host_dir_names(ctx, path) end
    }
  end

  defp host_stat(ctx, path) do
    with {:ok, dir} <- stat_dir(ctx, path) do
      {:ok, dir_to_stat(dir)}
    end
  end

  defp host_dir_names(ctx, path) do
    case dispatch(ctx, :list_dir, [path]) do
      {:ok, {:ok, names}} -> {:ok, Enum.map(names, &List.to_string/1)}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp wildcard_cwd(nil), do: {:ok, ~c"."}
  defp wildcard_cwd(cwd), do: charlist_arg(cwd)

  defp charlist_arg(value) when is_list(value), do: {:ok, value}
  defp charlist_arg(value) when is_binary(value), do: {:ok, String.to_charlist(value)}
  defp charlist_arg(_value), do: {:error, :badarg}

  # The configured filesystem limits, never a hardcoded default: an enabled
  # filesystem always carries normalized limits, and a context without them is
  # a wiring defect that must not degrade into "wildcard limits are off".
  defp wildcard_limits(%{manifest: %{filesystem: %{limits: %{} = limits}}}), do: limits

  defp ensure_parent_dirs(_ctx, dir) when dir in [".", "/", ""], do: {:ok, :ok}

  defp ensure_parent_dirs(ctx, dir) do
    case stat_dir(ctx, dir) do
      {:ok, existing} ->
        if band(dir_value(existing, "mode", 0), @dmdir) != 0 do
          {:ok, :ok}
        else
          {:ok, {:error, :enotdir}}
        end

      {:error, :enoent} ->
        with {:ok, :ok} <- ensure_parent_dirs(ctx, Path.dirname(dir)) do
          case sys_fd(ctx, :create, [dir, @oread, @dmdir ||| 0o777]) do
            {:ok, fd} ->
              _ = sys_int(ctx, :close, [fd])
              {:ok, :ok}

            {:error, :eexist} ->
              {:ok, :ok}

            {:error, reason} ->
              {:ok, {:error, reason}}
          end
        end

      {:error, reason} ->
        {:ok, {:error, reason}}
    end
  end

  # -- consult ---------------------------------------------------------------

  defp consult_parse(source, ctx) do
    case Hyperlang.Consult.parse(source, ctx) do
      {:ok, terms} -> {:ok, terms}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _reason} -> {:error, :badarg}
    end
  end

  defp path_consult_dirs(_ctx, [], _file), do: {:ok, {:error, :enoent}}

  defp path_consult_dirs(ctx, [dir | rest], file) do
    full = Path.join(dir, file)

    with {:ok, fd} <- open_path(ctx, full, @oread),
         {:ok, source} <- after_close(ctx, fd, fn -> read_all(ctx, fd) end),
         {:ok, terms} <- consult_parse(source, ctx) do
      {:ok, {:ok, terms, String.to_charlist(full)}}
    else
      {:error, :enoent} -> path_consult_dirs(ctx, rest, file)
      {:error, reason} -> {:ok, {:error, reason}}
    end
  end

  # -- shared plumbing -------------------------------------------------------

  defp remove_reply(ctx, path) do
    with {:ok, path} <- path_arg(path) do
      case sys_int(ctx, :remove, [path]) do
        {:ok, _n} -> {:ok, :ok}
        {:error, reason} -> {:ok, {:error, reason}}
      end
    else
      {:error, reason} -> {:ok, {:error, reason}}
    end
  end

  defp with_fd(ctx, io, fun) do
    case host_fd_number(ctx, io) do
      {:ok, fd} -> fun.(fd)
      {:error, reason} -> {:ok, {:error, reason}}
    end
  end

  defp host_fd_number(_ctx, fd) when is_reference(fd), do: fd_number(fd)
  defp host_fd_number(_ctx, _fd), do: {:error, :ebadf}

  defp after_close(ctx, fd, fun) do
    result = fun.()
    _ = sys_int(ctx, :close, [fd])
    result
  end

  defp wrap_status(:ok), do: {:ok, :ok}
  defp wrap_status({:error, reason}), do: {:error, reason}

  defp decode_data(io, bytes) when is_binary(bytes) do
    if handle_binary?(io) do
      bytes
    else
      :binary.bin_to_list(bytes)
    end
  end

  # Plan 9 C-style call helpers: a non-negative integer is success, anything
  # else means the kernel set errstr and we translate it to a POSIX reason.
  #
  # Calls go through the raw door (Runtime.host_call): the mirror's single
  # sanitize pass already happened at the Runtime.filesystem entry, and the
  # reply is sanitized once on the way back out of Runtime.filesystem.

  def sys(ctx, operation, args) do
    case Hyperlang.Runtime.host_call(ctx, operation, args) do
      {:error, :syscall_unavailable} -> {:error, :eacces}
      other -> other
    end
  end

  defp sys_fd(ctx, operation, args) do
    case sys(ctx, operation, args) do
      {:ok, fd} when is_integer(fd) and fd >= 0 -> {:ok, fd}
      {:ok, _failure} -> {:error, posix_reason(ctx)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sys_int(ctx, operation, args) do
    case sys(ctx, operation, args) do
      {:ok, n} when is_integer(n) and n >= 0 -> {:ok, n}
      {:ok, _failure} -> {:error, posix_reason(ctx)}
      {:error, reason} -> {:error, reason}
    end
  end

  def posix_reason(ctx, fallback \\ :eio) do
    case Hyperlang.Runtime.errstr(ctx) do
      message when is_binary(message) and message != "" ->
        Map.get(@errstr_reasons, message, fallback)

      _other ->
        fallback
    end
  end

  defp path_arg(path) when is_binary(path), do: {:ok, path}

  defp path_arg(path) when is_list(path) do
    case :unicode.characters_to_binary(path) do
      binary when is_binary(binary) -> {:ok, binary}
      _other -> {:error, :badarg}
    end
  end

  defp path_arg(_path), do: {:error, :badarg}

  defp path_list_arg(dirs) when is_list(dirs) do
    dirs
    |> Enum.reduce_while({:ok, []}, fn dir, {:ok, acc} ->
      case path_arg(dir) do
        {:ok, dir} -> {:cont, {:ok, [dir | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp path_list_arg(_dirs), do: {:error, :badarg}

  defp iodata_arg(data) do
    {:ok, IO.iodata_to_binary(data)}
  rescue
    ArgumentError ->
      case data do
        chars when is_list(chars) ->
          case :unicode.characters_to_binary(chars) do
            binary when is_binary(binary) -> {:ok, binary}
            _other -> {:error, :badarg}
          end

        _other ->
          {:error, :badarg}
      end
  end

  defp binary_mode?(modes) when is_list(modes), do: Enum.member?(modes, :binary)

  defp handle_binary?(handle) when is_reference(handle) do
    case Map.fetch(host_handles(), handle) do
      {:ok, %{binary?: binary?}} -> binary? == true
      _other -> false
    end
  end

  defp handle_binary?(_handle), do: false

  defp handle_append?(handle) when is_reference(handle) do
    case Map.fetch(host_handles(), handle) do
      {:ok, %{append?: append?}} -> append? == true
      _other -> false
    end
  end

  defp handle_append?(_handle), do: false

  defp host_handles do
    Process.get(@host_handles_key, %{})
  end
end
