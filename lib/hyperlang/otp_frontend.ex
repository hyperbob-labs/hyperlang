defmodule Hyperlang.OtpFrontend do
  @moduledoc false

  @safe_scan :hyperlang_otp_scan
  @safe_parse :hyperlang_otp_parse

  @empty_module_metadata %{
    vsn: nil,
    moduledoc: nil,
    docs: %{},
    specs: %{},
    callbacks: %{},
    behaviours: []
  }

  def parse(source, manifest) when is_binary(source) do
    try do
      with :ok <- check_source_limits(source, manifest.limits),
           {:ok, tokens0} <- scan(source),
           {:ok, tokens} <- expand_module_macro(tokens0),
           :ok <- check_token_limit(tokens, manifest.limits),
           :ok <- check_token_metrics(tokens, manifest),
           {:ok, ast} <- parse_tokens(tokens, manifest),
           :ok <- check_ast_limit(ast, manifest.limits) do
        {:ok, ast}
      end
    catch
      {:hyperlang_frontend_error, error} -> {:error, error}
    end
  end

  def frontend, do: :otp_derived

  def source_module_names(source, manifest) when is_binary(source) do
    with :ok <- check_source_limits(source, manifest.limits),
         {:ok, tokens0} <- scan(source),
         {:ok, tokens} <- expand_module_macro(tokens0),
         :ok <- check_token_limit(tokens, manifest.limits),
         :ok <- check_token_metrics(tokens, manifest) do
      tokens
      |> split_forms()
      |> Enum.reduce_while({:ok, []}, fn segment, {:ok, names} ->
        case @safe_parse.parse_form(normalize_form_tokens(segment)) do
          {:ok, {:attribute, _anno, :module, module}} ->
            {:cont, {:ok, [source_name(module) | names]}}

          {:ok, _other} ->
            {:cont, {:ok, names}}

          {:error, error} ->
            {:halt, {:error, parse_error(error)}}
        end
      end)
      |> case do
        {:ok, names} -> {:ok, Enum.reverse(names)}
        {:error, error} -> {:error, error}
      end
    end
  catch
    {:hyperlang_frontend_error, error} -> {:error, error}
  end

  def source_export_names(source, manifest) when is_binary(source) do
    with :ok <- check_source_limits(source, manifest.limits),
         {:ok, tokens0} <- scan(source),
         {:ok, tokens} <- expand_module_macro(tokens0),
         :ok <- check_token_limit(tokens, manifest.limits),
         :ok <- check_token_metrics(tokens, manifest) do
      tokens
      |> split_forms()
      |> Enum.reduce_while({:ok, []}, fn segment, {:ok, exports} ->
        case @safe_parse.parse_form(normalize_form_tokens(segment)) do
          {:ok, {:attribute, _anno, :export, list}} when is_list(list) ->
            entries =
              Enum.flat_map(list, fn
                {name, arity} when is_integer(arity) and arity >= 0 ->
                  [{source_name(name), arity}]

                _other ->
                  []
              end)

            {:cont, {:ok, exports ++ entries}}

          {:ok, _other} ->
            {:cont, {:ok, exports}}

          {:error, error} ->
            {:halt, {:error, parse_error(error)}}
        end
      end)
    end
  catch
    {:hyperlang_frontend_error, error} -> {:error, error}
  end

  def source_export_names(_source, _manifest),
    do: {:error, Hyperlang.Error.new(:parse, "source must be a binary")}

  # Module metadata (vsn/moduledoc/docs/specs/callbacks/behaviours) without
  # requiring any function definitions — behaviour-contract modules carry
  # only attributes, and `code:get_doc/1` still documents them.
  def source_module_metadata(source, manifest) when is_binary(source) do
    try do
      with :ok <- check_source_limits(source, manifest.limits),
           {:ok, tokens0} <- scan(source),
           {:ok, tokens} <- expand_module_macro(tokens0),
           :ok <- check_token_limit(tokens, manifest.limits),
           :ok <- check_token_metrics(tokens, manifest) do
        acc = reduce_function_segments(split_forms(tokens), manifest)
        {:ok, acc.meta}
      end
    catch
      {:hyperlang_frontend_error, error} -> {:error, error}
    end
  end

  def source_module_metadata(_source, _manifest),
    do: {:error, Hyperlang.Error.new(:parse, "source must be a binary")}

  # The safe scanner emits atom values as binaries, so the vendored parser's
  # special handling for `-spec`/`-callback` (keyword rewrite) and for
  # `-doc hidden` / `-moduledoc false` (boolean/hidden literals) never fires.
  # Normalize just those leading tokens before parse_form; expression parsing
  # always receives the original tokens.
  defp normalize_form_tokens([{:-, a1}, {:atom, a2, name} | rest])
       when name in ["spec", "callback"] do
    [{:-, a1}, {:atom, a2, String.to_existing_atom(name)} | rest]
  end

  defp normalize_form_tokens([{:-, _a1}, {:atom, _a2, name} | _rest] = segment)
       when name in ["doc", "moduledoc"] do
    [minus, attr | rest] = segment
    [minus, attr | Enum.map(rest, &normalize_doc_value_token/1)]
  end

  defp normalize_form_tokens(segment), do: segment

  defp normalize_doc_value_token({:atom, anno, name}) when name in ["hidden", "false", "true"],
    do: {:atom, anno, String.to_existing_atom(name)}

  defp normalize_doc_value_token(token), do: token

  def parse_consult_terms(source, manifest) when is_binary(source) do
    try do
      with :ok <- check_source_limits(source, manifest.limits),
           {:ok, tokens} <- scan(source),
           :ok <- check_token_limit(tokens, manifest.limits),
           :ok <- check_token_metrics(tokens, manifest) do
        segments = split_forms(tokens)

        cond do
          segments == [] ->
            {:ok, []}

          length(segments) > manifest.limits.max_forms ->
            {:error, Hyperlang.Error.new(:parse, "form count exceeds limit")}

          true ->
            with {:ok, terms} <- parse_consult_segments(segments),
                 :ok <- check_ast_limit(%{terms: terms}, manifest.limits) do
              {:ok, terms}
            end
        end
      end
    catch
      {:hyperlang_frontend_error, error} -> {:error, error}
    end
  end

  def parse_consult_terms(_source, _manifest),
    do: {:error, Hyperlang.Error.new(:parse, "consult source must be a binary")}

  defp parse_consult_segments(segments) do
    Enum.reduce_while(segments, {:ok, []}, fn tokens, {:ok, acc} ->
      case @safe_parse.parse_exprs(tokens) do
        {:ok, [expr]} ->
          {:cont, {:ok, [convert_expr(expr) | acc]}}

        {:ok, _exprs} ->
          {:halt, {:error, Hyperlang.Error.new(:parse, "consult form must contain one term")}}

        {:error, error} ->
          {:halt, {:error, parse_error(error)}}
      end
    end)
    |> case do
      {:ok, terms} -> {:ok, Enum.reverse(terms)}
      error -> error
    end
  end

  defp check_source_limits(source, limits) do
    cond do
      byte_size(source) > limits.max_source_bytes ->
        {:error, Hyperlang.Error.new(:lexer, "source byte size exceeds limit")}

      count_lines(source) > limits.max_line_count ->
        {:error, Hyperlang.Error.new(:lexer, "source line count exceeds limit")}

      true ->
        :ok
    end
  end

  defp count_lines(source), do: source |> :binary.matches("\n") |> length() |> Kernel.+(1)

  defp scan(source) do
    try do
      source
      |> String.to_charlist()
      |> @safe_scan.string({1, 1}, [:text])
      |> case do
        {:ok, tokens, _end_location} -> {:ok, tokens}
        {:error, error_info, _location} -> {:error, scan_error(error_info)}
      end
    catch
      class, reason ->
        {:error,
         Hyperlang.Error.new(:lexer, "OTP-derived scanner failed",
           details: %{class: class, reason: inspect(reason)}
         )}
    end
  end

  defp scan_error({location, module, description}) do
    message =
      description
      |> scanner_error_text(module)
      |> maybe_add_scanner_hint(description)

    Hyperlang.Error.new(:lexer, "scanner failed at #{format_location(location)}: #{message}",
      span: span(location)
    )
  end

  defp scan_error(other), do: Hyperlang.Error.new(:lexer, inspect(other))

  defp scanner_error_text(description, module) when is_atom(module) do
    rendered =
      if function_exported?(module, :format_error, 1),
        do: module.format_error(description),
        else: description

    unicode_binary!(rendered, :lexer)
  end

  defp scanner_error_text(description, _module), do: unicode_binary!(description, :lexer)

  defp maybe_add_scanner_hint(message, {:unterminated, :string, _head}),
    do: message <> " - check for a stray backslash before a closing quote"

  defp maybe_add_scanner_hint(message, _description), do: message

  defp format_location({line, col}), do: "line #{line}, column #{col}"
  defp format_location(line) when is_integer(line), do: "line #{line}"
  defp format_location(_location), do: "unknown location"

  defp expand_module_macro(tokens) do
    case source_module_name_from_tokens(tokens) do
      nil -> {:ok, tokens}
      module -> {:ok, do_expand_module_macro(tokens, module)}
    end
  end

  defp source_module_name_from_tokens(tokens) do
    tokens
    |> split_forms()
    |> Enum.find_value(fn
      [
        {:-, _},
        {:atom, _, name},
        {:"(", _},
        {:atom, _, module},
        {:")", _},
        {:dot, _}
      ]
      when name in ["module", :module] ->
        source_name(module)

      _segment ->
        nil
    end)
  end

  defp do_expand_module_macro([{:"?", anno}, {:var, _var_anno, name} | rest], module)
       when name in ["MODULE", :MODULE] do
    [
      {:atom, Keyword.put(anno, :text, String.to_charlist(module)), module}
      | do_expand_module_macro(rest, module)
    ]
  end

  defp do_expand_module_macro([token | rest], module),
    do: [token | do_expand_module_macro(rest, module)]

  defp do_expand_module_macro([], _module), do: []

  defp check_token_limit(tokens, limits) do
    if length(tokens) <= limits.max_tokens do
      :ok
    else
      {:error, Hyperlang.Error.new(:lexer, "token count exceeds limit")}
    end
  end

  defp check_token_metrics(tokens, manifest) do
    limits = manifest.limits

    initial = %{
      literal_bytes: 0,
      nesting_depth: 0,
      max_nesting_depth: 0
    }

    Enum.reduce_while(tokens, {:ok, initial}, fn token, {:ok, metrics} ->
      metrics = update_nesting_metrics(metrics, token)

      with :ok <- check_nesting_depth(metrics, token, limits),
           :ok <- check_integer_digits(token, limits),
           {:ok, metrics} <- check_literal_bytes(metrics, token, limits) do
        {:cont, {:ok, metrics}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, _metrics} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp check_nesting_depth(%{max_nesting_depth: depth}, token, limits) do
    if within_limit?(depth, limits.max_nesting_depth) do
      :ok
    else
      {:error,
       Hyperlang.Error.new(:lexer, "nesting depth exceeds limit",
         span: token_span(token),
         details: %{limit: limits.max_nesting_depth}
       )}
    end
  end

  defp check_integer_digits({:integer, _anno, _value} = token, limits) do
    digits = token |> token_text() |> integer_digit_count()

    if within_limit?(digits, limits.max_integer_digits) do
      :ok
    else
      {:error,
       Hyperlang.Error.new(:lexer, "integer digit count exceeds limit",
         span: token_span(token),
         details: %{limit: limits.max_integer_digits}
       )}
    end
  end

  defp check_integer_digits(_token, _limits), do: :ok

  defp check_literal_bytes(metrics, token, limits) do
    literal_bytes = metrics.literal_bytes + literal_byte_size(token)

    if within_limit?(literal_bytes, limits.max_literal_bytes) do
      {:ok, %{metrics | literal_bytes: literal_bytes}}
    else
      {:error,
       Hyperlang.Error.new(:lexer, "literal byte count exceeds limit",
         span: token_span(token),
         details: %{limit: limits.max_literal_bytes}
       )}
    end
  end

  defp update_nesting_metrics(metrics, token) do
    depth =
      case nesting_delta(token) do
        :open -> metrics.nesting_depth + 1
        :close -> max(metrics.nesting_depth - 1, 0)
        :none -> metrics.nesting_depth
      end

    %{metrics | nesting_depth: depth, max_nesting_depth: max(metrics.max_nesting_depth, depth)}
  end

  defp nesting_delta({kind, _anno})
       when kind in [:"(", :"[", :"{", :"<<", :case, :if, :try, :fun, :begin],
       do: :open

  defp nesting_delta({kind, _anno}) when kind in [:")", :"]", :"}", :">>", :end], do: :close
  defp nesting_delta(_token), do: :none

  defp literal_byte_size({:string, _anno, value}), do: byte_size(unicode_binary!(value, :lexer))
  defp literal_byte_size({:atom, _anno, value}), do: byte_size(source_name(value))
  defp literal_byte_size({:integer, _anno, _value} = token), do: byte_size(token_text(token))
  defp literal_byte_size({:float, _anno, _value} = token), do: byte_size(token_text(token))
  defp literal_byte_size({:char, _anno, _value}), do: 1
  defp literal_byte_size(_token), do: 0

  defp integer_digit_count(text) do
    text
    |> String.split("#", parts: 2)
    |> List.last()
    |> String.replace(~r/[^0-9A-Za-z]/, "")
    |> String.length()
  end

  defp token_text({_kind, anno, _value}), do: anno_text(anno)

  defp anno_text(anno) when is_list(anno) do
    anno
    |> Keyword.get(:text, [])
    |> unicode_binary!(:lexer)
  end

  defp anno_text(_anno), do: ""

  defp token_span({_kind, anno, _value}), do: span_from_anno(anno)
  defp token_span({_kind, anno}), do: span_from_anno(anno)

  defp within_limit?(_value, nil), do: true
  defp within_limit?(value, limit), do: value <= limit

  defp parse_tokens(tokens, manifest) do
    segments = split_forms(tokens)

    result =
      cond do
        segments == [] ->
          {:error, Hyperlang.Error.new(:parse, "empty source")}

        length(segments) > manifest.limits.max_forms ->
          {:error, Hyperlang.Error.new(:parse, "form count exceeds limit")}

        length(segments) == 1 ->
          parse_single_segment(hd(segments), manifest)

        true ->
          parse_function_segments(segments, manifest)
      end

    attach_source_contract(result, segments)
  end

  defp attach_source_contract({:ok, ast}, segments) do
    module_form? = module_attribute_present?(segments)
    attrs = source_contract_attributes(segments)

    contract =
      %{
        module_form: module_form?,
        synthetic_module: not module_form?
      }
      |> maybe_put_source_contract(:module, source_module_name_from_segments(segments))
      |> maybe_put_source_contract(:exports, attrs.exports)
      |> maybe_put_source_contract(:behaviours, attrs.behaviours)

    {:ok, Map.put(ast, :source_contract, contract)}
  end

  defp attach_source_contract(other, _segments), do: other

  defp maybe_put_source_contract(contract, _key, []), do: contract
  defp maybe_put_source_contract(contract, _key, nil), do: contract
  defp maybe_put_source_contract(contract, key, value), do: Map.put(contract, key, value)

  # The own-module name (resolution tier 1): recorded on the source contract so the classifier can dispatch
  # own-module remote calls to local functions.
  defp source_module_name_from_segments(segments) do
    Enum.find_value(segments, fn
      [
        {:-, _},
        {:atom, _, name},
        {:"(", _},
        {:atom, _, module},
        {:")", _},
        {:dot, _}
      ]
      when name in ["module", :module] ->
        source_name(module)

      _segment ->
        nil
    end)
  end

  defp source_contract_attributes(segments) do
    Enum.reduce(segments, %{exports: [], behaviours: []}, fn segment, acc ->
      case @safe_parse.parse_form(segment) do
        {:ok, {:attribute, _anno, :export, list}} when is_list(list) ->
          exports =
            Enum.flat_map(list, fn
              {name, arity} when is_integer(arity) and arity >= 0 ->
                [{source_name(name), arity}]

              _other ->
                []
            end)

          %{acc | exports: acc.exports ++ exports}

        {:ok, {:attribute, _anno, name, value}}
        when name in ["behaviour", "behavior", :behaviour, :behavior] ->
          %{acc | behaviours: acc.behaviours ++ [source_name(value)]}

        _other ->
          acc
      end
    end)
  end

  defp module_attribute_present?(segments) do
    Enum.any?(segments, fn
      [{:-, _}, {:atom, _anno, "module"} | _] -> true
      [{:-, _}, {:atom, _anno, :module} | _] -> true
      _ -> false
    end)
  end

  defp check_ast_limit(ast, limits) do
    if ast_node_count(ast) <= limits.max_ast_nodes do
      :ok
    else
      {:error, Hyperlang.Error.new(:parse, "AST node count exceeds limit")}
    end
  end

  defp ast_node_count(%{} = map) do
    map
    |> Map.values()
    |> Enum.reduce(if(Map.has_key?(map, :node), do: 1, else: 0), &(&2 + ast_node_count(&1)))
  end

  defp ast_node_count(list) when is_list(list),
    do: Enum.reduce(list, 0, &(&2 + ast_node_count(&1)))

  defp ast_node_count(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> ast_node_count()

  defp ast_node_count(_), do: 0

  defp split_forms(tokens) do
    {segments, current} =
      Enum.reduce(tokens, {[], []}, fn token, {segments, current} ->
        current = [token | current]

        if dot?(token) do
          {[Enum.reverse(current) | segments], []}
        else
          {segments, current}
        end
      end)

    segments =
      if current == [] do
        segments
      else
        [Enum.reverse(current) | segments]
      end

    Enum.reverse(segments)
  end

  defp parse_single_segment(tokens, manifest) do
    case @safe_parse.parse_form(normalize_form_tokens(tokens)) do
      {:ok, {:function, _anno, _name, _arity, _clauses} = form} ->
        {:ok, %{type: :function_program, functions: [convert_function(form)]}}

      {:ok, {:attribute, _, _, _} = attr} ->
        case attribute_action(attr, manifest) do
          {:error, error} -> {:error, error}
          _accepted -> {:error, Hyperlang.Error.new(:parse, "source contains no functions")}
        end

      {:error, error} ->
        case nested_function_clause_error(tokens, error) do
          {:ok, error} -> {:error, error}
          :error -> parse_expression_segment(tokens)
        end
    end
  end

  defp parse_function_segments(segments, manifest) do
    acc = reduce_function_segments(segments, manifest)
    functions = Enum.reverse(acc.functions)

    if functions == [] do
      {:error, Hyperlang.Error.new(:parse, "source contains no functions")}
    else
      ast = %{type: :function_program, functions: functions, records: Enum.reverse(acc.records)}
      {:ok, maybe_put_module_metadata(ast, acc.meta)}
    end
  end

  defp reduce_function_segments(segments, manifest) do
    initial = %{functions: [], records: [], meta: @empty_module_metadata, pending_doc: nil}

    Enum.reduce(segments, initial, fn tokens, acc ->
      case @safe_parse.parse_form(normalize_form_tokens(tokens)) do
        {:ok, {:function, _anno, name, arity, _clauses} = form} ->
          %{
            acc
            | functions: [convert_function(form) | acc.functions],
              meta: attach_function_doc(acc.meta, acc.pending_doc, source_name(name), arity),
              pending_doc: nil
          }

        {:ok, {:attribute, _, _, _} = attr} ->
          case attr do
            {:attribute, _, :record, {name, fields}} ->
              %{acc | records: [convert_record_definition(name, fields) | acc.records]}

            _ ->
              case attribute_action(attr, manifest) do
                :ignore -> acc
                {:collect, collect} -> %{acc | meta: collect.(acc.meta)}
                {:pending_doc, doc} -> %{acc | pending_doc: doc}
                {:error, error} -> throw({:hyperlang_frontend_error, error})
              end
          end

        {:ok, other} ->
          throw(
            {:hyperlang_frontend_error,
             Hyperlang.Error.new(:parse, "unsupported top-level form",
               details: %{form: inspect(other)}
             )}
          )

        {:error, error} ->
          throw({:hyperlang_frontend_error, parse_error(error)})
      end
    end)
  end

  defp convert_record_definition(name, fields) do
    %{name: source_name(name), fields: Enum.map(fields, &convert_record_definition_field/1)}
  end

  defp convert_record_definition_field({:typed_record_field, field, _type}),
    do: convert_record_definition_field(field)

  defp convert_record_definition_field({:record_field, _anno, {:atom, _, name}}),
    do: %{name: source_name(name), default: nil}

  defp convert_record_definition_field({:record_field, _anno, {:atom, _, name}, default}),
    do: %{name: source_name(name), default: convert_expr(default)}

  defp attach_function_doc(meta, nil, _name, _arity), do: meta

  defp attach_function_doc(meta, doc, name, arity),
    do: %{meta | docs: Map.put(meta.docs, {name, arity}, doc)}

  defp maybe_put_module_metadata(ast, meta) when meta == @empty_module_metadata, do: ast
  defp maybe_put_module_metadata(ast, meta), do: Map.put(ast, :module_metadata, meta)

  defp parse_expression_segment(tokens) do
    case @safe_parse.parse_exprs(tokens) do
      {:ok, exprs} -> {:ok, %{type: :expression_bundle, expr: body_expr(exprs)}}
      {:error, error} -> {:error, parse_error(error)}
    end
  end

  defp attribute_action({:attribute, _anno, :module, _value} = attr, manifest) do
    if manifest.syntax.inert_module_attributes do
      :ignore
    else
      {:error, attribute_error(attr)}
    end
  end

  defp attribute_action({:attribute, _anno, :export, _value} = attr, manifest) do
    if manifest.syntax.inert_export_attributes do
      :ignore
    else
      {:error, attribute_error(attr)}
    end
  end

  defp attribute_action({:attribute, _anno, name, value} = attr, _manifest)
       when name in ["behaviour", "behavior", :behaviour, :behavior] do
    if is_binary(value) or is_atom(value) do
      behaviour = source_name(value)
      {:collect, fn meta -> %{meta | behaviours: meta.behaviours ++ [behaviour]} end}
    else
      {:error, attribute_error(attr)}
    end
  end

  defp attribute_action({:attribute, _anno, name, value}, _manifest)
       when name in ["vsn", :vsn] do
    {:collect, fn meta -> %{meta | vsn: value} end}
  end

  defp attribute_action({:attribute, _anno, :moduledoc, value} = attr, _manifest) do
    case doc_value(value) do
      {:ok, doc} -> {:collect, fn meta -> %{meta | moduledoc: doc} end}
      :error -> {:error, attribute_error(attr)}
    end
  end

  defp attribute_action({:attribute, _anno, :doc, value} = attr, _manifest) do
    case doc_value(value) do
      {:ok, doc} -> {:pending_doc, doc}
      :error -> {:error, attribute_error(attr)}
    end
  end

  defp attribute_action({:attribute, _anno, :spec, spec} = attr, _manifest) do
    case spec_key(spec) do
      {:ok, key, types} ->
        entry = %{raw: types, profile: spec_profile(types)}
        {:collect, fn meta -> %{meta | specs: Map.put(meta.specs, key, entry)} end}

      :error ->
        {:error, attribute_error(attr)}
    end
  end

  defp attribute_action({:attribute, _anno, :callback, spec} = attr, _manifest) do
    case spec_key(spec) do
      {:ok, key, types} ->
        entry = %{raw: types, profile: spec_profile(types)}
        {:collect, fn meta -> %{meta | callbacks: Map.put(meta.callbacks, key, entry)} end}

      :error ->
        {:error, attribute_error(attr)}
    end
  end

  defp attribute_action({:attribute, _anno, name, _value}, _manifest)
       when name in ["optional_callbacks", :optional_callbacks] do
    :ignore
  end

  defp attribute_action(attr, _manifest), do: {:error, attribute_error(attr)}

  defp doc_value(value) when is_binary(value), do: {:ok, value}
  defp doc_value(value) when is_list(value), do: {:ok, unicode_binary!(value, :parse)}
  defp doc_value(value) when value in [:hidden, false], do: {:ok, :hidden}
  defp doc_value(_value), do: :error

  defp spec_key({{name, arity}, types}) when is_integer(arity) and arity >= 0,
    do: {:ok, {source_name(name), arity}, types}

  defp spec_key({{_module, name, arity}, types}) when is_integer(arity) and arity >= 0,
    do: {:ok, {source_name(name), arity}, types}

  defp spec_key(_spec), do: :error

  # Coarse per-argument/return boundary profile derived from a -spec: each
  # position collapses to one of :binary, :integer, :float, :atom, :boolean,
  # :list, :map, :tuple, or :term (unions and unknown types are :term).
  defp spec_profile(types) do
    types
    |> Enum.map(&fun_type_profile/1)
    |> Enum.reduce(:empty, fn
      profile, :empty -> profile
      _profile, nil -> nil
      profile, acc -> merge_fun_profiles(acc, profile)
    end)
    |> case do
      :empty -> nil
      profile -> profile
    end
  end

  defp fun_type_profile({:type, _anno, :bounded_fun, [fun | _constraints]}),
    do: fun_type_profile(fun)

  defp fun_type_profile({:type, _anno, :fun, [{:type, _panno, :product, args}, return]}),
    do: %{args: Enum.map(args, &coarse_type/1), return: coarse_type(return)}

  defp fun_type_profile(_type), do: nil

  defp merge_fun_profiles(_acc, nil), do: nil

  defp merge_fun_profiles(%{args: args_a, return: return_a}, %{args: args_b, return: return_b})
       when length(args_a) == length(args_b) do
    %{
      args: Enum.zip_with(args_a, args_b, &merge_coarse_types/2),
      return: merge_coarse_types(return_a, return_b)
    }
  end

  defp merge_fun_profiles(_acc, _profile), do: nil

  defp merge_coarse_types(type, type), do: type
  defp merge_coarse_types(_left, _right), do: :term

  defp coarse_type({:ann_type, _anno, [_var, type]}), do: coarse_type(type)
  defp coarse_type({:type, _anno, name, _args}), do: coarse_type_name(source_name(name))

  defp coarse_type({:atom, _anno, value}) when value in [true, false, "true", "false"],
    do: :boolean

  defp coarse_type({:atom, _anno, _value}), do: :atom
  defp coarse_type({:integer, _anno, _value}), do: :integer
  defp coarse_type({:char, _anno, _value}), do: :integer
  defp coarse_type({:op, _anno, _op, _expr}), do: :integer
  defp coarse_type({:op, _anno, _op, _left, _right}), do: :integer
  defp coarse_type(_type), do: :term

  defp coarse_type_name(name)
       when name in ["binary", "bitstring", "nonempty_binary", "nonempty_bitstring"],
       do: :binary

  defp coarse_type_name(name)
       when name in [
              "integer",
              "non_neg_integer",
              "pos_integer",
              "neg_integer",
              "byte",
              "char",
              "arity",
              "range"
            ],
       do: :integer

  defp coarse_type_name("float"), do: :float
  defp coarse_type_name(name) when name in ["atom", "module", "node"], do: :atom
  defp coarse_type_name("boolean"), do: :boolean

  defp coarse_type_name(name)
       when name in [
              "list",
              "nonempty_list",
              "maybe_improper_list",
              "nonempty_improper_list",
              "nonempty_maybe_improper_list",
              "string",
              "nonempty_string",
              "nil",
              "iolist"
            ],
       do: :list

  defp coarse_type_name("map"), do: :map
  defp coarse_type_name(name) when name in ["tuple", "mfa"], do: :tuple
  defp coarse_type_name(_name), do: :term

  defp attribute_error({:attribute, anno, name, _value}) do
    Hyperlang.Error.new(:parse, "source attribute #{inspect_name(name)} is not supported",
      span: span_from_anno(anno)
    )
  end

  defp convert_function({:function, anno, name, arity, clauses}) do
    %{
      node: :function,
      name: source_name(name),
      arity: arity,
      span: span_from_anno(anno),
      clauses: Enum.map(clauses, &convert_clause/1)
    }
  end

  defp convert_clause({:clause, _anno, patterns, guards, body}) do
    %{
      patterns: Enum.map(patterns, &convert_pattern/1),
      guard: convert_guard(guards),
      body: body_expr(body)
    }
  end

  defp body_expr([single]), do: convert_expr(single)

  defp body_expr(exprs) when is_list(exprs),
    do: %{node: :block, exprs: Enum.map(exprs, &convert_expr/1)}

  defp convert_guard([]), do: nil

  defp convert_guard(guards) when is_list(guards) do
    guards
    |> Enum.map(fn sequence ->
      sequence
      |> Enum.map(&convert_expr/1)
      |> combine_guard_sequence()
    end)
    |> combine_guard_alternatives()
  end

  defp combine_guard_sequence([single]), do: single

  defp combine_guard_sequence([left | rest]) do
    Enum.reduce(rest, left, fn right, acc ->
      %{node: :binary_op, op: "andalso", left: acc, right: right}
    end)
  end

  defp combine_guard_alternatives([single]), do: single

  defp combine_guard_alternatives([left | rest]) do
    Enum.reduce(rest, left, fn right, acc ->
      %{node: :binary_op, op: "orelse", left: acc, right: right}
    end)
  end

  defp convert_pattern({:var, _anno, "_"}), do: %{node: :wild_pattern}
  defp convert_pattern({:var, _anno, :_}), do: %{node: :wild_pattern}
  defp convert_pattern({:var, _anno, name}), do: %{node: :var_pattern, name: source_name(name)}

  defp convert_pattern({:match, _anno, left, right}) do
    %{node: :alias_pattern, left: convert_pattern(left), right: convert_pattern(right)}
  end

  defp convert_pattern({:tuple, _anno, items}),
    do: %{node: :tuple_pattern, items: Enum.map(items, &convert_pattern/1)}

  defp convert_pattern({:cons, _anno, _head, _tail} = list) do
    case proper_list_items(list) do
      {:ok, items} -> %{node: :list_pattern, items: Enum.map(items, &convert_pattern/1)}
      :error -> convert_cons_pattern(list)
    end
  end

  defp convert_pattern({nil, _anno}), do: %{node: :list_pattern, items: []}

  defp convert_pattern({:map, _anno, fields}) do
    %{
      node: :map_pattern,
      fields:
        Enum.map(fields, fn
          {:map_field_exact, _anno, key, value} ->
            %{key: convert_expr(key), value: convert_pattern(value)}

          {:map_field_assoc, _anno, _key, _value} ->
            unsupported!("map patterns must use := syntax")
        end)
    }
  end

  defp convert_pattern({:record, _anno, name, fields}) do
    %{
      node: :record_pattern,
      name: source_name(name),
      fields: Enum.map(fields, &convert_record_pattern_field/1)
    }
  end

  defp convert_pattern({:bin, _anno, elements}) do
    %{node: :binary, parts: Enum.map(elements, &convert_bin_element(&1, :pattern))}
  end

  defp convert_pattern(literal), do: %{node: :literal_pattern, literal: convert_expr(literal)}

  defp convert_record_pattern_field({:record_field, _anno, {:atom, _, name}, value}),
    do: %{name: source_name(name), value: convert_pattern(value)}

  defp convert_record_pattern_field({:record_field, _anno, {:var, _, "_"}, value}),
    do: %{name: "_", value: convert_pattern(value)}

  defp convert_expr({:integer, _anno, value}), do: %{node: :int, value: value}
  defp convert_expr({:float, _anno, value}), do: %{node: :float, value: value}
  defp convert_expr({:char, _anno, value}), do: %{node: :int, value: value}

  defp convert_expr({:string, _anno, value}),
    do: %{node: :string, value: unicode_binary!(value, :parse)}

  defp convert_expr({:atom, _anno, "true"}), do: %{node: :bool, value: true}
  defp convert_expr({:atom, _anno, "false"}), do: %{node: :bool, value: false}
  defp convert_expr({:atom, _anno, value}), do: %{node: :atom, value: source_name(value)}
  defp convert_expr({:var, _anno, "_"}), do: unsupported!("wildcard expression is not supported")
  defp convert_expr({:var, _anno, :_}), do: unsupported!("wildcard expression is not supported")
  defp convert_expr({:var, _anno, value}), do: %{node: :var, name: source_name(value)}
  defp convert_expr({nil, _anno}), do: %{node: :list, items: []}

  defp convert_expr({:cons, _anno, _head, _tail} = list) do
    case proper_list_items(list) do
      {:ok, items} -> %{node: :list, items: Enum.map(items, &convert_expr/1)}
      :error -> convert_cons_expr(list)
    end
  end

  defp convert_expr({:tuple, _anno, items}),
    do: %{node: :tuple, items: Enum.map(items, &convert_expr/1)}

  defp convert_expr({:map, _anno, fields}) when is_list(fields) do
    %{
      node: :map,
      fields:
        Enum.map(fields, fn
          {:map_field_assoc, _anno, key, value} ->
            %{op: "=>", key: convert_expr(key), value: convert_expr(value)}

          {:map_field_exact, _anno, key, value} ->
            %{op: ":=", key: convert_expr(key), value: convert_expr(value)}
        end)
    }
  end

  defp convert_expr({:map, _anno, base, fields}) when is_list(fields) do
    %{
      node: :map_update,
      base: convert_expr(base),
      fields:
        Enum.map(fields, fn
          {:map_field_exact, _anno, key, value} ->
            %{op: ":=", key: convert_expr(key), value: convert_expr(value)}

          {:map_field_assoc, _anno, key, value} ->
            %{op: "=>", key: convert_expr(key), value: convert_expr(value)}
        end)
    }
  end

  defp convert_expr({:record, _anno, name, fields}) when is_list(fields) do
    %{
      node: :record_create,
      name: source_name(name),
      fields: Enum.map(fields, &convert_record_field/1)
    }
  end

  defp convert_expr({:record, _anno, base, name, fields}) when is_list(fields) do
    %{
      node: :record_update,
      base: convert_expr(base),
      name: source_name(name),
      fields: Enum.map(fields, &convert_record_field/1)
    }
  end

  defp convert_expr({:record_field, _anno, base, name, {:atom, _, field}}) do
    %{
      node: :record_access,
      base: convert_expr(base),
      name: source_name(name),
      field: source_name(field)
    }
  end

  defp convert_expr({:record_index, _anno, name, {:atom, _, field}}) do
    %{node: :record_index, name: source_name(name), field: source_name(field)}
  end

  defp convert_expr({:bin, _anno, elements}) do
    %{node: :binary, parts: Enum.map(elements, &convert_bin_element(&1, :expr))}
  end

  defp convert_expr({:match, _anno, left, right}),
    do: %{node: :match, pattern: convert_match_pattern(left), expr: convert_expr(right)}

  defp convert_expr({:block, _anno, exprs}),
    do: %{node: :block, exprs: Enum.map(exprs, &convert_expr/1)}

  defp convert_expr({:op, _anno, :!, left, right}),
    do: %{node: :send, target: convert_expr(left), message: convert_expr(right)}

  defp convert_expr({:op, _anno, op, left, right}),
    do: %{
      node: :binary_op,
      op: source_name(op),
      left: convert_expr(left),
      right: convert_expr(right)
    }

  defp convert_expr({:op, _anno, op, expr}),
    do: %{node: :unary, op: source_name(op), expr: convert_expr(expr)}

  defp convert_expr(
         {:call, _anno, {:atom, _fa, fun},
          [
            {:atom, _ia, item},
            {:atom, _ra, record}
          ]}
       )
       when fun in [:record_info, "record_info"],
       do: %{node: :record_info, item: source_name(item), name: source_name(record)}

  defp convert_expr({:call, _anno, {:atom, _fa, fun}, args}),
    do: %{node: :local_call, function: source_name(fun), args: Enum.map(args, &convert_expr/1)}

  defp convert_expr({:call, _anno, {:remote, _ra, {:atom, _ma, mod}, {:atom, _fa, fun}}, args}) do
    %{
      node: :remote_call,
      module: source_name(mod),
      function: source_name(fun),
      args: Enum.map(args, &convert_expr/1)
    }
  end

  defp convert_expr({:call, _anno, {:remote, _ra, mod, {:atom, _fa, fun}}, args}) do
    %{
      node: :dynamic_remote_call,
      module: convert_expr(mod),
      function: source_name(fun),
      args: Enum.map(args, &convert_expr/1)
    }
  end

  defp convert_expr({:call, _anno, {:remote, _ra, _mod, _fun}, args}),
    do: %{node: :dynamic_remote_call, args: Enum.map(args, &convert_expr/1)}

  defp convert_expr({:call, _anno, callee, args}),
    do: %{node: :fun_call, callee: convert_expr(callee), args: Enum.map(args, &convert_expr/1)}

  defp convert_expr({:case, _anno, expr, clauses}),
    do: %{node: :case, expr: convert_expr(expr), clauses: Enum.map(clauses, &convert_clause/1)}

  defp convert_expr({:receive, _anno, clauses}),
    do: %{node: :receive, clauses: Enum.map(clauses, &convert_clause/1)}

  defp convert_expr({:receive, _anno, clauses, timeout, body}),
    do: %{
      node: :receive,
      clauses: Enum.map(clauses, &convert_clause/1),
      timeout: convert_expr(timeout),
      after_body: body_expr(body)
    }

  defp convert_expr({:if, _anno, clauses}),
    do: %{node: :if, clauses: Enum.map(clauses, &convert_if_clause/1)}

  defp convert_expr({:fun, _anno, {:clauses, clauses}}),
    do: %{node: :fun, clauses: Enum.map(clauses, &convert_clause/1)}

  defp convert_expr({:named_fun, _anno, name, clauses}),
    do: %{
      node: :named_fun,
      name: source_name(name),
      clauses: Enum.map(clauses, &convert_clause/1)
    }

  defp convert_expr({:fun, _anno, {:function, name, arity}})
       when is_integer(arity),
       do: %{node: :local_fun_ref, function: source_name(name), arity: arity}

  defp convert_expr({:fun, _anno, _external}),
    do: %{node: :external_fun}

  defp convert_expr({:try, _anno, _body, _of_clauses, _catch_clauses, after_body})
       when after_body != [],
       do: unsupported!("try-after clauses are not supported in v1")

  defp convert_expr({:try, _anno, body, of_clauses, catch_clauses, []}),
    do: %{
      node: :try,
      body: body_expr(body),
      of_clauses: Enum.map(of_clauses, &convert_clause/1),
      catch_clauses: Enum.map(catch_clauses, &convert_catch_clause/1)
    }

  defp convert_expr({:lc, _anno, expr, qualifiers}) do
    %{
      node: :list_comp,
      expr: convert_expr(expr),
      qualifiers: Enum.map(qualifiers, &convert_qualifier/1)
    }
  end

  defp convert_expr({:mc, _anno, {:map_field_assoc, _field_anno, key, value}, qualifiers}) do
    %{
      node: :map_comp,
      key: convert_expr(key),
      value: convert_expr(value),
      qualifiers: Enum.map(qualifiers, &convert_qualifier/1)
    }
  end

  defp convert_expr({:mc, _anno, _expr, _qualifiers}),
    do: unsupported!("map comprehensions must use => fields")

  defp convert_expr({:bc, _anno, expr, qualifiers}) do
    %{
      node: :binary_comp,
      expr: convert_expr(expr),
      qualifiers: Enum.map(qualifiers, &convert_qualifier/1)
    }
  end

  defp convert_expr(other), do: unsupported!("unsupported Erlang form #{inspect(other)}")

  defp convert_record_field({:record_field, _anno, {:atom, _, name}, value}),
    do: %{name: source_name(name), value: convert_expr(value)}

  defp convert_record_field({:record_field, _anno, {:var, _, "_"}, value}),
    do: %{name: "_", value: convert_expr(value)}

  defp convert_catch_clause(
         {:clause, anno, [{:tuple, tuple_anno, [class, reason, stack]}], guards, body}
       ) do
    {stack, body} = sanitize_catch_stack_pattern(stack, guards, body)
    convert_clause({:clause, anno, [{:tuple, tuple_anno, [class, reason, stack]}], guards, body})
  end

  defp convert_catch_clause(clause), do: convert_clause(clause)

  defp sanitize_catch_stack_pattern({:var, anno, name} = stack, guards, body) do
    cond do
      wildcard_name?(name) ->
        {{:var, anno, :_}, body}

      raw_contains_var?(guards, name) ->
        unsupported!("try/catch stack variables are not available in guards")

      true ->
        {{:var, anno, :_}, [{:match, anno, stack, {nil, anno}} | body]}
    end
  end

  defp sanitize_catch_stack_pattern(_stack, _guards, body), do: {{:var, 0, :_}, body}

  defp wildcard_name?(:_), do: true
  defp wildcard_name?("_"), do: true
  defp wildcard_name?(_name), do: false

  defp raw_contains_var?({:var, _anno, name}, name), do: true

  defp raw_contains_var?(tuple, name) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> raw_contains_var?(name)

  defp raw_contains_var?(list, name) when is_list(list),
    do: Enum.any?(list, &raw_contains_var?(&1, name))

  defp raw_contains_var?(_term, _name), do: false

  defp convert_if_clause({:clause, _anno, [], guards, body}),
    do: %{guard: convert_guard(guards), body: body_expr(body)}

  defp convert_qualifier({:generate, _anno, pattern, expr}),
    do: %{node: :generator, pattern: convert_pattern(pattern), expr: convert_expr(expr)}

  defp convert_qualifier({:b_generate, _anno, pattern, expr}),
    do: %{node: :b_generator, pattern: convert_pattern(pattern), expr: convert_expr(expr)}

  defp convert_qualifier(expr), do: %{node: :filter, expr: convert_expr(expr)}

  defp convert_match_pattern({:var, _anno, "_"}), do: %{node: :wild_pattern}
  defp convert_match_pattern({:var, _anno, :_}), do: %{node: :wild_pattern}

  defp convert_match_pattern({:match, _anno, left, right}) do
    %{node: :alias, left: convert_match_pattern(left), right: convert_match_pattern(right)}
  end

  defp convert_match_pattern({:tuple, _anno, items}),
    do: %{node: :tuple, items: Enum.map(items, &convert_match_pattern/1)}

  defp convert_match_pattern({:cons, _anno, _head, _tail} = list) do
    case proper_list_items(list) do
      {:ok, items} -> %{node: :list, items: Enum.map(items, &convert_match_pattern/1)}
      :error -> convert_cons_match_pattern(list)
    end
  end

  defp convert_match_pattern({nil, _anno}), do: %{node: :list, items: []}

  defp convert_match_pattern({:map, _anno, fields}) when is_list(fields) do
    %{
      node: :map,
      fields:
        Enum.map(fields, fn
          {:map_field_exact, _anno, key, value} ->
            %{op: ":=", key: convert_expr(key), value: convert_match_pattern(value)}

          {:map_field_assoc, _anno, _key, _value} ->
            unsupported!("match map patterns must use := syntax")
        end)
    }
  end

  defp convert_match_pattern({:record, _anno, name, fields}) do
    %{
      node: :record_pattern,
      name: source_name(name),
      fields:
        Enum.map(fields, fn
          {:record_field, _anno, {:atom, _, field}, value} ->
            %{name: source_name(field), value: convert_pattern(value)}

          {:record_field, _anno, {:var, _, "_"}, value} ->
            %{name: "_", value: convert_pattern(value)}
        end)
    }
  end

  defp convert_match_pattern({:bin, _anno, elements}) do
    %{node: :binary, parts: Enum.map(elements, &convert_bin_element(&1, :match))}
  end

  defp convert_match_pattern(expr), do: convert_expr(expr)

  defp convert_bin_element({:bin_element, _anno, expr, size, types}, mode) do
    %{
      node: :bit_segment,
      expr: convert_segment_expr(expr, mode),
      size: convert_segment_size(size),
      types: normalize_segment_types(types)
    }
  end

  defp convert_segment_expr(expr, :expr), do: convert_expr(expr)
  defp convert_segment_expr(expr, :pattern), do: convert_pattern(expr)
  defp convert_segment_expr(expr, :match), do: convert_match_pattern(expr)

  defp convert_segment_size(:default), do: :default
  defp convert_segment_size(size), do: convert_expr(size)

  defp normalize_segment_types(:default), do: :default

  defp normalize_segment_types(types) when is_list(types) do
    Enum.map(types, fn
      {name, value} -> {source_name(name), value}
      name -> source_name(name)
    end)
  end

  defp proper_list_items({nil, _anno}), do: {:ok, []}

  defp proper_list_items({:cons, _anno, head, tail}) do
    case proper_list_items(tail) do
      {:ok, rest} -> {:ok, [head | rest]}
      :error -> :error
    end
  end

  defp proper_list_items(_), do: :error

  defp convert_cons_pattern({:cons, _anno, head, tail}) do
    %{node: :cons_pattern, head: convert_pattern(head), tail: convert_pattern(tail)}
  end

  defp convert_cons_match_pattern({:cons, _anno, head, tail}) do
    %{node: :cons, head: convert_match_pattern(head), tail: convert_match_pattern(tail)}
  end

  defp convert_cons_expr({:cons, _anno, head, tail}) do
    %{node: :cons, head: convert_expr(head), tail: convert_expr(tail)}
  end

  defp source_name(value) when is_binary(value), do: value
  defp source_name(value) when is_atom(value), do: Atom.to_string(value)

  defp inspect_name(value) when is_binary(value), do: value
  defp inspect_name(value), do: inspect(value)

  defp unsupported!(message) do
    throw({:hyperlang_frontend_error, Hyperlang.Error.new(:verify, message)})
  end

  defp unicode_binary!(value, category) do
    case :unicode.characters_to_binary(value, :unicode, :unicode) do
      binary when is_binary(binary) ->
        binary

      {:error, _encoded, rest} ->
        throw(
          {:hyperlang_frontend_error,
           Hyperlang.Error.new(category, "invalid Unicode literal",
             details: %{remaining: inspect(rest)}
           )}
        )

      {:incomplete, _encoded, rest} ->
        throw(
          {:hyperlang_frontend_error,
           Hyperlang.Error.new(category, "incomplete Unicode literal",
             details: %{remaining: inspect(rest)}
           )}
        )
    end
  end

  defp parse_error({location, _module, description}) do
    Hyperlang.Error.new(:parse, unicode_binary!(description, :parse), span: span(location))
  end

  defp parse_error(other), do: Hyperlang.Error.new(:parse, inspect(other))

  defp nested_function_clause_error(tokens, {location, _module, description}) do
    description = unicode_binary!(description, :parse)

    if starts_like_function_form?(tokens) and arrow_count(tokens) > 1 and
         String.contains?(description, "->") do
      {:ok,
       Hyperlang.Error.new(:parse, "nested function clauses are not valid Erlang",
         span: span(location),
         details: %{
           hint:
             "define helper clauses as separate top-level functions, or use case ... of ... -> ... end inside the result function"
         }
       )}
    else
      :error
    end
  end

  defp nested_function_clause_error(_tokens, _error), do: :error

  defp starts_like_function_form?([{:atom, _anno, _name}, {:"(", _paren_anno} | _rest]),
    do: true

  defp starts_like_function_form?(_tokens), do: false

  defp arrow_count(tokens) do
    Enum.count(tokens, fn
      {:->, _anno} -> true
      _ -> false
    end)
  end

  defp dot?({:dot, _anno}), do: true
  defp dot?(_), do: false

  defp span_from_anno(anno) when is_list(anno), do: span(Keyword.get(anno, :location))
  defp span_from_anno(anno), do: span(:erl_anno.location(anno))
  defp span({line, col}), do: %{line: line, col: col}
  defp span(line) when is_integer(line), do: %{line: line}
  defp span(_), do: nil
end
