defmodule Hyperlang.Limits do
  @moduledoc """
  Process-group limits for confined code.

  A group owns a reduction rate, a total reduction ceiling, and any processes
  attached to it. A single watchdog samples every live member, suspends a
  group after its period quota is spent, resumes it at rollover, and
  terminates members that cross a ceiling. Each member's wall deadline is a
  dedicated timer.

  `Hyperlang.run/4` manages its own groups. Syscall hosts use this module to
  meter processes they spawn for a guest: create a group with `group/1`,
  `attach/3` the process, and `delete/1` the group when its owner is done.
  The process that calls `group/1` owns the group; its exit deletes it.

  Limit keys are `rate` (`%{quota: reductions, period_ms: ms}`), `ceiling`
  (total reductions), `wall_ms`, `heap_words` and `max_procs` (guest-spawned
  children; `0` admits none). `:infinity` or `nil` means unbounded.
  """

  use GenServer

  @tick_ms 25
  @slot_key {__MODULE__, :slots}
  @process_group_key {__MODULE__, :process_group}
  @process_run_key {__MODULE__, :process_run}
  @process_timer_key {__MODULE__, :process_timer}
  @finished_key {__MODULE__, :finished}
  @slot_generation 1
  @slot_armed 2
  @slot_baseline 3
  @slot_last 4
  @slot_ceiling 5
  @slot_deadline 6
  @slot_reason 7
  @slot_children 8
  @slot_max_procs 9
  @slot_record_only 10
  @slot_count 10
  @no_deadline -9_000_000_000_000_000_000
  @reason_none 0
  @reason_ceiling 1
  @reason_wall 2
  @no_limits %{rate: nil, ceiling: nil, wall_ms: nil, heap_words: nil, max_procs: nil}
  @obsolete_keys [:cpu_max, :reduction_rate, :budget, :reduction_budget]
  @obsolete_keys_and_names @obsolete_keys ++ Enum.map(@obsolete_keys, &Atom.to_string/1)

  defmodule Group do
    @moduledoc false
    @enforce_keys [:id]
    defstruct [:id, :limits]
  end

  @type group :: %Group{}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Create a group with `limits`, owned by the calling process."
  @spec group(map() | keyword()) :: group()
  def group(limits) do
    ensure_started()
    id = make_ref()
    :ok = Hyperlang.Scope.priority_call(__MODULE__, {:group, id, normalize(limits)})
    %Group{id: id}
  end

  # A run-owned group is created by the first `arm/3` of its run (the run's
  # worker, or a nested in-caller run), so a run needs no separate creation
  # call. Its owner is the process that calls `run_group/1`.
  @doc false
  def run_group(limits), do: %Group{id: make_ref(), limits: {self(), normalize(limits)}}

  # The limits group of a top-level in-caller run (an actor callback or a
  # host `run_in_caller?` run). One group and one ephemeral slot serve all
  # such runs of the calling process for its life, so a run sends Limits no
  # message unless a guest child joins it:
  #
  #   * the run's ceiling, wall deadline, child bound and kill mode are cells
  #     of the slot, armed and disarmed locally;
  #   * the wall timer is started by the run's process and names the Limits
  #     server, which kills only while the slot still holds that run's
  #     generation;
  #   * the server resets the group's usage when it sees a new generation, so
  #     no usage carries from one run to the next;
  #   * a guest child is admitted only while its run's generation is armed,
  #     and the run kills its children before it returns.
  #
  # A nested in-caller run, or one with a rate quota, gets its own run group.
  @doc false
  def in_caller_group(limits) do
    normalized = normalize(limits)

    if is_nil(normalized.rate) and is_nil(Process.get(@process_run_key)) do
      {id, counters} = process_group()
      generation = :atomics.add_get(counters, @slot_generation, 1)
      Process.put(@process_run_key, id)
      %Group{id: id, limits: {:process, generation, counters}}
    else
      %Group{id: make_ref(), limits: {self(), normalized}}
    end
  end

  defp process_group do
    ensure_started()
    server = Process.whereis(__MODULE__)

    case Process.get(@process_group_key) do
      {^server, id, counters} ->
        {id, counters}

      _ ->
        id = make_ref()
        counters = :atomics.new(@slot_count, signed: true)
        :atomics.put(counters, @slot_deadline, @no_deadline)
        :ok = Hyperlang.Scope.priority_call(__MODULE__, {:process_group, id, counters})
        Process.put(@process_group_key, {server, id, counters})
        {id, counters}
    end
  end

  @doc "Destroy a group and kill its remaining guest processes. Idempotent."
  @spec delete(group()) :: :ok
  def delete(%Group{id: id, limits: {:process, _generation, counters}}) do
    # The run is over: its slot is disarmed, so the server admits no more of
    # its children. A child counted before this read is killed here.
    Process.delete(@process_run_key)
    :atomics.put(counters, @slot_armed, 0)
    cancel_process_timer()

    if :atomics.exchange(counters, @slot_children, 0) > 0,
      do: :ok = Hyperlang.Scope.priority_call(__MODULE__, {:detach_children, id})

    :ok
  end

  def delete(%Group{id: id}) do
    {slot, slots} = Map.pop(Process.get(@slot_key, %{}), id)
    Process.put(@slot_key, slots)

    case Process.get(@finished_key, %{}) do
      %{^id => true} = finished ->
        Process.put(@finished_key, Map.delete(finished, id))
        :ok

      _ ->
        case slot do
          # The caller armed this group and no guest child ever joined it:
          # deletion kills nobody, so it needs no reply. Requests from one
          # process stay ordered, so a later request never sees the group.
          {_pid, counters} ->
            if :atomics.get(counters, @slot_children) == 0,
              do: Hyperlang.Scope.priority_cast(__MODULE__, {:delete, id}),
              else: Hyperlang.Scope.priority_call(__MODULE__, {:delete, id})

          nil ->
            Hyperlang.Scope.priority_call(__MODULE__, {:delete, id})
        end
    end
  end

  # The run's owner records that its worker already deleted the group in
  # `finish_run/2`, so `delete/1` needs no server call.
  @doc false
  def finished(%Group{id: id}),
    do: Process.put(@finished_key, Map.put(Process.get(@finished_key, %{}), id, true))

  @doc "Replace the limits of a live group. Returns `{:error, :closed}` for a deleted group."
  @spec limit(group(), map() | keyword()) :: :ok | {:error, :closed}
  def limit(%Group{id: id}, limits) do
    ensure_started()
    Hyperlang.Scope.priority_call(__MODULE__, {:limit, id, normalize(limits)})
  end

  @doc """
  Attach `pid` to `group` with per-member limits (`wall_ms`, `heap_words`,
  `ceiling`).

  Returns `{:error, :eagain}` when the group's `max_procs` is exhausted.
  """
  @spec attach(group(), pid(), map() | keyword()) :: :ok | {:error, :eagain}
  def attach(%Group{id: id} = group, pid, opts) when is_pid(pid) do
    ensure_started()

    opts =
      case group.limits do
        {:process, generation, _counters} ->
          Map.put(normalize_member_opts(opts), :generation, generation)

        _limits ->
          normalize_member_opts(opts)
      end

    case Hyperlang.Scope.priority_call(__MODULE__, {:attach, id, pid, opts}) do
      :ok ->
        apply_heap_limit(pid, opts.heap_words)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Finish a run worker armed with `arm/3`: disarm its slot locally, then
  # remove the worker from its run-owned group and delete the group. A group
  # no guest child joined is finished without waiting. Otherwise one call
  # checks the group's ceiling over the run and its children, deletes the
  # group and kills the children, all before the worker replies.
  @doc false
  def finish_run(%Group{id: id} = group, pid, generation) when pid == self() do
    reason = disarm(group, pid, generation)
    {slot, slots} = Map.pop(Process.get(@slot_key, %{}), id)
    Process.put(@slot_key, slots)

    case slot do
      {_pid, counters} ->
        if :atomics.get(counters, @slot_children) == 0 do
          :ok = Hyperlang.Scope.priority_cast(__MODULE__, {:finish, id, pid})
          reason
        else
          finish_with_children(id, pid, reason)
        end

      nil ->
        finish_with_children(id, pid, reason)
    end
  end

  defp finish_with_children(id, pid, reason) do
    group_reason = Hyperlang.Scope.priority_call(__MODULE__, {:finish, id, pid})
    if reason == :ok, do: group_reason, else: reason
  end

  @doc "Stop metering `pid` and release its member slot."
  @spec detach(group(), pid()) :: :ok
  def detach(%Group{} = group, pid) when is_pid(pid) do
    _ = complete(group, pid)
    :ok
  end

  @doc """
  Terminate every guest-spawned member of `group`, freeing its spawn slots.
  A child cannot survive the lifetime of the run that owns its accounting.
  """
  @spec detach_children(group()) :: :ok
  def detach_children(%Group{id: id}) do
    ensure_started()
    Hyperlang.Scope.priority_call(__MODULE__, {:detach_children, id})
  end

  @doc false
  @spec heap_flags(pos_integer() | nil) :: map()
  def heap_flags(words) do
    %{size: words, kill: true, error_logger: false, include_shared_binaries: true}
  end

  @doc "Return host-only reduction, throttle and member counters for `group`."
  @spec stat(group()) :: %{
          usage_reductions: non_neg_integer(),
          nr_throttled: non_neg_integer(),
          procs: non_neg_integer(),
          max_procs: non_neg_integer() | nil
        }
  def stat(%Group{id: id}) do
    ensure_started()
    Hyperlang.Scope.priority_call(__MODULE__, {:stat, id})
  catch
    :exit, _ -> empty_stat()
  end

  # Arm `pid`'s ephemeral slot in one call. The first arm of a slot also
  # registers it, and creates a run-owned group that does not exist yet.
  @doc false
  def arm(%Group{id: id, limits: {:process, generation, counters}}, pid, limits)
      when pid == self() do
    normalized = normalize(limits)
    baseline = reductions(pid) || 0

    :atomics.put(counters, @slot_baseline, baseline)
    :atomics.put(counters, @slot_last, baseline)
    :atomics.put(counters, @slot_ceiling, ceiling_cell(normalized.ceiling))
    :atomics.put(counters, @slot_deadline, deadline_cell(normalized.wall_ms))
    :atomics.put(counters, @slot_reason, @reason_none)
    :atomics.put(counters, @slot_children, 0)
    :atomics.put(counters, @slot_max_procs, normalized.max_procs || -1)
    # A caller-supplied kill (an explicit in-caller host run) means the
    # server only records the expiry; the run returns its typed fault.
    :atomics.put(
      counters,
      @slot_record_only,
      if(is_function(value(limits, :kill), 2), do: 1, else: 0)
    )

    :atomics.put(counters, @slot_armed, generation)

    cancel_process_timer()

    if is_integer(normalized.wall_ms) do
      timer =
        :erlang.start_timer(
          normalized.wall_ms,
          Process.whereis(__MODULE__),
          {:process_deadline, id, pid, generation}
        )

      Process.put(@process_timer_key, timer)
    end

    generation
  end

  def arm(%Group{id: id} = group, pid, limits) when is_pid(pid) do
    {counters, registered?} = local_slot(group, pid)
    normalized = normalize(limits)
    generation = :atomics.add_get(counters, @slot_generation, 1)
    baseline = reductions(pid) || 0

    :atomics.put(counters, @slot_baseline, baseline)
    :atomics.put(counters, @slot_last, baseline)
    :atomics.put(counters, @slot_ceiling, ceiling_cell(normalized.ceiling))
    :atomics.put(counters, @slot_deadline, deadline_cell(normalized.wall_ms))
    :atomics.put(counters, @slot_reason, @reason_none)
    :atomics.put(counters, @slot_armed, generation)
    kill = value(limits, :kill)
    kill = if is_function(kill, 2), do: kill, else: &default_kill/2

    case {registered?, group.limits} do
      {true, _limits} ->
        :ok =
          Hyperlang.Scope.priority_call(__MODULE__, {:arm_deadline, id, pid, generation, kill})

      # A run-owned group is created by this request, so nothing can be
      # rejected and the run need not wait for it. The deadline and ceiling
      # are absolute cells in `counters`: a request served late still fires
      # the wall timer at the armed deadline, and the run's later requests
      # (disarm, delete) are ordered behind it.
      {false, {_owner, _limits} = open} ->
        ensure_started()

        :ok =
          Hyperlang.Scope.priority_cast(
            __MODULE__,
            {:arm_slot, id, open, pid, counters, generation, kill}
          )

        Process.put(@slot_key, Map.put(Process.get(@slot_key, %{}), id, {pid, counters}))

      {false, nil} ->
        ensure_started()

        :ok =
          Hyperlang.Scope.priority_call(
            __MODULE__,
            {:arm_slot, id, nil, pid, counters, generation, kill}
          )

        Process.put(@slot_key, Map.put(Process.get(@slot_key, %{}), id, {pid, counters}))
    end

    generation
  end

  # Disarming is local. A wall timer the server may still hold is cancelled
  # asynchronously: a stale timer carries an old generation and its expiry
  # compares against the slot's armed generation, so it can never fire.
  @doc false
  def disarm(%Group{limits: {:process, _generation, counters}}, pid, generation) do
    reason =
      if :atomics.compare_exchange(counters, @slot_armed, generation, 0) == :ok do
        completion_reason(counters, pid)
      else
        decode_reason(:atomics.get(counters, @slot_reason))
      end

    :atomics.put(counters, @slot_deadline, @no_deadline)
    :atomics.put(counters, @slot_ceiling, 0)
    cancel_process_timer()
    reason
  end

  def disarm(%Group{id: id} = group, pid, generation) when is_pid(pid) do
    {counters, _registered?} = local_slot(group, pid)

    reason =
      if :atomics.compare_exchange(counters, @slot_armed, generation, 0) == :ok do
        completion_reason(counters, pid)
      else
        decode_reason(:atomics.get(counters, @slot_reason))
      end

    deadline = :atomics.exchange(counters, @slot_deadline, @no_deadline)
    :atomics.put(counters, @slot_ceiling, 0)

    if deadline != @no_deadline,
      do: Hyperlang.Scope.priority_cast(__MODULE__, {:disarm_deadline, id, pid, generation})

    reason
  end

  @doc false
  def complete(%Group{id: id}, pid) when is_pid(pid) do
    ensure_started()
    Hyperlang.Scope.priority_call(__MODULE__, {:complete, id, pid})
  end

  @impl true
  def init(_opts) do
    Hyperlang.Scope.install_priority_address(__MODULE__)
    Process.flag(:priority, :high)
    schedule_tick()
    {:ok, %{groups: %{}, monitors: %{}, active: MapSet.new()}}
  end

  @impl true
  def handle_call({:group, id, limits}, {owner, _}, state),
    do: {:reply, :ok, create_group(state, id, owner, limits)}

  # The group and its one slot share the owner's monitor: the owner's exit
  # deletes both.
  def handle_call({:process_group, id, counters}, {owner, _}, state) do
    monitor = Process.monitor(owner)

    kill = fn pid, reason ->
      if :atomics.get(counters, @slot_record_only) == 0, do: default_kill(pid, reason)
    end

    slot = %{pid: owner, monitor: monitor, counters: counters, kill: kill, suspended?: false}

    group =
      @no_limits
      |> new_group(now_ms())
      |> Map.merge(%{
        owner: owner,
        owner_monitor: monitor,
        slots: %{owner => slot},
        run: %{counters: counters, generation: 0}
      })

    state = put_in(state, [:monitors, monitor], {id, owner, :group_owner})
    {:reply, :ok, put_group(state, id, group)}
  end

  def handle_call({:arm_slot, id, open, pid, counters, generation, kill}, from, state) do
    state =
      case open do
        # A dead owner's monitor fires at once and deletes the group.
        {owner, limits} when not is_map_key(state.groups, id) ->
          create_group(state, id, owner, limits)

        _ ->
          state
      end

    case handle_call({:slot, id, pid, counters}, from, state) do
      {:reply, :ok, state} -> handle_call({:arm_deadline, id, pid, generation, kill}, from, state)
      reply -> reply
    end
  end

  # The worker's last accounting: its own slot and its children, against
  # the run-level ceiling. The worker leaves the group first, so deleting
  # the group kills only its children.
  def handle_call({:finish, id, pid}, _from, state) do
    case Map.fetch(state.groups, id) do
      :error ->
        {:reply, :ok, state}

      {:ok, group} ->
        group =
          case Map.get(group.slots, pid) do
            nil -> group
            slot -> group |> sample_slot(slot) |> elem(0)
          end

        group =
          Enum.reduce(group.members, group, fn {_pid, member}, acc ->
            member |> sample_member(acc) |> elem(1)
          end)

        ceiling = group_ceiling(group)

        reason =
          if is_integer(ceiling) and group.usage_reductions > ceiling,
            do: {:error, :ceiling},
            else: :ok

        {group, state} = drop_slot(group, state, pid)
        {:reply, reason, state |> put_group(id, group) |> delete_group(id)}
    end
  end

  def handle_call({:delete, id}, _from, state), do: {:reply, :ok, delete_group(state, id)}

  def handle_call({:attach, id, _pid, _opts}, _from, %{groups: groups} = state)
      when not is_map_key(groups, id), do: {:reply, {:error, :closed}, state}

  def handle_call({:slot, id, _pid, _counters}, _from, %{groups: groups} = state)
      when not is_map_key(groups, id), do: {:reply, {:error, :closed}, state}

  def handle_call({:limit, id, _limits}, _from, %{groups: groups} = state)
      when not is_map_key(groups, id), do: {:reply, {:error, :closed}, state}

  def handle_call({:arm_deadline, id, pid, generation, kill}, _from, state) do
    state =
      update_group(state, id, fn group ->
        slot = Map.fetch!(group.slots, pid)
        cancel_deadline(slot)
        deadline = :atomics.get(slot.counters, @slot_deadline)
        timer = start_deadline(id, pid, generation, deadline)

        put_in(
          group,
          [:slots, pid],
          Map.merge(slot, %{timer: timer, generation: generation, kill: kill})
        )
      end)

    {:reply, :ok, state}
  end

  def handle_call({:limit, id, limits}, _from, state) do
    now = now_ms()
    {group, state} = fetch_group(state, id, limits, now)

    members =
      Map.new(group.members, fn {pid, member} ->
        member = %{
          member
          | deadline: member_deadline(member.wall_ms, limits.wall_ms, now),
            ceiling: member_ceiling(member.ceiling_override, limits.ceiling)
        }

        cancel_deadline(member)
        {pid, %{member | timer: start_deadline(id, pid, :durable, member.deadline)}}
      end)

    group =
      maybe_resume(%{
        group
        | limits: limits,
          members: members,
          period_start: now,
          period_usage: 0
      })

    {:reply, :ok, put_group(state, id, group)}
  end

  def handle_call({:attach, id, pid, opts}, _from, state) do
    now = now_ms()
    {group, state} = fetch_group(state, id, @no_limits, now)
    {group, state} = drop_member(group, state, pid)

    # Count a guest child in the run's slots before admitting it, so a run
    # that reads no children after disarming can never miss one.
    if opts.spawned?,
      do:
        Enum.each(group.slots, fn {_pid, slot} ->
          :atomics.add(slot.counters, @slot_children, 1)
        end)

    cond do
      opts.spawned? and not current_run?(group, opts) ->
        {:reply, {:error, :closed}, put_group(state, id, group)}

      opts.spawned? and children_exhausted?(group) ->
        {:reply, {:error, :eagain}, put_group(state, id, group)}

      true ->
        attach_member(state, id, group, pid, opts, now)
    end
  end

  def handle_call({:detach_children, id}, _from, state) do
    case Map.fetch(state.groups, id) do
      :error ->
        {:reply, :ok, state}

      {:ok, group} ->
        {group, state} =
          group.members
          |> Enum.filter(fn {_pid, member} -> member.spawned? end)
          |> Enum.reduce({group, state}, fn {pid, _member}, {group, state} ->
            Process.exit(pid, :kill)
            drop_member(group, state, pid)
          end)

        {:reply, :ok, put_group(state, id, group)}
    end
  end

  def handle_call({:slot, id, pid, counters}, _from, state) do
    now = now_ms()
    {group, state} = fetch_group(state, id, @no_limits, now)
    {group, state} = drop_slot(group, state, pid)
    monitor = Process.monitor(pid)

    slot = %{
      pid: pid,
      monitor: monitor,
      counters: counters,
      kill: &default_kill/2,
      suspended?: false
    }

    group = put_in(group, [:slots, pid], slot)
    state = put_in(state, [:monitors, monitor], {id, pid, :ephemeral})
    {:reply, :ok, put_group(state, id, group)}
  end

  def handle_call({:complete, id, pid}, _from, state) do
    {reason, state} =
      case get_in(state, [:groups, id, :members, pid]) do
        nil ->
          {:ok, state}

        member ->
          {group, state} = pop_in(state, [:groups, id])
          {member, group} = sample_member(member, group)
          reason = durable_reason(member, group)
          {group, state} = drop_member(group, state, pid)
          {reason, put_group(state, id, group)}
      end

    {:reply, reason, state}
  end

  def handle_call({:stat, id}, _from, state) do
    stat =
      case Map.get(state.groups, id) do
        nil ->
          empty_stat()

        group ->
          group
          |> Map.take([:usage_reductions, :nr_throttled])
          |> Map.put(:procs, children(group))
          |> Map.put(:max_procs, group.limits.max_procs)
      end

    {:reply, stat, state}
  end

  @impl true
  def handle_cast({:delete, id}, state), do: {:noreply, delete_group(state, id)}

  def handle_cast({:finish, _id, _pid} = request, state) do
    {:reply, _reason, state} = handle_call(request, nil, state)
    {:noreply, state}
  end

  def handle_cast({:arm_slot, _id, _open, _pid, _counters, _generation, _kill} = request, state) do
    {:reply, _reply, state} = handle_call(request, nil, state)
    {:noreply, state}
  end

  def handle_cast({:disarm_deadline, id, pid, generation}, state),
    do: {:noreply, disarm_deadline(state, id, pid, generation)}

  @impl true
  def handle_info({:timeout, _timer, {:process_deadline, id, pid, generation}}, state) do
    case get_in(state, [:groups, id, :slots, pid]) do
      %{counters: counters} = slot ->
        if :atomics.compare_exchange(counters, @slot_armed, generation, 0) == :ok do
          :atomics.put(counters, @slot_reason, @reason_wall)
          safe_kill(slot.kill, pid, :wall_ms)
        end

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info({:timeout, timer, {:deadline, id, pid, generation}}, state) do
    case Map.get(state.groups, id) do
      nil ->
        :ok

      group ->
        if generation == :durable do
          case Map.get(group.members, pid) do
            %{timer: ^timer} = member -> safe_kill(member.kill, pid, :wall_ms)
            _ -> :ok
          end
        else
          case Map.get(group.slots, pid) do
            %{timer: ^timer, counters: counters} = slot ->
              if :atomics.compare_exchange(counters, @slot_armed, generation, 0) == :ok do
                :atomics.put(counters, @slot_reason, @reason_wall)
                safe_kill(slot.kill, pid, :wall_ms)
              end

            _ ->
              :ok
          end
        end
    end

    {:noreply, state}
  end

  def handle_info(:tick, state) do
    now = now_ms()

    state =
      Enum.reduce(state.active, state, fn id, acc ->
        case Map.get(acc.groups, id) do
          nil ->
            acc

          group ->
            if idle_process_group?(group),
              do: acc,
              else: put_group(acc, id, tick_group(group, now))
        end
      end)

    schedule_tick()
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} ->
        {:noreply, state}

      {{id, ^pid, :durable}, monitors} ->
        state = %{state | monitors: monitors}
        {:noreply, update_group(state, id, &drop_member_without_monitor(&1, pid))}

      {{id, ^pid, :group_owner}, _monitors} ->
        {:noreply, delete_group(state, id)}

      {{id, ^pid, :owner}, monitors} ->
        {:noreply, delete_group(%{state | monitors: monitors}, id)}

      {{id, ^pid, :ephemeral}, monitors} ->
        state = %{state | monitors: monitors}
        {:noreply, update_group(state, id, &drop_slot_without_monitor(&1, pid))}
    end
  end

  def handle_info({:runtime_resume, pid}, state) do
    try do
      :erlang.resume_process(pid)
    rescue
      ArgumentError -> :ok
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Wake at high priority only while idle; see `Hyperlang.Scope.idle_priority/1`.
  defoverridable handle_call: 3, handle_cast: 2, handle_info: 2

  @impl true
  def handle_call(request, from, state),
    do: Hyperlang.Scope.idle_priority(fn -> super(request, from, state) end)

  @impl true
  def handle_cast(request, state),
    do: Hyperlang.Scope.idle_priority(fn -> super(request, state) end)

  @impl true
  def handle_info(message, state),
    do: Hyperlang.Scope.idle_priority(fn -> super(message, state) end)

  defp attach_member(state, id, group, pid, opts, now) do
    monitor = Process.monitor(pid)

    deadline = member_deadline(opts.wall_ms, group.limits.wall_ms, now)

    member = %{
      pid: pid,
      monitor: monitor,
      last: reductions(pid) || 0,
      baseline: reductions(pid) || 0,
      deadline: deadline,
      timer: start_deadline(id, pid, :durable, deadline),
      ceiling: member_ceiling(opts.ceiling, group.limits.ceiling),
      ceiling_override: opts.ceiling,
      wall_ms: opts.wall_ms,
      kill: opts.kill,
      spawned?: opts.spawned?,
      suspended?: false
    }

    group = put_in(group, [:members, pid], member)
    kind = if opts.owner?, do: :owner, else: :durable
    state = put_in(state, [:monitors, monitor], {id, pid, kind})
    {:reply, :ok, put_group(state, id, group)}
  end

  defp tick_group(group, now) do
    {group, rolled_period?} = group |> reset_run() |> maybe_roll_period(now)

    group =
      Enum.reduce(Map.keys(group.members), group, fn pid, acc ->
        case Map.get(acc.members, pid) do
          nil -> acc
          member -> tick_member(acc, member, now)
        end
      end)

    group =
      Enum.reduce(Map.keys(group.slots), group, fn pid, acc ->
        case Map.get(acc.slots, pid) do
          nil -> acc
          slot -> tick_slot(acc, slot, now)
        end
      end)

    if rolled_period?, do: group, else: maybe_throttle(group)
  end

  defp tick_member(group, member, now) do
    {member, group} = sample_member(member, group)
    group = put_in(group, [:members, member.pid], member)

    case durable_reason(member, group, now) do
      :ok -> group
      {:error, reason} -> kill_member(group, member.pid, member.kill, reason)
    end
  end

  defp tick_slot(group, slot, now) do
    counters = slot.counters
    generation = :atomics.get(counters, @slot_armed)

    if generation == 0 do
      group
    else
      {group, current} = sample_slot(group, slot)

      ceiling = group_ceiling(group)

      reason =
        if is_integer(ceiling) and group.usage_reductions > ceiling,
          do: {:error, :ceiling},
          else: slot_reason(counters, current, now)

      case reason do
        :ok ->
          group

        {:error, reason} ->
          if :atomics.compare_exchange(counters, @slot_armed, generation, 0) == :ok do
            :atomics.put(counters, @slot_reason, encode_reason(reason))
            safe_kill(slot.kill, slot.pid, reason)
          end

          group
      end
    end
  end

  defp sample_member(member, group) do
    case reductions(member.pid) do
      current when is_integer(current) and current >= member.last ->
        delta = current - member.last

        {%{member | last: current},
         %{
           group
           | usage_reductions: group.usage_reductions + delta,
             period_usage: group.period_usage + delta
         }}

      _ ->
        {member, group}
    end
  end

  defp sample_slot(group, slot) do
    current = reductions(slot.pid)
    last = :atomics.get(slot.counters, @slot_last)

    if is_integer(current) and current >= last do
      delta = current - last
      :atomics.put(slot.counters, @slot_last, current)

      {%{
         group
         | usage_reductions: group.usage_reductions + delta,
           period_usage: group.period_usage + delta
       }, current}
    else
      {group, current}
    end
  end

  defp maybe_roll_period(%{limits: %{rate: nil}} = group, _now),
    do: {maybe_resume(group), false}

  defp maybe_roll_period(
         %{limits: %{rate: %{period_ms: period}}, period_start: start} = group,
         now
       ) do
    if now - start >= period do
      group =
        group
        |> maybe_resume()
        |> Map.put(:period_start, now)
        |> Map.put(:period_usage, 0)
        |> rebaseline_members()
        |> rebaseline_slots()

      {group, true}
    else
      {group, false}
    end
  end

  defp maybe_throttle(%{limits: %{rate: %{quota: quota}}} = group)
       when is_integer(quota) and quota > 0 do
    if group.period_usage > quota and not group.suspended? do
      each_live(group, fn pid ->
        :erlang.suspend_process(pid)
        Hyperlang.Scope.pause_runtime(pid)
      end)

      %{group | suspended?: true, nr_throttled: group.nr_throttled + 1}
    else
      group
    end
  end

  defp maybe_throttle(group), do: maybe_resume(group)

  defp maybe_resume(%{suspended?: true} = group) do
    each_live(group, fn pid ->
      case Hyperlang.Scope.resume_runtime(pid) do
        :ready -> :erlang.resume_process(pid)
        :queued -> :ok
      end
    end)

    %{group | suspended?: false}
  end

  defp maybe_resume(group), do: group

  defp rebaseline_members(group) do
    members =
      Map.new(group.members, fn {pid, member} ->
        current = reductions(pid) || member.last
        {pid, %{member | last: current, baseline: current, suspended?: false}}
      end)

    %{group | members: members}
  end

  defp rebaseline_slots(group) do
    Enum.each(group.slots, fn {_pid, slot} ->
      if :atomics.get(slot.counters, @slot_armed) != 0 do
        current = reductions(slot.pid) || :atomics.get(slot.counters, @slot_last)
        :atomics.put(slot.counters, @slot_last, current)
      end
    end)

    group
  end

  defp durable_reason(member, group, now \\ now_ms()) do
    cond do
      is_integer(member.deadline) and now >= member.deadline ->
        {:error, :wall_ms}

      is_integer(member.ceiling) and member.last - member.baseline > member.ceiling ->
        {:error, :ceiling}

      is_integer(group_ceiling(group)) and group.usage_reductions > group_ceiling(group) ->
        {:error, :ceiling}

      true ->
        :ok
    end
  end

  defp slot_reason(counters, current, now) do
    deadline = :atomics.get(counters, @slot_deadline)
    ceiling = :atomics.get(counters, @slot_ceiling)
    baseline = :atomics.get(counters, @slot_baseline)

    cond do
      deadline != @no_deadline and now >= deadline -> {:error, :wall_ms}
      ceiling > 0 and is_integer(current) and current - baseline > ceiling -> {:error, :ceiling}
      true -> :ok
    end
  end

  defp completion_reason(counters, pid) do
    case decode_reason(:atomics.get(counters, @slot_reason)) do
      :ok -> slot_reason(counters, reductions(pid), now_ms())
      reason -> reason
    end
  end

  defp kill_member(group, pid, kill, reason) do
    safe_kill(kill, pid, reason)
    group
  end

  defp each_live(group, fun) do
    pids = Map.keys(group.members) ++ Map.keys(group.slots)

    Enum.each(Enum.uniq(pids), fn pid ->
      if Process.alive?(pid) do
        try do
          fun.(pid)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
      end
    end)
  end

  defp safe_kill(kill, pid, reason) do
    kill.(pid, reason)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp default_kill(pid, reason), do: Process.exit(pid, {:hyperlang_limit, reason})

  # The calling process's slot for `group`, and whether the server already
  # holds it. A new slot is registered by the caller's `arm/3` request.
  defp local_slot(%Group{id: id}, pid) do
    case Process.get(@slot_key, %{}) do
      %{^id => {^pid, counters}} ->
        {counters, true}

      _ ->
        counters = :atomics.new(@slot_count, signed: true)
        :atomics.put(counters, @slot_deadline, @no_deadline)
        {counters, false}
    end
  end

  defp disarm_deadline(state, id, pid, generation) do
    update_group(state, id, fn group ->
      case Map.get(group.slots, pid) do
        %{generation: ^generation} = slot ->
          cancel_deadline(slot)
          put_in(group, [:slots, pid, :timer], nil)

        _ ->
          group
      end
    end)
  end

  defp apply_heap_limit(_pid, nil), do: :ok
  defp apply_heap_limit(_pid, :infinity), do: :ok

  defp apply_heap_limit(pid, words) when is_integer(words) and words > 0 do
    heap = heap_flags(words)

    if pid == self() do
      Process.flag(:message_queue_data, :on_heap)
      Process.flag(:max_heap_size, heap)
    else
      :erlang.process_flag(pid, :message_queue_data, :on_heap)
      :erlang.process_flag(pid, :max_heap_size, heap)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp normalize(limits) when is_list(limits), do: limits |> Map.new() |> normalize()

  defp normalize(%{} = limits) do
    if Enum.any?(@obsolete_keys_and_names, &Map.has_key?(limits, &1)) do
      raise ArgumentError, "obsolete limit key; use rate and ceiling"
    end

    %{
      rate: normalize_rate(value(limits, :rate)),
      ceiling: normalize_unbounded(value(limits, :ceiling) || value(limits, :max_reductions)),
      wall_ms: normalize_unbounded(value(limits, :wall_ms)),
      heap_words:
        normalize_unbounded(value(limits, :max_heap_words) || value(limits, :heap_words)),
      max_procs: normalize_max_procs(value(limits, :max_procs))
    }
  end

  defp normalize(_limits), do: normalize(%{})

  defp normalize_member_opts(opts) do
    normalized = normalize(opts)
    kill = value(opts, :kill)

    %{
      wall_ms: normalized.wall_ms,
      heap_words: normalized.heap_words,
      ceiling: normalized.ceiling,
      kill: if(is_function(kill, 2), do: kill, else: &default_kill/2),
      spawned?: value(opts, :spawned?) == true,
      owner?: value(opts, :owner?) == true
    }
  end

  # `max_procs` counts guest-spawned children only, and 0 means "no guest spawn
  # is admitted" — the opposite of the unbounded normalizer's reading of 0.
  defp normalize_max_procs(value) when is_integer(value) and value >= 0, do: value
  defp normalize_max_procs(_value), do: nil

  defp normalize_rate(%{} = rate) do
    quota = value(rate, :quota)
    period = value(rate, :period_ms)

    if is_integer(quota) and quota > 0 and is_integer(period) and period > 0 do
      %{quota: quota, period_ms: period}
    end
  end

  defp normalize_rate({quota, period})
       when is_integer(quota) and quota > 0 and is_integer(period) and period > 0,
       do: %{quota: quota, period_ms: period}

  defp normalize_rate(_rate), do: nil

  defp normalize_unbounded(value) when value in [nil, false, 0, :infinity], do: nil
  defp normalize_unbounded(value) when is_integer(value) and value > 0, do: value
  defp normalize_unbounded(_value), do: nil

  defp value(map, key) when is_map(map) do
    case map do
      %{^key => value} -> value
      _ -> Map.get(map, Atom.to_string(key))
    end
  end

  defp value(list, key) when is_list(list), do: Keyword.get(list, key)
  defp value(_other, _key), do: nil

  defp member_deadline(member_wall, group_wall, now) do
    case member_wall || group_wall do
      wall when is_integer(wall) -> now + wall
      _ -> nil
    end
  end

  defp member_ceiling(member_ceiling, group_ceiling), do: member_ceiling || group_ceiling
  defp ceiling_cell(ceiling) when is_integer(ceiling), do: ceiling
  defp ceiling_cell(_ceiling), do: 0
  defp deadline_cell(wall) when is_integer(wall), do: now_ms() + wall
  defp deadline_cell(_wall), do: @no_deadline
  defp encode_reason(:ceiling), do: @reason_ceiling
  defp encode_reason(:wall_ms), do: @reason_wall
  defp decode_reason(@reason_ceiling), do: {:error, :ceiling}
  defp decode_reason(@reason_wall), do: {:error, :wall_ms}
  defp decode_reason(_reason), do: :ok

  defp children(group), do: Enum.count(group.members, fn {_pid, member} -> member.spawned? end)

  defp children_exhausted?(%{run: %{counters: counters}} = group) do
    case :atomics.get(counters, @slot_max_procs) do
      max when max >= 0 -> children(group) >= max
      _unbounded -> false
    end
  end

  defp children_exhausted?(%{limits: %{max_procs: max}} = group) when is_integer(max),
    do: children(group) >= max

  defp children_exhausted?(_group), do: false

  # A process group's run-level ceiling is its armed run's own ceiling.
  defp group_ceiling(%{run: %{counters: counters}}) do
    case :atomics.get(counters, @slot_ceiling) do
      0 -> nil
      ceiling -> ceiling
    end
  end

  defp group_ceiling(group), do: group.limits.ceiling

  # Between its process's runs a process group has nothing to sample: its
  # slot is disarmed and its children are gone.
  defp idle_process_group?(%{run: %{counters: counters}, members: members}),
    do: map_size(members) == 0 and :atomics.get(counters, @slot_armed) == 0

  defp idle_process_group?(_group), do: false

  # A child joins a process group only while its own run is armed.
  defp current_run?(%{run: %{counters: counters}}, opts),
    do: :atomics.get(counters, @slot_armed) == Map.get(opts, :generation)

  defp current_run?(_group, _opts), do: true

  # A process group's usage belongs to one run: a new armed generation
  # starts from zero.
  defp reset_run(%{run: %{counters: counters, generation: seen} = run} = group) do
    case :atomics.get(counters, @slot_armed) do
      generation when generation != 0 and generation != seen ->
        %{group | usage_reductions: 0, period_usage: 0, run: %{run | generation: generation}}

      _generation ->
        group
    end
  end

  defp reset_run(group), do: group

  defp cancel_process_timer do
    case Process.delete(@process_timer_key) do
      timer when is_reference(timer) -> :erlang.cancel_timer(timer, async: true, info: false)
      _ -> :ok
    end
  end

  defp empty_stat,
    do: %{usage_reductions: 0, nr_throttled: 0, procs: 0, max_procs: nil}

  defp create_group(state, id, owner, limits) do
    monitor = Process.monitor(owner)
    group = Map.merge(new_group(limits, now_ms()), %{owner: owner, owner_monitor: monitor})
    state = put_in(state, [:monitors, monitor], {id, owner, :group_owner})
    put_group(state, id, group)
  end

  defp new_group(limits, now) do
    %{
      limits: limits,
      members: %{},
      slots: %{},
      period_start: now,
      period_usage: 0,
      usage_reductions: 0,
      nr_throttled: 0,
      suspended?: false
    }
  end

  defp fetch_group(state, id, limits, now) do
    case Map.fetch(state.groups, id) do
      {:ok, group} ->
        {group, state}

      :error ->
        group = new_group(limits, now)
        {group, put_group(state, id, group)}
    end
  end

  defp drop_member(group, state, pid) do
    case Map.pop(group.members, pid) do
      {nil, _members} ->
        {group, state}

      {%{monitor: monitor} = member, members} ->
        cancel_deadline(member)
        Process.demonitor(monitor, [:flush])
        {%{group | members: members}, %{state | monitors: Map.delete(state.monitors, monitor)}}
    end
  end

  defp drop_slot(group, state, pid) do
    case Map.pop(group.slots, pid) do
      {nil, _slots} ->
        {group, state}

      {%{monitor: monitor} = slot, slots} ->
        cancel_deadline(slot)
        Process.demonitor(monitor, [:flush])
        {%{group | slots: slots}, %{state | monitors: Map.delete(state.monitors, monitor)}}
    end
  end

  defp drop_member_without_monitor(group, pid) do
    cancel_deadline(Map.get(group.members, pid, %{}))
    %{group | members: Map.delete(group.members, pid)}
  end

  defp drop_slot_without_monitor(group, pid) do
    cancel_deadline(Map.get(group.slots, pid, %{}))
    %{group | slots: Map.delete(group.slots, pid)}
  end

  defp delete_group(state, id) do
    case Map.pop(state.groups, id) do
      {nil, _} ->
        state

      {group, groups} ->
        group = maybe_resume(group)
        entries = Map.values(group.members) ++ Map.values(group.slots)

        Enum.each(entries, fn member ->
          cancel_deadline(member)
          Process.demonitor(member.monitor, [:flush])
          if member.pid != Map.get(group, :owner), do: Process.exit(member.pid, :kill)
        end)

        owner_monitor = Map.get(group, :owner_monitor)
        if owner_monitor, do: Process.demonitor(owner_monitor, [:flush])
        monitors = Map.drop(state.monitors, [owner_monitor | Enum.map(entries, & &1.monitor)])
        %{state | groups: groups, monitors: monitors, active: MapSet.delete(state.active, id)}
    end
  end

  defp start_deadline(_id, _pid, _generation, deadline) when deadline in [nil, @no_deadline],
    do: nil

  defp start_deadline(id, pid, generation, deadline),
    do: :erlang.start_timer(max(0, deadline - now_ms()), self(), {:deadline, id, pid, generation})

  defp cancel_deadline(%{timer: timer}) when is_reference(timer), do: Process.cancel_timer(timer)
  defp cancel_deadline(_), do: :ok

  defp update_group(state, id, fun) do
    case Map.fetch(state.groups, id) do
      {:ok, group} -> put_group(state, id, fun.(group))
      :error -> state
    end
  end

  defp put_group(state, id, group) do
    active =
      if map_size(group.members) + map_size(group.slots) == 0,
        do: MapSet.delete(state.active, id),
        else: MapSet.put(state.active, id)

    %{state | groups: Map.put(state.groups, id, group), active: active}
  end

  defp reductions(pid) do
    case Process.info(pid, :reductions) do
      {:reductions, reductions} -> reductions
      _ -> nil
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case start_link([]) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
    end
  end
end
