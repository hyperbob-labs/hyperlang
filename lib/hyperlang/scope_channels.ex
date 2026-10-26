defmodule Hyperlang.Scope.Channels do
  @moduledoc false
  use GenServer
  @table :hyperlang_scope_channels

  def init_table do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])
  end

  # A controller of a quiet scope hibernates: an idle actor's own scope keeps
  # only the controller's live state resident.
  def start(server, id, generation, control, policy) do
    GenServer.start(__MODULE__, {server, id, generation, control, policy},
      spawn_opt: [priority: :low],
      hibernate_after: 1_000
    )
  end

  def close(id, pid) do
    :ets.match_delete(@table, {id, pid, :_})
    GenServer.cast(pid, :close)
  end

  def snapshot(id) do
    case lookup(id) do
      {_pid, snapshot} -> snapshot
      nil -> empty()
    end
  end

  defp lookup(id) do
    case :ets.lookup(@table, id) do
      [{^id, pid, snapshot}] -> {pid, snapshot}
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  def request(id, owner, request) do
    case lookup(id) do
      {pid, snapshot} ->
        await_request(pid, snapshot.control, request)

      nil ->
        :ok = Hyperlang.Scope.ensure(id, owner)

        case lookup(id) do
          {pid, snapshot} -> await_request(pid, snapshot.control, request)
          nil -> {:error, :channel_quota_exceeded}
        end
    end
  end

  def try_request(id, owner, request) do
    case address(id) do
      nil ->
        :ok = Hyperlang.Scope.ensure(id, owner)
        call(address(id), request)

      pid ->
        call(pid, request)
    end
  end

  def await(id) do
    case lookup(id) do
      {_pid, snapshot} -> await_control(snapshot.control)
      nil -> :ok
    end
  end

  defp await_control(control) do
    case :atomics.get(control, 1) do
      0 ->
        :ok

      1 ->
        Hyperlang.Scope.blocking(fn -> Process.sleep(1) end)
        await_control(control)

      _ ->
        {:error, :channel_quota_exceeded}
    end
  end

  defp await_request(pid, control, request) do
    case :atomics.get(control, 1) do
      0 ->
        case call(pid, request) do
          :retry -> await_request(pid, control, request)
          reply -> reply
        end

      1 ->
        Hyperlang.Scope.blocking(fn -> Process.sleep(1) end)
        await_request(pid, control, request)

      _ ->
        {:error, :channel_quota_exceeded}
    end
  end

  def uncharge(id, broker) do
    case address(id) do
      nil -> :ok
      pid -> call(pid, {:uncharge, broker})
    end
  end

  def release_startchan(id, handle) do
    case address(id) do
      nil -> :ok
      pid -> call(pid, {:release_startchan, handle})
    end
  end

  def address(id) do
    case :ets.lookup(@table, id) do
      [{^id, pid, _}] -> pid
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp call(nil, _), do: {:error, :channel_quota_exceeded}

  defp call(pid, request) do
    try do
      GenServer.call(pid, request)
    catch
      :exit, {:noproc, _} -> {:error, :channel_quota_exceeded}
      :exit, {:normal, _} -> {:error, :channel_quota_exceeded}
    end
  end

  @impl true
  def init({server, id, generation, control, policy}) do
    state = %{
      server: server,
      server_ref: Process.monitor(server),
      id: id,
      generation: generation,
      control: control,
      policy: policy,
      members: %{},
      refs: %{},
      starts: MapSet.new(),
      slots: 0,
      cpu: 0,
      growth: 0,
      gcs: 0,
      heap: 0,
      core_sampled_at: nil,
      armed?: false
    }

    :ets.insert(@table, {id, self(), counts(state)})
    {:ok, state}
  end

  @impl true
  def handle_call(request, from, state) do
    state = %{state | policy: Hyperlang.Scope.policy(state.id)}
    {:reductions, before} = Process.info(self(), :reductions)
    {:reply, reply, state} = handle_request(request, from, state)
    {:reductions, after_r} = Process.info(self(), :reductions)
    cost = if elem(request, 0) == :configure or reply == :retry, do: 0, else: after_r - before
    {:reply, reply, publish(%{state | cpu: state.cpu + cost})}
  end

  defp handle_request({:configure, policy}, _from, state) do
    Process.flag(:priority, if(policy.priority == :latency, do: :normal, else: :low))
    {:reply, :ok, %{state | policy: policy}}
  end

  defp handle_request({:channels, channels}, _from, state) do
    channels = Map.new(channels) |> Map.drop(Map.keys(state.members))
    slots = Enum.sum(Map.values(channels))

    cond do
      :atomics.get(state.control, 1) == 1 ->
        {:reply, :retry, state}

      :atomics.get(state.control, 1) >= 2 or
        map_size(state.members) + MapSet.size(state.starts) + map_size(channels) >
          state.policy.max_channels or
          state.slots + slots > state.policy.max_buffer_slots ->
        {:reply, {:error, :channel_quota_exceeded}, state}

      true ->
        state =
          Enum.reduce(channels, state, fn {pid, size}, acc ->
            ref = Process.monitor(pid)
            reading = read_member(pid)
            member = Map.merge(reading, %{pid: pid, size: size, monitor: ref, suspended?: false})

            %{
              acc
              | members: Map.put(acc.members, pid, member),
                refs: Map.put(acc.refs, ref, pid),
                slots: acc.slots + size,
                heap: acc.heap + reading.memory_words,
                growth: acc.growth + reading.heap
            }
          end)

        {:reply, :ok, state |> activate() |> publish()}
    end
  end

  defp handle_request({:uncharge, pid}, _from, state),
    do: {:reply, :ok, state |> drop(pid) |> activate() |> publish()}

  defp handle_request({:startchan, handle}, _from, state) do
    cond do
      :atomics.get(state.control, 1) == 1 ->
        {:reply, :retry, state}

      :atomics.get(state.control, 1) >= 2 or
          map_size(state.members) + MapSet.size(state.starts) >= state.policy.max_channels ->
        {:reply, {:error, :channel_quota_exceeded}, state}

      true ->
        {:reply, :ok, publish(%{state | starts: MapSet.put(state.starts, handle)})}
    end
  end

  defp handle_request({:release_startchan, handle}, _from, state),
    do: {:reply, :ok, publish(%{state | starts: MapSet.delete(state.starts, handle)})}

  @impl true
  def handle_cast(:close, state), do: {:stop, :normal, state}

  @impl true
  def handle_info({:registry_work, reductions, _recycle?}, state) do
    {:noreply, state |> Map.update!(:cpu, &(&1 + reductions)) |> activate() |> publish()}
  end

  def handle_info({:policy, policy}, state) do
    Process.flag(:priority, if(policy.priority == :latency, do: :normal, else: :low))
    {:noreply, %{state | policy: policy}}
  end

  def handle_info(:sample_channels, state) do
    state = %{state | armed?: false, policy: Hyperlang.Scope.policy(state.id)}

    recent? =
      is_integer(state.core_sampled_at) and
        System.monotonic_time(:microsecond) - state.core_sampled_at <
          state.policy.sample_ms * 1000

    state = if recent?, do: state, else: sample_channels(state)
    state = publish(state)

    if :atomics.get(state.control, 1) < 2 and
         (state.policy.rate != nil or state.policy.churn != nil or
            (not recent? and state.heap > state.policy.heap_words)) do
      send(state.server, {:channel_sampled, state.id, state.generation})
    end

    state =
      if map_size(state.members) > 0 and :atomics.get(state.control, 1) < 2,
        do: state |> activate() |> publish(),
        else: state

    {:noreply, state}
  end

  def handle_info({:priority, priority}, state) do
    Process.flag(:priority, priority)
    {:noreply, state}
  end

  def handle_info({:sample, workers}, state) do
    readings = Map.new(workers, fn {pid, ref} -> {pid, {ref, read_member(pid)}} end)
    state = sample_channels(state)
    state = publish(%{state | core_sampled_at: System.monotonic_time(:microsecond)})
    send(state.server, {:sampled, state.id, state.generation, readings})
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _}, %{server_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    case state.refs[ref] do
      nil -> {:noreply, state}
      pid -> {:noreply, state |> drop(pid) |> activate() |> publish()}
    end
  end

  @impl true
  def terminate(_, state) do
    Enum.each(state.members, fn {_, member} -> resume(member) end)

    try do
      :ets.match_delete(@table, {state.id, self(), :_})
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  defp drop(state, pid) do
    state = sample_member(state, pid)

    case Map.pop(state.members, pid) do
      {nil, _} ->
        state

      {member, members} ->
        resume(member)
        Process.demonitor(member.monitor, [:flush])

        %{
          state
          | members: members,
            refs: Map.delete(state.refs, member.monitor),
            slots: state.slots - member.size,
            heap: state.heap - member.memory_words
        }
    end
  end

  defp resume(%{suspended?: true, pid: pid}) do
    try do
      :erlang.resume_process(pid)
    rescue
      ArgumentError -> :ok
    end
  end

  defp resume(_), do: :ok

  defp sample_member(state, pid) do
    case state.members[pid] do
      nil ->
        state

      old ->
        current = read_member(pid)

        if current.reductions >= old.reductions do
          gc = max(0, current.gcs - old.gcs)
          growth = max(0, current.heap - old.heap) + gc * current.heap

          %{
            state
            | members: Map.put(state.members, pid, Map.merge(old, current)),
              cpu: state.cpu + current.reductions - old.reductions,
              growth: state.growth + growth,
              gcs: state.gcs + gc,
              heap: state.heap + current.memory_words - old.memory_words
          }
        else
          state
        end
    end
  end

  defp sample_channels(state),
    do: Enum.reduce(Map.keys(state.members), state, &sample_member(&2, &1))

  defp activate(%{armed?: true} = state), do: state

  defp activate(state) do
    Process.send_after(self(), :sample_channels, state.policy.sample_ms)
    %{state | armed?: true}
  end

  # The counters row is keyed by scope and owned by this controller's pid.
  # Publication replaces only a row this controller still owns: once the
  # scope is closed, or its name reused by another controller, a late
  # publication cannot revive the row.
  defp publish(state) do
    id = state.id
    row = {id, self(), counts(state)}
    :ets.select_replace(@table, [{{id, self(), :_}, [], [{:const, row}]}])
    state
  end

  defp counts(state) do
    %{
      channels: map_size(state.members),
      buffer_slots: state.slots,
      heap: state.heap,
      cpu: state.cpu,
      control: state.control,
      growth: state.growth,
      gcs: state.gcs,
      active?: state.armed?
    }
  end

  defp empty,
    do: %{channels: 0, buffer_slots: 0, heap: 0, cpu: 0, growth: 0, gcs: 0, active?: false}

  defp read_member(pid) do
    case Process.info(pid, [:reductions, :total_heap_size, :garbage_collection, :memory]) do
      nil ->
        %{reductions: 0, heap: 0, gcs: 0, memory_words: 0}

      info ->
        %{
          reductions: info[:reductions],
          heap: info[:total_heap_size],
          gcs: Keyword.get(info[:garbage_collection], :minor_gcs, 0),
          memory_words:
            max(info[:total_heap_size], div(info[:memory], :erlang.system_info(:wordsize)))
        }
    end
  end
end
