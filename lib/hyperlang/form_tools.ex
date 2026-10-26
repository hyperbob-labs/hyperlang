defmodule Hyperlang.FormTools do
  @moduledoc false
  @compile {:no_warn_undefined,
            [
              {:erl_syntax, :arity_qualifier, 2},
              {:erl_syntax, :atom, 1},
              {:erl_syntax, :attribute, 2},
              {:erl_syntax, :form_list, 1},
              {:erl_syntax, :integer, 1},
              {:erl_syntax, :list, 1},
              {:erl_syntax, :revert, 1},
              {:erl_syntax, :revert_forms, 1},
              {:erl_syntax, :type, 1},
              {:erl_syntax_lib, :fold, 3},
              {:erl_prettypr, :format, 1},
              {:merl, :quote, 1}
            ]}

  def module_attribute(module) when is_atom(module) do
    :erl_syntax.attribute(:erl_syntax.atom(:module), [:erl_syntax.atom(module)])
    |> :erl_syntax.revert()
  end

  def export_attribute(exports) when is_list(exports) do
    exports =
      Enum.map(exports, fn {function, arity} ->
        :erl_syntax.arity_qualifier(:erl_syntax.atom(function), :erl_syntax.integer(arity))
      end)

    :erl_syntax.attribute(:erl_syntax.atom(:export), [:erl_syntax.list(exports)])
    |> :erl_syntax.revert()
  end

  def ensure_revertible(forms) when is_list(forms) do
    forms
    |> :erl_syntax.form_list()
    |> :erl_syntax.revert_forms()

    :ok
  catch
    _class, reason ->
      {:error,
       Hyperlang.Error.new(:generated_form_verify, "generated forms are not revertible",
         details: %{reason: inspect(reason)}
       )}
  end

  def node_types(forms) when is_list(forms) do
    forms
    |> :erl_syntax.form_list()
    |> then(fn tree ->
      :erl_syntax_lib.fold(fn node, acc -> [:erl_syntax.type(node) | acc] end, [], tree)
    end)
    |> Enum.reverse()
  end

  def format_forms(forms) when is_list(forms) do
    forms
    |> :erl_syntax.form_list()
    |> :erl_prettypr.format()
    |> IO.iodata_to_binary()
  end

  def opaque_quote!(source) when is_binary(source) do
    source
    |> String.to_charlist()
    |> :merl.quote()
  end
end
