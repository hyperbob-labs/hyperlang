defmodule :hyperlang_msg do
  @moduledoc false
  @compile {:inline, [opt_value: 2, sender_ctx: 1, receive_window: 1]}

  import Kernel,
    except: [
      send: 2,
      spawn: 1,
      spawn_link: 1,
      spawn_monitor: 1,
      make_ref: 0,
      is_process_alive: 1
    ]

  @app :hyperlang
  @resolver_key :guest_msg_resolver
  @spawn_hook_key :guest_spawn_hook
  @exec_hook_key :guest_exec_hook
  @name_hook_key :guest_name_hook
  @monitor_hook_key :guest_monitor_hook
  @link_hook_key :guest_link_hook
  @envelope_tag :"$hyperlang_msg"
  @context_key :"$hyperlang_msg_context"
  @no_context :__hyperlang_no_msg_context__
  @timer_quota_key :guest_timer_max_outstanding
  @default_max_timers 16_384

  def with_context(context, fun) when is_map(context) and is_function(fun, 0) do
    previous = Process.get(@context_key, @no_context)
    Process.put(@context_key, context)

    try do
      fun.()
    after
      restore_context(previous)
    end
  end

  defp receive_window(:infinity), do: {1, :infinity}
  defp receive_window(0), do: {0, 0}

  defp receive_window(timeout)
       when is_integer(timeout) and timeout > 0 and timeout <= 0xFFFFFFFF do
    {1, System.monotonic_time(:millisecond) + timeout}
  end

  defp receive_window(_), do: :erlang.error(:timeout_value)

  defp receive_wait_slow(_wait, 0, on_timeout), do: on_timeout.()

  defp receive_wait_slow(wait, deadline, on_timeout) do
    remaining =
      if deadline == :infinity,
        do: :infinity,
        else: max(0, deadline - System.monotonic_time(:millisecond))

    continuation =
      if remaining == 0 do
        on_timeout
      else
        case Hyperlang.Scope.blocking(fn -> wait.(remaining) end) do
          :"$hyperlang_receive_timeout" -> on_timeout
          ready -> ready
        end
      end

    continuation.()
  end

  def receive_select(wait, timeout) do
    {probe, deadline} = receive_window(timeout)

    case wait.(probe) do
      :"$hyperlang_receive_timeout" when deadline == 0 ->
        :"$hyperlang_receive_timeout"

      :"$hyperlang_receive_timeout" ->
        remaining =
          if deadline == :infinity,
            do: :infinity,
            else: max(0, deadline - System.monotonic_time(:millisecond))

        if remaining == 0,
          do: :"$hyperlang_receive_timeout",
          else: Hyperlang.Scope.blocking(fn -> wait.(remaining) end)

      ready ->
        ready
    end
  end

  # Matched bodies are continuations, so they run after reacquisition without
  # copying nested receive bodies into both the short and long wait paths.
  def receive_wait(wait, timeout, on_timeout) do
    {probe, deadline} = receive_window(timeout)

    case wait.(probe) do
      :"$hyperlang_receive_timeout" -> receive_wait_slow(wait, deadline, on_timeout)
      ready -> ready.()
    end
  end

  def send(target, msg) do
    # Erlang `!` either evaluates to Msg or RAISES (e.g. badarg to an
    # unregistered name). Returning an {:error,_} tuple would make the
    # expression value silently divergent and trivially ignorable, so every
    # failure raises a guest-catchable error instead.
    with :ok <- reject_forbidden_carriers(msg),
         {:ok, pid, opts, quota} <- resolve(target),
         :ok <- check_mailbox_quota(pid, quota) do
      Kernel.send(pid, {@envelope_tag, sender_ctx(opts), msg})
      msg
    else
      {:error, reason} -> :erlang.error({:hyperlang_send, reason})
    end
  end

  # A guest child is metered by the evaluation's limits group: the rate throttle,
  # the reduction ceiling, the wall deadline and the heap cap are hereditary, and
  # `max_procs` is the group's live child count. `Hyperlang.Limits` is the single
  # mechanism — there is no local refcount.
  #
  # A host whose spawn hook already places every child in its own
  # `Hyperlang.Limits` group installs the hook as `{module, function,
  # %{host_metered?: true}}`: the engine stays the one mechanism, the host owns
  # the child's group, and the eval group neither wraps, admits nor attaches —
  # a double attach would meter one child against two budgets.
  def spawn(fun) when is_function(fun, 0) do
    boot = :erlang.make_ref()

    with {:ok, hook, policy} <- spawn_hook(),
         metering = if(policy[:host_metered?] == true, do: :off, else: child_metering()),
         :ok <- admit_child(metering),
         {:ok, carrier, _opts} <-
           Hyperlang.Scope.blocking(fn ->
             invoke_spawn_hook(hook, metered_child(metering, boot, fun), self_context())
           end),
         :ok <- Hyperlang.Scope.blocking(fn -> await_child_metering(metering, boot) end) do
      carrier
    else
      {:error, reason} -> :erlang.error({:hyperlang_spawn, reason})
    end
  end

  def spawn(_fun), do: :erlang.error(:badarg)

  def exec(path, argv, opts \\ %{})

  def exec(path, argv, opts) when is_binary(path) and is_list(argv) do
    exec(path, argv, opts, self_context())
  end

  def exec(_path, _argv, _opts), do: {:error, :badarg}

  def exec(path, argv, opts, ctx) when is_binary(path) and is_list(argv) and is_map(ctx) do
    with {:ok, hook} <- exec_hook() do
      Hyperlang.Scope.blocking(fn ->
        invoke_exec_hook(hook, path, argv, opts, exec_context(ctx))
      end)
    end
  end

  def exec(_path, _argv, _opts, _ctx), do: {:error, :badarg}

  def register(name, target) do
    with {:ok, name} <- name_binary(name),
         {:ok, target} <- carrier(target),
         {:ok, true} <- invoke_name(:register, {name, target}) do
      true
    else
      {:error, reason} -> :erlang.error({:hyperlang_name, reason})
    end
  end

  def whereis(name) do
    with {:ok, name} <- name_binary(name),
         {:ok, result} <- invoke_name(:whereis, name) do
      result
    else
      {:error, reason} -> :erlang.error({:hyperlang_name, reason})
    end
  end

  def unregister(name) do
    with {:ok, name} <- name_binary(name),
         {:ok, true} <- invoke_name(:unregister, name) do
      true
    else
      {:error, reason} -> :erlang.error({:hyperlang_name, reason})
    end
  end

  def monitor(target) do
    with {:ok, target} <- monitor_target(target),
         {:ok, ref} <- invoke_monitor(:monitor, target) do
      ref
    else
      {:error, reason} -> :erlang.error({:hyperlang_monitor, reason})
    end
  end

  def make_ref do
    case invoke_monitor(:make_ref, nil) do
      {:ok, ref} -> ref
      {:error, reason} -> :erlang.error({:hyperlang_monitor, reason})
    end
  end

  def is_process_alive(target) when is_integer(target) do
    case invoke_monitor(:alive?, target) do
      {:ok, alive} -> alive
      {:error, reason} -> :erlang.error({:hyperlang_monitor, reason})
    end
  end

  def is_process_alive(_target), do: :erlang.error(:badarg)

  def demonitor(ref), do: demonitor(ref, [])

  def demonitor(ref, options) do
    with {:ok, ref} <- monitor_ref(ref),
         {:ok, flush?} <- demonitor_flush?(options),
         {:ok, true} <- invoke_monitor(:demonitor, ref) do
      if flush?, do: flush_down(ref)
      true
    else
      {:error, reason} -> :erlang.error({:hyperlang_monitor, reason})
    end
  end

  def spawn_monitor(fun) when is_function(fun, 0) do
    carrier = spawn(fun)
    ref = monitor(carrier)
    {carrier, ref}
  end

  def spawn_monitor(_fun), do: :erlang.error(:badarg)

  def link(target) do
    with {:ok, target} <- link_target(target),
         {:ok, true} <- invoke_link(:link, target) do
      true
    else
      {:error, reason} -> :erlang.error({:hyperlang_link, reason})
    end
  end

  def unlink(target) do
    with {:ok, target} <- link_target(target),
         {:ok, true} <- invoke_link(:unlink, target) do
      true
    else
      {:error, reason} -> :erlang.error({:hyperlang_link, reason})
    end
  end

  def process_flag(flag, bool) do
    with {:ok, true} <- trap_exit_flag?(flag),
         {:ok, bool} <- trap_exit_bool(bool),
         {:ok, previous} <- invoke_link(:trap_exit, bool) do
      previous
    else
      {:error, reason} -> :erlang.error({:hyperlang_link, reason})
    end
  end

  def process_info_links do
    case invoke_link(:links, nil) do
      {:ok, links} -> {:links, links}
      {:error, reason} -> :erlang.error({:hyperlang_link, reason})
    end
  end

  def spawn_link(fun) when is_function(fun, 0) do
    # This mirrors spawn_monitor/1: the guest kernel hook only exposes spawn and
    # link as separate operations, so this lowering is spawn-then-link.
    carrier = spawn(fun)
    true = link(carrier)
    carrier
  end

  def spawn_link(_fun), do: :erlang.error(:badarg)

  def exit(target, reason) do
    with {:ok, target} <- link_target(target),
         :ok <- reject_forbidden_carriers(reason),
         {:ok, true} <- invoke_link(:exit_signal, {target, export_exit_reason(reason)}) do
      true
    else
      {:error, reason} -> :erlang.error({:hyperlang_link, reason})
    end
  end

  def send_after(time, target, msg), do: start_guest_timer(:send_after, time, target, msg)

  def start_timer(time, target, msg), do: start_guest_timer(:start_timer, time, target, msg)

  def cancel_timer(ref) when is_integer(ref),
    do: Hyperlang.MsgTimerServer.cancel(timer_scope(), ref)

  def cancel_timer(_ref), do: :erlang.error(:badarg)

  def read_timer(ref) when is_integer(ref),
    do: Hyperlang.MsgTimerServer.read(timer_scope(), ref)

  def read_timer(_ref), do: :erlang.error(:badarg)

  defp resolve(target), do: resolve(target, self_context())

  defp resolve(target, ctx) do
    with {:ok, resolver} <- resolver(),
         {:ok, pid, opts} <-
           Hyperlang.Scope.blocking(fn -> invoke_resolver(resolver, target, ctx) end) do
      normalize_opts(opts)
      |> case do
        {:ok, opts, quota} -> {:ok, pid, opts, quota}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolver do
    case installed_policy(@resolver_key, :__hyperlang_no_msg_policy__) do
      fun when is_function(fun, 2) -> {:ok, fun}
      {module, function} when is_atom(module) and is_atom(function) -> {:ok, {module, function}}
      _other -> {:error, :no_msg_policy}
    end
  end

  defp spawn_hook do
    case installed_policy(@spawn_hook_key, :__hyperlang_no_spawn_policy__) do
      fun when is_function(fun, 2) ->
        {:ok, fun, %{}}

      {module, function} when is_atom(module) and is_atom(function) ->
        {:ok, {module, function}, %{}}

      {module, function, %{} = policy} when is_atom(module) and is_atom(function) ->
        {:ok, {module, function}, policy}

      _other ->
        {:error, :no_spawn_policy}
    end
  end

  defp exec_hook do
    case installed_policy(@exec_hook_key, :__hyperlang_no_exec_policy__) do
      fun when is_function(fun, 4) -> {:ok, fun}
      fun when is_function(fun, 3) -> {:ok, fun}
      {module, function} when is_atom(module) and is_atom(function) -> {:ok, {module, function}}
      _other -> {:error, :no_exec_policy}
    end
  end

  defp name_hook do
    case installed_policy(@name_hook_key, :__hyperlang_no_name_policy__) do
      fun when is_function(fun, 2) -> {:ok, fun}
      {module, function} when is_atom(module) and is_atom(function) -> {:ok, {module, function}}
      _other -> {:error, :no_policy}
    end
  end

  defp monitor_hook do
    case installed_policy(@monitor_hook_key, :__hyperlang_no_monitor_policy__) do
      fun when is_function(fun, 2) -> {:ok, fun}
      {module, function} when is_atom(module) and is_atom(function) -> {:ok, {module, function}}
      _other -> {:error, :no_policy}
    end
  end

  defp link_hook do
    case installed_policy(@link_hook_key, :__hyperlang_no_link_policy__) do
      fun when is_function(fun, 2) -> {:ok, fun}
      {module, function} when is_atom(module) and is_atom(function) -> {:ok, {module, function}}
      _other -> {:error, :no_policy}
    end
  end

  defp installed_policy(key, missing) do
    case :persistent_term.get({__MODULE__, key}, :__hyperlang_no_installed_policy__) do
      :__hyperlang_no_installed_policy__ -> Application.get_env(@app, key, missing)
      policy -> policy
    end
  end

  defp invoke_resolver(fun, target, ctx) when is_function(fun, 2) do
    normalize_resolver_reply(fun.(target, ctx))
  rescue
    _ -> {:error, :bad_msg_policy}
  catch
    _, _ -> {:error, :bad_msg_policy}
  end

  defp invoke_resolver({module, function}, target, ctx) do
    normalize_resolver_reply(apply(module, function, [target, ctx]))
  rescue
    _ -> {:error, :bad_msg_policy}
  catch
    _, _ -> {:error, :bad_msg_policy}
  end

  defp invoke_spawn_hook(fun, guest_fun, ctx) when is_function(fun, 2) do
    normalize_spawn_reply(fun.(guest_fun, ctx))
  rescue
    _ -> {:error, :bad_spawn_policy}
  catch
    _, _ -> {:error, :bad_spawn_policy}
  end

  defp invoke_spawn_hook({module, function}, guest_fun, ctx) do
    normalize_spawn_reply(apply(module, function, [guest_fun, ctx]))
  rescue
    _ -> {:error, :bad_spawn_policy}
  catch
    _, _ -> {:error, :bad_spawn_policy}
  end

  defp invoke_exec_hook(fun, path, argv, opts, ctx) when is_function(fun, 4) do
    normalize_exec_reply(fun.(path, argv, opts, ctx))
  rescue
    _ -> {:error, :bad_exec_policy}
  catch
    _, _ -> {:error, :bad_exec_policy}
  end

  defp invoke_exec_hook(fun, path, argv, opts, _ctx) when is_function(fun, 3) do
    normalize_exec_reply(fun.(path, argv, opts))
  rescue
    _ -> {:error, :bad_exec_policy}
  catch
    _, _ -> {:error, :bad_exec_policy}
  end

  defp invoke_exec_hook({module, function}, path, argv, opts, ctx) do
    args =
      if function_exported?(module, function, 4),
        do: [path, argv, opts, ctx],
        else: [path, argv, opts]

    normalize_exec_reply(apply(module, function, args))
  rescue
    _ -> {:error, :bad_exec_policy}
  catch
    _, _ -> {:error, :bad_exec_policy}
  end

  defp invoke_name(op, arg) do
    with {:ok, hook} <- name_hook() do
      Hyperlang.Scope.blocking(fn -> invoke_name_hook(hook, op, arg) end)
    end
  end

  defp invoke_name_hook(fun, op, arg) when is_function(fun, 2) do
    normalize_name_reply(op, fun.(op, arg))
  rescue
    _ -> {:error, :bad_name_policy}
  catch
    _, _ -> {:error, :bad_name_policy}
  end

  defp invoke_name_hook({module, function}, op, arg) do
    normalize_name_reply(op, apply(module, function, [op, arg]))
  rescue
    _ -> {:error, :bad_name_policy}
  catch
    _, _ -> {:error, :bad_name_policy}
  end

  defp invoke_monitor(op, arg) do
    with {:ok, hook} <- monitor_hook() do
      Hyperlang.Scope.blocking(fn -> invoke_monitor_hook(hook, op, arg) end)
    end
  end

  defp invoke_monitor_hook(fun, op, arg) when is_function(fun, 2) do
    normalize_monitor_reply(op, fun.(op, arg))
  rescue
    _ -> {:error, :bad_monitor_policy}
  catch
    _, _ -> {:error, :bad_monitor_policy}
  end

  defp invoke_monitor_hook({module, function}, op, arg) do
    normalize_monitor_reply(op, apply(module, function, [op, arg]))
  rescue
    _ -> {:error, :bad_monitor_policy}
  catch
    _, _ -> {:error, :bad_monitor_policy}
  end

  defp invoke_link(op, arg) do
    with {:ok, hook} <- link_hook() do
      Hyperlang.Scope.blocking(fn -> invoke_link_hook(hook, op, arg) end)
    end
  end

  defp invoke_link_hook(fun, op, arg) when is_function(fun, 2) do
    normalize_link_reply(op, fun.(op, arg))
  rescue
    _ -> {:error, :bad_link_policy}
  catch
    _, _ -> {:error, :bad_link_policy}
  end

  defp invoke_link_hook({module, function}, op, arg) do
    normalize_link_reply(op, apply(module, function, [op, arg]))
  rescue
    _ -> {:error, :bad_link_policy}
  catch
    _, _ -> {:error, :bad_link_policy}
  end

  defp normalize_resolver_reply({:ok, pid, opts}) when is_pid(pid), do: {:ok, pid, opts}
  defp normalize_resolver_reply({:ok, pid}) when is_pid(pid), do: {:ok, pid, %{}}
  defp normalize_resolver_reply({:error, reason}), do: {:error, reason}
  defp normalize_resolver_reply(_other), do: {:error, :bad_msg_policy}

  defp normalize_spawn_reply({:ok, carrier, opts}) do
    with {:ok, opts} <- normalize_spawn_opts(opts), do: {:ok, carrier, opts}
  end

  defp normalize_spawn_reply({:ok, carrier}), do: {:ok, carrier, %{}}
  defp normalize_spawn_reply({:error, reason}), do: {:error, reason}
  defp normalize_spawn_reply(_other), do: {:error, :bad_spawn_policy}

  defp normalize_exec_reply({:exec_status, status}) when is_binary(status),
    do: {:exec_status, status}

  defp normalize_exec_reply({:error, reason}), do: {:error, reason}

  defp normalize_exec_reply(%{<<"__hyperbob_os_exec_overlay__">> => true} = value),
    do: value

  defp normalize_exec_reply(_other), do: {:error, :bad_exec_policy}

  defp normalize_name_reply(op, {:ok, true}) when op in [:register, :unregister],
    do: {:ok, true}

  defp normalize_name_reply(:whereis, {:ok, :undefined}), do: {:ok, :undefined}
  defp normalize_name_reply(:whereis, {:ok, carrier}) when is_integer(carrier), do: {:ok, carrier}
  defp normalize_name_reply(_op, {:error, reason}), do: {:error, reason}
  defp normalize_name_reply(_op, _other), do: {:error, :bad_name_policy}

  defp normalize_monitor_reply(:monitor, {:ok, ref}) when is_integer(ref), do: {:ok, ref}
  defp normalize_monitor_reply(:make_ref, {:ok, ref}) when is_integer(ref), do: {:ok, ref}
  defp normalize_monitor_reply(:alive?, {:ok, alive}) when is_boolean(alive), do: {:ok, alive}
  defp normalize_monitor_reply(:demonitor, {:ok, true}), do: {:ok, true}
  defp normalize_monitor_reply(_op, {:error, reason}), do: {:error, reason}
  defp normalize_monitor_reply(_op, _other), do: {:error, :bad_monitor_policy}

  defp normalize_link_reply(op, {:ok, true}) when op in [:link, :unlink, :exit_signal],
    do: {:ok, true}

  defp normalize_link_reply(:trap_exit, {:ok, previous}) when is_boolean(previous),
    do: {:ok, previous}

  defp normalize_link_reply(:links, {:ok, links}) when is_list(links) do
    if Enum.all?(links, &is_integer/1), do: {:ok, links}, else: {:error, :bad_link_policy}
  end

  defp normalize_link_reply(_op, {:error, reason}), do: {:error, reason}
  defp normalize_link_reply(_op, _other), do: {:error, :bad_link_policy}

  defp self_context do
    base =
      case Process.get(@context_key) do
        %{} = context -> context
        _other -> %{}
      end

    Map.put(base, :pid, self())
  end

  defp exec_context(ctx) do
    self_context()
    |> Map.merge(ctx)
    |> Map.put(:pid, self())
  end

  defp name_binary(name) when is_atom(name), do: {:ok, atom_source_name(name)}
  defp name_binary(_name), do: {:error, :badarg}

  defp carrier(value) when is_integer(value), do: {:ok, value}
  defp carrier(_value), do: {:error, :badarg}

  defp monitor_ref(value) when is_integer(value), do: {:ok, value}
  defp monitor_ref(_value), do: {:error, :badarg}

  defp monitor_target(value) when is_integer(value), do: {:ok, value}
  defp monitor_target(value) when is_binary(value), do: {:ok, value}
  defp monitor_target(value) when is_atom(value), do: {:ok, atom_source_name(value)}
  defp monitor_target(_value), do: {:error, :badarg}

  defp link_target(value) when is_integer(value), do: {:ok, value}
  defp link_target(value) when is_binary(value), do: {:ok, value}
  defp link_target(value) when is_atom(value), do: {:ok, atom_source_name(value)}
  defp link_target(_value), do: {:error, :badarg}

  defp export_exit_reason(value) when is_atom(value), do: exit_reason_source_atom(value)

  defp export_exit_reason(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&export_exit_reason/1)
    |> List.to_tuple()
  end

  defp export_exit_reason(value) when is_list(value), do: Enum.map(value, &export_exit_reason/1)

  defp export_exit_reason(%{} = value) do
    Map.new(value, fn {key, item} -> {export_exit_reason(key), export_exit_reason(item)} end)
  end

  defp export_exit_reason(value), do: value

  defp exit_reason_source_atom(atom) do
    case Hyperlang.Terms.atom_source(atom, self_context()) do
      source when is_binary(source) -> source_to_existing_atom(source)
      _ -> atom
    end
  end

  # A generated-family name (`v_N`, ...) stays a binary: whether it exists
  # depends on other programs' pool use.
  defp source_to_existing_atom(source) do
    if Hyperlang.GeneratedAtoms.family_name?(source),
      do: source,
      else: String.to_existing_atom(source)
  rescue
    ArgumentError -> source
  end

  defp timer_target(value) when is_integer(value), do: {:ok, value}
  defp timer_target(value) when is_binary(value), do: {:ok, value}
  defp timer_target(value) when is_atom(value), do: {:ok, atom_source_name(value)}
  defp timer_target(_value), do: {:error, :badarg}

  defp trap_exit_flag?(value) when is_atom(value) do
    if atom_source_name(value) == "trap_exit", do: {:ok, true}, else: {:error, :badarg}
  end

  defp trap_exit_flag?(_value), do: {:error, :badarg}

  defp trap_exit_bool(value) when is_boolean(value), do: {:ok, value}
  defp trap_exit_bool(_value), do: {:error, :badarg}

  defp atom_source_name(atom) when is_atom(atom) do
    Hyperlang.Terms.atom_source(atom, self_context()) || Atom.to_string(atom)
  end

  defp demonitor_flush?(options) when is_list(options) do
    if proper_list?(options) do
      Enum.reduce_while(options, {:ok, false}, fn
        option, {:ok, _flush?} when is_atom(option) ->
          if atom_source_name(option) == "flush" do
            {:cont, {:ok, true}}
          else
            {:halt, {:error, :badarg}}
          end

        _option, _acc ->
          {:halt, {:error, :badarg}}
      end)
    else
      {:error, :badarg}
    end
  end

  defp demonitor_flush?(_options), do: {:error, :badarg}

  defp proper_list?(list) when is_list(list), do: proper_list?(list, [])
  defp proper_list?(_value), do: false

  defp proper_list?([], _seen), do: true
  defp proper_list?([_head | tail], seen), do: proper_list?(tail, seen)
  defp proper_list?(_tail, _seen), do: false

  defp flush_down(ref) do
    receive do
      {@envelope_tag, _from, {:DOWN, ^ref, :process, _proc, _cause}} -> :ok
    after
      0 -> :ok
    end
  end

  defp normalize_opts(opts) when is_map(opts), do: normalize_opts_map(opts)

  defp normalize_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: opts |> Map.new() |> normalize_opts_map(),
      else: {:error, :bad_msg_policy}
  end

  defp normalize_opts(nil), do: {:ok, %{}, nil}
  defp normalize_opts(_opts), do: {:error, :bad_msg_policy}

  defp normalize_spawn_opts(opts) when is_map(opts), do: {:ok, opts}

  defp normalize_spawn_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: {:ok, Map.new(opts)}, else: {:error, :bad_spawn_policy}
  end

  defp normalize_spawn_opts(nil), do: {:ok, %{}}
  defp normalize_spawn_opts(_opts), do: {:error, :bad_spawn_policy}

  defp normalize_opts_map(opts) do
    case opt_value(opts, :max_mailbox) do
      nil ->
        {:ok, opts, nil}

      max when is_integer(max) and max >= 0 ->
        {:ok, opts, max}

      _other ->
        {:error, :bad_msg_policy}
    end
  end

  defp check_mailbox_quota(pid, quota) do
    case quota do
      nil ->
        :ok

      max ->
        case Hyperlang.Scope.blocking(fn -> Process.info(pid, :message_queue_len) end) do
          {:message_queue_len, len} when len < max -> :ok
          {:message_queue_len, _len} -> {:error, :mailbox_quota_exceeded}
          nil -> {:error, :noproc}
        end
    end
  end

  defp sender_ctx(opts), do: opt_value(opts, :sender_ctx) || opt_value(opts, :from) || self()

  defp start_guest_timer(kind, time, target, msg) do
    with {:ok, time} <- timer_time(time),
         {:ok, target} <- timer_target(target),
         :ok <- reject_forbidden_carriers(msg),
         {:ok, timer_ctx} <- timer_context(target),
         {:ok, scope, max} <- timer_quota_context() do
      :ok = Hyperlang.Scope.ensure(scope, Map.get(self_context(), :scope_owner, self()))
      entry = %{kind: kind, target: target, msg: msg, context: timer_ctx}

      case Hyperlang.MsgTimerServer.start_timer(scope, max, time, entry) do
        {:ok, id} -> id
        {:error, reason} -> :erlang.error({:hyperlang_timer, reason})
      end
    else
      {:error, reason} -> :erlang.error({:hyperlang_timer, reason})
    end
  end

  defp timer_time(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp timer_time(_value), do: {:error, :badarg}

  defp timer_context(target) do
    case resolve(target) do
      {:ok, _pid, opts, _quota} ->
        base = self_context()

        {:ok,
         base
         |> Map.put(:timer_sender_ctx, sender_ctx(opts))
         |> maybe_put_timer_world(opts)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_timer_world(ctx, opts) do
    case opt_value(opts, :world) do
      nil -> ctx
      world -> Map.put(ctx, :timer_world, world)
    end
  end

  @doc false
  def __deliver_timer__(%{kind: kind, target: target, msg: msg, context: ctx} = entry) do
    payload =
      case kind do
        :send_after -> msg
        :start_timer -> {:timeout, Map.fetch!(entry, :id), msg}
      end

    case resolve(target, timer_fire_context(ctx)) do
      {:ok, pid, opts, quota} ->
        case check_mailbox_quota(pid, quota) do
          :ok -> Kernel.send(pid, {@envelope_tag, timer_sender_ctx(ctx, opts), payload})
          {:error, _reason} -> :ok
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp timer_fire_context(ctx), do: Map.put(ctx, :pid, self())

  defp timer_sender_ctx(ctx, opts), do: Map.get(ctx, :timer_sender_ctx) || sender_ctx(opts)

  defp timer_quota_context do
    max = Application.get_env(@app, @timer_quota_key, @default_max_timers)

    if is_integer(max) and max >= 0 do
      {:ok, timer_scope(), max}
    else
      {:error, :bad_timer_policy}
    end
  end

  defp timer_scope do
    Map.get(self_context(), :scope, Hyperlang.Scope.current())
  end

  defp child_metering do
    case Process.get(@context_key) do
      %{} = context ->
        case opt_value(context, :limits_group) do
          %Hyperlang.Limits.Group{} = group -> {group, opt_value(context, :limits) || %{}}
          _other -> :off
        end

      _other ->
        :off
    end
  end

  # `max_procs` is enforced by the attach below, which is the single authority
  # for the count. This read keeps a saturated group from asking the host to
  # birth a child that the attach would immediately reject, and is skipped
  # entirely when the evaluation declares no `max_procs`.
  defp admit_child(:off), do: :ok

  defp admit_child({group, limits}) do
    case opt_value(limits, :max_procs) do
      max when is_integer(max) and max >= 0 ->
        case Hyperlang.Limits.stat(group) do
          %{procs: procs, max_procs: limit} when is_integer(limit) and procs >= limit ->
            {:error, :eagain}

          _stat ->
            :ok
        end

      _other ->
        :ok
    end
  end

  # A child registers itself before any guest instruction and waits for the
  # spawning process to acknowledge admission. This also covers hooks without
  # PID metadata, delayed scheduling and the birth-to-parent-attach race.
  defp metered_child(:off, _boot, fun) do
    # The hook owns this child's budgets and lifetime. Select its host context
    # after the hook has established the child, rather than inheriting the
    # spawning evaluation's scope (native resident children may outlive it).
    fn ->
      scope = Hyperlang.Scope.current()
      :ok = Hyperlang.Scope.ensure(scope, self())
      Hyperlang.Scope.running(scope, fun)
    end
  end

  defp metered_child({group, limits}, boot, fun) do
    context = self_context()
    scope = Map.get(context, :scope, Hyperlang.Scope.current())
    parent = self()
    owner = Map.get(context, :scope_owner, parent)

    fn ->
      monitor = Process.monitor(parent)

      Hyperlang.Scope.with_scope(scope, fn ->
        with_context(context, fn ->
          Process.flag(:priority, Hyperlang.Scope.priority(scope))
          Process.flag(:message_queue_data, :on_heap)
          words = opt_value(limits, :max_heap_words) || opt_value(limits, :heap_words)

          if is_integer(words) and words > 0,
            do: Process.flag(:max_heap_size, Hyperlang.Limits.heap_flags(words))

          admitted =
            with :ok <- Hyperlang.Limits.attach(group, self(), child_limits(limits)),
                 :ok <- Hyperlang.Scope.ensure(scope, owner),
                 :ok <- Hyperlang.Scope.attach(scope, self(), :run, words),
                 do: :ok

          Kernel.send(parent, {boot, self(), admitted})

          if admitted == :ok do
            receive do
              {^boot, :start} ->
                Process.demonitor(monitor, [:flush])
                Hyperlang.Scope.running(scope, fun)

              {:DOWN, ^monitor, :process, ^parent, _} ->
                Process.exit(self(), :kill)
            after
              1000 -> Process.exit(self(), :kill)
            end
          else
            Process.exit(self(), :kill)
          end
        end)
      end)
    end
  end

  defp await_child_metering(:off, _boot), do: :ok

  defp await_child_metering({_group, _limits}, boot) do
    receive do
      {^boot, pid, :ok} when is_pid(pid) ->
        Kernel.send(pid, {boot, :start})
        :ok

      {^boot, pid, {:error, reason}} when is_pid(pid) ->
        Process.exit(pid, :kill)
        {:error, if(is_atom(reason), do: reason, else: :eagain)}
    after
      1000 -> {:error, :spawn_timeout}
    end
  end

  defp child_limits(limits), do: Map.put(limits, :spawned?, true)

  # These keys are internal constants. Keep atom-key precedence, including a
  # present nil value, without building strings or repeating quota validation
  # on every message.
  for key <- [
        :max_mailbox,
        :sender_ctx,
        :from,
        :world,
        :limits_group,
        :limits,
        :max_procs,
        :max_heap_words,
        :heap_words
      ] do
    string = Atom.to_string(key)
    defp opt_value(%{unquote(key) => value}, unquote(key)), do: value
    defp opt_value(%{unquote(string) => value}, unquote(key)), do: value
    defp opt_value(%{}, unquote(key)), do: nil
  end

  defp restore_context(@no_context), do: Process.delete(@context_key)
  defp restore_context(context), do: Process.put(@context_key, context)

  # The carrier rule shared by every guest send path (`!`, `exit/2`, timers and
  # the Sys channel sends): funs, pids, ports and refs never travel guest to
  # guest at any depth.
  @doc false
  def reject_forbidden_carriers(value)
      when is_function(value) or is_pid(value) or is_port(value),
      do: {:error, :forbidden_term}

  def reject_forbidden_carriers(value) when is_reference(value), do: {:error, :forbidden_term}

  def reject_forbidden_carriers(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> reject_forbidden_carriers()
  end

  def reject_forbidden_carriers(value) when is_map(value) do
    Enum.reduce_while(value, :ok, fn {key, item}, :ok ->
      with :ok <- reject_forbidden_carriers(key),
           :ok <- reject_forbidden_carriers(item) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def reject_forbidden_carriers([head | tail]) do
    with :ok <- reject_forbidden_carriers(head), do: reject_forbidden_carriers(tail)
  end

  def reject_forbidden_carriers([]), do: :ok
  def reject_forbidden_carriers(_value), do: :ok
end

defmodule Hyperlang.MsgTimerServer do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def start_timer(scope, max, time, entry),
    do: GenServer.call(__MODULE__, {:start, scope, max, time, entry})

  def cancel(scope, id), do: GenServer.call(__MODULE__, {:cancel, scope, id})
  def read(scope, id), do: GenServer.call(__MODULE__, {:read, scope, id})
  def close_scope(scope), do: GenServer.call(__MODULE__, {:close, scope})

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    {:ok, %{timers: %{}, counts: %{}, deliverers: %{}}}
  end

  @impl true
  def handle_call({:start, scope, max, time, entry}, _from, state) do
    if Map.get(state.counts, scope, 0) >= max do
      {:reply, {:error, :timer_quota_exceeded}, state}
    else
      id = :crypto.strong_rand_bytes(16) |> :binary.decode_unsigned()
      key = {scope, id}
      timer = :erlang.start_timer(time, self(), key)
      entry = Map.merge(entry, %{id: id, beam_ref: timer})

      state =
        state
        |> put_in([:timers, key], entry)
        |> update_in([:counts, scope], &((&1 || 0) + 1))

      {:reply, {:ok, id}, state}
    end
  end

  def handle_call({:cancel, scope, id}, _from, state) do
    case state.timers[{scope, id}] do
      %{pending?: true} ->
        {:reply, false, state}

      _ ->
        {entry, state} = take(state, {scope, id})
        remaining = if entry, do: Process.cancel_timer(entry.beam_ref), else: false
        {:reply, remaining, state}
    end
  end

  def handle_call({:read, scope, id}, _from, state) do
    entry = state.timers[{scope, id}]

    {:reply,
     if(entry && !Map.get(entry, :pending?, false),
       do: Process.read_timer(entry.beam_ref),
       else: false
     ), state}
  end

  def handle_call({:close, scope}, _from, state), do: {:reply, :ok, close(state, scope)}

  @impl true
  def handle_info({:timeout, timer, key}, state) do
    case state.timers[key] do
      %{beam_ref: ^timer} = entry ->
        # Keep the quota charge until delivery acknowledges completion. Pending
        # deliveries plus live timers can never exceed this scope's quota.
        state = put_in(state, [:timers, key], Map.put(entry, :pending?, true))
        {deliverer, state} = deliverer(state, elem(key, 0))
        send(deliverer, {:deliver, key, entry})
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:delivered, pid, {scope, _} = key}, state) do
    if state.deliverers[scope] == pid do
      {_entry, state} = take(state, key)

      if Map.get(state.counts, scope, 0) == 0 do
        send(pid, :stop)
        {:noreply, %{state | deliverers: Map.delete(state.deliverers, scope)}}
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, _reason}, state) do
    scopes = for {scope, ^pid} <- state.deliverers, do: scope

    state =
      Enum.reduce(scopes, state, fn scope, acc ->
        acc = %{acc | deliverers: Map.delete(acc.deliverers, scope)}

        Enum.reduce(acc.timers, acc, fn
          {{^scope, _} = key, %{pending?: true}}, acc -> elem(take(acc, key), 1)
          _, acc -> acc
        end)
      end)

    {:noreply, state}
  end

  def handle_info({:scope_closed, scope}, state), do: {:noreply, close(state, scope)}

  # Each scope delivers its expired timers in its own linked process, in
  # expiry order. The host resolver hook runs there, so a slow resolver delays
  # only its own scope's timers, never the server or another scope.
  defp deliverer(state, scope) do
    case state.deliverers do
      %{^scope => pid} ->
        {pid, state}

      _ ->
        server = self()
        pid = spawn_link(fn -> deliver_loop(server) end)
        {pid, put_in(state, [:deliverers, scope], pid)}
    end
  end

  defp deliver_loop(server) do
    receive do
      {:deliver, key, entry} ->
        try do
          :hyperlang_msg.__deliver_timer__(entry)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        after
          send(server, {:delivered, self(), key})
        end

        deliver_loop(server)

      :stop ->
        :ok
    end
  end

  defp close(state, scope) do
    {deliverer, deliverers} = Map.pop(state.deliverers, scope)
    if deliverer, do: Process.exit(deliverer, :kill)
    state = %{state | deliverers: deliverers}

    Enum.reduce(state.timers, state, fn
      {{^scope, _} = key, entry}, state ->
        Process.cancel_timer(entry.beam_ref)
        elem(take(state, key), 1)

      _, state ->
        state
    end)
  end

  defp take(state, {scope, _} = key) do
    case Map.pop(state.timers, key) do
      {nil, _} ->
        {nil, state}

      {entry, timers} ->
        count = state.counts[scope] - 1

        counts =
          if count == 0,
            do: Map.delete(state.counts, scope),
            else: Map.put(state.counts, scope, count)

        {entry, %{state | timers: timers, counts: counts}}
    end
  end
end
