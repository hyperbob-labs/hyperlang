defmodule Hyperlang.ContentHashTest do
  use ExUnit.Case, async: false

  @source "result(X) -> {ok, X}."
  @manifest %{terms: %{public: :erlang}, limits: %{max_reductions: 10_000, heap_words: 50_000}}

  test "content, source and manifest hashes do not depend on the node's atom-table order" do
    {:ok, local} = Hyperlang.Test.program(@source, @manifest)

    # Fresh nodes that create every atom of the normalized manifest before
    # Hyperlang loads, once in ascending and once in descending name order.
    # Atom-keyed maps then have different native orders on the two nodes,
    # which plain term_to_binary would encode differently.
    names =
      local.artifact.manifest
      |> atoms()
      |> Enum.uniq()
      |> Enum.map(&Atom.to_string/1)
      |> Enum.sort()

    for order <- [names, Enum.reverse(names)] do
      remote = remote_program(order)
      assert remote.manifest_hash == local.manifest_hash
      assert remote.source_hash == local.source_hash
      assert remote.content_hash == local.content_hash
    end
  end

  defp remote_program(atom_names) do
    paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
    {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io, args: paths})

    try do
      for name <- atom_names, do: :peer.call(peer, :erlang, :binary_to_atom, [name, :utf8])

      # Same application configuration as this node: it is part of the manifest.
      for {key, value} <- Application.get_all_env(:hyperlang),
          do: :peer.call(peer, :application, :set_env, [:hyperlang, key, value])

      {:ok, _apps} = :peer.call(peer, :application, :ensure_all_started, [:hyperlang])
      {:ok, program} = :peer.call(peer, Hyperlang.Test, :program, [@source, @manifest], 60_000)
      program
    after
      :peer.stop(peer)
    end
  end

  defp atoms(term) when is_atom(term), do: [term]
  defp atoms(term) when is_map(term), do: term |> Map.to_list() |> atoms()
  defp atoms(term) when is_list(term), do: Enum.flat_map(term, &atoms/1)
  defp atoms(term) when is_tuple(term), do: term |> Tuple.to_list() |> atoms()
  defp atoms(_term), do: []
end
