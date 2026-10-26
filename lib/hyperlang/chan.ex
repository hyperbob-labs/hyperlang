defmodule Hyperlang.Chan do
  @moduledoc """
  Typed channels and `alt` for syscall hosts.

  These are the Dis channel primitives that a ported Limbo userland needs,
  with the semantics of the Inferno interpreter. Guests reach them through
  the `sys:*` facade (`newchan`, `csend`, `crecv`, `alt`). Hosts call this
  module directly to create, alias and close channels on a guest's behalf.

  ## What this ports

  This is the BEAM home of the Dis channel primitives from `libinterp/xec.c`
  (`isend`, `irecv`, `cqadd`/`cqdel`, `cgetb`/`cputb`) and `libinterp/alt.c`
  (`altrdy`/`altcomm`/`altdone`). In Dis those ops run inside the single-threaded
  interpreter loop, so a channel operation is *atomic* w.r.t. every other Prog: a
  send either hands its value to a waiting receiver and wakes it, or blocks the
  sender on the channel's `send` queue; a receive is symmetric; `alt` commits
  exactly one ready op atomically.

  On the BEAM each Inferno `Prog` is its own BEAM process (a hyperlang guest
  worker), so the atomicity that Dis got from a single interpreter thread is
  recovered by making each **channel a serialising OTP process** (the broker).
  The broker pid is the C `Channel*`. Every `csend`/`crecv`/`alt`/`nbsend`/
  `nbrecv` is one `GenServer.call` into the broker, so all the rendezvous
  bookkeeping (which Prog is parked on `send`/`recv`, the buffer ring) happens
  one message at a time — exactly the Dis invariant. The *calling* Prog's worker
  process is what blocks (it waits for the broker's reply), never a busy-wait.

  ### Rendezvous (unbuffered, `size == 0`)

  `isend`: if a receiver is already parked (`c->recv->member != nil`) hand the value
  over directly and wake it; else park the sender on `c->send` and block. `irecv`
  is the mirror. Exactly one value is handed off per matched pair — no loss, no
  double-take — because the broker matches under its single-process serialisation.

  ### Buffered (`size > 0`)

  A ring buffer of `size` slots (`cputb`/`cgetb`). Send blocks only when the
  buffer is full AND no receiver waits; recv blocks only when the buffer is empty
  AND no sender waits. A waiting receiver still takes precedence over the buffer
  for a fresh send (matching `isend`: it checks `c->recv->member` *before* `cputb`).

  ### alt

  `alt(ops)` is Dis `altrdy`+`altcomm`+`altdone`: scan the ops, collect the set
  that can fire right now; if any are ready, pick one **fairly** (uniformly at
  random over the ready set, the BEAM stand-in for Dis's run-queue order) and
  perform exactly that communication. If none are ready and there is a `*`
  default, take it without blocking; otherwise the caller blocks until one op
  becomes ready, then commits exactly one. `nbsend`/`nbrecv` are `alt` with a
  single op plus a default.

  ## Handles cross the guest boundary as integers, not pids

  A broker pid cannot cross the hyperlang term boundary — the sanitizer rejects
  pids, ports and refs as forbidden terms. So,
  exactly like a file descriptor, a channel is handed to the guest as an **opaque
  non-negative integer handle**. The handle → broker-pid map lives in a registry
  keyed by the caller's opaque channel scope. The OS installs the
  `:guest_channel_scope` hook when it wants guest-facing operations to resolve
  handles; kernel clients can still pass raw broker pids directly.

  ## What is DROPPED (Dis/BEAM already provides it)

    * The Dis heap `Channel` type, `H2D`/`D2H` tagged-pointer plumbing, the
      `mover`/`mid`/`Type` copy machinery, and `freechan` — BEAM terms are copied
      by message-passing and reclaimed by GC.
    * `Tarray`-of-channels alt arms (`==>` over an array of channels); `alt`
      here takes a flat op list.
  """
  use GenServer

  @app :hyperlang
  @scope_hook_key :guest_channel_scope
  @owner_hook_key :guest_channel_owner
  @channel_payload_tag {__MODULE__, :channel_payload}
  @channel_handle_tag {__MODULE__, :channel_handle}
  @known_channel_handles_key {__MODULE__, :known_channel_handles}
  @channel_classification_tab :hyperlang_channel_classifications
  @startchan_tab :hyperlang_startchans
  @startchan_msg {__MODULE__, :startchan_msg}
  @startchan_ack {__MODULE__, :startchan_ack}
  @channel_classifications [:handle_free, :may_contain_handles]
  @ex_alt "alt send/recv on same chan"

  # ---------------------------------------------------------------------------
  # Registry — handle (int) → broker pid, per opaque channel scope.
  #
  # One registry GenServer for the VM, holding `%{{scope, handle} => broker}`.
  # Keyed by stable scope identity, so a spawned child that shares its parent's
  # scope sees the same handles (channels pass as args).
  #
  # FORKNS carry-over: a Limbo `chan` is a heap object the forking proc and its
  # children all reference; `sys->pctl(FORKNS)` reshapes only the NAMESPACE
  # (Pgrp), never the channel set. Because handles are keyed by the namespace
  # scope identity, FORKNS (which mints a fresh scope) would orphan the forking proc's
  # handles — so `fork_scope/2` re-keys its live entries from the old scope into
  # the new one (same handle ints, same broker pids). See `fork_scope/2` and
  # SOURCE_ALIGNMENT A2.
  # ---------------------------------------------------------------------------

  @registry __MODULE__.Registry

  defmodule Registry do
    @moduledoc false
    use GenServer

    @resolve_table :hyperlang_channel_registry_resolve

    def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

    # A channel handle is the Dis `Channel*` identity: GLOBALLY unique per broker
    # (a canonical handle minted from one monotonic `next`, recorded in
    # `broker_handles`), NOT a per-Pgrp counter. So a handle a Prog holds means the
    # SAME channel in every Pgrp that shares/inherits it, and a child Prog's later
    # `newchan`/`file2chan` can never mint a handle that collides with one its
    # parent already handed across `sys:spawn` (the per-Pgrp-counter-copied-by-value
    # bug). `{scope, handle} => broker` are per-Pgrp ALIASES of that one identity.
    @impl true
    def init(_) do
      ensure_resolve_table!()

      # The registry owns the classification and startchan tables so they
      # outlive the guest process that creates the first channel.
      for table <- [:hyperlang_channel_classifications, :hyperlang_startchans] do
        :ets.new(table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])
      end

      {:ok,
       %{
         brokers: %{},
         broker_aliases: %{},
         ref_brokers: %{},
         broker_handles: %{},
         broker_refs: %{},
         broker_sizes: %{},
         next: 0,
         start_owners: %{},
         start_refs: %{}
       }}
    end

    @impl true
    def handle_call(request, from, state) do
      scope =
        case request do
          {:alias_handle, _, target, _} ->
            target

          {:fork_scope, target, _} ->
            target

          {:startchan, _, _, scope} ->
            scope

          {:drop_startchan, handle} ->
            case :ets.lookup(:hyperlang_startchans, handle) do
              [{_, owner}] ->
                case state.start_owners[owner] do
                  {_, handles} -> Map.get(handles, handle)
                  nil -> nil
                end

              [] ->
                nil
            end

          {kind, scope, _} when kind in [:remove, :resolve] ->
            scope

          {:install, scope, _, _} ->
            scope

          {:install, scope, _, _, _} ->
            scope

          _ ->
            nil
        end

      # Pin the accounting process before dispatch: a late bill must not land
      # in a newer lifetime that reused the same scope name.
      accountant = Hyperlang.Scope.Channels.address(scope)
      {:reductions, before} = Process.info(self(), :reductions)
      result = dispatch(request, from, state)
      {:reductions, after_r} = Process.info(self(), :reductions)

      if accountant do
        send(accountant, {:registry_work, after_r - before, elem(request, 0) == :remove})
      end

      result
    end

    defp dispatch({:startchan, handle, owner, scope}, _from, st) do
      case Hyperlang.Scope.Channels.try_request(scope, owner, {:startchan, handle}) do
        :ok ->
          if :ets.insert_new(:hyperlang_startchans, {handle, owner}) do
            {ref, handles} =
              Map.get_lazy(st.start_owners, owner, fn -> {Process.monitor(owner), %{}} end)

            owners = Map.put(st.start_owners, owner, {ref, Map.put(handles, handle, scope)})

            {:reply, handle,
             %{st | start_owners: owners, start_refs: Map.put(st.start_refs, ref, owner)}}
          else
            Hyperlang.Scope.release_startchan(scope, handle)
            {:reply, {:error, :eagain}, st}
          end

        :retry ->
          {:reply, {:error, :scope_throttled}, st}

        error ->
          {:reply, error, st}
      end
    end

    defp dispatch({:drop_startchan, handle}, _from, st) do
      {:reply, :ok, drop_startchan(st, handle)}
    end

    defp dispatch({:install, scope, broker, size, classification}, from, st) do
      :ets.insert(:hyperlang_channel_classifications, {broker, classification})
      dispatch({:install, scope, broker, size}, from, st)
    end

    defp dispatch({:install, scope, broker, size}, _from, st) do
      {handle, st} = ensure_handle(st, broker)
      sync_alias(scope, handle, broker)

      {:reply, handle,
       %{
         put_alias(st, {scope, handle}, broker)
         | broker_sizes: Map.put(st.broker_sizes, broker, size)
       }}
    end

    defp dispatch({:resolve, scope, handle}, _from, st) do
      broker = Map.get(st.brokers, {scope, handle})

      cond do
        is_pid(broker) and Process.alive?(broker) ->
          sync_alias(scope, handle, broker)
          {:reply, broker, st}

        is_pid(broker) ->
          delete_alias(scope, handle)
          {:reply, nil, purge_broker(st, broker)}

        true ->
          {:reply, nil, st}
      end
    end

    defp dispatch({:alias_handle, from_scope, to_scope, handle}, {owner, _}, st) do
      case Map.get(st.brokers, {from_scope, handle}) do
        broker when is_pid(broker) ->
          case charge_alias(st, to_scope, broker, owner) do
            :ok ->
              sync_alias(to_scope, handle, broker)
              {:reply, :ok, put_alias(st, {to_scope, handle}, broker)}

            _ ->
              {:reply, :error, st}
          end

        _ ->
          {:reply, :error, st}
      end
    end

    defp dispatch({:remove, scope, handle}, _from, st) do
      broker = Map.get(st.brokers, {scope, handle})
      st = drop_alias(st, {scope, handle})
      orphaned = if broker && not Map.has_key?(st.broker_aliases, broker), do: broker
      {:reply, {orphaned, broker}, forget_if_unaliased(st, broker)}
    end

    defp dispatch({:remove_broker, broker}, _from, st) do
      {:reply, :ok, purge_broker(st, broker)}
    end

    # FORKNS: carry the live channel set from `old_scope` into the freshly-forked
    # `new_scope`. A Limbo `chan` is a HEAP object (`Channel*`) the forking proc and
    # its children all reference; `sys->pctl(FORKNS)` copies only the NAMESPACE
    # (`Pgrp`/the mount table via `scopecpy`), NEVER the channel set — so every
    # handle the forking proc already holds must keep resolving to the SAME broker
    # afterwards. Re-key each `{old_scope, h} => broker` to `{new_scope, h} => broker`
    # (same handle int, same broker pid — the broker is the shared `Channel*`, not
    # copied), and carry forward the handle counter so a later `newchan` in the
    # child does not collide with an inherited handle. The old scope's entries are
    # left in place: a sibling that did NOT fork still resolves them, and the old
    # Pgrp is closed/dropped by its own `closescope` lifecycle independently of the
    # broker (channels are reclaimed when their broker process exits, never by the
    # registry, so this never double-frees a `Channel*`).
    defp dispatch({:fork_scope, new_scope, old_scope}, {owner, _}, st) do
      moved =
        for {{pg, h}, broker} <- st.brokers,
            pg == old_scope,
            into: %{},
            do: {{new_scope, h}, broker}

      channels = Enum.uniq(Map.values(moved)) |> Enum.map(&{&1, Map.fetch!(st.broker_sizes, &1)})

      case Hyperlang.Scope.Channels.try_request(new_scope, owner, {:channels, channels}) do
        :ok ->
          Enum.each(moved, fn {{scope, h}, broker} -> sync_alias(scope, h, broker) end)
          st = Enum.reduce(moved, st, fn {key, broker}, acc -> put_alias(acc, key, broker) end)
          {:reply, :ok, st}

        :retry ->
          {:reply, {:error, :scope_throttled}, st}

        error ->
          {:reply, error, st}
      end
    end

    # Pgrp close: drop every `{scope, h} => broker` entry for this scope and report
    # which brokers are now UNREFERENCED so the caller can terminate them. A
    # broker shared with another scope (a FORKNS copy left both `{old,h}` and
    # `{new,h}` pointing at it) SURVIVES — it is reclaimed only when its LAST
    # referencing scope closes. FileIO brokers also have a server-owner monitor
    # installed on first receive/alt-arm; that owner path can reap them before
    # scope close, matching Inferno's FileIO reachability. Returns the orphaned
    # broker pids (deduped); the registry never terminates them itself (that
    # would block this GenServer).
    defp dispatch({:close_scope, scope}, _from, st) do
      mine =
        for {{pg, _h} = k, b} <- st.brokers, pg == scope, do: {k, b}

      st = Enum.reduce(mine, st, fn {key, _broker}, acc -> drop_alias(acc, key) end)

      orphaned =
        Enum.uniq(
          for {_key, broker} <- mine, not Map.has_key?(st.broker_aliases, broker), do: broker
        )

      {:reply, {orphaned, Enum.uniq(Enum.map(mine, &elem(&1, 1)))}, forget_brokers(st, orphaned)}
    end

    @impl true
    def handle_info({:scope_closed, scope}, st) do
      {:reply, {orphaned, _charged}, st} = dispatch({:close_scope, scope}, nil, st)
      Enum.each(orphaned, &GenServer.cast(&1, :retire))

      st =
        Enum.reduce(st.start_owners, st, fn {_owner, {_ref, handles}}, st ->
          Enum.reduce(handles, st, fn {handle, handle_scope}, st ->
            if handle_scope == scope, do: drop_startchan(st, handle), else: st
          end)
        end)

      {:noreply, st}
    end

    def handle_info({:DOWN, ref, :process, _pid, _reason}, st) do
      case Map.get(st.start_refs, ref) do
        owner when is_pid(owner) ->
          {_ref, handles} = st.start_owners[owner]
          {:noreply, Enum.reduce(Map.keys(handles), st, &drop_startchan(&2, &1))}

        nil ->
          case Map.get(st.ref_brokers, ref) do
            nil -> {:noreply, st}
            broker -> {:noreply, purge_broker(st, broker, false)}
          end
      end
    end

    defp charge_alias(st, scope, broker, owner) do
      slots = Map.fetch!(st.broker_sizes, broker)
      Hyperlang.Scope.Channels.try_request(scope, owner, {:channels, [{broker, slots}]})
    end

    defp drop_startchan(st, handle) do
      case :ets.take(:hyperlang_startchans, handle) do
        [{^handle, owner}] ->
          {ref, handles} = st.start_owners[owner]
          Hyperlang.Scope.release_startchan(handles[handle], handle)
          handles = Map.delete(handles, handle)

          if map_size(handles) == 0 do
            Process.demonitor(ref, [:flush])

            %{
              st
              | start_owners: Map.delete(st.start_owners, owner),
                start_refs: Map.delete(st.start_refs, ref)
            }
          else
            put_in(st, [:start_owners, owner], {ref, handles})
          end

        _ ->
          st
      end
    end

    # Mint (or reuse) the broker's canonical global handle.
    defp ensure_handle(st, broker) do
      case Map.get(st.broker_handles, broker) do
        nil ->
          h = st.next
          ref = Process.monitor(broker)

          {h,
           %{
             st
             | next: h + 1,
               broker_handles: Map.put(st.broker_handles, broker, h),
               broker_refs: Map.put(st.broker_refs, broker, ref),
               ref_brokers: Map.put(st.ref_brokers, ref, broker)
           }}

        h ->
          {h, st}
      end
    end

    def lookup_alias(scope, handle) do
      case :ets.whereis(@resolve_table) do
        :undefined ->
          :no_table

        table ->
          key = {scope, handle}

          case :ets.lookup(table, key) do
            [{^key, broker}] -> {:ok, broker}
            [] -> :miss
          end
      end
    rescue
      ArgumentError -> :no_table
    end

    defp ensure_resolve_table! do
      case :ets.whereis(@resolve_table) do
        :undefined ->
          :ets.new(@resolve_table, [
            :named_table,
            :protected,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])

        _table ->
          :ok
      end

      :ok
    end

    defp sync_alias(scope, handle, broker) do
      case :ets.whereis(@resolve_table) do
        :undefined ->
          :ok

        table ->
          :ets.insert(table, {{scope, handle}, broker})
          :ok
      end
    rescue
      ArgumentError -> :ok
    end

    defp delete_alias(scope, handle) do
      case :ets.whereis(@resolve_table) do
        :undefined ->
          :ok

        table ->
          :ets.delete(table, {scope, handle})
      end
    rescue
      ArgumentError -> :ok
    end

    # Reverse aliases make the allocation/free hot path independent of the
    # total number of other scopes' channels. They also bound broker-death
    # cleanup to that broker's aliases rather than scanning the whole registry.
    defp put_alias(st, key, broker) do
      aliases = Map.update(st.broker_aliases, broker, MapSet.new([key]), &MapSet.put(&1, key))
      %{st | brokers: Map.put(st.brokers, key, broker), broker_aliases: aliases}
    end

    defp drop_alias(st, {scope, handle} = key) do
      delete_alias(scope, handle)

      case Map.pop(st.brokers, key) do
        {nil, _} ->
          st

        {broker, brokers} ->
          aliases = st.broker_aliases |> Map.fetch!(broker) |> MapSet.delete(key)

          reverse =
            if MapSet.size(aliases) == 0,
              do: Map.delete(st.broker_aliases, broker),
              else: Map.put(st.broker_aliases, broker, aliases)

          %{st | brokers: brokers, broker_aliases: reverse}
      end
    end

    defp forget_if_unaliased(st, nil), do: st

    defp forget_if_unaliased(st, broker) do
      if Map.has_key?(st.broker_aliases, broker), do: st, else: forget_broker(st, broker)
    end

    defp forget_brokers(st, brokers), do: Enum.reduce(brokers, st, &forget_broker(&2, &1))

    defp forget_broker(st, broker, demonitor? \\ true) do
      :ets.delete(:hyperlang_channel_classifications, broker)

      case Map.get(st.broker_refs, broker) do
        nil -> :ok
        ref when demonitor? -> Process.demonitor(ref, [:flush])
        _ref -> :ok
      end

      %{
        st
        | broker_handles: Map.delete(st.broker_handles, broker),
          broker_refs: Map.delete(st.broker_refs, broker),
          ref_brokers: Map.delete(st.ref_brokers, st.broker_refs[broker]),
          broker_aliases: Map.delete(st.broker_aliases, broker),
          broker_sizes: Map.delete(st.broker_sizes, broker)
      }
    end

    defp purge_broker(st, broker, demonitor? \\ true) do
      st.broker_aliases
      |> Map.get(broker, MapSet.new())
      |> Enum.reduce(st, fn key, acc -> drop_alias(acc, key) end)
      |> forget_broker(broker, demonitor?)
    end
  end

  defmodule BrokerSupervisor do
    @moduledoc false
    use Supervisor
    @background __MODULE__.Background
    @latency __MODULE__.Latency

    def start_link(_opts), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

    @impl true
    def init(:ok) do
      partitions = max(16, 4 * :erlang.system_info(:schedulers_online))

      children =
        for {name, priority} <- [{@background, :low}, {@latency, :normal}] do
          Supervisor.child_spec(
            {PartitionSupervisor,
             child_spec:
               {DynamicSupervisor, strategy: :one_for_one, spawn_opt: [priority: priority]},
             name: name,
             partitions: partitions},
            id: name
          )
        end

      Supervisor.init(children, strategy: :one_for_one)
    end

    def start_child({:scoped, scope, _} = arg) do
      pool = if Hyperlang.Scope.priority(scope) == :low, do: @background, else: @latency

      DynamicSupervisor.start_child(
        {:via, PartitionSupervisor, {pool, scope}},
        {Hyperlang.Chan, arg}
      )
    end

    def start_child(arg) do
      DynamicSupervisor.start_child(
        {:via, PartitionSupervisor, {@latency, self()}},
        {Hyperlang.Chan, arg}
      )
    end

    def partitions do
      for pool <- [@background, @latency],
          child <- PartitionSupervisor.which_children(pool),
          do: {pool, elem(child, 0), elem(child, 1)}
    end
  end

  @doc false
  def start_link({:scoped, scope, init_arg}),
    do:
      GenServer.start_link(__MODULE__, init_arg,
        spawn_opt: [{:priority, Hyperlang.Scope.priority(scope)}]
      )

  def start_link(init_arg), do: GenServer.start_link(__MODULE__, init_arg)

  @doc false
  def child_spec(init_arg) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [init_arg]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc """
  Start the channel registry and broker supervisor (idempotent).

  This runtime starts on first use, so channel operations do not require the
  OTP application tree to have been booted.
  """
  def ensure_started do
    with :ok <- ensure_process(Registry, fn -> Registry.start_link([]) end),
         :ok <- ensure_process(BrokerSupervisor, fn -> BrokerSupervisor.start_link([]) end) do
      :ok
    end
  end

  @doc "Same as `ensure_started/0`."
  def start_registry, do: ensure_started()

  defp ensure_process(name, start_fun) do
    case Process.whereis(name) do
      nil ->
        case start_fun.() do
          {:ok, pid} when is_pid(pid) ->
            Process.unlink(pid)
            :ok

          {:error, {:already_started, pid}} when is_pid(pid) ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      _pid ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # newchan(size) — `chan of T` (size 0) / `chan[size] of T`.
  #
  # Allocates a broker and installs it in the caller's opaque scope registry,
  # returning the opaque integer handle. Guest calls resolve scope through the
  # :guest_channel_scope app-env hook; kernel clients can pass a scope directly.
  # ---------------------------------------------------------------------------

  @doc """
  Create a channel of `size` buffer slots (0 = unbuffered/rendezvous) in process
  `scope`. Returns `{handle, broker_pid}`; the handle is the opaque integer the
  guest holds, the pid is the broker.
  """
  def newchan(size) when is_integer(size) and size >= 0 do
    newchan(size, :may_contain_handles)
  end

  def newchan(size, classification)
      when is_integer(size) and size >= 0 and classification in @channel_classifications do
    with {:ok, scope} <- current_scope(),
         {handle, _broker} <- create_channel(scope, size, classification) do
      handle
    end
  end

  def newchan(scope, size) when is_integer(size) and size >= 0 do
    create_channel(scope, size, :may_contain_handles)
  end

  def newchan(scope, size, classification)
      when is_integer(size) and size >= 0 and classification in @channel_classifications do
    create_channel(scope, size, classification)
  end

  defp create_channel(scope, size, classification) do
    with {:ok, scope} <- normalize_scope(scope),
         :ok <- ensure_started() do
      do_create_channel(scope, size, classification)
    end
  end

  defp do_create_channel(scope, size, classification) do
    with_scope_priority(scope, fn -> allocate_channel(scope, size, classification) end)
  end

  # Trusted host allocation loops have no guest CPU permit. Run their channel
  # bookkeeping at the owning scope's class too, restoring host priority even
  # when allocation or cleanup raises. They cannot flood normal-priority work.
  defp with_scope_priority(scope, fun) do
    previous = Process.flag(:priority, Hyperlang.Scope.priority(scope))

    try do
      fun.()
    after
      Process.flag(:priority, previous)
    end
  end

  defp allocate_channel(scope, size, classification) do
    case Hyperlang.Scope.Channels.await(scope) do
      :ok -> :ok
      {:error, reason} -> :erlang.error({:hyperlang_channel, reason})
    end

    {:ok, broker} = start_broker({:scoped, scope, {:chan, size}})

    try do
      case Hyperlang.Scope.charge_channel(scope, broker, size, allocation_owner()) do
        :ok -> :ok
        {:error, reason} -> :erlang.error({:hyperlang_channel, reason})
      end

      handle =
        GenServer.call(@registry, {:install, scope_key(scope), broker, size, classification})

      remember_channel_handle(handle)
      {handle, broker}
    rescue
      error ->
        stop_broker(broker)
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        stop_broker(broker)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc """
  Expose an existing channel broker through `scope`'s integer-handle registry.

  Used when a kernel-internal FileIO request carries a reply `Channel*` to guest
  code: the kernel keeps the broker pid, while the guest receives a scoped int
  handle and replies through the normal sys:send/alt path.
  """
  def handle_for(scope, broker) when is_pid(broker) do
    with {:ok, scope} <- normalize_scope(scope),
         :ok <- ensure_started(),
         :ok <-
           Hyperlang.Scope.charge_channel(
             scope,
             broker,
             GenServer.call(broker, :buffer_slots),
             allocation_owner()
           ) do
      size = GenServer.call(broker, :buffer_slots)
      GenServer.call(@registry, {:install, scope_key(scope), broker, size})
    end
  end

  @doc "True when `pid` is one of this module's channel broker processes."
  def broker?(pid) when is_pid(pid) do
    GenServer.call(pid, :channel_broker?, 5_000)
  catch
    :exit, _ -> false
  end

  def broker?(_), do: false

  @doc "Resolve a channel handle to its broker pid within `scope`, or nil."
  def resolve(scope, handle) when is_integer(handle) do
    with {:ok, scope} <- normalize_scope(scope),
         :ok <- ensure_started() do
      scope = scope_key(scope)

      case Registry.lookup_alias(scope, handle) do
        {:ok, broker} when is_pid(broker) ->
          if Process.alive?(broker),
            do: broker,
            else: GenServer.call(@registry, {:resolve, scope, handle})

        {:ok, _stale} ->
          GenServer.call(@registry, {:resolve, scope, handle})

        :miss ->
          GenServer.call(@registry, {:resolve, scope, handle})

        :no_table ->
          GenServer.call(@registry, {:resolve, scope, handle})
      end
    else
      {:error, _reason} -> nil
    end
  end

  @doc """
  Install `handle` in `to_scope` when it is a live channel capability in
  `from_scope`.

  Guest channel messages can carry channel handles created after `pctl(FORKNS)`.
  The handle is still the same Inferno heap-channel capability, but the receiving
  Prog may be in a different namespace scope. Aliasing only from a scope that
  already owns the handle preserves the capability boundary while letting the
  handle cross explicitly in a channel payload.
  """
  def alias_handle(from_scope, to_scope, handle) when is_integer(handle) do
    :ok = ensure_started()

    case {scope_key(from_scope), scope_key(to_scope)} do
      {nil, _} -> :error
      {_, nil} -> :error
      {from_key, to_key} -> GenServer.call(@registry, {:alias_handle, from_key, to_key, handle})
    end
  end

  def alias_handle(_from_scope, _to_scope, _handle), do: :error

  @doc """
  `pctl(FORKNS)` channel carry-over. Inferno channels are heap objects shared
  across a proc and its children regardless of the namespace group, and FORKNS
  reshapes only the namespace (`Pgrp.scopecpy`), never the channel set. So when
  the namespace scope is replaced by a fresh one, re-key the forking proc's live
  channel handles from `old_scope` into `new_scope` (same handle ints, same broker
  pids) so its existing handles still resolve in the child. A no-op if either
  scope is nil or the registry is not started.
  """
  def fork_scope(new_scope, old_scope) do
    case GenServer.whereis(@registry) do
      nil ->
        :ok

      _ ->
        case {scope_key(new_scope), scope_key(old_scope)} do
          {nil, _} -> :ok
          {_, nil} -> :ok
          {new_key, old_key} -> GenServer.call(@registry, {:fork_scope, new_key, old_key})
        end
    end
  end

  @doc """
  Release the channel set owned by `scope`. Drops the scope's handle->broker
  registry entries and TERMINATES every broker that is no longer referenced by
  any other scope (a FORKNS-shared broker survives until its last scope closes).
  Without this a closed lifetime leaks both
  the broker process (under `BrokerSupervisor`) and a stale registry entry that
  still resolves. A no-op if the registry is not started.
  """
  def close_scope(scope), do: close_scope_key(scope_key(scope))

  @doc false
  def close_scope_key(nil), do: :ok

  def close_scope_key(scope_key) do
    case GenServer.whereis(@registry) do
      nil ->
        :ok

      _ ->
        :ok = ensure_started()
        {orphaned, charged} = GenServer.call(@registry, {:close_scope, scope_key})
        Enum.each(charged, &Hyperlang.Scope.uncharge_channel(scope_key, &1))

        # Stop each lifetime's broker directly. A supervisor never waits for
        # another scope's termination callback or a broker's pending work.
        Enum.each(orphaned, &stop_broker/1)

        :ok
    end
  end

  @doc """
  Free a channel alias, revoking it and releasing its scope quota before return.
  A broker shared by another scope remains alive. The last alias schedules
  retirement in the broker itself, so the allocator never waits on broker
  supervision or a close hook. The hook runs once when retirement completes.
  Scope closure still waits for that lifetime's orphaned brokers directly.
  """
  def freechan(scope, handle, broker) when is_integer(handle) do
    with_scope_priority(scope, fn ->
      case GenServer.whereis(@registry) do
        nil ->
          :ok

        _ ->
          # Logical revocation and quota release are synchronous. Retirement
          # runs in the broker itself; allocation never waits on its supervisor.
          {orphaned, charged} = GenServer.call(@registry, {:remove, scope_key(scope), handle})
          if charged, do: Hyperlang.Scope.uncharge_channel(scope, charged)

          if orphaned == broker and is_pid(broker) do
            Process.put(
              known_channel_handles_key(),
              MapSet.delete(known_channel_handles(), handle)
            )

            GenServer.cast(broker, :retire)
          end

          :ok
      end
    end)
  end

  def freechan(_scope, _handle, _broker), do: :ok

  defp scope_key(nil), do: nil
  defp scope_key(scope), do: scope

  defp normalize_scope(nil), do: {:error, :no_scope}
  defp normalize_scope(scope), do: {:ok, scope}

  @doc """
  Resolve the current guest channel scope through the `:guest_channel_scope`
  app-env hook.

  The hook may be a zero-arity function or `{module, function}`. Missing or bad
  hooks fail closed with `{:error, :no_scope}`.
  """
  def current_scope do
    with {:ok, hook} <- scope_hook() do
      invoke_scope_hook(hook)
    end
  end

  defp scope_hook do
    case installed_hook(@scope_hook_key, :__hyperlang_no_channel_scope__) do
      fun when is_function(fun, 0) -> {:ok, fun}
      {module, function} when is_atom(module) and is_atom(function) -> {:ok, {module, function}}
      _other -> {:error, :no_scope}
    end
  end

  defp installed_hook(key, missing) do
    case :persistent_term.get({__MODULE__, key}, :__hyperlang_no_installed_hook__) do
      :__hyperlang_no_installed_hook__ -> Application.get_env(@app, key, missing)
      hook -> hook
    end
  end

  defp invoke_scope_hook(fun) when is_function(fun, 0) do
    normalize_scope_reply(fun.())
  rescue
    _ -> {:error, :no_scope}
  catch
    _, _ -> {:error, :no_scope}
  end

  defp invoke_scope_hook({module, function}) do
    normalize_scope_reply(apply(module, function, []))
  rescue
    _ -> {:error, :no_scope}
  catch
    _, _ -> {:error, :no_scope}
  end

  defp normalize_scope_reply({:ok, scope}), do: normalize_scope(scope)
  defp normalize_scope_reply({:error, reason}), do: {:error, reason}
  defp normalize_scope_reply(scope), do: normalize_scope(scope)

  @doc """
  Close an ephemeral broker and remove every registry handle that points at it.

  This is the BEAM counterpart of devsrv's `destroy(rc/wc)` for per-request
  Rread/Rwrite reply channels after the kernel receives the reply.
  """
  def close_broker(broker) when is_pid(broker) do
    case GenServer.whereis(@registry) do
      nil -> :ok
      _ -> GenServer.call(@registry, {:remove_broker, broker})
    end

    stop_broker(broker)
  end

  def close_broker(_broker), do: :ok

  # ---------------------------------------------------------------------------
  # csend(c, v) / crecv(c) — blocking send / receive (Dis isend/irecv).
  # The caller's worker process blocks in the GenServer.call until matched.
  # ---------------------------------------------------------------------------

  @doc """
  Send `v` on channel broker `c`, blocking (rendezvous / buffer-full) until the
  value is taken or buffered. Returns `:ok`.
  """
  def csend(c, v) when is_pid(c) do
    if Application.get_env(@app, :channel_trace, false) do
      IO.warn(
        "channel.csend caller=#{inspect(self())} broker=#{inspect(c)} value=#{inspect(trace_value_shape(v))}"
      )

      trace_event({:csend, self(), c, trace_value_shape(v)})
    end

    Hyperlang.Scope.blocking(fn -> GenServer.call(c, {:send, v}, :infinity) end)
  end

  def csend(handle, value) when is_integer(handle) and handle < 0 do
    startchan_send(handle, value)
  end

  def csend(handle, value) when is_integer(handle) do
    with_broker(handle, fn broker, scope ->
      :ok = csend(broker, channel_payload(value, scope, channel_classification(broker)))
      handle
    end)
  end

  @doc """
  Receive a value from channel broker `c`, blocking until one is available.
  Returns the value.
  """
  def crecv(c) when is_pid(c) do
    c
    |> crecv_raw()
    |> public_channel_value()
  end

  def crecv(handle) when is_integer(handle) and handle < 0 do
    startchan_recv(handle)
  end

  def crecv(handle) when is_integer(handle) do
    with_broker(handle, fn broker, scope ->
      broker
      |> crecv_raw()
      |> guest_channel_value(scope)
    end)
  end

  @doc """
  Receive a value without stripping the channel payload transport envelope.

  This is only for the guest boundary, which must inspect the source scope before
  exposing nested channel handles back to a guest.
  """
  def crecv_raw(c) when is_pid(c) do
    if Application.get_env(@app, :channel_trace, false) do
      IO.warn("channel.crecv caller=#{inspect(self())} broker=#{inspect(c)}")
      trace_event({:crecv, self(), c})
    end

    Hyperlang.Scope.blocking(fn -> GenServer.call(c, {:recv, fileio_owner()}, :infinity) end)
  end

  defp trace_event(event) do
    case :ets.whereis(:hb_channel_trace) do
      :undefined -> :ok
      tid -> :ets.insert(tid, {System.monotonic_time(), event})
    end
  end

  defp trace_value_shape(value) when is_tuple(value), do: {:tuple, tuple_size(value)}
  defp trace_value_shape(value) when is_list(value), do: {:list, length(value)}
  defp trace_value_shape(value) when is_map(value), do: {:map, Map.keys(value)}
  defp trace_value_shape(value), do: value

  # ---------------------------------------------------------------------------
  # startchan — one-shot command-start rendezvous.
  #
  # This is not a Limbo channel: the returned negative integer is a one-shot
  # direct mailbox capability used by shell/rc spawn handoffs, so it does not
  # allocate a broker or a registry row.
  # ---------------------------------------------------------------------------

  @doc false
  def startchan, do: new_startchan()

  @doc false
  def new_startchan do
    with :ok <- ensure_started(), do: new_startchan(0)
  end

  defp new_startchan(attempt) when attempt < 16 do
    handle = random_startchan_handle()

    scope = Hyperlang.Scope.current()

    if is_nil(Hyperlang.Scope.Channels.address(scope)),
      do: Hyperlang.Scope.ensure(scope, allocation_owner())

    case GenServer.call(@registry, {:startchan, handle, self(), scope}) do
      {:error, :eagain} -> new_startchan(attempt + 1)
      result -> result
    end
  rescue
    ArgumentError -> {:error, :eagain}
  end

  defp new_startchan(_attempt), do: {:error, :eagain}

  defp random_startchan_handle do
    raw = :crypto.strong_rand_bytes(8) |> :binary.decode_unsigned()
    -1 - Bitwise.band(raw, 0x3FFF_FFFF_FFFF_FFFF)
  end

  @doc false
  def startchan_send(handle, value) when is_integer(handle) and handle < 0 do
    Hyperlang.Scope.blocking(fn ->
      case lookup_startchan_owner(handle) do
        owner when is_pid(owner) ->
          if Process.alive?(owner) do
            startchan_send_to_owner(handle, owner, value)
          else
            GenServer.call(@registry, {:drop_startchan, handle})
            {:error, :badchan}
          end

        _ ->
          {:error, :badchan}
      end
    end)
  end

  def startchan_send(_handle, _value), do: {:error, :badchan}

  defp startchan_send_to_owner(handle, owner, value) do
    ref = make_ref()
    mon = Process.monitor(owner)
    send(owner, {@startchan_msg, handle, self(), ref, value})

    receive do
      {@startchan_ack, ^ref} ->
        Process.demonitor(mon, [:flush])
        handle

      {:DOWN, ^mon, :process, ^owner, _reason} ->
        GenServer.call(@registry, {:drop_startchan, handle})
        {:error, :badchan}
    end
  end

  @doc false
  def startchan_recv(handle) when is_integer(handle) and handle < 0 do
    Hyperlang.Scope.blocking(fn ->
      case lookup_startchan_owner(handle) do
        owner when owner == self() ->
          receive do
            {@startchan_msg, ^handle, from, ref, value} when is_pid(from) ->
              GenServer.call(@registry, {:drop_startchan, handle})
              send(from, {@startchan_ack, ref})
              value
          end

        _ ->
          {:error, :badchan}
      end
    end)
  end

  def startchan_recv(_handle), do: {:error, :badchan}

  defp lookup_startchan_owner(handle) do
    case :ets.lookup(@startchan_tab, handle) do
      [{^handle, owner}] -> owner
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp allocation_owner do
    case installed_hook(@owner_hook_key, nil) do
      nil -> Process.get(:"$hyperlang_msg_context", %{}) |> Map.get(:scope_owner, self())
      _ -> fileio_owner()
    end
  end

  # ---------------------------------------------------------------------------
  # Guest handle payloads — scoped integer handles cross channels as values.
  # ---------------------------------------------------------------------------

  @doc false
  def channel_payload(value, scope, :handle_free),
    do: {@channel_payload_tag, scope, :handle_free, value}

  def channel_payload(value, scope, _classification),
    do: {@channel_payload_tag, scope, :may_contain_handles, channel_payload_value(value, scope)}

  defp channel_payload_value(value, scope) when is_integer(value) do
    if known_channel_handle?(value, scope) do
      {@channel_handle_tag, value}
    else
      value
    end
  end

  defp channel_payload_value(value, scope) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&channel_payload_value(&1, scope))
    |> List.to_tuple()
  end

  defp channel_payload_value(value, scope) when is_list(value) do
    Enum.map(value, &channel_payload_value(&1, scope))
  end

  defp channel_payload_value(value, scope) when is_map(value) do
    Map.new(value, fn {key, item} ->
      {channel_payload_value(key, scope), channel_payload_value(item, scope)}
    end)
  end

  defp channel_payload_value(value, _scope), do: value

  @doc false
  def guest_channel_value({@channel_payload_tag, _from_scope, :handle_free, value}, _to_scope),
    do: value

  def guest_channel_value(
        {@channel_payload_tag, from_scope, :may_contain_handles, value},
        to_scope
      ) do
    guest_channel_value(value, from_scope, to_scope)
  end

  def guest_channel_value({@channel_payload_tag, from_scope, value}, to_scope) do
    guest_channel_value(value, from_scope, to_scope)
  end

  def guest_channel_value(value, scope), do: guest_channel_value(value, scope, scope)

  def guest_channel_value({@channel_handle_tag, handle}, from_scope, to_scope)
      when is_integer(handle) do
    cond do
      scope_key(from_scope) == scope_key(to_scope) ->
        remember_channel_handle(handle)
        handle

      alias_handle(from_scope, to_scope, handle) == :ok ->
        remember_channel_handle(handle)
        handle

      true ->
        nil
    end
  end

  def guest_channel_value(value, _from_scope, scope) when is_pid(value) do
    if broker?(value) do
      case handle_for(scope, value) do
        handle when is_integer(handle) ->
          remember_channel_handle(handle)
          handle

        _ ->
          nil
      end
    else
      value
    end
  end

  def guest_channel_value(value, from_scope, scope) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&guest_channel_value(&1, from_scope, scope))
    |> List.to_tuple()
  end

  def guest_channel_value(value, from_scope, scope) when is_list(value) do
    Enum.map(value, &guest_channel_value(&1, from_scope, scope))
  end

  def guest_channel_value(value, from_scope, scope) when is_map(value) do
    Map.new(value, fn {key, item} ->
      {guest_channel_value(key, from_scope, scope), guest_channel_value(item, from_scope, scope)}
    end)
  end

  def guest_channel_value(value, _from_scope, _scope), do: value

  @doc false
  def with_broker(handle, fun) when is_integer(handle) and is_function(fun, 2) do
    with {:ok, scope} <- current_scope() do
      with_broker(scope, handle, fun)
    end
  end

  def with_broker(scope, handle, fun) when is_integer(handle) and is_function(fun, 2) do
    case resolve(scope, handle) do
      broker when is_pid(broker) ->
        remember_channel_handle(handle)
        fun.(broker, scope)

      _ ->
        {:error, :badchan}
    end
  end

  @doc false
  def translate_alt_ops([], _scope), do: :error

  def translate_alt_ops(ops, scope) do
    Enum.reduce_while(ops, {:ok, []}, fn op, {:ok, acc} ->
      case translate_alt_op(op, scope) do
        {:ok, kop} -> {:cont, {:ok, [kop | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, kops} -> {:ok, Enum.reverse(kops)}
      :error -> :error
    end
  end

  defp translate_alt_op({:recv, handle}, scope) when is_integer(handle) do
    case resolve(scope, handle) do
      broker when is_pid(broker) ->
        remember_channel_handle(handle)
        {:ok, {:recv, broker}}

      _ ->
        :error
    end
  end

  defp translate_alt_op({:send, handle, value}, scope) when is_integer(handle) do
    case resolve(scope, handle) do
      broker when is_pid(broker) ->
        remember_channel_handle(handle)
        {:ok, {:send, broker, channel_payload(value, scope, channel_classification(broker))}}

      _ ->
        :error
    end
  end

  defp translate_alt_op(:default, _scope), do: {:ok, :default}
  defp translate_alt_op(_op, _scope), do: :error

  defp alt_result({:recv, index, value}, scope),
    do: {:recv, index, guest_channel_value(value, scope)}

  defp alt_result(result, _scope), do: result

  @doc false
  def known_channel_handle?(handle, scope) when is_integer(handle) do
    MapSet.member?(known_channel_handles(), handle) and is_pid(resolve(scope, handle))
  end

  def known_channel_handle?(_handle, _scope), do: false

  @doc false
  def remember_channel_handle(handle) when is_integer(handle) do
    key = known_channel_handles_key()
    Process.put(key, MapSet.put(Process.get(key, MapSet.new()), handle))
    :ok
  end

  def remember_channel_handle(_handle), do: :ok

  @doc false
  def known_channel_handles do
    Process.get(known_channel_handles_key(), MapSet.new())
  end

  defp known_channel_handles_key, do: @known_channel_handles_key

  @doc false
  def remember_channel_classification(broker, classification)
      when is_pid(broker) and classification in @channel_classifications do
    :ets.insert(@channel_classification_tab, {broker, classification})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def remember_channel_classification(_broker, _classification), do: :ok

  @doc false
  def channel_classification(broker) when is_pid(broker) do
    case :ets.lookup(@channel_classification_tab, broker) do
      [{^broker, classification}] -> classification
      _ -> :may_contain_handles
    end
  rescue
    ArgumentError -> :may_contain_handles
  end

  def channel_classification(_broker), do: :may_contain_handles

  # ---------------------------------------------------------------------------
  # FileIO typed channels (libinterp/xec.c `cnewc`/`movtmp`, the close-hook
  # `retype`, and the non-blocking `csendalt`) — the kernel-internal Dis channel
  # surface a host srv device needs to post a `Sys_FileIO` under
  # `/srv` (`sys->file2chan`) and forward client reads/writes over it.
  #
  # In Dis these are HEAP channels (a `Channel*` carved from `heap(&Tchannel)`),
  # NOT the per-scope handle channels guests see — devsrv holds the `Channel*`
  # directly and never hands it across the syscall door. So `cnewc` returns the
  # raw broker PID (the C `Channel*`), and `csendalt`/`csend`/`crecv` take that
  # pid, exactly as `srvread`/`srvwrite`/`srvunblock`/`srvcancelreqs` use them.
  # ---------------------------------------------------------------------------

  @doc """
  The `movtmp` mover sentinel (libinterp/xec.c `movtmp`). In Dis the channel
  `mover` is a function pointer driving the typed value copy during send/recv;
  on the BEAM message passing already copies the term by value, so the mover is
  an opaque marker passed to `cnewc/3` (kept 1:1 so `cnewc(t, movtmp(), n)`
  reads as in the reference). DROPPED: the `memmove`/`freeptrs`/`incmem` copy.
  """
  def movtmp, do: :movtmp

  @doc """
  `cnewc(t, mover, len)` (libinterp/xec.c) — allocate a fresh typed channel with
  `len` buffer slots (`len > 0` = buffered, as devsrv uses for its reply/request
  channels). `t` is the Dis value `Type*` (here the type TAG `:rread`/`:rwrite`/
  `:fileio_read`/`:fileio_write` — the heap GC type is DROPPED, only the tag is
  carried); `mover` is `movtmp()`. Returns the broker PID = the C `Channel*`.

  Unlike `newchan/2` this does NOT install the channel in a scope handle registry:
  these are kernel-internal `Channel*`s held by devsrv directly, never crossing
  the guest term boundary.
  """
  def cnewc(t, mover, len) when is_integer(len) and len >= 0 do
    {:ok, broker} = start_broker({:chan, len, t, mover})
    broker
  end

  @doc """
  `retype(c, hook)` — the BEAM home of devsrv's `srvretype` heap-type swap
  (libinterp `freetype(h->t); h->t = t; t->ref++; c->aux = f`). In Dis the swap
  installs the close-hook (`Trdchan`/`Twrchan`'s `free` callback =
  `freerdchan`/`freewrchan`) and binds `c->aux = f` (the `SrvFile*`). The Dis
  heap type / refcount is DROPPED (BEAM GC); the surviving behaviour is the
  close-hook binding: `hook` is `{module, fun, aux}`, invoked as
  `module.fun(aux, swept)` when the broker is collected (its owning process
  exits → the broker's `terminate/2`). `c` is the broker PID.
  """
  def retype(c, {_module, _fun, _aux} = hook) when is_pid(c) do
    GenServer.call(c, {:retype, hook}, :infinity)
  end

  @doc """
  Pair the read/write brokers of one `Sys->FileIO`.

  Inferno's `freeFileIO` destroys both channel fields together. The BEAM port
  uses integer scope handles for the guest view, so the channel brokers need an
  explicit peer link: when the server Proc that first receives from either side
  exits, the broker tears down its peer too, causing both devsrv close hooks to
  run.
  """
  def link_fileio_pair(read, write) when is_pid(read) and is_pid(write) do
    GenServer.call(read, {:fileio_peer, write}, :infinity)
    GenServer.call(write, {:fileio_peer, read}, :infinity)
    :ok
  end

  @doc """
  `csendalt(c, value, len)` (libinterp/xec.c) — a NON-BLOCKING send used by
  devsrv's `srvunblock` to push a sentinel request onto a server's read/write
  channel without parking. In Dis it grows the channel buffer if needed
  (`heaparray(t, len)`) so the `isend` it performs never blocks. Faithful
  mapping: hand the value to a parked receiver / armed alt-recv waiter if one is
  ready, else buffer it (growing past `size` as needed — the Dis buffer-grow).
  Always succeeds (returns 1, as the C returns 1 on the buffered path); `c` is
  the broker PID, `len` the requested buffer length (`-1` = grow on demand).
  """
  def csendalt(c, value, _len) when is_pid(c) do
    GenServer.call(c, {:csendalt, value}, :infinity)
  end

  # ---------------------------------------------------------------------------
  # alt(ops) — Dis altrdy/altcomm/altdone over a flat op list.
  #
  # `ops` is a list of `{:send, chan, value}` / `{:recv, chan}`, plus an
  # optional `:default` (the `*` arm). `chan` is a broker pid (kernel callers)
  # or a guest integer handle resolved in the caller's scope. Returns:
  #   * `{:recv, index, value}`  — recv arm `index` fired, value received
  #   * `{:send, index}`         — send arm `index` fired
  #   * `:default`               — no op ready and a default was present
  # `index` is the position of the chosen op in `ops` (Dis writes this into the
  # alt result so the caller dispatches the right arm). Blocks until exactly one
  # op fires unless a default is present.
  # ---------------------------------------------------------------------------

  @doc """
  Non-deterministic select over `ops`. See module doc for the op/return shapes.
  """
  def alt(ops) when is_list(ops) do
    if raw_alt_ops?(ops) do
      ops
      |> alt_raw()
      |> public_alt_result()
    else
      guest_alt(ops)
    end
  end

  @doc """
  Non-deterministic select without stripping the channel payload transport envelope.
  """
  def alt_raw(ops) when is_list(ops) do
    {indexed_ops, default?} = split_default(ops)
    reject_same_channel_send_recv!(Enum.map(indexed_ops, fn {op, _index} -> op end))
    ref = make_ref()
    caller = self()
    owner = fileio_owner()

    # Register intent on every broker; each broker replies either with an
    # immediate fire (it could commit at once) or :armed (parked, will message
    # `caller` when it can fire). We must commit EXACTLY ONE, so the broker that
    # fires does so atomically and we cancel the rest.
    arm_and_select(indexed_ops, default?, ref, caller, owner)
  end

  defp guest_alt(ops) do
    with {:ok, scope} <- current_scope(),
         {:ok, kernel_ops} <- translate_alt_ops(ops, scope) do
      kernel_ops
      |> alt_raw()
      |> alt_result(scope)
    else
      :error -> {:error, :badarg}
      {:error, _reason} = error -> error
    end
  end

  defp raw_alt_ops?(ops) do
    Enum.all?(ops, fn
      :default -> true
      {:send, broker, _value} when is_pid(broker) -> true
      {:recv, broker} when is_pid(broker) -> true
      _ -> false
    end)
  end

  defp public_alt_result({:recv, index, value}), do: {:recv, index, public_channel_value(value)}
  defp public_alt_result(other), do: other

  defp public_channel_value({@channel_payload_tag, _scope, :handle_free, value}),
    do: value

  defp public_channel_value({@channel_payload_tag, scope, :may_contain_handles, value}),
    do: guest_channel_value(value, scope, scope)

  defp public_channel_value({@channel_payload_tag, scope, value}),
    do: guest_channel_value(value, scope, scope)

  defp public_channel_value({@channel_handle_tag, handle})
       when is_integer(handle),
       do: handle

  defp public_channel_value({{_module, :channel_payload}, _scope, :handle_free, value}),
    do: value

  defp public_channel_value({{_module, :channel_payload}, _scope, :may_contain_handles, value}),
    do: public_channel_value(value)

  defp public_channel_value({{_module, :channel_payload}, _scope, value}),
    do: public_channel_value(value)

  defp public_channel_value({{_module, :channel_handle}, handle})
       when is_integer(handle),
       do: handle

  defp public_channel_value(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&public_channel_value/1)
    |> List.to_tuple()
  end

  defp public_channel_value(value) when is_list(value),
    do: Enum.map(value, &public_channel_value/1)

  defp public_channel_value(value) when is_map(value) do
    Map.new(value, fn {key, item} ->
      {public_channel_value(key), public_channel_value(item)}
    end)
  end

  defp public_channel_value(value), do: value

  @doc "Non-blocking send: `alt` with one send op and a default. true if sent."
  def nbsend(c, v) when is_pid(c) do
    case alt([{:send, c, v}, :default]) do
      {:send, _index} -> true
      :default -> false
    end
  end

  @doc "Non-blocking recv: `alt` with one recv op and a default. {:ok, v} | :empty."
  def nbrecv(c) when is_pid(c) do
    case alt([{:recv, c}, :default]) do
      {:recv, _index, value} -> {:ok, value}
      :default -> :empty
    end
  end

  # --- alt driver (runs in the caller's worker process) ----------------------

  defp split_default(ops) do
    ops
    |> Enum.with_index()
    |> Enum.reduce({[], false}, fn
      {:default, _index}, {acc, _default?} -> {acc, true}
      {op, index}, {acc, default?} -> {[{op, index} | acc], default?}
    end)
    |> then(fn {indexed_ops, default?} -> {Enum.reverse(indexed_ops), default?} end)
  end

  # The FileIO owner identity: the process whose death tears down the paired
  # brokers (devsrv freeFileIO). In the kernel port this was the Prog AGENT
  # (Proc.up_agent()), which outlives any single syscall worker and dies
  # exactly when the Prog does. The VM cannot read kernel Proc state, so the
  # OS supplies the identity through the :guest_channel_owner hook (a fun/0 or
  # {module, fun}); without a hook — standalone hyperlang tests — the calling
  # process itself is the owner, which is the same value the kernel fallback
  # (`_ -> self()`) produced for non-Prog callers.
  defp fileio_owner do
    case installed_hook(@owner_hook_key, nil) do
      fun when is_function(fun, 0) -> owner_or_self(fun.())
      {module, fun} when is_atom(module) and is_atom(fun) -> owner_or_self(apply(module, fun, []))
      _ -> self()
    end
  rescue
    _ -> self()
  catch
    _, _ -> self()
  end

  defp owner_or_self(pid) when is_pid(pid), do: pid
  defp owner_or_self(_), do: self()

  # libinterp/alt.c `altrdy`: recv arms are marked first; when a send arm sees
  # this same Prog already waiting to recv on the same Channel, Inferno raises
  # exAlt instead of trying to choose between both directions on one channel.
  defp reject_same_channel_send_recv!(ops) do
    send_brokers =
      ops
      |> Enum.filter(fn
        {:send, broker, _value} when is_pid(broker) -> true
        _ -> false
      end)
      |> Enum.map(fn {:send, broker, _value} -> broker end)
      |> MapSet.new()

    recv_brokers =
      ops
      |> Enum.filter(fn
        {:recv, broker} when is_pid(broker) -> true
        _ -> false
      end)
      |> Enum.map(fn {:recv, broker} -> broker end)
      |> MapSet.new()

    if MapSet.disjoint?(send_brokers, recv_brokers) do
      :ok
    else
      raise @ex_alt
    end
  end

  # Each op is already paired with its ORIGINAL op-list index so the returned
  # index dispatches the right Limbo alt arm even when default appears first.
  defp arm_and_select(indexed, default?, ref, caller, owner) do
    # Try a one-shot non-blocking commit first: collect the ready set (altrdy),
    # then commit one fairly (altcomm). A commit can lose a race to another Prog
    # (TOCTOU between the readiness scan and the commit), so retry over the
    # remaining ready ops; only when none commit do we fall through to default /
    # block.
    case try_ready_set(indexed, ref, owner) do
      {:ok, result} ->
        result

      :none ->
        cond do
          default? -> :default
          # Block: arm every broker with a waiter token, then wait for the first
          # to signal readiness and commit it, cancelling the others (altdone).
          true -> Hyperlang.Scope.blocking(fn -> block_on_alt(indexed, ref, caller, owner) end)
        end
    end
  end

  # altrdy + altcomm with retry: shuffle the ready set (fair pick), try to commit
  # each in turn; the first that wins is the result. Re-scan after a full miss so
  # a slot that opened during the attempt is still seen.
  defp try_ready_set(indexed, ref, owner) do
    ready =
      indexed
      |> Enum.filter(fn {op, _i} ->
        GenServer.call(op_broker(op), {:alt_ready?, op_kind(op)}, :infinity)
      end)
      |> Enum.shuffle()

    commit_first_ready(ready, ref, owner)
  end

  defp commit_first_ready([], _ref, _owner), do: :none

  defp commit_first_ready([{op, index} | rest], ref, owner) do
    case try_commit(op, ref, owner) do
      {:ok, result} -> {:ok, result_with_index(result, index)}
      :retry -> commit_first_ready(rest, ref, owner)
    end
  end

  defp block_on_alt(indexed, ref, caller, owner) do
    # Arm: register `{caller, ref}` as an alt-waiter on each broker. A broker
    # signals `{:alt_ready, ref, broker, index}` to `caller` when its state lets
    # that specific armed op fire. The index matters when one alt arms multiple
    # ops on the same broker; a broker pid alone cannot identify the chosen arm.
    # We then race to commit ONE; the winning broker confirms the commit, losers
    # are disarmed (cqdelp).
    Enum.each(indexed, fn {op, i} ->
      GenServer.call(op_broker(op), {:alt_arm, op_kind(op), ref, caller, i, owner}, :infinity)
    end)

    try do
      await_alt(indexed, ref, owner)
    after
      # altdone: disarm on every broker (idempotent; the committed one already
      # removed itself, the rest drop the waiter).
      Enum.each(indexed, fn {op, _i} ->
        GenServer.call(op_broker(op), {:alt_disarm, ref}, :infinity)
      end)
    end
  end

  defp await_alt(indexed, ref, owner) do
    receive do
      {:alt_ready, ^ref, broker, index} ->
        # Commit the exact arm that woke. A commit can still lose (another party
        # took the slot first), in which case we keep waiting.
        case Enum.find(indexed, fn {op, i} -> i == index and op_broker(op) == broker end) do
          nil ->
            await_alt(indexed, ref, owner)

          {op, ^index} ->
            case try_commit(op, ref, owner) do
              {:ok, result} -> result_with_index(result, index)
              :retry -> await_alt(indexed, ref, owner)
            end
        end
    end
  end

  defp try_commit({:send, broker, value}, ref, _owner) do
    case GenServer.call(broker, {:alt_try_send, ref, value}, :infinity) do
      :ok -> {:ok, :send}
      :retry -> :retry
    end
  end

  defp try_commit({:recv, broker}, ref, owner) do
    case GenServer.call(broker, {:alt_try_recv, ref, owner}, :infinity) do
      {:ok, value} -> {:ok, {:recv, value}}
      :retry -> :retry
    end
  end

  defp result_with_index(:send, index), do: {:send, index}
  defp result_with_index({:recv, value}, index), do: {:recv, index, value}

  defp op_broker({:send, broker, _value}), do: broker
  defp op_broker({:recv, broker}), do: broker

  defp op_kind({:send, _broker, _value}), do: :send
  defp op_kind({:recv, _broker}), do: :recv

  # ===========================================================================
  # Broker — one process per channel. Serialises all ops on that channel, so the
  # rendezvous bookkeeping is atomic (the Dis single-interpreter-thread invariant).
  #
  # State:
  #   size      — buffer slot count (0 = unbuffered)
  #   buf       — :queue of buffered values (length <= size)
  #   sendq     — FIFO of parked senders: {from, value}    (Dis c->send)
  #   recvq     — FIFO of parked receivers: {from, reply_shape} (Dis c->recv)
  #   altq      — alt-waiters armed on this channel: [{kind, ref, caller, index}]
  # ===========================================================================

  @impl true
  def init({:chan, size}), do: {:ok, new_state(size, nil, nil)}

  # FileIO typed-channel form (cnewc/3): carries the Dis value type TAG and the
  # `mover` sentinel, plus the close `hook` (set later by `retype/2`). Only these
  # brokers trap exits, so `terminate/2` runs the close-hook when a linked owner
  # is collected — guest (`newchan/2`) channels keep their prior link behaviour.
  def init({:chan, size, type, mover}) do
    Process.flag(:trap_exit, true)
    {:ok, new_state(size, type, mover)}
  end

  defp new_state(size, type, mover) do
    Process.flag(:message_queue_data, :on_heap)
    Process.flag(:max_heap_size, Hyperlang.Limits.heap_flags(1_000_000))

    %{
      size: size,
      buf: :queue.new(),
      buflen: 0,
      sendq: :queue.new(),
      recvq: :queue.new(),
      altq: [],
      # mons: parked from-tuple or alt key => monitor ref. The broker monitors
      # every BLOCKED caller (parked sender/receiver or armed alt waiter),
      # because a `GenServer.call` does NOT tell the callee when its caller is
      # killed. Without this, a killed Prog leaves ghost sendq/recvq/altq state.
      # On the caller's `:DOWN` the broker drops its parked op (Inferno's
      # kill/alt cqdelp cleanup); monitors are dropped when the op commits or
      # the alt arm is disarmed.
      mons: %{},
      type: type,
      mover: mover,
      hook: nil,
      owner: nil,
      owner_ref: nil,
      peer: nil
    }
  end

  # --- blocking send (isend) -------------------------------------------------
  @impl true
  def handle_call(:channel_broker?, _from, st), do: {:reply, true, st}

  def handle_call(:buffer_slots, _from, st), do: {:reply, st.size, st}

  def handle_call({:send, value}, from, st) do
    cond do
      # A receiver is parked: hand the value over directly and wake it.
      not :queue.is_empty(st.recvq) ->
        {{:value, recv_from}, recvq} = :queue.out(st.recvq)
        st = demon(%{st | recvq: recvq}, elem(recv_from, 0))
        reply_receiver(recv_from, value)
        # The sender completes immediately (rendezvous done).
        {:reply, :ok, st}

      # An alt-recv waiter is armed: wake it; the sender parks until that waiter
      # commits the recv (so exactly one handoff happens, atomically).
      alt_recv_waiter(st) != nil ->
        park_sender(from, value, st)

      # Buffer has room: enqueue and return (cputb).
      st.size > 0 and st.buflen < st.size ->
        {:reply, :ok, %{st | buf: :queue.in(value, st.buf), buflen: st.buflen + 1}}

      # Otherwise block the sender (cqadd c->send).
      true ->
        park_sender(from, value, st)
    end
  end

  # --- blocking recv (irecv) -------------------------------------------------
  def handle_call(:recv, from, st), do: handle_call({:recv, elem(from, 0)}, from, st)

  def handle_call({:recv, owner}, from, st) do
    st = maybe_set_fileio_owner(st, owner)

    cond do
      # A sender is parked: take its value and wake it.
      not :queue.is_empty(st.sendq) ->
        {{:value, {send_from, value}}, sendq} = :queue.out(st.sendq)
        st = demon(%{st | sendq: sendq}, send_from)
        # Buffered channel: the just-freed slot logic — in Dis irecv with a
        # buffer does cgetb then cputb(p->ptr). Mirror: if buffered and non-empty,
        # deliver the head of the buffer and enqueue the woken sender's value.
        if st.buflen > 0 do
          {{:value, head}, buf} = :queue.out(st.buf)
          GenServer.reply(send_from, :ok)
          {:reply, head, %{st | buf: :queue.in(value, buf)}}
        else
          GenServer.reply(send_from, :ok)
          {:reply, value, st}
        end

      # Buffer has a value: take it (cgetb).
      st.buflen > 0 ->
        {{:value, head}, buf} = :queue.out(st.buf)
        {:reply, head, %{st | buf: buf, buflen: st.buflen - 1}}

      # An alt-send waiter is armed: wake it; the receiver parks until it commits.
      alt_send_waiter(st) != nil ->
        park_receiver(from, st)

      # Otherwise block the receiver (cqadd c->recv).
      true ->
        park_receiver(from, st)
    end
  end

  # --- alt readiness (altrdy: can this op fire right now?) -------------------
  def handle_call({:alt_ready?, :send}, _from, st), do: {:reply, can_send_now?(st), st}
  def handle_call({:alt_ready?, :recv}, _from, st), do: {:reply, can_recv_now?(st), st}

  # --- alt arm / disarm (cqadd/cqdelp on the alt set) ------------------------
  def handle_call({:alt_arm, kind, ref, caller, index}, from, st),
    do: handle_call({:alt_arm, kind, ref, caller, index, elem(from, 0)}, from, st)

  def handle_call({:alt_arm, kind, ref, caller, index, owner}, _from, st) do
    st = if kind == :recv, do: maybe_set_fileio_owner(st, owner), else: st
    key = alt_key(ref, caller, index)
    st = %{st | altq: st.altq ++ [{kind, ref, caller, index}], mons: arm_alt_mon(st.mons, key)}
    # If the op can already fire, signal the caller right away (a send/recv
    # arrived between the non-blocking scan and the arm).
    maybe_signal_alt(kind, ref, caller, index, st)
    {:reply, :ok, st}
  end

  def handle_call({:alt_disarm, ref}, _from, st) do
    {drop, keep} = Enum.split_with(st.altq, fn {_k, r, _c, _i} -> r == ref end)
    keys = Enum.map(drop, fn {_k, r, caller, index} -> alt_key(r, caller, index) end)
    {:reply, :ok, %{st | altq: keep, mons: drop_mons(st.mons, keys)}}
  end

  # --- alt blocking commit (the armed waiter races to fire) ------------------
  def handle_call({:alt_try_send, ref, value}, from, st) do
    cond do
      not :queue.is_empty(st.recvq) ->
        {:reply, :ok, do_send_now(value, st)}

      alt_recv_waiter(st, ref) != nil ->
        park_sender(from, value, st, ref)

      st.size > 0 and st.buflen < st.size ->
        {:reply, :ok, do_send_now(value, st)}

      true ->
        {:reply, :retry, st}
    end
  end

  def handle_call({:alt_try_recv, ref}, from, st),
    do: handle_call({:alt_try_recv, ref, elem(from, 0)}, from, st)

  def handle_call({:alt_try_recv, ref, owner}, from, st) do
    st = maybe_set_fileio_owner(st, owner)

    cond do
      not :queue.is_empty(st.sendq) or st.buflen > 0 ->
        {value, st} = do_recv_now(st)
        {:reply, {:ok, value}, st}

      alt_send_waiter(st, ref) != nil ->
        park_receiver(from, st, ref, :alt)

      true ->
        {:reply, :retry, st}
    end
  end

  # --- retype: install the FileIO close-hook (srvretype) ---------------------
  # Installing a close-hook makes this broker TRAP EXITS, so `terminate/2` runs
  # (and fires the hook = freerdchan/freewrchan) both when a linked owner dies AND
  # when the kernel shuts the broker down via `close_scope` or asynchronous retirement. A
  # guest `newchan/2` broker does NOT trap (channel.ex `init({:chan, size})`), so
  # a `/srv` file2chan channel, created via newchan and then retyped, must opt in
  # here — otherwise its srvfree cleanup (freerdchan/freewrchan) is skipped.
  def handle_call({:retype, hook}, _from, st) do
    Process.flag(:trap_exit, true)
    {:reply, :ok, %{st | hook: hook}}
  end

  def handle_call({:fileio_peer, peer}, _from, st) when is_pid(peer) do
    {:reply, :ok, %{st | peer: peer}}
  end

  # --- csendalt: non-blocking buffered send (srvunblock sentinel) ------------
  # Hand the value to a parked receiver / armed alt-recv waiter if ready, else
  # buffer it (growing past `size`, the Dis `heaparray(t, len)` grow). Returns 1.
  def handle_call({:csendalt, value}, _from, st) do
    cond do
      not :queue.is_empty(st.recvq) ->
        {{:value, recv_from}, recvq} = :queue.out(st.recvq)
        st = demon(%{st | recvq: recvq}, elem(recv_from, 0))
        reply_receiver(recv_from, value)
        {:reply, 1, st}

      alt_recv_waiter(st) != nil ->
        # An alt-recv waiter is armed: buffer the value and signal it so it can
        # come take it (csendalt never blocks the sender).
        st = %{st | buf: :queue.in(value, st.buf), buflen: st.buflen + 1}
        signal_alt_waiters(:recv, st)
        {:reply, 1, st}

      true ->
        # Buffer unconditionally (grow past `size` if needed — Dis buffer grow).
        {:reply, 1, %{st | buf: :queue.in(value, st.buf), buflen: st.buflen + 1}}
    end
  end

  # --- trap_exit: a linked owner died; let terminate/2 fire the close-hook ----
  @impl true
  def handle_info({:EXIT, _pid, _reason}, st) do
    {:stop, :normal, st}
  end

  # --- a BLOCKED caller died (killed Prog / alt cancel): drop its queued ops ---
  # Inferno's kill and alt cleanup remove a Prog's blocked channel operations
  # (cqdelp) so no peer rendezvous with a value whose sender is gone. We monitor
  # every parked caller; on its DOWN we purge its parked send/recv + any alt arm.
  def handle_info({:DOWN, mref, :process, pid, _reason}, %{owner_ref: mref, owner: pid} = st) do
    if is_pid(st.peer), do: Process.exit(st.peer, :normal)
    {:stop, :normal, %{st | owner: nil, owner_ref: nil}}
  end

  def handle_info({:DOWN, _mref, :process, pid, _reason}, st) do
    {:noreply, purge_caller(st, pid)}
  end

  def handle_info(_msg, st), do: {:noreply, st}

  # Drop every parked op + alt arm belonging to the dead caller `pid`, and the
  # monitors we held for them.
  defp purge_caller(st, pid) do
    {sendq, sdrop} = queue_drop(st.sendq, fn {from, _v} -> elem(from, 0) == pid end)
    {recvq, rdrop} = queue_drop(st.recvq, fn {from, _s} -> elem(from, 0) == pid end)
    froms = Enum.map(sdrop ++ rdrop, fn entry -> elem(entry, 0) end)
    {adrop, altq} = Enum.split_with(st.altq, fn {_k, _r, caller, _i} -> caller == pid end)
    alt_keys = Enum.map(adrop, fn {_k, ref, caller, index} -> alt_key(ref, caller, index) end)
    mons = drop_mons(st.mons, froms ++ alt_keys)
    %{st | sendq: sendq, recvq: recvq, altq: altq, mons: mons}
  end

  # Demonitor + remove the monitors for the given parked `from`s (already dead;
  # demonitor/flush is the no-op safe form).
  defp drop_mons(mons, froms) do
    Enum.reduce(froms, mons, fn from, acc ->
      case Map.pop(acc, from) do
        {nil, _} ->
          acc

        {mref, acc1} ->
          Process.demonitor(mref, [:flush])
          acc1
      end
    end)
  end

  # Partition a :queue by a drop predicate: {kept_queue, dropped_list}.
  defp queue_drop(q, drop?) do
    {drop, keep} = Enum.split_with(:queue.to_list(q), drop?)
    {:queue.from_list(keep), drop}
  end

  @impl true
  def handle_cast(:retire, st), do: {:stop, :normal, st}

  # --- terminate: fire the FileIO close-hook (Trdchan/Twrchan free callback) --
  # When the broker is collected the Dis heap type's `free` callback runs
  # (freerdchan/freewrchan, marking the SrvFile read/write side closed). On the
  # BEAM that is the broker process exiting; invoke the installed close-hook
  # `module.fun(aux, swept)` (swept = 0; the Dis sweep flag is DROPPED GC).
  @impl true
  def terminate(_reason, %{hook: {module, fun, aux}}) do
    try do
      apply(module, fun, [aux, 0])
    catch
      _, _ -> :ok
    end

    :ok
  end

  def terminate(_reason, _st), do: :ok

  # --- broker helpers --------------------------------------------------------

  defp maybe_set_fileio_owner(%{hook: nil} = st, _pid), do: st
  defp maybe_set_fileio_owner(%{owner: owner} = st, _pid) when is_pid(owner), do: st

  defp maybe_set_fileio_owner(st, pid) when is_pid(pid) do
    %{st | owner: pid, owner_ref: Process.monitor(pid)}
  end

  defp maybe_set_fileio_owner(st, _pid), do: st

  # Park a blocking sender; if an alt-recv waiter is armed, wake it so it can
  # come take the value.
  defp park_sender(from, value, st, exclude_ref \\ nil) do
    st = %{st | sendq: :queue.in({from, value}, st.sendq), mons: arm_mon(st.mons, from)}
    signal_alt_waiters(:recv, st, exclude_ref)
    {:noreply, st}
  end

  defp park_receiver(from, st, exclude_ref \\ nil, reply_shape \\ :value) do
    st = %{st | recvq: :queue.in({from, reply_shape}, st.recvq), mons: arm_mon(st.mons, from)}
    signal_alt_waiters(:send, st, exclude_ref)
    {:noreply, st}
  end

  # Monitor the parked caller (the GenServer.call `from` is `{pid, tag}`).
  defp arm_mon(mons, from), do: Map.put(mons, from, Process.monitor(elem(from, 0)))

  defp arm_alt_mon(mons, {:alt, _ref, caller, _index} = key),
    do: Map.put(mons, key, Process.monitor(caller))

  defp alt_key(ref, caller, index), do: {:alt, ref, caller, index}

  # The parked op for `from` committed (it was woken / rendezvoused): drop the
  # monitor so it doesn't linger for the caller's whole lifetime.
  defp demon(st, from) do
    case Map.pop(st.mons, from) do
      {nil, _} ->
        st

      {mref, mons} ->
        Process.demonitor(mref, [:flush])
        %{st | mons: mons}
    end
  end

  # CANPUT / a parked receiver / a recv-alt-waiter ⇒ a send can fire now.
  defp can_send_now?(st, ref \\ nil) do
    not :queue.is_empty(st.recvq) or alt_recv_waiter(st, ref) != nil or
      (st.size > 0 and st.buflen < st.size)
  end

  # CANGET / a parked sender / buffered value ⇒ a recv can fire now.
  defp can_recv_now?(st, ref \\ nil) do
    not :queue.is_empty(st.sendq) or alt_send_waiter(st, ref) != nil or
      st.buflen > 0
  end

  # Commit a send immediately (used by alt). Mirror of the {:send,...} fast path
  # WITHOUT the parking arm (the caller only calls this when can_send_now?).
  defp do_send_now(value, st) do
    cond do
      not :queue.is_empty(st.recvq) ->
        {{:value, recv_from}, recvq} = :queue.out(st.recvq)
        st = demon(%{st | recvq: recvq}, elem(recv_from, 0))
        reply_receiver(recv_from, value)
        st

      st.size > 0 and st.buflen < st.size ->
        %{st | buf: :queue.in(value, st.buf), buflen: st.buflen + 1}
    end
  end

  # Commit a recv immediately (used by alt). Returns {value, state}.
  defp do_recv_now(st) do
    cond do
      not :queue.is_empty(st.sendq) ->
        {{:value, {send_from, value}}, sendq} = :queue.out(st.sendq)
        st = demon(%{st | sendq: sendq}, send_from)

        if st.buflen > 0 do
          {{:value, head}, buf} = :queue.out(st.buf)
          GenServer.reply(send_from, :ok)
          {head, %{st | buf: :queue.in(value, buf)}}
        else
          GenServer.reply(send_from, :ok)
          {value, st}
        end

      st.buflen > 0 ->
        {{:value, head}, buf} = :queue.out(st.buf)
        {head, %{st | buf: buf, buflen: st.buflen - 1}}
    end
  end

  defp alt_recv_waiter(st, ref \\ nil),
    do: Enum.find(st.altq, fn {k, r, _c, _i} -> k == :recv and r != ref end)

  defp alt_send_waiter(st, ref \\ nil),
    do: Enum.find(st.altq, fn {k, r, _c, _i} -> k == :send and r != ref end)

  defp reply_receiver({from, :value}, value), do: GenServer.reply(from, value)
  defp reply_receiver({from, :alt}, value), do: GenServer.reply(from, {:ok, value})

  # Signal armed alt-waiters of `kind` that their op may now be ready.
  defp signal_alt_waiters(kind, st, exclude_ref \\ nil) do
    Enum.each(st.altq, fn {k, ref, caller, index} ->
      if k == kind and ref != exclude_ref, do: send(caller, {:alt_ready, ref, self(), index})
    end)
  end

  defp maybe_signal_alt(:send, ref, caller, index, st) do
    if can_send_now?(st, ref), do: send(caller, {:alt_ready, ref, self(), index})
  end

  defp maybe_signal_alt(:recv, ref, caller, index, st) do
    if can_recv_now?(st, ref), do: send(caller, {:alt_ready, ref, self(), index})
  end

  defp start_broker(init_arg) do
    :ok = ensure_started()

    case BrokerSupervisor.start_child(init_arg) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  defp stop_broker(broker) when is_pid(broker) do
    if Process.alive?(broker) do
      GenServer.stop(broker, :normal, 5_000)
    end

    :ok
  catch
    :exit, _ -> :ok
  end
end
