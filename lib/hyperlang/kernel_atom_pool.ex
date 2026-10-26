defmodule Hyperlang.KernelAtomPool do
  @moduledoc false

  # A per-evaluation bridge for an atom whose source name is not present in
  # the receiving artifact. The atoms come from the fixed
  # `hyperlang_kernel_atom_N` family (materialized on first use); guest module
  # traffic can never mint ambient VM atoms.
  @key :"$hyperlang_kernel_atom_pool"

  def clear, do: Process.delete(@key)
  def snapshot, do: Process.get(@key, :undefined)

  def restore(:undefined), do: Process.delete(@key)
  def restore(pool) when is_map(pool), do: Process.put(@key, pool)

  def source(atom) when is_atom(atom) do
    @key
    |> Process.get(%{})
    |> Map.get(:pool_to_source, %{})
    |> Map.get(atom)
  end

  def source(_value), do: nil

  def canonical_atom(source, limit) when is_binary(source) and is_integer(limit) and limit >= 0 do
    limit = min(limit, Hyperlang.GeneratedAtoms.max_kernel_source_atoms())
    pool = Process.get(@key, empty_pool(limit))

    case Map.fetch(pool.source_to_pool, source) do
      {:ok, atom} -> {:ok, atom}
      :error -> allocate(source, pool)
    end
  end

  def canonical_atom(_source, _limit), do: {:error, :kernel_atom_pool_exhausted}

  defp allocate(_source, %{next_index: index, limit: limit}) when index >= limit,
    do: {:error, :kernel_atom_pool_exhausted}

  defp allocate(source, %{next_index: index} = pool) do
    case Hyperlang.GeneratedAtoms.kernel_source_atom(index) do
      {:ok, atom} ->
        Process.put(@key, %{
          pool
          | source_to_pool: Map.put(pool.source_to_pool, source, atom),
            pool_to_source: Map.put(pool.pool_to_source, atom, source),
            next_index: index + 1
        })

        {:ok, atom}

      {:error, :exhausted} ->
        {:error, :kernel_atom_pool_exhausted}

      {:error, :atom_table_reserve} ->
        {:error, :atom_table_reserve}
    end
  end

  defp empty_pool(limit),
    do: %{source_to_pool: %{}, pool_to_source: %{}, next_index: 0, limit: limit}
end
