defmodule Hyperlang.Fault do
  @moduledoc false

  @public_categories [
    :api,
    :busy,
    :code_pool,
    :codegen,
    :compile,
    :compile_budget,
    :compile_timeout,
    :eval,
    :export,
    :filesystem,
    :generated_form_verify,
    :heap,
    :import,
    :input,
    :internal,
    :internal_compile,
    :lexer,
    :lifecycle,
    :load,
    :manifest,
    :module,
    :output,
    :parse,
    :reduction_watchdog,
    :runtime,
    :sandbox_crash,
    :source,
    :stdlib,
    :stdout,
    :timeout,
    :verify
  ]

  @public_category_set MapSet.new(@public_categories)
  @public_category_names Map.new(@public_categories, &{Atom.to_string(&1), &1})

  @internal_boundary_categories [
    :docs,
    :error,
    :filesystem_args,
    :filesystem_return,
    :import_args,
    :import_return,
    :stdlib_args,
    :stdlib_return,
    :table
  ]

  @internal_boundary_category_set MapSet.new(@internal_boundary_categories)
  @internal_boundary_category_names Map.new(
                                      @internal_boundary_categories,
                                      &{Atom.to_string(&1), &1}
                                    )

  def public_categories, do: @public_categories

  def public_category?(category) when is_atom(category),
    do: MapSet.member?(@public_category_set, category)

  def public_category?(category) when is_binary(category),
    do: Map.has_key?(@public_category_names, category)

  def public_category?(_category), do: false

  def public_category(category) when is_atom(category) do
    if public_category?(category), do: category, else: :internal
  end

  def public_category(category) when is_binary(category),
    do: Map.get(@public_category_names, category, :internal)

  def public_category(_category), do: :internal

  def internal_boundary_categories, do: @internal_boundary_categories

  def internal_boundary_category?(category) when is_atom(category),
    do: MapSet.member?(@internal_boundary_category_set, category)

  def internal_boundary_category?(category) when is_binary(category),
    do: Map.has_key?(@internal_boundary_category_names, category)

  def internal_boundary_category?(_category), do: false
end
