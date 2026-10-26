defmodule Hyperlang.Cache do
  @moduledoc false

  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def get_program(key), do: call({:get_program, key})
  def put_program(key, program), do: call({:put_program, key, program})

  def lookup_library(key), do: call({:lookup_library, key})
  def register_library(key, program, budget), do: call({:register_library, key, program, budget})

  @impl true
  def init(_opts) do
    {:ok,
     %{
       programs: %{},
       libraries: %{},
       library_clock: 0
     }}
  end

  @impl true
  def handle_call({:get_program, key}, _from, state) do
    case Map.fetch(state.programs, key) do
      {:ok, program} ->
        {:reply, {:ok, program}, state}

      :error ->
        {:reply, :miss, state}
    end
  end

  def handle_call({:put_program, key, program}, _from, state) do
    case Map.fetch(state.programs, key) do
      {:ok, cached} ->
        {:reply, {:cached, cached}, state}

      :error ->
        {:reply, :ok, put_in(state, [:programs, key], program)}
    end
  end

  def handle_call({:lookup_library, key}, _from, state) do
    case Map.fetch(state.libraries, key) do
      {:ok, entry} ->
        clock = state.library_clock + 1
        state = put_in(%{state | library_clock: clock}, [:libraries, key, :last_used], clock)
        {:reply, {:ok, entry.program}, state}

      :error ->
        {:reply, :miss, state}
    end
  end

  def handle_call({:register_library, key, program, budget}, _from, state) do
    if Map.has_key?(state.libraries, key) do
      {:reply, :ok, state}
    else
      clock = state.library_clock + 1

      state =
        state
        |> put_in([:libraries, key], %{program: program, last_used: clock})
        |> Map.put(:library_clock, clock)
        |> evict_libraries(budget, key)

      {:reply, :ok, state}
    end
  end

  # Eviction is a real release: the evicted program's generated module is
  # purged and its slot returns to the code pool. Without that, an evicted
  # entry would free the cached value while its slot stayed occupied forever.
  defp evict_libraries(state, budget, keep) when is_integer(budget) and budget > 0 do
    excess = map_size(state.libraries) - budget

    victims =
      state.libraries
      |> Enum.reject(fn {key, _entry} -> key == keep end)
      |> Enum.sort_by(fn {_key, entry} -> entry.last_used end)
      |> Enum.take(max(excess, 0))

    Enum.each(victims, fn {_key, entry} ->
      :ok = Hyperlang.CodeServer.release(entry.program.content_hash)
    end)

    %{state | libraries: Map.drop(state.libraries, Enum.map(victims, &elem(&1, 0)))}
  end

  defp evict_libraries(state, _budget, _keep), do: state

  defp call(message) do
    ensure_started()
    GenServer.call(__MODULE__, message, :infinity)
  end

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
