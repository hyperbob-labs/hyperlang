defmodule Hyperlang.Filesystem.Registry do
  @moduledoc false

  use GenServer

  @table :hyperlang_filesystem_registry_handles

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def register(id, pid) when is_reference(id) and is_pid(pid) do
    call({:register, id, pid})
  end

  def lookup(id) when is_reference(id) do
    case :ets.whereis(@table) do
      :undefined ->
        call({:lookup, id})

      table ->
        case :ets.lookup(table, id) do
          [{^id, pid}] when is_pid(pid) ->
            if Process.alive?(pid), do: {:ok, pid}, else: {:error, :filesystem_server_down}

          [] ->
            {:error, :filesystem_server_unknown}
        end
    end
  end

  def lookup(_id), do: {:error, :invalid_filesystem_handle}

  @impl true
  def init(_opts) do
    table = ensure_table()
    :ets.delete_all_objects(table)
    {:ok, %{handles: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:register, id, pid}, _from, state) do
    state = unregister_id(state, id)
    monitor = Process.monitor(pid)

    state = %{
      state
      | handles: Map.put(state.handles, id, {pid, monitor}),
        monitors: Map.put(state.monitors, monitor, id)
    }

    :ets.insert(@table, {id, pid})

    {:reply, :ok, state}
  end

  def handle_call({:lookup, id}, _from, state) do
    reply =
      case Map.fetch(state.handles, id) do
        {:ok, {pid, _monitor}} ->
          if Process.alive?(pid), do: {:ok, pid}, else: {:error, :filesystem_server_down}

        :error ->
          {:error, :filesystem_server_unknown}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, monitor) do
      {:ok, id} ->
        {:noreply, unregister_monitor(state, id, monitor)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # The registry only ever runs under the application supervisor; there is no
  # self-start fallback.
  defp call(message), do: GenServer.call(__MODULE__, message)

  defp unregister_id(state, id) do
    case Map.fetch(state.handles, id) do
      {:ok, {_pid, monitor}} ->
        :ets.delete(@table, id)
        Process.demonitor(monitor, [:flush])
        unregister_monitor(state, id, monitor)

      :error ->
        state
    end
  end

  defp unregister_monitor(state, id, monitor) do
    :ets.delete(@table, id)

    %{
      state
      | handles: Map.delete(state.handles, id),
        monitors: Map.delete(state.monitors, monitor)
    }
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :protected, read_concurrency: true])
      table -> table
    end
  end
end
