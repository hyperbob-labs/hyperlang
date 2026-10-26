defmodule Hyperlang.Consult do
  @moduledoc false

  def parse(source, ctx) when is_binary(source) do
    with {:ok, terms} <- Hyperlang.OtpFrontend.parse_consult_terms(source, ctx.manifest) do
      eval_terms(terms, ctx)
    end
  end

  def parse(_source, _ctx), do: {:error, :badarg}

  defp eval_terms(terms, ctx) do
    Enum.reduce_while(terms, {:ok, []}, fn term, {:ok, acc} ->
      case eval_term(term, ctx) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp eval_term(%{node: :int, value: value}, _ctx), do: {:ok, value}
  defp eval_term(%{node: :float, value: value}, _ctx), do: {:ok, value}
  defp eval_term(%{node: :bool, value: value}, _ctx), do: {:ok, value}
  defp eval_term(%{node: :string, value: value}, _ctx), do: {:ok, String.to_charlist(value)}

  defp eval_term(%{node: :atom, value: value}, ctx), do: source_atom(value, ctx)

  defp eval_term(%{node: :tuple, items: items}, ctx) do
    with {:ok, items} <- eval_term_list(items, ctx) do
      {:ok, List.to_tuple(items)}
    end
  end

  defp eval_term(%{node: :list, items: items}, ctx), do: eval_term_list(items, ctx)

  defp eval_term(%{node: :cons, head: head, tail: tail}, ctx) do
    with {:ok, head} <- eval_term(head, ctx),
         {:ok, tail} <- eval_term(tail, ctx) do
      {:ok, [head | tail]}
    end
  end

  defp eval_term(%{node: :map, fields: fields}, ctx) do
    Enum.reduce_while(fields, {:ok, %{}}, fn %{key: key, value: value}, {:ok, acc} ->
      with {:ok, key} <- eval_term(key, ctx),
           {:ok, value} <- eval_term(value, ctx) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp eval_term(%{node: :binary, parts: parts}, ctx) do
    Enum.reduce_while(parts, {:ok, <<>>}, fn part, {:ok, acc} ->
      case eval_binary_part(part, ctx) do
        {:ok, bytes} -> {:cont, {:ok, <<acc::binary, bytes::binary>>}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp eval_term(_term, _ctx), do: {:error, :badarg}

  defp eval_term_list(items, ctx) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case eval_term(item, ctx) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp eval_binary_part(%{node: :bit_segment, expr: expr, size: :default, types: types}, ctx) do
    cond do
      binary_segment?(types) ->
        with {:ok, value} <- eval_term(expr, ctx),
             true <- is_binary(value) do
          {:ok, value}
        else
          _ -> {:error, :badarg}
        end

      utf8_segment?(types) ->
        with {:ok, value} <- eval_term(expr, ctx),
             true <- is_integer(value),
             binary when is_binary(binary) <- :unicode.characters_to_binary([value]) do
          {:ok, binary}
        else
          _ -> {:error, :badarg}
        end

      match?(%{node: :string}, expr) ->
        eval_term(expr, ctx)
        |> case do
          {:ok, chars} when is_list(chars) -> {:ok, :unicode.characters_to_binary(chars)}
          _ -> {:error, :badarg}
        end

      true ->
        with {:ok, value} <- eval_term(expr, ctx),
             true <- is_integer(value) and value >= 0 and value <= 255 do
          {:ok, <<value>>}
        else
          _ -> {:error, :badarg}
        end
    end
  end

  defp eval_binary_part(_part, _ctx), do: {:error, :badarg}

  defp binary_segment?(types), do: segment_type?(types, "binary")
  defp utf8_segment?(types), do: segment_type?(types, "utf8")

  defp segment_type?(:default, _type), do: false

  defp segment_type?(types, type) when is_list(types) do
    Enum.any?(types, fn
      ^type -> true
      {^type, _value} -> true
      _other -> false
    end)
  end

  defp segment_type?(_types, _type), do: false

  defp source_atom(source, ctx) when is_binary(source) do
    source_to_pool =
      ctx
      |> Map.get(:atom_pool, %{})
      |> Map.new(fn {pool, source} -> {source, pool} end)

    cond do
      atom = Map.get(source_to_pool, source) ->
        {:ok, atom}

      atom = Enum.find(ctx.terms.allowed_atoms, &(Atom.to_string(&1) == source)) ->
        {:ok, atom}

      true ->
        {:error, :eoverflow}
    end
  end
end
