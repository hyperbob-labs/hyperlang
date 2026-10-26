defmodule Hyperlang.ChannelTypes do
  @moduledoc false

  @handle_free_primitives [
    :atom,
    :binary,
    :bitstring,
    :bool,
    :boolean,
    :byte,
    :bytes,
    :char,
    :float,
    :int,
    :integer,
    nil,
    :none,
    :number,
    :real,
    :string
  ]

  @maybe_types [:any, :dynamic, :term, :chan, :channel]
  @known_names @handle_free_primitives ++
                 @maybe_types ++
                 [
                   :array,
                   :dict,
                   :list,
                   :map,
                   :record,
                   :sequence,
                   :set,
                   :struct,
                   :tuple,
                   :union,
                   :vector
                 ]

  @doc false
  def classify(nil), do: :may_contain_handles

  def classify(:handle_free), do: :handle_free
  def classify(:may_contain_handles), do: :may_contain_handles

  def classify(type) do
    if handle_free_type?(type), do: :handle_free, else: :may_contain_handles
  end

  @doc false
  def handle_free_type?(type), do: do_handle_free_type?(normalize_name(type))

  defp do_handle_free_type?(type) when type in @handle_free_primitives, do: true
  defp do_handle_free_type?(type) when type in @maybe_types, do: false

  defp do_handle_free_type?({kind, element})
       when kind in [:array, :list, :sequence, :set, :vector],
       do: handle_free_type?(element)

  defp do_handle_free_type?({kind, _element}) when kind in [:chan, :channel], do: false

  defp do_handle_free_type?({kind, key, value}) when kind in [:dict, :map],
    do: handle_free_type?(key) and handle_free_type?(value)

  defp do_handle_free_type?({kind, fields}) when kind in [:record, :struct],
    do: handle_free_record_fields?(fields)

  defp do_handle_free_type?({kind, elements}) when kind in [:tuple, :union],
    do: handle_free_elements?(elements)

  defp do_handle_free_type?(%{} = type) do
    kind =
      normalize_name(
        Map.get(type, :type, Map.get(type, "type", Map.get(type, :kind, Map.get(type, "kind"))))
      )

    cond do
      kind in @handle_free_primitives ->
        true

      kind in @maybe_types ->
        false

      kind in [:array, :list, :sequence, :set, :vector] ->
        type
        |> map_value([:element, "element", :elem, "elem", :of, "of"])
        |> handle_free_type?()

      kind in [:dict, :map] ->
        handle_free_type?(map_value(type, [:key, "key", :keys, "keys"])) and
          handle_free_type?(map_value(type, [:value, "value", :values, "values"]))

      kind in [:record, :struct] ->
        handle_free_record_fields?(map_value(type, [:fields, "fields"]))

      kind in [:tuple, :union] ->
        handle_free_elements?(map_value(type, [:elements, "elements", :types, "types"]))

      true ->
        false
    end
  end

  defp do_handle_free_type?(types) when is_list(types), do: handle_free_elements?(types)
  defp do_handle_free_type?(_type), do: false

  defp handle_free_record_fields?(fields) when is_list(fields) do
    Enum.all?(fields, fn
      {_name, field_type} -> handle_free_type?(field_type)
      %{type: field_type} -> handle_free_type?(field_type)
      %{"type" => field_type} -> handle_free_type?(field_type)
      field_type -> handle_free_type?(field_type)
    end)
  end

  defp handle_free_record_fields?(fields) when is_map(fields) do
    fields
    |> Map.values()
    |> handle_free_elements?()
  end

  defp handle_free_record_fields?(_fields), do: false

  defp handle_free_elements?(elements) when is_list(elements),
    do: Enum.all?(elements, &handle_free_type?/1)

  defp handle_free_elements?(_elements), do: false

  defp map_value(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp normalize_name(value) when is_binary(value) do
    normalized =
      value
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]+/, "_")
      |> String.trim("_")

    Enum.find(@known_names, value, &(Atom.to_string(&1) == normalized))
  end

  defp normalize_name(value), do: value
end
