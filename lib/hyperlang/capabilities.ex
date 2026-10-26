defmodule Hyperlang.Capabilities do
  @moduledoc false

  def derive(%{core: %{calls: calls}}) do
    initial = %{stdlib: [], facades: [], code: [], modules: []}

    calls
    |> Enum.reduce(initial, fn
      {:stdlib, module, function, arity}, acc ->
        %{acc | stdlib: [{module, function, arity} | acc.stdlib]}

      {:filesystem, module, function, arity}, acc ->
        %{acc | facades: [{module, function, arity} | acc.facades]}

      {:table, module, function, arity}, acc ->
        %{acc | facades: [{module, function, arity} | acc.facades]}

      {:code, module, function, arity}, acc ->
        %{acc | code: [{module, function, arity} | acc.code]}

      {:code_path, module, _function, _arity}, acc ->
        %{acc | modules: [module | acc.modules]}

      _call, acc ->
        acc
    end)
    |> Map.new(fn {key, values} -> {key, values |> Enum.uniq() |> Enum.sort()} end)
  end
end
