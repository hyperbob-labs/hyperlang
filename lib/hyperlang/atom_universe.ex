defmodule Hyperlang.AtomUniverse do
  @moduledoc false

  use GenServer

  def start_link(opts \\ []) do
    case GenServer.start_link(__MODULE__, opts, name: __MODULE__) do
      {:error, {:already_started, pid}} when is_pid(pid) ->
        if Process.alive?(pid), do: Process.link(pid)
        {:ok, pid}

      other ->
        other
    end
  end

  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case GenServer.start(__MODULE__, [], name: __MODULE__) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _pid ->
        :ok
    end
  end

  def reserve(universe_id, sources) when is_list(sources) do
    ensure_started()
    GenServer.call(__MODULE__, {:reserve, normalize_id(universe_id), normalize_sources(sources)})
  end

  def pool_to_source(universe_id) do
    ensure_started()
    GenServer.call(__MODULE__, {:pool_to_source, normalize_id(universe_id)})
  end

  def source_for_atom(universe_id, atom) when is_atom(atom) do
    ensure_started()
    GenServer.call(__MODULE__, {:source_for_atom, normalize_id(universe_id), atom})
  end

  def source_for_atom(_universe_id, _atom), do: nil

  @impl true
  def init(_opts) do
    :ok = Hyperlang.GeneratedAtoms.init_inflight()
    {:ok, %{universes: %{}}}
  end

  @impl true
  def handle_call({:reserve, nil, _sources}, _from, state),
    do: {:reply, {:error, :missing_atom_universe}, state}

  def handle_call({:reserve, universe_id, sources}, _from, state) do
    universe = Map.get(state.universes, universe_id, empty_universe())

    case reserve_sources(universe, sources) do
      {:ok, universe, source_to_pool} ->
        state = put_in(state, [:universes, universe_id], universe)
        {:reply, {:ok, source_to_pool, subset_pool_to_source(source_to_pool)}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:pool_to_source, nil}, _from, state), do: {:reply, %{}, state}

  def handle_call({:pool_to_source, universe_id}, _from, state) do
    pool =
      state.universes
      |> Map.get(universe_id, empty_universe())
      |> Map.fetch!(:pool_to_source)

    {:reply, pool, state}
  end

  def handle_call({:source_for_atom, nil, _atom}, _from, state), do: {:reply, nil, state}

  def handle_call({:source_for_atom, universe_id, atom}, _from, state) do
    source =
      state.universes
      |> Map.get(universe_id, empty_universe())
      |> Map.fetch!(:pool_to_source)
      |> Map.get(atom)

    {:reply, source, state}
  end

  defp reserve_sources(universe, sources) do
    Enum.reduce_while(sources, {:ok, universe, %{}}, fn source, {:ok, universe, acc} ->
      case Map.fetch(universe.source_to_pool, source) do
        {:ok, atom} ->
          {:cont, {:ok, universe, Map.put(acc, source, atom)}}

        :error ->
          case next_atom(universe.next) do
            {:ok, atom} ->
              universe = %{
                source_to_pool: Map.put(universe.source_to_pool, source, atom),
                pool_to_source: Map.put(universe.pool_to_source, atom, source),
                next: universe.next + 1
              }

              {:cont, {:ok, universe, Map.put(acc, source, atom)}}

            {:error, :exhausted} ->
              {:halt, {:error, :atom_universe_exhausted}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp next_atom(index), do: Hyperlang.GeneratedAtoms.source_atom(index)

  defp subset_pool_to_source(source_to_pool) do
    Map.new(source_to_pool, fn {source, atom} -> {atom, source} end)
  end

  defp empty_universe, do: %{source_to_pool: %{}, pool_to_source: %{}, next: 0}

  defp normalize_sources(sources) do
    sources
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp normalize_id(nil), do: nil
  defp normalize_id(id), do: id
end
