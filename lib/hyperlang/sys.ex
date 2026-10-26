defmodule Hyperlang.Sys do
  # Canonical Plan 9 libc-shaped guest syscall surface. Guest module `sys:`
  # resolves the full table. All operations lower onto the host-supplied
  # syscall callback.
  @moduledoc false

  import Bitwise

  @fd_key "$sys_fd"
  @guest_fd_tokens_key :hyperlang_guest_fd_tokens
  @maxint 2_147_483_647
  @qtdir 0x80
  @qtappend 0x40
  @qtexcl 0x20
  @qtauth 0x08
  @qttmp 0x04
  @qtfile 0

  @atomicio 8192
  @seekstart 0
  @seekrela 1
  @seekend 2
  @namemax 256
  @errmax 128
  @waitlen @errmax + 64

  @oread 0
  @owrite 1
  @ordwr 2
  @otrunc 16
  @ocexec 32
  @orclose 64
  @oexcl 0x1000
  @dmdir 1 <<< 31
  @dmappend 1 <<< 30
  @dmexcl 1 <<< 29
  @dmauth 1 <<< 27
  @dmtmp 1 <<< 26

  @mrepl 0
  @mbefore 1
  @mafter 2
  @mcreate 4
  @mcache 16

  @newfd 1 <<< 0
  @forkfd 1 <<< 1
  @newns 1 <<< 2
  @forkns 1 <<< 3
  @new_process_group 1 <<< 4
  @nodevs 1 <<< 5
  @newenv 1 <<< 6
  @forkenv 1 <<< 7

  @expwait 0
  @expasync 1

  @pnproc 1
  @pngroup 2

  @utfmax 4
  @utferror 0xFFFD
  @runemax 0x10FFFF
  @runemask 0x1FFFFF

  @constants %{
    "maxint" => @maxint,
    "qtdir" => @qtdir,
    "qtappend" => @qtappend,
    "qtexcl" => @qtexcl,
    "qtauth" => @qtauth,
    "qttmp" => @qttmp,
    "qtfile" => @qtfile,
    "atomicio" => @atomicio,
    "seekstart" => @seekstart,
    "seekrela" => @seekrela,
    "seekend" => @seekend,
    "namemax" => @namemax,
    "errmax" => @errmax,
    "waitlen" => @waitlen,
    "oread" => @oread,
    "owrite" => @owrite,
    "ordwr" => @ordwr,
    "otrunc" => @otrunc,
    "ocexec" => @ocexec,
    "orclose" => @orclose,
    "oexcl" => @oexcl,
    "dmdir" => @dmdir,
    "dmappend" => @dmappend,
    "dmexcl" => @dmexcl,
    "dmauth" => @dmauth,
    "dmtmp" => @dmtmp,
    "mrepl" => @mrepl,
    "mbefore" => @mbefore,
    "mafter" => @mafter,
    "mcreate" => @mcreate,
    "mcache" => @mcache,
    "newfd" => @newfd,
    "forkfd" => @forkfd,
    # The RFCNAMEG pctl flag. Arity-0 `sys:newns` is the newns SYSCALL, so the
    # flag has its own accessor name (rc's `rfork N` uses it).
    "rfcnameg" => @newns,
    "forkns" => @forkns,
    ("new" <> "p" <> "grp") => @new_process_group,
    "nodevs" => @nodevs,
    "newenv" => @newenv,
    "forkenv" => @forkenv,
    "expwait" => @expwait,
    "expasync" => @expasync,
    "pnproc" => @pnproc,
    "pngroup" => @pngroup,
    "utfmax" => @utfmax,
    "utferror" => @utferror,
    "runemax" => @runemax,
    "runemask" => @runemask
  }

  @sys_calls %{
    {"announce", 1} => :sys_announce,
    {"bind", 3} => :sys_bind,
    {"byte2char", 2} => :sys_byte2char,
    {"char2byte", 3} => :sys_char2byte,
    {"chdir", 1} => :sys_chdir,
    {"create", 3} => :sys_create,
    {"dial", 2} => :sys_dial,
    {"dirread", 1} => :sys_dirread,
    {"dup", 2} => :sys_dup,
    {"export", 3} => :sys_export,
    {"fauth", 2} => :sys_fauth,
    {"fd2path", 1} => :sys_fd2path,
    {"fildes", 1} => :sys_fildes,
    {"file2chan", 2} => :sys_file2chan,
    {"fstat", 1} => :sys_fstat,
    {"fversion", 3} => :sys_fversion,
    {"fwstat", 2} => :sys_fwstat,
    {"iounit", 1} => :sys_iounit,
    {"listen", 1} => :sys_listen,
    {"millisec", 0} => :sys_millisec,
    {"mount", 5} => :sys_mount,
    {"nulldir", 0} => :sys_nulldir,
    {"open", 2} => :sys_open,
    {"pctl", 2} => :sys_pctl,
    {"pipe", 1} => :sys_pipe,
    {"pread", 4} => :sys_pread,
    {"pwrite", 4} => :sys_pwrite,
    {"print", 1} => :sys_print,
    {"read", 3} => :sys_read,
    {"readn", 3} => :sys_readn,
    {"remove", 1} => :sys_remove,
    {"seek", 3} => :sys_seek,
    {"sleep", 1} => :sys_sleep,
    {"sprint", 1} => :sys_sprint,
    {"stat", 1} => :sys_stat,
    {"stream", 3} => :sys_stream,
    {"tokenize", 2} => :sys_tokenize,
    {"unmount", 2} => :sys_unmount,
    {"utfbytes", 2} => :sys_utfbytes,
    {"werrstr", 1} => :sys_werrstr,
    {"write", 3} => :sys_write,
    {"wstat", 2} => :sys_wstat,
    {"zerodir", 0} => :sys_zerodir
  }

  @sys_vm_runtime_calls %{
    # Dis concurrency primitives — typed channels + alt (libinterp/xec.c,
    # libinterp/alt.c). These are VM-runtime calls into Hyperlang.Chan, not host-door syscalls.
    #   newchan(size)        -> chan of T (0) / chan[size] of T
    #   csend(c, v)          -> c <-= v   (blocking send)
    #   crecv(c)             -> <-c       (blocking recv)
    #   alt(ops)             -> alt { ... }
    {"newchan", 1} => :sys_newchan_chan,
    {"csend", 2} => :sys_csend,
    {"crecv", 1} => :sys_crecv,
    {"alt", 1} => :sys_alt,
    {"startchan", 0} => :sys_startchan,
    {"exec", 2} => :sys_exec,
    {"exec", 3} => :sys_exec
  }

  @sys_pure_calls %{
    {"exits", 1} => {:internal, :exits}
  }

  @sys_only_calls %{
    {"builtin", 3} => :sys_builtin,
    {"close", 1} => :sys_close,
    # There is no `sys:spawn`. Inferno's real Sys module has no spawn:
    # Limbo `spawn f(args)` is a language statement (a Dis instruction), not a
    # syscall. Guests use the native `spawn(fun() -> f(args) end)` profile, which
    # lowers to hyperlang_msg:spawn -> the host :guest_spawn_hook. Stale
    # `sys:spawn(...)` code is rejected at compile time by the verifier
    # (Hyperlang.Filesystem.call_diagnostic) with a message pointing at the native
    # form, so it never reaches a runtime door.
    {"finit", 0} => :sys_finit,
    {"mount", 3} => :sys_mount,
    {"newns", 0} => :sys_newns,
    {"newns", 1} => :sys_newns,
    {"newns", 2} => :sys_newns,
    {"postnote", 3} => :sys_postnote,
    {"pipe", 0} => :sys_pipe,
    {"pread", 3} => :sys_pread,
    {"pwrite", 3} => :sys_pwrite,
    {"read", 2} => :sys_read,
    {"write", 2} => :sys_write
  }

  @vararg_calls Map.new(1..8, &{{"aprint", &1}, :sys_aprint})
                |> Map.merge(Map.new(2..9, &{{"fprint", &1}, :sys_fprint}))
                |> Map.merge(Map.new(1..8, &{{"print", &1}, :sys_print}))
                |> Map.merge(Map.new(1..8, &{{"sprint", &1}, :sys_sprint}))

  @constant_calls Map.new(@constants, fn {name, _value} -> {{name, 0}, :"sys_#{name}"} end)
  @sys_calls_all @constant_calls
                 |> Map.merge(@sys_calls)
                 |> Map.merge(@vararg_calls)
                 |> Map.merge(@sys_vm_runtime_calls)
                 |> Map.merge(@sys_pure_calls)
                 |> Map.merge(@sys_only_calls)

  @supported_sys_mfas @sys_calls_all
                      |> Map.keys()
                      |> Enum.map(fn {function, arity} -> {"sys", function, arity} end)
                      |> Enum.sort()

  def supported_sys_mfas, do: @supported_sys_mfas

  # Live clock readers. Like `erlang:monotonic_time/0`, they belong to the
  # global nondeterminism capability, not to the deterministic Sys profile.
  def nondeterministic_call?("millisec", 0), do: true
  def nondeterministic_call?(_function, _arity), do: false

  def known_call?("sys", function, arity), do: Map.has_key?(@sys_calls_all, {function, arity})

  def known_call?(_module, _function, _arity), do: false

  def call_target("sys", function, arity), do: Map.get(@sys_calls_all, {function, arity}, :error)

  def call_target(_module, _function, _arity), do: :error

  def guest_context(ctx) when is_map(ctx), do: Map.put(ctx, @guest_fd_tokens_key, true)

  for {function, value} <- @constants do
    def unquote(String.to_atom(function))(_ctx), do: unquote(value)
  end

  def open(ctx, path, mode) do
    case syscall_value(ctx, :open, [path, mode]) do
      {:ok, value} ->
        guest_fd_token(ctx, value)

      :unavailable ->
        nil

      {:error, _reason} ->
        nil
    end
  end

  def create(ctx, path, mode, perm) do
    case syscall_value(ctx, :create, [path, mode, perm]) do
      {:ok, value} ->
        guest_fd_token(ctx, value)

      :unavailable ->
        nil

      {:error, _reason} ->
        nil
    end
  end

  def read(ctx, fd, count), do: read(ctx, fd, <<>>, count)

  def read(ctx, fd, _buf, count) do
    case syscall_value(ctx, :read, [fd, <<>>, count]) do
      {:ok, value} ->
        value

      :unavailable ->
        {-1, ""}

      {:error, _reason} ->
        {-1, ""}
    end
  end

  def readn(ctx, fd, _buf, count) when is_integer(count) and count >= 0 do
    do_readn(ctx, fd, count, [])
  end

  def readn(_ctx, _fd, _buf, _count), do: {-1, ""}

  def write(ctx, fd, buf, count) do
    case syscall_value(ctx, :write, [fd, buf, count]) do
      {:ok, value} ->
        value

      :unavailable ->
        -1

      {:error, _reason} ->
        -1
    end
  end

  def write(ctx, fd, buf), do: write(ctx, fd, buf, IO.iodata_length(buf))

  def stat(ctx, path) do
    case syscall_value(ctx, :stat, [path]) do
      {:ok, value} ->
        value

      :unavailable ->
        {-1, nil}

      {:error, _reason} ->
        {-1, nil}
    end
  end

  def fstat(ctx, fd) do
    case syscall_value(ctx, :fstat, [fd]) do
      {:ok, value} ->
        value

      :unavailable ->
        {-1, nil}

      {:error, _reason} ->
        {-1, nil}
    end
  end

  def remove(ctx, path) do
    case syscall_value(ctx, :remove, [path]) do
      {:ok, value} ->
        value

      :unavailable ->
        -1

      {:error, _reason} ->
        -1
    end
  end

  def iounit(ctx, fd) do
    case syscall_value(ctx, :iounit, [fd]) do
      {:ok, value} when is_integer(value) ->
        value

      :unavailable ->
        -1

      {:error, _reason} ->
        -1
    end
  end

  def announce(ctx, addr) do
    case syscall_value(ctx, :announce, [addr]) do
      {:ok, value} ->
        value

      :unavailable ->
        {-1, nil}

      {:error, _reason} ->
        {-1, nil}
    end
  end

  def byte2char(_ctx, buf, n) do
    with {:ok, bytes} <- bytes_arg(buf),
         {:ok, n} <- offset_arg(n),
         true <- n <= byte_size(bytes) do
      decode_utf8_char(bytes, n)
    else
      _error -> {-1, 0, 0}
    end
  end

  def char2byte(_ctx, c, buf, n) do
    with {:ok, c} <- rune_arg(c),
         {:ok, bytes} <- bytes_arg(buf),
         {:ok, n} <- offset_arg(n),
         true <- n <= byte_size(bytes),
         {:ok, encoded} <- encode_utf8_char(c) do
      if n + byte_size(encoded) <= byte_size(bytes) do
        prefix = binary_part(bytes, 0, n)
        suffix_offset = n + byte_size(encoded)
        suffix = binary_part(bytes, suffix_offset, byte_size(bytes) - suffix_offset)
        {byte_size(encoded), prefix <> encoded <> suffix}
      else
        {0, bytes}
      end
    else
      _error -> {-1, bytes_or_empty(buf)}
    end
  end

  def dial(ctx, addr, local) do
    case syscall_value(ctx, :dial, [addr, local]) do
      {:ok, value} ->
        value

      :unavailable ->
        {-1, nil}

      {:error, _reason} ->
        {-1, nil}
    end
  end

  def dirread(ctx, fd) do
    case syscall_value(ctx, :dirread, [fd]) do
      {:ok, value} ->
        value

      :unavailable ->
        {-1, nil}

      {:error, _reason} ->
        {-1, nil}
    end
  end

  def pread(ctx, fd, count, offset), do: pread(ctx, fd, <<>>, count, offset)

  def pread(ctx, fd, _buf, count, offset) do
    case syscall_value(ctx, :pread, [fd, <<>>, count, offset]) do
      {:ok, value} ->
        value

      :unavailable ->
        {-1, ""}

      {:error, _reason} ->
        {-1, ""}
    end
  end

  def pwrite(ctx, fd, buf, offset), do: pwrite(ctx, fd, buf, IO.iodata_length(buf), offset)

  def pwrite(ctx, fd, buf, count, offset) do
    case syscall_value(ctx, :pwrite, [fd, buf, count, offset]) do
      {:ok, value} ->
        value

      :unavailable ->
        -1

      {:error, _reason} ->
        -1
    end
  end

  def bind(ctx, source, target, flags) do
    case syscall_value(ctx, :bind, [source, target, flags]) do
      {:ok, value} ->
        value

      :unavailable ->
        -1

      {:error, _reason} ->
        -1
    end
  end

  def chdir(ctx, path) do
    case syscall_value(ctx, :chdir, [path]) do
      {:ok, value} ->
        value

      :unavailable ->
        -1

      {:error, _reason} ->
        -1
    end
  end

  def dup(ctx, old, new) do
    case syscall_value(ctx, :dup, [old, new]) do
      {:ok, fd} when is_integer(fd) and fd >= 0 ->
        guest_fd_token(ctx, fd)

      {:ok, value} ->
        value

      :unavailable ->
        -1

      {:error, _reason} ->
        -1
    end
  end

  # sys->export(fd, dir, async): serve the namespace at `dir` over the already-open
  # Styx transport `fd` (exportfs.c). Routes through the host syscall door
  # (Emu.Port.SysHost :export → Emu.Port.Exportfs.export/3), exactly like dup/read.
  def export(ctx, fd, dir, flag) do
    case syscall_value(ctx, :export, [fd, dir, flag]) do
      {:ok, value} ->
        value

      :unavailable ->
        -1

      {:error, _reason} ->
        -1
    end
  end

  def fauth(ctx, fd, aname) do
    case syscall_value(ctx, :fauth, [fd, aname]) do
      {:ok, value} ->
        value

      :unavailable ->
        nil

      {:error, _reason} ->
        nil
    end
  end

  def fd2path(ctx, fd) do
    case syscall_value(ctx, :fd2path, [fd]) do
      {:ok, value} ->
        value

      :unavailable ->
        nil

      {:error, _reason} ->
        nil
    end
  end

  def fildes(ctx, fd) do
    case syscall_value(ctx, :fildes, [fd]) do
      {:ok, value} ->
        value

      :unavailable ->
        nil

      {:error, _reason} ->
        nil
    end
  end

  def file2chan(ctx, dir, file) do
    case syscall_value(ctx, :file2chan, [dir, file]) do
      {:ok, value} ->
        value

      :unavailable ->
        nil

      {:error, _reason} ->
        nil
    end
  end

  def fversion(ctx, fd, msize, version) do
    case syscall_value(ctx, :fversion, [fd, msize, version]) do
      {:ok, value} ->
        value

      :unavailable ->
        {-1, ""}

      {:error, _reason} ->
        {-1, ""}
    end
  end

  def fwstat(ctx, fd, dir) do
    case syscall_value(ctx, :fwstat, [fd, dir]) do
      {:ok, value} ->
        value

      :unavailable ->
        -1

      {:error, _reason} ->
        -1
    end
  end

  def mount(ctx, fd, afd, target, flags, spec) do
    case syscall_value(ctx, :mount, [fd, afd, target, flags, spec]) do
      {:ok, value} ->
        value

      :unavailable ->
        -1

      {:error, _reason} ->
        -1
    end
  end

  def mount(ctx, service, dir, opts) do
    case syscall_value(ctx, :mount, [service, dir, opts]) do
      {:ok, value} -> value
      :unavailable -> -1
      {:error, _reason} -> -1
    end
  end

  def listen(ctx, connection) do
    case syscall_value(ctx, :listen, [connection_arg(connection)]) do
      {:ok, value} ->
        value

      :unavailable ->
        {-1, nil}

      {:error, _reason} ->
        {-1, nil}
    end
  end

  defp connection_arg(%{} = connection) do
    %{
      "dfd" => Map.get(connection, "dfd", Map.get(connection, :dfd)),
      "cfd" => Map.get(connection, "cfd", Map.get(connection, :cfd)),
      "dir" => Map.get(connection, "dir", Map.get(connection, :dir))
    }
  end

  defp connection_arg(connection), do: connection

  def millisec(_ctx) do
    System.monotonic_time(:millisecond)
    |> Integer.mod(@maxint + 1)
  end

  def nulldir(_ctx), do: null_dir()

  def pctl(ctx, flags, movefd) do
    case syscall_value(ctx, :pctl, [flags, movefd]) do
      {:ok, value} -> value
      :unavailable -> -1
      {:error, _reason} -> -1
    end
  end

  def pipe(ctx), do: pipe(ctx, nil)

  def pipe(ctx, _fds) do
    case syscall_value(ctx, :pipe, []) do
      {:ok, value} ->
        value

      :unavailable ->
        {-1, []}

      {:error, _reason} ->
        {-1, []}
    end
  end

  def seek(ctx, fd, off, start) do
    case syscall_value(ctx, :seek, [fd, off, start]) do
      {:ok, value} ->
        value

      :unavailable ->
        -1

      {:error, _reason} ->
        -1
    end
  end

  def stream(ctx, src, dst, bufsiz) do
    case syscall_value(ctx, :stream, [src, dst, bufsiz]) do
      {:ok, value} -> value
      :unavailable -> -1
      {:error, _reason} -> -1
    end
  end

  def sleep(_ctx, period) when is_integer(period) and period >= 0 do
    Hyperlang.Scope.blocking(fn -> Process.sleep(period) end)
    0
  end

  def sleep(_ctx, _period), do: -1

  def tokenize(_ctx, s, delim) do
    with {:ok, s} <- nullable_string_arg(s),
         {:ok, delim} <- nullable_string_arg(delim) do
      tokens = tokenize_string(s, delim)
      {length(tokens), tokens}
    else
      _error -> {-1, []}
    end
  end

  def utfbytes(_ctx, buf, n) do
    with {:ok, bytes} <- bytes_arg(buf),
         {:ok, n} <- count_arg(n),
         true <- n <= byte_size(bytes) do
      complete_utf8_bytes(binary_part(bytes, 0, n), 0)
    else
      _error -> -1
    end
  end

  def unmount(ctx, source, target) do
    case syscall_value(ctx, :unmount, [source, target]) do
      {:ok, value} ->
        value

      :unavailable ->
        -1

      {:error, _reason} ->
        -1
    end
  end

  def close(ctx, fd) do
    case syscall_value(ctx, :close, [fd]) do
      {:ok, value} ->
        if is_integer(value) and value >= 0 do
          case close_fd_number(ctx, fd) do
            {:ok, closed_fd} -> Hyperlang.Filesystem.HostBackend.release_fd(closed_fd)
            {:error, _reason} -> :ok
          end

          Hyperlang.Filesystem.HostBackend.release_handle(fd)
        end

        value

      :unavailable ->
        -1

      {:error, _reason} ->
        -1
    end
  end

  def newns(ctx, path) do
    case syscall_value(ctx, :newns, [path]) do
      {:ok, value} -> value
      :unavailable -> -1
      {:error, _reason} -> -1
    end
  end

  def newns(ctx, user, path) do
    case syscall_value(ctx, :newns, [user, path]) do
      {:ok, value} -> value
      :unavailable -> -1
      {:error, _reason} -> -1
    end
  end

  def newns(ctx) do
    case syscall_value(ctx, :newns, []) do
      {:ok, value} -> value
      :unavailable -> -1
      {:error, _reason} -> -1
    end
  end

  # --- Dis channel primitives (libinterp/xec.c, libinterp/alt.c) ------------
  # Channel ops are VM-runtime calls,
  # not host-door syscalls. Hyperlang.Chan resolves guest handle scope through its
  # `:guest_channel_scope` hook. Channel handles are opaque integers; the guest
  # never sees a pid (which the term sanitizer would reject).

  # newchan(size) — chan of T (size 0) / chan[size] of T. Returns the handle, or
  # nil on failure (Limbo nil-channel).
  def newchan(_ctx, size) do
    runtime_channel_value(fn -> Hyperlang.Chan.newchan(size) end)
  end

  def newchan(_ctx, size, classification)
      when classification in [:handle_free, :may_contain_handles] do
    runtime_channel_value(fn -> Hyperlang.Chan.newchan(size, classification) end)
  end

  # startchan() — the host's command-start rendezvous. The runtime returns an
  # opaque negative integer capability that only csend/crecv understand; it is
  # not a Limbo channel and cannot be armed by alt.
  def startchan(_ctx) do
    runtime_channel_value(fn -> Hyperlang.Chan.startchan() end)
  end

  def sys_startchan(ctx), do: startchan(ctx)

  # csend(c, v) — `c <-= v`. Blocking send; returns the channel handle (truthy)
  # on success, nil on a bad/closed channel.
  # A guest channel send follows the `!` carrier rule: a fun, pid, port or
  # ref anywhere in the value raises like `!` does, before any channel is
  # touched. Host kernels that pass broker pids use Hyperlang.Chan directly.
  def csend(_ctx, c, v) do
    reject_forbidden_carriers!(v)
    runtime_channel_value(fn -> Hyperlang.Chan.csend(c, v) end)
  end

  # crecv(c) — `<-c`. Blocking receive; returns the value.
  def crecv(_ctx, c) do
    runtime_channel_value(fn -> Hyperlang.Chan.crecv(c) end)
  end

  # alt(ops) — `alt { ... }`. Arms are `{recv, C}` (or `{'receive', C}`),
  # `{send, C, V}`, `default` (the `*` arm), and the labelled forms
  # `{Label, recv, C}` / `{Label, send, C, V}`. A fired recv returns
  # `{Index, Value}`, a fired send `{Index, ok}`, and the default arm returns
  # the guest's own `default` atom. A labelled arm reports its Label in place
  # of the 0-based Index. A malformed op list or a bad channel returns nil.
  def alt(ctx, ops) when is_list(ops) do
    with {:ok, arms} <- alt_arms(ctx, ops) do
      for {_key, {:send, _handle, value}} <- arms, do: reject_forbidden_carriers!(value)

      case runtime_channel_value(fn -> Hyperlang.Chan.alt(Enum.map(arms, &elem(&1, 1))) end) do
        {:recv, index, value} -> {alt_arm_key(arms, index), value}
        {:send, index} -> {alt_arm_key(arms, index), :ok}
        :default -> arms |> Enum.find(&(elem(&1, 1) == :default)) |> elem(0)
        _other -> nil
      end
    else
      :error -> nil
    end
  end

  def alt(_ctx, _ops), do: nil

  defp reject_forbidden_carriers!(value) do
    with {:error, reason} <- :hyperlang_msg.reject_forbidden_carriers(value),
         do: :erlang.error({:hyperlang_send, reason})
  end

  defp runtime_channel_value(fun) when is_function(fun, 0) do
    case Hyperlang.Scope.blocking(fun) do
      {:error, _reason} -> nil
      value -> value
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # builtin(kind, func, args) — statically-linked builtin module call. This is
  # the holder-free replacement for `load "$Keyring"` / `load "$IPints"` when
  # the guest dependency is known at compile/link time. It remains a host syscall
  # boundary, but no loaded-module handle or module data segment is allocated.
  def builtin(ctx, kind, func, args) do
    case syscall_value(ctx, :builtin, [kind, func, args]) do
      {:ok, {:hyperlang_guest_throw, throw_term}} -> throw(throw_term)
      {:ok, value} -> value
      :unavailable -> nil
      {:error, reason} -> {:hyperlang_syscall_error, reason}
    end
  end

  def exec_lowered(ctx, command, argv),
    do: do_exec_lowered(ctx, command, argv, %{}, false)

  def exec_lowered(ctx, command, argv, options),
    do: do_exec_lowered(ctx, command, argv, options, true)

  defp do_exec_lowered(ctx, command, argv, options, include_opts?) do
    case Hyperlang.Runtime.exec_lowering_args(ctx, command, argv, options, include_opts?) do
      {:ok, {path, argv, opts}} ->
        case :hyperlang_msg.exec(path, argv, opts, ctx) do
          {:exec_status, status} -> throw({:hyperlang_exits, status})
          {:error, _reason} -> -1
          value -> maybe_overlay_exec(value)
        end

      {:error, _reason} ->
        nil
    end
  end

  # sys:exec(command, argv[, options]) — the TERMINAL exec primitive. The guest
  # surface remains `sys:exec`, but the runtime now lowers it to the kernel's
  # `:guest_exec_hook` instead of the syscall door. Successful image completion
  # unwinds this Prog with the replacement image's status; load failure returns
  # -1 with `%r` already set by the kernel hook.
  def exec(ctx, command, argv), do: exec_lowered(ctx, command, argv)

  def exec(ctx, command, argv, options), do: exec_lowered(ctx, command, argv, options)

  defp maybe_overlay_exec(%{<<"__hyperbob_os_exec_overlay__">> => true} = value),
    do: throw({:hyperbob_os_exec_overlay, value})

  defp maybe_overlay_exec(value), do: value

  def exits(_ctx, status), do: throw({:hyperlang_exits, exit_status(status)})

  defp exit_status(nil), do: <<>>
  defp exit_status(status) when is_binary(status), do: status
  defp exit_status(status), do: IO.iodata_to_binary(status)

  def finit(ctx) do
    case syscall_value(ctx, :finit, []) do
      {:ok, value} -> value
      :unavailable -> -1
      {:error, _reason} -> -1
    end
  end

  def postnote(ctx, who, pid, note) do
    case syscall_value(ctx, :postnote, [who, pid, note]) do
      {:ok, value} -> value
      :unavailable -> -1
      {:error, _reason} -> -1
    end
  end

  def werrstr(ctx, s) do
    case syscall_value(ctx, :werrstr, [s]) do
      {:ok, value} -> value
      :unavailable -> -1
      {:error, _reason} -> -1
    end
  end

  def wstat(ctx, path, dir) do
    case syscall_value(ctx, :wstat, [path, dir]) do
      {:ok, value} ->
        value

      :unavailable ->
        -1

      {:error, _reason} ->
        -1
    end
  end

  def zerodir(_ctx), do: zero_dir()

  for source_arity <- 1..8 do
    args = for index <- 1..source_arity, do: Macro.var(:"arg#{index}", __MODULE__)
    def aprint(ctx, unquote_splicing(args)), do: do_aprint(ctx, [unquote_splicing(args)])
    def print(ctx, unquote_splicing(args)), do: do_print(ctx, [unquote_splicing(args)])
    def sprint(ctx, unquote_splicing(args)), do: do_sprint(ctx, [unquote_splicing(args)])
  end

  for source_arity <- 2..9 do
    args = for index <- 1..source_arity, do: Macro.var(:"arg#{index}", __MODULE__)
    def fprint(ctx, unquote_splicing(args)), do: do_fprint(ctx, [unquote_splicing(args)])
  end

  defp do_aprint(ctx, args) do
    case format_args(ctx, args) do
      {:ok, bytes} -> bytes
      {:error, _reason} -> nil
    end
  end

  defp do_sprint(ctx, args), do: do_aprint(ctx, args)

  defp do_print(ctx, args) do
    with {:ok, bytes} <- format_args(ctx, args),
         :ok <- write_formatted(ctx, 1, bytes) do
      byte_size(bytes)
    else
      _error -> -1
    end
  end

  defp do_fprint(ctx, [fd | args]) do
    with {:ok, bytes} <- format_args(ctx, args),
         :ok <- write_formatted(ctx, fd, bytes) do
      byte_size(bytes)
    else
      _error -> -1
    end
  end

  defp format_args(ctx, [format | values]) do
    with {:ok, [format | values]} <-
           Hyperlang.Terms.sanitize_filesystem_args([format | values], ctx),
         {:ok, format} <- nullable_string_arg(format) do
      inferno_format(ctx, format, values)
    end
  end

  defp format_args(_ctx, []), do: {:error, :badarg}

  defp write_formatted(ctx, fd, bytes) do
    with {:ok, fd} <- fd_number_or_int(ctx, fd),
         count when count == byte_size(bytes) <- write(ctx, fd, bytes, byte_size(bytes)) do
      :ok
    else
      _error -> {:error, :write_failed}
    end
  end

  defp inferno_format(ctx, format, values), do: do_inferno_format(ctx, format, values, [])

  defp do_inferno_format(_ctx, "", _values, acc) do
    {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp do_inferno_format(ctx, <<"%", rest::binary>>, values, acc) do
    with {:ok, directive, rest} <- parse_directive(rest),
         {:ok, bytes, values} <- render_directive(ctx, directive, values) do
      do_inferno_format(ctx, rest, values, [bytes | acc])
    end
  end

  defp do_inferno_format(ctx, <<char::utf8, rest::binary>>, values, acc) do
    do_inferno_format(ctx, rest, values, [<<char::utf8>> | acc])
  end

  defp do_inferno_format(_ctx, _format, _values, _acc), do: {:error, :badarg}

  defp parse_directive(<<"%", rest::binary>>), do: {:ok, %{verb: ?%, flags: ""}, rest}
  defp parse_directive(rest), do: collect_directive(rest, "")

  defp collect_directive("", _flags), do: {:error, :badfmt}

  defp collect_directive(<<verb, rest::binary>>, flags) when verb in ~c"cdosqxXr%efgEFG" do
    {:ok, directive_spec(verb, flags), rest}
  end

  defp collect_directive(<<"u", rest::binary>>, flags), do: collect_directive(rest, flags <> "u")

  defp collect_directive(<<char, rest::binary>>, flags)
       when char in ~c"#-+ 0,." or char in ?0..?9 do
    collect_directive(rest, flags <> <<char>>)
  end

  defp collect_directive(_rest, _flags), do: {:error, :badfmt}

  defp directive_spec(verb, flags) do
    {width, precision} = parse_width_precision(flags)

    %{
      verb: verb,
      flags: flags,
      alt?: String.contains?(flags, "#"),
      left?: String.contains?(flags, "-"),
      sign?: String.contains?(flags, "+"),
      space?: String.contains?(flags, " "),
      zero?: String.contains?(flags, "0") and not String.contains?(flags, "-"),
      width: width,
      precision: precision
    }
  end

  defp parse_width_precision(flags) do
    flags =
      flags
      |> String.replace("#", "")
      |> String.replace("-", "")
      |> String.replace("+", "")
      |> String.replace(" ", "")
      |> String.replace(",", "")
      |> String.replace("u", "")

    case String.split(flags, ".", parts: 2) do
      [width, precision] -> {digits_or_nil(width), digits_or_nil(precision) || 0}
      [width] -> {digits_or_nil(width), nil}
    end
  end

  defp digits_or_nil(""), do: nil

  defp digits_or_nil(digits) do
    if String.match?(digits, ~r/^\d+$/), do: String.to_integer(digits), else: nil
  end

  defp render_directive(_ctx, %{verb: ?%}, values), do: {:ok, "%", values}

  defp render_directive(ctx, %{verb: ?r} = spec, values) do
    {:ok, apply_text_width(current_errstr(ctx), spec), values}
  end

  defp render_directive(_ctx, %{verb: ?s} = spec, [value | values]) do
    with {:ok, string} <- printable_string(value) do
      {:ok, string |> apply_string_precision(spec) |> apply_text_width(spec), values}
    end
  end

  defp render_directive(_ctx, %{verb: ?q} = spec, [value | values]) do
    with {:ok, string} <- printable_string(value) do
      {:ok, string |> quote_if_needed(spec) |> apply_text_width(spec), values}
    end
  end

  defp render_directive(_ctx, %{verb: ?c} = spec, [value | values]) do
    with {:ok, rune} <- rune_arg(value) do
      {:ok, <<rune::utf8>> |> apply_text_width(spec), values}
    end
  end

  defp render_directive(_ctx, %{verb: verb} = spec, [value | values]) when verb in ~c"doxX" do
    with {:ok, int} <- int_arg(value) do
      {:ok, format_integer(int, verb, spec), values}
    end
  end

  # Float verbs %e/%f/%g (+ uppercase %E/%G/%F). Inferno `sys->print` routes these
  # to lib9/fltfmt.c `_efgfmt`/`xdtoa` (Rob Pike / Ken Thompson). The rendering is
  # NOT standard C printf: Inferno strips a leading "0" before the decimal point
  # (`0.5` -> `.5`), shows `prec+1` significant digits for %g (so `%.4g` keeps 5
  # sig figs), switches %g to e-style when `e < -5 || e > prec`, and always emits a
  # signed >=2-digit exponent (`e+07`). `format_float/3` is a faithful port of
  # `xdtoa`; width/justification then apply through the shared `apply_text_width`.
  defp render_directive(_ctx, %{verb: verb} = spec, [value | values])
       when verb in ~c"efgEFG" do
    with {:ok, float} <- float_arg(value) do
      {:ok, format_float(float, verb, spec) |> apply_text_width(spec), values}
    end
  end

  defp render_directive(_ctx, _directive, _values), do: {:error, :badarg}

  defp printable_string(value) when is_binary(value) do
    if String.valid?(value), do: {:ok, value}, else: {:error, :badarg}
  end

  defp printable_string(value) when is_list(value) do
    if Enum.all?(value, &is_integer/1), do: {:ok, List.to_string(value)}, else: {:error, :badarg}
  rescue
    _error -> {:error, :badarg}
  end

  defp printable_string(_value), do: {:error, :badarg}

  defp int_arg(value) when is_integer(value), do: {:ok, value}
  defp int_arg(_value), do: {:error, :badarg}

  # A Limbo `real` arrives as a native float; an integer arg to a float verb is
  # promoted (C varargs widen an int to double only if the caller cast it, but a
  # faithful guest passes a `real`, so accept both rather than fail the format).
  defp float_arg(value) when is_float(value), do: {:ok, value}
  defp float_arg(value) when is_integer(value), do: {:ok, value * 1.0}
  defp float_arg(_value), do: {:error, :badarg}

  defp format_integer(value, ?d, spec), do: format_integer_base(value, 10, "", false, spec)

  defp format_integer(value, ?o, spec) do
    prefix = if spec.alt? and value != 0, do: "0", else: ""
    format_integer_base(value, 8, prefix, false, spec)
  end

  defp format_integer(value, ?x, spec) do
    prefix = if spec.alt? and value != 0, do: "0x", else: ""
    format_integer_base(value, 16, prefix, false, spec)
  end

  defp format_integer(value, ?X, spec) do
    prefix = if spec.alt? and value != 0, do: "0X", else: ""
    format_integer_base(value, 16, prefix, true, spec)
  end

  defp format_integer_base(value, base, prefix, upper?, spec) do
    sign = if value < 0, do: "-", else: ""

    digits =
      value
      |> abs()
      |> Integer.to_string(base)
      |> apply_integer_case(upper?)

    precision = spec.precision || 0
    digits = String.pad_leading(digits, precision, "0")

    text = sign <> prefix <> digits

    if spec.zero? and spec.precision == nil and spec.width do
      pad = max(spec.width - String.length(text), 0)
      sign <> prefix <> String.duplicate("0", pad) <> digits
    else
      text
    end
    |> apply_text_width(%{spec | zero?: false})
  end

  defp apply_integer_case(string, true), do: String.upcase(string)
  defp apply_integer_case(string, false), do: String.downcase(string)

  # ==========================================================================
  # Float formatting — a faithful port of lib9/fltfmt.c `xdtoa` (Rob Pike / Ken
  # Thompson, Lucent). Inferno's `sys->print`/`fprint`/`sprint`/`aprint` route
  # %e/%f/%g (and uppercase %E/%F/%G) here. The output is deliberately NOT C
  # printf: leading "0." becomes ".", %g uses `prec+1` significant digits and
  # switches to e-style when `e < -5 || e > prec`, and the exponent is always a
  # signed >=2-digit field. Tuned constants are the originals:
  #   FDIGIT=30 (max precision), FDEFLT=6 (default precision), NSIGNIF=17.
  # The integer/string digit array `s1` is carried as a charlist; `xadd`/`xsub`
  # are the carry add/subtract on it; `frexp` supplies the binary exponent.
  # ==========================================================================
  @fdigit 30
  @fdeflt 6
  @nsignif 17

  defp format_float(f, verb, spec) do
    chr = lower_verb(verb)
    ucase? = verb >= ?A and verb <= ?Z

    prec =
      case spec.precision do
        nil -> @fdeflt
        p when p > @fdigit -> @fdigit
        p -> p
      end

    # BEAM floats are always finite, non-NaN IEEE-754 doubles (the runtime raises
    # on inf/NaN arithmetic and the term sanitiser only admits finite floats), so
    # the fltfmt.c NaN/Inf paths cannot fire here. Kept structurally as a guard
    # comment; the live path is xdtoa proper (recorded BEAM divergence).
    xdtoa(abs(f), f < 0, chr, ucase?, prec, spec)
  end

  defp lower_verb(?E), do: ?e
  defp lower_verb(?F), do: ?f
  defp lower_verb(?G), do: ?g
  defp lower_verb(verb), do: verb

  # xdtoa proper. `f` is the magnitude (>= 0); `sign?` carries the original sign.
  defp xdtoa(f, sign?, chr, ucase?, prec, spec) do
    # Normalise to scientific: find decimal exponent `e` and the 17-digit string
    # `s1` of significant digits (fltfmt.c lines 102-179).
    {s1, e} = xdtoa_digits(f)

    # Sign prefix (fltfmt.c lines 185-192).
    sign_str =
      cond do
        sign? -> "-"
        spec.sign? -> "+"
        spec.space? -> " "
        true -> ""
      end

    # Decide style + the four counters c1/c2/c3/c4 (fltfmt.c lines 201-242).
    {s1, e, c1, c2, c3, c4, chr} = xdtoa_style(s1, e, chr, prec)

    # Lay out the digits with the decimal point (fltfmt.c lines 246-264).
    body = xdtoa_layout(s1, c1, c2, c3, c4)

    # Trailing-zero strip for %g/%h, or force-point under '#' (lines 269-284).
    body = xdtoa_trim(body, c4, chr, spec.alt?)

    # Exponent suffix for %e/%g (fltfmt.c lines 285-302).
    exp = xdtoa_exp(e, chr, ucase?)

    sign_str <> body <> exp
  end

  # Produce the NSIGNIF(=17)-significant-digit charlist `s1` and decimal exponent
  # `e` (the position of the leading digit), such that the decimal s1·10^(e-16)
  # round-trips to exactly `f` (i.e. strtod(that) == f). This is precisely what
  # fltfmt.c:102-179 computes: a frexp seed normalises f into [1,10) carrying a
  # decimal exponent, NSIGNIF digits are extracted, then a strtod-driven loop
  # nudges the last digit until the reconstructed double equals f. The BEAM port
  # follows the SAME structure; the only divergence is that `value_of/2`
  # reconstructs the candidate via a single correctly-rounded decimal->double
  # parse (one rounding, matching C `strtod`) rather than a mantissa·pow10 product
  # (which double-rounds and drifted in the 17th digit). The frexp seed and
  # extraction use the same double-precision pow10 as fltfmt.c, so the digits the
  # loop starts from — and converges to — are identical to C's.
  defp xdtoa_digits(f) when f == 0.0, do: {List.duplicate(?0, @nsignif), 0}

  defp xdtoa_digits(f) do
    e2 = frexp_exp(f)
    e0 = trunc(e2 * 0.301029995664)

    {d, h} =
      if e0 >= -150 and e0 <= 150 do
        {0, f}
      else
        d = div(e0, 2)
        {d, f * pow10(-d)}
      end

    # Normalise g into [1, 10) adjusting e (fltfmt.c:114-122).
    e = normalize_exp(h, d, e0)
    g0 = h * pow10(d - e)

    # Extract NSIGNIF digits (fltfmt.c:129-134).
    s1 = extract_digits(g0, @nsignif, [])

    # Refine s1/e so the reconstructed double equals f exactly (fltfmt.c:165-179).
    refine_loop(s1, e, f, 0)
  end

  # The binary exponent e2 with f == mantissa·2^e2, mantissa in [0.5, 1) — i.e.
  # C `frexp(f, &e2)`'s out-param. Only e2 is consumed (the decimal-exponent
  # seed). :math.frexp is absent in this OTP, so read it from the IEEE-754 bits.
  defp frexp_exp(f) do
    <<_sign::1, exp::11, frac::52>> = <<abs(f)::float>>

    cond do
      exp == 0 -> 52 - msb_index(frac) - 1074 + 1
      true -> exp - 1023 + 1
    end
  end

  defp msb_index(0), do: 0
  defp msb_index(n), do: trunc(:math.log2(n))

  # pow10(n) verbatim from lib9/pow10.c — the recursive split (the table is the
  # same IEEE-754 double powers BEAM produces, so :math.pow(10, n) for |n| < 160
  # is identical; |n| >= 160 splits exactly as the C does).
  defp pow10(n) when n < 0 do
    m = -n
    if m < 160, do: 1 / :math.pow(10, m), else: 1 / (pow10(div(m, 2)) * pow10(m - div(m, 2)))
  end

  defp pow10(n) do
    if n < 160, do: :math.pow(10, n), else: pow10(div(n, 2)) * pow10(n - div(n, 2))
  end

  defp normalize_exp(h, d, e) do
    g = h * pow10(d - e)

    cond do
      g < 1 -> normalize_exp(h, d, e - 1)
      g >= 10 -> normalize_exp_up(h, d, e)
      true -> e
    end
  end

  defp normalize_exp_up(h, d, e) do
    g = h * pow10(d - e)
    if g >= 10, do: normalize_exp_up(h, d, e + 1), else: e
  end

  defp extract_digits(_g, 0, acc), do: Enum.reverse(acc)

  defp extract_digits(g, n, acc) do
    d = trunc(g)
    extract_digits((g - d) * 10, n - 1, [?0 + d | acc])
  end

  # fltfmt.c:165-179 strtod refinement: nudge the last digit ±1 until the
  # reconstructed double equals f. Bounded by 64 steps (converges in 0-1 in
  # practice). xadd/xsub carry across the digit string.
  defp refine_loop(s1, e, _f, n) when n > 64, do: {s1, e}

  defp refine_loop(s1, e, f, n) do
    g = value_of(s1, e)

    cond do
      f > g ->
        case xadd(s1, @nsignif - 1, 1) do
          {s1, true} -> refine_loop(s1, e - 1, f, n + 1)
          {s1, false} -> refine_loop(s1, e, f, n + 1)
        end

      f < g ->
        case xsub(s1, @nsignif - 1, 1) do
          {s1, true} -> refine_loop(s1, e + 1, f, n + 1)
          {s1, false} -> refine_loop(s1, e, f, n + 1)
        end

      true ->
        {s1, e}
    end
  end

  # Reconstruct the double denoted by digit-list s1 with leading-digit exponent e:
  # the integer d1d2...dN scaled by 10^(e-N+1). A SINGLE correctly-rounded decimal
  # -> double parse ("<int>e<scale>"), matching C `strtod` (one rounding).
  defp value_of(s1, e) do
    intdigits = List.to_string(s1)
    scale = e - @nsignif + 1
    {value, ""} = Float.parse(intdigits <> "e" <> Integer.to_string(scale))
    value
  end

  # fltfmt.c:201-242 — choose 'e'/'f'/'g'(->'h') style and counters.
  defp xdtoa_style(s1, e, chr, prec) do
    c2 = prec + 1

    case chr do
      ?g ->
        {s1, e} = round5(s1, c2, e)

        if e >= -5 and e <= prec do
          # 'f' style flagged as 'h'
          finish_counters(s1, e, ?h, -e - 1, c2, prec - e)
        else
          finish_counters(s1, e, ?g, 0, c2, prec)
        end

      ?f ->
        {s1, e} = round5(s1, c2 + e, e)
        c1 = -e
        c1 = if c1 > prec, do: c2, else: c1
        finish_counters(s1, e, ?f, c1, c2 + e, prec)

      _ ->
        {s1, e} = round5(s1, c2, e)
        finish_counters(s1, e, chr, 0, c2, prec)
    end
  end

  # default-case rounding (fltfmt.c:207 / inside the 'g'/'f' cases): xadd(s1, c2, 5).
  defp round5(s1, pos, e) do
    case xadd(s1, pos, 5) do
      {s1, true} -> {s1, e + 1}
      {s1, false} -> {s1, e}
    end
  end

  # Clean up c1/c2/c3 (fltfmt.c:235-242) and bundle for layout.
  defp finish_counters(s1, e, chr, c1, c2, c4) do
    c1 = max(c1, 0)
    c2 = max(c2, 0)

    {c2, c3} =
      if c2 > @nsignif do
        {@nsignif, c2 - @nsignif}
      else
        {c2, 0}
      end

    {s1, e, c1, c2, c3, c4, chr}
  end

  # fltfmt.c:246-264 — emit c1 leading zeros, c2 conversion digits, c3 trailing
  # zeros, inserting '.' at the c4-from-the-right boundary. `s1` is the digit
  # tuple; `i` indexes the next conversion digit.
  defp xdtoa_layout(s1, c1, c2, c3, c4) do
    arr = List.to_tuple(s1)
    {acc, i} = lay_leading(c1, c2, c3, c4, [])
    {acc, _i} = lay_conv(acc, i, arr, c2, c3, c4)
    acc = lay_trailing(acc, c3, c4)
    acc |> Enum.reverse() |> List.to_string()
  end

  defp lay_leading(0, _c2, _c3, _c4, acc), do: {acc, 0}

  defp lay_leading(c1, c2, c3, c4, acc) do
    acc = if c1 + c2 + c3 == c4, do: [?. | acc], else: acc
    lay_leading(c1 - 1, c2, c3, c4, [?0 | acc])
  end

  defp lay_conv(acc, i, _arr, 0, _c3, _c4), do: {acc, i}

  defp lay_conv(acc, i, arr, c2, c3, c4) do
    acc = if c2 + c3 == c4, do: [?. | acc], else: acc
    lay_conv([elem(arr, i) | acc], i + 1, arr, c2 - 1, c3, c4)
  end

  defp lay_trailing(acc, 0, _c4), do: acc

  defp lay_trailing(acc, c3, c4) do
    acc = if c3 == c4, do: [?. | acc], else: acc
    lay_trailing([?0 | acc], c3 - 1, c4)
  end

  # fltfmt.c:269-284 — under '#', force a trailing '.' when c4==0; otherwise for
  # 'g'/'h' strip trailing zeros (and a dangling '.').
  defp xdtoa_trim(body, c4, _chr, true) do
    if c4 == 0, do: body <> ".", else: body
  end

  defp xdtoa_trim(body, _c4, chr, false) when chr in [?g, ?h] do
    chars = String.to_charlist(body)
    n = last_nonzero_index(chars, length(chars) - 1)

    case dot_index(chars, n) do
      nil ->
        body

      {dot_i, n} ->
        keep = if dot_i != n, do: n + 1, else: n
        chars |> Enum.take(keep) |> List.to_string()
    end
  end

  defp xdtoa_trim(body, _c4, _chr, false), do: body

  defp last_nonzero_index(_chars, n) when n < 0, do: -1

  defp last_nonzero_index(chars, n) do
    if Enum.at(chars, n) != ?0, do: n, else: last_nonzero_index(chars, n - 1)
  end

  # Walk back from n looking for the '.'; return {dot_index, n} or nil (no point).
  defp dot_index(_chars, n) when n < 0, do: nil

  defp dot_index(chars, orig_n) do
    do_dot_index(chars, orig_n, orig_n)
  end

  defp do_dot_index(_chars, i, _n) when i < 0, do: nil

  defp do_dot_index(chars, i, n) do
    if Enum.at(chars, i) == ?., do: {i, n}, else: do_dot_index(chars, i - 1, n)
  end

  # fltfmt.c:285-302 — exponent suffix for 'e'/'g' (NOT 'f'/'h'). Sign + >=2 digits.
  defp xdtoa_exp(e, chr, ucase?) when chr in [?e, ?g] do
    ech = if ucase?, do: "E", else: "e"
    sign = if e < 0, do: "-", else: "+"
    mag = abs(e)

    digits =
      cond do
        mag >= 100 -> Integer.to_string(mag)
        true -> mag |> Integer.to_string() |> String.pad_leading(2, "0")
      end

    ech <> sign <> digits
  end

  defp xdtoa_exp(_e, _chr, _ucase?), do: ""

  # xadd/xsub (fltfmt.c:24-63) — add/subtract `v` at digit position `n`, carrying.
  # Operate on the charlist; return {new_list, overflow?}.
  defp xadd(s1, n, _v) when n < 0 or n >= @nsignif, do: {s1, false}

  defp xadd(s1, n, v) do
    arr = List.to_tuple(s1)
    xadd_loop(arr, n, v)
  end

  defp xadd_loop(arr, b, _v) when b < 0 do
    # *a = '1'; return 1  (overflow adding)
    {tuple_set(arr, 0, ?1) |> Tuple.to_list(), true}
  end

  defp xadd_loop(arr, b, v) do
    c = elem(arr, b) + v

    if c <= ?9 do
      {tuple_set(arr, b, c) |> Tuple.to_list(), false}
    else
      xadd_loop(tuple_set(arr, b, ?0), b - 1, 1)
    end
  end

  defp xsub(s1, n, v) do
    arr = List.to_tuple(s1)
    xsub_loop(arr, n, v)
  end

  defp xsub_loop(arr, b, _v) when b < 0 do
    {tuple_set(arr, 0, ?9) |> Tuple.to_list(), true}
  end

  defp xsub_loop(arr, b, v) do
    c = elem(arr, b) - v

    if c >= ?0 do
      {tuple_set(arr, b, c) |> Tuple.to_list(), false}
    else
      xsub_loop(tuple_set(arr, b, ?9), b - 1, 1)
    end
  end

  defp tuple_set(tuple, index, value), do: put_elem(tuple, index, value)

  defp apply_string_precision(string, %{precision: nil}), do: string

  defp apply_string_precision(string, %{precision: precision}),
    do: String.slice(string, 0, precision)

  defp apply_text_width(string, %{width: nil}), do: string

  defp apply_text_width(string, %{width: width, left?: left?}) do
    padding = max(width - String.length(string), 0)

    if left? do
      string <> String.duplicate(" ", padding)
    else
      String.duplicate(" ", padding) <> string
    end
  end

  defp quote_if_needed(string, spec) do
    if spec.alt? or quote_needed?(string) do
      "'" <> String.replace(string, "'", "''") <> "'"
    else
      string
    end
  end

  defp quote_needed?(""), do: true

  defp quote_needed?(string) do
    String.contains?(string, [
      " ",
      "\t",
      "\n",
      "'",
      "$",
      "&",
      "|",
      ";",
      "<",
      ">",
      "(",
      ")",
      "{",
      "}"
    ])
  end

  defp current_errstr(ctx), do: Hyperlang.Runtime.errstr(ctx)

  # Operations whose listed argument positions carry an fd. Guests may hold
  # either a raw kernel fd integer or an opaque fd token map (one handle type
  # shared with the file:/filelib: mirror); token maps are unwrapped to the
  # kernel integer before crossing the syscall boundary.
  @fd_positions %{
    close: [0],
    dirread: [0],
    dup: [0, 1],
    export: [0],
    fd2path: [0],
    fauth: [0],
    fildes: [0],
    fstat: [0],
    fwstat: [0],
    iounit: [0],
    mount: [0, 1],
    pread: [0],
    pwrite: [0],
    read: [0],
    seek: [0],
    stream: [0, 1],
    write: [0]
  }

  defp syscall_value(ctx, operation, args) do
    with {:ok, args} <- normalize_fd_args(ctx, operation, args) do
      Hyperlang.Runtime.syscall(ctx, operation, args)
      |> case do
        {:ok, value} -> {:ok, value}
        {:error, :syscall_unavailable} -> :unavailable
        {:error, reason} -> {:error, reason}
      end
    end
  catch
    :error, {:sandbox, :filesystem_error, reason} -> {:error, reason}
    :error, {:sandbox, :syscall_error, reason} -> {:error, reason}
  end

  defp normalize_fd_args(_ctx, operation, args)
       when operation in [:bind, :chdir, :exec, :open, :pctl, :remove, :stat, :werrstr],
       do: {:ok, args}

  defp normalize_fd_args(_ctx, operation, [fd] = args)
       when operation in [:close, :dirread, :fd2path, :fildes, :fstat, :iounit] and
              is_integer(fd),
       do: {:ok, args}

  defp normalize_fd_args(_ctx, operation, [fd, _arg] = args)
       when operation in [:fauth, :fwstat, :read, :write] and is_integer(fd),
       do: {:ok, args}

  defp normalize_fd_args(_ctx, operation, [fd, _arg1, _arg2] = args)
       when operation in [:export, :read, :seek, :write] and is_integer(fd),
       do: {:ok, args}

  defp normalize_fd_args(_ctx, operation, [fd, _arg1, _arg2, _arg3] = args)
       when operation in [:pread, :pwrite] and is_integer(fd),
       do: {:ok, args}

  defp normalize_fd_args(_ctx, :dup, [old, new] = args) when is_integer(old) and is_integer(new),
    do: {:ok, args}

  defp normalize_fd_args(_ctx, :mount, [fd, afd, _target, _flags, _spec] = args)
       when is_integer(fd) and (is_integer(afd) or is_nil(afd)),
       do: {:ok, args}

  defp normalize_fd_args(_ctx, :stream, [src, dst, _bufsiz] = args)
       when is_integer(src) and is_integer(dst),
       do: {:ok, args}

  defp normalize_fd_args(ctx, operation, args) do
    case Map.get(@fd_positions, operation) do
      nil ->
        {:ok, args}

      positions ->
        Enum.reduce_while(positions, {:ok, args}, fn position, {:ok, args} ->
          case Enum.at(args, position) do
            value when is_reference(value) or is_map(value) ->
              case fd_number(ctx, value) do
                {:ok, fd} -> {:cont, {:ok, List.replace_at(args, position, fd)}}
                {:error, reason} -> {:halt, {:error, reason}}
              end

            _other ->
              {:cont, {:ok, args}}
          end
        end)
    end
  end

  defp do_readn(_ctx, _fd, 0, acc) do
    bytes = acc |> Enum.reverse() |> IO.iodata_to_binary()
    {byte_size(bytes), bytes}
  end

  defp do_readn(ctx, fd, remaining, acc) do
    case read_once(ctx, fd, remaining) do
      {:ok, ""} ->
        bytes = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {byte_size(bytes), bytes}

      {:ok, bytes} ->
        size = byte_size(bytes)
        do_readn(ctx, fd, remaining - size, [bytes | acc])

      :eof ->
        bytes = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {byte_size(bytes), bytes}

      {:error, _reason} ->
        if acc == [] do
          {-1, ""}
        else
          bytes = acc |> Enum.reverse() |> IO.iodata_to_binary()
          {byte_size(bytes), bytes}
        end
    end
  end

  defp read_once(ctx, fd, count) when is_integer(count) and count >= 0 do
    case syscall_value(ctx, :read, [fd, <<>>, count]) do
      {:ok, {n, bytes}} when is_integer(n) and n >= 0 and is_binary(bytes) ->
        {:ok, binary_part(bytes, 0, min(n, byte_size(bytes)))}

      {:ok, bytes} when is_binary(bytes) ->
        {:ok, bytes}

      {:ok, :eof} ->
        :eof

      :unavailable ->
        {:error, :syscall_unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_once(_ctx, _fd, _count), do: {:error, :badarg}

  defp guest_fd_token(%{@guest_fd_tokens_key => true}, fd) when is_integer(fd) and fd >= 0,
    do: Hyperlang.Filesystem.HostBackend.handle(fd, false, false)

  defp guest_fd_token(%{@guest_fd_tokens_key => true} = ctx, %{@fd_key => fd})
       when is_integer(fd) and fd >= 0,
       do: guest_fd_token(ctx, fd)

  defp guest_fd_token(%{@guest_fd_tokens_key => true} = ctx, %{<<"$sys_fd">> => fd})
       when is_integer(fd) and fd >= 0,
       do: guest_fd_token(ctx, fd)

  defp guest_fd_token(_ctx, fd), do: fd

  defp close_fd_number(_ctx, fd) when is_integer(fd) and fd >= 0, do: {:ok, fd}
  defp close_fd_number(ctx, fd), do: fd_number(ctx, fd)

  def fd_number(_ctx, fd) when is_reference(fd),
    do: Hyperlang.Filesystem.HostBackend.fd_number(fd)

  def fd_number(_ctx, %{@fd_key => fd} = token)
      when map_size(token) == 1 and is_integer(fd) and fd >= 0,
      do: {:ok, fd}

  def fd_number(_ctx, %{<<"fd">> => fd} = token)
      when map_size(token) == 1 and is_integer(fd) and fd >= 0,
      do: {:ok, fd}

  def fd_number(ctx, fd) do
    with {:ok, [fd]} <- Hyperlang.Terms.sanitize_filesystem_args([fd], ctx) do
      case fd do
        %{@fd_key => fd} when is_integer(fd) and fd >= 0 -> {:ok, fd}
        %{<<"fd">> => fd} when is_integer(fd) and fd >= 0 -> {:ok, fd}
        %{"fd" => fd} when is_integer(fd) and fd >= 0 -> {:ok, fd}
        _other -> {:error, :ebadf}
      end
    end
  end

  def fd_number_or_int(_ctx, fd) when is_integer(fd) and fd >= 0, do: {:ok, fd}
  def fd_number_or_int(ctx, fd), do: fd_number(ctx, fd)

  # Each arm is `{key, channel_op}`: key is `{:label, Label}`, `:index`, or
  # (for the default arm) the guest's own `default` term.
  defp alt_arms(ctx, ops) do
    ops
    |> Enum.reduce_while({:ok, []}, fn op, {:ok, acc} ->
      case alt_arm(ctx, op) do
        {:ok, arm} -> {:cont, {:ok, [arm | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, arms} -> {:ok, Enum.reverse(arms)}
      :error -> :error
    end
  end

  defp alt_arm(ctx, {tag, handle}) do
    if alt_tag(ctx, tag) == :recv, do: {:ok, {:index, {:recv, handle}}}, else: :error
  end

  defp alt_arm(ctx, {tag, handle, value}) do
    cond do
      alt_tag(ctx, tag) == :send -> {:ok, {:index, {:send, handle, value}}}
      alt_tag(ctx, handle) == :recv -> {:ok, {{:label, tag}, {:recv, value}}}
      true -> :error
    end
  end

  defp alt_arm(ctx, {label, tag, handle, value}) do
    if alt_tag(ctx, tag) == :send,
      do: {:ok, {{:label, label}, {:send, handle, value}}},
      else: :error
  end

  defp alt_arm(ctx, op) do
    if alt_tag(ctx, op) == :default, do: {:ok, {op, :default}}, else: :error
  end

  defp alt_arm_key(arms, index) do
    case Enum.at(arms, index) do
      {{:label, label}, _op} -> label
      _unlabelled -> index
    end
  end

  defp alt_tag(ctx, value) when is_atom(value) do
    case Hyperlang.Terms.atom_source(value, ctx) || Atom.to_string(value) do
      name when name in ["recv", "receive"] -> :recv
      "send" -> :send
      "default" -> :default
      _other -> nil
    end
  end

  defp alt_tag(_ctx, _value), do: nil

  defp count_arg(count) when is_integer(count) and count >= 0, do: {:ok, count}
  defp count_arg(_count), do: {:error, :badarg}

  defp offset_arg(offset) when is_integer(offset) and offset >= 0, do: {:ok, offset}
  defp offset_arg(_offset), do: {:error, :badarg}

  defp bytes_arg(buf) when is_binary(buf), do: {:ok, buf}

  defp bytes_arg(buf) when is_list(buf) do
    if Enum.all?(buf, &is_integer/1), do: {:ok, IO.iodata_to_binary(buf)}, else: {:error, :badarg}
  rescue
    _error -> {:error, :badarg}
  end

  defp bytes_arg(_buf), do: {:error, :badarg}

  defp bytes_or_empty(buf) do
    case bytes_arg(buf) do
      {:ok, bytes} -> bytes
      {:error, _reason} -> ""
    end
  end

  defp rune_arg(c) when is_integer(c) and c >= 0 and c <= @runemax and c not in 0xD800..0xDFFF,
    do: {:ok, c}

  defp rune_arg(_c), do: {:error, :badarg}

  defp encode_utf8_char(c) do
    {:ok, <<c::utf8>>}
  rescue
    _error -> {:error, :badarg}
  end

  defp nullable_string_arg(value) when value in [nil, ""], do: {:ok, ""}

  defp nullable_string_arg(value) do
    with {:ok, string} <- path_binary(value),
         true <- String.valid?(string) do
      {:ok, string}
    else
      _error -> {:error, :badarg}
    end
  end

  defp tokenize_string("", _delim), do: []
  defp tokenize_string(s, ""), do: [s]

  defp tokenize_string(s, delim) do
    delimiters = MapSet.new(String.codepoints(delim))

    s
    |> String.codepoints()
    |> Enum.reduce({[], []}, fn char, {tokens, current} ->
      if MapSet.member?(delimiters, char) do
        flush_token(tokens, current)
      else
        {tokens, [char | current]}
      end
    end)
    |> then(fn {tokens, current} -> flush_token(tokens, current) end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp flush_token(tokens, []), do: {tokens, []}

  defp flush_token(tokens, current),
    do: {[current |> Enum.reverse() |> IO.iodata_to_binary() | tokens], []}

  defp complete_utf8_bytes(bytes, offset) when offset < byte_size(bytes) do
    case decode_utf8_char(bytes, offset) do
      {_char, 0, 0} -> offset
      {_char, size, _status} -> complete_utf8_bytes(bytes, offset + size)
    end
  end

  defp complete_utf8_bytes(bytes, offset) when offset == byte_size(bytes), do: offset

  defp decode_utf8_char(bytes, offset) when offset == byte_size(bytes), do: {0, 0, 0}

  defp decode_utf8_char(bytes, offset) do
    remaining = byte_size(bytes) - offset
    first = :binary.at(bytes, offset)

    cond do
      first < 0x80 ->
        {first, 1, 1}

      first in 0xC2..0xDF ->
        decode_utf8_char(bytes, offset, remaining, 2, fn b1, b2 ->
          (b1 &&& 0x1F) <<< 6 ||| (b2 &&& 0x3F)
        end)

      first == 0xE0 ->
        decode_utf8_char(bytes, offset, remaining, 3, fn b1, b2, b3 ->
          if b2 in 0xA0..0xBF,
            do: (b1 &&& 0x0F) <<< 12 ||| (b2 &&& 0x3F) <<< 6 ||| (b3 &&& 0x3F),
            else: :invalid
        end)

      first in 0xE1..0xEC or first in 0xEE..0xEF ->
        decode_utf8_char(bytes, offset, remaining, 3, fn b1, b2, b3 ->
          (b1 &&& 0x0F) <<< 12 ||| (b2 &&& 0x3F) <<< 6 ||| (b3 &&& 0x3F)
        end)

      first == 0xED ->
        decode_utf8_char(bytes, offset, remaining, 3, fn b1, b2, b3 ->
          if b2 in 0x80..0x9F,
            do: (b1 &&& 0x0F) <<< 12 ||| (b2 &&& 0x3F) <<< 6 ||| (b3 &&& 0x3F),
            else: :invalid
        end)

      first == 0xF0 ->
        decode_utf8_char(bytes, offset, remaining, 4, fn b1, b2, b3, b4 ->
          if b2 in 0x90..0xBF,
            do:
              (b1 &&& 0x07) <<< 18 ||| (b2 &&& 0x3F) <<< 12 ||| (b3 &&& 0x3F) <<< 6 |||
                (b4 &&& 0x3F),
            else: :invalid
        end)

      first in 0xF1..0xF3 ->
        decode_utf8_char(bytes, offset, remaining, 4, fn b1, b2, b3, b4 ->
          (b1 &&& 0x07) <<< 18 ||| (b2 &&& 0x3F) <<< 12 ||| (b3 &&& 0x3F) <<< 6 |||
            (b4 &&& 0x3F)
        end)

      first == 0xF4 ->
        decode_utf8_char(bytes, offset, remaining, 4, fn b1, b2, b3, b4 ->
          if b2 in 0x80..0x8F,
            do:
              (b1 &&& 0x07) <<< 18 ||| (b2 &&& 0x3F) <<< 12 ||| (b3 &&& 0x3F) <<< 6 |||
                (b4 &&& 0x3F),
            else: :invalid
        end)

      true ->
        {@utferror, 1, 0}
    end
  end

  defp decode_utf8_char(_bytes, _offset, remaining, needed, _fun) when remaining < needed,
    do: {0, 0, 0}

  defp decode_utf8_char(bytes, offset, _remaining, needed, fun) do
    sequence = for index <- 0..(needed - 1), do: :binary.at(bytes, offset + index)

    if sequence |> tl() |> Enum.all?(&(&1 in 0x80..0xBF)) do
      case apply(fun, sequence) do
        :invalid -> {@utferror, 1, 0}
        char -> {char, needed, 1}
      end
    else
      {@utferror, 1, 0}
    end
  end

  defp path_binary(path) when is_binary(path), do: {:ok, path}

  defp path_binary(path) when is_list(path) do
    if Enum.all?(path, &is_integer/1), do: {:ok, List.to_string(path)}, else: {:error, :badarg}
  rescue
    _error -> {:error, :badarg}
  end

  defp path_binary(_path), do: {:error, :badarg}

  defp null_dir do
    %{
      "name" => nil,
      "uid" => nil,
      "gid" => nil,
      "muid" => nil,
      "qid" => %{"path" => -1, "vers" => -1, "qtype" => -1},
      "mode" => -1,
      "atime" => -1,
      "mtime" => -1,
      "length" => -1,
      "dtype" => -1,
      "dev" => -1
    }
  end

  defp zero_dir do
    %{
      "name" => nil,
      "uid" => nil,
      "gid" => nil,
      "muid" => nil,
      "qid" => %{"path" => 0, "vers" => 0, "qtype" => 0},
      "mode" => 0,
      "atime" => 0,
      "mtime" => 0,
      "length" => 0,
      "dtype" => 0,
      "dev" => 0
    }
  end
end
