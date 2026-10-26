defmodule Hyperlang.Error do
  @moduledoc false

  defexception [:category, :message, :span, :details]

  def new(category, message, opts \\ []) do
    %{
      category: Hyperlang.Fault.public_category(category),
      message: message,
      span: Keyword.get(opts, :span),
      details: Keyword.get(opts, :details, %{})
    }
  end

  def normalize(%__MODULE__{} = error) do
    %{
      category: Hyperlang.Fault.public_category(error.category),
      message: error.message,
      span: error.span,
      details: error.details || %{}
    }
  end

  def normalize(%{category: category, message: message} = error) do
    %{
      category: Hyperlang.Fault.public_category(category),
      message: message,
      span: Map.get(error, :span),
      details: Map.get(error, :details, %{})
    }
  end

  def normalize({category, message}) when is_atom(category) do
    new(category, inspect(message))
  end

  def normalize(error) do
    new(:internal, inspect(error))
  end
end
