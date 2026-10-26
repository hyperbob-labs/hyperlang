defmodule Hyperlang.Scope do
  @moduledoc """
  Host-owned resource scopes shared by runs, timers, channels and compilation.

  Select a scope with `spec.policy.scope`, or wrap compilation in `with_scope/2`.
  The default scope belongs to the host caller. `configure/2` makes the calling
  host its lifetime owner; its exit or `close/1` reclaims the scope's resources.

  Policy keys are `max_concurrent_runs`, `max_concurrent_compiles`, `max_queue`,
  `wait_ms`, `priority` (`:background` or `:latency`), `heap_words` (aggregate),
  `compile_heap_words` (one compile worker's heap, OTP compilation included),
  `rate` and `compile_rate` (`%{quota: reductions, period_ms: ms}`), `churn`
  (`%{heap_words: growth_words, gcs: minor_collections, period_ms: ms}`),
  `sample_ms`, `max_violations`, `max_channels`, `max_buffer_slots`, and
  `max_code_pins` (distinct code slots the scope's live actors may pin).
  Same-scope nested calls borrow an ancestor's permit of the same kind; their
  workers remain members and share heap, reduction, churn and wall accounting.
  A nested compile still needs a compile permit when its ancestor only holds a
  run permit. Cross-scope nesting takes an independent permit. Nested requests
  that cannot acquire immediately return `busy/admission_cycle`, avoiding
  circular waits across per-scope run/compile admission.

  Per-scope admission counts live runs, including blocked runs. This is an
  owner-selected lifetime policy, independent of node-wide runnable capacity.
  Node-wide runtime permits bound guest execution. Channel send/recv/alt,
  timer sleep, binding/syscall doors, nested calls and child/reply/monitor waits
  release capacity before waiting and reacquire before guest execution resumes.
  Native receives retain their existing permit for a probe bounded to one
  millisecond (zero for after-zero), then release for any remaining wait.
  Workers stay attached to all resource accounting while blocked.

  Uncontended handoffs reserve an atomic ETS slot without a server call. The
  runtime keeps one monitored lifetime record across waits; slot insertion also
  records ownership, so death before the local commit cannot leak capacity.
  A spawned run worker opens that lifetime with its membership and retires it,
  with the run's live lease, when it detaches. An in-caller run is admitted,
  attached and given a lifetime by one call. Detaching is a request the run
  does not wait for; the run's later requests are ordered behind it. An
  uncontended spawned run makes one admission call in its caller and one
  Scope call in its worker; an uncontended in-caller run makes one call.
  A queue gate prevents these reservations from overtaking queued work. Closed
  lifetime records remain until the caller unregisters or dies, covering an
  interrupted insertion racing closure. The runtime configuration is read at
  startup and when the runtime becomes idle; changes do not resize live grants.

  Runnable admission and reacquisition are FIFO within each priority class,
  with one node-wide slot reserved for latency scopes. Their wait is unbounded
  by `wait_ms` or `max_queue`; the run's wall deadline still applies. Closing or
  terminating the scope returns a typed busy fault. Resumption is pinned to the
  original scope lifetime, so closing and reusing a name cannot revive old work.
  Suspended workers surrender capacity and reacquire before being resumed;
  blocking cannot reset a scope's rate/churn counters or bypass suspension.
  `:runtime_concurrency` configures total capacity (minimum two); the default is
  `max(256, 32 * schedulers_online)`. Latency-class scope calls use OTP priority
  messages in Scope and Limits to avoid queued background bookkeeping. Their
  callers wait for the reply at `high` process priority and drop back on
  wake-up; a latency-class worker also starts at `high` and takes `normal`
  before any other work. Scope and Limits wake at `high` only while idle and
  handle every message at `normal`, so a backlog or a long handler competes
  at `normal` and runs at most one time slice at `high`. Guest code never runs
  above its class. A
  monitored control sampler per scope inspects processes outside the shared
  admission server, so a busy broker or worker cannot stall latency requests.
  Stale samples cannot replace newer observations or cross member lifetimes.
  Channel and buffer quotas are serialized in a controller for each scope,
  including start-channel reservations and bulk alias admission. Each controller
  owns its scope's counters row in a shared table and replaces only a row it
  still owns, so a closed or reused name cannot be revived by a late
  publication. A quiet controller hibernates. Allocation and free never
  enter the shared Scope mailbox. Channel-only sampling stays local; configured
  rate/churn policies and heap violations report to Scope for enforcement.
  Worker sampling still combines worker and channel heaps in one scope budget.
  Cumulative CPU/churn totals survive free, so short-lived brokers retain their
  charges. Registry bills measured hot-path reductions to the scope controller.
  Throttled allocation waits outside Registry and holds no runnable permit.

  Channel brokers, control samplers and host allocation/free bookkeeping use
  their allocating scope's priority class. Broker startup is partitioned by
  scope and priority; retirement never blocks the shared supervisor. A protected
  host that cannot be preempted retains its runnable permit after
  closure/termination until it returns, blocks or exits.
  Compile heaps are bounded separately by `compile_heap_words` and do not
  consume the run aggregate heap or churn budget. Compile reductions still
  consume `compile_rate`, and node-wide compile admission remains mandatory.

  Scope enforcement never kills or suspends the owner or an in-caller host.
  Those calls report `busy/scope_terminated` or `busy/scope_closed` on return;
  arbitrary trusted host callbacks must cooperate to return control. Explicit
  in-caller wall/reduction expiry likewise returns a typed fault on return,
  rather than terminating the trusted host process. Engine-owned OTP actor
  callbacks remain preemptible even though they run in their actor's process.
  Offending scopes are suspended until refill and terminated after repeated
  violations. Measurement is sampled; OS/node isolation is still necessary
  for hostile tenants and native work that does not yield to the scheduler.
  """
  use GenServer
  alias Hyperlang.Scope.{Runtime, Channels}

  @context {__MODULE__, :context}
  @runnable {__MODULE__, :runnable}
  @lifetime {__MODULE__, :lifetime}
  @offered_lease {__MODULE__, :offered_lease}
  @policies :hyperlang_scope_policies
  @defaults %{
    max_concurrent_runs: 64,
    max_concurrent_compiles: 1,
    max_queue: 128,
    wait_ms: 5_000,
    priority: :background,
    heap_words: 16_000_000,
    compile_heap_words: 64_000_000,
    rate: nil,
    compile_rate: nil,
    churn: nil,
    sample_ms: 2,
    max_violations: 3,
    max_channels: 1024,
    max_buffer_slots: 65_536,
    max_code_pins: 64
  }

  @doc false
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Configure a scope owned by the calling host. Invalid policies fail closed."
  def configure(scope, policy) when is_map(policy) do
    with {:ok, policy} <- normalize_policy(policy) do
      call({:configure, scope, self(), policy})
    end
  end

  @doc "Run host work under a scope, restoring any enclosing scope afterwards."
  def with_scope(scope, fun) when is_function(fun, 0) do
    previous = Process.get(@context)
    Process.put(@context, scope)

    try do
      fun.()
    after
      if is_nil(previous), do: Process.delete(@context), else: Process.put(@context, previous)
    end
  end

  @doc "Return the current host scope, defaulting to the calling host's lifetime."
  def current, do: Process.get(@context, {__MODULE__, self()})

  @doc "Close a scope, killing its workers and cancelling timers and channels."
  def close(scope) do
    :ok = call({:close, scope})
    cleanup_external(scope)
  end

  @doc "Return host-only admission and throttle counters, without guest or binding data."
  def stats(scope), do: call({:stats, scope})

  @doc false
  def policy(scope) do
    case :ets.lookup(@policies, scope) do
      [{^scope, policy}] -> policy
      [] -> @defaults
    end
  end

  @doc false
  def priority(scope), do: if(policy(scope).priority == :latency, do: :normal, else: :low)

  @doc false
  def acquire(scope, kind \\ :run),
    do: call({:acquire, scope, kind, not is_nil(Process.get(@runnable))}, :infinity)

  # A live-run lease is independent of the permit held by the process that
  # actually executes guest code. Host work and blocked waits carry no permit.
  @doc false
  def running(scope, fun) do
    case Process.get(@runnable) do
      {^scope, _, token} when not is_nil(token) ->
        if Runtime.valid?(token), do: fun.(), else: run_with_runtime(scope, fun)

      _ ->
        run_with_runtime(scope, fun)
    end
  end

  defp run_with_runtime(scope, fun) do
    case Process.get(@lifetime) do
      {^scope, generation, token} -> run_with_lifetime(scope, generation, token, fun)
      _ -> run_with_new_runtime(scope, fun)
    end
  end

  # A spawned run worker receives its monitored runtime lifetime with its
  # membership in `attach_worker/4`. Entering guest code then takes the local
  # slot fast path; leaving releases the slot locally. `detach_worker/2` retires
  # the lifetime with the membership, so an uncontended run makes no runtime
  # calls. Nested same-scope entries in that worker reuse the same lifetime.
  defp run_with_lifetime(scope, generation, token, fun) do
    blocking(fn ->
      previous = Process.get(@runnable)
      resume_runtime_token(scope, generation, token)
      Process.put(@runnable, {scope, generation, token})

      try do
        fun.()
      after
        try do
          Runtime.block(token)
        after
          if previous, do: Process.put(@runnable, previous), else: Process.delete(@runnable)
        end
      end
    end)
  end

  defp run_with_new_runtime(scope, fun) do
    blocking(fn ->
      previous = Process.get(@runnable)
      {token, generation} = enter_runtime(scope, :new)
      Process.put(@runnable, {scope, generation, token})

      try do
        fun.()
      after
        # Also unregister when resumption raised while the process
        # dictionary deliberately contained the blocked marker.
        try do
          leave_runtime(token)
        after
          if previous, do: Process.put(@runnable, previous), else: Process.delete(@runnable)
        end
      end
    end)
  end

  @doc false
  def blocking(fun) do
    case Process.get(@runnable) do
      {scope, generation, token} when not is_nil(token) ->
        Process.put(@runnable, {scope, generation, nil})
        Runtime.block(token)

        try do
          fun.()
        after
          resume_runtime_token(scope, generation, token)
          Process.put(@runnable, {scope, generation, token})
        end

      _ ->
        fun.()
    end
  end

  defp enter_runtime(scope, generation) do
    case call({:runnable, scope, generation}, :infinity) do
      {:ok, token, generation} -> {token, generation}
      {:error, error} -> throw({:hyperlang_scope_busy, error})
    end
  end

  defp resume_runtime_token(scope, generation, token) do
    case Runtime.try_resume(token) do
      :ok ->
        :ok

      :slow ->
        Runtime.end_wait(elem(token, 2))

        case call({:resume_token, scope, generation, elem(token, 0)}, :infinity) do
          :ok -> :ok
          {:error, error} -> throw({:hyperlang_scope_busy, error})
        end
    end
  end

  defp leave_runtime({token, _, _, _, _, _, _}), do: call({:blocked, token}, :infinity)

  @doc false
  def runtime_snapshot, do: call(:runtime_snapshot)

  @doc false
  def pause_runtime(pid) do
    if Process.whereis(__MODULE__), do: call({:pause_runtime, pid}, :infinity), else: :ok
  end

  @doc false
  def resume_runtime(pid) do
    if Process.whereis(__MODULE__), do: call({:resume_runtime, pid}, :infinity), else: :ready
  end

  @doc false
  def ensure(scope, owner), do: call({:ensure, scope, owner})

  @doc false
  def release(lease), do: call({:release, lease})

  # A run's live lease is offered to the worker that executes it. The worker
  # releases it together with its membership in `detach/2`; the run releases
  # it itself only when no worker took it, or when the worker did not detach.
  @doc false
  def offer_lease(scope, lease), do: Process.put(@offered_lease, {scope, lease})

  @doc false
  def take_lease(scope) do
    case Process.get(@offered_lease) do
      {^scope, lease} ->
        Process.put(@offered_lease, :taken)
        lease

      _ ->
        nil
    end
  end

  @doc false
  def release_offered(lease, previous) do
    try do
      case Process.get(@offered_lease) do
        {_scope, ^lease} -> release(lease)
        _ -> :ok
      end
    after
      if previous,
        do: Process.put(@offered_lease, previous),
        else: Process.delete(@offered_lease)
    end
  end

  @doc false
  def attach(scope, pid, kind \\ :run, heap_reservation \\ 0, caller \\ nil, fault \\ nil),
    do:
      call({:attach, scope, pid, kind, heap_reservation, caller, fault, read_member(pid), false})

  # Attach the calling run worker and open its runtime lifetime in one call.
  @doc false
  def attach_worker(scope, heap_reservation, caller, fault) do
    request =
      {:attach, scope, self(), :run, heap_reservation, caller, fault, read_member(self()), true}

    case call(request) do
      {:ok, token, generation} ->
        Process.put(@lifetime, {scope, generation, token})
        :ok

      error ->
        error
    end
  end

  # Admit and attach the calling in-caller run. A scope that admits at once
  # also attaches it in the same call. When the process holds no runtime
  # lifetime yet, the attach opens one, so entering and leaving guest code
  # takes the local slot fast path instead of a server call each way.
  # Returns `{:ok, lease, opened?}`; `detach_run/3` retires a lifetime it
  # opened and releases the lease.
  @doc false
  def acquire_run(scope, kind, heap_reservation, fault) do
    lifetime? = is_nil(Process.get(@lifetime))
    attach = {self(), kind, heap_reservation, nil, fault, read_member(self()), lifetime?}
    nested_hint? = not is_nil(Process.get(@runnable))

    case call({:acquire, scope, :run, nested_hint?, attach}, :infinity) do
      {:ok, lease, attached} ->
        {:ok, lease, put_lifetime(scope, attached)}

      {:ok, lease} ->
        request =
          {:attach, scope, self(), kind, heap_reservation, nil, fault, read_member(self()),
           lifetime?}

        case call(request) do
          {:error, _} = error ->
            release(lease)
            error

          attached ->
            {:ok, lease, put_lifetime(scope, attached)}
        end

      error ->
        error
    end
  end

  defp put_lifetime(_scope, :ok), do: false

  defp put_lifetime(scope, {:ok, token, generation}) do
    Process.put(@lifetime, {scope, generation, token})
    true
  end

  @doc false
  def detach(scope, pid), do: call({:detach, scope, pid, read_member(pid), nil, nil})

  # Detach the calling in-caller run: retire the lifetime `acquire_run/4`
  # opened, if any, and release its `lease`, in one request. Nothing waits
  # for the reply: this process's later requests to the server are ordered
  # behind it, so its next admission already sees the lease released.
  @doc false
  def detach_run(scope, opened?, lease) do
    token =
      if opened? do
        {^scope, _generation, {token, _, _, _, _, _, _}} = Process.delete(@lifetime)
        token
      end

    priority_cast(__MODULE__, {:detach, scope, self(), read_member(self()), token, lease})
  end

  # Detach the calling run worker: retire the runtime lifetime opened by
  # `attach_worker/4` and release the run's offered `lease` in one request.
  # Nothing waits for the reply: the worker replies to its caller after
  # sending it, so the caller's later requests are ordered behind it.
  @doc false
  def detach_worker(scope, lease) do
    {^scope, _generation, {token, _, _, _, _, _, _}} = Process.delete(@lifetime)
    priority_cast(__MODULE__, {:detach, scope, self(), read_member(self()), token, lease})
  end

  @doc false
  def charge_channel(scope, broker, slots, owner),
    do: charge_channels(scope, [{broker, slots}], owner)

  @doc false
  def charge_channels(scope, channels, owner),
    do: Channels.request(scope, owner, {:channels, channels})

  @doc false
  def reserve_startchan(scope, handle, owner),
    do: Channels.request(scope, owner, {:startchan, handle})

  @doc false
  def release_startchan(scope, handle), do: Channels.release_startchan(scope, handle)

  @doc false
  def uncharge_channel(scope, broker), do: Channels.uncharge(scope, broker)

  # OTP priority aliases keep latency-class admission/accounting off the
  # background channel-bookkeeping mailbox lane. Each synchronous caller has
  # at most one request in flight; background work continues in its FIFO lane.
  defp call(request, timeout \\ 5_000), do: priority_call(__MODULE__, request, timeout)

  @doc false
  def install_priority_address(server) do
    :persistent_term.put({server, :priority_address}, {self(), :erlang.alias([:priority])})
  end

  @doc false
  def priority_call(server, request, timeout \\ 5_000) do
    if latency_request?(server, request) do
      {pid, address} = :persistent_term.get({server, :priority_address})
      ref = :erlang.monitor(:process, pid, [{:alias, :demonitor}])
      :erlang.send(address, {:"$gen_call", {self(), [:alias | ref]}, request}, [:priority])

      # Wait at high priority so the reply resumes the caller without queueing
      # behind background processes. The boost covers only this receive.
      previous = Process.flag(:priority, :high)

      try do
        receive do
          {[:alias | ^ref], reply} ->
            Process.demonitor(ref, [:flush])
            reply

          {:DOWN, ^ref, :process, ^pid, reason} ->
            exit(reason)
        after
          timeout ->
            Process.demonitor(ref, [:flush])
            exit({:timeout, {__MODULE__, request}})
        end
      after
        Process.flag(:priority, previous)
      end
    else
      GenServer.call(server, request, timeout)
    end
  end

  # A request that needs no reply takes the same lane as `priority_call/3`
  # would, so it stays ordered behind the caller's earlier requests.
  @doc false
  def priority_cast(server, request) do
    if latency_request?(server, request) do
      {_pid, address} = :persistent_term.get({server, :priority_address})
      :erlang.send(address, {:"$gen_cast", request}, [:priority])
      :ok
    else
      GenServer.cast(server, request)
    end
  end

  defp latency_request?(server, request) do
    id = if is_tuple(request) and tuple_size(request) > 1, do: elem(request, 1), else: nil

    (is_tuple(request) and elem(request, 0) in [:pause_runtime, :resume_runtime]) or
      (:ets.whereis(@policies) != :undefined and
         ((server == __MODULE__ and policy(id).priority == :latency) or
            policy(current()).priority == :latency))
  end

  @impl true
  def init(_) do
    :ets.new(@policies, [:named_table, :protected, :set, read_concurrency: true])
    install_priority_address(__MODULE__)
    Process.flag(:priority, :high)
    Runtime.init()
    Channels.init_table()

    {:ok,
     %{
       scopes: %{},
       leases: %{},
       lease_owners: %{},
       monitors: %{},
       compile_count: 0,
       runtime_gate: Runtime.new(runtime_limit()),
       runtime_permits: %{},
       runtime_scopes: %{},
       runtime_queue: [],
       runtime_parked: %{},
       run_count: 0,
       background_count: 0,
       queue: []
     }}
  end

  @impl true
  def handle_call({:ensure, id, owner}, _from, state),
    do: {:reply, :ok, ensure_scope(state, id, owner)}

  def handle_call({:configure, id, owner, policy}, _from, state) do
    state = ensure_scope(state, id, owner)
    scope = state.scopes[id]
    # Settle lazy channel totals under the previous policy before changing it.
    scope = sample(scope)
    # A scope's lifetime is explicit: configuration does not silently transfer it.
    if scope.owner != owner do
      {:reply, {:error, :scope_owner}, state}
    else
      :ets.insert(@policies, {id, policy})
      send(scope.sampler, {:policy, policy})
      state = put_in(state, [:scopes, id], %{scope | policy: policy})
      {:reply, :ok, drain(state)}
    end
  end

  def handle_call({:acquire, id, kind, nested_hint?}, from, state),
    do: handle_call({:acquire, id, kind, nested_hint?, nil}, from, state)

  # `attach` (or nil) attaches the admitted process in the same call when the
  # scope admits at once; a queued request is granted without it.
  def handle_call({:acquire, id, kind, nested_hint?, attach}, {owner, _} = from, state) do
    state = ensure_scope(state, id, owner)
    scope = state.scopes[id]

    cond do
      scope.killed? ->
        {:reply, busy(:scope_terminated), state}

      # Re-entrant admission: a run or compile started by a process that is
      # already running inside this scope (it holds a lease or is an attached
      # member) is charged to that parent. Taking a fresh permit would make a
      # nested run wait behind the permit its own parent holds.
      nested?(state, id, kind, owner, nested_hint?) ->
        {lease, state} = admit_nested(state, id, kind, owner)
        admitted(state, id, lease, attach)

      available?(state, scope, kind) ->
        {lease, state} = admit(state, id, kind, owner)
        admitted(state, id, lease, attach)

      active_caller?(state, owner) ->
        {:reply, busy(:admission_cycle), state}

      length(Enum.filter(state.queue, &(&1.scope == id))) >= scope.policy.max_queue ->
        {:reply, busy(:queue_full), state}

      true ->
        ref = make_ref()
        monitor = Process.monitor(owner)
        timer = Process.send_after(self(), {:wait_expired, ref}, scope.policy.wait_ms)

        request = %{
          ref: ref,
          scope: id,
          kind: kind,
          owner: owner,
          from: from,
          monitor: monitor,
          timer: timer
        }

        {:noreply, %{state | queue: state.queue ++ [request]}}
    end
  end

  def handle_call({:runnable, id, generation}, {owner, _} = from, state) do
    scope = state.scopes[id]

    cond do
      is_nil(scope) or (generation != :new and generation != scope.generation) ->
        {:reply, busy(:scope_closed), state}

      scope.killed? ->
        {:reply, busy(:scope_terminated), state}

      true ->
        {token, state} = new_runtime_entry(state, id, owner, false)
        request = %{token: token, from: from}
        {:noreply, drain(%{state | runtime_queue: state.runtime_queue ++ [request]})}
    end
  end

  def handle_call({:resume_token, id, generation, token}, from, state) do
    scope = state.scopes[id]
    entry = state.runtime_permits[token]

    cond do
      is_nil(scope) or is_nil(entry) or scope.generation != generation ->
        {:reply, busy(:scope_closed), state}

      scope.killed? ->
        {:reply, busy(:scope_terminated), state}

      Runtime.active?(entry.cell) ->
        {:reply, :ok, state}

      true ->
        {old, state} = take_runtime_requests(state, [token])

        request =
          old |> List.first(%{token: token}) |> Map.put(:from, from) |> Map.put(:resume?, true)

        :atomics.put(state.runtime_gate, 1, 1)
        {:noreply, drain(%{state | runtime_queue: state.runtime_queue ++ [request]})}
    end
  end

  def handle_call({:pause_runtime, pid}, _from, state) do
    state =
      Enum.reduce(state.runtime_permits, state, fn {token, entry}, acc ->
        if entry.owner == pid do
          Runtime.pause(entry.cell)
          Runtime.suspend(acc.runtime_gate, entry.cell, token, self())

          acc =
            put_in(acc, [:runtime_permits, token], %{
              entry
              | active?: false,
                paused?: true,
                pause_depth: entry.pause_depth + 1
            })

          if Runtime.waiting?(entry.cell) or
               Enum.any?(runtime_requests(acc), &(&1.token == token)),
             do: acc,
             else: %{acc | runtime_queue: acc.runtime_queue ++ [%{token: token, from: nil}]}
        else
          acc
        end
      end)

    {:reply, :ok, drain(state)}
  end

  def handle_call({:resume_runtime, pid}, {suspender, _}, state) do
    {state, ready} =
      Enum.reduce(state.runtime_permits, {state, []}, fn {token, entry}, {acc, ready} ->
        if entry.owner == pid and entry.paused? do
          depth = entry.pause_depth - 1
          if depth == 0, do: Runtime.unpause(entry.cell)

          acc =
            put_in(acc, [:runtime_permits, token], %{
              entry
              | pause_depth: depth,
                paused?: depth > 0
            })

          {acc,
           if(depth == 0 and not Runtime.waiting?(entry.cell), do: [token | ready], else: ready)}
        else
          {acc, ready}
        end
      end)

    {requests, state} = take_runtime_requests(state, ready)
    requests = Enum.map(requests, &Map.put(&1, :notify, {suspender, pid}))
    state = %{state | runtime_queue: state.runtime_queue ++ requests}
    {:reply, if(requests == [], do: :ready, else: :queued), drain(state)}
  end

  def handle_call(:runtime_snapshot, _from, state) do
    {total, background} = Runtime.counts(state.runtime_gate)

    permits =
      Map.new(state.runtime_permits, fn {token, entry} ->
        {token, %{entry | active?: Runtime.active?(entry.cell)}}
      end)

    snapshot = %{state | runtime_permits: permits, run_count: total, background_count: background}
    {:reply, snapshot, snapshot}
  end

  def handle_call({:blocked, token}, _from, state),
    do: {:reply, :ok, state |> drop_runtime(token) |> drain()}

  def handle_call({:release, lease}, _from, state),
    do: {:reply, :ok, state |> release_lease(lease) |> drain()}

  def handle_call(
        {:attach, id, pid, kind, heap_reservation, caller, fault, reading, lifetime?},
        _from,
        state
      ) do
    {reply, state} =
      attach_member(state, id, {pid, kind, heap_reservation, caller, fault, reading, lifetime?})

    {:reply, reply, state}
  end

  def handle_call({:detach, id, pid, reading, token, lease}, _from, state) do
    state = if token, do: drop_runtime(state, token), else: state
    state = if lease, do: release_lease(state, lease), else: state
    state = if token || lease, do: drain(state), else: state

    case get_in(state, [:scopes, id, :members, pid]) do
      nil ->
        {:reply, :ok, state}

      %{depth: depth} when depth > 1 ->
        state =
          update_scope(state, id, fn scope ->
            scope
            |> sample(%{pid => {:current, reading}})
            |> update_in([:members, pid, :depth], &(&1 - 1))
            |> update_in([:members, pid, :faults], &tl/1)
          end)

        {:reply, :ok, state}

      member ->
        caller_monitor = Map.get(member, :caller_monitor)
        if caller_monitor, do: Process.demonitor(caller_monitor, [:flush])
        Process.demonitor(member.monitor, [:flush])
        resume_member(member)

        state =
          update_scope(state, id, fn scope ->
            scope = sample(scope, %{pid => {:current, reading}})
            %{scope | members: Map.delete(scope.members, pid)}
          end)

        {:reply, :ok,
         %{state | monitors: Map.drop(state.monitors, [member.monitor, caller_monitor])}}
    end
  end

  def handle_call({:close, id}, _from, state),
    do: {:reply, :ok, state |> remove_scope(id) |> drain()}

  def handle_call({:stats, id}, _from, state) do
    stats =
      case Map.get(state.scopes, id) do
        nil ->
          nil

        scope ->
          channel = Channels.snapshot(id)

          Map.take(scope, [
            :runs,
            :compiles,
            :violations,
            :throttles,
            :killed?,
            :last_offence,
            :last_throttle_us,
            :max_reaction_us,
            :heap_words,
            :usage_reductions,
            :compile_reductions,
            :growth_words,
            :gcs,
            :buffer_slots
          ])
          |> Map.put(
            :runnable,
            Enum.count(state.runtime_permits, fn {_, e} ->
              e.scope == id and e.generation == scope.generation and Runtime.active?(e.cell)
            end)
          )
          |> Map.put(
            :runtime_queued,
            Enum.count(state.runtime_queue, fn r -> state.runtime_permits[r.token].scope == id end) +
              length(Map.get(state.runtime_parked, id, []))
          )
          |> Map.update!(:usage_reductions, &(&1 + max(0, channel.cpu - scope.channel_seen.cpu)))
          |> Map.update!(
            :growth_words,
            &(&1 + max(0, channel.growth - scope.channel_seen.growth))
          )
          |> Map.update!(:gcs, &(&1 + max(0, channel.gcs - scope.channel_seen.gcs)))
          |> Map.put(
            :heap_words,
            max(0, scope.heap_words - scope.channel_seen.heap) + channel.heap
          )
          |> Map.put(:channels, channel.channels)
          |> Map.put(:buffer_slots, channel.buffer_slots)
          |> Map.put(:members, map_size(scope.members) + channel.channels)
          |> Map.put(:queued, Enum.count(state.queue, &(&1.scope == id)))
      end

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:detach, _id, _pid, _reading, _token, _lease} = request, state) do
    {:reply, :ok, state} = handle_call(request, nil, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:channel_sampled, id, generation}, state) do
    state =
      update_scope(state, id, fn scope ->
        if scope.generation == generation and not scope.killed?,
          do: scope |> sample() |> enforce(id) |> arm_sample(id),
          else: scope
      end)

    {:noreply, state |> sync_runtime_scope(id) |> drain()}
  end

  def handle_info(:runtime_ready, state), do: {:noreply, drain(state)}

  def handle_info({{:scope_suspended, id, _pid, offence_after}, :suspended}, state) do
    state =
      update_scope(state, id, fn scope ->
        Map.update!(scope, :max_reaction_us, &max(&1, now_us() - offence_after))
      end)

    {:noreply, state}
  end

  def handle_info({{:scope_suspended, _id, _pid, _time}, _}, state), do: {:noreply, state}

  def handle_info({:sample, id, generation}, state) do
    state =
      update_scope(state, id, fn scope ->
        if scope.generation == generation do
          members = Enum.map(scope.members, fn {pid, member} -> {pid, member.sample_ref} end)
          send(scope.sampler, {:sample, members})
          %{scope | timer: nil, sampling?: true}
        else
          scope
        end
      end)

    {:noreply, state}
  end

  def handle_info({:sampled, id, generation, readings}, state) do
    state =
      update_scope(state, id, fn scope ->
        if scope.generation == generation and not scope.killed? do
          scope
          |> Map.put(:sampling?, false)
          |> Map.put(:timer, nil)
          |> sample(readings)
          |> enforce(id)
          |> arm_sample(id)
        else
          scope
        end
      end)

    {:noreply, state |> sync_runtime_scope(id) |> drain()}
  end

  def handle_info({:wait_expired, ref}, state) do
    {expired, queue} = Enum.split_with(state.queue, &(&1.ref == ref))

    Enum.each(expired, fn request ->
      Process.demonitor(request.monitor, [:flush])
      GenServer.reply(request.from, busy(:wait_timeout))
    end)

    {:noreply, %{state | queue: queue}}
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    case Map.get(state.monitors, monitor) do
      {:owner, id} ->
        state = remove_scope(state, id)
        # External owners clean their own tables without a synchronous cycle.
        cleanup_external_async(id)
        {:noreply, drain(state)}

      {:sampler, id} ->
        cleanup_external_async(id)
        {:noreply, state |> remove_scope(id) |> drain()}

      {:runtime, token} ->
        {:noreply, state |> drop_runtime(token) |> drain()}

      {:lease, lease} ->
        {:noreply, state |> release_lease(lease) |> drain()}

      {:member_caller, id, worker} ->
        scope = state.scopes[id]
        member = scope && scope.members[worker]
        if member && killable?(scope, member), do: Process.exit(worker, :kill)
        {:noreply, %{state | monitors: Map.delete(state.monitors, monitor)}}

      {:member, id, ^pid} ->
        caller_monitor = get_in(state, [:scopes, id, :members, pid, :caller_monitor])
        if caller_monitor, do: Process.demonitor(caller_monitor, [:flush])

        state =
          update_scope(state, id, fn scope ->
            slots = Map.get(scope.channels, pid, 0)

            %{
              scope
              | members: Map.delete(scope.members, pid),
                channels: Map.delete(scope.channels, pid),
                buffer_slots: scope.buffer_slots - slots
            }
          end)

        {:noreply, %{state | monitors: Map.drop(state.monitors, [monitor, caller_monitor])}}

      nil ->
        {dead, queue} = Enum.split_with(state.queue, &(&1.monitor == monitor))
        Enum.each(dead, &Process.cancel_timer(&1.timer))
        {:noreply, %{state | queue: queue}}
    end
  end

  # Scope and Limits wake at high priority only while idle, so a latency
  # request reaches an idle server without queueing behind background
  # processes. Each message drops to normal priority first: a long handler
  # runs at most one time slice at high, and a backlog is served at normal.
  defoverridable handle_call: 3, handle_cast: 2, handle_info: 2

  @impl true
  def handle_call(request, from, state),
    do: idle_priority(fn -> super(request, from, state) end)

  @impl true
  def handle_cast(request, state), do: idle_priority(fn -> super(request, state) end)

  @impl true
  def handle_info(message, state), do: idle_priority(fn -> super(message, state) end)

  @doc false
  def idle_priority(fun) do
    Process.flag(:priority, :normal)

    try do
      fun.()
    after
      idle? = Process.info(self(), :message_queue_len) == {:message_queue_len, 0}
      Process.flag(:priority, if(idle?, do: :high, else: :normal))
    end
  end

  defp normalize_policy(policy) do
    policy = Map.merge(@defaults, policy)

    positive = [
      :max_concurrent_runs,
      :max_concurrent_compiles,
      :wait_ms,
      :heap_words,
      :compile_heap_words,
      :sample_ms,
      :max_violations,
      :max_code_pins
    ]

    nonnegative = [:max_queue, :max_channels, :max_buffer_slots]

    valid =
      Map.keys(policy) -- Map.keys(@defaults) == [] and
        Enum.all?(positive, &(is_integer(policy[&1]) and policy[&1] > 0)) and
        Enum.all?(nonnegative, &(is_integer(policy[&1]) and policy[&1] >= 0)) and
        policy.priority in [:background, :latency] and policy.sample_ms <= 10 and
        valid_rate?(policy.rate) and
        valid_rate?(policy.compile_rate) and
        valid_churn?(policy.churn)

    if valid, do: {:ok, policy}, else: {:error, :invalid_scope_policy}
  end

  defp valid_rate?(nil), do: true

  defp valid_rate?(%{quota: q, period_ms: p})
       when is_integer(q) and q > 0 and is_integer(p) and p > 0, do: true

  defp valid_rate?(_), do: false
  defp valid_churn?(nil), do: true

  defp valid_churn?(%{heap_words: h, gcs: g, period_ms: p})
       when is_integer(h) and h > 0 and is_integer(g) and g > 0 and is_integer(p) and p > 0,
       do: true

  defp valid_churn?(_), do: false

  defp ensure_scope(state, id, owner) do
    if Map.has_key?(state.scopes, id) do
      state
    else
      # A default scope belongs to the host it is named after, whichever
      # process asks first: a code load reaches Scope through CodeServer.
      owner =
        case id do
          {__MODULE__, host} when is_pid(host) -> host
          _named -> owner
        end

      monitor = Process.monitor(owner)
      generation = make_ref()
      server = self()

      control = Runtime.control()
      {:ok, sampler} = Channels.start(server, id, generation, control, @defaults)
      sampler_monitor = Process.monitor(sampler)

      now = now_us()

      scope = %{
        id: id,
        owner: owner,
        owner_monitor: monitor,
        policy: @defaults,
        runs: 0,
        compiles: 0,
        members: %{},
        channels: %{},
        startchans: %{},
        buffer_slots: 0,
        cpu_start: now,
        compile_start: now,
        churn_start: now,
        cpu_used: 0,
        compile_used: 0,
        growth_used: 0,
        gcs_used: 0,
        heap_words: 0,
        usage_reductions: 0,
        compile_reductions: 0,
        growth_words: 0,
        gcs: 0,
        suspended_until: nil,
        violations: 0,
        throttles: 0,
        killed?: false,
        last_offence: nil,
        last_throttle_us: nil,
        max_reaction_us: 0,
        timer: nil,
        sampling?: false,
        sampler: sampler,
        sampler_monitor: sampler_monitor,
        generation: generation,
        runtime_control: control,
        channel_seen: %{cpu: 0, growth: 0, gcs: 0, heap: 0},
        sampled_at: now,
        detection_bound_us: 0
      }

      :ets.insert(@policies, {id, @defaults})

      state
      |> put_in([:scopes, id], scope)
      |> put_in([:monitors, monitor], {:owner, id})
      |> put_in([:monitors, sampler_monitor], {:sampler, id})
    end
  end

  defp attach_member(
         state,
         id,
         {pid, kind, heap_reservation, caller, fault, reading, lifetime?}
       ) do
    case Map.get(state.scopes, id) do
      nil ->
        {busy(:scope_closed), state}

      %{killed?: true} ->
        {busy(:scope_terminated), state}

      scope ->
        scope = sample(scope, %{pid => {:current, reading}})
        previous_member = Map.get(scope.members, pid)
        {scope, state} = put_member(scope, state, id, pid, kind, reading)

        scope =
          if previous_member,
            do: update_in(scope, [:members, pid, :depth], &(&1 + 1)),
            else: scope

        scope =
          scope
          |> put_in([:members, pid, :faults], [fault | Map.get(scope.members[pid], :faults, [])])
          |> put_in([:members, pid, :caller], caller || Map.get(scope.members[pid], :caller))

        {scope, state} =
          if is_pid(caller) and not Map.has_key?(scope.members[pid], :caller_monitor) do
            monitor = Process.monitor(caller)

            {put_in(scope, [:members, pid, :caller_monitor], monitor),
             put_in(state, [:monitors, monitor], {:member_caller, id, pid})}
          else
            {scope, state}
          end

        # Charge the committed heap allowance as well as sampled growth. A
        # worker that dies between samples cannot reset a tenant's churn budget.
        reservation =
          if kind != :compile && scope.policy.churn && is_integer(heap_reservation),
            do: max(0, heap_reservation),
            else: 0

        scope = %{
          scope
          | growth_used: scope.growth_used + reservation,
            growth_words: scope.growth_words + reservation
        }

        scope = scope |> sample() |> enforce(id)
        state = put_in(state, [:scopes, id], arm_sample(scope, id))
        state = state |> sync_runtime_scope(id) |> drain_runtime()

        cond do
          scope.killed? ->
            {busy(:scope_terminated), state}

          lifetime? ->
            {token, state} = open_lifetime(state, id, pid)
            {{:ok, runtime_handle(state, token), scope.generation}, state}

          true ->
            {:ok, state}
        end
    end
  end

  defp admitted(state, _id, lease, nil), do: {:reply, {:ok, lease}, state}

  defp admitted(state, id, lease, attach) do
    case attach_member(state, id, attach) do
      {{:error, _} = error, state} -> {:reply, error, state |> release_lease(lease) |> drain()}
      {reply, state} -> {:reply, {:ok, lease, reply}, state}
    end
  end

  defp available?(state, scope, kind) do
    not scope.killed? and (is_nil(scope.suspended_until) or scope.suspended_until <= now_us()) and
      case kind do
        :run ->
          scope.runs < scope.policy.max_concurrent_runs

        :compile ->
          scope.compiles < scope.policy.max_concurrent_compiles and
            state.compile_count < compile_limit()
      end
  end

  defp runtime_limit do
    max(
      2,
      Application.get_env(
        :hyperlang,
        :runtime_concurrency,
        max(256, 32 * :erlang.system_info(:schedulers_online))
      )
    )
  end

  defp compile_limit do
    schedulers = :erlang.system_info(:schedulers_online)
    configured = Application.get_env(:hyperlang, :compile_concurrency, max(1, div(schedulers, 2)))
    max(1, min(configured, max(1, schedulers - 1)))
  end

  defp admit(state, id, kind, owner) do
    lease = make_ref()
    monitor = Process.monitor(owner)
    key = if kind == :run, do: :runs, else: :compiles
    state = update_in(state, [:scopes, id, key], &(&1 + 1))
    state = update_in(state, [:lease_owners], &Map.update(&1, owner, 1, fn n -> n + 1 end))

    state =
      state
      |> put_in([:leases, lease], %{
        scope: id,
        kind: kind,
        owner: owner,
        monitor: monitor,
        background?: state.scopes[id].policy.priority == :background,
        nested?: false
      })
      |> put_in([:monitors, monitor], {:lease, lease})

    state =
      if kind == :compile, do: %{state | compile_count: state.compile_count + 1}, else: state

    {lease, state}
  end

  defp nested?(state, id, kind, owner, hint?) do
    if hint? or Map.has_key?(state.lease_owners, owner) or
         Map.has_key?(state.scopes[id].members, owner) do
      nested_ancestor?(state, id, kind, owner)
    else
      false
    end
  end

  defp nested_ancestor?(state, id, kind, owner) do
    ancestry = ancestors(state, owner, MapSet.new())

    (kind == :run and Map.has_key?(state.scopes[id].members, owner) and state.scopes[id].runs > 0) or
      Enum.any?(state.leases, fn {_lease, entry} ->
        entry.scope == id and entry.kind == kind and MapSet.member?(ancestry, entry.owner)
      end)
  end

  defp ancestors(state, pid, seen) do
    if MapSet.member?(seen, pid) do
      seen
    else
      seen = MapSet.put(seen, pid)

      Enum.reduce(state.scopes, seen, fn {_id, scope}, acc ->
        case scope.members[pid] do
          %{caller: caller} when is_pid(caller) -> ancestors(state, caller, acc)
          _ -> acc
        end
      end)
    end
  end

  defp active_caller?(state, owner) do
    Enum.any?(state.scopes, fn {_id, scope} -> Map.has_key?(scope.members, owner) end) or
      Enum.any?(state.leases, fn {_, entry} -> entry.owner == owner end)
  end

  defp admit_nested(state, id, kind, owner) do
    lease = make_ref()
    monitor = Process.monitor(owner)

    state = update_in(state, [:lease_owners], &Map.update(&1, owner, 1, fn n -> n + 1 end))

    state =
      state
      |> put_in([:leases, lease], %{
        scope: id,
        kind: kind,
        owner: owner,
        monitor: monitor,
        nested?: true
      })
      |> put_in([:monitors, monitor], {:lease, lease})

    {lease, state}
  end

  defp release_lease(state, lease) do
    case Map.pop(state.leases, lease) do
      {nil, _} ->
        state

      {%{nested?: true} = entry, leases} ->
        Process.demonitor(entry.monitor, [:flush])
        state = untrack_lease_owner(state, entry.owner)
        %{state | leases: leases, monitors: Map.delete(state.monitors, entry.monitor)}

      {entry, leases} ->
        Process.demonitor(entry.monitor, [:flush])
        state = untrack_lease_owner(state, entry.owner)
        state = %{state | leases: leases, monitors: Map.delete(state.monitors, entry.monitor)}
        key = if entry.kind == :run, do: :runs, else: :compiles
        state = update_scope(state, entry.scope, &Map.update!(&1, key, fn n -> max(0, n - 1) end))

        case entry.kind do
          :compile ->
            %{state | compile_count: max(0, state.compile_count - 1)}

          :run ->
            state
        end
    end
  end

  defp untrack_lease_owner(state, owner) do
    owners =
      case Map.get(state.lease_owners, owner, 0) do
        n when n > 1 -> Map.put(state.lease_owners, owner, n - 1)
        _ -> Map.delete(state.lease_owners, owner)
      end

    %{state | lease_owners: owners}
  end

  defp drain(state) do
    state = drain_runtime(state)

    Enum.reduce(
      Enum.sort_by(state.queue, fn request ->
        if get_in(state, [:scopes, request.scope, :policy, :priority]) == :latency, do: 0, else: 1
      end),
      %{state | queue: []},
      fn request, state ->
        scope = state.scopes[request.scope]

        cond do
          is_nil(scope) or scope.killed? ->
            cancel_request(request)
            GenServer.reply(request.from, busy(:scope_closed))
            state

          available?(state, scope, request.kind) ->
            cancel_request(request)
            {lease, state} = admit(state, request.scope, request.kind, request.owner)
            GenServer.reply(request.from, {:ok, lease})
            state

          true ->
            %{state | queue: state.queue ++ [request]}
        end
      end
    )
  end

  defp runtime_available?(state, scope) do
    not scope.killed? and is_nil(scope.suspended_until) and
      not is_nil(state.runtime_gate)
  end

  defp runtime_count(state, entry, -1) do
    Runtime.suspend(state.runtime_gate, entry.cell, entry.token, self())
    state
  end

  # A run worker's lifetime starts blocked: it holds no slot until it enters
  # guest code, and pause/suspension never re-grants it a slot while it waits.
  # It counts as granted because its first local reservation needs no server
  # round trip; scope termination must therefore kill it like any granted run.
  defp open_lifetime(state, id, owner) do
    {token, state} = new_runtime_entry(state, id, owner, true)
    Runtime.wait(state.runtime_permits[token].cell)
    {token, state}
  end

  defp new_runtime_entry(state, id, owner, granted?) do
    scope = state.scopes[id]
    token = make_ref()
    monitor = Process.monitor(owner)

    state =
      if map_size(state.runtime_permits) == 0 and
           Runtime.limit(state.runtime_gate) != runtime_limit(),
         do: %{state | runtime_gate: Runtime.new(runtime_limit())},
         else: state

    entry = %{
      cell: Runtime.slot(Runtime.limit(state.runtime_gate)),
      token: token,
      scope: id,
      owner: owner,
      monitor: monitor,
      active?: false,
      granted?: granted?,
      paused?: false,
      pause_depth: 0,
      closed?: false,
      protected?:
        not match?(%{kind: :actor_run}, scope.members[owner]) and
          (owner == scope.owner or match?(%{kind: :host_run}, scope.members[owner])),
      background?: scope.policy.priority == :background,
      generation: scope.generation
    }

    state =
      state
      |> put_in([:runtime_permits, token], entry)
      |> put_in([:monitors, monitor], {:runtime, token})
      |> update_in(
        [:runtime_scopes],
        &Map.update(&1, id, MapSet.new([token]), fn tokens -> MapSet.put(tokens, token) end)
      )

    {token, state}
  end

  defp drop_runtime(state, token, reason \\ nil) do
    case Map.pop(state.runtime_permits, token) do
      {nil, _} ->
        state

      {entry, permits} ->
        Process.demonitor(entry.monitor, [:flush])
        parked = Map.get(state.runtime_parked, entry.scope, [])
        {parked_removed, parked} = Enum.split_with(parked, &(&1.token == token))
        {removed, queue} = Enum.split_with(state.runtime_queue, &(&1.token == token))
        removed = parked_removed ++ removed

        parked_scopes =
          if parked == [],
            do: Map.delete(state.runtime_parked, entry.scope),
            else: Map.put(state.runtime_parked, entry.scope, parked)

        for request <- removed do
          if request.from, do: GenServer.reply(request.from, busy(reason || :scope_terminated))
          notify_runtime_resume(request)
        end

        tokens = state.runtime_scopes |> Map.fetch!(entry.scope) |> MapSet.delete(token)

        runtime_scopes =
          if MapSet.size(tokens) == 0,
            do: Map.delete(state.runtime_scopes, entry.scope),
            else: Map.put(state.runtime_scopes, entry.scope, tokens)

        state = %{
          state
          | runtime_permits: permits,
            runtime_scopes: runtime_scopes,
            runtime_parked: parked_scopes,
            runtime_queue: queue,
            monitors: Map.delete(state.monitors, entry.monitor)
        }

        Runtime.close(entry.cell)
        Runtime.reclaim(state.runtime_gate, entry.cell, entry.token, self())
        state
    end
  end

  defp sync_runtime_scope(state, id) do
    if scope = state.scopes[id] do
      :atomics.put(
        scope.runtime_control,
        1,
        cond do
          scope.killed? -> 2
          not is_nil(scope.suspended_until) -> 1
          true -> 0
        end
      )
    end

    # Suspended workers surrender capacity. On refill they keep their original
    # token but must win admission before the VM suspension is lifted.
    state =
      Enum.reduce(Map.get(state.runtime_scopes, id, MapSet.new()), state, fn token, acc ->
        entry = acc.runtime_permits[token]
        scope = if entry.scope == id, do: acc.scopes[id]
        member = scope && scope.members[entry.owner]

        cond do
          entry.scope != id ->
            acc

          entry.closed? ->
            acc

          scope && scope.killed? && entry.granted? && entry.protected? &&
              not Runtime.waiting?(entry.cell) ->
            retain_closed_runtime(acc, token)

          is_nil(scope) or scope.killed? ->
            retire_runtime(acc, token, :scope_terminated)

          member && member.suspended? ->
            # Include a reservation interrupted before its local active commit.
            acc = runtime_count(acc, entry, -1)
            acc = put_in(acc, [:runtime_permits, token, :active?], false)

            if Runtime.waiting?(entry.cell) or
                 Enum.any?(runtime_requests(acc), &(&1.token == token)),
               do: acc,
               else: park_runtime(acc, entry.scope, %{token: token, from: nil})

          true ->
            acc
        end
      end)

    scope = state.scopes[id]

    state =
      if scope && is_nil(scope.suspended_until) do
        {ready, parked} = Map.pop(state.runtime_parked, id, [])
        %{state | runtime_parked: parked, runtime_queue: state.runtime_queue ++ ready}
      else
        state
      end

    if scope && is_nil(scope.suspended_until) && scope.throttles > 0 do
      owners =
        state.runtime_permits
        |> Enum.reject(fn {_, e} -> Runtime.waiting?(e.cell) end)
        |> MapSet.new(fn {_, e} -> e.owner end)

      Enum.reduce(scope.members, state, fn {pid, member}, acc ->
        if member.suspended? and not MapSet.member?(owners, pid),
          do: resume_runtime_member(acc, id, pid),
          else: acc
      end)
    else
      state
    end
  end

  defp drain_runtime(state) do
    if state.runtime_queue != [], do: :atomics.put(state.runtime_gate, 1, 1)

    queue =
      Enum.sort_by(state.runtime_queue, fn request ->
        entry = state.runtime_permits[request.token]
        if entry && not entry.background?, do: 0, else: 1
      end)

    state =
      Enum.reduce(queue, %{state | runtime_queue: []}, fn request, acc ->
        entry = acc.runtime_permits[request.token]
        scope = entry && acc.scopes[entry.scope]

        cond do
          is_nil(entry) ->
            acc

          entry.paused? or (not entry.closed? && scope && not is_nil(scope.suspended_until)) ->
            park_runtime(acc, entry.scope, request)

          (entry.closed? || (scope && runtime_available?(acc, scope))) &&
              Runtime.grant(acc.runtime_gate, entry.cell, entry.token, entry.background?) == :ok ->
            acc =
              acc
              |> put_in([:runtime_permits, request.token, :active?], true)
              |> put_in([:runtime_permits, request.token, :granted?], true)

            if request.from do
              reply =
                if Map.get(request, :resume?),
                  do: :ok,
                  else: {:ok, runtime_handle(acc, request.token), entry.generation}

              GenServer.reply(request.from, reply)
            end

            notify_runtime_resume(request)
            if entry.closed?, do: acc, else: resume_runtime_member(acc, entry.scope, entry.owner)

          true ->
            %{acc | runtime_queue: acc.runtime_queue ++ [request]}
        end
      end)

    :atomics.put(state.runtime_gate, 1, if(state.runtime_queue == [], do: 0, else: 1))
    state
  end

  defp runtime_handle(state, token) do
    entry = state.runtime_permits[token]

    {token, state.runtime_gate, entry.cell, state.scopes[entry.scope].runtime_control,
     entry.background?, self(), Runtime.limit(state.runtime_gate)}
  end

  defp take_runtime_requests(state, tokens) do
    {ready, queue} = Enum.split_with(state.runtime_queue, &(&1.token in tokens))

    {parked_ready, parked} =
      Enum.reduce(state.runtime_parked, {[], %{}}, fn {id, requests}, {ready, parked} ->
        {yes, no} = Enum.split_with(requests, &(&1.token in tokens))
        {ready ++ yes, if(no == [], do: parked, else: Map.put(parked, id, no))}
      end)

    {ready ++ parked_ready, %{state | runtime_queue: queue, runtime_parked: parked}}
  end

  defp retire_runtime(state, token, reason) do
    entry = state.runtime_permits[token]

    if not entry.granted? do
      drop_runtime(state, token, reason)
    else
      Runtime.close(entry.cell)

      if not entry.protected? and not Runtime.waiting?(entry.cell),
        do: Process.exit(entry.owner, :kill)

      {requests, state} = take_runtime_requests(state, [token])

      for request <- requests do
        if request.from, do: GenServer.reply(request.from, busy(reason))
        notify_runtime_resume(request)
      end

      put_in(state, [:runtime_permits, token, :closed?], true)
    end
  end

  defp retain_closed_runtime(state, token) do
    entry = state.runtime_permits[token]
    Runtime.close(entry.cell)
    state = put_in(state, [:runtime_permits, token, :closed?], true)

    {ready, parked} =
      Enum.split_with(Map.get(state.runtime_parked, entry.scope, []), &(&1.token == token))

    parked_scopes =
      if parked == [],
        do: Map.delete(state.runtime_parked, entry.scope),
        else: Map.put(state.runtime_parked, entry.scope, parked)

    %{state | runtime_parked: parked_scopes, runtime_queue: state.runtime_queue ++ ready}
  end

  defp runtime_requests(state),
    do: state.runtime_queue ++ Enum.flat_map(state.runtime_parked, fn {_, q} -> q end)

  defp notify_runtime_resume(request) do
    case Map.get(request, :notify) do
      {suspender, pid} -> send(suspender, {:runtime_resume, pid})
      nil -> :ok
    end
  end

  defp park_runtime(state, id, request) do
    update_in(
      state,
      [:runtime_parked],
      &Map.update(&1, id, [request], fn rows -> rows ++ [request] end)
    )
  end

  defp resume_runtime_member(state, id, pid) do
    case get_in(state, [:scopes, id, :members, pid]) do
      %{suspended?: true} = member ->
        resume_member(member)
        put_in(state, [:scopes, id, :members, pid, :suspended?], false)

      _ ->
        state
    end
  end

  defp cancel_request(request) do
    Process.cancel_timer(request.timer)
    Process.demonitor(request.monitor, [:flush])
  end

  defp put_member(scope, state, id, pid, kind, reading) do
    if Map.has_key?(scope.members, pid) do
      {scope, state}
    else
      monitor = Process.monitor(pid)

      member =
        Map.merge(reading, %{
          pid: pid,
          kind: kind,
          monitor: monitor,
          suspended?: false,
          sample_ref: make_ref(),
          depth: 1
        })

      scope = put_in(scope, [:members, pid], member)
      {scope, put_in(state, [:monitors, monitor], {:member, id, pid})}
    end
  end

  defp read_member(pid) do
    case Process.info(pid, [:reductions, :total_heap_size, :garbage_collection, :memory]) do
      nil ->
        %{reductions: 0, heap: 0, gcs: 0, memory_words: 0}

      info ->
        %{
          reductions: info[:reductions],
          heap: info[:total_heap_size],
          gcs: Keyword.get(info[:garbage_collection], :minor_gcs, 0),
          memory_words: div(info[:memory], :erlang.system_info(:wordsize))
        }
    end
  end

  defp sample(scope, readings \\ %{}) do
    now = now_us()
    scope = refill(scope, now)

    {members, cpu, compile, growth, gcs, heap} =
      Enum.reduce(scope.members, {scope.members, 0, 0, 0, 0, 0}, fn {pid, member},
                                                                    {members, cpu, compile,
                                                                     growth, gcs, heap} ->
        current =
          case Map.get(readings, pid) do
            {ref, current} when ref == :current or ref == member.sample_ref ->
              if current.reductions >= member.reductions, do: current

            _ ->
              nil
          end

        if is_nil(current) do
          {members, cpu, compile, growth, gcs,
           heap + if(member.kind == :compile, do: 0, else: max(member.heap, member.memory_words))}
        else
          reductions = max(0, current.reductions - member.reductions)
          growth_delta = max(0, current.heap - member.heap)
          gc_delta = max(0, current.gcs - member.gcs)
          # A collection between samples is charged at least its retained heap.
          growth_delta =
            if member.kind == :compile, do: 0, else: growth_delta + gc_delta * current.heap

          gc_delta = if member.kind == :compile, do: 0, else: gc_delta
          compile_delta = if member.kind == :compile, do: reductions, else: 0

          {Map.put(members, pid, Map.merge(member, current)), cpu + reductions - compile_delta,
           compile + compile_delta, growth + growth_delta, gcs + gc_delta,
           heap +
             if(member.kind == :compile, do: 0, else: max(current.heap, current.memory_words))}
        end
      end)

    channel = Channels.snapshot(scope.id)
    cpu = cpu + max(0, channel.cpu - scope.channel_seen.cpu)
    growth = growth + max(0, channel.growth - scope.channel_seen.growth)
    gcs = gcs + max(0, channel.gcs - scope.channel_seen.gcs)
    heap = heap + channel.heap

    %{
      scope
      | members: members,
        channel_seen: Map.take(channel, [:cpu, :growth, :gcs, :heap]),
        cpu_used: scope.cpu_used + cpu,
        compile_used: scope.compile_used + compile,
        growth_used: scope.growth_used + growth,
        gcs_used: scope.gcs_used + gcs,
        heap_words: heap,
        usage_reductions: scope.usage_reductions + cpu,
        compile_reductions: scope.compile_reductions + compile,
        growth_words: scope.growth_words + growth,
        gcs: scope.gcs + gcs,
        sampled_at: now,
        detection_bound_us: now - scope.sampled_at
    }
  end

  defp refill(scope, now) do
    scope =
      if not is_nil(scope.suspended_until) and now >= scope.suspended_until do
        %{scope | suspended_until: nil}
      else
        scope
      end

    scope = refill_counter(scope, :rate, :cpu_start, [:cpu_used], now)
    scope = refill_counter(scope, :compile_rate, :compile_start, [:compile_used], now)
    refill_counter(scope, :churn, :churn_start, [:growth_used, :gcs_used], now)
  end

  defp refill_counter(scope, policy_key, start_key, counters, now) do
    case scope.policy[policy_key] do
      %{period_ms: period} ->
        if now - scope[start_key] >= period * 1000 do
          Enum.reduce(counters, Map.put(scope, start_key, now), &Map.put(&2, &1, 0))
        else
          scope
        end

      _ ->
        scope
    end
  end

  defp enforce(%{killed?: true} = scope, _id), do: scope

  defp enforce(scope, id) do
    offence =
      cond do
        scope.heap_words > scope.policy.heap_words ->
          {:heap, now_us()}

        scope.policy.rate && scope.cpu_used > scope.policy.rate.quota ->
          {:cpu, scope.cpu_start + scope.policy.rate.period_ms * 1000}

        scope.policy.compile_rate && scope.compile_used > scope.policy.compile_rate.quota ->
          {:compile, scope.compile_start + scope.policy.compile_rate.period_ms * 1000}

        scope.policy.churn &&
            (scope.growth_used > scope.policy.churn.heap_words or
               scope.gcs_used > scope.policy.churn.gcs) ->
          {:churn, scope.churn_start + scope.policy.churn.period_ms * 1000}

        true ->
          nil
      end

    cond do
      is_nil(offence) or (not is_nil(scope.suspended_until) and scope.suspended_until > now_us()) ->
        scope

      true ->
        {reason, until} = offence
        now = now_us()
        reaction = scope.detection_bound_us + now - scope.sampled_at
        violations = scope.violations + 1
        kill? = reason == :heap or violations >= scope.policy.max_violations

        members =
          Map.new(scope.members, fn {pid, member} ->
            if kill? do
              mark_fault(member, 2)
              if killable?(scope, member), do: Process.exit(pid, :kill)
              {pid, member}
            else
              suspended =
                try do
                  killable?(scope, member) and
                    :erlang.suspend_process(pid, [
                      {:asynchronous,
                       {:scope_suspended, id, pid, scope.sampled_at - scope.detection_bound_us}}
                    ])
                rescue
                  _ -> false
                end

              {pid, %{member | suspended?: suspended == true}}
            end
          end)

        if kill?, do: cleanup_external_async(id)

        %{
          scope
          | members: members,
            violations: violations,
            throttles: scope.throttles + 1,
            killed?: kill?,
            suspended_until: max(until, now + 1000),
            last_offence: reason,
            last_throttle_us: now,
            max_reaction_us: max(scope.max_reaction_us, reaction)
        }
    end
  end

  defp arm_sample(scope, _id) do
    if scope.timer == nil and not scope.sampling? and
         (map_size(scope.members) > 0 or
            (not is_nil(scope.suspended_until) and scope.suspended_until > now_us())) and
         not scope.killed? do
      %{
        scope
        | timer:
            Process.send_after(
              scope.sampler,
              {:sample,
               Enum.map(scope.members, fn {pid, member} -> {pid, member.sample_ref} end)},
              sample_delay(scope)
            )
      }
    else
      scope
    end
  end

  defp sample_delay(scope) do
    if scope.suspended_until && scope.suspended_until > now_us() &&
         Enum.all?(scope.members, fn {_, member} -> member.suspended? end) do
      # No member can accrue usage until refill. Avoid polling each suspended
      # tenant every two milliseconds; wake exactly when it can become runnable.
      max(1, div(scope.suspended_until - now_us() + 999, 1000))
    else
      scope.policy.sample_ms
    end
  end

  defp resume_member(%{suspended?: true, pid: pid}) do
    try do
      :erlang.resume_process(pid)
    rescue
      _ -> :ok
    end
  end

  defp resume_member(_), do: :ok

  defp remove_scope(state, id) do
    case Map.pop(state.scopes, id) do
      {nil, _} ->
        state

      {scope, scopes} ->
        :atomics.put(scope.runtime_control, 1, 3)
        if scope.timer, do: Process.cancel_timer(scope.timer)
        Process.demonitor(scope.owner_monitor, [:flush])
        Process.demonitor(scope.sampler_monitor, [:flush])
        Channels.close(id, scope.sampler)

        Enum.each(scope.members, fn {pid, member} ->
          resume_member(member)
          Process.demonitor(member.monitor, [:flush])
          if ref = Map.get(member, :caller_monitor), do: Process.demonitor(ref, [:flush])
          mark_fault(member, 1)
          if killable?(scope, member), do: Process.exit(pid, :kill)
        end)

        leases = for {lease, entry} <- state.leases, entry.scope == id, do: lease
        state = Enum.reduce(leases, state, &release_lease(&2, &1))

        refs = [
          scope.owner_monitor
          | [scope.sampler_monitor] ++
              Enum.flat_map(scope.members, fn {_, m} ->
                [m.monitor, Map.get(m, :caller_monitor)]
              end)
        ]

        state =
          Enum.reduce(Map.get(state.runtime_scopes, id, MapSet.new()), state, fn token, acc ->
            entry = acc.runtime_permits[token]

            if entry.granted? and entry.protected? and not Runtime.waiting?(entry.cell) do
              # Scope closure cannot preempt trusted in-caller execution. Keep
              # charging its CPU slot until it returns, blocks or exits.
              retain_closed_runtime(acc, token)
            else
              retire_runtime(acc, token, :scope_closed)
            end
          end)

        :ets.delete(@policies, id)
        %{state | scopes: scopes, monitors: Map.drop(state.monitors, refs)}
    end
  end

  defp killable?(scope, member),
    do:
      member.kind == :actor_run or
        (member.pid != scope.owner and member.kind not in [:channel, :host_run])

  defp mark_fault(member, reason) do
    for fault <- Map.get(member, :faults, []),
        not is_nil(fault),
        do: :atomics.put(fault, 1, reason)

    :ok
  end

  @doc false
  def fault_reason(fault) do
    case :atomics.get(fault, 1) do
      1 -> busy(:scope_closed)
      2 -> busy(:scope_terminated)
      _ -> :ok
    end
  end

  defp cleanup_external(scope) do
    Hyperlang.MsgTimerServer.close_scope(scope)
    Hyperlang.Chan.close_scope(scope)
    :ok
  end

  defp cleanup_external_async(scope) do
    for name <- [Hyperlang.MsgTimerServer, Hyperlang.Chan.Registry] do
      if pid = Process.whereis(name), do: send(pid, {:scope_closed, scope})
    end

    :ok
  end

  defp update_scope(state, id, fun) do
    if Map.has_key?(state.scopes, id), do: update_in(state, [:scopes, id], fun), else: state
  end

  defp busy(reason), do: {:error, %{category: :busy, reason: reason}}
  defp now_us, do: System.monotonic_time(:microsecond)
end
