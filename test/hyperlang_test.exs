defmodule HyperlangTest do
  use ExUnit.Case, async: false

  defmodule LogBinding do
    @behaviour Hyperlang.Binding
    @impl true
    def exports, do: [{:emit, 1, limits: %{"unknown_limit" => 1}}]
    @impl true
    def call(_state, :emit, [_value]), do: :ok
  end

  defmodule ClockBinding do
    @behaviour Hyperlang.Binding
    @impl true
    def exports, do: [{:now_ms, 0, nondeterministic: true}]
    @impl true
    def call(now, :now_ms, []), do: now
  end

  defmodule KVBinding do
    @behaviour Hyperlang.Binding
    @impl true
    def exports, do: [get: 1, read: 1]
    @impl true
    def call(fun, _function, [value]), do: fun.(value)
  end

  @readme_doc Path.expand("../README.md", __DIR__)
  @security_spec_doc Path.expand("../doc/SECURITY_SPECIFICATION.md", __DIR__)

  # A test "instance" is a program plus the bindings and policy it runs with.
  defp compile_and_instance(source, manifest \\ %{}, bindings \\ %{}, options \\ %{}) do
    manifest = if bindings == %{}, do: manifest, else: Map.put(manifest, :bindings, bindings)
    {:ok, program} = Hyperlang.Test.program(source, manifest)
    {program, {program, [bindings: bindings, policy: options]}}
  end

  defp run_instance({program, opts}, input, extra \\ []),
    do: Hyperlang.Test.run(program, :entry, [input], merge_policy(opts, extra))

  defp run_instance_export({program, opts}, export, args, extra \\ []),
    do: Hyperlang.Test.run(program, export, args, merge_policy(opts, extra))

  defp merge_policy(opts, extra) do
    policy = Map.merge(Map.new(Keyword.get(opts, :policy, %{})), Map.new(extra))
    Keyword.put(opts, :policy, policy)
  end

  defp eval(instance, input) do
    case run_instance(instance, input) do
      {:ok, result, %{stdout: []}} -> {:ok, result}
      other -> other
    end
  end

  defp existing_atom?(name) do
    String.to_existing_atom(name)
    true
  rescue
    ArgumentError -> false
  end

  defp next_free_code_pool_size do
    case Process.whereis(Hyperlang.CodeServer) do
      nil ->
        1

      pid ->
        pid
        |> :sys.get_state()
        |> Map.fetch!(:slots)
        |> Enum.filter(fn
          {id, %{state: :free}} when id < 1_000_000 -> true
          _other -> false
        end)
        |> Enum.map(fn {id, _slot} -> id end)
        |> Enum.min()
    end
  end

  defp scan_parse_form(scanner, parser, source) do
    source = if is_binary(source), do: String.to_charlist(source), else: source
    {:ok, tokens, _end_location} = scanner.string(source, {1, 1}, [:text])
    parser.parse_form(tokens)
  end

  defp scan_parse_exprs(scanner, parser, source) do
    source = if is_binary(source), do: String.to_charlist(source), else: source
    {:ok, tokens, _end_location} = scanner.string(source, {1, 1}, [:text])
    parser.parse_exprs(tokens)
  end

  defp normalize_parse_tree(term) when is_atom(term), do: Atom.to_string(term)
  defp normalize_parse_tree(term) when is_binary(term), do: term

  defp normalize_parse_tree(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.map(&normalize_parse_tree/1)
    |> List.to_tuple()
  end

  defp normalize_parse_tree(term) when is_list(term), do: Enum.map(term, &normalize_parse_tree/1)
  defp normalize_parse_tree(term), do: term

  defp load_test_kv_module do
    forms = [
      {:attribute, 0, :module, :kv},
      {:attribute, 0, :export, [get: 1]},
      {:function, 0, :get, 1,
       [
         {:clause, 0, [{:var, 0, :key}], [],
          [{:tuple, 0, [{:atom, 0, :ambient}, {:var, 0, :key}]}]}
       ]}
    ]

    {:ok, :kv, binary} = :compile.forms(forms, [:binary])
    :code.purge(:kv)
    :code.delete(:kv)
    {:module, :kv} = :code.load_binary(:kv, ~c"hyperlang_test_kv", binary)

    on_exit(fn ->
      :code.purge(:kv)
      :code.delete(:kv)
      :code.purge(:kv)
    end)
  end

  defp assert_eval_error(result, expected_category) do
    assert {:error, error} = result
    assert error_category(error) == expected_category
    error
  end

  defp error_category(error), do: Map.get(error, :category)
  defp error_reason(error), do: get_in(error, [:details, "reason"])

  # A process cannot be its own call tracer, so a separate collector receives
  # the trace messages. `:local` patterns also catch remote calls.
  defp capture_trace_calls(mfas, fun) when is_list(mfas) and is_function(fun, 0) do
    parent = self()
    tracer = spawn_link(fn -> collect_trace_calls(parent, []) end)
    Enum.each(mfas, &:erlang.trace_pattern(&1, true, [:local]))
    :erlang.trace(:all, true, [:call, {:tracer, tracer}])

    result =
      try do
        fun.()
      after
        :erlang.trace(:all, false, [:call])
        Enum.each(mfas, &:erlang.trace_pattern(&1, false, [:local]))
      end

    ref = :erlang.trace_delivered(:all)

    receive do
      {:trace_delivered, :all, ^ref} -> :ok
    end

    send(tracer, {:collect, parent})

    receive do
      {:trace_calls, ^tracer, calls} -> {result, calls}
    end
  end

  defp collect_trace_calls(parent, acc) do
    receive do
      {:trace, _pid, :call, {module, function, args}} ->
        collect_trace_calls(parent, [{module, function, length(args)} | acc])

      {:collect, ^parent} ->
        send(parent, {:trace_calls, self(), Enum.reverse(acc)})
    end
  end

  defp remote_calls(term), do: remote_calls(term, [])

  defp remote_calls(
         {:call, _anno, {:remote, _ra, {:atom, _ma, module}, {:atom, _fa, function}}, args},
         acc
       ) do
    {module, function, length(args)}
    |> then(&[&1 | acc])
    |> then(fn acc -> Enum.reduce(args, acc, &remote_calls/2) end)
  end

  defp remote_calls(term, acc) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.reduce(acc, &remote_calls/2)
  end

  defp remote_calls(term, acc) when is_list(term), do: Enum.reduce(term, acc, &remote_calls/2)
  defp remote_calls(_term, acc), do: acc

  defp local_calls(term), do: local_calls(term, [])

  defp local_calls({:call, _anno, {:atom, _fa, function}, args}, acc) do
    {function, length(args)}
    |> then(&[&1 | acc])
    |> then(fn acc -> Enum.reduce(args, acc, &local_calls/2) end)
  end

  defp local_calls(term, acc) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.reduce(acc, &local_calls/2)
  end

  defp local_calls(term, acc) when is_list(term), do: Enum.reduce(term, acc, &local_calls/2)
  defp local_calls(_term, acc), do: acc

  defp generated_function_form(forms, safe_name, arity) do
    Enum.find(forms, fn
      {:function, _anno, ^safe_name, ^arity, _clauses} -> true
      _other -> false
    end)
  end

  defp erlang_public(manifest \\ %{}) do
    Map.update(manifest, :terms, %{public: :erlang}, &Map.put(&1, :public, :erlang))
  end

  defp filesystem_pid(%Hyperlang.Filesystem.Handle{id: id}) do
    {:ok, pid} = Hyperlang.Filesystem.Registry.lookup(id)
    pid
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp contains_atom?(term) when is_atom(term), do: true

  defp contains_atom?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.any?(&contains_atom?/1)

  defp contains_atom?(term) when is_list(term), do: Enum.any?(term, &contains_atom?/1)

  defp contains_atom?(term) when is_map(term) do
    Enum.any?(term, fn {key, value} -> contains_atom?(key) or contains_atom?(value) end)
  end

  defp contains_atom?(_term), do: false

  defp sha256_file(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp assert_filesystem_resolver_mode(operation, mode) do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{virtual: "/data", backend: "memory", mode: :memory}
                 ]
               }
             })

    assert {:ok, %{path: "/data/a", mount: %{virtual: "/data"}, resolver_mode: ^mode}} =
             Hyperlang.Filesystem.resolve_operation(manifest.filesystem, "/data/a", operation)
  end

  defp filesystem_guest_example_sources(kind) do
    kind = Atom.to_string(kind)
    doc = File.read!(@readme_doc)
    regex = ~r/<!--\s*hyperlang:example\s+#{kind}\b[^>]*-->\s*```erlang\n(.*?)\n```/s

    doc
    |> then(&Regex.scan(regex, &1, capture: :all_but_first))
    |> Enum.map(fn [source] -> source end)
  end

  defp loader_evaluator_unsupported_mfas do
    [
      {"file", "script", 1, :unsupported_filesystem_mfa},
      {"file", "script", 2, :unsupported_filesystem_mfa},
      {"file", "path_script", 2, :unsupported_filesystem_mfa},
      {"file", "path_script", 3, :unsupported_filesystem_mfa},
      {"file", "eval", 1, :unsupported_filesystem_mfa},
      {"file", "eval", 2, :unsupported_filesystem_mfa},
      {"file", "path_eval", 2, :unsupported_filesystem_mfa},
      {"file", "path_eval", 3, :unsupported_filesystem_mfa},
      {"compile", "compile", 3, :unsupported_loader_mfa},
      {"compile", "compile_abstr", 3, :unsupported_loader_mfa},
      {"compile", "compile_asm", 3, :unsupported_loader_mfa},
      {"compile", "compile_core", 3, :unsupported_loader_mfa},
      {"compile", "env_compiler_options", 0, :unsupported_loader_mfa},
      {"compile", "format_error", 1, :unsupported_loader_mfa},
      {"compile", "forms", 1, :unsupported_loader_mfa},
      {"compile", "forms", 2, :unsupported_loader_mfa},
      {"compile", "noenv_file", 2, :unsupported_loader_mfa},
      {"compile", "noenv_forms", 2, :unsupported_loader_mfa},
      {"compile", "noenv_output_generated", 1, :unsupported_loader_mfa},
      {"compile", "options", 0, :unsupported_loader_mfa},
      {"compile", "output_generated", 1, :unsupported_loader_mfa},
      {"compile", "run_sub_passes", 2, :unsupported_loader_mfa},
      {"code", "add_path", 1, :unsupported_loader_mfa},
      {"code", "add_path", 2, :unsupported_loader_mfa},
      {"code", "add_patha", 1, :unsupported_loader_mfa},
      {"code", "add_patha", 2, :unsupported_loader_mfa},
      {"code", "add_paths", 1, :unsupported_loader_mfa},
      {"code", "add_paths", 2, :unsupported_loader_mfa},
      {"code", "add_pathsa", 1, :unsupported_loader_mfa},
      {"code", "add_pathsa", 2, :unsupported_loader_mfa},
      {"code", "add_pathsz", 1, :unsupported_loader_mfa},
      {"code", "add_pathsz", 2, :unsupported_loader_mfa},
      {"code", "add_pathz", 1, :unsupported_loader_mfa},
      {"code", "add_pathz", 2, :unsupported_loader_mfa},
      {"code", "all_available", 0, :unsupported_loader_mfa},
      {"code", "all_loaded", 0, :unsupported_loader_mfa},
      {"code", "atomic_load", 1, :unsupported_loader_mfa},
      {"code", "clash", 0, :unsupported_loader_mfa},
      {"code", "clear_cache", 0, :unsupported_loader_mfa},
      {"code", "compiler_dir", 0, :unsupported_loader_mfa},
      {"code", "coverage_support", 0, :unsupported_loader_mfa},
      {"code", "del_path", 1, :unsupported_loader_mfa},
      {"code", "del_paths", 1, :unsupported_loader_mfa},
      {"code", "delete", 1, :unsupported_loader_mfa},
      {"code", "ensure_modules_loaded", 1, :unsupported_loader_mfa},
      {"code", "finish_loading", 1, :unsupported_loader_mfa},
      {"code", "get_chunk", 2, :unsupported_loader_mfa},
      {"code", "get_coverage", 2, :unsupported_loader_mfa},
      {"code", "get_coverage_mode", 0, :unsupported_loader_mfa},
      {"code", "get_coverage_mode", 1, :unsupported_loader_mfa},
      {"code", "get_debug_info", 1, :unsupported_loader_mfa},
      {"code", "get_doc", 1, :unsupported_loader_mfa},
      {"code", "get_doc", 2, :unsupported_loader_mfa},
      {"code", "get_mode", 0, :unsupported_loader_mfa},
      {"code", "get_object_code", 1, :unsupported_loader_mfa},
      {"code", "get_path", 0, :unsupported_loader_mfa},
      {"code", "is_loaded", 1, :unsupported_loader_mfa},
      {"code", "is_sticky", 1, :unsupported_loader_mfa},
      {"code", "lib_dir", 0, :unsupported_loader_mfa},
      {"code", "lib_dir", 1, :unsupported_loader_mfa},
      {"code", "lib_dir", 2, :unsupported_loader_mfa},
      {"code", "load_abs", 1, :unsupported_loader_mfa},
      {"code", "load_abs", 2, :unsupported_loader_mfa},
      {"code", "load_binary", 3, :unsupported_loader_mfa},
      {"code", "load_file", 1, :unsupported_loader_mfa},
      {"code", "modified_modules", 0, :unsupported_loader_mfa},
      {"code", "module_md5", 1, :unsupported_loader_mfa},
      {"code", "module_status", 0, :unsupported_loader_mfa},
      {"code", "module_status", 1, :unsupported_loader_mfa},
      {"code", "objfile_extension", 0, :unsupported_loader_mfa},
      {"code", "prepare_loading", 1, :unsupported_loader_mfa},
      {"code", "priv_dir", 1, :unsupported_loader_mfa},
      {"code", "purge", 1, :unsupported_loader_mfa},
      {"code", "replace_path", 2, :unsupported_loader_mfa},
      {"code", "replace_path", 3, :unsupported_loader_mfa},
      {"code", "reset_coverage", 1, :unsupported_loader_mfa},
      {"code", "root_dir", 0, :unsupported_loader_mfa},
      {"code", "set_coverage_mode", 1, :unsupported_loader_mfa},
      {"code", "set_path", 1, :unsupported_loader_mfa},
      {"code", "set_path", 2, :unsupported_loader_mfa},
      {"code", "soft_purge", 1, :unsupported_loader_mfa},
      {"code", "start_link", 0, :unsupported_loader_mfa},
      {"code", "stick_dir", 1, :unsupported_loader_mfa},
      {"code", "stick_mod", 1, :unsupported_loader_mfa},
      {"code", "stop", 0, :unsupported_loader_mfa},
      {"code", "unstick_dir", 1, :unsupported_loader_mfa},
      {"code", "unstick_mod", 1, :unsupported_loader_mfa},
      {"code", "where_is_file", 1, :unsupported_loader_mfa},
      {"code", "where_is_file", 2, :unsupported_loader_mfa},
      {"code", "which", 1, :unsupported_loader_mfa},
      {"erl_eval", "add_binding", 3, :evaluator_compat_disabled},
      {"erl_eval", "binding", 2, :evaluator_compat_disabled},
      {"erl_eval", "bindings", 1, :evaluator_compat_disabled},
      {"erl_eval", "check_command", 2, :evaluator_compat_disabled},
      {"erl_eval", "del_binding", 2, :evaluator_compat_disabled},
      {"erl_eval", "eval_str", 1, :evaluator_compat_disabled},
      {"erl_eval", "expr", 2, :evaluator_compat_disabled},
      {"erl_eval", "expr", 3, :evaluator_compat_disabled},
      {"erl_eval", "expr", 4, :evaluator_compat_disabled},
      {"erl_eval", "expr", 5, :evaluator_compat_disabled},
      {"erl_eval", "expr_list", 2, :evaluator_compat_disabled},
      {"erl_eval", "expr_list", 3, :evaluator_compat_disabled},
      {"erl_eval", "expr_list", 4, :evaluator_compat_disabled},
      {"erl_eval", "exprs", 2, :evaluator_compat_disabled},
      {"erl_eval", "exprs", 3, :evaluator_compat_disabled},
      {"erl_eval", "exprs", 4, :evaluator_compat_disabled},
      {"erl_eval", "extended_parse_exprs", 1, :evaluator_compat_disabled},
      {"erl_eval", "extended_parse_term", 1, :evaluator_compat_disabled},
      {"erl_eval", "fun_data", 1, :evaluator_compat_disabled},
      {"erl_eval", "is_constant_expr", 1, :evaluator_compat_disabled},
      {"erl_eval", "match_clause", 4, :evaluator_compat_disabled},
      {"erl_eval", "new_bindings", 0, :evaluator_compat_disabled},
      {"erl_eval", "new_bindings", 1, :evaluator_compat_disabled},
      {"erl_eval", "partial_eval", 1, :evaluator_compat_disabled}
    ]
    |> Enum.reject(fn {module, function, arity, _reason} ->
      {module, function, arity} in [
        {"code", "all_available", 0},
        {"code", "get_doc", 1},
        {"code", "get_path", 0},
        {"code", "is_loaded", 1},
        {"code", "which", 1}
      ]
    end)
  end

  defp current_otp_unsupported_filesystem_mfas do
    supported = MapSet.new(Hyperlang.Filesystem.supported_mfas())

    [:file, :filelib]
    |> Enum.flat_map(fn module ->
      module.module_info(:exports)
      |> Enum.reject(fn {function, _arity} -> function == :module_info end)
      |> Enum.map(fn {function, arity} ->
        {Atom.to_string(module), Atom.to_string(function), arity}
      end)
    end)
    |> Enum.reject(&MapSet.member?(supported, &1))
    |> Enum.sort()
  end

  defp mfa_call_source(module, function, 0), do: "#{module}:#{function}()."

  defp mfa_call_source(module, function, arity) do
    args = Enum.map_join(1..arity, ", ", fn _ -> "nil" end)
    "#{module}:#{function}(#{args})."
  end

  test "evaluates expression bundles as result-only programs" do
    {program, instance} = compile_and_instance("1 + 2.")
    assert Map.from_struct(program).metadata.frontend == :otp_derived
    assert eval(instance, :ok) == {:ok, 3}
  end

  test "expression bundles support map and binary comprehensions" do
    {_program, instance} =
      compile_and_instance(
        ~S"""
        #{X => X * 2 || X <- Input}.
        """,
        erlang_public()
      )

    assert eval(instance, [1, 2, 3]) == {:ok, %{1 => 2, 2 => 4, 3 => 6}}

    {_program, instance} =
      compile_and_instance("<< <<X>> || X <- Input >>.", erlang_public())

    assert eval(instance, [65, 66]) == {:ok, "AB"}

    {_program, instance} =
      compile_and_instance("<< <<X>> || <<X>> <= Input, X > 65 >>.", erlang_public())

    assert eval(instance, "ABC") == {:ok, "BC"}
  end

  test "unicode string and binary literals compile without internal worker errors" do
    {_program, instance} = compile_and_instance(~S|<<"Taipei—red">>.|, erlang_public())

    assert eval(instance, :ok) == {:ok, "Taipei—red"}
  end

  test "unicode import payloads compile without collapsing to badarg" do
    manifest =
      erlang_public(%{
        bindings: %{"tools" => %{submit_session_input: fn input -> input end}}
      })

    source =
      ~S"""
      Submit = tools:submit_session_input(#{
        <<"input">> => #{
          <<"session_id">> => <<"session_123">>,
          <<"branch_id">> => <<"root">>,
          <<"input_kind">> => <<"message">>,
          <<"text">> => <<"Map this: Taipei—red lanterns">>,
          <<"wake_runtime">> => true
        }
      }),
      Submit.
      """

    assert {:ok, _program} = Hyperlang.Test.program(source, manifest)
  end

  test "vendored OTP scanner keeps untrusted names as binaries without atom growth" do
    {:ok, _tokens, _end_location} =
      :hyperlang_otp_scan.string(~c"warmup(Warmup) -> 'warmup'.", {1, 1}, [:text])

    for _ <- 1..10 do
      :hyperlang_otp_scan.string(~c"~warmup\"x\".", {1, 1}, [:text])
    end

    assert {:ok, sigil_tokens, _} =
             :hyperlang_otp_scan.string(~c"~unique_sigil\"x\".", {1, 1}, [:text])

    assert {:sigil_prefix, _anno, "unique_sigil"} =
             Enum.find(sigil_tokens, &match?({:sigil_prefix, _, _}, &1))

    assert {:ok, safe_string_tokens, _} =
             :hyperlang_otp_scan.string(~c"~s\"a\\n\".", {1, 1}, [:text])

    assert {:ok, [{:string, _anno, ~c"a\n"}]} =
             :hyperlang_otp_parse.parse_exprs(safe_string_tokens)

    assert {:ok, safe_binary_tokens, _} =
             :hyperlang_otp_scan.string(~c"~b\"a\\n\".", {1, 1}, [:text])

    assert {:ok, [{:bin, _anno, [{:bin_element, _, {:string, _, ~c"a\n"}, :default, [:utf8]}]}]} =
             :hyperlang_otp_parse.parse_exprs(safe_binary_tokens)

    assert {:error, {_location, :hyperlang_otp_scan, _reason}, _end_location} =
             :hyperlang_otp_scan.string(~c"~b\"unterminated", {1, 1}, [:text])

    for keyword <- [:maybe, :else], keyword in :erl_features.keywords() do
      assert {:ok, [token | _], _} =
               :hyperlang_otp_scan.string(Atom.to_charlist(keyword) ++ ~c".", {1, 1}, [:text])

      assert {^keyword, _anno} = token
    end

    reserved_word_fun = fn
      :foo -> true
      atom -> :hyperlang_otp_scan.reserved_word(atom)
    end

    assert {:ok, [custom_keyword, ordinary_atom | _], _} =
             :hyperlang_otp_scan.string(~c"foo bar.", {1, 1},
               text: true,
               reserved_word_fun: reserved_word_fun
             )

    assert {:foo, _anno} = custom_keyword
    assert {:atom, _anno, "bar"} = ordinary_atom

    before_count = :erlang.system_info(:atom_count)

    source =
      1..1_000
      |> Enum.map(fn i ->
        "name_#{i} Var_#{i} 'quoted_#{i}' module_label_#{i}:function_name_#{i}(Var_#{i})."
      end)
      |> Enum.join(" ")
      |> String.to_charlist()

    assert {:ok, tokens, _end_location} = :hyperlang_otp_scan.string(source, {1, 1}, [:text])

    assert Enum.all?(tokens, fn
             {:atom, _anno, value} -> is_binary(value)
             {:var, _anno, value} -> is_binary(value)
             _ -> true
           end)

    for i <- 1..1_000 do
      :hyperlang_otp_scan.string(String.to_charlist("~sigil_#{i}\"x\"."), {1, 1}, [:text])
    end

    after_count = :erlang.system_info(:atom_count)
    assert after_count - before_count < 120
  end

  test "OTP frontend patchset is reproducible from vendored upstream files" do
    script = Path.expand("../scripts/diff_otp_frontend.sh", __DIR__)

    {output, status} =
      System.cmd(script, ["--check"], stderr_to_stdout: true)

    assert status == 0, output
  end

  test "vendored OTP parser preserves safe names while matching OTP parse shape" do
    form_sources = [
      "result(Input) -> maps:get(thing, Input).",
      "-module(example_module).",
      "-export([result/1]).",
      "-record(person, {name, age = 0}).",
      "-type pair(T) :: {T, integer()}.",
      "result(Input) -> {fun helper/1, fun maps:get/2}."
    ]

    for source <- form_sources do
      assert normalize_parse_tree(scan_parse_form(:erl_scan, :erl_parse, source)) ==
               normalize_parse_tree(
                 scan_parse_form(:hyperlang_otp_scan, :hyperlang_otp_parse, source)
               )
    end

    expr_sources = [
      "maps:get(thing, Input).",
      "M:F().",
      "fun LocalFun(X) -> X end."
    ]

    for source <- expr_sources do
      assert normalize_parse_tree(scan_parse_exprs(:erl_scan, :erl_parse, source)) ==
               normalize_parse_tree(
                 scan_parse_exprs(:hyperlang_otp_scan, :hyperlang_otp_parse, source)
               )
    end

    for source <- [
          "warm_parser_safe_name(WarmParserSafeName) -> remote_warm_parser:call_warm_parser(WarmParserSafeName).",
          "-record(record_warm_parser, {field_warm_parser}).",
          "-type type_warm_parser(T) :: {T, user_type_warm_parser()}.",
          "result(Input) -> {fun helper_warm_parser/1, fun remote_warm_parser:call_warm_parser/1}."
        ] do
      assert {:ok, _parsed} = scan_parse_form(:hyperlang_otp_scan, :hyperlang_otp_parse, source)
    end

    unique = "parser_safe_name_#{System.unique_integer([:positive])}"

    unique_names = [
      unique,
      "remote_#{unique}",
      "call_#{unique}",
      "record_#{unique}",
      "field_#{unique}",
      "type_#{unique}",
      "user_type_#{unique}",
      "helper_#{unique}",
      String.capitalize(unique)
    ]

    for name <- unique_names, do: refute(existing_atom?(name))

    for source <- [
          "#{unique}(#{String.capitalize(unique)}) -> remote_#{unique}:call_#{unique}(#{String.capitalize(unique)}).",
          "-record(record_#{unique}, {field_#{unique}}).",
          "-type type_#{unique}(T) :: {T, user_type_#{unique}()}.",
          "result(Input) -> {fun helper_#{unique}/1, fun remote_#{unique}:call_#{unique}/1}."
        ] do
      assert {:ok, parsed} = scan_parse_form(:hyperlang_otp_scan, :hyperlang_otp_parse, source)
      assert inspect(parsed) =~ unique
    end

    for name <- unique_names, do: refute(existing_atom?(name))
  end

  test "frontend enforces form and AST node limits" do
    source = """
    result(Input) -> Input.
    helper(Input) -> Input.
    """

    assert {:error, [%{category: :parse, message: message}]} =
             Hyperlang.Test.program(source, %{limits: %{max_forms: 1}})

    assert message =~ "form count"

    assert {:error, [%{category: :parse, message: message}]} =
             Hyperlang.Test.program("[1, 2, 3, 4, 5, 6, 7, 8, 9, 10].", %{
               limits: %{max_ast_nodes: 5}
             })

    assert message =~ "AST node count"
  end

  test "frontend enforces compilation literal and nesting limits with spans" do
    assert {:error, [%{category: :lexer, message: message, span: %{line: 1, col: 1}}]} =
             Hyperlang.Test.program("\"abc\".", %{limits: %{max_literal_bytes: 2}})

    assert message =~ "literal byte count"

    assert {:error, [%{category: :lexer, message: message, span: %{line: 1, col: 1}}]} =
             Hyperlang.Test.program("1234.", %{limits: %{max_integer_digits: 3}})

    assert message =~ "integer digit count"

    assert {:error, [%{category: :verify, message: message}]} =
             Hyperlang.Test.program("{alpha, beta}.", %{limits: %{max_atom_count: 1}})

    assert message =~ "source atom pool"

    assert {:error, [%{category: :lexer, message: message, span: %{line: 1}}]} =
             Hyperlang.Test.program("[[[1]]].", %{limits: %{max_nesting_depth: 2}})

    assert message =~ "nesting depth"
  end

  test "frontend renders scanner errors with location and OTP format_error text" do
    assert {:error, [%{category: :lexer, message: message, span: %{line: 2, col: 6}}]} =
             Hyperlang.Test.program("result(_) ->\n  <<\"abc\\\">>.\n", %{})

    assert message =~ "scanner failed at line 2, column 6"
    assert message =~ "unterminated string"
    assert message =~ "stray backslash before a closing quote"

    assert {:error, [%{category: :lexer, message: message, span: %{line: 1, col: 14}}]} =
             Hyperlang.Test.program("result(_) -> 1#1.", %{})

    assert message =~ "scanner failed at line 1, column 14"
    assert message =~ "illegal base '1'"

    assert {:error, [%{category: :lexer, message: message, span: %{line: 1, col: 14}}]} =
             Hyperlang.Test.program("result(_) -> \uFFFE.", %{})

    assert message =~ "scanner failed at line 1, column 14"
    assert message =~ "illegal character"

    assert {:error, [%{category: :lexer, message: message, span: %{line: 1, col: 15}}]} =
             Hyperlang.Test.program("result(_) -> 'abc.", %{})

    assert message =~ "scanner failed at line 1, column 15"
    assert message =~ "unterminated atom"
  end

  test "compilation has a wall-clock timeout gate" do
    assert {:error, [%{category: :manifest, message: message}]} =
             Hyperlang.Test.program("1.", %{limits: %{max_compile_ms: 0}})

    assert message =~ "runtime-critical limits must be positive"
  end

  test "supports helper functions without exposing guest exports in public info" do
    source = """
    result(Input) -> double(Input) + 1.
    double(X) -> X * 2.
    """

    {program, instance} = compile_and_instance(source)

    assert eval(instance, 20) == {:ok, 41}
    refute Map.has_key?(Map.from_struct(program), :module)
    refute Map.has_key?(Map.from_struct(program), :mfa)
    refute Map.has_key?(Map.from_struct(program), :slot)
    refute Map.has_key?(Map.from_struct(program).metadata, :generated_exports)

    refute :slot in Map.keys(Map.from_struct(program))
    refute :core in Map.keys(Map.from_struct(program))
    refute :manifest in Map.keys(Map.from_struct(program))
  end

  test "local helpers may redefine forbidden BIF names" do
    source = ~S"""
    get(Map) ->
      case maps:find(<<"id">>, Map) of
        {ok, Value} -> Value;
        error -> missing
      end.

    result(_) ->
      get(#{<<"id">> => 7}).
    """

    {_program, instance} = compile_and_instance(source, erlang_public())
    assert eval(instance, :ok) == {:ok, 7}

    source = """
    spawn(Fun) -> Fun(21).
    result(_) ->
      F = fun spawn/1,
      F(fun(X) -> X * 2 end).
    """

    {_program, instance} = compile_and_instance(source, erlang_public())
    assert eval(instance, :ok) == {:ok, 42}

    assert {:error, [%{category: :verify, message: message}]} =
             Hyperlang.Test.program(
               """
               result(_) -> self().
               """,
               %{}
             )

    assert message =~ "forbidden local call self/0"

    assert {:error, [%{category: :verify, message: message}]} =
             Hyperlang.Test.program(
               """
               result(_) -> fun spawn/1.
               """,
               %{}
             )

    assert message =~ "forbidden local fun capture spawn/1"
  end

  test "local helpers shadow multiple blocked names when the local arity matches" do
    source = """
    apply(Fun, Value) -> Fun(Value).
    binary_to_term(Bin) -> byte_size(Bin).
    list_to_atom(List) -> length(List).

    result(_) ->
      apply(fun(X) -> X + 1 end, binary_to_term(<<"abc">>) + list_to_atom("xy")).
    """

    {_program, instance} = compile_and_instance(source, erlang_public())
    assert eval(instance, :ok) == {:ok, 6}

    source = """
    erase(Value) -> {local, Value}.
    put(Key, Value) -> {Key, Value}.
    result(_) -> {erase(7), put(<<"k">>, <<"v">>)}.
    """

    {_program, instance} =
      compile_and_instance(source, erlang_public(%{terms: %{allowed_atoms: [:local]}}))

    assert eval(instance, :ok) == {:ok, {{:local, 7}, {<<"k">>, <<"v">>}}}
  end

  test "blocked names remain blocked when not resolved as local helpers" do
    assert {:error, [%{category: :verify, message: message}]} =
             Hyperlang.Test.program(
               """
               self(X) -> X.
               result(_) -> self().
               """,
               %{}
             )

    assert message =~ "forbidden local call self/0"

    assert {:error, [%{category: :verify, message: message}]} =
             Hyperlang.Test.program(
               """
               get(Map) -> Map.
               result(_) -> erlang:get(x).
               """,
               %{}
             )

    assert message =~ "forbidden remote call erlang:get/1"

    assert {:error, [%{category: :verify, message: message}]} =
             Hyperlang.Test.program(
               """
               apply(Fun, Value, Extra) -> {Fun, Value, Extra}.
               result(_) -> apply(fun(X) -> X end, [1]).
               """,
               %{}
             )

    assert message =~ "forbidden local call apply/2"

    assert {:error, [%{category: :verify, message: message}]} =
             Hyperlang.Test.program("result(_) -> fun binary_to_term/1.", %{})

    assert message =~ "forbidden local fun capture binary_to_term/1"
  end

  test "instance construction stamps normalized runtime policy without recursive walks" do
    source = """
    result(Input) -> Input.
    """

    {:ok, program} = Hyperlang.Test.program(source, erlang_public())

    {result, calls} =
      capture_trace_calls([{Hyperlang.Terms, :contains_forbidden?, 1}], fn ->
        Hyperlang.Test.run(program, :entry, [1])
      end)

    assert {:ok, 1, _meta} = result

    refute {Hyperlang.Terms, :contains_forbidden?, 1} in calls
  end

  test "helper functions are resolved by name and arity" do
    source = """
    primes20() -> primes20(2, []).
    primes20(_C, Acc) when length(Acc) =:= 20 -> lists:reverse(Acc);
    primes20(C, Acc) ->
      case is_prime(C) of
        true -> primes20(C + 1, [C | Acc]);
        false -> primes20(C + 1, Acc)
      end.
    is_prime(N) when N < 2 -> false;
    is_prime(2) -> true;
    is_prime(N) when N rem 2 =:= 0 -> false;
    is_prime(N) -> is_prime_odd(N, 3).
    is_prime_odd(N, I) when I * I > N -> true;
    is_prime_odd(N, I) when N rem I =:= 0 -> false;
    is_prime_odd(N, I) -> is_prime_odd(N, I + 2).
    result(_Input) -> primes20().
    """

    {_program, instance} = compile_and_instance(source, erlang_public())

    assert eval(instance, :ok) ==
             {:ok, [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71]}
  end

  test "duplicate helper function name and arity is rejected" do
    source = """
    result(Input) -> Input.
    helper(X) -> X.
    helper(X) -> X + 1.
    """

    assert {:error, [%{category: :verify, message: "duplicate function name/arity"}]} =
             Hyperlang.Test.program(source, erlang_public())
  end

  test "nested function-looking clauses get a useful parse error" do
    assert {:error, [%{category: :parse, message: message, span: span, details: details}]} =
             Hyperlang.Test.program(
               "result(_) -> is_prime(2) -> true end.",
               erlang_public()
             )

    assert message == "nested function clauses are not valid Erlang"
    assert span == %{line: 1, col: 26}
    assert details.hint =~ "top-level functions"
  end

  test "named anonymous functions stay safe and recursive" do
    {_program, instance} =
      compile_and_instance(
        "F = fun Loop(0) -> 0; Loop(N) -> Loop(N - 1) + 1 end, F(5).",
        erlang_public()
      )

    assert eval(instance, :ok) == {:ok, 5}
  end

  test "named anonymous functions can be used as stdlib callbacks" do
    source = """
    result(_) ->
      IsPrime =
        fun IsPrime(N) ->
          if
            N < 2 -> false;
            N =:= 2 -> true;
            N rem 2 =:= 0 -> false;
            true ->
              Limit = trunc(math:sqrt(N)),
              lists:all(fun(D) -> N rem D =/= 0 end, lists:seq(3, Limit, 2))
          end
        end,
      lists:foldl(
        fun(Candidate, Acc) ->
          case length(Acc) < 20 andalso IsPrime(Candidate) of
            true -> Acc ++ [Candidate];
            false -> Acc
          end
        end,
        [],
        lists:seq(2, 1000)
      ).
    """

    {_program, instance} = compile_and_instance(source, erlang_public())

    assert eval(instance, :ok) ==
             {:ok, [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71]}
  end

  test "forward closure references report source variable names" do
    source = """
    result(_Input) ->
      IsPrime =
        fun IsPrime(N) ->
          if
            N < 2 -> false;
            true -> IsPrimeOdd(N, 3)
          end
        end,
      IsPrimeOdd =
        fun IsPrimeOdd(_N, _D) -> true end,
      IsPrime(7).
    """

    assert {:error, [%{category: :verify, message: message, details: details}]} =
             Hyperlang.Test.program(source, erlang_public())

    assert message == "unbound variable IsPrimeOdd"
    assert details.variable == "IsPrimeOdd"
    assert details.hint =~ "bind IsPrimeOdd"
    refute inspect(details) =~ "v_"
  end

  test "fun calls in if guards report guard-specific guidance" do
    source = """
    result(_Input) ->
      IsPrime = fun(_N) -> true end,
      if
        IsPrime(7) -> ok;
        true -> error
      end.
    """

    assert {:error, [%{category: :verify, message: message, details: details}]} =
             Hyperlang.Test.program(source, erlang_public())

    assert message == "fun calls are not allowed in guards"
    assert details.hint =~ "case"
    refute inspect(details) =~ "v_"
  end

  test "remote calls in guards report source MFA" do
    assert {:error, [%{category: :verify, message: message, details: details}]} =
             Hyperlang.Test.program(
               "result(_) -> if math:sqrt(4) > 1 -> ok; true -> error end.",
               erlang_public()
             )

    assert message == "remote call math:sqrt/1 is not allowed in a guard"
    assert details.module == "math"
    assert details.function == "sqrt"
    assert details.arity == 1
  end

  test "inline helper definitions inside result get a useful parse error" do
    source =
      "result(_) -> is_prime(N) -> true, collect(Candidate) -> Candidate, collect(2)."

    assert {:error, [%{category: :parse, message: message, details: details}]} =
             Hyperlang.Test.program(source, erlang_public())

    assert message == "nested function clauses are not valid Erlang"
    assert details.hint =~ "top-level functions"
  end

  test "manifest normalizes function exports and exposes safe compile metadata" do
    source = """
    -export([helper/1]).
    result(Input) -> read_value(Input, 2).
    read_value(Input, N) -> Input + N.
    read_value(Input, N, Scale) -> Input + N + Scale.
    write_increment(State, Delta, Ctx) -> {State, Delta, Ctx}.
    helper(X) -> X.
    """

    manifest =
      erlang_public(%{
        exports: %{
          functions: %{
            "read_value" => %{
              function: "read_value",
              arity: 2,
              input: %{profile: :fileserver_read},
              output: %{profile: :bytes}
            },
            "read_value_scaled" => %{
              function: "read_value",
              arity: 3,
              input: %{profile: :safe_term},
              output: %{profile: :bytes}
            },
            "write_increment" => %{
              function: "write_increment",
              arity: "3",
              input: %{},
              output: %{profile: "status"}
            }
          }
        }
      })

    {:ok, program} = Hyperlang.Test.program(source, manifest)

    info = Map.from_struct(program)

    assert info.metadata.exports == %{
             functions: %{
               "read_value" => %{
                 id: "read_value",
                 function: "read_value",
                 arity: 2,
                 input: %{profile: :fileserver_read},
                 output: %{profile: :bytes}
               },
               "read_value_scaled" => %{
                 id: "read_value_scaled",
                 function: "read_value",
                 arity: 3,
                 input: %{profile: :safe_term},
                 output: %{profile: :bytes}
               },
               "write_increment" => %{
                 id: "write_increment",
                 function: "write_increment",
                 arity: 3,
                 input: %{},
                 output: %{profile: :status}
               }
             },
             files: []
           }

    refute Map.has_key?(info.metadata, :generated_exports)
    refute inspect(info.metadata.exports) =~ "hyperlang_slot"
  end

  test "invalid manifest export shapes get specific diagnostics" do
    assert {:error, [%{category: :manifest, message: message}]} =
             Hyperlang.Test.program("1.", %{exports: []})

    assert message =~ "exports must be a map"

    assert {:error, [%{category: :manifest, message: message}]} =
             Hyperlang.Test.program("1.", %{
               exports: %{functions: [%{function: "a", arity: 1}]}
             })

    assert message =~ "exports.functions must be a map"

    assert {:error, [%{category: :manifest, message: message}]} =
             Hyperlang.Test.program("1.", %{
               exports: %{
                 functions: %{
                   :dup => %{function: "a", arity: 1},
                   "dup" => %{function: "b", arity: 1}
                 }
               }
             })

    assert message =~ "duplicate exports.functions id"

    assert {:error, [%{category: :manifest, message: message}]} =
             Hyperlang.Test.program("1.", %{
               exports: %{
                 functions: %{
                   "one" => %{function: "same", arity: 1},
                   "two" => %{function: "same", arity: 1}
                 }
               }
             })

    assert message =~ "ambiguous exports.functions function/arity"

    assert {:error, [%{category: :manifest, message: message}]} =
             Hyperlang.Test.program("1.", %{
               exports: %{functions: %{"bad" => %{function: "f", arity: -1}}}
             })

    assert message =~ "exports function arity must be 0..255"

    assert {:error, [%{category: :manifest, message: message}]} =
             Hyperlang.Test.program("1.", %{exports: %{files: []}})

    assert message =~ "unknown exports key"

    assert {:error, [%{category: :manifest, message: message}]} =
             Hyperlang.Test.program("1.", %{
               exports: %{
                 functions: %{
                   "bad_profile" => %{
                     function: "f",
                     arity: 1,
                     input: %{profile: :not_a_declared_profile}
                   }
                 }
               }
             })

    assert message =~ "invalid exports input profile"

    assert {:error, [%{category: :manifest, message: message}]} =
             Hyperlang.Test.program("1.", %{
               exports: %{
                 functions: %{
                   "bad_profile_key" => %{
                     function: "f",
                     arity: 1,
                     output: %{profile: :bytes, extra: true}
                   }
                 }
               }
             })

    assert message =~ "unknown exports output profile key"
  end

  test "module macro expands in source modules without enabling general macros" do
    source = """
    -module(chat).
    result(_Input) -> ?MODULE.
    """

    {_program, instance} = compile_and_instance(source, erlang_public())
    assert eval(instance, :ok) == {:ok, "chat"}
  end

  test "hyperbob_os behaviour attributes are inert to Hyperlang" do
    source = """
    -module(chat).
    -behaviour(webfs).

    main(Args) -> {ok, Args}.
    """

    {:ok, program} =
      Hyperlang.Test.program(
        source,
        erlang_public(%{entry: %{function: "main"}, modules: %{enabled: true}})
      )

    info = Map.from_struct(program)
    exports = info.metadata.exports.functions

    assert exports == %{}
    assert get_in(info.metadata, [:source_contract, :behaviours]) == ["webfs"]
  end

  test "reserved generated helper names cannot be claimed by source or manifest exports" do
    source = """
    result(Input) -> safe_f_0(Input).
    safe_f_0(Input) -> Input + 1.
    """

    assert {:error, [%{category: :verify, message: message} = error]} =
             Hyperlang.Test.program(source, erlang_public())

    assert message =~ "reserved Hyperlang internal name"
    refute inspect(error) =~ "safe_f_"

    assert {:error, [%{category: :manifest, message: message}]} =
             Hyperlang.Test.program(
               "result(Input) -> Input.",
               erlang_public(%{result: %{name: "safe_f_0"}})
             )

    assert message =~ "reserved Hyperlang internal name"

    assert {:error, [%{category: :manifest, message: message}]} =
             Hyperlang.Test.program(
               "safe_f_0() -> 1. result(Input) -> Input.",
               erlang_public(%{
                 exports: %{functions: %{"public_read" => %{function: "safe_f_0", arity: 0}}}
               })
             )

    assert message =~ "reserved Hyperlang internal name"
  end

  test "fileserver descriptor normalizes through declared callback ids" do
    source = ~S"""
    read_index(_FidCtx, _Offset, _Count) -> <<"index">>.
    write_update(_FidCtx, Data, _Offset) -> {ok, byte_size(Data)}.
    list_dynamic(_FidCtx) -> [<<"child.txt">>].
    stat_dynamic(_FidCtx) -> #{size => 0, mode => 365}.
    """

    manifest =
      erlang_public(%{
        exports: %{
          functions: %{
            "render_index" => %{function: "read_index", arity: 3},
            "update" => %{function: "write_update", arity: 3},
            "list_dynamic" => %{function: "list_dynamic", arity: 1},
            "stat_dynamic" => %{function: "stat_dynamic", arity: 1}
          },
          fileserver: %{
            files: [
              %{path: "/", type: :dir, list: :declared, rights: [:list, :stat]},
              %{
                path: "/index.html",
                type: :file,
                read: "render_index",
                rights: [:read, :watch, :stat],
                content_type: "text/html",
                reactive: :fid_generation,
                deps: ["/state/count"]
              },
              %{
                path: "/intents/update",
                type: :file,
                write: "update",
                rights: [:write, :stat]
              },
              %{
                path: "/dynamic",
                type: :dir,
                list: "list_dynamic",
                stat: "stat_dynamic",
                rights: [:list, :stat]
              }
            ]
          }
        }
      })

    {:ok, program} = Hyperlang.Test.program(source, manifest)

    assert Map.from_struct(program).metadata.exports.files == [
             %{
               path: "/",
               type: :dir,
               op: :dir,
               rights: [:list, :stat],
               deps: [],
               metadata: %{},
               reactive_policy: nil
             },
             %{
               path: "/index.html",
               type: :file,
               op: :read,
               function: "read_index",
               arity: 3,
               input: %{profile: :fileserver_read},
               output: %{profile: :bytes},
               effects: [],
               rights: [:read, :watch, :stat],
               deps: ["/state/count"],
               metadata: %{content_type: "text/html"},
               reactive_policy: :fid_generation
             },
             %{
               path: "/intents/update",
               type: :file,
               op: :write,
               function: "write_update",
               arity: 3,
               input: %{profile: :fileserver_write},
               output: %{profile: :status},
               effects: [:bump],
               rights: [:write, :stat],
               deps: [],
               metadata: %{},
               reactive_policy: nil
             },
             %{
               path: "/dynamic",
               type: :dir,
               op: :list,
               function: "list_dynamic",
               arity: 1,
               input: %{profile: :fileserver_list},
               output: %{profile: :list},
               effects: [],
               rights: [:list, :stat],
               deps: [],
               metadata: %{},
               reactive_policy: nil
             },
             %{
               path: "/dynamic",
               type: :dir,
               op: :stat,
               function: "stat_dynamic",
               arity: 1,
               input: %{profile: :fileserver_stat},
               output: %{profile: :stat},
               effects: [],
               rights: [:list, :stat],
               deps: [],
               metadata: %{},
               reactive_policy: nil
             }
           ]
  end

  test "fileserver descriptor rejects unsafe or ambiguous declarations" do
    source = "read_value(_FidCtx, _Offset, _Count) -> <<\"ok\">>."

    base_manifest = fn fileserver ->
      erlang_public(%{
        exports: %{
          functions: %{
            "read_value" => %{function: "read_value", arity: 3}
          },
          fileserver: fileserver
        }
      })
    end

    assert {:error, [%{category: :manifest, message: message}]} =
             Hyperlang.Test.program(
               source,
               base_manifest.(%{files: [%{path: "/value", read: "missing", rights: [:read]}]})
             )

    assert message =~ "callback id is not declared"

    assert {:error, [%{category: :manifest, message: message}]} =
             Hyperlang.Test.program(
               source,
               base_manifest.(%{
                 files: [
                   %{
                     path: "/value",
                     read: "read_value",
                     callbacks: %{read: "read_value"},
                     rights: [:read]
                   }
                 ]
               })
             )

    assert message =~ "ambiguous exports.fileserver callback"

    assert {:error, [%{category: :manifest, message: message}]} =
             Hyperlang.Test.program(
               source,
               base_manifest.(%{
                 files: [
                   %{
                     path: "/value",
                     read: "read_value",
                     rights: [:read],
                     metadata: %{unsafe: self()}
                   }
                 ]
               })
             )

    assert message =~ "invalid exports.fileserver metadata"

    for {files, expected} <- [
          {[%{path: "relative", read: "read_value", rights: [:read]}],
           "filesystem path must be absolute"},
          {[%{path: "/bad\u0000path", read: "read_value", rights: [:read]}], "null byte"},
          {[%{path: "/bad/../path", read: "read_value", rights: [:read]}], "normalized"},
          {[%{path: "/", read: "read_value", rights: [:read]}], "file path cannot be /"},
          {[%{path: "/value", read: "read_value", rights: [:execute]}],
           "invalid exports.fileserver.files right"},
          {[%{path: "/dir", type: :dir, read: "read_value", rights: [:read]}],
           "directory exports cannot declare read/write callbacks"},
          {[%{path: "/value", type: :file, list: :declared, rights: [:list]}],
           "file exports cannot declare list callbacks"},
          {[%{path: "/value", read: "read_value", rights: [:read], effects: [:bump]}],
           "effects require write callback"},
          {[
             %{path: "/intents/update", write: "read_value", rights: [:write], effects: [:delete]}
           ], "invalid exports.fileserver effect"},
          {[
             %{path: "/parent", read: "read_value", rights: [:read]},
             %{path: "/parent/child", read: "read_value", rights: [:read]}
           ], "overlapping exports.fileserver.files path"}
        ] do
      assert {:error, [%{category: :manifest, message: message}]} =
               Hyperlang.Test.program(source, base_manifest.(%{files: files}))

      assert message =~ expected
    end

    assert {:error, [%{category: :manifest, message: message}]} =
             Hyperlang.Test.program(
               source,
               base_manifest.(%{
                 files: [
                   %{path: "/value", read: "read_value", rights: [:read]},
                   %{path: "/value", read: "read_value", rights: [:read]}
                 ]
               })
             )

    assert message =~ "duplicate exports.fileserver.files node"
  end

  test "fileserver descriptor rejects explicit callback profile mismatches" do
    source = """
    callback3(_FidCtx, _Offset, _Count) -> <<"ok">>.
    callback1(_FidCtx) -> [].
    """

    manifest = fn export, file ->
      erlang_public(%{
        exports: %{
          functions: %{"callback" => export},
          fileserver: %{files: [file]}
        }
      })
    end

    cases = [
      {:read, :input, :safe_term, :fileserver_read, :bytes,
       %{path: "/value", read: "callback", rights: [:read]}, "callback3", 3},
      {:read, :output, :status, :fileserver_read, :bytes,
       %{path: "/value", read: "callback", rights: [:read]}, "callback3", 3},
      {:write, :input, :safe_term, :fileserver_write, :status,
       %{path: "/value", write: "callback", rights: [:write]}, "callback3", 3},
      {:write, :output, :bytes, :fileserver_write, :status,
       %{path: "/value", write: "callback", rights: [:write]}, "callback3", 3},
      {:list, :input, :safe_term, :fileserver_list, :list,
       %{path: "/dir", type: :dir, list: "callback", rights: [:list]}, "callback1", 1},
      {:list, :output, :bytes, :fileserver_list, :list,
       %{path: "/dir", type: :dir, list: "callback", rights: [:list]}, "callback1", 1},
      {:stat, :input, :safe_term, :fileserver_stat, :stat,
       %{path: "/dir", type: :dir, stat: "callback", rights: [:stat]}, "callback1", 1},
      {:stat, :output, :bytes, :fileserver_stat, :stat,
       %{path: "/dir", type: :dir, stat: "callback", rights: [:stat]}, "callback1", 1}
    ]

    Enum.each(cases, fn {op, direction, wrong, expected_input, expected_output, file, function,
                         arity} ->
      export =
        %{
          function: function,
          arity: arity,
          input: %{profile: expected_input},
          output: %{profile: expected_output}
        }
        |> put_in([direction, :profile], wrong)

      assert {:error, [%{category: :manifest, message: message, details: details}]} =
               Hyperlang.Test.program(source, manifest.(export, file))

      expected = if direction == :input, do: expected_input, else: expected_output
      assert message =~ "#{op} callback #{direction} profile must be #{expected}"
      assert details.op == op
      assert details.direction == direction
      assert details.expected == expected
      assert details.actual == wrong
    end)
  end

  test "fileserver descriptor rejects adapter-unsupported callback arities" do
    source = "read_value(_A, _B, _C, _D) -> <<\"ok\">>."

    assert {:error, [%{category: :manifest, message: message, details: details}]} =
             Hyperlang.Test.program(
               source,
               erlang_public(%{
                 exports: %{
                   functions: %{"read_value" => %{function: "read_value", arity: 4}},
                   fileserver: %{
                     files: [%{path: "/value", read: "read_value", rights: [:read]}]
                   }
                 }
               })
             )

    assert message =~ "exports.fileserver read callback arity must be 0..3"
    assert details.arity == 4
  end

  test "fileserver dynamic dependency callbacks compile and validate target functions" do
    source = """
    deps_value(_FidCtx) -> [<<"/state/input.txt">>].
    read_value(_FidCtx, _Offset, _Count) -> <<"ok">>.
    """

    manifest =
      erlang_public(%{
        exports: %{
          functions: %{"read_value" => %{function: "read_value", arity: 3}},
          fileserver: %{
            files: [
              %{
                path: "/value",
                read: "read_value",
                rights: [:read, :watch],
                deps: %{function: "deps_value", arity: 1}
              }
            ]
          }
        }
      })

    {:ok, program} = Hyperlang.Test.program(source, manifest)

    assert [
             %{
               path: "/value",
               deps: %{type: :dynamic, function: "deps_value", arity: 1}
             }
           ] = Map.from_struct(program).metadata.exports.files

    assert {:error, [%{category: :verify, message: message}]} =
             Hyperlang.Test.program(
               "read_value(_FidCtx, _Offset, _Count) -> <<\"ok\">>.",
               manifest
             )

    assert message =~ "declared export function not found"
  end

  test "manifest overrides use atom keys and reject unknown siblings instead of failing open" do
    assert {:ok, manifest} = Hyperlang.Manifest.normalize(%{limits: %{wall_ms: 1}})
    assert manifest.limits.wall_ms == 1

    assert {:error, %{category: :manifest, message: message}} =
             Hyperlang.Manifest.normalize(%{"limits" => %{wall_ms: 1}})

    assert message =~ "unknown manifest key"

    assert {:error, %{category: :manifest, message: message}} =
             Hyperlang.Manifest.normalize(%{limits: %{"wall_ms" => 1}})

    assert message =~ "unknown limit key"

    assert {:error, %{category: :manifest, message: message}} =
             Hyperlang.Manifest.normalize(%{imports: %{}})

    assert message =~ "unknown manifest key"

    assert {:ok, manifest} = Hyperlang.Manifest.normalize(%{limits: %{wall_ms: :infinity}})
    assert manifest.limits.wall_ms == :infinity

    assert {:error, %{category: :manifest, message: message}} =
             Hyperlang.Manifest.normalize(%{limits: %{wall_ms: 1, unknown_limit: 1}})

    assert message =~ "unknown limit key"

    assert {:error, %{category: :manifest, message: message}} =
             Hyperlang.Manifest.normalize(%{limits: %{max_call_depth: 1}})

    assert message =~ "unknown limit key"

    assert {:ok, manifest} = Hyperlang.Manifest.normalize(%{stdlib: %{io: false}})
    refute manifest.stdlib.io

    assert {:error, %{category: :manifest, message: message}} =
             Hyperlang.Manifest.normalize(%{
               stdlib: %{io: false, unknown_stdlib: false}
             })

    assert message =~ "unknown stdlib key"

    assert {:error, %{category: :manifest, message: message}} =
             Hyperlang.Manifest.normalize(%{bindings: %{"log" => LogBinding}})

    assert message =~ "unknown limit key"
  end

  test "manifest defaults to deterministic capabilities unless explicitly opted in" do
    assert {:ok, manifest} = Hyperlang.Manifest.normalize(%{})
    refute manifest.capabilities.nondeterminism

    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{capabilities: %{nondeterminism: true}})

    assert manifest.capabilities.nondeterminism

    assert {:ok, manifest} = Hyperlang.Manifest.normalize(%{capabilities: [:non_determinism]})
    assert manifest.capabilities.nondeterminism

    assert {:error, %{category: :manifest, message: message}} =
             Hyperlang.Manifest.normalize(%{capabilities: %{clock_reads: true}})

    assert message =~ "unknown capability key"

    assert {:error, %{category: :manifest, message: message}} =
             Hyperlang.Manifest.normalize(%{bindings: %{"clock" => ClockBinding}})

    assert message =~ "nondeterministic bindings require capabilities.nondeterminism"

    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               capabilities: [:nondeterminism],
               bindings: %{"clock" => ClockBinding}
             })

    assert manifest.bindings["clock"].exports[{"now_ms", 0}].nondeterministic
  end

  test "filesystem compatibility baseline records pinned OTP release and source references" do
    metadata = Hyperlang.CompatibilityBaseline.metadata()
    patch_log = Path.expand("../#{metadata.patch_log}", __DIR__)
    patch_log_text = File.read!(patch_log)

    assert metadata.otp_release == Hyperlang.Stdlib.otp_release()
    assert patch_log_text =~ "OTP release: #{metadata.otp_release}"

    for {key, source} <- metadata.otp_sources do
      assert source.source_path =~ ".erl" or source.source_path =~ ".hrl"
      assert patch_log_text =~ "`#{key}`"
      assert patch_log_text =~ "`#{source.app}`"
      assert patch_log_text =~ "`#{source.source_path}`"
    end

    for {key, vendor} <- metadata.vendor_sources do
      vendor_path = Path.expand("../#{vendor.vendor_path}", __DIR__)
      assert File.exists?(vendor_path)
      assert metadata.otp_sources[vendor.source_key]
      assert patch_log_text =~ "`#{key}`"
      assert patch_log_text =~ "`#{vendor.vendor_path}`"
      assert patch_log_text =~ "`#{vendor.sha256}`"
      assert sha256_file(vendor_path) == vendor.sha256
    end
  end

  test "filesystem OTP vendor integrity records source hashes and patch-log entries" do
    metadata = Hyperlang.CompatibilityBaseline.metadata()
    patch_log_text = File.read!(Path.expand("../#{metadata.patch_log}", __DIR__))

    assert patch_log_text =~ "scripts/update_otp_filesystem.sh"

    expected_sources = MapSet.new([:file, :filelib, :file_hrl])

    filesystem_sources =
      metadata.vendor_sources
      |> Enum.filter(fn {_key, vendor} ->
        source = Map.fetch!(metadata.otp_sources, vendor.source_key)

        source.role in [
          :filesystem_compatibility,
          :filesystem_metadata_shape
        ]
      end)
      |> Map.new()

    assert MapSet.new(Map.keys(filesystem_sources)) == expected_sources

    for {key, vendor} <- filesystem_sources do
      source = Map.fetch!(metadata.otp_sources, vendor.source_key)
      vendor_path = Path.expand("../#{vendor.vendor_path}", __DIR__)

      assert source.role in [
               :filesystem_compatibility,
               :filesystem_metadata_shape
             ]

      assert File.regular?(vendor_path)
      assert sha256_file(vendor_path) == vendor.sha256
      assert patch_log_text =~ "`#{key}`"
      assert patch_log_text =~ "`#{source.source_path}`"
      assert patch_log_text =~ "`#{vendor.vendor_path}`"
      assert patch_log_text =~ "`#{vendor.sha256}`"
    end
  end

  test "vendored stdout formatter tracks OTP io_lib formatting" do
    cases = [
      {~c"plain text", []},
      {~c"~p", [{:ok, [1, 2], %{foo: "bar"}}]},
      {~c"~w", [{:ok, [1, 2], %{foo: "bar"}}]},
      {~c"~s", [~c"abc"]},
      {~c"~ts", ["✨"]},
      {~c"~.2f", [1.2345]},
      {~c"~8.16.0B", [255]},
      {~c"~p ~ts ~.1f", [{:tuple, :value}, "snow", 3.14]}
    ]

    for {format, args} <- cases do
      assert :hyperlang_otp_io_lib.format(format, args) == :io_lib.format(format, args)
    end
  end

  test "runtime stdlib compatibility does not auto-admit live OTP exports" do
    assert {:module, :file} = :code.ensure_loaded(:file)
    assert :erlang.function_exported(:file, :read_file, 1)
    assert Hyperlang.Stdlib.call_target("file", "read_file", 1) == :error

    assert :erlang.function_exported(:erlang, :system_info, 1)
    assert Hyperlang.Stdlib.call_target("erlang", "system_info", 1) == :error
  end

  test "compatibility audit rejects abstract and BEAM ambient escape calls" do
    module = :"hyperlang_bad_compat_#{System.unique_integer([:positive])}"

    forms = [
      {:attribute, 0, :module, module},
      {:attribute, 0, :export,
       [read: 1, port: 0, pid: 0, glob: 1, proc: 0, dyn: 3, send: 1, spawn_req: 1]},
      {:function, 0, :read, 1,
       [
         {:clause, 0, [{:var, 0, :Path}], [],
          [
            {:call, 0, {:remote, 0, {:atom, 0, :prim_file}, {:atom, 0, :read_file}},
             [{:var, 0, :Path}]}
          ]}
       ]},
      {:function, 0, :port, 0,
       [
         {:clause, 0, [], [],
          [
            {:call, 0, {:remote, 0, {:atom, 0, :erlang}, {:atom, 0, :open_port}},
             [
               {:tuple, 0, [{:atom, 0, :spawn}, {:string, 0, ~c"cat"}]},
               {nil, 0}
             ]}
          ]}
       ]},
      {:function, 0, :pid, 0,
       [
         {:clause, 0, [], [],
          [
            {:call, 0, {:remote, 0, {:atom, 0, :erlang}, {:atom, 0, :self}}, []}
          ]}
       ]},
      {:function, 0, :glob, 1,
       [
         {:clause, 0, [{:var, 0, :Pattern}], [],
          [
            {:call, 0, {:remote, 0, {:atom, 0, :filelib}, {:atom, 0, :wildcard}},
             [{:var, 0, :Pattern}]}
          ]}
       ]},
      {:function, 0, :proc, 0,
       [
         {:clause, 0, [], [],
          [
            {:call, 0, {:remote, 0, {:atom, 0, Process}, {:atom, 0, :get}},
             [{:atom, 0, :unsafe_process_key}]}
          ]}
       ]},
      {:function, 0, :dyn, 3,
       [
         {:clause, 0, [{:var, 0, :Module}, {:var, 0, :Function}, {:var, 0, :Arg}], [],
          [
            {:call, 0, {:remote, 0, {:var, 0, :Module}, {:var, 0, :Function}}, [{:var, 0, :Arg}]}
          ]}
       ]},
      {:function, 0, :send, 1,
       [
         {:clause, 0, [{:var, 0, :Pid}], [],
          [
            {:op, 0, :!, {:var, 0, :Pid}, {:atom, 0, :ok}}
          ]}
       ]},
      {:function, 0, :spawn_req, 1,
       [
         {:clause, 0, [{:var, 0, :Fun}], [],
          [
            {:call, 0, {:remote, 0, {:atom, 0, :erlang}, {:atom, 0, :spawn_request}},
             [{:var, 0, :Fun}]}
          ]}
       ]}
    ]

    assert {:error, abstract_findings} = Hyperlang.CompatibilityAudit.audit_abstract_forms(forms)
    assert Enum.any?(abstract_findings, &(&1.layer == :abstract and &1.module == :prim_file))

    assert Enum.any?(
             abstract_findings,
             &(&1.layer == :abstract and &1.module == :erlang and &1.function == :open_port)
           )

    assert Enum.any?(
             abstract_findings,
             &(&1.layer == :abstract and &1.module == :erlang and &1.function == :self)
           )

    assert Enum.any?(abstract_findings, &(&1.layer == :abstract and &1.module == :filelib))

    assert Enum.any?(abstract_findings, &(&1.layer == :abstract and &1.module == Process))

    assert Enum.any?(
             abstract_findings,
             &(&1.layer == :abstract and &1.module == :erlang and &1.function == :apply)
           )

    assert Enum.any?(
             abstract_findings,
             &(&1.layer == :abstract and &1.module == :erlang and &1.function == :send)
           )

    assert Enum.any?(
             abstract_findings,
             &(&1.layer == :abstract and &1.module == :erlang and &1.function == :spawn_request)
           )

    assert {:ok, ^module, beam} = :compile.forms(forms, [:binary, :debug_info])
    beam_path = Path.join(System.tmp_dir!(), "#{module}.beam")
    File.write!(beam_path, beam)

    try do
      assert {:error, beam_findings} =
               Hyperlang.CompatibilityAudit.audit_beam_file(String.to_charlist(beam_path))

      assert Enum.any?(beam_findings, &(&1.layer == :beam and &1.module == :prim_file))

      assert Enum.any?(
               beam_findings,
               &(&1.layer == :beam and &1.module == :erlang and &1.function == :open_port)
             )

      assert Enum.any?(
               beam_findings,
               &(&1.layer == :beam and &1.module == :erlang and &1.function == :self)
             )

      assert Enum.any?(beam_findings, &(&1.layer == :beam and &1.module == :filelib))

      assert Enum.any?(beam_findings, &(&1.layer == :beam and &1.module == Process))

      assert Enum.any?(
               beam_findings,
               &(&1.layer == :beam and &1.module == :erlang and &1.function == :apply)
             )

      assert Enum.any?(
               beam_findings,
               &(&1.layer == :beam and &1.module == :erlang and &1.function == :send)
             )

      assert Enum.any?(
               beam_findings,
               &(&1.layer == :beam and &1.module == :erlang and &1.function == :spawn_request)
             )
    after
      File.rm(beam_path)
    end
  end

  test "compatibility audit passes real compatibility modules" do
    assert :ok = Hyperlang.CompatibilityAudit.audit_default_modules()
  end

  test "filesystem compatibility surface resolves exactly the supported guest MFAs" do
    enabled = %{
      filesystem: %{
        enabled: true,
        file_compat: true,
        filelib_compat: true,
        handle_compat: true,
        loader_compat: true
      },
      sys: %{enabled: false}
    }

    {file_exports, filelib_exports} =
      Hyperlang.Filesystem.supported_mfas()
      |> Enum.filter(fn {module, _function, _arity} -> module in ["file", "filelib"] end)
      |> Enum.split_with(fn {module, _function, _arity} -> module == "file" end)

    # Every advertised file:/filelib: MFA must resolve to a lowering operation
    # through the MFA tables, and nothing else may resolve.
    for {module, function, arity} <- file_exports ++ filelib_exports do
      assert Hyperlang.Filesystem.call_target(enabled, module, function, arity) != :error,
             "#{module}:#{function}/#{arity} is advertised but does not resolve"
    end

    sys_module_exports =
      Hyperlang.Sys.module_info(:exports)
      |> Enum.reject(fn {function, _arity} ->
        function in [
          :__info__,
          :module_info,
          :supported_sys_mfas,
          :call_target,
          :known_call?
        ]
      end)
      |> Enum.sort()

    sys_exports = Hyperlang.Sys.supported_sys_mfas()

    assert Enum.sort(file_exports ++ filelib_exports ++ sys_exports) ==
             Hyperlang.Filesystem.supported_mfas()

    for {_module, function, arity} <- sys_exports do
      assert {String.to_existing_atom(function), arity + 1} in sys_module_exports
    end

    exported = MapSet.new(file_exports ++ filelib_exports)

    for unsupported <- current_otp_unsupported_filesystem_mfas() do
      refute MapSet.member?(exported, unsupported)
    end

    assert Hyperlang.Filesystem.WildcardBridge.module_info(:exports)
           |> Enum.reject(fn {function, _arity} -> function in [:__info__, :module_info] end)
           |> Enum.sort() == [
             list_dir: 1,
             read_file_info: 1,
             read_link_info: 1,
             with_callbacks: 2,
             with_callbacks: 3
           ]
  end

  test "removed compatibility facades are not exposed as supported guest MFAs" do
    refute Hyperlang.Sys.known_call?("hbfs", "open", 2)
    refute Hyperlang.Sys.known_call?("sys", "webpark", 2)
    refute {"hbfs", "open", 2} in Hyperlang.Filesystem.supported_mfas()
    refute {"sys", "webpark", 2} in Hyperlang.Sys.supported_sys_mfas()
  end

  test "manifest rejects reserved authority module imports before classification" do
    for key <- [
          {"file", "read_file", 1},
          {"prim_file", "read_file", 1},
          {"code", "ensure_loaded", 1},
          {"compile", "file", 1},
          {"erl_eval", "exprs", 2},
          {"os", "cmd", 1},
          {"socket", "open", 2},
          {"prim_inet", "open", 3},
          {"gen_tcp", "connect", 3},
          {"gen_sctp", "open", 1},
          {"httpc", "request", 1},
          {"ftp", "open", 1},
          {"ssh", "connect", 3},
          {"ets", "new", 2},
          {"disk_log", "open", 1},
          {"net_adm", "ping", 1},
          {"rpc", "call", 4}
        ] do
      {module, _function, _arity} = key

      assert {:error, %{category: :manifest, message: message}} =
               Hyperlang.Manifest.normalize(%{bindings: %{module => KVBinding}})

      assert message =~ "reserved"
    end

    assert {:ok, manifest} = Hyperlang.Manifest.normalize(%{bindings: %{"asset" => KVBinding}})
    assert manifest.bindings["asset"].exports[{"read", 1}].call == {"asset", "read", 1}
  end

  test "manifest binding lookup resolves atom and binary call names to the pinned export" do
    assert {:ok, manifest} = Hyperlang.Manifest.normalize(%{bindings: %{"kv" => KVBinding}})

    assert Hyperlang.Manifest.binding_for_call(manifest, :kv, :get, 1).call == {"kv", "get", 1}
    assert Hyperlang.Manifest.binding_for_call(manifest, {"kv", "get", 1}).binding == "kv"
    assert Hyperlang.Manifest.binding_for_call(manifest, "kv", "put", 2) == nil
  end

  test "filesystem manifest schema normalizes defaults and valid mounts" do
    host_dir = Path.join(System.tmp_dir!(), "hyperlang_fs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(host_dir)
    on_exit(fn -> File.rm_rf(host_dir) end)

    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               sys: %{
                 enabled: true
               },
               filesystem: %{
                 enabled: true,
                 cwd: "/work",
                 allow_relative_paths: true,
                 file_compat: true,
                 filelib_compat: true,
                 handle_compat: true,
                 loader_compat: true,
                 source_compile: true,
                 commit_policy: "on_eval_success",
                 limits: %{max_mounts: 3, max_path_bytes: 128},
                 atom_vocabularies: %{filesystem: true, re: true},
                 mounts: [
                   %{
                     virtual: "/data",
                     backend: %{type: "host", path: host_dir},
                     mode: "read_only",
                     allow: ["read", "stat"]
                   },
                   %{
                     virtual: "/tmp",
                     backend: "memory",
                     mode: "memory",
                     allow: ["read", "write", "list"]
                   }
                 ]
               }
             })

    assert manifest.sys.enabled
    assert manifest.filesystem.enabled
    assert manifest.filesystem.cwd == "/work"
    assert manifest.filesystem.allow_relative_paths
    assert manifest.filesystem.file_compat
    assert manifest.filesystem.filelib_compat
    assert manifest.filesystem.handle_compat
    assert manifest.filesystem.loader_compat
    assert manifest.filesystem.source_compile
    assert manifest.filesystem.commit_policy == :on_eval_success
    assert manifest.filesystem.limits.max_mounts == 3
    assert manifest.filesystem.limits.max_path_bytes == 128
    assert manifest.filesystem.atom_vocabularies.filesystem
    assert manifest.filesystem.atom_vocabularies.re
    refute manifest.filesystem.atom_vocabularies.loader

    assert [
             %{
               virtual: "/data",
               backend: {:host, host_backend_path},
               mode: :read_only,
               allow: [:read, :stat],
               overlay: nil
             },
             %{
               virtual: "/tmp",
               backend: :memory,
               mode: :memory,
               allow: [:list, :read, :write],
               overlay: nil
             }
           ] = manifest.filesystem.mounts

    assert String.ends_with?(host_backend_path, "/" <> Path.basename(host_dir))

    assert {:ok, program} =
             Hyperlang.Test.program("1.", %{
               sys: %{
                 enabled: true
               },
               filesystem: %{
                 enabled: true,
                 cwd: "/work",
                 allow_relative_paths: true,
                 file_compat: true,
                 filelib_compat: true,
                 handle_compat: true,
                 loader_compat: true,
                 source_compile: true,
                 commit_policy: :on_eval_success,
                 limits: %{max_mounts: 3, max_path_bytes: 128},
                 atom_vocabularies: %{filesystem: true, re: true},
                 mounts: [
                   %{
                     virtual: "/data",
                     backend: {:host, host_dir},
                     mode: :read_only,
                     allow: [:read, :stat, :lstat]
                   }
                 ]
               }
             })

    filesystem = Map.from_struct(program).metadata.filesystem
    sys = Map.from_struct(program).metadata.sys

    assert sys.enabled
    assert filesystem.enabled
    assert filesystem.cwd == "/work"
    assert filesystem.allow_relative_paths
    assert filesystem.file_compat
    assert filesystem.filelib_compat
    assert filesystem.handle_compat
    assert filesystem.loader_compat
    assert filesystem.source_compile
    assert filesystem.commit_policy == :on_eval_success
    assert filesystem.limits.max_mounts == 3
    assert filesystem.limits.max_path_bytes == 128
    assert filesystem.atom_vocabularies.filesystem
    assert filesystem.atom_vocabularies.re
    assert [%{virtual: "/data", backend: :host, overlay: nil}] = filesystem.mounts
    refute inspect(filesystem) =~ host_dir

    assert {:ok, default_program} = Hyperlang.Test.program("1.", %{})

    filesystem = Map.from_struct(default_program).metadata.filesystem
    sys = Map.from_struct(default_program).metadata.sys

    refute sys.enabled
    refute filesystem.enabled
    assert filesystem.cwd == "/"
    refute filesystem.allow_relative_paths
    refute filesystem.file_compat
    refute filesystem.filelib_compat
    refute filesystem.handle_compat
    refute filesystem.loader_compat
    refute filesystem.source_compile
    assert filesystem.commit_policy == :per_request
    assert filesystem.mounts == []
    assert filesystem.limits.max_mounts == 64
    assert filesystem.limits.max_path_bytes == 4096
  end

  test "filesystem manifest schema rejects unknown keys and invalid mount shapes" do
    host_dir = Path.join(System.tmp_dir!(), "hyperlang_fs_#{System.unique_integer([:positive])}")
    host_file = Path.join(host_dir, "not_a_dir")
    File.mkdir_p!(host_dir)
    File.write!(host_file, "not a directory")
    on_exit(fn -> File.rm_rf(host_dir) end)

    invalids = [
      {%{filesystem: %{unknown: true}}, "unknown filesystem key"},
      {%{filesystem: %{limits: %{unknown_limit: 1}}}, "unknown filesystem limit key"},
      {%{filesystem: %{atom_vocabularies: %{unknown_vocab: true}}},
       "unknown filesystem atom vocabulary key"},
      {%{filesystem: %{mounts: [%{virtual: "/tmp", backend: "memory", unknown_mount: true}]}},
       "unknown filesystem mount key"},
      {%{filesystem: %{mounts: [%{virtual: "relative", backend: "memory"}]}},
       "filesystem path must be absolute"},
      {%{filesystem: %{mounts: [%{virtual: "/bad//path", backend: "memory"}]}},
       "empty components"},
      {%{filesystem: %{mounts: [%{virtual: "/bad/path/", backend: "memory"}]}}, "normalized"},
      {%{filesystem: %{mounts: [%{virtual: "/bad\u0000path", backend: "memory"}]}}, "null byte"},
      {%{filesystem: %{mounts: [%{virtual: "/bad\\path", backend: "memory"}]}},
       "POSIX separators"},
      {%{filesystem: %{mounts: [%{virtual: "/bad/./path", backend: "memory"}]}}, "normalized"},
      {%{filesystem: %{mounts: [%{virtual: "/bad/../path", backend: "memory"}]}}, "normalized"},
      {%{filesystem: %{mounts: [%{virtual: "/bad", backend: "memory", host_path: host_dir}]}},
       "memory filesystem mounts must not specify host_path"},
      {%{
         filesystem: %{
           mounts: [
             %{virtual: "/bad", backend: %{type: "memory", path: host_dir}}
           ]
         }
       }, "memory filesystem mounts must not specify host_path"},
      {%{
         filesystem: %{
           mounts: [
             %{virtual: "/bad", backend: %{kind: :memory}, host_path: host_dir}
           ]
         }
       }, "memory filesystem mounts must not specify host_path"},
      {%{
         filesystem: %{
           mounts: [
             %{virtual: "/bad", backend: %{type: "memory", host_path: host_dir}}
           ]
         }
       }, "unknown filesystem mount backend key"},
      {%{
         filesystem: %{
           mounts: [
             %{virtual: "/bad", backend: %{kind: :memory, host_path: host_dir}}
           ]
         }
       }, "unknown filesystem mount backend key"},
      {%{
         filesystem: %{
           mounts: [
             %{
               virtual: "/bad",
               backend: %{type: "memory", options: %{host_path: host_dir}}
             }
           ]
         }
       }, "unknown filesystem mount backend key"},
      {%{filesystem: %{mounts: [%{virtual: "/overlay", backend: "memory", mode: :overlay}]}},
       "overlay filesystem mounts require a canonical host directory"},
      {%{
         filesystem: %{
           mounts: [%{virtual: "/missing", backend: {:host, Path.join(host_dir, "missing")}}]
         }
       }, "existing directory"},
      {%{
         filesystem: %{
           mounts: [%{virtual: "/not_dir", backend: {:host, host_file}}]
         }
       }, "existing directory"},
      {%{
         filesystem: %{
           mounts: [
             %{virtual: "/dup", backend: "memory"},
             %{virtual: "/dup", backend: "memory"}
           ]
         }
       }, "duplicate filesystem mount virtual root"},
      {%{
         filesystem: %{
           mounts: [
             %{
               virtual: "/legacy_purpose",
               backend: "memory",
               purpose: :data
             }
           ]
         }
       }, "unknown filesystem mount key"}
    ]

    for {manifest, expected} <- invalids do
      assert {:error, %{category: :manifest, message: message}} =
               Hyperlang.Manifest.normalize(manifest)

      assert message =~ expected
    end

    long_component = String.duplicate("a", 256)

    assert {:error, %{category: :manifest, message: message}} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 limits: %{max_component_bytes: 10},
                 mounts: [%{virtual: "/#{long_component}", backend: "memory"}]
               }
             })

    assert message =~ "component"

    assert {:error, %{category: :manifest, message: message}} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 limits: %{max_path_bytes: 8},
                 mounts: [%{virtual: "/too-long", backend: "memory"}]
               }
             })

    assert message =~ "max_path_bytes"
  end

  test "filesystem host roots are canonicalized through symlinks" do
    parent = Path.join(System.tmp_dir!(), "hyperlang_fs_#{System.unique_integer([:positive])}")
    real_dir = Path.join(parent, "real")
    real_child_dir = Path.join(real_dir, "child")
    link_dir = Path.join(parent, "link")
    File.mkdir_p!(real_child_dir)
    on_exit(fn -> File.rm_rf(parent) end)

    case File.ln_s(real_dir, link_dir) do
      :ok ->
        assert {:ok, manifest} =
                 Hyperlang.Manifest.normalize(%{
                   filesystem: %{
                     mounts: [
                       %{
                         virtual: "/data",
                         backend: {:host, Path.join(link_dir, "child")}
                       }
                     ]
                   }
                 })

        assert [%{backend: {:host, canonical_path}}] = manifest.filesystem.mounts
        assert String.ends_with?(canonical_path, "/real/child")
        refute canonical_path =~ "/link/"

      {:error, :enotsup} ->
        :ok
    end
  end

  test "filesystem host-backed mounts normalize canonical host backend paths" do
    host_dir = Path.join(System.tmp_dir!(), "hyperlang_fs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(host_dir)
    on_exit(fn -> File.rm_rf(host_dir) end)

    assert {:ok, host_mount} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/host_rw",
                     backend: {:host, host_dir},
                     mode: :read_write
                   }
                 ]
               }
             })

    assert [
             %{virtual: "/host_rw", backend: {:host, host_backend_path}, mode: :read_write}
           ] =
             host_mount.filesystem.mounts

    assert String.ends_with?(host_backend_path, "/" <> Path.basename(host_dir))

    assert {:ok, snapshot} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/snapshot",
                     backend: {:host, host_dir},
                     mode: :snapshot
                   }
                 ]
               }
             })

    assert [%{virtual: "/snapshot", backend: {:host, snapshot_backend_path}, mode: :snapshot}] =
             snapshot.filesystem.mounts

    assert String.ends_with?(snapshot_backend_path, "/" <> Path.basename(host_dir))
  end

  test "filesystem host read-only backend virtualizes reads listings and stats" do
    root = Path.join(System.tmp_dir!(), "hyperlang_host_ro_#{System.unique_integer([:positive])}")

    outside =
      Path.join(System.tmp_dir!(), "hyperlang_host_out_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "dir"))
    File.write!(Path.join(root, "file.txt"), "alpha")
    File.write!(Path.join(root, "dir/nested.txt"), "beta")
    File.write!(outside, "secret")

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(outside)
    end)

    symlink_result = File.ln_s(outside, Path.join(root, "outbound"))

    source = ~S"""
    {ok, <<"alpha">>} = file:read_file("/host/file.txt"),
    {ok, Names} = file:list_dir("/host"),
    {ok, Info} = file:read_file_info("/host/file.txt"),
    {ok, DirInfo} = file:read_file_info("/host/dir"),
    #{<<"names">> => Names,
      <<"file_info">> => Info,
      <<"dir_info">> => DirInfo,
      <<"missing">> => file:read_file("/host/missing.txt"),
      <<"prefix_confusion">> => file:read_file("/hostile/file.txt"),
      <<"dotdot_escape">> => file:read_file("/host/../../etc/passwd")}.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          filesystem: %{
            enabled: true,
            file_compat: true,
            mounts: [
              %{
                virtual: "/host",
                backend: {:host, root},
                mode: :read_only,
                allow: [:read, :list, :stat]
              }
            ]
          }
        })
      )

    assert {:ok,
            %{
              <<"names">> => names,
              <<"file_info">> => file_info,
              <<"dir_info">> => dir_info,
              <<"missing">> => {:error, :enoent},
              <<"prefix_confusion">> => {:error, :eacces},
              <<"dotdot_escape">> => {:error, :eacces}
            } = result} = eval(instance, :ok)

    assert ~c"file.txt" in names
    assert ~c"dir" in names
    if symlink_result == :ok, do: assert(~c"outbound" in names)

    assert {:file_info, 5, :regular, _access, _, _, _, file_mode, 1, 0, 0, 0, 0, 0} =
             file_info

    assert Bitwise.band(file_mode, 0o100000) == 0o100000

    assert {:file_info, 0, :directory, _access, _, _, _, dir_mode, 1, 0, 0, 0, 0, 0} =
             dir_info

    assert Bitwise.band(dir_mode, 0o040000) == 0o040000

    refute inspect(result) =~ root
    refute inspect(result) =~ outside
  end

  test "filesystem host read-only backend follows existing symlinks without leaking host paths" do
    root =
      Path.join(System.tmp_dir!(), "hyperlang_host_symlink_#{System.unique_integer([:positive])}")

    outside =
      Path.join(
        System.tmp_dir!(),
        "hyperlang_host_symlink_out_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.write!(outside, "secret")

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(outside)
    end)

    case File.ln_s(outside, Path.join(root, "outbound")) do
      :ok ->
        source = ~S"""
        #{<<"list">> => file:list_dir("/host"),
          <<"read">> => file:read_file("/host/outbound"),
          <<"stat">> => file:read_file_info("/host/outbound"),
          <<"link_stat">> => file:read_link_info("/host/outbound")}.
        """

        {_program, instance} =
          compile_and_instance(
            source,
            erlang_public(%{
              filesystem: %{
                enabled: true,
                file_compat: true,
                mounts: [
                  %{
                    virtual: "/host",
                    backend: {:host, root},
                    mode: :read_only,
                    allow: [:read, :list, :stat, :lstat]
                  }
                ]
              }
            })
          )

        assert {:ok,
                %{
                  <<"list">> => {:ok, [~c"outbound"]},
                  <<"read">> => {:ok, <<"secret">>},
                  <<"stat">> =>
                    {:ok,
                     {:file_info, 6, :regular, _access, _, _, _, file_mode, 1, 0, 0, 0, 0, 0}},
                  <<"link_stat">> =>
                    {:ok,
                     {:file_info, _link_size, :symlink, _link_access, _, _, _, link_mode, 1, 0, 0,
                      0, 0, 0}}
                } = result} = eval(instance, :ok)

        assert Bitwise.band(file_mode, 0o100000) == 0o100000
        assert Bitwise.band(link_mode, 0o120000) == 0o120000

        refute inspect(result) =~ root
        refute inspect(result) =~ outside

      {:error, :enotsup} ->
        :ok
    end
  end

  test "filesystem overlay backend captures writes deletes mkdirs and merged listings in memory" do
    root = Path.join(System.tmp_dir!(), "hyperlang_overlay_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "dir"))
    File.write!(Path.join(root, "host.txt"), "host")
    File.write!(Path.join(root, "delete_me.txt"), "delete")
    File.write!(Path.join(root, "dir/nested.txt"), "nested")

    on_exit(fn -> File.rm_rf(root) end)

    source = ~S"""
    {ok, <<"host">>} = file:read_file("/ov/host.txt"),
    {ok, <<"live">>} = file:read_file("/ov/live_after.txt"),
    ok = file:write_file("/ov/new.txt", <<"overlay">>),
    ok = file:write_file("/ov/host.txt", <<"changed">>),
    ok = file:delete("/ov/delete_me.txt"),
    ok = file:make_dir("/ov/mkdir"),
    {ok, Names} = file:list_dir("/ov"),
    #{<<"changed">> => file:read_file("/ov/host.txt"),
      <<"deleted">> => file:read_file("/ov/delete_me.txt"),
      <<"live_after">> => file:read_file("/ov/live_after.txt"),
      <<"new">> => file:read_file("/ov/new.txt"),
      <<"names">> => Names}.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          filesystem: %{
            enabled: true,
            file_compat: true,
            mounts: [
              %{
                virtual: "/ov",
                backend: {:host, root},
                mode: :overlay,
                allow: [:read, :write, :delete, :mkdir, :list, :rename, :stat]
              }
            ]
          }
        })
      )

    File.write!(Path.join(root, "live_after.txt"), "live")

    assert {:ok,
            %{
              <<"changed">> => {:ok, <<"changed">>},
              <<"deleted">> => {:error, :enoent},
              <<"live_after">> => {:ok, <<"live">>},
              <<"new">> => {:ok, <<"overlay">>},
              <<"names">> => names
            }} = eval(instance, :ok)

    assert ~c"dir" in names
    assert ~c"host.txt" in names
    assert ~c"live_after.txt" in names
    assert ~c"mkdir" in names
    assert ~c"new.txt" in names
    refute ~c"delete_me.txt" in names

    assert File.read!(Path.join(root, "host.txt")) == "host"
    assert File.read!(Path.join(root, "delete_me.txt")) == "delete"
    refute File.exists?(Path.join(root, "new.txt"))
    refute File.exists?(Path.join(root, "mkdir"))
  end

  test "filesystem overlay backend renames descendants and returns OTP-shaped rename errors" do
    root =
      Path.join(
        System.tmp_dir!(),
        "hyperlang_overlay_rename_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "dir"))
    File.mkdir_p!(Path.join(root, "dir/sub"))
    File.mkdir_p!(Path.join(root, "target_dir"))
    File.write!(Path.join(root, "dir/a.txt"), "a")
    File.write!(Path.join(root, "dir/sub/deleted.txt"), "deleted")
    File.write!(Path.join(root, "file.txt"), "file")

    on_exit(fn -> File.rm_rf(root) end)

    source = ~S"""
    ok = file:delete("/ov/dir/sub/deleted.txt"),
    ok = file:rename("/ov/dir", "/ov/moved"),
    {ok, <<"a">>} = file:read_file("/ov/moved/a.txt"),
    #{<<"deleted_descendant_new">> => file:read_file("/ov/moved/sub/deleted.txt"),
      <<"deleted_descendant_old">> => file:read_file("/ov/dir/sub/deleted.txt"),
      <<"descendant">> => file:rename("/ov/moved", "/ov/moved/sub"),
      <<"file_over_dir">> => file:rename("/ov/file.txt", "/ov/target_dir"),
      <<"dir_over_file">> => file:rename("/ov/moved", "/ov/file.txt"),
      <<"cross_mount">> => file:rename("/ov/moved", "/other/moved")}.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          filesystem: %{
            enabled: true,
            file_compat: true,
            mounts: [
              %{
                virtual: "/ov",
                backend: {:host, root},
                mode: :overlay,
                allow: [:read, :write, :delete, :mkdir, :list, :rename, :stat]
              },
              %{virtual: "/other", backend: "memory", mode: :memory, allow: [:rename]}
            ]
          }
        })
      )

    assert eval(instance, :ok) ==
             {:ok,
              %{
                <<"deleted_descendant_new">> => {:error, :enoent},
                <<"deleted_descendant_old">> => {:error, :enoent},
                <<"descendant">> => {:error, :einval},
                <<"file_over_dir">> => {:error, :eisdir},
                <<"dir_over_file">> => {:error, :enotdir},
                <<"cross_mount">> => {:error, :exdev}
              }}

    assert File.exists?(Path.join(root, "dir/a.txt"))
    refute File.exists?(Path.join(root, "moved/a.txt"))
  end

  test "filesystem overlay backend rejects outbound and broken symlink renames" do
    root =
      Path.join(
        System.tmp_dir!(),
        "hyperlang_overlay_symlink_#{System.unique_integer([:positive])}"
      )

    outside =
      Path.join(
        System.tmp_dir!(),
        "hyperlang_overlay_symlink_out_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.write!(outside, "secret")

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(outside)
    end)

    with :ok <- File.ln_s(outside, Path.join(root, "outbound")),
         :ok <- File.ln_s(Path.join(root, "missing"), Path.join(root, "broken")) do
      source = ~S"""
      #{<<"outbound">> => file:rename("/ov/outbound", "/ov/outbound2"),
        <<"broken">> => file:rename("/ov/broken", "/ov/broken2")}.
      """

      {_program, instance} =
        compile_and_instance(
          source,
          erlang_public(%{
            filesystem: %{
              enabled: true,
              file_compat: true,
              mounts: [
                %{
                  virtual: "/ov",
                  backend: {:host, root},
                  mode: :overlay,
                  allow: [:read, :write, :delete, :mkdir, :list, :rename, :stat]
                }
              ]
            }
          })
        )

      assert eval(instance, :ok) ==
               {:ok,
                %{
                  <<"outbound">> => {:error, :eacces},
                  <<"broken">> => {:error, :eacces}
                }}
    else
      {:error, :enotsup} -> :ok
    end
  end

  test "filesystem overlay backend rejects host symlink reads stats and listings" do
    root =
      Path.join(
        System.tmp_dir!(),
        "hyperlang_overlay_symlink_read_#{System.unique_integer([:positive])}"
      )

    outside_file =
      Path.join(
        System.tmp_dir!(),
        "hyperlang_overlay_symlink_read_out_#{System.unique_integer([:positive])}"
      )

    outside_dir =
      Path.join(
        System.tmp_dir!(),
        "hyperlang_overlay_symlink_read_dir_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.write!(outside_file, "secret")
    File.mkdir_p!(outside_dir)
    File.write!(Path.join(outside_dir, "a.txt"), "outside")

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(outside_file)
      File.rm_rf(outside_dir)
    end)

    with :ok <- File.ln_s(outside_file, Path.join(root, "outbound")),
         :ok <- File.ln_s(outside_dir, Path.join(root, "outbound_dir")) do
      assert {:ok, manifest} =
               Hyperlang.Manifest.normalize(%{
                 filesystem: %{
                   mounts: [
                     %{
                       virtual: "/ov",
                       backend: {:host, root},
                       mode: :overlay,
                       allow: [:read, :write, :delete, :mkdir, :list, :rename, :stat, :lstat]
                     }
                   ]
                 }
               })

      assert {:ok, handle} = Hyperlang.Filesystem.start(manifest.filesystem)
      on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

      assert Hyperlang.Filesystem.read_file(handle, "/ov/outbound") == {:error, :eacces}
      assert Hyperlang.Filesystem.stat(handle, "/ov/outbound") == {:error, :eacces}
      assert Hyperlang.Filesystem.list_dir(handle, "/ov/outbound_dir") == {:error, :eacces}
      assert {:ok, %{type: :symlink}} = Hyperlang.Filesystem.link_stat(handle, "/ov/outbound")
      assert {:ok, names} = Hyperlang.Filesystem.list_dir(handle, "/ov")
      assert "outbound" in names
      assert "outbound_dir" in names
    else
      {:error, :enotsup} -> :ok
    end
  end

  test "filesystem mount table supports longest-prefix lookup with path boundaries" do
    host_dir = Path.join(System.tmp_dir!(), "hyperlang_fs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(host_dir)
    on_exit(fn -> File.rm_rf(host_dir) end)

    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{virtual: "/", backend: "memory", mode: :memory},
                   %{virtual: "/data", backend: "memory", mode: :memory},
                   %{virtual: "/data/private", backend: "memory", mode: :memory},
                   %{
                     virtual: "/overlay",
                     backend: {:host, host_dir},
                     mode: :overlay
                   }
                 ]
               }
             })

    assert {:ok, %{mount: %{virtual: "/data"}, relative_path: "/a"}} =
             Hyperlang.Filesystem.resolve_mount(manifest.filesystem, "/data/a")

    assert {:ok, %{mount: %{virtual: "/data/private"}, relative_path: "/a"}} =
             Hyperlang.Filesystem.resolve_mount(manifest.filesystem, "/data/private/a")

    assert {:ok, %{mount: %{virtual: "/"}, relative_path: "/data2/a"}} =
             Hyperlang.Filesystem.resolve_mount(manifest.filesystem, "/data2/a")

    assert {:ok, %{mount: %{virtual: "/data"}, relative_path: "/"}} =
             Hyperlang.Filesystem.resolve_mount(manifest.filesystem, "/data")

    assert [%{virtual: "/overlay", mode: :overlay, overlay: :memory}] =
             Enum.filter(manifest.filesystem.mounts, &(&1.virtual == "/overlay"))
  end

  test "filesystem mount table reports no match without prefix confusion" do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{virtual: "/data", backend: "memory", mode: :memory}
                 ]
               }
             })

    assert {:error, error} = Hyperlang.Filesystem.resolve_mount(manifest.filesystem, "/data2/a")
    assert error.category == :filesystem
    assert error.message =~ "no matching filesystem mount"
  end

  test "filesystem mount permissions gate operations independently" do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/data",
                     backend: "memory",
                     mode: :memory,
                     allow: [:read, :stat, :lstat]
                   }
                 ]
               }
             })

    assert {:ok, %{mount: %{virtual: "/data"}, operation: :read}} =
             Hyperlang.Filesystem.authorize_data_operation(
               manifest.filesystem,
               "/data/input.txt",
               :read
             )

    assert {:ok, %{mount: %{virtual: "/data"}, operation: :stat}} =
             Hyperlang.Filesystem.authorize_data_operation(
               manifest.filesystem,
               "/data/input.txt",
               :stat
             )

    assert {:ok, %{mount: %{virtual: "/data"}, operation: :lstat}} =
             Hyperlang.Filesystem.authorize_data_operation(
               manifest.filesystem,
               "/data/input.txt",
               :lstat
             )

    for operation <- [:list, :write, :rename] do
      assert {:error, error} =
               Hyperlang.Filesystem.authorize_data_operation(
                 manifest.filesystem,
                 "/data/input.txt",
                 operation
               )

      assert error.category == :filesystem
      assert error.message =~ "permission denied"
      assert error.details.operation == operation
      assert error.details.allowed == [:lstat, :read, :stat]
    end
  end

  test "filesystem source compilation uses normal read permission" do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/src",
                     backend: "memory",
                     mode: :memory,
                     allow: [:read]
                   }
                 ]
               }
             })

    assert {:ok, %{mount: %{virtual: "/src"}, operation: :read}} =
             Hyperlang.Filesystem.authorize_source_compile_read(
               manifest.filesystem,
               "/src/main.erl"
             )

    assert {:ok, %{mount: %{virtual: "/src"}, operation: :read}} =
             Hyperlang.Filesystem.authorize_data_operation(
               manifest.filesystem,
               "/src/main.erl",
               :read
             )
  end

  test "filesystem write-only output mounts deny later reads" do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/out",
                     backend: "memory",
                     mode: :memory,
                     allow: [:write]
                   }
                 ]
               }
             })

    assert {:ok, %{mount: %{virtual: "/out"}, operation: :write}} =
             Hyperlang.Filesystem.authorize_data_operation(
               manifest.filesystem,
               "/out/secret.txt",
               :write
             )

    assert {:error, error} =
             Hyperlang.Filesystem.authorize_data_operation(
               manifest.filesystem,
               "/out/secret.txt",
               :read
             )

    assert error.category == :filesystem
    assert error.message =~ "permission denied"
    assert error.details.operation == :read
    assert error.details.allowed == [:write]
  end

  # One permission engine: read-only enforcement is not the server's private
  # rule. A read-only mount refuses mutations on every authorization path, even
  # when its allow list names them.
  test "filesystem read-only mounts refuse mutations through direct authorization" do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/ro",
                     backend: "memory",
                     mode: :read_only,
                     allow: [:read, :write, :delete, :mkdir, :rename]
                   }
                 ]
               }
             })

    assert {:ok, %{mount: %{virtual: "/ro"}, operation: :read}} =
             Hyperlang.Filesystem.authorize_data_operation(
               manifest.filesystem,
               "/ro/a.txt",
               :read
             )

    assert {:ok, %{mount: %{virtual: "/ro"}, operation: :read}} =
             Hyperlang.Filesystem.authorize_source_compile_read(
               manifest.filesystem,
               "/ro/a.erl"
             )

    for operation <- [:write, :delete, :mkdir, :rename] do
      assert {:error, error} =
               Hyperlang.Filesystem.authorize_data_operation(
                 manifest.filesystem,
                 "/ro/a.txt",
                 operation
               )

      assert error.category == :filesystem
      assert error.message =~ "read-only"
      assert error.details.reason == :erofs
      assert error.details.operation == operation
    end
  end

  test "filesystem virtual cwd resolves relative paths when enabled" do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 cwd: "/work",
                 allow_relative_paths: true,
                 mounts: [
                   %{virtual: "/work", backend: "memory", mode: :memory, allow: [:read]}
                 ]
               }
             })

    assert {:ok, "/work"} = Hyperlang.Filesystem.cwd(manifest.filesystem)

    assert {:ok, %{path: "/work/input.txt", relative_path: "/input.txt"}} =
             Hyperlang.Filesystem.resolve_mount(manifest.filesystem, "input.txt")

    assert {:ok, updated} = Hyperlang.Filesystem.set_cwd(manifest.filesystem, "/work/sub")
    assert {:ok, "/work/sub"} = Hyperlang.Filesystem.cwd(updated)

    assert {:ok, %{path: "/work/sub/next.txt", relative_path: "/sub/next.txt"}} =
             Hyperlang.Filesystem.resolve_mount(updated, "next.txt")
  end

  test "filesystem virtual cwd rejects relative paths when disabled" do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 cwd: "/work",
                 allow_relative_paths: false,
                 mounts: [
                   %{virtual: "/work", backend: "memory", mode: :memory, allow: [:read]}
                 ]
               }
             })

    assert {:error, error} = Hyperlang.Filesystem.resolve_mount(manifest.filesystem, "input.txt")
    assert error.category == :filesystem
    assert error.message =~ "relative filesystem paths are disabled"
    assert error.details.reason == :invalid_path
  end

  test "filesystem get_cwd returns only virtual cwd" do
    host_dir = Path.join(System.tmp_dir!(), "hyperlang_fs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(host_dir)
    on_exit(fn -> File.rm_rf(host_dir) end)

    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 cwd: "/virtual",
                 mounts: [
                   %{
                     virtual: "/virtual",
                     backend: {:host, host_dir}
                   }
                 ]
               }
             })

    assert {:ok, "/virtual"} = Hyperlang.Filesystem.cwd(manifest.filesystem)
    refute Hyperlang.Filesystem.cwd(manifest.filesystem) == {:ok, host_dir}
  end

  test "filesystem resolver modes normalize standard operation paths" do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{virtual: "/data", backend: "memory", mode: :memory, allow: [:read, :write]}
                 ]
               }
             })

    for {input, expected} <- [
          {"/data/a", "/data/a"},
          {"/data/./a", "/data/a"},
          {"/data/x/../a", "/data/a"},
          {"/../../../data/a", "/data/a"}
        ] do
      assert {:ok, %{path: ^expected, mount: %{virtual: "/data"}}} =
               Hyperlang.Filesystem.resolve_operation(manifest.filesystem, input, :read_file)
    end
  end

  test "filesystem resolver modes fail invalid paths before mount lookup" do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 limits: %{max_path_bytes: 32, max_component_bytes: 8},
                 mounts: [
                   %{virtual: "/data", backend: "memory", mode: :memory, allow: [:read]}
                 ]
               }
             })

    for {input, expected} <- [
          {"/missing\u0000x", "null byte"},
          {"/missing\\x", "POSIX separators"},
          {"/this/path/is-far-too-long-for-limit", "max_path_bytes"},
          {"/toolongcomponent", "max_component_bytes"}
        ] do
      assert {:error, error} =
               Hyperlang.Filesystem.resolve_operation(manifest.filesystem, input, :read_file)

      assert error.category == :filesystem
      assert error.message =~ expected
      refute error.message =~ "no matching filesystem mount"
    end
  end

  test "filesystem resolver modes are declared per operation" do
    expected = %{
      read_file: :read_existing_follow_final,
      read_file_info: :stat_existing_follow_final,
      read_link_info: :lstat_existing_no_follow_final,
      write_file: :create_parent_no_follow,
      delete: :delete_parent_no_follow,
      list_dir: :list_names_only,
      rename: :rename_source_lstat,
      make_dir: :recursive_mkdir_checked_ancestors
    }

    assert Hyperlang.Filesystem.operation_resolver_modes() == expected

    for {operation, mode} <- expected do
      assert Hyperlang.Filesystem.resolver_mode_for(operation) == {:ok, mode}
    end
  end

  test "filesystem resolver mode read_existing_follow_final is used by read_file" do
    assert_filesystem_resolver_mode(:read_file, :read_existing_follow_final)
  end

  test "filesystem resolver mode stat_existing_follow_final is used by read_file_info" do
    assert_filesystem_resolver_mode(:read_file_info, :stat_existing_follow_final)
  end

  test "filesystem resolver mode lstat_existing_no_follow_final is used by read_link_info" do
    assert_filesystem_resolver_mode(:read_link_info, :lstat_existing_no_follow_final)
  end

  test "filesystem resolver mode create_parent_no_follow is used by write_file" do
    assert_filesystem_resolver_mode(:write_file, :create_parent_no_follow)
  end

  test "filesystem resolver mode delete_parent_no_follow is used by delete" do
    assert_filesystem_resolver_mode(:delete, :delete_parent_no_follow)
  end

  test "filesystem resolver mode list_names_only is used by list_dir" do
    assert_filesystem_resolver_mode(:list_dir, :list_names_only)
  end

  test "filesystem resolver mode rename_source_lstat is used by rename" do
    assert_filesystem_resolver_mode(:rename, :rename_source_lstat)
  end

  test "filesystem resolver mode recursive_mkdir_checked_ancestors is used by make_dir" do
    assert_filesystem_resolver_mode(:make_dir, :recursive_mkdir_checked_ancestors)
  end

  test "filesystem guest examples use standard Erlang modules only" do
    examples = filesystem_guest_example_sources(:compile)

    assert length(examples) >= 2

    for source <- examples do
      refute source =~ ~r/\bhyperlang:/i
      refute source =~ "Hyperlang.Filesystem"
      refute source =~ ~r/\b(?:vfs|safe_fs|filesystem):/i
    end
  end

  test "filesystem guest examples compile and run; the README has no illustrative examples" do
    compile_examples = filesystem_guest_example_sources(:compile)

    assert length(compile_examples) >= 2

    manifest =
      erlang_public(%{
        filesystem: %{
          enabled: true,
          file_compat: true,
          filelib_compat: true,
          mounts: [
            %{
              virtual: "/data",
              backend: "memory",
              mode: :memory,
              allow: [:read, :list],
              files: [%{path: "/data/input.txt", content: <<"sample">>}]
            },
            %{
              virtual: "/work",
              backend: "memory",
              mode: :memory,
              allow: [:read, :write, :mkdir, :stat],
              dirs: ["/work"]
            }
          ]
        }
      })

    for source <- compile_examples do
      {_program, instance} = compile_and_instance(source, manifest)
      assert {:ok, _result} = eval(instance, :ok)
    end

    doc = File.read!(@readme_doc)
    refute doc =~ ~r/<!--\s*hyperlang:example\s+illustrative\b/
  end

  test "filesystem resolver modes reject unsupported operations without generic fallback" do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{virtual: "/data", backend: "memory", mode: :memory}
                 ]
               }
             })

    assert {:error, error} =
             Hyperlang.Filesystem.resolve_operation(manifest.filesystem, "/data/a", :unknown_op)

    assert error.category == :filesystem
    assert error.message =~ "unsupported filesystem resolver operation"
    assert error.details.operation == :unknown_op
  end

  test "filesystem memory backend reads seeded files and lists seeded directories" do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/mem",
                     backend: "memory",
                     mode: :memory,
                     allow: [:read, :list, :stat],
                     dirs: ["/mem/docs"],
                     files: [
                       %{path: "/mem/docs/a.txt", content: <<"alpha">>, mode: 0o600}
                     ]
                   }
                 ]
               }
             })

    assert {:ok, handle} = Hyperlang.Filesystem.start(manifest.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    assert inspect(handle) =~ "Hyperlang.Filesystem.Handle"
    refute inspect(handle) =~ "#PID"

    assert Hyperlang.Filesystem.list_dir(handle, "/mem") == {:ok, ["docs"]}
    assert Hyperlang.Filesystem.list_dir(handle, "/mem/docs") == {:ok, ["a.txt"]}
    assert Hyperlang.Filesystem.read_file(handle, "/mem/docs/a.txt") == {:ok, <<"alpha">>}

    assert Hyperlang.Filesystem.stat(handle, "/mem/docs/a.txt") ==
             {:ok, %{type: :regular, size: 5, mode: 0o600}}
  end

  test "filesystem server logs swallowed internal failures while returning eacces" do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/mem",
                     backend: "memory",
                     mode: :memory,
                     allow: [:read],
                     files: [%{path: "/mem/a.txt", content: <<"alpha">>}]
                   }
                 ]
               }
             })

    assert {:ok, handle} = Hyperlang.Filesystem.start(manifest.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    {:ok, pid} = Hyperlang.Filesystem.Registry.lookup(handle.id)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        :sys.replace_state(pid, fn state -> %{state | filesystem: nil} end)

        assert GenServer.call(pid, {:filesystem_request, make_ref(), :snapshot}) ==
                 {:error, :eacces}
      end)

    assert log =~ "Hyperlang filesystem request failed; returning eacces"
    assert log =~ "operation=:snapshot"
    assert log =~ "BadMapError"
  end

  test "filesystem memory backend writes deletes mkdirs stats and renames bounded entries" do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/mem",
                     backend: "memory",
                     mode: :memory,
                     allow: [:read, :write, :delete, :mkdir, :list, :rename, :stat],
                     dirs: ["/mem/tmp", "/mem/out"]
                   }
                 ]
               }
             })

    assert {:ok, handle} = Hyperlang.Filesystem.start(manifest.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    assert Hyperlang.Filesystem.write_file(handle, "/mem/tmp/a.txt", [<<"a">>, ["b", <<"c">>]]) ==
             {:ok, :ok}

    assert Hyperlang.Filesystem.read_file(handle, "/mem/tmp/a.txt") == {:ok, <<"abc">>}

    assert Hyperlang.Filesystem.stat(handle, "/mem/tmp") ==
             {:ok, %{type: :directory, size: 0, mode: 0o755}}

    assert Hyperlang.Filesystem.rename(handle, "/mem/tmp/a.txt", "/mem/out/b.txt") == {:ok, :ok}
    assert Hyperlang.Filesystem.read_file(handle, "/mem/out/b.txt") == {:ok, <<"abc">>}
    assert Hyperlang.Filesystem.read_file(handle, "/mem/tmp/a.txt") == {:error, :enoent}
    assert Hyperlang.Filesystem.delete(handle, "/mem/out/b.txt") == {:ok, :ok}
    assert Hyperlang.Filesystem.make_dir(handle, "/mem/out/empty") == {:ok, :ok}
    assert Hyperlang.Filesystem.del_dir(handle, "/mem/out/empty") == {:ok, :ok}
  end

  test "filesystem memory backend rename does not move nested child mount entries" do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/parent",
                     backend: "memory",
                     mode: :memory,
                     allow: [:read, :write, :rename, :mkdir, :list],
                     limits: %{max_total_path_bytes: 30},
                     dirs: ["/parent/dir"]
                   },
                   %{
                     virtual: "/parent/dir/child",
                     backend: "memory",
                     mode: :memory,
                     allow: [:read, :list],
                     files: [
                       %{path: "/parent/dir/child/a.txt", content: <<"child">>},
                       %{path: "/parent/dir/child/very-long-child-name.txt", content: <<"child">>}
                     ]
                   }
                 ]
               }
             })

    assert {:ok, handle} = Hyperlang.Filesystem.start(manifest.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    assert Hyperlang.Filesystem.rename(handle, "/parent/dir", "/parent/longermoved") ==
             {:ok, :ok}

    assert Hyperlang.Filesystem.list_dir(handle, "/parent") == {:ok, ["dir", "longermoved"]}
    assert Hyperlang.Filesystem.read_file(handle, "/parent/dir/child/a.txt") == {:ok, <<"child">>}

    assert Hyperlang.Filesystem.read_file(handle, "/parent/longermoved/child/a.txt") ==
             {:error, :enoent}
  end

  test "filesystem memory backend rejects root rename" do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/",
                     backend: "memory",
                     mode: :memory,
                     allow: [:read, :rename, :list],
                     files: [%{path: "/a.txt", content: <<"root">>}]
                   }
                 ]
               }
             })

    assert {:ok, handle} = Hyperlang.Filesystem.start(manifest.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    assert Hyperlang.Filesystem.rename(handle, "/", "/x") == {:error, :einval}
    assert Hyperlang.Filesystem.list_dir(handle, "/") == {:ok, ["a.txt"]}
    assert Hyperlang.Filesystem.read_file(handle, "/a.txt") == {:ok, <<"root">>}
  end

  test "filesystem memory backend enforces write read and listing limits" do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/mem",
                     backend: "memory",
                     mode: :memory,
                     allow: [:read, :write, :list],
                     limits: %{
                       max_single_write_bytes: 3,
                       max_write_bytes: 6,
                       max_read_bytes: 2,
                       max_dir_entries: 1
                     },
                     files: [%{path: "/mem/a.txt", content: <<"ab">>}]
                   }
                 ]
               }
             })

    assert {:ok, handle} = Hyperlang.Filesystem.start(manifest.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    huge_iodata = [List.duplicate(<<"x">>, 5_000)]

    assert Hyperlang.Filesystem.write_file(handle, "/mem/huge.txt", huge_iodata) ==
             {:error, :enospc}

    assert Hyperlang.Filesystem.write_file(handle, "/mem/b.txt", <<"abcd">>) == {:error, :enospc}
    assert Hyperlang.Filesystem.write_file(handle, "/mem/b.txt", <<"abc">>) == {:ok, :ok}
    assert Hyperlang.Filesystem.write_file(handle, "/mem/c.txt", <<"abc">>) == {:ok, :ok}
    assert Hyperlang.Filesystem.write_file(handle, "/mem/d.txt", <<"a">>) == {:error, :enospc}
    assert Hyperlang.Filesystem.read_file(handle, "/mem/b.txt") == {:error, :eoverflow}
    assert Hyperlang.Filesystem.list_dir(handle, "/mem") == {:error, :eoverflow}
  end

  test "filesystem write preflight checks iodata before content crosses server boundary" do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/mem",
                     backend: "memory",
                     mode: :memory,
                     allow: [:read, :write],
                     dirs: ["/mem"],
                     limits: %{max_single_write_bytes: 3}
                   }
                 ]
               }
             })

    assert {:ok, handle} = Hyperlang.Filesystem.start(manifest.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    assert Hyperlang.Filesystem.write_file(handle, "/mem/a.txt", [self()]) == {:error, :badarg}
    assert Hyperlang.Filesystem.write_file(handle, "/mem/a.txt", ["abcd"]) == {:error, :enospc}
    assert Hyperlang.Filesystem.read_file(handle, "/mem/a.txt") == {:error, :enoent}
  end

  test "filesystem handles use supervised registry instead of public ETS" do
    assert :ets.whereis(:hyperlang_filesystem_handles) == :undefined

    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/mem",
                     backend: "memory",
                     mode: :memory,
                     allow: [:read],
                     files: [%{path: "/mem/a.txt", content: <<"a">>}]
                   }
                 ]
               }
             })

    assert {:ok, handle} = Hyperlang.Filesystem.start(manifest.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    assert :ets.whereis(:hyperlang_filesystem_handles) == :undefined
    assert Hyperlang.Filesystem.read_file(handle, "/mem/a.txt") == {:ok, <<"a">>}

    forged = %Hyperlang.Filesystem.Handle{id: make_ref()}

    assert Hyperlang.Filesystem.read_file(forged, "/mem/a.txt") ==
             {:error, :filesystem_server_unknown}
  end

  test "filesystem failed cumulative quota write leaves remaining quota usable" do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/mem",
                     backend: "memory",
                     mode: :memory,
                     allow: [:read, :write],
                     limits: %{max_write_bytes: 5, max_single_write_bytes: 10}
                   }
                 ]
               }
             })

    assert {:ok, handle} = Hyperlang.Filesystem.start(manifest.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    assert Hyperlang.Filesystem.write_file(handle, "/mem/a.txt", <<"abc">>) == {:ok, :ok}
    assert Hyperlang.Filesystem.write_file(handle, "/mem/b.txt", <<"abc">>) == {:error, :enospc}
    assert Hyperlang.Filesystem.write_file(handle, "/mem/c.txt", <<"de">>) == {:ok, :ok}
    assert Hyperlang.Filesystem.read_file(handle, "/mem/c.txt") == {:ok, <<"de">>}
  end

  test "filesystem append is server-side and charges only appended bytes" do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/mem",
                     backend: "memory",
                     mode: :memory,
                     allow: [:read, :write],
                     limits: %{max_write_bytes: 5, max_single_write_bytes: 10}
                   }
                 ]
               }
             })

    assert {:ok, handle} = Hyperlang.Filesystem.start(manifest.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    assert Hyperlang.Filesystem.write_file(handle, "/mem/a.txt", <<"abc">>) == {:ok, :ok}

    assert Hyperlang.Filesystem.begin_eval(handle, 1) == {:ok, :ok}

    assert Hyperlang.Filesystem.dispatch(
             handle,
             :write_file,
             ["/mem/a.txt", <<"de">>, [:append]],
             %{call_id: 1}
           ) == {:ok, :ok}

    assert Hyperlang.Filesystem.finish_eval(handle, 1, :success) == {:ok, :ok}
    assert Hyperlang.Filesystem.read_file(handle, "/mem/a.txt") == {:ok, <<"abcde">>}

    assert Hyperlang.Filesystem.begin_eval(handle, 2) == {:ok, :ok}

    assert Hyperlang.Filesystem.dispatch(
             handle,
             :write_file,
             ["/mem/a.txt", <<"f">>, [:append]],
             %{call_id: 2}
           ) == {:ok, {:error, :enospc}}

    assert Hyperlang.Filesystem.finish_eval(handle, 2, :success) == {:ok, :ok}
  end

  test "filesystem host read-only backend enforces read cap without returning full file" do
    root =
      Path.join(
        System.tmp_dir!(),
        "hyperlang_host_read_cap_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.write!(Path.join(root, "big.txt"), String.duplicate("x", 128_000))

    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/host",
                     backend: {:host, root},
                     mode: :read_only,
                     allow: [:read],
                     limits: %{max_read_bytes: 3}
                   }
                 ]
               }
             })

    assert {:ok, handle} = Hyperlang.Filesystem.start(manifest.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    assert Hyperlang.Filesystem.read_file(handle, "/host/big.txt") == {:error, :eoverflow}
  end

  test "filesystem host directory listing enforces declared entry and byte caps" do
    root =
      Path.join(
        System.tmp_dir!(),
        "hyperlang_host_list_cap_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    for index <- 1..20 do
      File.write!(Path.join(root, "entry_#{index}.txt"), "x")
    end

    on_exit(fn -> File.rm_rf(root) end)

    manifest = fn limits ->
      Hyperlang.Manifest.normalize(%{
        filesystem: %{
          mounts: [
            %{
              virtual: "/host",
              backend: {:host, root},
              mode: :read_only,
              allow: [:list],
              limits: limits
            }
          ]
        }
      })
    end

    assert {:ok, entry_manifest} = manifest.(%{max_dir_entries: 4})
    assert {:ok, entry_limited} = Hyperlang.Filesystem.start(entry_manifest.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(entry_limited) end)
    assert Hyperlang.Filesystem.list_dir(entry_limited, "/host") == {:error, :eoverflow}

    assert {:ok, byte_manifest} = manifest.(%{max_dir_entries: 100, max_dir_result_bytes: 8})
    assert {:ok, byte_limited} = Hyperlang.Filesystem.start(byte_manifest.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(byte_limited) end)
    assert Hyperlang.Filesystem.list_dir(byte_limited, "/host") == {:error, :eoverflow}
  end

  test "filesystem backend memory accounting includes directory metadata and tombstones" do
    assert {:ok, memory_manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/mem",
                     backend: "memory",
                     mode: :memory,
                     allow: [:mkdir],
                     limits: %{max_total_memory_bytes: 140}
                   }
                 ]
               }
             })

    assert {:ok, memory} = Hyperlang.Filesystem.start(memory_manifest.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(memory) end)

    assert Hyperlang.Filesystem.make_dir(memory, "/mem/one") == {:ok, :ok}
    assert Hyperlang.Filesystem.make_dir(memory, "/mem/two") == {:error, :enospc}

    root =
      Path.join(
        System.tmp_dir!(),
        "hyperlang_overlay_memory_cap_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.write!(Path.join(root, "a.txt"), "a")
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, overlay_manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/ov",
                     backend: {:host, root},
                     mode: :overlay,
                     allow: [:read, :delete],
                     limits: %{
                       max_total_memory_bytes: 64,
                       max_tombstones: 10,
                       max_overlay_entries: 10
                     }
                   }
                 ]
               }
             })

    assert {:ok, overlay} = Hyperlang.Filesystem.start(overlay_manifest.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(overlay) end)

    assert Hyperlang.Filesystem.delete(overlay, "/ov/a.txt") == {:error, :enospc}
    assert Hyperlang.Filesystem.read_file(overlay, "/ov/a.txt") == {:ok, <<"a">>}
  end

  test "filesystem overlay backend enforces tombstone and overlay entry limits" do
    root =
      Path.join(
        System.tmp_dir!(),
        "hyperlang_overlay_state_cap_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.write!(Path.join(root, "a.txt"), "a")
    File.write!(Path.join(root, "b.txt"), "b")

    on_exit(fn -> File.rm_rf(root) end)

    overlay_manifest = fn limits ->
      Hyperlang.Manifest.normalize(%{
        filesystem: %{
          mounts: [
            %{
              virtual: "/ov",
              backend: {:host, root},
              mode: :overlay,
              allow: [:read, :write, :delete, :mkdir],
              limits: limits
            }
          ]
        }
      })
    end

    assert {:ok, tombstone_manifest} =
             overlay_manifest.(%{
               max_tombstones: 1,
               max_overlay_entries: 10,
               max_total_memory_bytes: 10_000
             })

    assert {:ok, tombstone_limited} = Hyperlang.Filesystem.start(tombstone_manifest.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(tombstone_limited) end)

    assert Hyperlang.Filesystem.delete(tombstone_limited, "/ov/a.txt") == {:ok, :ok}
    assert Hyperlang.Filesystem.delete(tombstone_limited, "/ov/b.txt") == {:error, :enospc}
    assert Hyperlang.Filesystem.read_file(tombstone_limited, "/ov/b.txt") == {:ok, <<"b">>}

    assert {:ok, overlay_entry_manifest} =
             overlay_manifest.(%{
               max_tombstones: 10,
               max_overlay_entries: 1,
               max_total_memory_bytes: 10_000
             })

    assert {:ok, overlay_entry_limited} =
             Hyperlang.Filesystem.start(overlay_entry_manifest.filesystem)

    on_exit(fn -> Hyperlang.Filesystem.stop(overlay_entry_limited) end)

    assert Hyperlang.Filesystem.write_file(overlay_entry_limited, "/ov/new.txt", <<"x">>) ==
             {:ok, :ok}

    assert Hyperlang.Filesystem.make_dir(overlay_entry_limited, "/ov/second") == {:error, :enospc}
  end

  test "filesystem memory backend rejects over-limit or root-clobbering seeds" do
    assert {:ok, two_seed_files_at_limit} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/mem",
                     backend: "memory",
                     mode: :memory,
                     limits: %{max_file_count: 3},
                     files: [
                       %{path: "/mem/a.txt", content: <<"a">>},
                       %{path: "/mem/b.txt", content: <<"b">>}
                     ]
                   }
                 ]
               }
             })

    assert {:ok, handle} = Hyperlang.Filesystem.start(two_seed_files_at_limit.filesystem)
    Hyperlang.Filesystem.stop(handle)

    assert {:ok, empty_non_root_mount_with_zero_files} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/empty",
                     backend: "memory",
                     mode: :memory,
                     limits: %{max_file_count: 0}
                   }
                 ]
               }
             })

    assert {:ok, handle} =
             Hyperlang.Filesystem.start(empty_non_root_mount_with_zero_files.filesystem)

    Hyperlang.Filesystem.stop(handle)

    assert {:ok, root_mount_with_zero_files} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/",
                     backend: "memory",
                     mode: :memory,
                     limits: %{max_file_count: 0}
                   }
                 ]
               }
             })

    assert {:ok, handle} = Hyperlang.Filesystem.start(root_mount_with_zero_files.filesystem)
    Hyperlang.Filesystem.stop(handle)

    assert {:ok, too_many_entries} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/mem",
                     backend: "memory",
                     mode: :memory,
                     limits: %{max_file_count: 2},
                     dirs: ["/mem/a", "/mem/b", "/mem/c"]
                   }
                 ]
               }
             })

    assert {:error, :enospc} = Hyperlang.Filesystem.start(too_many_entries.filesystem)

    assert {:ok, clobber_mount_root} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/mem",
                     backend: "memory",
                     mode: :memory,
                     files: [%{path: "/mem", content: <<"bad">>}]
                   }
                 ]
               }
             })

    assert {:error, :eexist} = Hyperlang.Filesystem.start(clobber_mount_root.filesystem)
  end

  test "filesystem memory backend accounts quotas per mount and enforces path and stat caps" do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/a",
                     backend: "memory",
                     mode: :memory,
                     allow: [:read, :write, :stat],
                     limits: %{max_write_bytes: 3, max_total_path_bytes: 100}
                   },
                   %{
                     virtual: "/b",
                     backend: "memory",
                     mode: :memory,
                     allow: [:read, :write, :stat],
                     limits: %{max_write_bytes: 3, max_total_path_bytes: 100}
                   },
                   %{
                     virtual: "/short",
                     backend: "memory",
                     mode: :memory,
                     allow: [:write],
                     limits: %{max_total_path_bytes: 5}
                   },
                   %{
                     virtual: "/stat",
                     backend: "memory",
                     mode: :memory,
                     allow: [:read, :stat],
                     limits: %{max_stat_result_bytes: 0},
                     files: [%{path: "/stat/a.txt", content: <<"a">>}]
                   },
                   %{
                     virtual: "/parent",
                     backend: "memory",
                     mode: :memory,
                     allow: [:write],
                     limits: %{max_file_count: 2, max_total_path_bytes: 64}
                   },
                   %{
                     virtual: "/parent/child",
                     backend: "memory",
                     mode: :memory,
                     allow: [:write],
                     limits: %{max_file_count: 4, max_total_path_bytes: 128},
                     files: [
                       %{path: "/parent/child/one.txt", content: <<"1">>},
                       %{path: "/parent/child/two.txt", content: <<"2">>}
                     ]
                   }
                 ]
               }
             })

    assert {:ok, handle} = Hyperlang.Filesystem.start(manifest.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    assert Hyperlang.Filesystem.write_file(handle, "/a/x", <<"abc">>) == {:ok, :ok}
    assert Hyperlang.Filesystem.write_file(handle, "/b/x", <<"abc">>) == {:ok, :ok}
    assert Hyperlang.Filesystem.write_file(handle, "/a/y", <<"d">>) == {:error, :enospc}

    assert Hyperlang.Filesystem.write_file(handle, "/short/too-long", <<"x">>) ==
             {:error, :enospc}

    assert Hyperlang.Filesystem.stat(handle, "/stat/a.txt") == {:error, :eoverflow}
    assert Hyperlang.Filesystem.write_file(handle, "/parent/a.txt", <<"a">>) == {:ok, :ok}
    assert Hyperlang.Filesystem.write_file(handle, "/parent/b.txt", <<"b">>) == {:ok, :ok}
    assert Hyperlang.Filesystem.write_file(handle, "/parent/c.txt", <<"c">>) == {:error, :enospc}
  end

  test "filesystem server owns state and ignores stale request replies" do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/mem",
                     backend: "memory",
                     mode: :memory,
                     allow: [:read],
                     files: [%{path: "/mem/a.txt", content: <<"alpha">>}]
                   }
                 ]
               }
             })

    assert {:ok, handle} = Hyperlang.Filesystem.start(manifest.filesystem, request_queue_limit: 5)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    assert {:ok, info} = Hyperlang.Filesystem.server_info(handle)
    assert info.pid_visible_to_guest == false
    assert info.message_queue_data == :off_heap
    assert is_map(info.max_heap_size)
    assert info.request_queue_limit == 5
    assert info.supervisor == Hyperlang.Filesystem.Supervisor

    assert Hyperlang.Filesystem.inject_stale_reply(handle, make_ref()) == {:ok, :ignored}
    assert {:ok, %{pending_request_count: 0}} = Hyperlang.Filesystem.server_info(handle)
    assert Hyperlang.Filesystem.read_file(handle, "/mem/a.txt") == {:ok, <<"alpha">>}
  end

  test "host filesystem inspection APIs seed read tree snapshot export and materialize" do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/mem",
                     backend: "memory",
                     mode: :memory,
                     allow: [:read]
                   }
                 ]
               }
             })

    assert {:ok, handle} = Hyperlang.Filesystem.start(manifest.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    assert Hyperlang.Filesystem.seed(handle, [
             %{path: "/mem/dir", type: :directory},
             %{path: "/mem/dir/a.txt", content: <<"alpha">>},
             %{"path" => "/mem/b.txt", "content" => "beta"}
           ]) == {:ok, :ok}

    assert Hyperlang.Filesystem.read_file(handle, "/mem/dir/a.txt") == {:ok, <<"alpha">>}

    assert {:ok, tree} = Hyperlang.Filesystem.tree(handle)
    assert tree["/mem/dir"] == %{type: :dir}
    assert tree["/mem/dir/a.txt"] == %{type: :file, size: 5, mode: 0o644}

    assert {:ok, snapshot} = Hyperlang.Filesystem.snapshot(handle)
    assert snapshot.cwd == "/"
    assert snapshot.diff == %{created: [], modified: [], deleted: []}
    assert snapshot.tree["/mem/b.txt"] == %{type: :file, size: 4, mode: 0o644}

    assert {:ok, exported} = Hyperlang.Filesystem.export(handle)
    assert "/mem/dir" in exported.directories
    assert %{path: "/mem/dir/a.txt", content: <<"alpha">>, mode: 0o644, size: 5} in exported.files

    materialize_root =
      Path.join(System.tmp_dir!(), "hyperlang_export_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(materialize_root) end)

    assert {:ok, materialized} =
             Hyperlang.Filesystem.export(handle, materialize_to: materialize_root)

    assert materialized.materialized_to == Path.expand(materialize_root)
    assert File.read!(Path.join(materialize_root, "mem/dir/a.txt")) == "alpha"
    refute inspect(exported) =~ materialize_root
  end

  test "guest code cannot call host filesystem helper namespaces" do
    for source <- [
          ~S|'Elixir.Hyperlang.Filesystem':read_file("/mem/a.txt").|,
          ~S|hyperlang_filesystem:read_file("/mem/a.txt").|
        ] do
      assert {:error, [error]} = Hyperlang.Test.program(source, erlang_public())
      assert error.category == :verify
      assert error.message =~ "remote call"
    end
  end

  test "compile_from_filesystem rejects dangling linked-module calls before runtime loading" do
    suffix = "#{System.unique_integer([:positive])}_#{System.system_time(:nanosecond)}"
    root = "/src_snapshot_dangling_#{suffix}"
    main_module = "dangling_main_#{suffix}"
    dep_module = "dangling_dep_#{suffix}"
    main_path = "#{root}/#{main_module}.erl"
    dep_path = "#{root}/#{dep_module}.erl"

    manifest =
      erlang_public(%{
        filesystem: %{
          enabled: true,
          source_compile: true,
          mounts: [
            %{
              virtual: root,
              backend: "memory",
              mode: :memory,
              allow: [:read]
            }
          ]
        }
      })

    {:ok, normalized} = Hyperlang.Manifest.normalize(manifest)
    {:ok, handle} = Hyperlang.Filesystem.start(normalized.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    assert Hyperlang.Filesystem.seed(handle, main_path, """
           -module(#{main_module}).
           -export([result/1]).
           result(Input) -> #{dep_module}:missing(Input).
           """) == {:ok, :ok}

    assert Hyperlang.Filesystem.seed(handle, dep_path, """
           -module(#{dep_module}).
           -export([score/1]).
           score(N) -> N + 1.
           """) == {:ok, :ok}

    assert {:error, [error]} =
             Hyperlang.DoorTestSupport.build_from_filesystem(
               handle,
               %{entry: main_path, sources: [main_path, dep_path]},
               manifest
             )

    assert error.category == :source

    assert error.message =~
             "source snapshot linked module call #{dep_module}:missing/1 is not exported"
  end

  test "compile_from_filesystem rejects unlinked code-path modules in source snapshots" do
    suffix = "#{System.unique_integer([:positive])}_#{System.system_time(:nanosecond)}"
    root = "/src_snapshot_closed_#{suffix}"
    main_module = "closed_main_#{suffix}"
    dep_module = "closed_dep_#{suffix}"
    main_path = "#{root}/#{main_module}.erl"
    dep_path = "#{root}/#{dep_module}.erl"

    manifest =
      erlang_public(%{
        modules: %{enabled: true, path: [root]},
        filesystem: %{
          enabled: true,
          source_compile: true,
          mounts: [
            %{
              virtual: root,
              backend: "memory",
              mode: :memory,
              allow: [:read]
            }
          ]
        }
      })

    {:ok, normalized} = Hyperlang.Manifest.normalize(manifest)
    {:ok, handle} = Hyperlang.Filesystem.start(normalized.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    assert Hyperlang.Filesystem.seed(handle, main_path, """
           -module(#{main_module}).
           -export([result/1]).
           result(Input) -> #{dep_module}:score(Input).
           """) == {:ok, :ok}

    assert Hyperlang.Filesystem.seed(handle, dep_path, """
           -module(#{dep_module}).
           -export([score/1]).
           score(N) -> N + 1.
           """) == {:ok, :ok}

    assert {:error, [error]} =
             Hyperlang.DoorTestSupport.build_from_filesystem(
               handle,
               %{entry: main_path, sources: [main_path]},
               manifest
             )

    assert error.category == :verify
    assert error.message =~ "remote call #{dep_module}:score/1 is not declared"
  end

  test "compile_from_filesystem rejects dynamic callbacks that cannot be linked" do
    suffix = "#{System.unique_integer([:positive])}_#{System.system_time(:nanosecond)}"
    root = "/src_snapshot_dynamic_#{suffix}"
    main_module = "dynamic_main_#{suffix}"
    lib_module = "dynamic_lib_#{suffix}"
    main_path = "#{root}/#{main_module}.erl"
    lib_path = "#{root}/#{lib_module}.erl"

    manifest =
      erlang_public(%{
        modules: %{
          enabled: true,
          guest_modules: [main_module, lib_module]
        },
        filesystem: %{
          enabled: true,
          source_compile: true,
          mounts: [
            %{
              virtual: root,
              backend: "memory",
              mode: :memory,
              allow: [:read]
            }
          ]
        }
      })

    {:ok, normalized} = Hyperlang.Manifest.normalize(manifest)
    {:ok, handle} = Hyperlang.Filesystem.start(normalized.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    assert Hyperlang.Filesystem.seed(handle, main_path, """
           -module(#{main_module}).
           -export([result/1]).
           result(Module) -> Module:missing(1).
           """) == {:ok, :ok}

    assert Hyperlang.Filesystem.seed(handle, lib_path, """
           -module(#{lib_module}).
           -export([score/1]).
           score(N) -> N + 1.
           """) == {:ok, :ok}

    assert {:error, [error]} =
             Hyperlang.DoorTestSupport.build_from_filesystem(
               handle,
               %{entry: main_path, sources: [main_path, lib_path]},
               manifest
             )

    assert error.category == :source
    assert error.message =~ "source snapshot dynamic module call missing/1 is not linked"
  end

  test "compile_from_filesystem rejects literal dynamic module calls that do not resolve exactly" do
    suffix = "#{System.unique_integer([:positive])}_#{System.system_time(:nanosecond)}"
    root = "/src_snapshot_dynamic_literal_#{suffix}"
    main_module = "dynamic_literal_main_#{suffix}"
    lib_module = "dynamic_literal_lib_#{suffix}"
    missing_module = "dynamic_literal_missing_#{suffix}"
    main_path = "#{root}/#{main_module}.erl"
    lib_path = "#{root}/#{lib_module}.erl"

    manifest =
      erlang_public(%{
        modules: %{
          enabled: true,
          guest_modules: [main_module, lib_module]
        },
        filesystem: %{
          enabled: true,
          source_compile: true,
          mounts: [
            %{
              virtual: root,
              backend: "memory",
              mode: :memory,
              allow: [:read]
            }
          ]
        }
      })

    {:ok, normalized} = Hyperlang.Manifest.normalize(manifest)
    {:ok, handle} = Hyperlang.Filesystem.start(normalized.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    assert Hyperlang.Filesystem.seed(handle, main_path, """
           -module(#{main_module}).
           -export([result/1]).
           result(Input) ->
             Module = #{missing_module},
             Module:run(Input).
           """) == {:ok, :ok}

    assert Hyperlang.Filesystem.seed(handle, lib_path, """
           -module(#{lib_module}).
           -export([run/1]).
           run(N) -> N + 1.
           """) == {:ok, :ok}

    assert {:error, [error]} =
             Hyperlang.DoorTestSupport.build_from_filesystem(
               handle,
               %{entry: main_path, sources: [main_path, lib_path]},
               manifest
             )

    assert error.category == :source
    assert error.message =~ "source snapshot dynamic module call run/1 is not linked"
  end

  test "compile_from_filesystem lowers dynamic callbacks inside source snapshots" do
    suffix = "#{System.unique_integer([:positive])}_#{System.system_time(:nanosecond)}"
    root = "/src_snapshot_cb_#{suffix}"
    main_module = "snapshot_cb_main_#{suffix}"
    lib_module = "snapshot_cb_lib_#{suffix}"
    main_path = "#{root}/#{main_module}.erl"
    lib_path = "#{root}/#{lib_module}.erl"

    manifest =
      erlang_public(%{
        code_pool: %{size: next_free_code_pool_size()},
        limits: %{max_atom_count: 16},
        modules: %{
          enabled: true,
          guest_modules: [main_module, lib_module]
        },
        filesystem: %{
          enabled: true,
          source_compile: true,
          mounts: [
            %{
              virtual: root,
              backend: "memory",
              mode: :memory,
              allow: [:read]
            }
          ]
        }
      })

    {:ok, normalized} = Hyperlang.Manifest.normalize(manifest)
    {:ok, handle} = Hyperlang.Filesystem.start(normalized.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    assert Hyperlang.Filesystem.seed(handle, main_path, """
           -module(#{main_module}).
           -export([result/1, render/1]).
           result(N) -> #{lib_module}:run(?MODULE, N).
           render(N) -> <<"n=", (integer_to_binary(N))/binary>>.
           """) == {:ok, :ok}

    assert Hyperlang.Filesystem.seed(handle, lib_path, """
           -module(#{lib_module}).
           -export([run/2]).
           run(Module, N) -> Module:render(N).
           """) == {:ok, :ok}

    spec = %{entry: main_path, sources: [main_path, lib_path]}

    assert {:ok, program} =
             Hyperlang.DoorTestSupport.build_from_filesystem(handle, spec, manifest)

    instance = {program, [bindings: %{}, policy: %{}]}

    assert eval(instance, 7) == {:ok, <<"n=7">>}
  end

  test "compile_from_filesystem dispatches dynamic callbacks across snapshot modules" do
    suffix = "#{System.unique_integer([:positive])}_#{System.system_time(:nanosecond)}"
    root = "/src_snapshot_dyn_dispatch_#{suffix}"
    main_module = "dyn_dispatch_main_#{suffix}"
    runner_module = "dyn_dispatch_runner_#{suffix}"
    a_module = "dyn_dispatch_a_#{suffix}"
    b_module = "dyn_dispatch_b_#{suffix}"
    c_module = "dyn_dispatch_c_#{suffix}"

    paths = %{
      main_module => "#{root}/#{main_module}.erl",
      runner_module => "#{root}/#{runner_module}.erl",
      a_module => "#{root}/#{a_module}.erl",
      b_module => "#{root}/#{b_module}.erl",
      c_module => "#{root}/#{c_module}.erl"
    }

    manifest =
      erlang_public(%{
        limits: %{max_atom_count: 16},
        modules: %{
          enabled: true,
          guest_modules: [main_module, runner_module, a_module, b_module, c_module]
        },
        filesystem: %{
          enabled: true,
          source_compile: true,
          mounts: [
            %{
              virtual: root,
              backend: "memory",
              mode: :memory,
              allow: [:read]
            }
          ]
        }
      })

    {:ok, normalized} = Hyperlang.Manifest.normalize(manifest)
    {:ok, handle} = Hyperlang.Filesystem.start(normalized.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    assert Hyperlang.Filesystem.seed(handle, paths[main_module], """
           -module(#{main_module}).
           -export([result/1]).
           result(Which) ->
             case Which of
               1 -> #{runner_module}:run(#{a_module}, 5);
               2 -> #{runner_module}:run(#{b_module}, 5);
               _ -> #{runner_module}:run(#{c_module}, 5)
             end.
           """) == {:ok, :ok}

    assert Hyperlang.Filesystem.seed(handle, paths[runner_module], """
           -module(#{runner_module}).
           -export([run/2]).
           run(Module, N) -> Module:render(N).
           """) == {:ok, :ok}

    assert Hyperlang.Filesystem.seed(handle, paths[a_module], """
           -module(#{a_module}).
           -export([render/1]).
           render(N) -> N + 10.
           """) == {:ok, :ok}

    assert Hyperlang.Filesystem.seed(handle, paths[b_module], """
           -module(#{b_module}).
           -export([render/1]).
           render(N) -> N + 20.
           """) == {:ok, :ok}

    assert Hyperlang.Filesystem.seed(handle, paths[c_module], """
           -module(#{c_module}).
           -export([render/1]).
           render(N) -> N + 30.
           """) == {:ok, :ok}

    spec = %{entry: paths[main_module], sources: Map.values(paths)}

    assert {:ok, program} =
             Hyperlang.DoorTestSupport.build_from_filesystem(handle, spec, manifest)

    instance = {program, [bindings: %{}, policy: %{}]}

    assert eval(instance, 1) == {:ok, 15}
    assert eval(instance, 2) == {:ok, 25}
    assert eval(instance, 3) == {:ok, 35}
  end

  test "compile_from_filesystem dynamic callbacks miss cleanly at runtime" do
    suffix = "#{System.unique_integer([:positive])}_#{System.system_time(:nanosecond)}"
    root = "/src_snapshot_dyn_runtime_miss_#{suffix}"
    main_module = "dyn_runtime_miss_main_#{suffix}"
    runner_module = "dyn_runtime_miss_runner_#{suffix}"
    renderer_module = "dyn_runtime_miss_renderer_#{suffix}"
    empty_module = "dyn_runtime_miss_empty_#{suffix}"
    main_path = "#{root}/#{main_module}.erl"
    runner_path = "#{root}/#{runner_module}.erl"
    renderer_path = "#{root}/#{renderer_module}.erl"
    empty_path = "#{root}/#{empty_module}.erl"

    manifest =
      erlang_public(%{
        modules: %{
          enabled: true,
          guest_modules: [main_module, runner_module, renderer_module, empty_module]
        },
        filesystem: %{
          enabled: true,
          source_compile: true,
          mounts: [
            %{
              virtual: root,
              backend: "memory",
              mode: :memory,
              allow: [:read]
            }
          ]
        }
      })

    {:ok, normalized} = Hyperlang.Manifest.normalize(manifest)
    {:ok, handle} = Hyperlang.Filesystem.start(normalized.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    assert Hyperlang.Filesystem.seed(handle, main_path, """
           -module(#{main_module}).
           -export([result/1]).
           result(_Input) -> #{runner_module}:run(#{empty_module}, 5).
           """) == {:ok, :ok}

    assert Hyperlang.Filesystem.seed(handle, runner_path, """
           -module(#{runner_module}).
           -export([run/2]).
           run(Module, N) -> Module:render(N).
           """) == {:ok, :ok}

    assert Hyperlang.Filesystem.seed(handle, renderer_path, """
           -module(#{renderer_module}).
           -export([render/1]).
           render(N) -> N + 100.
           """) == {:ok, :ok}

    assert Hyperlang.Filesystem.seed(handle, empty_path, """
           -module(#{empty_module}).
           -export([other/1]).
           other(N) -> N.
           """) == {:ok, :ok}

    spec = %{entry: main_path, sources: [main_path, runner_path, renderer_path, empty_path]}

    assert {:ok, program} =
             Hyperlang.DoorTestSupport.build_from_filesystem(handle, spec, manifest)

    instance = {program, [bindings: %{}, policy: %{}]}

    error = eval(instance, :ok) |> assert_eval_error(:runtime)
    assert to_string(error_reason(error)) == "undef"
  end

  test "non-snapshot compile rejects dynamic remote calls" do
    source = """
    Module = non_snapshot_dynamic_target,
    Module:run(1).
    """

    assert {:error, [error]} =
             Hyperlang.Test.program(
               source,
               erlang_public(%{
                 modules: %{enabled: true, guest_modules: ["non_snapshot_dynamic_target"]}
               })
             )

    assert error.category == :verify
    assert error.message =~ "dynamic remote calls are forbidden"
  end

  test "compile_from_filesystem dynamic callback linking stays within atom-count limits" do
    suffix = "#{System.unique_integer([:positive])}_#{System.system_time(:nanosecond)}"
    root = "/src_snapshot_dyn_atom_limit_#{suffix}"
    main_module = "dyn_atom_limit_main_#{suffix}"
    lib_module = "dyn_atom_limit_lib_#{suffix}"
    main_path = "#{root}/#{main_module}.erl"
    lib_path = "#{root}/#{lib_module}.erl"

    manifest =
      erlang_public(%{
        limits: %{max_atom_count: 1},
        modules: %{
          enabled: true,
          guest_modules: [main_module, lib_module]
        },
        filesystem: %{
          enabled: true,
          source_compile: true,
          mounts: [
            %{
              virtual: root,
              backend: "memory",
              mode: :memory,
              allow: [:read]
            }
          ]
        }
      })

    {:ok, normalized} = Hyperlang.Manifest.normalize(manifest)
    {:ok, handle} = Hyperlang.Filesystem.start(normalized.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    assert Hyperlang.Filesystem.seed(handle, main_path, """
           -module(#{main_module}).
           -export([result/1, render/1]).
           result(N) -> #{lib_module}:run(?MODULE, N).
           render(N) -> N + 1.
           """) == {:ok, :ok}

    assert Hyperlang.Filesystem.seed(handle, lib_path, """
           -module(#{lib_module}).
           -export([run/2]).
           run(Module, N) -> Module:render(N).
           """) == {:ok, :ok}

    spec = %{entry: main_path, sources: [main_path, lib_path]}

    assert {:ok, program} =
             Hyperlang.DoorTestSupport.build_from_filesystem(handle, spec, manifest)

    instance = {program, [bindings: %{}, policy: %{}]}

    assert eval(instance, 41) == {:ok, 42}
  end

  test "compile_from_filesystem cache distinguishes explicit missing result roots" do
    base_manifest =
      erlang_public(%{
        exports: %{
          functions: %{
            "public_probe" => %{function: "public_probe", arity: 1}
          }
        },
        filesystem: %{
          enabled: true,
          source_compile: true,
          mounts: [
            %{
              virtual: "/cache_probe",
              backend: "memory",
              mode: :memory,
              allow: [:read]
            }
          ]
        }
      })

    {:ok, normalized} = Hyperlang.Manifest.normalize(base_manifest)
    {:ok, handle} = Hyperlang.Filesystem.start(normalized.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    assert Hyperlang.Filesystem.seed(handle, "/cache_probe/cache_probe_main.erl", """
           -module(cache_probe_main).
           -export([public_probe/1]).
           public_probe(Input) -> Input.
           """) == {:ok, :ok}

    spec = %{
      entry: "/cache_probe/cache_probe_main.erl",
      sources: ["/cache_probe/cache_probe_main.erl"]
    }

    assert {:ok, _implicit_program} =
             Hyperlang.DoorTestSupport.build_from_filesystem(handle, spec, base_manifest)

    explicit_manifest = Map.put(base_manifest, :result, %{name: "result", arity: 1})

    assert {:error, [error]} =
             Hyperlang.DoorTestSupport.build_from_filesystem(handle, spec, explicit_manifest)

    assert error.category == :source
    assert error.message =~ "source snapshot entry result root not found"
  end

  test "source module identities cannot claim Hyperlang generated slot names" do
    manifest =
      erlang_public(%{
        limits: %{max_atom_count: 8},
        filesystem: %{
          enabled: true,
          file_compat: true,
          loader_compat: true,
          source_compile: true,
          mounts: [
            %{
              virtual: "/src",
              backend: "memory",
              mode: :memory,
              allow: [:read, :write],
              dirs: ["/src"]
            }
          ]
        }
      })

    {:ok, normalized} = Hyperlang.Manifest.normalize(manifest)
    {:ok, handle} = Hyperlang.Filesystem.start(normalized.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    assert Hyperlang.Filesystem.seed(handle, "/src/hyperlang_slot_000001.erl", """
           -module(hyperlang_slot_000001).
           -export([result/1]).
           result(_Input) -> ok.
           """) == {:ok, :ok}

    assert {:error, [error]} =
             Hyperlang.DoorTestSupport.build_from_filesystem(
               handle,
               %{
                 entry: "/src/hyperlang_slot_000001.erl",
                 sources: ["/src/hyperlang_slot_000001.erl"]
               },
               manifest
             )

    assert error.category == :source
    assert error.message =~ "reserved Hyperlang internal name"

    assert Hyperlang.Filesystem.seed(handle, "/src/quoted_slot.erl", """
           -module('hyperlang_slot_000001').
           -export([result/1]).
           result(_Input) -> ok.
           """) == {:ok, :ok}

    assert {:error, [quoted_error]} =
             Hyperlang.DoorTestSupport.build_from_filesystem(
               handle,
               %{entry: "/src/quoted_slot.erl", sources: ["/src/quoted_slot.erl"]},
               manifest
             )

    assert quoted_error.category == :source
    assert quoted_error.message =~ "reserved Hyperlang internal name"

    assert Hyperlang.Filesystem.seed(handle, "/src/main.erl", """
           -module(main).
           -module(hyperlang_slot_000001).
           -export([result/1]).
           result(_Input) -> ok.
           """) == {:ok, :ok}

    assert {:error, [duplicate_module_error]} =
             Hyperlang.DoorTestSupport.build_from_filesystem(
               handle,
               %{entry: "/src/main.erl", sources: ["/src/main.erl"]},
               manifest
             )

    assert duplicate_module_error.category == :source
    assert duplicate_module_error.message =~ "multiple -module attributes"

    assert Hyperlang.Filesystem.seed(handle, "/src/main.erl", """
           -module(main).
           -module('hyperlang_slot_000001').
           -export([result/1]).
           result(_Input) -> ok.
           """) == {:ok, :ok}

    assert {:error, [duplicate_quoted_error]} =
             Hyperlang.DoorTestSupport.build_from_filesystem(
               handle,
               %{entry: "/src/main.erl", sources: ["/src/main.erl"]},
               manifest
             )

    assert duplicate_quoted_error.category == :source
    assert duplicate_quoted_error.message =~ "multiple -module attributes"
  end

  test "compile_from_filesystem rejects unreadable mounts and follows existing host symlink sources" do
    source = "-module(main). result(_) -> 1."

    data_manifest =
      erlang_public(%{
        filesystem: %{
          enabled: true,
          source_compile: true,
          mounts: [
            %{virtual: "/data", backend: "memory", mode: :memory, allow: []}
          ]
        }
      })

    {:ok, data_normalized} = Hyperlang.Manifest.normalize(data_manifest)
    {:ok, data_handle} = Hyperlang.Filesystem.start(data_normalized.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(data_handle) end)
    Hyperlang.Filesystem.seed(data_handle, "/data/main.erl", source)

    assert {:error, [data_error]} =
             Hyperlang.DoorTestSupport.build_from_filesystem(
               data_handle,
               %{entry: "/data/main.erl", sources: ["/data/main.erl"]},
               data_manifest
             )

    assert data_error.message =~ "source file read failed"

    src_manifest =
      erlang_public(%{
        filesystem: %{
          enabled: true,
          source_compile: true,
          mounts: [
            %{virtual: "/src", backend: "memory", mode: :memory, allow: [:read]}
          ]
        }
      })

    {:ok, src_normalized} = Hyperlang.Manifest.normalize(src_manifest)
    {:ok, src_handle} = Hyperlang.Filesystem.start(src_normalized.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(src_handle) end)

    assert {:error, [outside_mount_error]} =
             Hyperlang.DoorTestSupport.build_from_filesystem(
               src_handle,
               %{entry: "/outside/main.erl", sources: ["/outside/main.erl"]},
               src_manifest
             )

    assert outside_mount_error.category == :source
    assert outside_mount_error.message =~ "source file read failed"
    assert outside_mount_error.details.path == "/outside/main.erl"
    assert outside_mount_error.details.reason == :eacces

    root =
      Path.join(System.tmp_dir!(), "hyperlang_source_host_#{System.unique_integer([:positive])}")

    outside =
      Path.join(
        System.tmp_dir!(),
        "hyperlang_source_out_#{System.unique_integer([:positive])}.erl"
      )

    File.mkdir_p!(root)
    File.write!(outside, source)

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(outside)
    end)

    if File.ln_s(outside, Path.join(root, "main.erl")) == :ok do
      host_manifest =
        erlang_public(%{
          filesystem: %{
            enabled: true,
            source_compile: true,
            mounts: [
              %{
                virtual: "/src",
                backend: {:host, root},
                mode: :read_only,
                allow: [:read]
              }
            ]
          }
        })

      {:ok, host_normalized} = Hyperlang.Manifest.normalize(host_manifest)
      {:ok, host_handle} = Hyperlang.Filesystem.start(host_normalized.filesystem)
      on_exit(fn -> Hyperlang.Filesystem.stop(host_handle) end)

      assert {:ok, _symlink_program} =
               Hyperlang.DoorTestSupport.build_from_filesystem(
                 host_handle,
                 %{entry: "/src/main.erl", sources: ["/src/main.erl"]},
                 host_manifest
               )
    end
  end

  test "filesystem server rejects stale eval requests after transaction failure" do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 commit_policy: :on_eval_success,
                 mounts: [
                   %{
                     virtual: "/mem",
                     backend: "memory",
                     mode: :memory,
                     allow: [:read, :write]
                   }
                 ]
               }
             })

    assert {:ok, handle} = Hyperlang.Filesystem.start(manifest.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    pid = filesystem_pid(handle)
    call_id = :erlang.unique_integer([:positive])
    request_id = make_ref()

    assert Hyperlang.Filesystem.begin_eval(handle, call_id) == {:ok, :ok}

    assert GenServer.call(
             pid,
             {:filesystem_request, request_id,
              {:eval_request, call_id, {:write_file, "/mem/replayed.txt", "first"}}}
           ) == {:ok, :ok}

    assert Hyperlang.Filesystem.read_file(handle, "/mem/replayed.txt") == {:error, :enoent}
    assert Hyperlang.Filesystem.finish_eval(handle, call_id, :failure) == {:ok, :ok}

    assert GenServer.call(
             pid,
             {:filesystem_request, request_id,
              {:eval_request, call_id, {:write_file, "/mem/replayed.txt", "replayed"}}}
           ) == {:error, :stale_eval_request}

    assert Hyperlang.Filesystem.read_file(handle, "/mem/replayed.txt") == {:error, :enoent}
  end

  test "filesystem eval owner death aborts active transaction" do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 commit_policy: :on_eval_success,
                 mounts: [
                   %{
                     virtual: "/mem",
                     backend: "memory",
                     mode: :memory,
                     allow: [:read, :write]
                   }
                 ]
               }
             })

    assert {:ok, handle} = Hyperlang.Filesystem.start(manifest.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    owner_monitor = Process.monitor(owner)
    call_id = :erlang.unique_integer([:positive])

    assert Hyperlang.Filesystem.begin_eval(handle, call_id, owner) == {:ok, :ok}

    assert Hyperlang.Filesystem.dispatch(
             handle,
             :write_file,
             ["/mem/owned.txt", "owned"],
             %{call_id: call_id}
           ) == {:ok, :ok}

    assert Hyperlang.Filesystem.read_file(handle, "/mem/owned.txt") == {:error, :enoent}

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}

    assert eventually(fn ->
             match?(
               {:ok, %{open_handle_count: 0, transaction_count: 0}},
               Hyperlang.Filesystem.server_info(handle)
             )
           end)

    assert Hyperlang.Filesystem.dispatch(
             handle,
             :write_file,
             ["/mem/owned.txt", "replayed"],
             %{call_id: call_id}
           ) == {:ok, {:error, :stale_eval_request}}

    assert Hyperlang.Filesystem.read_file(handle, "/mem/owned.txt") == {:error, :enoent}
  end

  test "filesystem eval lifecycle API rejects missing call ids before server dispatch" do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 commit_policy: :on_eval_success,
                 mounts: [
                   %{
                     virtual: "/mem",
                     backend: "memory",
                     mode: :memory,
                     allow: [:read, :write]
                   }
                 ]
               }
             })

    assert {:ok, handle} = Hyperlang.Filesystem.start(manifest.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    assert Hyperlang.Filesystem.begin_eval(handle, :missing) == {:error, :missing_call_id}

    assert Hyperlang.Filesystem.finish_eval(handle, :missing, :success) ==
             {:error, :missing_call_id}

    assert Hyperlang.Filesystem.close_call_handles(handle, :missing) == {:error, :missing_call_id}
    assert Hyperlang.Filesystem.read_file(handle, "/mem/anything.txt") == {:error, :enoent}
  end

  test "shared attached filesystem serializes parallel eval writes" do
    source = ~S"""
    result(Input) ->
      file:write_file("/shared/log.txt", Input, [append]).
    """

    manifest =
      erlang_public(%{
        filesystem: %{
          enabled: true,
          file_compat: true,
          commit_policy: :per_request,
          mounts: [
            %{
              virtual: "/shared",
              backend: "memory",
              mode: :memory,
              allow: [:read, :write],
              files: [%{path: "/shared/log.txt", content: <<>>}]
            }
          ]
        }
      })

    {:ok, normalized} = Hyperlang.Manifest.normalize(manifest)
    {:ok, handle} = Hyperlang.Filesystem.start(normalized.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    {:ok, program} = Hyperlang.Test.program(source, manifest)

    instance_a = {program, [bindings: %{}, policy: [filesystem: [attach: handle]]]}
    instance_b = {program, [bindings: %{}, policy: [filesystem: [attach: handle]]]}

    tasks =
      for n <- 1..40 do
        instance = if rem(n, 2) == 0, do: instance_a, else: instance_b
        Task.async(fn -> eval(instance, <<?a + rem(n, 26)>>) end)
      end

    assert Enum.map(tasks, &Task.await(&1, 5_000)) == List.duplicate({:ok, :ok}, 40)
    assert {:ok, log} = Hyperlang.Filesystem.read_file(handle, "/shared/log.txt")
    assert byte_size(log) == 40

    assert Hyperlang.Filesystem.read_file(handle, "/shared/log.txt") == {:ok, log}
    assert Hyperlang.Filesystem.read_file(handle, "/shared/log.txt") == {:ok, log}
  end

  test "shared on_eval_success transactions merge concurrent staged writes" do
    parent = self()

    source = ~S"""
    result(Input) ->
      Path = maps:get(<<"path">>, Input),
      Body = maps:get(<<"body">>, Input),
      Gate = maps:get(<<"gate">>, Input),
      ok = file:write_file(Path, Body),
      gate:block(Gate),
      ok.
    """

    manifest =
      erlang_public(%{
        bindings: %{"gate" => %{block: fn _gate -> :ok end}},
        filesystem: %{
          enabled: true,
          file_compat: true,
          commit_policy: :on_eval_success,
          mounts: [
            %{
              virtual: "/shared",
              backend: "memory",
              mode: :memory,
              allow: [:read, :write]
            }
          ]
        },
        limits: %{wall_ms: 5_000}
      })

    {:ok, normalized} = Hyperlang.Manifest.normalize(Map.delete(manifest, :bindings))
    {:ok, handle} = Hyperlang.Filesystem.start(normalized.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    {:ok, program} = Hyperlang.Test.program(source, manifest)

    imports = %{
      "gate" => %{
        block: fn gate ->
          send(parent, {:after_write, gate, self()})

          receive do
            :continue -> :ok
          after
            5_000 -> :timeout
          end
        end
      }
    }

    instance_a =
      {program, [bindings: imports, policy: [filesystem: [attach: handle]]]}

    instance_b =
      {program, [bindings: imports, policy: [filesystem: [attach: handle]]]}

    task_a =
      Task.async(fn ->
        eval(instance_a, %{
          <<"path">> => <<"/shared/a.txt">>,
          <<"body">> => <<"a">>,
          <<"gate">> => <<"a">>
        })
      end)

    task_b =
      Task.async(fn ->
        eval(instance_b, %{
          <<"path">> => <<"/shared/b.txt">>,
          <<"body">> => <<"b">>,
          <<"gate">> => <<"b">>
        })
      end)

    assert_receive {:after_write, <<"a">>, worker_a}, 1_000
    assert_receive {:after_write, <<"b">>, worker_b}, 1_000

    assert Hyperlang.Filesystem.read_file(handle, "/shared/a.txt") == {:error, :enoent}
    assert Hyperlang.Filesystem.read_file(handle, "/shared/b.txt") == {:error, :enoent}

    send(worker_a, :continue)
    assert Task.await(task_a, 5_000) == {:ok, :ok}
    send(worker_b, :continue)
    assert Task.await(task_b, 5_000) == {:ok, :ok}

    assert Hyperlang.Filesystem.read_file(handle, "/shared/a.txt") == {:ok, <<"a">>}
    assert Hyperlang.Filesystem.read_file(handle, "/shared/b.txt") == {:ok, <<"b">>}
  end

  test "failed shared on_eval_success transaction does not roll back newer commits" do
    parent = self()

    source = ~S"""
    result(Input) ->
      Path = maps:get(<<"path">>, Input),
      Body = maps:get(<<"body">>, Input),
      Fail = maps:get(<<"fail">>, Input),
      Gate = maps:get(<<"gate">>, Input),
      ok = file:write_file(Path, Body),
      gate:block(Gate),
      case Fail of
        true -> 1 div 0;
        false -> ok
      end.
    """

    manifest =
      erlang_public(%{
        bindings: %{"gate" => %{block: fn _gate -> :ok end}},
        filesystem: %{
          enabled: true,
          file_compat: true,
          commit_policy: :on_eval_success,
          mounts: [
            %{
              virtual: "/shared",
              backend: "memory",
              mode: :memory,
              allow: [:read, :write]
            }
          ]
        },
        limits: %{wall_ms: 5_000}
      })

    {:ok, normalized} = Hyperlang.Manifest.normalize(Map.delete(manifest, :bindings))
    {:ok, handle} = Hyperlang.Filesystem.start(normalized.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    {:ok, program} = Hyperlang.Test.program(source, manifest)

    imports = %{
      "gate" => %{
        block: fn gate ->
          send(parent, {:after_write, gate, self()})

          receive do
            :continue -> :ok
          after
            5_000 -> :timeout
          end
        end
      }
    }

    instance_a =
      {program, [bindings: imports, policy: [filesystem: [attach: handle]]]}

    instance_b =
      {program, [bindings: imports, policy: [filesystem: [attach: handle]]]}

    task_a =
      Task.async(fn ->
        run_instance(instance_a, %{
          <<"path">> => <<"/shared/a.txt">>,
          <<"body">> => <<"a">>,
          <<"fail">> => true,
          <<"gate">> => <<"a">>
        })
      end)

    task_b =
      Task.async(fn ->
        eval(instance_b, %{
          <<"path">> => <<"/shared/b.txt">>,
          <<"body">> => <<"b">>,
          <<"fail">> => false,
          <<"gate">> => <<"b">>
        })
      end)

    assert_receive {:after_write, <<"a">>, worker_a}, 1_000
    assert_receive {:after_write, <<"b">>, worker_b}, 1_000

    send(worker_b, :continue)
    assert Task.await(task_b, 5_000) == {:ok, :ok}
    assert Hyperlang.Filesystem.read_file(handle, "/shared/b.txt") == {:ok, <<"b">>}

    send(worker_a, :continue)
    assert {:error, _error} = Task.await(task_a, 5_000)

    assert Hyperlang.Filesystem.read_file(handle, "/shared/a.txt") == {:error, :enoent}
    assert Hyperlang.Filesystem.read_file(handle, "/shared/b.txt") == {:ok, <<"b">>}
  end

  test "filesystem disabled keeps standard compatibility calls rejected" do
    for {source, expected} <- [
          {"file:read_file(\"x\").", "file:read_file/1"},
          {"file:write_file(\"x\", <<\"data\">>).", "file:write_file/2"},
          {"file:list_dir(\"x\").", "file:list_dir/1"},
          {"file:delete(\"x\").", "file:delete/1"},
          {"file:make_dir(\"x\").", "file:make_dir/1"},
          {"file:rename(\"x\", \"y\").", "file:rename/2"},
          {"file:read_file_info(\"x\").", "file:read_file_info/1"},
          {"file:open(\"x\", [read]).", "file:open/2"},
          {"file:consult(\"x\").", "file:consult/1"},
          {"file:script(\"x\").", "file:script/1"},
          {"file:eval(\"x\").", "file:eval/1"},
          {"filelib:is_file(\"x\").", "filelib:is_file/1"},
          {"filelib:is_dir(\"x\").", "filelib:is_dir/1"},
          {"filelib:ensure_dir(\"x\").", "filelib:ensure_dir/1"},
          {"compile:file(\"x\").", "compile:file/1"},
          {"code:ensure_loaded(<<\"codemode_program\">>).", "code:ensure_loaded/1"},
          {"erl_eval:exprs([], []).", "erl_eval:exprs/2"}
        ] do
      assert {:error, errors} =
               Hyperlang.Test.program(source, %{filesystem: %{enabled: false}})

      assert inspect(errors) =~ expected
    end
  end

  test "standard filesystem and loader calls return capability-aware diagnostics" do
    assert {:error, [disabled_fs]} =
             Hyperlang.Test.program(~S|file:read_file("x").|, %{
               filesystem: %{enabled: false}
             })

    assert disabled_fs.message =~ "file:read_file/1"
    assert disabled_fs.message =~ "filesystem compatibility is disabled"
    assert disabled_fs.details.capability == :filesystem
    assert disabled_fs.details.reason == :filesystem_disabled

    assert {:error, [disabled_handle]} =
             Hyperlang.Test.program(~S|file:open("x", [read]).|, %{
               filesystem: %{enabled: true, file_compat: true}
             })

    assert disabled_handle.message =~ "file:open/2"
    assert disabled_handle.message =~ "handle compatibility is disabled"
    assert disabled_handle.details.capability == :filesystem
    assert disabled_handle.details.reason == :handle_compat_disabled

    assert {:error, [disabled_file_loader]} =
             Hyperlang.Test.program(~S|file:consult("x").|, %{
               filesystem: %{enabled: true, file_compat: true}
             })

    assert disabled_file_loader.message =~ "file:consult/1"
    assert disabled_file_loader.message =~ "loader/evaluator compatibility is disabled"
    assert disabled_file_loader.details.capability == :filesystem
    assert disabled_file_loader.details.reason == :loader_compat_disabled

    assert {:error, [unsupported_filelib]} =
             Hyperlang.Test.program(~S|filelib:last_modified("x").|, %{
               filesystem: %{enabled: true, filelib_compat: true}
             })

    assert unsupported_filelib.message =~ "filelib:last_modified/1"
    assert unsupported_filelib.message =~ "not supported by Hyperlang"
    assert unsupported_filelib.details.capability == :filesystem
    assert unsupported_filelib.details.reason == :unsupported_filesystem_mfa

    assert {:error, [forbidden_compile]} =
             Hyperlang.Test.program(~S|compile:file("x").|, %{
               filesystem: %{enabled: true}
             })

    assert forbidden_compile.message =~ "compile:file/1"
    assert forbidden_compile.message =~ "compatibility is disabled"

    assert {:error, [forbidden_compile_with_flags]} =
             Hyperlang.Test.program(~S|compile:file("x").|, %{
               filesystem: %{enabled: true, loader_compat: true}
             })

    assert forbidden_compile_with_flags.message =~ "compile:file/1"
    assert forbidden_compile_with_flags.message =~ "source compilation compatibility is disabled"

    assert {:error, [forbidden_evaluator]} =
             Hyperlang.Test.program(~S|erl_eval:exprs([], []).|, %{
               filesystem: %{enabled: true, loader_compat: true}
             })

    assert forbidden_evaluator.message =~ "erl_eval:exprs/2"
    assert forbidden_evaluator.message =~ "evaluator compatibility is disabled"

    diagnostic_text =
      inspect([
        disabled_fs,
        disabled_handle,
        disabled_file_loader,
        unsupported_filelib,
        forbidden_compile,
        forbidden_compile_with_flags,
        forbidden_evaluator
      ])

    refute diagnostic_text =~ "#PID<"
    refute diagnostic_text =~ "#Port<"
    refute diagnostic_text =~ "#Reference<"

    if System.get_env("USER") do
      refute diagnostic_text =~ System.get_env("USER")
    end
  end

  test "filesystem compatibility does not add binary convenience helpers" do
    assert {:error, [helper_error]} =
             Hyperlang.Test.program(~S|file:list_dir_binary("/assets").|, %{
               filesystem: %{enabled: true, file_compat: true}
             })

    assert helper_error.message =~ "file:list_dir_binary/1"
    assert helper_error.details.reason == :unsupported_filesystem_mfa

    {_program, instance} =
      compile_and_instance(
        ~S|asset:list_names("/assets").|,
        erlang_public(),
        %{"asset" => %{list_names: fn path -> {path, [<<"a.txt">>, <<"b.txt">>]} end}}
      )

    assert eval(instance, :ok) == {:ok, {~c"/assets", [<<"a.txt">>, <<"b.txt">>]}}

    for reserved <- ["file", "filelib"] do
      assert {:error, errors} =
               Hyperlang.Manifest.normalize(%{bindings: %{reserved => KVBinding}})

      assert inspect(errors) =~ "reserved authority module"
    end
  end

  test "filesystem enabled lowers file read to compiler-owned dispatch and evaluates through worker" do
    manifest =
      erlang_public(%{
        filesystem: %{
          enabled: true,
          file_compat: true,
          mounts: [
            %{
              virtual: "/mem",
              backend: "memory",
              mode: :memory,
              allow: [:read],
              files: [%{path: "/mem/a.txt", content: <<"alpha">>}]
            }
          ]
        }
      })

    assert {:ok, normalized} = Hyperlang.Manifest.normalize(manifest)
    normalized = Hyperlang.DoorTestSupport.seed_atom_universe(normalized)

    assert {:ok, compiled} =
             Hyperlang.Compiler.compile(~S|file:read_file("/mem/a.txt").|, normalized)

    assert {:filesystem, "file", "read_file", 1} in compiled.core.calls

    {_program, instance} = compile_and_instance(~S|file:read_file("/mem/a.txt").|, manifest)
    assert eval(instance, :ok) == {:ok, {:ok, <<"alpha">>}}
  end

  test "filesystem dispatch does not fall through to host file or manifest imports" do
    manifest =
      erlang_public(%{
        filesystem: %{
          enabled: true,
          file_compat: true,
          mounts: [
            %{virtual: "/mem", backend: "memory", mode: :memory, allow: [:read]}
          ]
        }
      })

    {_program, instance} =
      compile_and_instance(
        ~S|file:read_file("/definitely-not-mounted-safe-erl-path").|,
        manifest,
        %{"tools" => %{read_file: fn _path -> raise "must not be called" end}}
      )

    assert {:ok, {:error, :eacces}, %{stdout: []}} = run_instance(instance, :ok)

    assert {:error, errors} = Hyperlang.Manifest.normalize(%{bindings: %{"file" => KVBinding}})

    assert inspect(errors) =~ "reserved authority module file"
  end

  test "filesystem enabled still rejects prim_file and unsupported loader-style file calls" do
    manifest = %{
      filesystem: %{
        enabled: true,
        file_compat: true,
        mounts: [
          %{virtual: "/mem", backend: "memory", mode: :memory, allow: [:read]}
        ]
      }
    }

    for {source, expected} <- [
          {"file_server:read_file(\"/mem/a.txt\").", "file_server:read_file/1"},
          {"prim_file:read_file(\"/mem/a.txt\").", "prim_file:read_file/1"},
          {"file:consult(\"/mem/a.terms\").", "file:consult/1"},
          {"file:script(\"/mem/a.erl\").", "file:script/1"}
        ] do
      assert {:error, errors} = Hyperlang.Test.program(source, manifest)
      assert inspect(errors) =~ expected
    end
  end

  test "filesystem verifier and classifier allow only compiler-owned capability calls" do
    enabled = %{
      filesystem: %{
        enabled: true,
        file_compat: true,
        mounts: [
          %{virtual: "/mem", backend: "memory", mode: :memory, allow: [:read]}
        ]
      }
    }

    assert {:error, disabled_errors} =
             Hyperlang.Test.program(~S|file:read_file("/mem/a.txt").|, %{
               filesystem: %{enabled: false}
             })

    assert [disabled_error] = disabled_errors
    assert disabled_error.message =~ "file:read_file/1"
    assert disabled_error.message =~ "filesystem compatibility is disabled"
    assert disabled_error.details.reason == :filesystem_disabled

    assert {:ok, normalized} = Hyperlang.Manifest.normalize(enabled)
    normalized = Hyperlang.DoorTestSupport.seed_atom_universe(normalized)

    assert {:ok, compiled} =
             Hyperlang.Compiler.compile(~S|file:read_file("/mem/a.txt").|, normalized)

    assert {:filesystem, "file", "read_file", 1} in compiled.core.calls

    result_fun = Map.fetch!(compiled.core.functions, {"result", 1})
    [clause] = result_fun.clauses
    assert clause.body.node == :safe_filesystem_call
    assert clause.body.module == "file"
    assert clause.body.function == "read_file"
    assert clause.body.operation == :read_file

    for {source, expected} <- [
          {~S|some_module:f(1).|, "some_module:f/1"},
          {~S|os:cmd("id").|, "os:cmd/1"},
          {~S|code:priv_dir(kernel).|, "code:priv_dir/1"},
          {~S|file_server:read_file("/mem/a.txt").|, "file_server:read_file/1"},
          {~S|prim_file:read_file("/mem/a.txt").|, "prim_file:read_file/1"}
        ] do
      assert {:error, errors} = Hyperlang.Test.program(source, enabled)
      assert inspect(errors) =~ expected
    end
  end

  test "documentation is collapsed to approved top-level docs" do
    assert Path.wildcard("README*") == ["README.md"]

    assert Path.wildcard("doc/*.md") == [
             "doc/COMPARISON.md",
             "doc/SECURITY_SPECIFICATION.md"
           ]

    readme = File.read!(@readme_doc)
    security = File.read!(@security_spec_doc)

    assert readme =~ "# Hyperlang 101"
    assert readme =~ "## The door"
    assert readme =~ "## Filesystem capability"
    assert readme =~ "## Where Hyperlang deliberately differs"
    assert security =~ "# Hyperlang Security Specification"
    assert security =~ "This is the only security specification document"
  end

  test "loader evaluator unsupported MFA coverage has explicit diagnostics" do
    manifest = %{
      filesystem: %{
        enabled: true,
        file_compat: true,
        loader_compat: true,
        source_compile: true,
        mounts: [
          %{virtual: "/src", backend: "memory", mode: :memory, allow: [:read]}
        ]
      }
    }

    for {module, function, arity, reason} <- loader_evaluator_unsupported_mfas() do
      source = mfa_call_source(module, function, arity)
      expected_mfa = "#{module}:#{function}/#{arity}"

      assert {:error, [error]} = Hyperlang.Test.program(source, manifest)
      assert error.message =~ expected_mfa

      if module in ["compile", "code"] do
        assert error.message =~ "not supported by Hyperlang"
      else
        if module == "erl_eval" do
          assert error.message =~ "evaluator compatibility is disabled"
        else
          assert error.details.reason == reason
          assert error.details.capability == :filesystem
        end
      end
    end
  end

  test "unsupported loader evaluator calls are compile-time diagnostics despite guest catch" do
    manifest = %{
      filesystem: %{
        enabled: true,
        file_compat: true,
        loader_compat: true,
        source_compile: true,
        mounts: [
          %{virtual: "/src", backend: "memory", mode: :memory, allow: [:read]}
        ]
      }
    }

    for {source, expected_mfa, expected_reason} <- [
          {~S|try file:script("/src/a.erl") catch _:_ -> caught end.|, "file:script/1",
           :unsupported_filesystem_mfa},
          {~S|try file:eval("/src/a.expr") catch _:_ -> caught end.|, "file:eval/1",
           :unsupported_filesystem_mfa},
          {~S|try compile:forms([]) catch _:_ -> caught end.|, "compile:forms/1",
           :unsupported_loader_mfa},
          {~S|try erl_eval:exprs([], []) catch _:_ -> caught end.|, "erl_eval:exprs/2",
           :evaluator_compat_disabled}
        ] do
      assert {:error, [error]} = Hyperlang.Test.program(source, manifest)
      assert error.message =~ expected_mfa

      if expected_reason == :unsupported_loader_mfa do
        assert error.message =~ "not supported by Hyperlang"
      else
        if expected_reason == :evaluator_compat_disabled do
          assert error.message =~ "evaluator compatibility is disabled"
        else
          assert error.details.reason == expected_reason
          assert error.details.capability == :filesystem
        end
      end
    end
  end

  test "runtime-owned capability atom vocabularies merge into allowed atoms" do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 enabled: true,
                 file_compat: true,
                 loader_compat: true,
                 mounts: [
                   %{virtual: "/mem", backend: "memory", mode: :memory, allow: [:read]}
                 ]
               }
             })

    for atom <- [
          :enoent,
          :eacces,
          :eisdir,
          :enotdir,
          :enospc,
          :badarg,
          :file_info,
          :regular,
          :directory,
          :symlink,
          :read_write,
          :none
        ] do
      assert MapSet.member?(manifest.terms.allowed_atoms, atom)
    end

    for atom <- [
          :global,
          :return,
          :binary,
          :capture,
          :all,
          :unicode,
          :notempty,
          :nomatch,
          :value,
          :empty,
          :millisecond,
          :microsecond,
          :nanosecond,
          :perf_counter,
          :array,
          :graph
        ] do
      assert MapSet.member?(manifest.terms.allowed_atoms, atom)
    end

    for atom <- [:module, :deterministic, :no_docs, :no_auto_import] do
      assert MapSet.member?(manifest.terms.allowed_atoms, atom)
    end
  end

  test "file consult reads virtual files and parses literal terms through Hyperlang" do
    source = ~S"""
    case file:consult("/terms/a.config") of
      {ok, [42, <<"bin">>, {alpha, [1, 2]}, #{<<"k">> := beta}]} -> ok;
      Other -> Other
    end.
    """

    {program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          limits: %{max_atom_count: 2},
          filesystem: %{
            enabled: true,
            file_compat: true,
            loader_compat: true,
            mounts: [
              %{
                virtual: "/terms",
                backend: "memory",
                mode: :memory,
                allow: [:read],
                files: [
                  %{
                    path: "/terms/a.config",
                    content: ~S"""
                    42.
                    <<"bin">>.
                    {alpha, [1, 2]}.
                    #{<<"k">> => beta}.
                    """
                  }
                ]
              }
            ]
          }
        })
      )

    assert Map.from_struct(program).metadata.atom_pool_size == 2
    assert eval(instance, :ok) == {:ok, :ok}
  end

  test "file path_consult searches virtual paths and returns the matching filename" do
    source = ~S"""
    case file:path_consult(["/terms/missing", "/terms"], "a.config") of
      {ok, [alpha], "/terms/a.config"} -> ok;
      Other -> Other
    end.
    """

    {program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          limits: %{max_atom_count: 1},
          filesystem: %{
            enabled: true,
            file_compat: true,
            loader_compat: true,
            mounts: [
              %{
                virtual: "/terms",
                backend: "memory",
                mode: :memory,
                allow: [:read],
                files: [%{path: "/terms/a.config", content: "alpha.\n"}]
              }
            ]
          }
        })
      )

    assert Map.from_struct(program).metadata.atom_pool_size == 1
    assert eval(instance, :ok) == {:ok, :ok}
  end

  test "file consult returns OTP-shaped errors for missing unsafe and atom-overflow terms" do
    source = ~S"""
    Missing = file:consult("/terms/missing.config"),
    Unsafe = file:consult("/terms/call.config"),
    Overflow = file:consult("/terms/atom.config"),
    {Missing, Unsafe, Overflow}.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          limits: %{max_atom_count: 0},
          filesystem: %{
            enabled: true,
            file_compat: true,
            loader_compat: true,
            mounts: [
              %{
                virtual: "/terms",
                backend: "memory",
                mode: :memory,
                allow: [:read],
                files: [
                  %{path: "/terms/call.config", content: "os:cmd(\"id\").\n"},
                  %{path: "/terms/atom.config", content: "runtime_new_atom.\n"}
                ]
              }
            ]
          }
        })
      )

    assert eval(instance, :ok) ==
             {:ok, {{:error, :enoent}, {:error, :badarg}, {:error, :eoverflow}}}
  end

  test "file consult requires loader compatibility and keeps script eval unsupported" do
    assert {:error, [disabled_consult]} =
             Hyperlang.Test.program(~S|file:consult("/terms/a.config").|, %{
               filesystem: %{enabled: true, file_compat: true}
             })

    assert disabled_consult.message =~ "file:consult/1"
    assert disabled_consult.details.reason == :loader_compat_disabled

    assert {:error, [disabled_path_consult]} =
             Hyperlang.Test.program(~S|file:path_consult(["/terms"], "a.config").|, %{
               filesystem: %{enabled: true, file_compat: true}
             })

    assert disabled_path_consult.message =~ "file:path_consult/2"
    assert disabled_path_consult.details.reason == :loader_compat_disabled

    manifest = %{
      filesystem: %{
        enabled: true,
        file_compat: true,
        loader_compat: true,
        source_compile: true,
        mounts: [%{virtual: "/terms", backend: "memory", mode: :memory, allow: [:read]}]
      }
    }

    for source <- [
          ~S|file:script("/terms/a.erl").|,
          ~S|file:eval("/terms/a.expr").|,
          ~S|file:path_script(["/terms"], "a.erl").|,
          ~S|file:path_eval(["/terms"], "a.expr").|
        ] do
      assert {:error, [error]} = Hyperlang.Test.program(source, manifest)
      assert error.details.reason == :unsupported_filesystem_mfa
    end
  end

  test "filesystem reason atoms pattern-match without consuming guest atom slots" do
    source = ~S"""
    case {
      file:read_file("/mem/missing.txt"),
      file:read_file("/secret/a.txt"),
      file:read_file("/mem/dir")
    } of
      {{error, enoent}, {error, eacces}, {error, eisdir}} -> ok;
      Other -> Other
    end.
    """

    manifest =
      erlang_public(%{
        limits: %{max_atom_count: 0},
        filesystem: %{
          enabled: true,
          file_compat: true,
          mounts: [
            %{
              virtual: "/mem",
              backend: "memory",
              mode: :memory,
              allow: [:read],
              dirs: ["/mem/dir"]
            },
            %{
              virtual: "/secret",
              backend: "memory",
              mode: :memory,
              allow: [],
              files: [%{path: "/secret/a.txt", content: <<"hidden">>}]
            }
          ]
        }
      })

    {program, instance} = compile_and_instance(source, manifest)
    assert Map.from_struct(program).metadata.atom_pool_size == 0
    assert eval(instance, :ok) == {:ok, :ok}
  end

  test "filesystem metadata atoms pattern-match without consuming guest atom slots" do
    source = ~S"""
    case file:read_file_info("/mem/a.txt") of
      {ok, {file_info, 3, regular, read_write, _, _, _, _, 1, 0, 0, 0, 0, 0}} -> ok;
      Other -> Other
    end.
    """

    manifest =
      erlang_public(%{
        stdlib: [],
        limits: %{max_atom_count: 0},
        filesystem: %{
          enabled: true,
          file_compat: true,
          mounts: [
            %{
              virtual: "/mem",
              backend: "memory",
              mode: :memory,
              allow: [:stat],
              files: [%{path: "/mem/a.txt", content: <<"abc">>}]
            }
          ]
        }
      })

    {program, instance} = compile_and_instance(source, manifest)
    assert Map.from_struct(program).metadata.atom_pool_size == 0
    assert eval(instance, :ok) == {:ok, :ok}
  end

  test "filesystem write_file option atoms do not consume guest atom slots" do
    source = ~S"""
    ok = file:write_file("/mem/write.txt", <<"x">>, [write]),
    ok = file:write_file("/mem/raw.txt", <<"x">>, [raw]),
    ok = file:write_file("/mem/binary.txt", <<"x">>, [binary]),
    ok = file:write_file("/mem/delayed_write.txt", <<"x">>, [delayed_write]),
    ok = file:write_file("/mem/delayed_write_tuple.txt", <<"x">>, [{delayed_write, 8, 100}]),
    ok = file:write_file("/mem/read.txt", <<"x">>, [read]),
    ok = file:write_file("/mem/sync.txt", <<"x">>, [sync]),
    ok = file:write_file("/mem/read_ahead.txt", <<"x">>, [read_ahead]),
    ok = file:write_file("/mem/read_ahead_size.txt", <<"x">>, [{read_ahead, 8}]),
    ok = file:write_file("/mem/append.txt", <<"x">>, [append]),
    ok = file:write_file("/mem/exclusive.txt", <<"x">>, [exclusive]),
    ok.
    """

    manifest =
      erlang_public(%{
        stdlib: [],
        limits: %{max_atom_count: 0},
        filesystem: %{
          enabled: true,
          file_compat: true,
          mounts: [
            %{virtual: "/mem", backend: "memory", mode: :memory, allow: [:write]}
          ]
        }
      })

    {program, instance} = compile_and_instance(source, manifest)
    assert Map.from_struct(program).metadata.atom_pool_size == 0
    assert eval(instance, :ok) == {:ok, :ok}
  end

  test "regex option atoms work under atom-pool limits without manual allowlists" do
    source = ~S"""
    re:replace(<<"aaaa">>, <<"a">>, <<"b">>, [global, {return, binary}]).
    """

    {program, instance} =
      compile_and_instance(source, erlang_public(%{limits: %{max_atom_count: 0}}))

    assert Map.from_struct(program).metadata.atom_pool_size == 0
    assert eval(instance, :ok) == {:ok, <<"bbbb">>}
  end

  test "loader result atoms are fixed vocabulary while source module names stay pooled" do
    source = ~S"""
    case {{ok, main}, {module, main}, {error, deterministic}, {ok, no_docs}} of
      {{ok, main}, {module, main}, {error, deterministic}, {ok, no_docs}} -> ok;
      Other -> Other
    end.
    """

    {program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          limits: %{max_atom_count: 1},
          filesystem: %{loader_compat: true}
        })
      )

    assert Map.from_struct(program).metadata.atom_pool_size == 1
    assert eval(instance, :ok) == {:ok, :ok}

    assert {:error, errors} =
             Hyperlang.Test.program(
               "custom_runtime_atom.",
               erlang_public(%{
                 limits: %{max_atom_count: 0},
                 filesystem: %{enabled: true, file_compat: true}
               })
             )

    assert inspect(errors) =~ "source atom pool exceeds limit"
  end

  test "data filesystem file operations expose standard Erlang status shapes" do
    source = ~S"""
    ok = file:write_file("/mem/out/a.txt", <<"one">>),
    ok = file:write_file("/mem/out/a.txt", <<"two">>, [append]),
    {ok, <<"onetwo">>} = file:read_file("/mem/out/a.txt"),
    ok = file:make_dir("/mem/out/dir"),
    {ok, Names} = file:list_dir("/mem/out"),
    ok = file:rename("/mem/out/a.txt", "/mem/out/b.txt"),
    {error, enoent} = file:read_file("/mem/out/a.txt"),
    {ok, <<"onetwo">>} = file:read_file("/mem/out/b.txt"),
    ok = file:delete("/mem/out/b.txt"),
    ok = file:del_dir("/mem/out/dir"),
    Names.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          filesystem: %{
            enabled: true,
            file_compat: true,
            mounts: [
              %{
                virtual: "/mem",
                backend: "memory",
                mode: :memory,
                allow: [:read, :write, :delete, :mkdir, :list, :rename],
                dirs: ["/mem/out"]
              }
            ]
          }
        })
      )

    assert eval(instance, :ok) == {:ok, [~c"a.txt", ~c"dir"]}
  end

  test "data filesystem metadata and cwd operations use virtual OTP-compatible results" do
    source = ~S"""
    {ok, Cwd0} = file:get_cwd(),
    ok = file:set_cwd("/mem/docs"),
    {ok, Cwd1} = file:get_cwd(),
    ok = file:write_file("note.txt", <<"abc">>, [binary]),
    {ok, <<"abc">>} = file:read_file("note.txt"),
    {ok, Info} = file:read_file_info("note.txt"),
    {ok, LinkInfo} = file:read_link_info("note.txt"),
    {error, enotsup} = file:get_cwd("C:"),
    {error, badarg} = file:get_cwd(<<"C:">>),
    ok = file:write_file("exclusive.txt", <<"x">>, [exclusive]),
    {error, eexist} = file:write_file("exclusive.txt", <<"y">>, [exclusive]),
    {Cwd0, Cwd1, Info, LinkInfo}.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          filesystem: %{
            enabled: true,
            file_compat: true,
            allow_relative_paths: true,
            cwd: "/mem",
            mounts: [
              %{
                virtual: "/mem",
                backend: "memory",
                mode: :memory,
                allow: [:read, :write, :stat, :lstat],
                dirs: ["/mem/docs"]
              }
            ]
          }
        })
      )

    assert {:ok, {~c"/mem", ~c"/mem/docs", info, link_info}} = eval(instance, :ok)
    assert info == link_info

    assert {:file_info, 3, :regular, :read_write, _, _, _, 0o100644, 1, 0, 0, 0, 0, 0} =
             info
  end

  test "guest relative file paths resolve only through virtual cwd" do
    source = ~S"""
    {ok, Cwd0} = file:get_cwd(),
    {ok, <<"root">>} = file:read_file("input.txt"),
    ok = file:set_cwd("/work/sub"),
    {ok, Cwd1} = file:get_cwd(),
    {ok, <<"sub">>} = file:read_file("input.txt"),
    {Cwd0, Cwd1}.
    """

    host_cwd = File.cwd!()

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          filesystem: %{
            enabled: true,
            file_compat: true,
            cwd: "/work",
            allow_relative_paths: true,
            mounts: [
              %{
                virtual: "/work",
                backend: "memory",
                mode: :memory,
                allow: [:read, :stat],
                dirs: ["/work/sub"],
                files: [
                  %{path: "/work/input.txt", content: <<"root">>},
                  %{path: "/work/sub/input.txt", content: <<"sub">>}
                ]
              }
            ]
          }
        })
      )

    assert eval(instance, :ok) == {:ok, {~c"/work", ~c"/work/sub"}}
    assert File.cwd!() == host_cwd

    disabled_source = ~S"""
    {ok, Cwd} = file:get_cwd(),
    {error, invalid_path} = file:read_file("input.txt"),
    Cwd.
    """

    {_program, disabled_instance} =
      compile_and_instance(
        disabled_source,
        erlang_public(%{
          filesystem: %{
            enabled: true,
            file_compat: true,
            cwd: "/work",
            allow_relative_paths: false,
            mounts: [
              %{
                virtual: "/work",
                backend: "memory",
                mode: :memory,
                allow: [:read],
                files: [%{path: "/work/input.txt", content: <<"root">>}]
              }
            ]
          }
        })
      )

    assert eval(disabled_instance, :ok) == {:ok, ~c"/work"}
    assert File.cwd!() == host_cwd
  end

  test "file handle compatibility is opt-in and rejected by default" do
    manifest =
      erlang_public(%{
        filesystem: %{
          enabled: true,
          file_compat: true,
          mounts: [
            %{
              virtual: "/mem",
              backend: "memory",
              mode: :memory,
              allow: [:read],
              files: [%{path: "/mem/a.txt", content: <<"abc">>}]
            }
          ]
        }
      })

    assert {:error, errors} =
             Hyperlang.Test.program(~S|file:open("/mem/a.txt", [read]).|, manifest)

    assert inspect(errors) =~ "file:open/2"
  end

  test "file handles read write append close and eof through the filesystem server" do
    source = ~S"""
    {ok, R} = file:open("/mem/in.txt", [read, binary]),
    {ok, <<"ab">>} = file:read(R, 2),
    {ok, <<"c">>} = file:read(R, 10),
    eof = file:read(R, 1),
    ok = file:close(R),
    {error, ebadf} = file:read(R, 1),

    {ok, W} = file:open("/mem/out.txt", [write, binary]),
    ok = file:write(W, [<<"x">>, "y"]),
    ok = file:close(W),
    {ok, A} = file:open("/mem/out.txt", [append, binary]),
    ok = file:write(A, <<"z">>),
    ok = file:close(A),
    {ok, <<"xyz">>} = file:read_file("/mem/out.txt"),
    ok.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          filesystem: %{
            enabled: true,
            file_compat: true,
            handle_compat: true,
            mounts: [
              %{
                virtual: "/mem",
                backend: "memory",
                mode: :memory,
                allow: [:read, :write],
                files: [%{path: "/mem/in.txt", content: <<"abc">>}]
              }
            ]
          }
        })
      )

    assert eval(instance, :ok) == {:ok, :ok}
  end

  test "file handle writes enforce iodata size before sending content to server" do
    source = ~S"""
    {ok, W} = file:open("/mem/out.txt", [write, binary]),
    {error, enospc} = file:write(W, lists:duplicate(5000, <<"x">>)),
    ok = file:write(W, <<"ok">>),
    ok = file:close(W),
    file:read_file("/mem/out.txt").
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          filesystem: %{
            enabled: true,
            file_compat: true,
            handle_compat: true,
            mounts: [
              %{
                virtual: "/mem",
                backend: "memory",
                mode: :memory,
                allow: [:read, :write],
                limits: %{max_single_write_bytes: 3}
              }
            ]
          }
        })
      )

    assert eval(instance, :ok) == {:ok, {:ok, <<"ok">>}}
  end

  test "file handles cannot cross host output import or stdout boundaries" do
    base_manifest =
      erlang_public(%{
        filesystem: %{
          enabled: true,
          file_compat: true,
          handle_compat: true,
          mounts: [
            %{
              virtual: "/mem",
              backend: "memory",
              mode: :memory,
              allow: [:read],
              files: [%{path: "/mem/a.txt", content: <<"abc">>}]
            }
          ]
        }
      })

    {_program, output_instance} =
      compile_and_instance(
        ~S|{ok, H} = file:open("/mem/a.txt", [read]), H.|,
        base_manifest
      )

    assert_eval_error(run_instance(output_instance, :ok), :output)

    {_program, input_instance} = compile_and_instance(~S|Input.|, base_manifest)
    forged_host_handle = Hyperlang.Filesystem.make_guest_handle()

    assert_eval_error(
      run_instance(input_instance, forged_host_handle),
      :input
    )

    parent = self()

    {_program, import_instance} =
      compile_and_instance(
        ~S|{ok, H} = file:open("/mem/a.txt", [read]), sink:take(H).|,
        base_manifest,
        %{"sink" => %{take: fn _handle -> send(parent, :sink_called) end}}
      )

    assert_eval_error(run_instance(import_instance, :ok), :import)
    refute_received :sink_called

    {_program, stdout_instance} =
      compile_and_instance(
        ~S|{ok, H} = file:open("/mem/a.txt", [read]), io:format("~p", [H]).|,
        base_manifest
      )

    assert_eval_error(run_instance(stdout_instance, :ok), :stdout)
  end

  test "file handles are opaque to guest tuple deconstruction" do
    source = ~S"""
    {ok, H} = file:open("/mem/a.txt", [read]),
    Opaque =
      try element(1, H) catch
        error:badarg -> <<"opaque">>
      end,
    {ok, <<"a">>} = file:read(H, 1),
    Opaque.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          filesystem: %{
            enabled: true,
            file_compat: true,
            handle_compat: true,
            mounts: [
              %{
                virtual: "/mem",
                backend: "memory",
                mode: :memory,
                allow: [:read],
                files: [%{path: "/mem/a.txt", content: <<"abc">>}]
              }
            ]
          }
        })
      )

    assert eval(instance, :ok) == {:ok, <<"opaque">>}
  end

  test "filesystem term sanitizer accepts only Hyperlang-created handles at filesystem boundary" do
    {:ok, manifest} =
      Hyperlang.Manifest.normalize(
        erlang_public(%{
          filesystem: %{
            enabled: true,
            file_compat: true,
            handle_compat: true,
            mounts: [%{virtual: "/mem", backend: "memory", mode: :memory}]
          }
        })
      )

    ctx = %{limits: manifest.limits, terms: manifest.terms}
    raw_ref = make_ref()

    assert {:error, %{category: :filesystem_args, reason: :forbidden_term}} =
             Hyperlang.Terms.sanitize_filesystem_args([raw_ref], ctx)

    port = Port.open({:spawn, "cat"}, [:binary])

    unsupported_terms = [
      self(),
      port,
      fn -> :ok end,
      :not_allowed,
      [1 | 2],
      :binary.copy(<<"x">>, manifest.limits.max_binary_bytes + 1)
    ]

    try do
      for term <- unsupported_terms do
        assert {:error, %{category: :filesystem_args}} =
                 Hyperlang.Terms.sanitize_filesystem_args([term], ctx)

        assert {:error, %{category: :filesystem_return}} =
                 Hyperlang.Terms.sanitize_filesystem_return(term, ctx)
      end
    after
      Port.close(port)
    end

    handle = Hyperlang.Filesystem.make_guest_handle(:term_boundary_test)

    assert {:ok, [^handle]} = Hyperlang.Terms.sanitize_filesystem_args([handle], ctx)
    assert {:ok, ^handle} = Hyperlang.Terms.sanitize_filesystem_return(handle, ctx)

    Hyperlang.Filesystem.release_guest_handles(:term_boundary_test)

    assert {:error, %{category: :filesystem_args, reason: :forbidden_term}} =
             Hyperlang.Terms.sanitize_filesystem_args([handle], ctx)
  end

  test "filesystem compatibility rejects unsupported path iodata and handle terms" do
    source = ~S"""
    {ok, H} = file:open("/mem/a.txt", [read, binary]),
    {error, badarg} = file:read_file(H),
    {error, badarg} = file:write_file("/mem/out.txt", [H]),
    {error, ebadf} = file:read(<<"not-a-handle">>, 1),
    {error, invalid_path} = file:read_file(<<"/mem/", 0, "bad">>),
    {error, badarg} = file:read_file([<<"/mem">>, "/a.txt"]),
    {ok, <<"abc">>} = file:read_file("/mem/a.txt"),
    {ok, Names} = file:list_dir("/mem"),
    {ok, Info} = file:read_file_info("/mem/a.txt"),
    #{<<"names">> => Names, <<"info">> => Info}.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          filesystem: %{
            enabled: true,
            file_compat: true,
            handle_compat: true,
            mounts: [
              %{
                virtual: "/mem",
                backend: "memory",
                mode: :memory,
                allow: [:read, :write, :list, :stat],
                files: [%{path: "/mem/a.txt", content: <<"abc">>}]
              }
            ]
          }
        })
      )

    assert {:ok, %{<<"names">> => names, <<"info">> => info}} = eval(instance, :ok)
    assert ~c"a.txt" in names

    assert {:file_info, 3, :regular, :read_write, _, _, _, 0o100644, 1, 0, 0, 0, 0, 0} =
             info
  end

  test "filesystem directory and metadata returns sanitize under default public policy" do
    source = ~S"""
    {ok, <<"abc">>} = file:read_file("/mem/a.txt"),
    {ok, Names} = file:list_dir("/mem"),
    {ok, Info} = file:read_file_info("/mem/a.txt"),
    #{<<"names">> => Names, <<"info">> => Info}.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        %{
          filesystem: %{
            enabled: true,
            file_compat: true,
            mounts: [
              %{
                virtual: "/mem",
                backend: "memory",
                mode: :memory,
                allow: [:read, :list, :stat],
                files: [%{path: "/mem/a.txt", content: <<"abc">>}]
              }
            ]
          }
        }
      )

    assert {:ok, %{"names" => [~c"a.txt"], "info" => info}} = eval(instance, nil)
    assert ["file_info", 3, "regular", "read_write" | _rest] = info
  end

  test "filesystem direct API rejects unsupported boundary terms by role" do
    {:ok, manifest} =
      Hyperlang.Manifest.normalize(
        erlang_public(%{
          filesystem: %{
            enabled: true,
            file_compat: true,
            handle_compat: true,
            mounts: [
              %{
                virtual: "/mem",
                backend: "memory",
                mode: :memory,
                allow: [:read, :write],
                files: [%{path: "/mem/a.txt", content: <<"abc">>}]
              }
            ]
          }
        })
      )

    assert {:ok, filesystem} = Hyperlang.Filesystem.start(manifest.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(filesystem) end)

    port = Port.open({:spawn, "cat"}, [:binary])
    registered = Hyperlang.Filesystem.make_guest_handle(:direct_boundary_test)

    try do
      bad_path_terms = [self(), port, fn -> :ok end, make_ref(), registered, :unknown, [1 | 2]]

      for term <- bad_path_terms do
        assert Hyperlang.Filesystem.read_file(filesystem, term) == {:error, :badarg}
      end

      bad_iodata_terms = [self(), port, fn -> :ok end, make_ref(), registered, :unknown, [1 | 2]]

      for term <- bad_iodata_terms do
        assert Hyperlang.Filesystem.write_file(filesystem, "/mem/out.txt", [term]) ==
                 {:error, :badarg}
      end

      call_id = 123_456
      ctx = %{call_id: call_id}

      assert Hyperlang.Filesystem.begin_eval(filesystem, call_id) == {:ok, :ok}

      assert Hyperlang.Filesystem.dispatch(filesystem, :handle_read, [make_ref(), 1], ctx) ==
               {:ok, {:error, :ebadf}}

      assert Hyperlang.Filesystem.dispatch(filesystem, :handle_read, [port, 1], ctx) ==
               {:ok, {:error, :ebadf}}

      assert Hyperlang.Filesystem.finish_eval(filesystem, call_id, :success) == {:ok, :ok}
    after
      Port.close(port)
      Hyperlang.Filesystem.release_guest_handles(:direct_boundary_test)
    end
  end

  test "data filesystem file operation success values match OTP-compatible shapes" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "hyperlang_otp_file_parity_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp, "work"))

    {:ok, original_cwd} = :file.get_cwd()

    on_exit(fn ->
      :file.set_cwd(original_cwd)
      File.rm_rf!(tmp)
    end)

    otp_work = Path.join(tmp, "work")
    otp_a = Path.join(otp_work, "a.txt")
    otp_b = Path.join(otp_work, "b.txt")
    otp_dir = Path.join(otp_work, "dir")
    otp_modes = Path.join(otp_work, "modes")

    assert :ok = :file.write_file(String.to_charlist(otp_a), <<"one">>)
    assert :ok = :file.write_file(String.to_charlist(otp_a), <<"two">>, [:append])
    assert {:ok, <<"onetwo">>} = :file.read_file(String.to_charlist(otp_a))
    assert :ok = :file.write_file(String.to_charlist(otp_b), <<"fresh">>, [:exclusive])

    assert {:error, :eexist} =
             :file.write_file(String.to_charlist(otp_b), <<"again">>, [:exclusive])

    assert :ok = :file.make_dir(String.to_charlist(otp_dir))
    assert {:ok, otp_names} = :file.list_dir(String.to_charlist(otp_work))
    assert :ok = :file.make_dir(String.to_charlist(otp_modes))

    otp_write_modes = [
      {:write, [:write]},
      {:raw, [:raw]},
      {:binary, [:binary]},
      {:delayed_write, [:delayed_write]},
      {:delayed_write_tuple, [{:delayed_write, 8, 100}]},
      {:read, [:read]},
      {:sync, [:sync]},
      {:read_ahead, [:read_ahead]},
      {:read_ahead_size, [{:read_ahead, 8}]},
      {:write_read, [:write, :read]},
      {:append_exclusive, [:append, :exclusive]}
    ]

    otp_mode_results =
      Enum.map(otp_write_modes, fn {name, modes} ->
        path = Path.join(otp_modes, "#{name}.txt")
        result = :file.write_file(String.to_charlist(path), <<"x">>, modes)
        {name, result, File.read!(path)}
      end)

    assert Enum.all?(otp_mode_results, fn {_name, result, content} ->
             result == :ok and content == "x"
           end)

    assert {:error, :eexist} =
             :file.write_file(
               String.to_charlist(Path.join(otp_modes, "append_exclusive.txt")),
               <<"y">>,
               [:append, :exclusive]
             )

    assert :ok =
             :file.rename(
               String.to_charlist(otp_a),
               String.to_charlist(Path.join(otp_work, "c.txt"))
             )

    assert :ok = :file.delete(String.to_charlist(Path.join(otp_work, "c.txt")))
    assert :ok = :file.del_dir(String.to_charlist(otp_dir))
    assert {:ok, otp_info} = :file.read_file_info(String.to_charlist(otp_b))
    assert {:ok, otp_link_info} = :file.read_link_info(String.to_charlist(otp_b))
    assert {:ok, otp_cwd} = :file.get_cwd()
    assert {:error, :enotsup} = :file.get_cwd(~c"C:")
    assert {:error, :badarg} = :file.get_cwd(<<"C:">>)
    assert :ok = :file.set_cwd(String.to_charlist(otp_work))
    assert {:ok, otp_set_cwd} = :file.get_cwd()
    assert :ok = :file.set_cwd(~c"modes")
    assert {:ok, otp_relative_set_cwd} = :file.get_cwd()
    assert {:error, :enotdir} = :file.set_cwd(String.to_charlist(otp_b))
    assert {:error, :enoent} = :file.set_cwd(String.to_charlist(Path.join(otp_work, "missing")))
    assert :ok = :file.set_cwd(original_cwd)

    source = ~S"""
    ok = file:write_file("/mem/work/a.txt", <<"one">>),
    ok = file:write_file("/mem/work/a.txt", <<"two">>, [append]),
    {ok, <<"onetwo">>} = file:read_file("/mem/work/a.txt"),
    ok = file:write_file("/mem/work/b.txt", <<"fresh">>, [exclusive]),
    {error, eexist} = file:write_file("/mem/work/b.txt", <<"again">>, [exclusive]),
    ok = file:make_dir("/mem/work/dir"),
    {ok, Names0} = file:list_dir("/mem/work"),
    ok = file:make_dir("/mem/work/modes"),
    ok = file:write_file("/mem/work/modes/write.txt", <<"x">>, [write]),
    ok = file:write_file("/mem/work/modes/raw.txt", <<"x">>, [raw]),
    ok = file:write_file("/mem/work/modes/binary.txt", <<"x">>, [binary]),
    ok = file:write_file("/mem/work/modes/delayed_write.txt", <<"x">>, [delayed_write]),
    ok = file:write_file("/mem/work/modes/delayed_write_tuple.txt", <<"x">>, [{delayed_write, 8, 100}]),
    ok = file:write_file("/mem/work/modes/read.txt", <<"x">>, [read]),
    ok = file:write_file("/mem/work/modes/sync.txt", <<"x">>, [sync]),
    ok = file:write_file("/mem/work/modes/read_ahead.txt", <<"x">>, [read_ahead]),
    ok = file:write_file("/mem/work/modes/read_ahead_size.txt", <<"x">>, [{read_ahead, 8}]),
    ok = file:write_file("/mem/work/modes/write_read.txt", <<"x">>, [write, read]),
    ok = file:write_file("/mem/work/modes/append_exclusive.txt", <<"x">>, [append, exclusive]),
    {error, eexist} = file:write_file("/mem/work/modes/append_exclusive.txt", <<"y">>, [append, exclusive]),
    {error, badarg} = file:write_file("/mem/work/modes/unsupported.txt", <<"x">>, [compressed]),
    {error, badarg} = file:write_file("/mem/work/modes/bad_delayed_negative.txt", <<"x">>, [{delayed_write, -1, 10}]),
    {error, badarg} = file:write_file("/mem/work/modes/bad_delayed_missing.txt", <<"x">>, [{delayed_write, 8}]),
    {error, badarg} = file:write_file("/mem/work/modes/bad_delayed_non_integer.txt", <<"x">>, [{delayed_write, <<"8">>, 10}]),
    {error, badarg} = file:write_file("/mem/work/modes/bad_read_ahead_negative.txt", <<"x">>, [{read_ahead, -1}]),
    {error, badarg} = file:write_file("/mem/work/modes/bad_read_ahead_non_integer.txt", <<"x">>, [{read_ahead, <<"8">>}]),
    {error, badarg} = file:write_file("/mem/work/modes/bad_options.txt", <<"x">>, append),
    ModeContents = [
      file:read_file("/mem/work/modes/write.txt"),
      file:read_file("/mem/work/modes/raw.txt"),
      file:read_file("/mem/work/modes/binary.txt"),
      file:read_file("/mem/work/modes/delayed_write.txt"),
      file:read_file("/mem/work/modes/delayed_write_tuple.txt"),
      file:read_file("/mem/work/modes/read.txt"),
      file:read_file("/mem/work/modes/sync.txt"),
      file:read_file("/mem/work/modes/read_ahead.txt"),
      file:read_file("/mem/work/modes/read_ahead_size.txt"),
      file:read_file("/mem/work/modes/write_read.txt"),
      file:read_file("/mem/work/modes/append_exclusive.txt")
    ],
    ok = file:rename("/mem/work/a.txt", "/mem/work/c.txt"),
    ok = file:delete("/mem/work/c.txt"),
    ok = file:del_dir("/mem/work/dir"),
    {ok, Info} = file:read_file_info("/mem/work/b.txt"),
    {ok, LinkInfo} = file:read_link_info("/mem/work/b.txt"),
    {ok, Cwd} = file:get_cwd(),
    {error, enotsup} = file:get_cwd("C:"),
    {error, badarg} = file:get_cwd(<<"C:">>),
    ok = file:set_cwd("/mem/work"),
    {ok, SetCwd} = file:get_cwd(),
    ok = file:set_cwd("modes"),
    {ok, RelativeSetCwd} = file:get_cwd(),
    {error, enotdir} = file:set_cwd("/mem/work/b.txt"),
    {error, enoent} = file:set_cwd("/mem/work/missing"),
    #{<<"names">> => lists:sort(Names0),
      <<"mode_contents">> => ModeContents,
      <<"info">> => Info,
      <<"link_info">> => LinkInfo,
      <<"cwd">> => Cwd,
      <<"set_cwd">> => SetCwd,
      <<"relative_set_cwd">> => RelativeSetCwd}.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          filesystem: %{
            enabled: true,
            file_compat: true,
            allow_relative_paths: true,
            cwd: "/mem",
            mounts: [
              %{
                virtual: "/mem",
                backend: "memory",
                mode: :memory,
                allow: [:read, :write, :delete, :mkdir, :list, :rename, :stat, :lstat],
                dirs: ["/mem/work"]
              }
            ]
          }
        })
      )

    assert {:ok, safe} = eval(instance, :ok)
    assert Map.fetch!(safe, <<"names">>) == Enum.sort(otp_names)
    assert is_list(Map.fetch!(safe, <<"cwd">>))
    assert is_list(otp_cwd)
    assert is_list(otp_set_cwd)
    assert is_list(otp_relative_set_cwd)
    assert String.ends_with?(List.to_string(otp_set_cwd), "/work")
    assert String.ends_with?(List.to_string(otp_relative_set_cwd), "/work/modes")
    assert Map.fetch!(safe, <<"set_cwd">>) == ~c"/mem/work"
    assert Map.fetch!(safe, <<"relative_set_cwd">>) == ~c"/mem/work/modes"
    assert Map.fetch!(safe, <<"mode_contents">>) == List.duplicate({:ok, <<"x">>}, 11)

    assert {:file_info, 5, :regular, :read_write, _, _, _, safe_mode, 1, 0, 0, 0, 0, 0} =
             Map.fetch!(safe, <<"info">>)

    assert {:file_info, 5, :regular, :read_write, _, _, _, safe_link_mode, 1, 0, 0, 0, 0, 0} =
             Map.fetch!(safe, <<"link_info">>)

    assert tuple_size(otp_info) == tuple_size(Map.fetch!(safe, <<"info">>))
    assert tuple_size(otp_link_info) == tuple_size(Map.fetch!(safe, <<"link_info">>))
    assert elem(otp_info, 0) == :file_info
    assert elem(otp_link_info, 0) == :file_info
    assert safe_mode == 0o100644
    assert safe_link_mode == 0o100644
  end

  test "data filesystem file operation errors cover accepted OTP-style reasons" do
    source = ~S"""
    ok = file:write_file("/rw/file.txt", <<"x">>),
    ok = file:make_dir("/rw/dir"),
    ok = file:write_file("/rw/dir/nested.txt", <<"x">>),
    ok = file:make_dir("/rw/parent"),
    ok = file:make_dir("/rw/parent/child"),
    OverlongPath = <<"/rw/", (binary:copy(<<"x">>, 5000))/binary>>,
    #{<<"missing_file">> => file:read_file("/rw/missing.txt"),
      <<"missing_parent">> => file:write_file("/rw/missing/a.txt", <<"x">>),
      <<"no_mount">> => file:read_file("/none/a.txt"),
      <<"existing_path">> => file:write_file("/rw/file.txt", <<"again">>, [exclusive]),
      <<"read_directory">> => file:read_file("/rw/dir"),
      <<"write_directory">> => file:write_file("/rw/dir", <<"x">>),
      <<"delete_directory">> => file:delete("/rw/dir"),
      <<"list_file">> => file:list_dir("/rw/file.txt"),
      <<"del_file">> => file:del_dir("/rw/file.txt"),
      <<"del_nonempty_dir">> => file:del_dir("/rw/dir"),
      <<"readonly_write">> => file:write_file("/ro/new.txt", <<"x">>),
      <<"cross_mount_rename">> => file:rename("/rw/file.txt", "/other/file.txt"),
      <<"overlong_path">> => file:read_file(OverlongPath),
      <<"invalid_path">> => file:read_file(<<"/rw/", 0, "bad">>),
      <<"descendant_rename">> => file:rename("/rw/parent", "/rw/parent/child/grand")}.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          filesystem: %{
            enabled: true,
            file_compat: true,
            mounts: [
              %{
                virtual: "/rw",
                backend: "memory",
                mode: :memory,
                allow: [:read, :write, :delete, :mkdir, :list, :rename, :stat]
              },
              %{
                virtual: "/ro",
                backend: "memory",
                mode: :read_only,
                allow: [:read, :write, :list, :stat],
                files: [%{path: "/ro/existing.txt", content: <<"ro">>}]
              },
              %{
                virtual: "/other",
                backend: "memory",
                mode: :memory,
                allow: [:read, :write, :delete, :mkdir, :list, :rename, :stat]
              }
            ]
          }
        })
      )

    assert {:ok, errors} = eval(instance, :ok)
    assert Map.fetch!(errors, <<"missing_file">>) == {:error, :enoent}
    assert Map.fetch!(errors, <<"missing_parent">>) == {:error, :enoent}
    assert Map.fetch!(errors, <<"no_mount">>) == {:error, :eacces}
    assert Map.fetch!(errors, <<"existing_path">>) == {:error, :eexist}
    assert Map.fetch!(errors, <<"read_directory">>) == {:error, :eisdir}
    assert Map.fetch!(errors, <<"write_directory">>) == {:error, :eisdir}
    assert Map.fetch!(errors, <<"delete_directory">>) == {:error, :eisdir}
    assert Map.fetch!(errors, <<"list_file">>) == {:error, :enotdir}
    assert Map.fetch!(errors, <<"del_file">>) == {:error, :enotdir}
    assert Map.fetch!(errors, <<"del_nonempty_dir">>) == {:error, :enotempty}
    assert Map.fetch!(errors, <<"readonly_write">>) == {:error, :erofs}
    assert Map.fetch!(errors, <<"cross_mount_rename">>) == {:error, :exdev}
    assert Map.fetch!(errors, <<"overlong_path">>) == {:error, :enametoolong}
    assert Map.fetch!(errors, <<"invalid_path">>) == {:error, :invalid_path}
    assert Map.fetch!(errors, <<"descendant_rename">>) == {:error, :einval}
  end

  test "filesystem file_info metadata is virtualized for files dirs symlinks and failures" do
    source = ~S"""
    ok = file:make_dir("/mem/dir"),
    {ok, FileInfo} = file:read_file_info("/mem/a.txt"),
    {ok, DirInfo} = file:read_file_info("/mem/dir"),
    {ok, FollowedLinkInfo} = file:read_file_info("/mem/link"),
    {ok, LinkInfo} = file:read_link_info("/mem/link"),
    #{<<"file">> => FileInfo,
      <<"dir">> => DirInfo,
      <<"followed_link">> => FollowedLinkInfo,
      <<"link">> => LinkInfo,
      <<"missing">> => file:read_file_info("/mem/missing.txt"),
      <<"missing_link">> => file:read_link_info("/mem/missing-link.txt"),
      <<"denied">> => file:read_file_info("/hidden/secret.txt"),
      <<"denied_link">> => file:read_link_info("/hidden/secret.txt")}.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          filesystem: %{
            enabled: true,
            file_compat: true,
            mounts: [
              %{
                virtual: "/mem",
                backend: "memory",
                mode: :memory,
                allow: [:read, :write, :mkdir, :stat, :lstat],
                files: [%{path: "/mem/a.txt", content: <<"abc">>}],
                symlinks: [%{path: "/mem/link", target: "/mem/a.txt"}]
              },
              %{
                virtual: "/hidden",
                backend: "memory",
                mode: :memory,
                allow: [:read],
                files: [%{path: "/hidden/secret.txt", content: <<"secret">>}]
              }
            ]
          }
        })
      )

    assert {:ok,
            %{
              <<"file">> => file_info,
              <<"dir">> => dir_info,
              <<"followed_link">> => followed_link_info,
              <<"link">> => link_info,
              <<"missing">> => {:error, :enoent},
              <<"missing_link">> => {:error, :enoent},
              <<"denied">> => {:error, :eacces},
              <<"denied_link">> => {:error, :eacces}
            }} = eval(instance, :ok)

    epoch = {{1970, 1, 1}, {0, 0, 0}}

    assert {:file_info, 3, :regular, :read_write, ^epoch, ^epoch, ^epoch, file_mode, 1, 0, 0, 0,
            0, 0} = file_info

    assert Bitwise.band(file_mode, 0o100000) == 0o100000

    assert followed_link_info == file_info

    assert {:file_info, 0, :directory, :read_write, ^epoch, ^epoch, ^epoch, dir_mode, 1, 0, 0, 0,
            0, 0} = dir_info

    assert Bitwise.band(dir_mode, 0o040000) == 0o040000

    assert {:file_info, 10, :symlink, :read_write, ^epoch, ^epoch, ^epoch, link_mode, 1, 0, 0, 0,
            0, 0} = link_info

    assert Bitwise.band(link_mode, 0o120000) == 0o120000
    assert Bitwise.band(link_mode, 0o777) == 0o777
  end

  test "host file_info metadata does not leak host uid gid inode device or timestamps" do
    root =
      Path.join(
        System.tmp_dir!(),
        "hyperlang_host_metadata_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    file_path = Path.join(root, "a.txt")
    link_path = Path.join(root, "link")

    File.write!(file_path, "abc")

    case File.ln_s("a.txt", link_path) do
      :ok -> :ok
      {:error, reason} -> flunk("host symlink setup failed: #{inspect(reason)}")
    end

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, host_stat} = File.stat(file_path)

    source = ~S"""
    #{<<"file">> => file:read_file_info("/host/a.txt"),
      <<"followed_link">> => file:read_file_info("/host/link"),
      <<"link">> => file:read_link_info("/host/link")}.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          filesystem: %{
            enabled: true,
            file_compat: true,
            mounts: [
              %{
                virtual: "/host",
                backend: {:host, root},
                mode: :read_only,
                allow: [:stat, :lstat]
              }
            ]
          }
        })
      )

    assert {:ok,
            %{
              <<"file">> => {:ok, safe_info},
              <<"followed_link">> => {:ok, followed_link_info},
              <<"link">> => {:ok, link_info}
            }} = eval(instance, :ok)

    epoch = {{1970, 1, 1}, {0, 0, 0}}

    assert {:file_info, 3, :regular, :read_write, ^epoch, ^epoch, ^epoch, _mode, 1, 0, 0, 0, 0, 0} =
             safe_info

    assert {:file_info, 3, :regular, :read_write, ^epoch, ^epoch, ^epoch, followed_link_mode, 1,
            0, 0, 0, 0, 0} = followed_link_info

    assert {:file_info, _link_size, :symlink, :read_write, ^epoch, ^epoch, ^epoch, link_mode, 1,
            0, 0, 0, 0, 0} = link_info

    assert Bitwise.band(followed_link_mode, 0o100000) == 0o100000
    assert Bitwise.band(link_mode, 0o120000) == 0o120000
    refute elem(safe_info, 4) == host_stat.atime
    refute elem(safe_info, 5) == host_stat.mtime
    refute elem(safe_info, 6) == host_stat.ctime
  end

  test "host file_info rejects unsupported special file types as virtual errors" do
    unless File.exists?("/dev/null") do
      flunk("/dev/null is required for host special file metadata coverage")
    end

    source = ~S"""
    #{<<"stat">> => file:read_file_info("/dev/null"),
      <<"lstat">> => file:read_link_info("/dev/null")}.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          filesystem: %{
            enabled: true,
            file_compat: true,
            mounts: [
              %{
                virtual: "/dev",
                backend: {:host, "/dev"},
                mode: :read_only,
                allow: [:stat, :lstat]
              }
            ]
          }
        })
      )

    assert {:ok, %{<<"stat">> => {:error, :eacces}, <<"lstat">> => {:error, :eacces}}} =
             eval(instance, :ok)
  end

  test "filesystem diagnostics distinguish resolver authority and quota failures" do
    host_dir =
      Path.join(
        System.tmp_dir!(),
        "hyperlang_unsupported_mount_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(host_dir)
    on_exit(fn -> File.rm_rf(host_dir) end)

    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/ro",
                     backend: "memory",
                     mode: :memory,
                     allow: [:read],
                     files: [%{path: "/ro/a.txt", content: <<"a">>}]
                   },
                   %{
                     virtual: "/quota",
                     backend: "memory",
                     mode: :memory,
                     allow: [:read, :write],
                     limits: %{max_single_write_bytes: 1}
                   },
                   %{
                     virtual: "/readonly",
                     backend: "memory",
                     mode: :read_only,
                     allow: [:read, :write]
                   },
                   %{
                     virtual: "/host",
                     backend: {:host, host_dir},
                     mode: :read_write,
                     allow: [:write]
                   }
                 ]
               }
             })

    assert {:error, unsupported} =
             Hyperlang.Filesystem.resolve_operation(manifest.filesystem, "/ro/a.txt", :unknown_op)

    assert unsupported.category == :filesystem
    assert unsupported.message =~ "unsupported filesystem resolver operation"
    assert unsupported.details.operation == :unknown_op

    assert {:error, no_mount} = Hyperlang.Filesystem.resolve_mount(manifest.filesystem, "/none/a")
    assert no_mount.category == :filesystem
    assert no_mount.message =~ "no matching filesystem mount"
    assert no_mount.details.path == "/none/a"

    assert {:error, invalid_path} =
             Hyperlang.Filesystem.resolve_mount(manifest.filesystem, <<"/ro/", 0, "bad">>)

    assert invalid_path.category == :filesystem
    assert invalid_path.message =~ "null byte"
    refute invalid_path.message =~ "no matching filesystem mount"

    assert {:error, denied} =
             Hyperlang.Filesystem.authorize_data_operation(
               manifest.filesystem,
               "/ro/a.txt",
               :write
             )

    assert denied.category == :filesystem
    assert denied.message =~ "permission denied"
    assert denied.details.reason == :eacces
    assert denied.details.virtual == "/ro"

    assert {:ok, handle} = Hyperlang.Filesystem.start(manifest.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    assert Hyperlang.Filesystem.write_file(handle, "/quota/a.txt", <<"xx">>) == {:error, :enospc}

    assert Hyperlang.Filesystem.write_file(handle, "/readonly/a.txt", <<"x">>) ==
             {:error, :erofs}

    assert Hyperlang.Filesystem.write_file(handle, "/host/a.txt", <<"x">>) == {:error, :enotsup}
    assert Hyperlang.Filesystem.read_file(handle, "/none/a.txt") == {:error, :eacces}
    assert Hyperlang.Filesystem.read_file(handle, <<"/ro/", 0, "bad">>) == {:error, :invalid_path}

    quota = Hyperlang.Filesystem.reason_diagnostic(:enospc)
    assert quota.category == :filesystem
    assert quota.details.kind == :quota_failure
    assert quota.details.reason == :enospc
    refute inspect(quota) =~ host_dir

    unsupported_mount = Hyperlang.Filesystem.reason_diagnostic(:enotsup)
    assert unsupported_mount.details.kind == :unsupported_mount_operation
    assert unsupported_mount.details.reason == :enotsup

    read_only = Hyperlang.Filesystem.reason_diagnostic(:erofs)
    assert read_only.details.kind == :read_only_mount

    non_empty = Hyperlang.Filesystem.reason_diagnostic(:enotempty)
    assert non_empty.details.kind == :non_empty_directory
  end

  test "filesystem host failures are virtualized without host path details" do
    host_dir =
      Path.join(
        System.tmp_dir!(),
        "hyperlang_SECRET_HOST_PATH_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(host_dir)
    File.write!(Path.join(host_dir, "a.txt"), "a")

    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/host",
                     backend: {:host, host_dir},
                     mode: :read_only,
                     allow: [:read, :list, :stat]
                   }
                 ]
               }
             })

    assert {:ok, handle} = Hyperlang.Filesystem.start(manifest.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)
    File.rm_rf!(host_dir)

    result = %{
      read: Hyperlang.Filesystem.read_file(handle, "/host/a.txt"),
      list: Hyperlang.Filesystem.list_dir(handle, "/host"),
      stat: Hyperlang.Filesystem.stat(handle, "/host/a.txt")
    }

    assert result.read == {:error, :enoent}
    assert result.list == {:error, :enoent}
    assert result.stat == {:error, :enoent}
    refute inspect(result) =~ host_dir
    refute inspect(result) =~ "SECRET_HOST_PATH"
  end

  test "filesystem host exceptions are trimmed to virtualized errors" do
    secret = "SECRET_HOST_EXCEPTION_#{System.unique_integer([:positive])}"

    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               filesystem: %{
                 mounts: [
                   %{
                     virtual: "/host",
                     backend: {:host, System.tmp_dir!()},
                     mode: :read_only,
                     allow: [:read]
                   }
                 ]
               }
             })

    [mount] = manifest.filesystem.mounts
    broken_mount = %{mount | backend: {:host, {:not_a_path, secret}}}
    filesystem = %{manifest.filesystem | mounts: [broken_mount]}

    assert {:ok, handle} = Hyperlang.Filesystem.start(filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    result = Hyperlang.Filesystem.read_file(handle, "/host/a.txt")
    assert result == {:error, :eacces}

    assert {:ok, %{open_handle_count: 0, pending_request_count: 0, pid_visible_to_guest: false}} =
             Hyperlang.Filesystem.server_info(handle)

    refute inspect(result) =~ secret
    refute inspect(result) =~ "not_a_path"
  end

  test "filelib predicates match OTP behavior over virtual files and denied mounts" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "hyperlang_filelib_predicate_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp, "dir"))
    File.write!(Path.join(tmp, "file.txt"), "x")
    on_exit(fn -> File.rm_rf!(tmp) end)

    otp =
      for {label, path} <- [
            file: Path.join(tmp, "file.txt"),
            dir: Path.join(tmp, "dir"),
            missing: Path.join(tmp, "missing")
          ],
          into: %{} do
        {
          Atom.to_string(label),
          %{
            is_file: :filelib.is_file(String.to_charlist(path)),
            is_dir: :filelib.is_dir(String.to_charlist(path))
          }
        }
      end

    source = ~S"""
    #{<<"file">> => #{<<"is_file">> => filelib:is_file("/mem/file.txt"),
                      <<"is_dir">> => filelib:is_dir("/mem/file.txt")},
      <<"dir">> => #{<<"is_file">> => filelib:is_file("/mem/dir"),
                     <<"is_dir">> => filelib:is_dir("/mem/dir")},
      <<"missing">> => #{<<"is_file">> => filelib:is_file("/mem/missing"),
                         <<"is_dir">> => filelib:is_dir("/mem/missing")},
      <<"denied">> => #{<<"is_file">> => filelib:is_file("/hidden/secret.txt"),
                        <<"is_dir">> => filelib:is_dir("/hidden/secret.txt")}}.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          filesystem: %{
            enabled: true,
            filelib_compat: true,
            mounts: [
              %{
                virtual: "/mem",
                backend: "memory",
                mode: :memory,
                allow: [:stat],
                dirs: ["/mem/dir"],
                files: [%{path: "/mem/file.txt", content: <<"x">>}]
              },
              %{
                virtual: "/hidden",
                backend: "memory",
                mode: :memory,
                allow: [],
                files: [%{path: "/hidden/secret.txt", content: <<"secret">>}]
              }
            ]
          }
        })
      )

    assert {:ok, safe} = eval(instance, :ok)

    assert safe[<<"file">>] == %{
             <<"is_file">> => otp["file"].is_file,
             <<"is_dir">> => otp["file"].is_dir
           }

    assert safe[<<"dir">>] == %{
             <<"is_file">> => otp["dir"].is_file,
             <<"is_dir">> => otp["dir"].is_dir
           }

    assert safe[<<"missing">>] == %{
             <<"is_file">> => otp["missing"].is_file,
             <<"is_dir">> => otp["missing"].is_dir
           }

    assert safe[<<"denied">>] == %{<<"is_file">> => false, <<"is_dir">> => false}
  end

  test "filelib ensure_dir creates recursive parents with OTP-shaped results" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "hyperlang_filelib_ensure_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "file.txt"), "x")
    on_exit(fn -> File.rm_rf!(tmp) end)

    assert :ok = :filelib.ensure_dir(String.to_charlist(Path.join(tmp, "a/b.txt")))
    assert File.dir?(Path.join(tmp, "a"))
    assert :ok = :filelib.ensure_dir(String.to_charlist(Path.join(tmp, "a/b/c.txt")))
    assert File.dir?(Path.join(tmp, "a/b"))

    assert {:error, :eexist} =
             :filelib.ensure_dir(String.to_charlist(Path.join(tmp, "file.txt/child.txt")))

    source = ~S"""
    ok = filelib:ensure_dir("/mem/a/b.txt"),
    true = filelib:is_dir("/mem/a"),
    ok = filelib:ensure_dir("/mem/a/b/c.txt"),
    true = filelib:is_dir("/mem/a/b"),
    ok = filelib:ensure_dir("/mem/a/b/"),
    {error, eexist} = filelib:ensure_dir("/mem/file.txt/child.txt"),
    #{<<"a">> => filelib:is_dir("/mem/a"),
      <<"b">> => filelib:is_dir("/mem/a/b"),
      <<"file_child">> => filelib:is_file("/mem/file.txt/child.txt")}.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          filesystem: %{
            enabled: true,
            filelib_compat: true,
            allow_relative_paths: true,
            mounts: [
              %{
                virtual: "/mem",
                backend: "memory",
                mode: :memory,
                allow: [:stat, :mkdir],
                files: [%{path: "/mem/file.txt", content: <<"x">>}]
              }
            ]
          }
        })
      )

    assert eval(instance, :ok) ==
             {:ok, %{<<"a">> => true, <<"b">> => true, <<"file_child">> => false}}
  end

  test "filelib ensure_dir rejects escaping symlink ancestors" do
    source = ~S"""
    #{<<"escape">> => filelib:ensure_dir("/mem/link/child.txt"),
      <<"link_is_file">> => filelib:is_file("/mem/link"),
      <<"link_is_dir">> => filelib:is_dir("/mem/link")}.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          filesystem: %{
            enabled: true,
            filelib_compat: true,
            mounts: [
              %{
                virtual: "/mem",
                backend: "memory",
                mode: :memory,
                allow: [:stat, :mkdir],
                symlinks: [
                  %{path: "/mem/link", target: "/outside", escape: true}
                ]
              }
            ]
          }
        })
      )

    assert eval(instance, :ok) ==
             {:ok,
              %{
                <<"escape">> => {:error, :eacces},
                <<"link_is_file">> => false,
                <<"link_is_dir">> => false
              }}
  end

  test "supports Erlang-style local bindings and pattern matching" do
    source = ~S"""
    result(#{<<"x">> := X}) ->
      Y = X + 1,
      {ok, Y}.
    """

    {_program, instance} =
      compile_and_instance(source, erlang_public(%{terms: %{allowed_atoms: [:ok]}}))

    assert eval(instance, %{<<"x">> => 6}) == {:ok, {:ok, 7}}
  end

  test "supports Erlang exact map update syntax" do
    source = ~S"""
    result(Input) ->
      Input#{<<"count">> := maps:get(<<"count">>, Input) + 1}.
    """

    {_program, instance} = compile_and_instance(source, erlang_public())

    assert eval(instance, %{<<"count">> => 2, <<"name">> => <<"Ada">>}) ==
             {:ok, %{<<"count">> => 3, <<"name">> => <<"Ada">>}}

    assert_eval_error(eval(instance, %{<<"name">> => <<"Ada">>}), :runtime)
  end

  test "supports Erlang assoc map update syntax with dynamic keys" do
    source = ~S"""
    pick(Keys, Map) ->
        pick(Keys, Map, #{}).

    pick([], Map, Acc) ->
        Size = maps:size(Map),
        case Size >= 0 of
            true -> Acc;
            false -> Acc
        end;
    pick([K | Rest], Map, Acc) ->
        case maps:find(K, Map) of
            {ok, V} -> pick(Rest, Map, Acc#{K => V});
            error -> pick(Rest, Map, Acc)
        end.

    result(_) ->
        pick([<<"session_id">>, <<"branch_id">>, <<"missing">>], #{
          <<"session_id">> => <<"session_1">>,
          <<"branch_id">> => <<"root">>
        }).
    """

    {_program, instance} = compile_and_instance(source, erlang_public())

    assert eval(instance, nil) ==
             {:ok, %{"session_id" => "session_1", "branch_id" => "root"}}
  end

  test "codemode orchestration shape supports assoc map updates" do
    source = ~S"""
    -module(codemode_program).

    shorten(Bin, Max) ->
        case byte_size(Bin) =< Max of
            true -> Bin;
            false ->
                PrefixLen = Max - 3,
                <<Prefix:PrefixLen/binary, Rest/binary>> = Bin,
                RestSize = byte_size(Rest),
                case RestSize >= 0 of
                    true -> <<Prefix/binary, "...">>;
                    false -> Bin
                end
        end.

    pick(Keys, Map) ->
        pick(Keys, Map, #{}).

    pick([], Map, Acc) ->
        Size = maps:size(Map),
        case Size >= 0 of
            true -> Acc;
            false -> Acc
        end;
    pick([K | Rest], Map, Acc) ->
        case maps:find(K, Map) of
            {ok, V} -> pick(Rest, Map, Acc#{K => V});
            error -> pick(Rest, Map, Acc)
        end.

    result(Input) ->
        InputSize = byte_size(Input),
        case InputSize >= 0 of
            true -> ok;
            false -> ok
        end,
        Session = tools:create_session(#{
            <<"input">> => #{
                <<"name">> => <<"codemode-demo-neon-orchestrator">>,
                <<"model">> => <<"google:gemini-2.5-flash">>,
                <<"thinking_level">> => <<"off">>,
                <<"system_prompt">> => <<"You are concise.">>
            }
        }),

        SessionId = maps:get(<<"session_id">>, Session),
        BranchId = maps:get(<<"branch_id">>, Session),

        Submit = tools:submit_session_input(#{
            <<"input">> => #{
                <<"session_id">> => SessionId,
                <<"branch_id">> => BranchId,
                <<"input_kind">> => <<"message">>,
                <<"text">> => <<"Describe Hyperlang orchestration briefly.">>,
                <<"wake_runtime">> => true
            }
        }),

        TurnId = maps:get(<<"turn_id">>, Submit),

        Wait = tools:wait_for(#{
            <<"input">> => #{
                <<"target">> => #{
                    <<"kind">> => <<"turn">>,
                    <<"session_id">> => SessionId,
                    <<"branch_id">> => BranchId,
                    <<"turn_id">> => TurnId
                },
                <<"result">> => <<"last_agent_message">>,
                <<"timeout_ms">> => 30000
            }
        }),

        Result0 = maps:get(<<"result">>, Wait, nil),
        Result =
            case Result0 of
                B when is_binary(B) -> shorten(B, 24);
                Other -> Other
            end,

        #{
            <<"session">> => pick([<<"session_id">>, <<"branch_id">>, <<"model">>, <<"thinking_level">>], Session),
            <<"turn">> => pick([<<"turn_id">>, <<"turn_seq">>, <<"input_seq">>], Submit),
            <<"wait_status">> => maps:get(<<"status">>, Wait),
            <<"agent_reply">> => Result
        }.
    """

    manifest =
      erlang_public(%{})

    imports = %{
      "tools" => %{
        create_session: fn %{<<"input">> => input} ->
          %{
            <<"session_id">> => <<"session_1">>,
            <<"branch_id">> => <<"root">>,
            <<"model">> => input[<<"model">>],
            <<"thinking_level">> => input[<<"thinking_level">>]
          }
        end,
        submit_session_input: fn %{<<"input">> => input} ->
          %{
            <<"turn_id">> => <<"turn_1">>,
            <<"turn_seq">> => 4,
            <<"input_seq">> => 3,
            <<"branch_id">> => input[<<"branch_id">>]
          }
        end,
        wait_for: fn %{<<"input">> => _input} ->
          %{
            <<"status">> => <<"done">>,
            <<"result">> =>
              <<"Erlang coordinates agent turns through a small bright switchboard.">>
          }
        end
      }
    }

    {_program, instance} = compile_and_instance(source, manifest, imports)

    assert {:ok, result} = eval(instance, <<"input">>)

    assert result["session"] == %{
             "session_id" => "session_1",
             "branch_id" => "root",
             "model" => "google:gemini-2.5-flash",
             "thinking_level" => "off"
           }

    assert result["turn"] == %{"turn_id" => "turn_1", "turn_seq" => 4, "input_seq" => 3}
    assert result["wait_status"] == "done"
    assert result["agent_reply"] == "Erlang coordinates ag..."
  end

  test "supports bound import results in normal Erlang-shaped bodies" do
    manifest =
      erlang_public(%{
        terms: %{allowed_atoms: [:price]}
      })

    source = ~S"""
    result(Item) ->
      Price = kv:get({price, Item}),
      Tax = Price div 10,
      #{price => Price + Tax}.
    """

    imports = %{
      "kv" => %{
        get: fn {:price, _item} -> 100 end
      }
    }

    {_program, instance} = compile_and_instance(source, manifest, imports)

    assert eval(instance, <<"book">>) == {:ok, %{price: 110}}
  end

  test "module-less helpers are still accepted as a wrapped source module" do
    source = """
    result(Input) -> helper(Input).
    helper(Input) -> Input + 3.
    """

    {program, instance} = compile_and_instance(source, erlang_public())
    assert eval(instance, 4) == {:ok, 7}

    assert Map.from_struct(program).metadata.source_contract == %{
             module_form: false,
             synthetic_module: true
           }
  end

  test "declared host imports are callable and undeclared modules are not" do
    load_test_kv_module()
    assert :erlang.function_exported(:kv, :get, 1)
    assert apply(:kv, :get, [<<"price">>]) == {:ambient, <<"price">>}

    manifest = erlang_public(%{})
    source = "result(Input) -> kv:get(Input)."
    tenant = "tenant"
    imports = %{"kv" => %{get: fn key -> {"kv", key, tenant} end}}

    {_program, instance} = compile_and_instance(source, manifest, imports)
    assert eval(instance, <<"price">>) == {:ok, {"kv", <<"price">>, "tenant"}}

    assert {:error, [%{category: :verify}]} = Hyperlang.Test.program("kv:get(1).", %{})

    assert {:error, [%{category: :verify}]} =
             Hyperlang.Test.program("kv:put(1, 2).", %{})
  end

  test "import dispatch sanitizes args, applies stricter limits, and trims host failures" do
    parent = self()

    manifest =
      erlang_public(%{})

    source = """
    result(Input) ->
      case Input of
        <<"raise">> -> bad:raise();
        <<"throw">> -> bad:throw();
        <<"slow">> -> slow:wait();
        _ -> log:emit(Input)
      end.
    """

    imports = %{
      "log" => %{
        emit:
          {fn msg ->
             send(parent, {:import_called, msg})
             :ok
           end, limits: %{max_binary_bytes: 4, max_list_length: 2, max_term_depth: 2}}
      },
      "bad" => %{
        raise: fn -> raise "host boom with a much longer stack" end,
        throw: fn -> throw({self(), make_ref(), fn -> :ok end}) end
      },
      "slow" => %{
        wait: fn ->
          Process.sleep(100)
          :ok
        end
      }
    }

    {_program, instance} =
      compile_and_instance(source, manifest, imports, %{limits: %{wall_ms: 500}})

    assert eval(instance, <<"ok">>) == {:ok, :ok}
    assert_receive {:import_called, <<"ok">>}

    error = eval(instance, <<"toolong">>) |> assert_eval_error(:import)
    assert error_reason(error) == "import_error"
    assert inspect(error.details) =~ "binary_bytes"
    refute_receive {:import_called, <<"toolong">>}, 20

    assert_eval_error(eval(instance, self()), :input)
    refute_receive {:import_called, _}, 20

    error = eval(instance, <<"raise">>) |> assert_eval_error(:import)
    assert error_reason(error) == "import_error"
    assert get_in(error, [:details, "error", "exception"]) == "import_exception"

    assert get_in(error, [:details, "error", "message"]) ==
             "host boom with a much longer stack"

    refute inspect(error) =~ "RuntimeError"
    assert get_in(error, [:details, "error", "reason"]) == "raised"

    error = eval(instance, <<"throw">>) |> assert_eval_error(:import)
    inspected = inspect(error)
    refute inspected =~ "#PID"
    refute inspected =~ "#Reference"
    refute inspected =~ "#Function"
    assert get_in(error, [:details, "error", "exception"]) == "import_exception"
    assert get_in(error, [:details, "error", "reason"]) == "caught"

    {_program, slow_instance} =
      compile_and_instance(source, manifest, imports, %{limits: %{wall_ms: 20}})

    assert {:error, error} = eval(slow_instance, <<"slow">>)
    assert error_category(error) in [:timeout, :sandbox_crash]
  end

  test "binding state carries host scope and export options carry limits and nondeterminism" do
    parent = self()

    manifest =
      erlang_public(%{
        capabilities: [:nondeterminism],
        terms: %{allowed_atoms: [:ok]}
      })

    source = """
    result(Key) ->
      Value = kv:get(Key),
      ok = log:emit(Value),
      {Value, clock:now_ms()}.
    """

    scope = "tenant-17"

    imports = %{
      "kv" => %{get: fn key -> {scope, key} end},
      "log" => %{
        emit:
          {fn msg ->
             send(parent, {:hyperlang_log, msg})
             :ok
           end, limits: %{max_binary_bytes: 32}}
      },
      "clock" => %{now_ms: {fn -> 123_456 end, nondeterministic: true}}
    }

    {_program, instance} = compile_and_instance(source, manifest, imports)

    assert eval(instance, <<"price">>) == {:ok, {{"tenant-17", <<"price">>}, 123_456}}
    assert_receive {:hyperlang_log, {"tenant-17", <<"price">>}}

    too_long = String.duplicate("x", 40)
    error = eval(instance, too_long) |> assert_eval_error(:import)
    assert inspect(error.details) =~ "binary_bytes"
    refute_receive {:hyperlang_log, _}, 20
  end

  test "a dependency-tracking host profile is ordinary bindings over host state" do
    parent = self()

    manifest = erlang_public(%{})

    source = """
    result(Path) ->
      {
        world:get(Path),
        world:len(Path),
        lists:sort(world:keys(Path)),
        lists:sort(world:items(Path))
      }.
    """

    world = %{
      <<"catalog">> => %{<<"count">> => 2, <<"title">> => <<"Catalog">>}
    }

    scope = "doc:/shop"
    read = fn path, kind -> send(parent, {:world_read, {scope, path}, kind}) end

    imports = %{
      "world" => %{
        get: fn path ->
          read.(path, :exact)
          Map.fetch!(world, path)
        end,
        len: fn path ->
          read.(path, :exact)
          map_size(Map.fetch!(world, path))
        end,
        keys: fn path ->
          read.(path, :subtree)
          Map.keys(Map.fetch!(world, path))
        end,
        items: fn path ->
          read.(path, :subtree)
          Map.to_list(Map.fetch!(world, path))
        end
      }
    }

    {_program, instance} = compile_and_instance(source, manifest, imports)

    assert eval(instance, <<"catalog">>) ==
             {:ok,
              {
                %{<<"count">> => 2, <<"title">> => <<"Catalog">>},
                2,
                [<<"count">>, <<"title">>],
                [{<<"count">>, 2}, {<<"title">>, <<"Catalog">>}]
              }}

    assert_receive {:world_read, {"doc:/shop", <<"catalog">>}, :exact}
    assert_receive {:world_read, {"doc:/shop", <<"catalog">>}, :exact}
    assert_receive {:world_read, {"doc:/shop", <<"catalog">>}, :subtree}
    assert_receive {:world_read, {"doc:/shop", <<"catalog">>}, :subtree}

    assert {:error, [%{category: :verify}]} =
             Hyperlang.Test.program("world:mutate(Input).", Map.put(manifest, :bindings, imports))
  end

  test "executes an application binding profile with limits" do
    parent = self()

    manifest =
      erlang_public(%{
        terms: %{allowed_atoms: [:ok]}
      })

    source = """
    result(Item) ->
      Price = catalog:price(Item),
      Discounted =
        case flags:enabled(<<"discount">>) of
          true -> Price - 10;
          false -> Price
        end,
      ok = audit:record({Item, Discounted}),
      Discounted.
    """

    scope = "billing"

    imports = %{
      "catalog" => %{price: fn <<"sku-1">> -> 42 end},
      "flags" => %{enabled: fn <<"discount">> -> true end},
      "audit" => %{
        record:
          {fn entry ->
             send(parent, {:audit_recorded, scope, entry})
             :ok
           end, limits: %{max_binary_bytes: 64}}
      }
    }

    {_program, instance} = compile_and_instance(source, manifest, imports)

    assert eval(instance, <<"sku-1">>) == {:ok, 32}
    assert_receive {:audit_recorded, "billing", {<<"sku-1">>, 32}}
  end

  test "rejects process, ambient authority, and dynamic dispatch calls" do
    for source <- [
          "self().",
          "spawn_opt(fun() -> 1 end, []).",
          "process_flag(priority, true).",
          "process_info(Input).",
          "group_leader().",
          "fun erlang:halt/0.",
          "fun M:F/0.",
          "erlang:halt().",
          "erlang:open_port({spawn, <<\"sh\">>}, []).",
          "erlang:load_nif(<<\"x\">>, 0).",
          "erlang:system_flag(schedulers_online, 1).",
          "erlang:apply(foo, bar, []).",
          "erlang:binary_to_term(<<131,100,0,3,102,111,111>>).",
          "code:which(foo).",
          "os:cmd(<<\"whoami\">>).",
          "file:read_file(<<\"x\">>).",
          "file_server:read_file(<<\"x\">>).",
          "prim_file:read_file(<<\"x\">>).",
          "gen_tcp:connect(<<\"localhost\">>, 80, []).",
          "gen_udp:open(0).",
          "ssl:connect(<<\"localhost\">>, 443, []).",
          "inet:getaddr(<<\"localhost\">>, inet).",
          "ets:new(name, []).",
          "dets:open_file(name, []).",
          "mnesia:system_info(tables).",
          "persistent_term:get(key).",
          "rpc:call(node(), erlang, system_info, [version]).",
          "net_kernel:connect_node(node()).",
          "global:whereis_name(name).",
          "pg:get_members(group).",
          "apply(foo, bar, []).",
          "apply(fun() -> 1 end, []).",
          "M:F()."
        ] do
      assert {:error, [%{category: category} | _]} = Hyperlang.Test.program(source, %{}),
             source

      assert category in [:parse, :verify]
    end

    for source <- [
          "receive X -> X end.",
          "Input ! ok.",
          "spawn(fun() -> 1 end).",
          "spawn_link(fun() -> 1 end).",
          "link(Input).",
          "unlink(Input).",
          "process_flag(trap_exit, true)."
        ] do
      assert {:ok, _program} = Hyperlang.Test.program(source, %{}), source
    end
  end

  test "rejects module_info and generated module calls" do
    for source <- [
          "module_info().",
          "erlang:module_info().",
          "hyperlang_slot_000001:module_info().",
          "'hyperlang_slot_000001':'$safe_entry'(1, 2, 3).",
          "some_module:some_function(1)."
        ] do
      assert {:error, [%{category: category} | _]} = Hyperlang.Test.program(source, %{}),
             source

      assert category in [:parse, :verify]
    end
  end

  test "classifies local, import, stdlib, and dynamic calls before code generation" do
    manifest = %{bindings: %{"kv" => %{get: fn input -> input end}}}

    source = """
    result(Input) ->
      helper(Input) + kv:get(Input) + abs(-1) + math:floor(1.5).
    helper(X) -> X.
    """

    assert {:ok, program} = Hyperlang.Test.program(source, manifest)
    info = Map.from_struct(program)
    assert info.metadata.helper_count == 2

    for source <- [
          "result(Input) -> unknown(Input).",
          "result(Input) -> unknown_module:call(Input).",
          "result(Input) -> M:F(Input)."
        ] do
      assert {:error, [%{category: :verify}]} = Hyperlang.Test.program(source, %{})
    end
  end

  test "rejects source attributes and generated-form verifier rejects ambient calls" do
    for source <- [
          "-compile(export_all). result(Input) -> Input.",
          "-compile({parse_transform, hostile_transform}). result(Input) -> Input.",
          "-import(lists, [map/2]). result(Input) -> Input.",
          "-on_load(init/0). result(Input) -> Input.",
          "-include_lib(\"kernel/include/file.hrl\"). result(Input) -> Input."
        ] do
      assert {:error, [%{category: category} | _]} = Hyperlang.Test.program(source, %{}),
             source

      assert category in [:parse, :verify]
    end

    forms = [
      {:attribute, 0, :module, :hyperlang_pending_slot},
      {:attribute, 0, :export,
       [
         {:"$safe_entry", 3},
         {:"$safe_export", 4},
         {:"$safe_raw_export", 3}
       ]},
      {:function, 0, :"$safe_entry", 3,
       [
         {:clause, 0, [{:var, 0, :token}, {:var, 0, :input}, {:var, 0, :runtime}], [],
          [
            {:call, 0, {:remote, 0, {:atom, 0, :os}, {:atom, 0, :cmd}},
             [{:string, 0, ~c"whoami"}]}
          ]}
       ]}
    ]

    assert {:error, %{category: :generated_form_verify}} =
             Hyperlang.Codegen.verify_generated_forms(forms)

    receive_forms = [
      {:attribute, 0, :module, :hyperlang_pending_slot},
      {:attribute, 0, :export,
       [
         {:"$safe_entry", 3},
         {:"$safe_export", 4},
         {:"$safe_raw_export", 3}
       ]},
      {:function, 0, :"$safe_entry", 3,
       [
         {:clause, 0, [{:var, 0, :token}, {:var, 0, :input}, {:var, 0, :runtime}], [],
          [{:receive, 0, []}]}
       ]}
    ]

    # A receive outside a lifted wait fun would let the compiler name its loop
    # after a guest-shaped function.
    assert {:error, %{message: "generated forms contain a compiler-named construct" <> _}} =
             Hyperlang.Codegen.verify_generated_forms(receive_forms)

    lifted_receive_forms =
      List.replace_at(
        receive_forms,
        2,
        {:function, 0, :safe_f_0, 2,
         [
           {:clause, 0, [{:var, 0, :ctx}, {:tuple, 0, []}], [],
            [{:fun, 0, {:clauses, [{:clause, 0, [], [], [{:receive, 0, []}]}]}}]}
         ]}
      )

    assert :ok = Hyperlang.Codegen.verify_generated_forms(lifted_receive_forms)

    send_forms = [
      {:attribute, 0, :module, :hyperlang_pending_slot},
      {:attribute, 0, :export,
       [
         {:"$safe_entry", 3},
         {:"$safe_export", 4},
         {:"$safe_raw_export", 3}
       ]},
      {:function, 0, :"$safe_entry", 3,
       [
         {:clause, 0, [{:var, 0, :token}, {:var, 0, :input}, {:var, 0, :runtime}], [],
          [{:op, 0, :!, {:var, 0, :input}, {:atom, 0, :ok}}]}
       ]}
    ]

    assert {:error, %{category: :generated_form_verify, message: message}} =
             Hyperlang.Codegen.verify_generated_forms(send_forms)

    assert message =~ "forbidden syntax"

    assert {:error, %{category: :generated_form_verify}} =
             Hyperlang.Codegen.verify_generated_forms(send_forms, :hyperlang_slot_000001)

    dynamic_remote_forms = [
      {:attribute, 0, :module, :hyperlang_pending_slot},
      {:attribute, 0, :export,
       [
         {:"$safe_entry", 3},
         {:"$safe_export", 4},
         {:"$safe_raw_export", 3}
       ]},
      {:function, 0, :"$safe_entry", 3,
       [
         {:clause, 0, [{:var, 0, :token}, {:var, 0, :input}, {:var, 0, :runtime}], [],
          [{:call, 0, {:remote, 0, {:var, 0, :m}, {:atom, 0, :f}}, []}]}
       ]}
    ]

    assert {:error, %{category: :generated_form_verify, message: message}} =
             Hyperlang.Codegen.verify_generated_forms(dynamic_remote_forms)

    assert message =~ "forbidden syntax"

    dynamic_local_forms = [
      {:attribute, 0, :module, :hyperlang_pending_slot},
      {:attribute, 0, :export,
       [
         {:"$safe_entry", 3},
         {:"$safe_export", 4},
         {:"$safe_raw_export", 3}
       ]},
      {:function, 0, :"$safe_entry", 3,
       [
         {:clause, 0, [{:var, 0, :token}, {:var, 0, :input}, {:var, 0, :runtime}], [],
          [{:call, 0, {:var, 0, :f}, []}]}
       ]}
    ]

    assert {:error, %{category: :generated_form_verify, message: message}} =
             Hyperlang.Codegen.verify_generated_forms(dynamic_local_forms)

    assert message =~ "forbidden syntax"

    unknown_forms = [
      {:attribute, 0, :module, :hyperlang_pending_slot},
      {:attribute, 0, :export,
       [
         {:"$safe_entry", 3},
         {:"$safe_export", 4},
         {:"$safe_raw_export", 3}
       ]},
      {:function, 0, :"$safe_entry", 3,
       [
         {:clause, 0, [{:var, 0, :token}, {:var, 0, :input}, {:var, 0, :runtime}], [],
          [{:made_up_expr, 0, :surprise}]}
       ]}
    ]

    assert {:error, %{category: :generated_form_verify, message: message}} =
             Hyperlang.Codegen.verify_generated_forms(unknown_forms)

    assert message =~ "forbidden syntax"
  end

  test "does not drop try subtrees before verification" do
    assert {:error, [%{category: :verify, message: message}]} =
             Hyperlang.Test.program(~S|try 1 after file:delete(<<"x">>) end.|, %{})

    assert message =~ "try-after"

    assert {:error, [%{category: :verify, message: message}]} =
             Hyperlang.Test.program(
               ~S|try 1 of X -> file:delete(X) catch _:_ -> ok end.|,
               %{}
             )

    assert message =~ "file:delete/1"

    assert {:error, [%{category: :verify, message: message}]} =
             Hyperlang.Test.program(
               "try 1 after hidden_atom_that_must_not_escape end.",
               %{}
             )

    assert message =~ "try-after"
    refute existing_atom?("hidden_atom_that_must_not_escape")
  end

  test "source names do not create unbounded atoms" do
    {:ok, _warmup} = Hyperlang.Test.program("result(Input) -> Input.", %{})
    before_count = :erlang.system_info(:atom_count)

    for i <- 1..50 do
      name = "very_unique_guest_helper_name_#{i}_#{System.unique_integer([:positive])}"
      source = "result(Input) -> #{name}(Input). #{name}(X) -> X."
      assert {:ok, _program} = Hyperlang.Test.program(source, %{})
    end

    after_count = :erlang.system_info(:atom_count)
    assert after_count - before_count < 50
  end

  test "pooled literal atoms do not become source VM atoms" do
    warmup_name = "pooled_atom_warmup_#{System.unique_integer([:positive])}"
    refute existing_atom?(warmup_name)
    assert {:ok, _warmup} = Hyperlang.Test.program("#{warmup_name}.", %{})
    refute existing_atom?(warmup_name)

    before_count = :erlang.system_info(:atom_count)

    for i <- 1..1_000 do
      name = "very_unique_literal_atom_#{i}_#{System.unique_integer([:positive])}"
      refute existing_atom?(name)
      assert {:ok, _program} = Hyperlang.Test.program("#{name}.", %{})
      refute existing_atom?(name)
    end

    after_count = :erlang.system_info(:atom_count)
    assert after_count - before_count < 10
  end

  test "bounded atom pool serializes guest atoms at host boundaries" do
    name = "session_#{System.unique_integer([:positive])}"
    refute existing_atom?(name)

    {_program, instance} =
      compile_and_instance("#{name}.", %{})

    assert eval(instance, :ok) == {:ok, name}
    refute existing_atom?(name)

    {_program, instance} =
      compile_and_instance("\#{session => ok, submit => session}.", %{})

    assert eval(instance, :ok) == {:ok, %{"session" => "ok", "submit" => "session"}}

    parent = self()

    manifest = erlang_public(%{})

    {_program, instance} =
      compile_and_instance(
        "tool:echo(session).",
        manifest,
        %{
          "tool" => %{
            echo: fn arg ->
              send(parent, {:tool_echo_args, [arg]})
              :ok
            end,
            leak: fn _arg -> :hyperlang_atom_0 end
          }
        }
      )

    assert eval(instance, :ok) == {:ok, :ok}
    assert_receive {:tool_echo_args, ["session"]}

    {_program, instance} =
      compile_and_instance(
        "tool:leak(session).",
        manifest,
        %{"tool" => %{echo: fn _arg -> :ok end, leak: fn _arg -> :hyperlang_atom_0 end}}
      )

    error = eval(instance, :ok) |> assert_eval_error(:import)
    assert error_reason(error) == "import_error"
    assert inspect(error.details) =~ "atom_not_allowed"

    assert {:error, [%{category: category, message: message}]} =
             Hyperlang.Test.program("{one, two}.", %{limits: %{max_atom_count: 1}})

    assert category in [:lexer, :verify]
    assert message =~ "atom"

    for source <- [
          "hyperlang_atom_0.",
          "safe_f_0.",
          "hyperlang_slot_000001.",
          "safe_result.",
          "'$safe_entry'.",
          "'$safe_export'."
        ] do
      {_program, instance} = compile_and_instance(source, %{})
      error = eval(instance, :ok) |> assert_eval_error(:output)
      assert inspect(error) =~ "atom_not_allowed"
      refute inspect(error) =~ "hyperlang_atom_"
      refute inspect(error) =~ "hyperlang_slot_"
      refute inspect(error) =~ "safe_f_"
    end

    assert {:error, [%{category: :manifest, message: message}]} =
             Hyperlang.Test.program("1.", %{terms: %{allowed_atoms: [:hyperlang_atom_0]}})

    assert message =~ "reserved Hyperlang internal name"

    assert {:error, [%{category: :manifest, message: message}]} =
             Hyperlang.Test.program("1.", %{
               terms: %{allowed_atoms: ["hyperlang_atom_1"]}
             })

    assert message =~ "reserved Hyperlang internal name"

    assert {:error, [%{category: :manifest, message: message}]} =
             Hyperlang.Test.program("1.", %{
               terms: %{allowed_atoms: [:hyperlang_slot_000001]}
             })

    assert message =~ "reserved Hyperlang internal name"

    assert {:error, [%{category: :manifest, message: message}]} =
             Hyperlang.Test.program("1.", %{
               terms: %{allowed_atoms: [:hyperlang_pending_version]}
             })

    assert message =~ "reserved Hyperlang internal name"

    assert {:error, [%{category: :manifest, message: message}]} =
             Hyperlang.Test.program("1.", %{
               terms: %{allowed_atoms: ["hyperlang_pending_slot"]}
             })

    assert message =~ "reserved Hyperlang internal name"

    {_program, instance} =
      compile_and_instance("Input =:= session.", erlang_public())

    assert_eval_error(eval(instance, :hyperlang_atom_0), :input)
  end

  test "allowed atoms stay atoms across import arguments and returns" do
    parent = self()

    manifest =
      erlang_public(%{
        terms: %{allowed_atoms: [:id, :session_id, :status, :active]}
      })

    {_program, instance} =
      compile_and_instance(
        ~S"""
        Result = tools:roundtrip(#{id => session_id, status => active}),
        {maps:get(id, Result), maps:get(status, Result)}.
        """,
        manifest,
        %{
          "tools" => %{
            roundtrip: fn arg ->
              send(parent, {:roundtrip_args, [arg]})
              %{id: <<"session_1">>, status: :active}
            end
          }
        }
      )

    assert eval(instance, :ok) == {:ok, {<<"session_1">>, :active}}
    assert_receive {:roundtrip_args, [%{id: :session_id, status: :active}]}
  end

  test "fixed generated atom pools are hard manifest caps" do
    assert {:error, [%{category: :manifest, message: message}]} =
             Hyperlang.Test.program("1.", %{
               limits: %{max_atom_count: Hyperlang.GeneratedAtoms.max_source_atoms() + 1}
             })

    assert message =~ "fixed atom pool"

    assert {:error, [%{category: :manifest, message: message}]} =
             Hyperlang.Test.program("1.", %{
               limits: %{max_functions: Hyperlang.GeneratedAtoms.max_functions() + 1}
             })

    assert message =~ "fixed function atom pool"

    assert {:error, [%{category: :manifest, message: message}]} =
             Hyperlang.Test.program("1.", %{
               limits: %{max_tokens: Hyperlang.GeneratedAtoms.max_variables() + 1}
             })

    assert message =~ "fixed variable atom pool"
  end

  test "ordinary atom source lookup skips global generated-atom services" do
    universe = {:hyperlang_test_atom_source_lookup, System.unique_integer([:positive])}

    assert {:ok, source_to_pool, _pool_to_source} =
             Hyperlang.AtomUniverse.reserve(universe, ["local_lookup_atom"])

    pooled_atom = Map.fetch!(source_to_pool, "local_lookup_atom")
    ctx = %{atom_pool: %{}, atom_universe: universe, terms: %{}}

    traced = [{Hyperlang.AtomUniverse, :source_for_atom, 2}]

    {nil, ordinary_calls} =
      capture_trace_calls(traced, fn -> Hyperlang.Terms.atom_source(:utf8, ctx) end)

    refute {Hyperlang.AtomUniverse, :source_for_atom, 2} in ordinary_calls

    assert Hyperlang.Terms.atom_source(pooled_atom, ctx) == "local_lookup_atom"
  end

  test "atom universe pool exhaustion returns a controlled compile error" do
    suffix = System.unique_integer([:positive])
    universe = {:hyperlang_test_exhausted_atom_universe, suffix}

    reserved =
      for index <- 0..(Hyperlang.GeneratedAtoms.max_source_atoms() - 1) do
        "reserved_#{suffix}_#{index}"
      end

    assert {:ok, _source_to_pool, _pool_to_source} =
             Hyperlang.AtomUniverse.reserve(universe, reserved)

    assert {:error, [%{category: :verify, message: message}]} =
             Hyperlang.Test.program("reserved_#{suffix}_overflow.", %{
               atom_universe: universe,
               limits: %{max_atom_count: 1}
             })

    assert message =~ "atom universe exhausted"
  end

  test "sanitizes inputs and import returns" do
    {_program, instance} = compile_and_instance("Input.", %{})
    assert_eval_error(eval(instance, self()), :input)

    bad = %{"bad" => %{pid: fn -> self() end, callback: fn -> fn x -> x end end}}

    {_program, instance} = compile_and_instance("bad:pid().", %{}, bad)

    error = assert_eval_error(eval(instance, :ok), :import)
    assert inspect(error.details) =~ "forbidden_term"

    {_program, instance} = compile_and_instance("bad:callback().", %{}, bad)

    error = assert_eval_error(eval(instance, :ok), :import)
    assert inspect(error.details) =~ "forbidden_term"
  end

  test "sanitizer enforces host input and final output boundaries" do
    source = ~S|binary:copy(<<"a">>, 5).|

    {_program, instance} =
      compile_and_instance(source, %{}, %{}, %{limits: %{max_binary_bytes: 4}})

    error = eval(instance, :ok) |> assert_eval_error(:stdlib)
    assert get_in(error, [:details, "error", "reason"]) == "binary_bytes"

    source = ~S|#{<<"value">> => Input}.|

    {_program, instance} =
      compile_and_instance(source, erlang_public(), %{}, %{
        limits: %{max_binary_bytes: 100, max_term_depth: 8}
      })

    assert eval(instance, [<<"abc">>, [1, 2]]) ==
             {:ok, %{<<"value">> => [<<"abc">>, [1, 2]]}}

    bad_inputs = [
      self(),
      make_ref(),
      fn -> :ok end,
      :not_allowed,
      List.to_tuple(Enum.to_list(1..1001)),
      Enum.to_list(1..10_001),
      Map.new(1..1001, &{&1, &1}),
      List.duplicate([[[[[[[[[[0]]]]]]]]]], 1)
    ]

    for input <- bad_inputs do
      assert_eval_error(eval(instance, input), :input)
    end
  end

  test "final result sanitizer enforces configured public term policy" do
    {_program, instance} =
      compile_and_instance("{ok, <<1, 2>>}.", %{terms: %{allowed_atoms: [:ok]}})

    assert eval(instance, nil) == {:ok, ["ok", %{"$binary" => "AQI="}]}

    {_program, instance} =
      compile_and_instance("{ok, Input}.", erlang_public(%{terms: %{allowed_atoms: [:ok]}}))

    assert eval(instance, 1) == {:ok, {:ok, 1}}

    {_program, instance} =
      compile_and_instance("{ok, Input}.", %{terms: %{allowed_atoms: [:ok]}}, %{}, %{
        terms: %{atom_public: :binary, tuple_public: :list, binary_public: :base64}
      })

    assert eval(instance, <<1, 2>>) == {:ok, ["ok", %{"$binary" => "AQI="}]}

    {_program, instance} =
      compile_and_instance("{ok, Input}.", %{terms: %{allowed_atoms: [:ok]}}, %{}, %{
        terms: %{allow_tuples: false}
      })

    error = eval(instance, 1) |> assert_eval_error(:output)
    assert error_reason(error) == "tuple_not_allowed"

    {_program, instance} =
      compile_and_instance("ok.", %{terms: %{allowed_atoms: [:ok]}}, %{}, %{
        terms: %{allow_atoms: false}
      })

    error = eval(instance, nil) |> assert_eval_error(:output)
    assert error_reason(error) =~ "atom_not_allowed"

    # The door envelope keys and the closed public-category vocabulary are
    # kernel atoms. Nothing guest-derived may arrive as an atom.
    refute contains_atom?(error.details)
    refute contains_atom?(error.message)
  end

  test "input and output byte limits are explicit manifest limits" do
    {_program, instance} =
      compile_and_instance("Input.", %{limits: %{max_input_bytes: 4}}, %{}, %{})

    error = eval(instance, <<"abcde">>) |> assert_eval_error(:input)
    assert error_reason(error) == "input_bytes"

    {_program, instance} =
      compile_and_instance(~S|<<"abcde">>.|, %{limits: %{max_output_bytes: 4}}, %{}, %{})

    error = eval(instance, nil) |> assert_eval_error(:output)
    assert error_reason(error) == "output_bytes"
  end

  test "allocation-heavy expressions are bounded by safe terms and worker limits" do
    {_program, instance} =
      compile_and_instance("32 * 32.", erlang_public(%{limits: %{max_integer_bits: 7}}))

    error = eval(instance, nil) |> assert_eval_error(:output)
    assert error_reason(error) == "integer_bits"

    {_program, instance} =
      compile_and_instance(~S|binary:copy(<<"ab">>, 3).|, %{
        limits: %{max_binary_bytes: 4}
      })

    error = eval(instance, nil) |> assert_eval_error(:stdlib)
    assert get_in(error, [:details, "error", "reason"]) == "binary_bytes"

    {_program, instance} =
      compile_and_instance(~S|binary:copy(<<"x">>, 10000000).|, %{
        limits: %{max_binary_bytes: 4}
      })

    error = eval(instance, nil) |> assert_eval_error(:stdlib)
    assert get_in(error, [:details, "error", "reason"]) == "binary_bytes"

    for source <- [
          ~S|binary:list_to_bin([65, 66, 67, 68, 69]).|,
          ~S|binary:join([<<"ab">>, <<"cd">>], <<":">>).|,
          ~S|binary:encode_hex(<<"abc">>).|,
          ~S|base64:encode(<<"abc">>).|,
          ~S|base64:decode([89, 87, 70, 104, 89, 81, 61, 61]).|,
          ~S|unicode:characters_to_binary([16#1F600]).|,
          ~S|unicode:characters_to_binary([255, 255], latin1, utf8).|,
          ~S|erlang:iolist_to_binary([<<"ab">>, <<"cd">>, <<"e">>]).|,
          ~S|erlang:list_to_binary([<<"ab">>, <<"cd">>, <<"e">>]).|
        ] do
      {_program, instance} =
        compile_and_instance(source, %{limits: %{max_binary_bytes: 3}})

      error = eval(instance, nil) |> assert_eval_error(:stdlib)
      assert get_in(error, [:details, "error", "reason"]) == "binary_bytes"
    end

    for source <- [
          ~S|base64:encode_to_string(<<"abc">>).|,
          ~S|base64:decode_to_string(<<"YWFhYQ==">>).|,
          ~S|base64:mime_decode_to_string(<<"Y W F h Y Q = =">>).|
        ] do
      {_program, instance} =
        compile_and_instance(source, %{limits: %{max_binary_bytes: 32, max_list_length: 3}})

      error = eval(instance, nil) |> assert_eval_error(:stdlib)
      assert get_in(error, [:details, "error", "reason"]) == "list_length"
    end

    {_program, instance} =
      compile_and_instance(
        ~S|unicode:characters_to_list(<<0, 0, 0, 65, 0, 0, 0, 66>>, utf32).|,
        %{limits: %{max_binary_bytes: 8, max_list_length: 1}}
      )

    error = eval(instance, nil) |> assert_eval_error(:stdlib)
    assert get_in(error, [:details, "error", "reason"]) == "list_length"

    {_program, instance} =
      compile_and_instance(
        ~S|string:lowercase(<<196, 176>>).|,
        %{limits: %{max_binary_bytes: 2}}
      )

    error = eval(instance, nil) |> assert_eval_error(:stdlib)
    assert get_in(error, [:details, "error", "reason"]) == "binary_bytes"

    {_program, instance} =
      compile_and_instance(
        ~S|string:uppercase([223, 223]).|,
        %{limits: %{max_binary_bytes: 8, max_list_length: 3}}
      )

    error = eval(instance, nil) |> assert_eval_error(:stdlib)
    assert get_in(error, [:details, "error", "reason"]) == "list_length"

    for source <- [
          ~S|string:chars($a, 5).|,
          ~S|string:copies("ab", 3).|,
          ~S|string:pad("x", 5).|,
          ~S|string:left("x", 5).|,
          ~S|string:right("x", 5).|,
          ~S|string:centre("x", 5).|,
          ~S|string:concat("ab", "cd").|,
          ~S|string:join(["ab", "cd"], ":").|
        ] do
      {_program, instance} =
        compile_and_instance(source, %{limits: %{max_binary_bytes: 32, max_list_length: 3}})

      error = eval(instance, nil) |> assert_eval_error(:stdlib)
      assert get_in(error, [:details, "error", "reason"]) == "list_length"
    end

    for source <- [
          ~S|string:tokens(<<"a b c d">>, <<" ">>).|,
          ~S|string:lexemes(<<"a,b,c,d">>, <<",">>).|
        ] do
      {_program, instance} =
        compile_and_instance(source, %{limits: %{max_binary_bytes: 32, max_list_length: 3}})

      error = eval(instance, nil) |> assert_eval_error(:stdlib)
      assert get_in(error, [:details, "error", "reason"]) == "list_length"
    end

    {_program, instance} =
      compile_and_instance(
        ~S|string:split(<<"a,a,a,a">>, <<",">>, all).|,
        %{limits: %{max_binary_bytes: 32, max_list_length: 3}}
      )

    error = eval(instance, nil) |> assert_eval_error(:stdlib)
    assert get_in(error, [:details, "error", "reason"]) == "list_length"

    {_program, instance} =
      compile_and_instance(
        ~S|string:replace(<<"aaaa">>, <<"a">>, <<"bbbb">>, all).|,
        %{limits: %{max_binary_bytes: 8, max_list_length: 16}}
      )

    error = eval(instance, nil) |> assert_eval_error(:stdlib)
    assert get_in(error, [:details, "error", "reason"]) == "binary_bytes"

    for source <- [
          ~S|string:reverse(<<"abcd">>).|,
          ~S|string:to_graphemes(<<"abcd">>).|
        ] do
      {_program, instance} =
        compile_and_instance(source, %{limits: %{max_binary_bytes: 8, max_list_length: 3}})

      error = eval(instance, nil) |> assert_eval_error(:stdlib)
      assert get_in(error, [:details, "error", "reason"]) == "list_length"
    end

    for source <- [
          ~S|binary:bin_to_list(<<"abcd">>).|,
          ~S|binary:split(<<"a,a,a,a">>, <<",">>, [global]).|,
          ~S|binary:matches(<<"aaaa">>, <<"a">>).|
        ] do
      {_program, instance} =
        compile_and_instance(source, %{limits: %{max_binary_bytes: 32, max_list_length: 3}})

      error = eval(instance, nil) |> assert_eval_error(:stdlib)
      assert get_in(error, [:details, "error", "reason"]) == "list_length"
    end

    {_program, instance} =
      compile_and_instance(
        ~S|binary:replace(<<"aaaa">>, <<"a">>, <<"bbbb">>, [global]).|,
        %{limits: %{max_binary_bytes: 8, max_list_length: 32}}
      )

    error = eval(instance, nil) |> assert_eval_error(:stdlib)
    assert get_in(error, [:details, "error", "reason"]) == "binary_bytes"

    {_program, instance} =
      compile_and_instance(
        ~S|binary:encode_unsigned(16#100000000).|,
        %{limits: %{max_binary_bytes: 4}}
      )

    error = eval(instance, nil) |> assert_eval_error(:stdlib)
    assert get_in(error, [:details, "error", "reason"]) == "binary_bytes"

    {_program, instance} =
      compile_and_instance(
        ~S|binary:decode_unsigned(<<1, 0>>).|,
        %{limits: %{max_binary_bytes: 4, max_integer_bits: 8}}
      )

    error = eval(instance, nil) |> assert_eval_error(:stdlib)
    assert get_in(error, [:details, "error", "reason"]) == "integer_bits"

    {_program, instance} =
      compile_and_instance(
        ~S|{string:tokens("a b", " "), string:lexemes("a,,b", ","), binary:encode_unsigned(258), binary:encode_unsigned(258, little)}.|,
        erlang_public(%{
          limits: %{max_binary_bytes: 8, max_list_length: 8},
          terms: %{allowed_atoms: [:little]}
        })
      )

    assert eval(instance, nil) == {:ok, {[~c"a", ~c"b"], [~c"a", ~c"b"], <<1, 2>>, <<2, 1>>}}

    {_program, instance} =
      compile_and_instance(
        ~S|{binary:decode_unsigned(<<1, 2>>), binary:decode_unsigned(<<2, 1>>, little)}.|,
        erlang_public(%{
          limits: %{max_binary_bytes: 8, max_integer_bits: 16},
          terms: %{allowed_atoms: [:little]}
        })
      )

    assert eval(instance, nil) == {:ok, {258, 258}}

    {_program, instance} =
      compile_and_instance(
        ~S|{unicode:characters_to_binary("abc"), unicode:characters_to_list(<<"abc">>, utf8)}.|,
        erlang_public(%{limits: %{max_binary_bytes: 8, max_list_length: 8}})
      )

    assert eval(instance, nil) == {:ok, {"abc", ~c"abc"}}

    {_program, instance} =
      compile_and_instance(
        ~S|base64:encode(<<"a">>, #{padding => false}).|,
        erlang_public(%{limits: %{max_binary_bytes: 2}})
      )

    assert eval(instance, nil) == {:ok, "YQ"}

    {_program, instance} =
      compile_and_instance("[X || X <- lists:seq(1, 5)].", %{
        limits: %{max_list_length: 4}
      })

    error = eval(instance, nil) |> assert_eval_error(:stdlib)
    assert inspect(error) =~ "list_length"

    {_program, instance} =
      compile_and_instance(
        ~S|re:replace(<<"aaaa">>, <<"a">>, <<"bb">>, [global, {return, binary}]).|,
        erlang_public(%{
          limits: %{max_binary_bytes: 4},
          terms: %{allowed_atoms: [:global, :return, :binary]}
        })
      )

    error = eval(instance, nil) |> assert_eval_error(:stdlib)
    assert get_in(error, [:details, "error", "reason"]) == "binary_bytes"
  end

  test "binary split and matches limits count actual matches, not the static bound" do
    # The static bound assumes every pattern_size bytes match, so a large
    # binary with sparse separators (an rc env import: 16KB value, byte-1
    # SEP) used to be refused outright. Sparse inputs must pass; only
    # results that truly exceed max_list_length may be refused.
    big = String.duplicate("a", 16_000)

    {_program, instance} =
      compile_and_instance(
        "result(Value) -> binary:split(Value, <<1>>, [global]).",
        erlang_public(%{limits: %{max_binary_bytes: 32_768, max_list_length: 16}})
      )

    assert eval(instance, big <> <<1>> <> big) == {:ok, [big, big]}

    {_program, instance} =
      compile_and_instance(
        ~S|binary:split(<<"a,b,c,d">>, <<",">>, [global]).|,
        erlang_public(%{limits: %{max_binary_bytes: 32, max_list_length: 4}})
      )

    assert eval(instance, nil) == {:ok, [<<"a">>, <<"b">>, <<"c">>, <<"d">>]}

    {_program, instance} =
      compile_and_instance(
        ~S|binary:split(<<"a,b,c,d,e">>, <<",">>, [global]).|,
        erlang_public(%{limits: %{max_binary_bytes: 32, max_list_length: 4}})
      )

    error = eval(instance, nil) |> assert_eval_error(:stdlib)
    assert get_in(error, [:details, "error", "reason"]) == "list_length"

    {_program, instance} =
      compile_and_instance(
        ~S|binary:split(<<"a:b;c">>, [<<":">>, <<";">>], [global]).|,
        erlang_public(%{limits: %{max_binary_bytes: 32, max_list_length: 3}})
      )

    assert eval(instance, nil) == {:ok, [<<"a">>, <<"b">>, <<"c">>]}

    {_program, instance} =
      compile_and_instance(
        ~S|binary:matches(<<"xaxbxc">>, <<"x">>).|,
        erlang_public(%{limits: %{max_binary_bytes: 32, max_list_length: 3}})
      )

    assert {eval_result, calls} =
             capture_trace_calls(
               [{Hyperlang.Runtime, :stdlib, 4}, {Hyperlang.Runtime, :binary_matches, 3}],
               fn -> eval(instance, nil) end
             )

    assert eval_result == {:ok, [{0, 1}, {2, 1}, {4, 1}]}
    refute {Hyperlang.Runtime, :stdlib, 4} in calls
    assert {Hyperlang.Runtime, :binary_matches, 3} in calls

    {_program, instance} =
      compile_and_instance(
        ~S|binary:matches(<<"xxxxxxxx">>, <<"x">>).|,
        erlang_public(%{limits: %{max_binary_bytes: 32, max_list_length: 3}})
      )

    error = eval(instance, nil) |> assert_eval_error(:stdlib)
    assert get_in(error, [:details, "error", "reason"]) == "list_length"
  end

  test "uses direct OTP stdlib capabilities" do
    {_program, instance} = compile_and_instance("abs(-4) + math:sqrt(81) + lists:sum([1,2,3]).")
    assert eval(instance, :ok) == {:ok, 19.0}

    {_program, instance} = compile_and_instance(~S|maps:get(<<"x">>, #{<<"x">> => 7}).|)
    assert eval(instance, :ok) == {:ok, 7}

    assert {:error, [%{category: :verify}]} =
             Hyperlang.Test.program("lists:sum([1,2,3]).", %{stdlib: %{lists: false}})

    {_program, instance} =
      compile_and_instance(
        ~S|re:run(<<"a">>, <<"a">>).|,
        erlang_public(%{terms: %{allowed_atoms: [:match]}})
      )

    assert {:ok, {:match, _}} = eval(instance, nil)

    {_program, instance} =
      compile_and_instance(
        """
        {
          lists:map(fun(X) -> X + 1 end, [1, 2, 3]),
          lists:filter(fun(X) -> X > 1 end, [1, 2, 3]),
          lists:foldl(fun(X, Acc) -> X + Acc end, 0, [1, 2, 3]),
          lists:foldr(fun(X, Acc) -> [X | Acc] end, [], [1, 2]),
          lists:all(fun(X) -> X > 0 end, [1, 2, 3]),
          lists:any(fun(X) -> X =:= 2 end, [1, 2, 3]),
          lists:sort(fun(A, B) -> A =< B end, [2, 1])
        }.
        """,
        erlang_public()
      )

    assert eval(instance, nil) == {:ok, {[2, 3, 4], [2, 3], 6, [1, 2], true, true, [1, 2]}}

    # re:compile is a bounded wrapped proxy: the compiled re_pattern is a
    # pure term that round-trips back into the match-limited run/replace/
    # split wrappers.
    {_program2, instance2} =
      compile_and_instance(
        ~S|{ok, Pat} = re:compile(<<"a">>), re:run(<<"a">>, Pat, [{capture, none}]).|,
        erlang_public(%{terms: %{allowed_atoms: [:match, :ok, :capture, :none]}})
      )

    assert eval(instance2, nil) == {:ok, :match}
  end

  test "stdlib admission is frozen to the OTP allowlist instead of live exports" do
    assert Hyperlang.Stdlib.supported_otp_release?()
    assert Hyperlang.Stdlib.runtime_otp_release() == Hyperlang.Stdlib.otp_release()

    assert Hyperlang.Stdlib.call_target("lists", "map", 2) == {:direct, :lists, :map}

    assert {:ok, :callback_intrinsic, [1], :lists, false} =
             Hyperlang.Stdlib.runtime_spec(:lists, :map, 2)

    # lists:map/2 is a callback intrinsic: codegen routes it through
    # Runtime.stdlib, so the generated-call gate never admits it directly.
    refute Hyperlang.Stdlib.generated_call_allowed?(:lists, :map, 2)
    assert Hyperlang.Stdlib.generated_call_allowed?(:binary, :part, 3)

    assert Code.ensure_loaded?(:timer)
    assert :erlang.function_exported(:timer, :sleep, 1)
    assert Hyperlang.Stdlib.call_target("timer", "sleep", 1) == :error
    refute Hyperlang.Stdlib.generated_call_allowed?(:timer, :sleep, 1)

    assert Code.ensure_loaded?(:lists)
    assert :erlang.function_exported(:lists, :module_info, 0)
    assert Hyperlang.Stdlib.call_target("lists", "module_info", 0) == :error
    refute Hyperlang.Stdlib.generated_call_allowed?(:lists, :module_info, 0)

    assert Hyperlang.Stdlib.call_target("io_lib", "build_text", 1) ==
             {:wrapped, :io_lib, :build_text}

    assert Hyperlang.Stdlib.call_target("io_lib", "format", 2) ==
             {:wrapped, :io_lib, :format}

    assert {:ok, :intrinsic, [], :lists, false} = Hyperlang.Stdlib.runtime_spec(:lists, :nth, 2)

    assert {:ok, :bounded_wrapper, [], :binary, false} =
             Hyperlang.Stdlib.runtime_spec(:binary, :copy, 2)

    assert Hyperlang.Stdlib.call_target("io", "format", 2) == {:captured_io, :io, :format}

    refute Hyperlang.Stdlib.generated_call_allowed?(:io_lib, :build_text, 1)
    refute Hyperlang.Stdlib.generated_call_allowed?(:io_lib, :format, 2)
    refute Hyperlang.Stdlib.generated_call_allowed?(:erlang, :system_time, 0)
  end

  test "guest process dictionary calls compile to direct process path by default" do
    {:ok, manifest} = Hyperlang.Manifest.normalize(erlang_public())
    manifest = Hyperlang.DoorTestSupport.seed_atom_universe(manifest)

    source = """
    result(_) ->
      put(k, undefined),
      A = get(k),
      B = get(),
      C = erase(k),
      D = erase(),
      {A, B, C, D}.
    """

    {:ok, compiled} = Hyperlang.Compiler.compile(source, manifest)
    {:ok, forms, _metadata} = Hyperlang.Codegen.to_forms(compiled, manifest)
    calls = remote_calls(forms)

    refute {Hyperlang.Runtime, :stdlib, 4} in calls
    assert {Hyperlang.Runtime, :guest_dictionary_get_all, 1} in calls
    assert {Hyperlang.Runtime, :guest_dictionary_erase_all, 1} in calls

    refute {Hyperlang.Runtime, :guest_dictionary_get, 2} in calls
    refute {Hyperlang.Runtime, :guest_dictionary_put, 3} in calls
    refute {Hyperlang.Runtime, :guest_dictionary_erase, 2} in calls

    assert {:erlang, :get, 1} in calls
    assert {:erlang, :put, 2} in calls
    assert {:erlang, :erase, 1} in calls
    assert {:maps, :remove, 2} in calls
    refute {:maps, :put, 3} in calls
  end

  test "generated guest process dictionary preserves wrapper semantics" do
    source = """
    result(_) ->
      A = get(<<"k">>),
      B = put(<<"k">>, undefined),
      C = get(<<"k">>),
      D = get(),
      E = erase(<<"k">>),
      F = get(<<"k">>),
      G = get(),
      {A, B, C, D, E, F, G}.
    """

    {_program, instance} = compile_and_instance(source, erlang_public())

    assert eval(instance, nil) ==
             {:ok,
              {:undefined, :undefined, :undefined, [{<<"k">>, :undefined}], :undefined,
               :undefined, []}}
  end

  test "maps get two compiles to the equivalent erlang map_get bif" do
    {:ok, manifest} = Hyperlang.Manifest.normalize(erlang_public())
    manifest = Hyperlang.DoorTestSupport.seed_atom_universe(manifest)

    source = """
    result(Input) ->
      {maps:get(<<"a">>, Input), maps:get(<<"missing">>, Input, <<"fallback">>)}.
    """

    {:ok, compiled} = Hyperlang.Compiler.compile(source, manifest)
    {:ok, forms, _metadata} = Hyperlang.Codegen.to_forms(compiled, manifest)
    calls = remote_calls(forms)

    assert {:erlang, :map_get, 2} in calls
    refute {:maps, :get, 2} in calls
    assert {:maps, :get, 3} in calls

    {_program, instance} = compile_and_instance(source, erlang_public())
    assert eval(instance, %{<<"a">> => 7}) == {:ok, {7, <<"fallback">>}}
  end

  test "maps put three compiles to a native map update expression" do
    {:ok, manifest} = Hyperlang.Manifest.normalize(erlang_public())
    manifest = Hyperlang.DoorTestSupport.seed_atom_universe(manifest)

    source = """
    result(Input) ->
      maps:put(<<"b">>, 2, Input).
    """

    {:ok, compiled} = Hyperlang.Compiler.compile(source, manifest)
    {:ok, forms, _metadata} = Hyperlang.Codegen.to_forms(compiled, manifest)
    calls = remote_calls(forms)

    refute {:maps, :put, 3} in calls

    {_program, instance} = compile_and_instance(source, erlang_public())
    assert eval(instance, %{<<"a">> => 1}) == {:ok, %{<<"a">> => 1, <<"b">> => 2}}
  end

  test "wrapped unicode conversions compile to dedicated bounded shims" do
    {:ok, manifest} =
      Hyperlang.Manifest.normalize(erlang_public(%{terms: %{allowed_atoms: [:latin1, :utf8]}}))

    manifest = Hyperlang.DoorTestSupport.seed_atom_universe(manifest)

    source = """
    result(_) ->
      {
        unicode:characters_to_binary("abc"),
        unicode:characters_to_binary("abc", latin1),
        unicode:characters_to_binary("abc", latin1, utf8),
        unicode:characters_to_list(<<"abc">>),
        unicode:characters_to_list(<<"abc">>, utf8)
      }.
    """

    {:ok, compiled} = Hyperlang.Compiler.compile(source, manifest)
    {:ok, forms, _metadata} = Hyperlang.Codegen.to_forms(compiled, manifest)
    calls = remote_calls(forms)

    refute {Hyperlang.Runtime, :stdlib, 4} in calls
    assert {Hyperlang.Runtime, :unicode_characters_to_binary, 2} in calls
    assert {Hyperlang.Runtime, :unicode_characters_to_binary, 3} in calls
    assert {Hyperlang.Runtime, :unicode_characters_to_binary, 4} in calls
    assert {Hyperlang.Runtime, :unicode_characters_to_list, 2} in calls
    assert {Hyperlang.Runtime, :unicode_characters_to_list, 3} in calls
  end

  test "canonical rune helpers compile to bounded runtime intrinsics" do
    {:ok, manifest} = Hyperlang.Manifest.normalize(erlang_public())
    manifest = Hyperlang.DoorTestSupport.seed_atom_universe(manifest)

    source = """
    result({S, I, J}) ->
      {slen(S), sidx(S, I), sslice(S, I, J), sslicefrom(S, I)}.

    runes(nil) -> [];
    runes(<<"">>) -> [];
    runes(S) when is_binary(S) -> unicode:characters_to_list(S);
    runes(L) when is_list(L) -> L.

    slen(S) ->
      length(runes(S)).

    sidx(S, I) ->
      lists:nth(I + 1, runes(S)).

    sslice(S, I, J) ->
      l2b(lists:sublist(runes(S), I + 1, J - I)).

    sslicefrom(S, I) ->
      l2b(lists:nthtail(I, runes(S))).

    l2b(L) ->
      unicode:characters_to_binary(L).
    """

    {:ok, compiled} = Hyperlang.Compiler.compile(source, manifest)
    {:ok, forms, _metadata} = Hyperlang.Codegen.to_forms(compiled, manifest)

    result_safe = compiled.core.functions[{"result", 1}].safe_name
    slen_safe = compiled.core.functions[{"slen", 1}].safe_name
    sidx_safe = compiled.core.functions[{"sidx", 2}].safe_name
    sslice_safe = compiled.core.functions[{"sslice", 3}].safe_name
    sslicefrom_safe = compiled.core.functions[{"sslicefrom", 2}].safe_name
    result_form = generated_function_form(forms, result_safe, 2)

    calls = remote_calls(result_form)
    local = local_calls(result_form)

    assert {Hyperlang.Runtime, :rune_len, 2} in calls
    assert {Hyperlang.Runtime, :rune_at, 3} in calls
    assert {Hyperlang.Runtime, :rune_slice, 4} in calls
    assert {Hyperlang.Runtime, :rune_tail, 3} in calls
    refute {Hyperlang.Runtime, :unicode_characters_to_list, 2} in calls
    refute {Hyperlang.Runtime, :unicode_characters_to_binary, 2} in calls
    refute {slen_safe, 2} in local
    refute {sidx_safe, 3} in local
    refute {sslice_safe, 4} in local
    refute {sslicefrom_safe, 3} in local

    {_program, instance} = compile_and_instance(source, erlang_public())
    assert eval(instance, {<<"åbc">>, 1, 3}) == {:ok, {3, ?b, <<"bc">>, <<"bc">>}}
    assert eval(instance, {[?a, ?b, ?c], 1, 2}) == {:ok, {3, ?b, <<"b">>, <<"bc">>}}
  end

  test "canonical rune helper intrinsics preserve unicode resource limits" do
    source = """
    result(_) ->
      sidx(<<"abcd">>, 0).

    runes(nil) -> [];
    runes(<<"">>) -> [];
    runes(S) when is_binary(S) -> unicode:characters_to_list(S);
    runes(L) when is_list(L) -> L.

    sidx(S, I) ->
      lists:nth(I + 1, runes(S)).
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{limits: %{max_binary_bytes: 32, max_list_length: 3}})
      )

    error = eval(instance, nil) |> assert_eval_error(:stdlib)
    assert get_in(error, [:details, "error", "reason"]) == "list_length"

    source = """
    result(_) ->
      sslicefrom([97, 98, 99, 100], 0).

    runes(nil) -> [];
    runes(<<"">>) -> [];
    runes(S) when is_binary(S) -> unicode:characters_to_list(S);
    runes(L) when is_list(L) -> L.

    sslicefrom(S, I) ->
      l2b(lists:nthtail(I, runes(S))).

    l2b(L) ->
      unicode:characters_to_binary(L).
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{limits: %{max_binary_bytes: 3, max_list_length: 32}})
      )

    error = eval(instance, nil) |> assert_eval_error(:stdlib)
    assert get_in(error, [:details, "error", "reason"]) == "binary_bytes"

    source = """
    result(_) ->
      sidx(<<97, 255>>, 0).

    runes(nil) -> [];
    runes(<<"">>) -> [];
    runes(S) when is_binary(S) -> unicode:characters_to_list(S);
    runes(L) when is_list(L) -> L.

    sidx(S, I) ->
      lists:nth(I + 1, runes(S)).
    """

    {_program, instance} = compile_and_instance(source, erlang_public())
    assert {:error, error} = eval(instance, nil)
    assert error_category(error) == :runtime
  end

  test "constant list table helpers compile hot calls to tuple element lookups" do
    {:ok, manifest} = Hyperlang.Manifest.normalize(erlang_public())
    manifest = Hyperlang.DoorTestSupport.seed_atom_universe(manifest)

    source = """
    result(I) ->
      {tab(tbl(), I), tablen(tbl())}.

    tbl() ->
      [10, 20, 30].

    tab(T, I) ->
      lists:nth(I + 1, T).

    tablen(T) ->
      length(T).
    """

    {:ok, compiled} = Hyperlang.Compiler.compile(source, manifest)
    {:ok, forms, _metadata} = Hyperlang.Codegen.to_forms(compiled, manifest)

    result_safe = compiled.core.functions[{"result", 1}].safe_name
    table_safe = compiled.core.functions[{"tbl", 0}].safe_name
    tab_safe = compiled.core.functions[{"tab", 2}].safe_name
    result_form = generated_function_form(forms, result_safe, 2)

    calls = remote_calls(result_form)
    local = local_calls(result_form)

    assert {:erlang, :element, 2} in calls
    assert {:erlang, :tuple_size, 1} in calls
    assert {:erlang, :is_integer, 1} in calls
    assert {table_safe, 2} in local
    refute {tab_safe, 3} in local

    {_program, instance} = compile_and_instance(source, erlang_public())
    assert eval(instance, 1) == {:ok, {20, 3}}
  end

  test "constant list table helpers accept negative numeric table entries" do
    {:ok, manifest} = Hyperlang.Manifest.normalize(erlang_public())
    manifest = Hyperlang.DoorTestSupport.seed_atom_universe(manifest)

    source = """
    result(I) ->
      {tab(tbl(), I), tablen(tbl())}.

    tbl() ->
      [-2, -1000, 0, 17].

    tab(T, I) ->
      lists:nth(I + 1, T).

    tablen(T) ->
      length(T).
    """

    {:ok, compiled} = Hyperlang.Compiler.compile(source, manifest)
    {:ok, forms, _metadata} = Hyperlang.Codegen.to_forms(compiled, manifest)

    result_safe = compiled.core.functions[{"result", 1}].safe_name
    table_safe = compiled.core.functions[{"tbl", 0}].safe_name
    tab_safe = compiled.core.functions[{"tab", 2}].safe_name
    result_form = generated_function_form(forms, result_safe, 2)

    calls = remote_calls(result_form)
    local = local_calls(result_form)

    assert {:erlang, :element, 2} in calls
    assert {table_safe, 2} in local
    refute {tab_safe, 3} in local

    {_program, instance} = compile_and_instance(source, erlang_public())
    assert eval(instance, 1) == {:ok, {-1000, 4}}
  end

  test "constant list table lookup fallback preserves lists:nth errors" do
    optimized_source = """
    result(_) ->
      tab(tbl(), -1).

    tbl() ->
      [10, 20, 30].

    tab(T, I) ->
      lists:nth(I + 1, T).
    """

    dynamic_source = """
    result(T) ->
      tab(T, -1).

    tab(T, I) ->
      lists:nth(I + 1, T).
    """

    {_program, optimized_instance} = compile_and_instance(optimized_source, erlang_public())
    {_program, dynamic_instance} = compile_and_instance(dynamic_source, erlang_public())

    assert {:error, optimized_error} = run_instance(optimized_instance, nil)

    assert {:error, dynamic_error} =
             run_instance(dynamic_instance, [10, 20, 30])

    assert error_category(optimized_error) == error_category(dynamic_error)
    assert Map.get(optimized_error, "class") == Map.get(dynamic_error, "class")
    assert Map.get(optimized_error, "reason") == Map.get(dynamic_error, "reason")
  end

  test "guest source cannot call generated guest dictionary helpers" do
    for source <- [
          "'Elixir.Hyperlang.Runtime':guest_dictionary_get(ctx, key).",
          "'Elixir.Hyperlang.Runtime':guest_dictionary_get_ns(ns, key).",
          "'Elixir.Hyperlang.Runtime':guest_dictionary_put(key, value, other).",
          "'Elixir.Hyperlang.Runtime':guest_dictionary_put_ns(ns, key, value).",
          "'Elixir.Hyperlang.Runtime':guest_dictionary_erase(key).",
          "'Elixir.Hyperlang.Runtime':guest_dictionary_erase_ns(ns, key).",
          "'Elixir.Hyperlang.Runtime':unicode_characters_to_list(ctx, data)."
        ] do
      assert {:error, [%{category: category} | _]} = Hyperlang.Test.program(source, %{}),
             source

      assert category in [:parse, :verify]
    end
  end

  test "frozen direct and captured stdlib entries exist in this OTP runtime" do
    missing =
      [
        Hyperlang.Stdlib.direct_matrix(),
        Hyperlang.Stdlib.captured_matrix(),
        Hyperlang.Stdlib.wrapped_matrix()
      ]
      |> Enum.flat_map(fn modules ->
        for {module, functions} <- modules,
            {function, arities} <- functions,
            arity <- arities,
            not exported_mfa?(module, function, arity) do
          {module, function, arity}
        end
      end)

    assert missing == []

    assert Hyperlang.Stdlib.call_target("webfs", "serve", 3) == :error
    assert Hyperlang.Stdlib.call_target("webfs", "json_encode", 1) == :error
    assert Hyperlang.Stdlib.call_target("webfs", "render", 2) == :error
    assert Hyperlang.Stdlib.call_target("webfs", "render_file", 2) == :error
    assert Hyperlang.Stdlib.call_target("webfs", "reactive", 2) == :error
    assert Hyperlang.Stdlib.call_target("fs", "serve", 3) == :error
    assert Hyperlang.Stdlib.call_target("fs", "ok", 1) == :error
  end

  defp exported_mfa?(module, function, arity) do
    module = String.to_atom(module)
    function = String.to_atom(function)
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  test "numeric and conversion coverage has stable bounds and diagnostics" do
    source = """
    {
      abs(-9),
      17 div 5,
      17 rem 5,
      math:pow(2.0, 3.0),
      round(3.6),
      trunc(3.6),
      lists:sum([1, 2, 3]),
      2 < 3,
      integer_to_binary(255, 16),
      binary_to_integer(<<"ff">>, 16),
      float_to_binary(1.25, [{decimals, 2}, compact])
    }.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{terms: %{allowed_atoms: [:compact, :decimals]}})
      )

    assert eval(instance, nil) ==
             {:ok, {9, 3, 2, 8.0, 4, 3, 6, true, "FF", 255, "1.25"}}

    {_program, instance} =
      compile_and_instance(~S|binary_to_integer(<<"nope">>).|, erlang_public())

    error = eval(instance, nil) |> assert_eval_error(:runtime)
    assert error_reason(error) =~ "not a textual representation of an integer"

    {_program, instance} =
      compile_and_instance("integer_to_binary(1024).", %{
        limits: %{max_binary_bytes: 2}
      })

    error = eval(instance, nil) |> assert_eval_error(:stdlib)
    assert inspect(error) =~ "binary_bytes"
  end

  test "wrapped float formatting normalizes pooled option atoms" do
    source = """
    {
      float_to_binary(2.54, [{decimals, 6}, compact]),
      float_to_binary(2.54, [short]),
      erlang:float_to_binary(2.54, [{decimals, 1}]),
      float_to_binary(2.54, [{scientific, 3}]),
      float_to_list(2.54, [{decimals, 3}, compact]),
      erlang:float_to_list(2.54, [{decimals, 1}])
    }.
    """

    {_program, instance} = compile_and_instance(source, erlang_public())

    assert eval(instance, nil) == {:ok, {"2.54", "2.54", "2.5", "2.540e+00", ~c"2.54", ~c"2.5"}}
  end

  test "wrapped float formatting rejects unsupported options without creating atoms" do
    name = "safe_float_option_probe_#{System.unique_integer([:positive])}"
    refute existing_atom?(name)

    for source <- [
          "float_to_binary(2.54, [#{name}]).",
          "float_to_binary(2.54, [{decimals, 254}]).",
          "float_to_binary(2.54, [{scientific, 250}]).",
          "float_to_binary(2.54, [{binary, 2}])."
        ] do
      {_program, instance} = compile_and_instance(source, erlang_public())

      error = eval(instance, nil) |> assert_eval_error(:stdlib)
      assert get_in(error, [:details, "error"]) == "badarg"
    end

    refute existing_atom?(name)
  end

  test "wrapped float formatting enforces output limits" do
    for {source, reason} <- [
          {"float_to_binary(2.54, [{decimals, 6}]).", "binary_bytes"},
          {"float_to_list(2.54, [{decimals, 6}]).", "list_length"}
        ] do
      {_program, instance} =
        compile_and_instance(source, %{
          limits: %{max_binary_bytes: 3, max_list_length: 3}
        })

      error = eval(instance, nil) |> assert_eval_error(:stdlib)
      assert get_in(error, [:details, "error", "reason"]) == reason
    end
  end

  test "wrapped atom_to_binary returns guest atom names without leaking pool atoms" do
    name = "safe_atom_to_binary_probe_#{System.unique_integer([:positive])}"
    refute existing_atom?(name)

    source = """
    {
      atom_to_binary(#{name}),
      erlang:atom_to_binary(#{name}, utf8),
      erlang:atom_to_binary(ok, unicode),
      erlang:atom_to_binary(foo, latin1)
    }.
    """

    {_program, instance} = compile_and_instance(source, erlang_public())

    assert eval(instance, nil) == {:ok, {name, name, "ok", "foo"}}
    refute existing_atom?(name)
  end

  test "wrapped atom_to_binary rejects unsupported encodings" do
    {_program, instance} =
      compile_and_instance("erlang:atom_to_binary(foo, native).", erlang_public())

    error = eval(instance, nil) |> assert_eval_error(:stdlib)
    assert get_in(error, [:details, "module"]) in ["erlang", :erlang]
    assert get_in(error, [:details, "function"]) in ["atom_to_binary", :atom_to_binary]
  end

  test "io_lib build_text routes through the vendored wrapper" do
    {_program, instance} = compile_and_instance(~S|io_lib:build_text("ok").|, erlang_public())

    assert eval(instance, nil) == {:ok, ~c"ok"}
  end

  test "io_lib formatting routes through the vendored safe wrapper" do
    name = "safe_io_lib_format_probe_#{System.unique_integer([:positive])}"
    refute existing_atom?(name)

    source = ~s|{
      io_lib:format("atom=~p text=~s", [#{name}, "ok"]),
      io_lib:fwrite("n=~2..0B", [7]),
      io_lib:bformat("bin=~p", [{#{name}, ok}]),
      io_lib:bfwrite("uni=~ts", [<<"☃"/utf8>>]),
      io_lib:format("limit=~p", [{#{name}, ok}], [{chars_limit, 64}])
    }.|

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          limits: %{max_atom_count: 1},
          terms: %{allowed_atoms: [:chars_limit, :ok]}
        })
      )

    assert {:ok, {formatted, padded, binary, unicode, limited}} = eval(instance, nil)
    assert IO.iodata_to_binary(formatted) =~ name
    assert IO.iodata_to_binary(formatted) =~ "text=ok"
    refute IO.iodata_to_binary(formatted) =~ "hyperlang_atom_"
    assert IO.iodata_to_binary(padded) == "n=07"
    assert binary =~ name
    refute binary =~ "hyperlang_atom_"
    assert unicode == "uni=☃"
    assert IO.iodata_to_binary(limited) =~ name
    refute existing_atom?(name)
  end

  test "io_lib formatting rejects unsupported options without creating atoms" do
    name = "safe_io_lib_option_probe_#{System.unique_integer([:positive])}"
    refute existing_atom?(name)

    for source <- [
          "io_lib:format(\"x\", [], [#{name}]).",
          "io_lib:format(\"x\", [], [{encoding, unicode}]).",
          "io_lib:format(\"x\", [], [{chars_limit, bad}])."
        ] do
      {_program, instance} = compile_and_instance(source, erlang_public())

      error = eval(instance, nil) |> assert_eval_error(:stdlib)
      assert get_in(error, [:details, "error"]) == "badarg"
    end

    refute existing_atom?(name)
  end

  test "io_lib formatting enforces formatted output limits" do
    for {source, manifest, reason} <- [
          {
            ~S|io_lib:format("~*c", [5, $a]).|,
            %{limits: %{max_binary_bytes: 16, max_list_length: 4}},
            "list_length"
          },
          {
            ~S|io_lib:bformat("~*c", [5, $a]).|,
            %{limits: %{max_binary_bytes: 4, max_list_length: 8}},
            "binary_bytes"
          }
        ] do
      {_program, instance} = compile_and_instance(source, manifest)

      error = eval(instance, nil) |> assert_eval_error(:stdlib)
      actual = get_in(error, [:details, "error", "reason"])
      assert actual == reason or get_in(actual, ["reason"]) == reason
    end
  end

  test "erlang BIF gap coverage uses direct pure term operations" do
    source = """
    {
      element(2, {a, b, c}),
      setelement(2, {a, b, c}, z),
      erlang:append_element({a, b}, c),
      erlang:delete_element(2, erlang:insert_element(2, {a, c}, b)),
      erlang:make_tuple(3, a, [{2, b}]),
      binary_part(<<"abcdef">>, {1, 3}),
      binary_part(<<"abcdef">>, 2, 2),
      integer_to_list(255, 16),
      float_to_list(1.25, [{decimals, 2}, compact]),
      erlang:is_record({foo, 1}, foo),
      erlang:is_record({foo, 1}, foo, 2),
      case {foo, 1} of R when erlang:is_record(R, foo, 2) -> ok; _ -> error end,
      crc32(<<"abc">>),
      adler32(<<"abc">>),
      md5(<<"abc">>),
      md5_final(md5_update(md5_init(), <<"abc">>)),
      phash2({a, 1}, 1000),
      iolist_to_iovec([<<"a">>, [<<"b">>, "c"]]),
      bit_size(list_to_bitstring([<<1:1>>])),
      length(bitstring_to_list(<<1:1>>)),
      erlang:append([1, 2], [3]),
      erlang:subtract([1, 2, 3], [2]),
      convert_time_unit(2, second, millisecond),
      posixtime_to_universaltime(0),
      universaltime_to_posixtime({{1970, 1, 1}, {0, 0, 0}})
    }.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          terms: %{
            allowed_atoms: [
              :a,
              :b,
              :c,
              :compact,
              :decimals,
              :foo,
              :ok,
              :error,
              :millisecond,
              :second,
              :z
            ]
          }
        })
      )

    assert {:ok, result} = eval(instance, nil)

    assert result ==
             {:b, {:a, :z, :c}, {:a, :b, :c}, {:a, :c}, {:a, :b, :a}, "bcd", "cd", ~c"FF",
              ~c"1.25", true, true, :ok, :erlang.crc32("abc"), :erlang.adler32("abc"),
              :erlang.md5("abc"), :erlang.md5("abc"), :erlang.phash2({:a, 1}, 1000), ["abc"], 1,
              1, [1, 2, 3], [1, 3], 2000, {{1970, 1, 1}, {0, 0, 0}}, 0}
  end

  test "reserved stdlib module names cannot be claimed by host imports" do
    manifest =
      erlang_public(%{
        bindings: %{
          "erlang" => %{system_info: fn _key -> :ok end},
          "tools" => %{list: fn -> [] end}
        }
      })

    assert {:error, [error]} = Hyperlang.Test.program("1.", manifest)
    assert error.category == :manifest
    assert error.message =~ "reserved authority module erlang"

    manifest =
      erlang_public(%{
        bindings: %{"lists" => %{sum: fn list -> Enum.sum(list) end}}
      })

    assert {:error, [error]} = Hyperlang.Test.program("1.", manifest)
    assert error.category == :manifest
    assert error.message =~ "reserved authority module lists"
  end

  test "problematic stdlib result shapes are contained at output boundaries" do
    manifest = erlang_public()

    for source <- [
          ~S"maps:iterator(#{}).",
          "gb_sets:iterator(gb_sets:new()).",
          "gb_trees:iterator(gb_trees:empty()).",
          "json:decode(<<\"null\">>).",
          "uri_string:parse(<<\"https://example.com\">>).",
          "unicode_util:lookup(65).",
          "sofs:set([1])."
        ] do
      {_program, instance} = compile_and_instance(source, manifest)
      assert {:error, _reason} = eval(instance, nil)
    end
  end

  test "OTP native records are rejected instead of crashing term sanitization" do
    assert {:ok, normalized} =
             Hyperlang.Manifest.normalize(%{terms: %{public: :erlang}})

    ctx = %{limits: normalized.limits, terms: normalized.terms}
    record = :records.create(:host, :item, [value: 1], %{is_exported: false})

    assert Hyperlang.Terms.sanitize_output(record, ctx) ==
             {:error, %{category: :output, reason: :native_record}}

    {_program, instance} =
      compile_and_instance(
        "bad:record().",
        erlang_public(),
        %{"bad" => %{record: fn -> record end}}
      )

    error = eval(instance, nil) |> assert_eval_error(:import)
    assert inspect(error) =~ "native_record"
  end

  test "runtime stdlib dispatch validates callback fun arguments" do
    {:ok, manifest} = Hyperlang.Manifest.normalize(erlang_public())

    ctx = %{
      limits: manifest.limits,
      terms: manifest.terms,
      atom_pool: %{},
      slot_module: __MODULE__
    }

    assert Hyperlang.Runtime.stdlib(ctx, :lists, :map, [fn x -> x + 1 end, [1, 2]]) == [2, 3]

    assert catch_error(Hyperlang.Runtime.stdlib(ctx, :lists, :map, [&String.length/1, ["abc"]])) ==
             {:sandbox, :stdlib_error, :lists, :map,
              %{category: :stdlib_args, reason: :forbidden_term}}
  end

  test "runtime process dictionary wrapper preserves Erlang undefined sentinel" do
    {:ok, manifest} = Hyperlang.Manifest.normalize(erlang_public())

    ctx = %{
      limits: manifest.limits,
      terms: manifest.terms,
      atom_pool: %{},
      slot_module: __MODULE__
    }

    key =
      <<"guest_pdict_test:",
        Integer.to_string(System.unique_integer([:positive, :monotonic]))::binary>>

    try do
      Process.put(key, :host_secret)
      assert Hyperlang.Runtime.stdlib(ctx, :erlang, :get, [key]) == :undefined
      assert Hyperlang.Runtime.stdlib(ctx, :erlang, :put, [key, 7]) == :undefined
      assert Hyperlang.Runtime.stdlib(ctx, :erlang, :get, [key]) == 7
      assert Hyperlang.Runtime.stdlib(ctx, :erlang, :erase, [key]) == 7
      assert Hyperlang.Runtime.stdlib(ctx, :erlang, :get, [key]) == :undefined
      assert Process.get(key) == :host_secret

      assert Hyperlang.Runtime.stdlib(ctx, :erlang, :put, [key, :undefined]) == :undefined
      assert Hyperlang.Runtime.stdlib(ctx, :erlang, :get, [key]) == :undefined
      assert Hyperlang.Runtime.stdlib(ctx, :erlang, :get, []) == [{key, :undefined}]
      assert Hyperlang.Runtime.stdlib(ctx, :erlang, :erase, [key]) == :undefined
      assert Hyperlang.Runtime.stdlib(ctx, :erlang, :get, []) == []
    after
      Process.delete(key)
    end
  end

  test "runtime process dictionary wrapper isolates all guest keys from host process keys" do
    {:ok, manifest} = Hyperlang.Manifest.normalize(erlang_public())

    ctx = %{
      limits: manifest.limits,
      terms: manifest.terms,
      atom_pool: %{},
      slot_module: __MODULE__
    }

    host_keys = [
      "hyperlang_re_patterns",
      "$hyperlang_test_reserved",
      "Elixir.Hyperlang.Runtime",
      "host_proc_agent",
      "$host_kernel_state",
      {"host", "proc", "state"},
      "up_agent",
      {"guest", "$hyperlang_test_reserved"},
      {"guest", {"Elixir.Hyperlang.Runtime", "leaf"}}
    ]

    try do
      for key <- host_keys do
        Process.put(key, :secret)

        assert Hyperlang.Runtime.stdlib(ctx, :erlang, :get, [key]) == :undefined
        assert Hyperlang.Runtime.stdlib(ctx, :erlang, :put, [key, 7]) == :undefined
        assert Hyperlang.Runtime.stdlib(ctx, :erlang, :get, [key]) == 7
        assert Hyperlang.Runtime.stdlib(ctx, :erlang, :erase, [key]) == 7
        assert Hyperlang.Runtime.stdlib(ctx, :erlang, :get, [key]) == :undefined
        assert Process.get(key) == :secret
      end

      for key <- host_keys do
        Hyperlang.Runtime.stdlib(ctx, :erlang, :put, [key, {"guest_value", key}])
      end

      entries = Hyperlang.Runtime.stdlib(ctx, :erlang, :get, [])
      assert Enum.sort(entries) == Enum.sort(Enum.map(host_keys, &{&1, {"guest_value", &1}}))

      erased = Hyperlang.Runtime.stdlib(ctx, :erlang, :erase, [])
      assert Enum.sort(erased) == Enum.sort(entries)
      assert Hyperlang.Runtime.stdlib(ctx, :erlang, :get, []) == []

      for key <- host_keys do
        assert Process.get(key) == :secret
      end
    after
      Enum.each(host_keys, &Process.delete/1)
    end
  end

  test "fs and webfs calls are not Hyperlang stdlib dispatch targets" do
    {:ok, manifest} = Hyperlang.Manifest.normalize(erlang_public())

    ctx = %{
      limits: manifest.limits,
      terms: manifest.terms,
      atom_pool: %{},
      slot_module: __MODULE__
    }

    assert catch_error(Hyperlang.Runtime.stdlib(ctx, :fs, :serve, [<<"/srv/x">>, :ok, []])) ==
             {:sandbox, :stdlib_error, :fs, :serve, :forbidden_stdlib_call}

    assert catch_error(Hyperlang.Runtime.stdlib(ctx, :webfs, :serve, [<<"/srv/x">>, :ok, []])) ==
             {:sandbox, :stdlib_error, :webfs, :serve, :forbidden_stdlib_call}

    assert catch_error(Hyperlang.Runtime.stdlib(ctx, :fs, :ok, [[]])) ==
             {:sandbox, :stdlib_error, :fs, :ok, :forbidden_stdlib_call}

    assert catch_error(Hyperlang.Runtime.stdlib(ctx, :webfs, :render, [<<"x">>, %{}])) ==
             {:sandbox, :stdlib_error, :webfs, :render, :forbidden_stdlib_call}
  end

  test "string and binary coverage uses OTP helpers" do
    source = """
    {
      string:trim("  abc  "),
      string:lowercase("ABC"),
      string:uppercase("abc"),
      string:split("a,b,c", ",", all),
      string:replace("banana", "na", "NA", all),
      string:prefix("foobar", "foo"),
      string:find("foobar", "bar"),
      string:pad("x", 3),
      binary:matches(<<"banana">>, <<"na">>),
      binary:match(<<"banana">>, <<"zz">>),
      unicode:characters_to_binary("abc"),
      lists:suffix("bar", "foobar"),
      binary:encode_hex(<<10, 11>>),
      base64:encode(<<"abc">>),
      uri_string:quote(<<"a b">>)
    }.
    """

    {_program, instance} =
      compile_and_instance(source, erlang_public(%{terms: %{allowed_atoms: [:all, :ok]}}))

    assert {:ok,
            {~c"abc", ~c"abc", ~c"ABC", [~c"a", ~c"b", ~c"c"], replace, ~c"bar", ~c"bar", pad,
             [{2, 2}, {4, 2}], :nomatch, "abc", true, "0A0B", "YWJj", "a%20b"}} =
             eval(instance, nil)

    assert IO.iodata_to_binary(replace) == "baNANA"
    assert IO.iodata_to_binary(pad) == "x  "

    assert {:error, [%{category: :verify}]} =
             Hyperlang.Test.program(
               ~S|safe_std:string_count(<<"abc">>, <<>>).|,
               erlang_public()
             )

    assert {:error, [%{category: :verify}]} =
             Hyperlang.Test.program(
               ~S|binary:compile_pattern(<<"a">>).|,
               erlang_public()
             )
  end

  test "bit syntax supports codemode-style binary builders" do
    source = ~S"""
    -module(codemode_program).

    hash_bin(Bin, Acc) ->
        Bytes = binary:bin_to_list(Bin),
        hash_list(Bytes, Acc).

    hash_list([], Acc) ->
        Acc;
    hash_list([B | Rest], Acc) ->
        hash_list(Rest, ((Acc * 131) + B) rem 1000003).

    bar(_, 0, Acc) ->
        Acc;
    bar(Char, N, Acc) ->
        bar(Char, N - 1, <<Acc/binary, Char/binary>>).

    line_for(Agent, Index) ->
        Name = maps:get(<<"name">>, Agent, <<"unnamed">>),
        Model = maps:get(<<"model">>, Agent, <<"unknown-model">>),
        Thinking = maps:get(<<"thinking_level">>, Agent, <<"off">>),
        H = hash_bin(<<Name/binary, Model/binary, Thinking/binary>>, Index + 7),
        Width = 8 + (H rem 8),
        Chars = [<<"✦"/utf8>>, <<"·"/utf8>>, <<"*">>, <<"◇"/utf8>>, <<"~">>, <<"#">>],
        Char = lists:nth((H rem length(Chars)) + 1, Chars),
        Stars = bar(Char, Width, <<>>),
        <<"│ "/utf8, Stars/binary, "  ", Name/binary, " / ", Thinking/binary, " │"/utf8>>.

    result(_) ->
        line_for(#{<<"name">> => <<"Ada">>, <<"model">> => <<"m">>, <<"thinking_level">> => <<"off">>}, 1).
    """

    {_program, instance} = compile_and_instance(source, erlang_public())

    assert {:ok, line} = eval(instance, nil)
    assert String.contains?(line, "Ada / off")
    assert byte_size(line) > byte_size("Ada / off")
  end

  test "bit syntax match patterns allow wildcard binary segments" do
    source = ~S"""
    -module(codemode_program).

    shorten(Bin, Max) ->
        case byte_size(Bin) =< Max of
            true -> Bin;
            false ->
                PrefixLen = Max - 3,
                <<Prefix:PrefixLen/binary, _/binary>> = Bin,
                <<Prefix/binary, "...">>
        end.

    result(_) ->
        #{
          <<"short">> => shorten(<<"abc">>, 6),
          <<"long">> => shorten(<<"abcdef">>, 5),
          <<"nested">> =>
            case <<1, 2, 3, 4>> of
              <<_:8, Keep:8, _/binary>> -> Keep
            end
        }.
    """

    {_program, instance} = compile_and_instance(source, erlang_public())

    assert eval(instance, nil) ==
             {:ok, %{"short" => "abc", "long" => "ab...", "nested" => 2}}
  end

  test "wildcards remain rejected in value-shaped expressions" do
    for source <- [
          "_.",
          "X = _, X.",
          "<<_/binary>>.",
          "<<_:8>>.",
          "length(_).",
          ~S|#{a => _}.|
        ] do
      assert {:error, [%{category: category} | _]} =
               Hyperlang.Test.program(source, erlang_public())

      assert category in [:parse, :verify]
    end
  end

  test "wildcards are accepted inside normal Erlang alias patterns" do
    source = ~S"""
    -module(codemode_program).

    prefix([], _) -> true;
    prefix(_, []) -> false;
    prefix([A | AR], [A | BR]) -> prefix(AR, BR);
    prefix(_, _) -> false.

    contains_list(_, []) -> true;
    contains_list([], _) -> false;
    contains_list(Hay = [_ | T], Needle) ->
      case prefix(Needle, Hay) of
        true -> {true, T};
        false -> contains_list(T, Needle)
      end.

    result(_) ->
      Alias = [_ | Tail] = [10, 20, 30],
      {prefix([1, 2], [1, 2, 3]),
       prefix([9], []),
       contains_list([1, 2, 3, 4], [2, 3]),
       Alias,
       Tail}.
    """

    {_program, instance} = compile_and_instance(source, erlang_public())

    assert eval(instance, nil) == {:ok, {true, false, {true, [3, 4]}, [10, 20, 30], [20, 30]}}
  end

  test "math coverage uses direct OTP helpers only" do
    source = """
    {
      math:sin(0.0),
      math:cos(0.0),
      math:tan(0.0),
      math:asin(0.0),
      math:acos(1.0),
      math:atan(1.0),
      math:sqrt(9.0),
      math:log(math:exp(1.0)),
      math:floor(3.8),
      math:ceil(3.2),
      math:pow(2.0, 3.0),
      math:pi(),
      math:tau(),
      math:fmod(7.0, 2.0),
      math:erf(0.0),
      math:erfc(0.0),
      timer:seconds(2)
    }.
    """

    {_program, instance} = compile_and_instance(source, erlang_public())

    assert {:ok,
            {sin, cos, tan, asin, acos, atan, sqrt, log, floor, ceil, pow, pi, tau, fmod, erf,
             erfc, seconds}} = eval(instance, nil)

    assert_in_delta sin, 0.0, 1.0e-12
    assert_in_delta cos, 1.0, 1.0e-12
    assert_in_delta tan, 0.0, 1.0e-12
    assert_in_delta asin, 0.0, 1.0e-12
    assert_in_delta acos, 0.0, 1.0e-12
    assert_in_delta atan, :math.pi() / 4, 1.0e-12
    assert_in_delta sqrt, 3.0, 1.0e-12
    assert_in_delta log, 1.0, 1.0e-12
    assert floor == 3
    assert ceil == 4
    assert_in_delta pow, 8.0, 1.0e-12
    assert_in_delta pi, :math.pi(), 1.0e-12
    assert_in_delta tau, 2 * :math.pi(), 1.0e-12
    assert_in_delta fmod, 1.0, 1.0e-12
    assert_in_delta erf, 0.0, 1.0e-12
    assert_in_delta erfc, 1.0, 1.0e-12
    assert seconds == 2000

    {_program, instance} = compile_and_instance("math:sqrt(-1.0).", erlang_public())

    error = eval(instance, nil) |> assert_eval_error(:runtime)
    assert error_reason(error) =~ "bad argument in arithmetic expression"

    assert {:error, [%{category: :verify}]} =
             Hyperlang.Test.program("safe_std:mean([2,4,6]).", erlang_public())
  end

  test "stdlib matrix identifies direct, captured, and unsupported OTP surface" do
    direct = Hyperlang.Stdlib.direct_matrix()
    wrapped = Hyperlang.Stdlib.wrapped_matrix()
    assert Hyperlang.Stdlib.otp_release() == "29"
    assert map_size(direct) >= 20
    assert get_in(wrapped, ["base64", "decode"]) == [1, 2]
    assert get_in(wrapped, ["base64", "decode_to_string"]) == [1, 2]
    assert get_in(wrapped, ["base64", "encode"]) == [1, 2]
    assert get_in(wrapped, ["base64", "encode_to_string"]) == [1, 2]
    assert get_in(wrapped, ["base64", "mime_decode"]) == [1, 2]
    assert get_in(wrapped, ["base64", "mime_decode_to_string"]) == [1, 2]
    assert get_in(wrapped, ["binary", "copy"]) == [1, 2]
    assert get_in(wrapped, ["binary", "bin_to_list"]) == [1, 2, 3]
    assert get_in(wrapped, ["binary", "decode_unsigned"]) == [1, 2]
    assert get_in(wrapped, ["binary", "encode_hex"]) == [1, 2]
    assert get_in(wrapped, ["binary", "encode_unsigned"]) == [1, 2]
    assert get_in(wrapped, ["binary", "join"]) == [2]
    assert get_in(wrapped, ["binary", "list_to_bin"]) == [1]
    assert get_in(wrapped, ["binary", "matches"]) == [2, 3]
    assert get_in(wrapped, ["binary", "replace"]) == [3, 4]
    assert get_in(wrapped, ["binary", "split"]) == [2, 3]
    assert get_in(wrapped, ["erlang", "atom_to_binary"]) == [1, 2]
    assert get_in(wrapped, ["erlang", "float_to_binary"]) == [1, 2]
    assert get_in(wrapped, ["erlang", "float_to_list"]) == [1, 2]
    assert get_in(wrapped, ["erlang", "iolist_to_binary"]) == [1]
    assert get_in(wrapped, ["erlang", "list_to_binary"]) == [1]
    refute Map.has_key?(wrapped, "fs")
    refute Map.has_key?(wrapped, "webfs")
    assert get_in(wrapped, ["io_lib", "bformat"]) == [2, 3]
    assert get_in(wrapped, ["io_lib", "bfwrite"]) == [2, 3]
    assert get_in(wrapped, ["io_lib", "build_text"]) == [1, 2]
    assert get_in(wrapped, ["io_lib", "format"]) == [2, 3]
    assert get_in(wrapped, ["io_lib", "fwrite"]) == [2, 3]
    assert get_in(wrapped, ["re", "run"]) == [2, 3]
    assert get_in(wrapped, ["re", "replace"]) == [3, 4]
    assert get_in(wrapped, ["re", "split"]) == [2, 3]
    assert get_in(wrapped, ["unicode", "characters_to_binary"]) == [1, 2, 3]
    assert get_in(wrapped, ["unicode", "characters_to_list"]) == [1, 2]
    assert get_in(wrapped, ["string", "lowercase"]) == [1]
    assert get_in(wrapped, ["string", "uppercase"]) == [1]
    assert get_in(wrapped, ["string", "casefold"]) == [1]
    assert get_in(wrapped, ["string", "titlecase"]) == [1]
    assert get_in(wrapped, ["string", "copies"]) == [2]
    assert get_in(wrapped, ["string", "chars"]) == [2, 3]
    assert get_in(wrapped, ["string", "pad"]) == [2, 3, 4]
    assert get_in(wrapped, ["string", "join"]) == [2]
    assert get_in(wrapped, ["string", "lexemes"]) == [2]
    assert get_in(wrapped, ["string", "replace"]) == [3, 4]
    assert get_in(wrapped, ["string", "split"]) == [2, 3]
    assert get_in(wrapped, ["string", "reverse"]) == [1]
    assert get_in(wrapped, ["string", "to_graphemes"]) == [1]
    assert get_in(wrapped, ["string", "tokens"]) == [2]

    assert Hyperlang.Stdlib.nondeterministic?("erlang", "system_time", 0)
    assert Hyperlang.Stdlib.nondeterministic?("erlang", "system_time", 1)
    assert Hyperlang.Stdlib.nondeterministic?("rand", "mwc59_seed", 0)
    refute Map.has_key?(direct, "ets")
    assert Hyperlang.Stdlib.call_target("binary", "compile_pattern", 1) == :error
    assert Hyperlang.Stdlib.call_target("erlang", "atom_to_list", 1) == :error
    assert Hyperlang.Stdlib.call_target("io_lib", "write_atom", 1) == :error
    assert Hyperlang.Stdlib.call_target("json", "encode_atom", 2) == :error
    assert Hyperlang.Stdlib.call_target("rand", "seed_s", 1) == :error
    assert Hyperlang.Stdlib.call_target("rand", "seed_s", 2) == :error
    refute Map.has_key?(direct, "records")
    refute Map.has_key?(direct, "io_ansi")
    assert Hyperlang.Stdlib.call_target("array", "upgrade", 1) == :error
    assert Hyperlang.Stdlib.call_target("zstd", "compress", 1) == :error
    assert Hyperlang.Stdlib.call_target("zstd", "decompress", 1) == :error
    assert Hyperlang.Stdlib.call_target("unicode", "characters_to_nfc_binary", 1) == :error
    assert Hyperlang.Stdlib.call_target("unicode", "characters_to_binary_int", 2) == :error
    assert Hyperlang.Stdlib.call_target("unicode_util", "uppercase", 1) == :error
    assert Hyperlang.Stdlib.call_target("unicode_util", "nfc", 1) == :error
    assert 2 in (get_in(direct, ["array", "append"]) || [])
    assert 1 in (get_in(direct, ["gb_trees", "from_list"]) || [])
    assert 0 in (get_in(direct, ["graph", "new"]) || [])
    assert 4 in (get_in(direct, ["graph", "add_edge"]) || [])
    assert 1 in (get_in(direct, ["unicode", "category"]) || [])
    assert 0 in (get_in(direct, ["unicode_util", "pattern_whitespace"]) || [])
    assert 2 in (get_in(direct, ["lists", "map"]) || [])
    assert 2 in (get_in(direct, ["erlang", "is_record"]) || [])
    assert Hyperlang.Stdlib.call_target("timer", "sleep", 1) == :error
    # re:compile moved to the wrapped matrix (bounded pattern-size proxy);
    # the handle-API stays rejected.
    assert get_in(wrapped, ["re", "compile"]) == [1, 2]
    assert Hyperlang.Stdlib.call_target("re", "ucompile", 2) == :error
    refute Map.has_key?(direct, "argparse")
    refute 1 in (get_in(direct, ["erlang", "atom_to_binary"]) || [])

    assert Hyperlang.Stdlib.call_target("erlang", "atom_to_binary", 1) ==
             {:wrapped, :erlang, :atom_to_binary}

    refute 1 in (get_in(direct, ["base64", "encode"]) || [])

    assert Hyperlang.Stdlib.call_target("base64", "encode", 1) ==
             {:wrapped, :base64, :encode}

    refute 1 in (get_in(direct, ["base64", "decode"]) || [])

    assert Hyperlang.Stdlib.call_target("base64", "decode", 1) ==
             {:wrapped, :base64, :decode}

    refute 1 in (get_in(direct, ["base64", "encode_to_string"]) || [])

    assert Hyperlang.Stdlib.call_target("base64", "encode_to_string", 1) ==
             {:wrapped, :base64, :encode_to_string}

    refute 1 in (get_in(direct, ["base64", "decode_to_string"]) || [])

    assert Hyperlang.Stdlib.call_target("base64", "decode_to_string", 1) ==
             {:wrapped, :base64, :decode_to_string}

    refute 1 in (get_in(direct, ["unicode", "characters_to_binary"]) || [])

    assert Hyperlang.Stdlib.call_target("unicode", "characters_to_binary", 1) ==
             {:wrapped, :unicode, :characters_to_binary}

    refute 1 in (get_in(direct, ["unicode", "characters_to_list"]) || [])

    assert Hyperlang.Stdlib.call_target("unicode", "characters_to_list", 1) ==
             {:wrapped, :unicode, :characters_to_list}

    refute 1 in (get_in(direct, ["string", "uppercase"]) || [])

    assert Hyperlang.Stdlib.call_target("string", "uppercase", 1) ==
             {:wrapped, :string, :uppercase}

    refute 1 in (get_in(direct, ["string", "lowercase"]) || [])

    assert Hyperlang.Stdlib.call_target("string", "lowercase", 1) ==
             {:wrapped, :string, :lowercase}

    refute 2 in (get_in(direct, ["string", "copies"]) || [])

    assert Hyperlang.Stdlib.call_target("string", "copies", 2) ==
             {:wrapped, :string, :copies}

    refute 2 in (get_in(direct, ["string", "pad"]) || [])

    assert Hyperlang.Stdlib.call_target("string", "pad", 2) ==
             {:wrapped, :string, :pad}

    refute 3 in (get_in(direct, ["string", "split"]) || [])

    assert Hyperlang.Stdlib.call_target("string", "split", 3) ==
             {:wrapped, :string, :split}

    refute 4 in (get_in(direct, ["string", "replace"]) || [])

    assert Hyperlang.Stdlib.call_target("string", "replace", 4) ==
             {:wrapped, :string, :replace}

    refute 1 in (get_in(direct, ["string", "reverse"]) || [])

    assert Hyperlang.Stdlib.call_target("string", "reverse", 1) ==
             {:wrapped, :string, :reverse}

    refute 1 in (get_in(direct, ["string", "to_graphemes"]) || [])

    assert Hyperlang.Stdlib.call_target("string", "to_graphemes", 1) ==
             {:wrapped, :string, :to_graphemes}

    refute 1 in (get_in(direct, ["io_lib", "build_text"]) || [])

    assert Hyperlang.Stdlib.call_target("io_lib", "build_text", 1) ==
             {:wrapped, :io_lib, :build_text}

    refute 2 in (get_in(direct, ["io_lib", "format"]) || [])

    assert Hyperlang.Stdlib.call_target("io_lib", "format", 2) ==
             {:wrapped, :io_lib, :format}

    refute 2 in (get_in(direct, ["binary", "copy"]) || [])

    assert Hyperlang.Stdlib.call_target("binary", "copy", 2) ==
             {:wrapped, :binary, :copy}

    refute 1 in (get_in(direct, ["binary", "bin_to_list"]) || [])

    assert Hyperlang.Stdlib.call_target("binary", "bin_to_list", 1) ==
             {:wrapped, :binary, :bin_to_list}

    refute 1 in (get_in(direct, ["binary", "list_to_bin"]) || [])

    assert Hyperlang.Stdlib.call_target("binary", "list_to_bin", 1) ==
             {:wrapped, :binary, :list_to_bin}

    refute 2 in (get_in(direct, ["binary", "join"]) || [])

    assert Hyperlang.Stdlib.call_target("binary", "join", 2) ==
             {:wrapped, :binary, :join}

    refute 1 in (get_in(direct, ["binary", "encode_hex"]) || [])

    assert Hyperlang.Stdlib.call_target("binary", "encode_hex", 1) ==
             {:wrapped, :binary, :encode_hex}

    refute 1 in (get_in(direct, ["binary", "decode_unsigned"]) || [])

    assert Hyperlang.Stdlib.call_target("binary", "decode_unsigned", 1) ==
             {:wrapped, :binary, :decode_unsigned}

    refute 1 in (get_in(direct, ["binary", "encode_unsigned"]) || [])

    assert Hyperlang.Stdlib.call_target("binary", "encode_unsigned", 1) ==
             {:wrapped, :binary, :encode_unsigned}

    refute 3 in (get_in(direct, ["binary", "split"]) || [])

    assert Hyperlang.Stdlib.call_target("binary", "split", 3) ==
             {:wrapped, :binary, :split}

    refute 4 in (get_in(direct, ["binary", "replace"]) || [])

    assert Hyperlang.Stdlib.call_target("binary", "replace", 4) ==
             {:wrapped, :binary, :replace}

    refute 2 in (get_in(direct, ["binary", "matches"]) || [])

    assert Hyperlang.Stdlib.call_target("binary", "matches", 2) ==
             {:wrapped, :binary, :matches}

    refute 2 in (get_in(direct, ["string", "tokens"]) || [])

    assert Hyperlang.Stdlib.call_target("string", "tokens", 2) ==
             {:wrapped, :string, :tokens}

    refute 2 in (get_in(direct, ["string", "lexemes"]) || [])

    assert Hyperlang.Stdlib.call_target("string", "lexemes", 2) ==
             {:wrapped, :string, :lexemes}

    refute 1 in (get_in(direct, ["erlang", "iolist_to_binary"]) || [])

    assert Hyperlang.Stdlib.call_target("erlang", "iolist_to_binary", 1) ==
             {:wrapped, :erlang, :iolist_to_binary}

    refute 1 in (get_in(direct, ["erlang", "list_to_binary"]) || [])

    assert Hyperlang.Stdlib.call_target("erlang", "list_to_binary", 1) ==
             {:wrapped, :erlang, :list_to_binary}

    refute 1 in (get_in(direct, ["binary", "compile_pattern"]) || [])
    refute 2 in (get_in(direct, ["re", "run"]) || [])

    assert Hyperlang.Stdlib.call_target("re", "run", 2) ==
             {:wrapped, :re, :run}

    refute 1 in (get_in(direct, ["re", "compile"]) || [])
  end

  test "zstd compression calls are rejected until a bounded implementation exists" do
    for source <- [
          ~S|zstd:compress(<<"abc">>).|,
          ~S|zstd:compress(<<"abc">>, []).|,
          ~S|zstd:decompress(<<"abc">>).|,
          ~S|zstd:decompress(<<"abc">>, []).|
        ] do
      assert {:error, [%{category: :verify}]} =
               Hyperlang.Test.program(source, erlang_public())
    end
  end

  test "unicode normalization helpers are rejected until bounded wrappers exist" do
    for source <- [
          ~S|unicode:characters_to_nfc_binary("abc").|,
          ~S|unicode:characters_to_nfd_list("abc").|,
          ~S|unicode:characters_to_nfkc_binary("abc").|,
          ~S|unicode:characters_to_nfkd_list("abc").|,
          ~S|unicode:characters_to_binary_int("abc", unicode).|,
          ~S|unicode:characters_to_list_int("abc", unicode).|,
          ~S|unicode_util:uppercase($a).|,
          ~S|unicode_util:casefold($A).|,
          ~S|unicode_util:nfc($a).|,
          ~S|unicode_util:nfkd($a).|
        ] do
      assert {:error, [%{category: :verify}]} =
               Hyperlang.Test.program(source, erlang_public())
    end
  end

  test "supports broader OTP data modules without Hyperlang stdlib wrappers" do
    source = ~S"""
    {{value, QueueHead}, QueueRest} = queue:out(queue:in(<<"first">>, queue:new())),
    {empty, EmptyQueue} = queue:out(queue:new()),
    G0 = graph:new(),
    G1 = graph:add_vertex(graph:add_vertex(graph:add_vertex(G0, a), b), c),
    G = graph:add_edge(graph:add_edge(G1, a, b), b, c),
    A = array:from_list([1, 2, 3]),
    A2 = array:append(4, array:prepend(0, A)),
    {A3, ArraySum} = array:mapfoldl(fun(_I, V, Acc) -> {V + 1, Acc + V} end, 0, A),
    {
      base64:decode(base64:encode(<<"abc">>)),
      proplists:get_value(a, [{a, 1}], none),
      queue:to_list(queue:in(3, queue:from_list([1, 2]))),
      {QueueHead, QueueRest, EmptyQueue},
      ordsets:union(ordsets:from_list([b, a]), ordsets:from_list([c])),
      gb_sets:to_list(gb_sets:add(3, gb_sets:from_list([1, 2]))),
      lists:sort(sets:to_list(sets:from_list([c, a, b]))),
      gb_trees:to_list(gb_trees:insert(b, 2, gb_trees:insert(a, 1, gb_trees:empty()))),
      gb_trees:to_list(gb_trees:from_list([{b, 2}, {a, 1}, {b, 3}])),
      {graph:has_path(G, a, c), graph:no_edges(G), graph:topsort(G)},
      {
        array:to_list(array:slice(1, 3, A2)),
        array:foldl(1, 2, fun(_I, V, Acc) -> Acc + V end, 0, A),
        array:to_list(array:from(fun(0) -> {10, 1}; (1) -> {20, 2}; (2) -> done end, 0)),
        array:to_list(A3),
        ArraySum
      },
      {
        unicode:is_id_start($a),
        unicode:is_id_continue($_),
        unicode:is_whitespace($\s),
        unicode:category($a),
        unicode_util:category($a),
        unicode_util:is_other_id_start(8472),
        unicode_util:is_other_id_continue(183),
        unicode_util:is_letter_not_pattern_syntax($a),
        length(unicode_util:pattern_whitespace()) > 0
      },
      timer:hms(1, 2, 3)
    }.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          terms: %{
            allowed_atoms: [:a, :b, :c, :done, :letter, :lowercase, :none]
          }
        })
      )

    assert eval(instance, nil) ==
             {:ok,
              {"abc", 1, [1, 2, 3], {"first", {[], []}, {[], []}}, [:a, :b, :c], [1, 2, 3],
               [:a, :b, :c], [a: 1, b: 2], [a: 1, b: 3], {true, 2, [:a, :b, :c]},
               {[1, 2, 3], 5, [10, 20], [2, 3, 4], 6},
               {true, true, true, {:letter, :lowercase}, {:letter, :lowercase}, true, true, true,
                true}, 3_723_000}}

    assert {:error, [%{category: :verify}]} =
             Hyperlang.Test.program("safe_std:repr({ok, Input}).", erlang_public())
  end

  test "regex coverage includes wrapped OTP re calls" do
    source = ~S"""
    {
      re:run(<<"abc">>, <<"b">>),
      re:run(<<"abc123">>, <<"([a-z]+)([0-9]+)">>, [{capture, all, binary}]),
      re:split(<<"a,b,c">>, <<",">>, [trim]),
      re:replace(<<"banana">>, <<"a">>, <<"x">>, [global, {return, binary}])
    }.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          terms: %{allowed_atoms: [:all, :binary, :capture, :global, :match, :ok, :return, :trim]}
        })
      )

    expected_direct_run = :re.run("abc123", "([a-z]+)([0-9]+)", [{:capture, :all, :binary}])

    assert eval(instance, nil) ==
             {:ok, {:re.run("abc", "b"), expected_direct_run, ["a", "b", "c"], "bxnxnx"}}

    assert {:error, [%{category: :verify}]} =
             Hyperlang.Test.program(
               ~S|safe_std:regex_search(<<"a">>, <<"a">>).|,
               erlang_public()
             )

    assert {:ok, _program} =
             Hyperlang.Test.program(~S|re:compile(<<"a">>).|, erlang_public())

    # The handle-API rejects stay rejected.
    assert {:error, [%{category: :verify}]} =
             Hyperlang.Test.program(~S|re:ucompile(<<"a">>, []).|, erlang_public())
  end

  test "regex runtime caps override guest supplied match limit options" do
    source = ~S"""
    {
      re:run(<<"abc">>, <<"a">>, [{match_limit, bad}, {match_limit_recursion, bad}, {capture, none}]),
      re:split(<<"a,b">>, <<",">>, [{match_limit, bad}, {return, binary}]),
      re:replace(<<"a,b">>, <<",">>, <<";">>, [{match_limit_recursion, bad}, {return, binary}])
    }.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{terms: %{allowed_atoms: [:match]}})
      )

    assert eval(instance, nil) == {:ok, {:match, ["a", "b"], "a;b"}}
  end

  test "regex wrapper rejects oversized generated subject pattern and replacement" do
    for source <- [
          ~S"""
          Subject = << <<X>> || X <- [97, 98, 99, 100, 101] >>,
          re:run(Subject, <<"a">>).
          """,
          ~S"""
          Pattern = << <<X>> || X <- [97, 98, 99, 100, 101] >>,
          re:run(<<"a">>, Pattern).
          """,
          ~S"""
          Replacement = << <<X>> || X <- [97, 98, 99, 100, 101] >>,
          re:replace(<<"a">>, <<"a">>, Replacement, [{return, binary}]).
          """
        ] do
      {_program, instance} =
        compile_and_instance(
          source,
          erlang_public(%{
            limits: %{max_binary_bytes: 4},
            terms: %{allowed_atoms: [:match, :return, :binary]}
          })
        )

      error = eval(instance, nil) |> assert_eval_error(:stdlib)

      reason =
        case get_in(error, [:details, "error"]) do
          %{"reason" => reason} -> reason
          %{reason: reason} -> reason
          reason -> reason
        end

      assert reason == "binary_bytes"
    end
  end

  test "regex run rejects named-group capture that would create VM atoms" do
    group = "hyperlang_re_group_#{System.unique_integer([:positive])}"
    refute existing_atom?(group)

    source =
      ~s|re:run(<<"a">>, <<"(?<#{group}>a)">>, [{capture, all_names, binary}]).|

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{terms: %{allowed_atoms: [:all_names, :binary, :capture]}})
      )

    error = eval(instance, nil) |> assert_eval_error(:stdlib)

    assert get_in(error, [:details, "error"]) == "unsupported_re_capture_all_names"
    refute existing_atom?(group)
  end

  test "deterministic calendar and rand helpers stay available by default" do
    source = """
    {
      calendar:valid_date(2026, 5, 14),
      calendar:day_of_the_week({2026, 5, 14}),
      calendar:date_to_gregorian_days({1970, 1, 1}),
      calendar:gregorian_days_to_date(719528),
      calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}}),
      calendar:gregorian_seconds_to_datetime(62167219200),
      calendar:seconds_to_time(3661),
      calendar:time_to_seconds({1, 1, 1}),
      calendar:system_time_to_universal_time(0, second),
      calendar:system_time_to_rfc3339(0, [{unit, second}, {offset, "Z"}]),
      calendar:rfc3339_to_system_time("1970-01-01T00:00:00Z", [{unit, second}]),
      calendar:iso_week_number({2026, 5, 14}),
      integer_to_binary(1024)
    }.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{terms: %{allowed_atoms: [:exsss, :second, :unit]}})
      )

    expected_rfc3339 = ~c"1970-01-01T00:00:00Z"

    assert {:ok,
            {
              true,
              4,
              719_528,
              {1970, 1, 1},
              62_167_219_200,
              {{1970, 1, 1}, {0, 0, 0}},
              {1, 1, 1},
              3661,
              {{1970, 1, 1}, {0, 0, 0}},
              ^expected_rfc3339,
              0,
              {2026, _iso_week},
              "1024"
            }} = eval(instance, nil)
  end

  test "live clocks and entropy require the nondeterminism capability" do
    manifest = erlang_public(%{terms: %{allowed_atoms: [:exsss]}})

    for source <- [
          "calendar:universal_time().",
          "calendar:local_time().",
          "calendar:iso_week_number().",
          "calendar:system_time_to_local_time(0, second).",
          "calendar:local_time_to_system_time({{1970,1,1},{0,0,0}}, [{unit, second}]).",
          "calendar:local_time_to_universal_time({{1970,1,1},{0,0,0}}).",
          "calendar:local_time_to_universal_time_dst({{1970,1,1},{0,0,0}}).",
          "calendar:now_to_local_time({0,0,0}).",
          "calendar:universal_time_to_local_time({{1970,1,1},{0,0,0}}).",
          "erlang:system_time().",
          "erlang:system_time(millisecond).",
          "erlang:monotonic_time().",
          "erlang:monotonic_time(millisecond).",
          "erlang:time_offset().",
          "erlang:time_offset(millisecond).",
          "erlang:timestamp().",
          "erlang:date().",
          "erlang:time().",
          "erlang:universaltime().",
          "erlang:localtime().",
          "erlang:universaltime_to_localtime({{1970,1,1},{0,0,0}}).",
          "erlang:localtime_to_universaltime({{1970,1,1},{0,0,0}}).",
          "erlang:localtime_to_universaltime({{1970,1,1},{0,0,0}}, true).",
          "rand:seed_s(exsss).",
          "rand:seed_s(exsss, {1, 2, 3}).",
          "rand:mwc59_seed()."
        ] do
      assert {:error, [%{category: :verify}]} = Hyperlang.Test.program(source, manifest)
    end

    nondeterministic_manifest =
      erlang_public(%{
        capabilities: [:nondeterminism],
        terms: %{allowed_atoms: [:exsss]}
      })

    source = """
    {
      is_integer(erlang:system_time()),
      is_integer(erlang:system_time(millisecond)),
      is_integer(erlang:monotonic_time()),
      is_integer(erlang:monotonic_time(millisecond)),
      is_integer(erlang:time_offset()),
      is_integer(erlang:time_offset(millisecond)),
      tuple_size(erlang:timestamp()),
      tuple_size(erlang:date()),
      tuple_size(erlang:time()),
      tuple_size(erlang:universaltime()),
      tuple_size(erlang:localtime()),
      tuple_size(calendar:universal_time()),
      tuple_size(calendar:local_time()),
      tuple_size(calendar:iso_week_number()),
      tuple_size(calendar:system_time_to_local_time(0, second)),
      is_integer(calendar:local_time_to_system_time({{1970,1,1},{0,0,0}}, [{unit, second}])),
      tuple_size(calendar:local_time_to_universal_time({{1970,1,1},{0,0,0}})),
      is_list(calendar:local_time_to_universal_time_dst({{1970,1,1},{0,0,0}})),
      tuple_size(calendar:now_to_local_time({0,0,0})),
      tuple_size(calendar:universal_time_to_local_time({{1970,1,1},{0,0,0}})),
      tuple_size(erlang:universaltime_to_localtime({{1970,1,1},{0,0,0}})),
      tuple_size(erlang:localtime_to_universaltime({{1970,1,1},{0,0,0}})),
      tuple_size(erlang:localtime_to_universaltime({{1970,1,1},{0,0,0}}, true)),
      is_integer(rand:mwc59_seed())
    }.
    """

    {_program, instance} = compile_and_instance(source, nondeterministic_manifest)

    assert eval(instance, nil) ==
             {:ok,
              {true, true, true, true, true, true, 3, 3, 3, 2, 2, 2, 2, 2, 2, true, 2, true, 2, 2,
               2, 2, 2, true}}

    assert {:error, [%{category: :verify}]} =
             Hyperlang.Test.program("rand:seed_s(exsss).", nondeterministic_manifest)

    assert {:error, [%{category: :verify}]} =
             Hyperlang.Test.program(
               "rand:seed_s(exsss, {1, 2, 3}).",
               nondeterministic_manifest
             )

    assert {:ok, _program} =
             Hyperlang.Test.program("rand:mwc59_seed().", nondeterministic_manifest)

    assert {:error, [%{category: :verify}]} =
             Hyperlang.Test.program("clock:now_ms().", %{})

    assert {:error, [%{category: :verify}]} =
             Hyperlang.Test.program("safe_std:date(2026, 5, 14).", erlang_public())

    assert {:error, [%{category: :verify}]} =
             Hyperlang.Test.program(
               "safe_std:datetime(2026, 5, 14, 9, 8, 7).",
               erlang_public()
             )

    assert {:error, [%{category: :verify}]} =
             Hyperlang.Test.program("safe_std:timedelta(1, 2, 3).", erlang_public())

    assert {:error, [%{category: :verify}]} =
             Hyperlang.Test.program("safe_std:timezone_offset(10, 30).", erlang_public())

    assert {:error, [%{category: :verify}]} =
             Hyperlang.Test.program(
               ~S|safe_std:date_from_iso(<<"2026-05-14">>).|,
               erlang_public()
             )

    assert {:error, [%{category: :verify}]} =
             Hyperlang.Test.program(
               ~S|safe_std:datetime_to_iso({{2026, 5, 14}, {9, 8, 7}}).|,
               erlang_public()
             )

    {_program, instance} =
      compile_and_instance("clock:now_ms().", erlang_public(), %{
        "clock" => %{now_ms: fn -> 123 end}
      })

    assert eval(instance, nil) == {:ok, 123}
  end

  test "container coverage uses direct OTP containers and callbacks" do
    source = """
    {
      length([a, b, c]),
      lists:seq(0, 4),
      lists:seq(2, 5),
      lists:seq(6, 2, -2),
      maps:to_list(\#{a => 1}),
      maps:from_list([{a, 1}, {b, 2}]),
      lists:enumerate([a, b]),
      lists:zip([a, b], [1, 2]),
      lists:reverse([1, 2, 3]),
      lists:sort([3, 1, 2]),
      queue:to_list(queue:in(third, queue:from_list([first, second]))),
      ordsets:to_list(ordsets:from_list([b, a, c])),
      lists:uniq([a, b, a, c, b])
    }.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{terms: %{allowed_atoms: [:a, :b, :c, :default, :first, :second, :third]}})
      )

    assert eval(instance, nil) ==
             {:ok,
              {
                3,
                [0, 1, 2, 3, 4],
                [2, 3, 4, 5],
                [6, 4, 2],
                [a: 1],
                %{a: 1, b: 2},
                [{1, :a}, {2, :b}],
                [{:a, 1}, {:b, 2}],
                [3, 2, 1],
                [1, 2, 3],
                [:first, :second, :third],
                [:a, :b, :c],
                [:a, :b, :c]
              }}

    {_program, instance} =
      compile_and_instance("lists:filter(fun(X) -> X > 1 end, [1, 2, 3]).", erlang_public())

    assert eval(instance, nil) == {:ok, [2, 3]}

    {_program, instance} =
      compile_and_instance("lists:seq(1, 10).", %{limits: %{max_list_length: 3}})

    error = eval(instance, nil) |> assert_eval_error(:stdlib)
    assert inspect(error) =~ "list_length"

    assert {:error, [%{category: :verify}]} =
             Hyperlang.Test.program("safe_std:next([first], default).", erlang_public())

    assert {:error, [%{category: :verify}]} =
             Hyperlang.Test.program("safe_std:zip([a], [1], [x]).", erlang_public())

    assert {:error, [%{category: :verify}]} =
             Hyperlang.Test.program(
               "safe_std:map(fun(X) -> X end, [1]).",
               erlang_public()
             )

    assert {:error, [%{category: :verify}]} =
             Hyperlang.Test.program(
               "safe_std:filter(fun(X) -> true end, [1]).",
               erlang_public()
             )
  end

  test "sys exits requires sys capability" do
    source = """
    -module(exitcmd).
    -export([main/1]).

    main(_Args) ->
      sys:exits(<<"nope">>).
    """

    assert {:error, [%{category: :verify}]} =
             Hyperlang.Test.program(source, erlang_public(%{entry: %{function: "main"}}))
  end

  test "worker wall timeout kills runaway guest code" do
    source = """
    result(Input) -> loop(Input).
    loop(X) -> loop(X).
    """

    {_program, instance} = compile_and_instance(source, %{}, %{}, %{limits: %{wall_ms: 10}})
    assert {:error, error} = eval(instance, 1)
    assert error_category(error) in [:timeout, :sandbox_crash, :reduction_watchdog]

    refute_receive {:DOWN, _monitor, :process, _pid, :killed}, 50
  end

  test "run_in_caller owner survives completed and expired short wall deadlines" do
    source = """
    -module(deadlinecmd).
    -export([main/1]).

    main(_Args) ->
      sys:sleep(1),
      ok.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          entry: %{function: "main"},
          sys: %{enabled: true},
          limits: %{wall_ms: 5, max_reductions: nil}
        })
      )

    parent = self()

    owner =
      spawn(fn ->
        results =
          Enum.map(1..50, fn _ ->
            run_instance(instance, [<<"deadlinecmd">>], run_in_caller?: true, wall_timeout: 5)
          end)

        send(parent, {:deadline_owner_done, self(), results})

        receive do
          :stop -> :ok
        end
      end)

    monitor = Process.monitor(owner)

    assert_receive {:deadline_owner_done, ^owner, results}, 5_000

    assert Enum.all?(results, fn
             {:ok, :ok, %{stdout: []}} -> true
             {:error, %{category: :timeout, message: "wall_ms"}} -> true
             _ -> false
           end)

    refute_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 100

    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 1_000
  end

  test "tagged reduction watchdog still reports max reductions" do
    source = """
    result(Input) -> loop(Input).
    loop(X) -> loop(X).
    """

    {_program, instance} =
      compile_and_instance(source, %{}, %{}, %{limits: %{max_reductions: 1_000, wall_ms: 500}})

    assert {:error, error} = eval(instance, 1)
    assert error_category(error) == :reduction_watchdog
    assert error_reason(error) == "max_reductions"
  end

  test "worker wall timeout override is honored in child and caller modes" do
    source = """
    -module(sleepcmd).
    -export([main/1]).

    main(_Args) ->
      sys:sleep(40),
      ok.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          entry: %{function: "main"},
          sys: %{enabled: true},
          limits: %{wall_ms: 10, max_reductions: nil}
        })
      )

    assert {:ok, :ok, _} =
             run_instance(instance, [<<"sleepcmd">>], wall_timeout: :infinity)

    assert {:ok, :ok, _} =
             run_instance(instance, [<<"sleepcmd">>],
               run_in_caller?: true,
               wall_timeout: :infinity
             )
  end

  test "manifest wall_ms infinity is honored in child and caller modes" do
    source = """
    -module(sleepcmd).
    -export([main/1]).

    main(_Args) ->
      sys:sleep(30),
      ok.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          entry: %{function: "main"},
          sys: %{enabled: true},
          limits: %{wall_ms: :infinity, max_reductions: nil}
        })
      )

    assert {:ok, :ok, _} = run_instance(instance, [<<"sleepcmd">>])

    assert {:ok, :ok, _} =
             run_instance(instance, [<<"sleepcmd">>], run_in_caller?: true)
  end

  test "runtime errors map guest stack frames and hide host frames" do
    source = """
    result(Input) -> helper(Input).
    helper(0) -> 1 div 0;
    helper(Input) -> Input.
    """

    {_program, instance} = compile_and_instance(source)

    assert {:error, error} = eval(instance, 0)
    stack = Map.fetch!(error.details, "stack")

    assert Enum.any?(stack, &(&1["module"] == "guest" and &1["function"] == "helper"))
    assert Enum.any?(stack, &(&1["module"] == "guest" and &1["function"] == "result"))

    helper = Enum.find(stack, &(&1["function"] == "helper"))
    assert helper["span"] == %{"line" => 2, "col" => 1}

    refute Enum.any?(stack, fn frame ->
             module = to_string(frame["module"])

             String.starts_with?(module, "hyperlang_slot_") or
               String.starts_with?(module, "Hyperlang.")
           end)
  end

  test "guest try catch stack variable is sanitized to empty list" do
    source = """
    result(_) ->
      try case a of b -> 1 end
      catch error:{case_clause, a}:S ->
        {S, erlang:phash2(S)}
      end.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{terms: %{allowed_atoms: [:a, :b, :case_clause]}})
      )

    assert eval(instance, nil) == {:ok, {[], :erlang.phash2([])}}

    assert {:error, [%{category: :verify, message: message}]} =
             Hyperlang.Test.program(
               """
               result(_) ->
                 try case a of b -> 1 end
                 catch error:{case_clause, a}:S when is_list(S) -> ok
                 end.
               """,
               %{terms: %{allowed_atoms: [:a, :b, :case_clause]}}
             )

    assert message =~ "stack variables are not available in guards"
  end

  test "try of catch follows Erlang protection boundary" do
    source = """
    result(Input) ->
      case Input of
        body_error ->
          try 1 div 0 of X -> X catch error:badarith -> caught end;
        of_mismatch ->
          try 1 of 2 -> matched catch error:{try_clause, 1} -> caught end;
        of_body_error ->
          try 1 of X -> X div 0 catch error:badarith -> caught end
      end.
    """

    {_program, instance} =
      compile_and_instance(
        source,
        erlang_public(%{
          terms: %{
            allowed_atoms: [
              :badarith,
              :body_error,
              :caught,
              :matched,
              :of_body_error,
              :of_mismatch,
              :try_clause
            ]
          }
        })
      )

    assert eval(instance, :body_error) == {:ok, :caught}

    assert {:error, mismatch_error} = eval(instance, :of_mismatch)
    assert error_category(mismatch_error) == :runtime
    assert inspect(error_reason(mismatch_error)) =~ "TryClauseError"

    assert {:error, body_error} = eval(instance, :of_body_error)
    assert error_category(body_error) == :runtime
    assert inspect(error_reason(body_error)) =~ "ArithmeticError"
  end

  test "public fault categories are closed and documented" do
    categories = Hyperlang.Fault.public_categories()
    assert categories == Enum.uniq(categories)

    doc = File.read!(@security_spec_doc)

    for category <- categories do
      assert Hyperlang.Fault.public_category?(category)
      assert Hyperlang.Fault.public_category?(Atom.to_string(category))
      assert doc =~ "`#{category}`"
    end

    for category <- Hyperlang.Fault.internal_boundary_categories() do
      assert Hyperlang.Fault.internal_boundary_category?(category)
      refute Hyperlang.Fault.public_category?(category)
    end

    assert Hyperlang.Fault.public_category(:unknown_guest_fault) == :internal
    assert Hyperlang.Fault.public_category("unknown_guest_fault") == :internal
  end

  test "error sanitizer maps unknown primary categories to internal" do
    error =
      Hyperlang.Terms.sanitize_error(%{
        category: :filesystem_args,
        reason: {:bad, self(), make_ref(), fn -> :ok end}
      })

    assert error.category == :internal
    assert error.details["reason"] == "unknown_fault_category"

    encoded = inspect(error)
    refute encoded =~ "#PID"
    refute encoded =~ "#Reference"
    refute encoded =~ "#Fun"
  end

  test "eval and export faults use the closed taxonomy and redact unsafe internals" do
    manifest =
      erlang_public(%{
        exports: %{
          functions: %{
            "boom" => %{function: "boom", arity: 0}
          }
        }
      })

    source = """
    result(_) -> fun(X) -> X end.
    boom() -> 1 div 0.
    """

    {_program, instance} = compile_and_instance(source, manifest)

    failures = [
      run_instance(instance, self()),
      run_instance(instance, :ok),
      run_instance_export(instance, "boom", []),
      run_instance_export(instance, "missing", []),
      run_instance_export(instance, "boom", [1])
    ]

    for result <- failures do
      assert {:error, error} = result
      assert Hyperlang.Fault.public_category?(error_category(error))
      refute_public_error_leaks(error)
    end

    raw =
      Hyperlang.Terms.sanitize_error(%{
        category: :sandbox_crash,
        reason: {:shutdown, self(), make_ref(), fn -> :ok end},
        stack: [{:hyperlang_slot_000001, :safe_f_0, 1, []}]
      })

    assert raw.category == :sandbox_crash
    refute_public_error_leaks(raw)
  end

  defp refute_public_error_leaks(term) do
    encoded = inspect(term)

    for denied <- [
          "#PID",
          "#Reference",
          "#Fun",
          "hyperlang_slot",
          "safe_f_",
          "$safe_entry",
          "$safe_export"
        ] do
      refute encoded =~ denied
    end
  end

  test "guest try catch cannot swallow external resource kills" do
    source = """
    result(Input) -> try loop(Input) catch _:_ -> ok end.
    loop(X) -> loop(X).
    """

    {_program, instance} = compile_and_instance(source, %{}, %{}, %{limits: %{wall_ms: 10}})
    assert {:error, error} = eval(instance, 1)
    assert error_category(error) in [:timeout, :sandbox_crash, :reduction_watchdog]

    {_program, instance} =
      compile_and_instance(source, %{}, %{}, %{limits: %{max_reductions: 1_000, wall_ms: 500}})

    assert {:error, error} = eval(instance, 1)
    assert error_category(error) == :reduction_watchdog

    source = """
    result(Input) -> try grow(Input) catch _:_ -> ok end.
    grow(X) -> grow([X,X,X,X,X,X,X,X,X,X]).
    """

    {_program, instance} =
      compile_and_instance(source, %{}, %{}, %{limits: %{heap_words: 20_000, wall_ms: 500}})

    assert {:error, error} = eval(instance, 1)
    assert error_category(error) == :heap

    {_program, instance} =
      compile_and_instance(source, %{}, %{}, %{
        limits: %{heap_words: 20_000, max_reductions: 1_000_000_000, wall_ms: 500}
      })

    assert {:error, error} = eval(instance, 1)
    assert error_category(error) == :heap
  end

  test "CodeServer compile options hash is memoized on warm reads" do
    hash = Hyperlang.CodeServer.compile_options_hash()
    traced = [{Hyperlang.CodeServer, :put_compile_options_hash!, 1}]

    {^hash, calls} =
      capture_trace_calls(traced, fn ->
        Hyperlang.CodeServer.compile_options_hash()
      end)

    refute {Hyperlang.CodeServer, :put_compile_options_hash!, 1} in calls
  end

  test "program cache distinguishes source and manifest identity" do
    manifest = erlang_public()
    source1 = "main(Input) -> Input + 1.\nresult(Input) -> Input + 1.\n"
    source2 = "main(Input) -> Input + 2.\nresult(Input) -> Input + 2.\n"

    {:ok, program1} = Hyperlang.Test.program(source1, manifest)
    {:ok, program2} = Hyperlang.Test.program(source1, manifest)
    {:ok, program3} = Hyperlang.Test.program(source2, manifest)

    {:ok, program4} =
      Hyperlang.Test.program(source1, erlang_public(%{result: %{name: "main"}}))

    assert program1.content_hash == program2.content_hash
    refute program1.content_hash == program3.content_hash
    refute program1.content_hash == program4.content_hash

    instance1 = {program1, [bindings: %{}, policy: %{}]}
    instance3 = {program3, [bindings: %{}, policy: %{}]}

    assert eval(instance1, 10) == {:ok, 11}
    assert eval(instance3, 10) == {:ok, 12}
  end

  test "program cache validates source hash limits before reuse" do
    source = """
    case Input of
      _ -> Input
    end.
    """

    {:ok, _program} =
      Hyperlang.Test.program(
        source,
        erlang_public(%{limits: %{max_source_bytes: byte_size(source)}})
      )

    assert {:error, [%{category: :lexer, message: "source byte size exceeds limit"}]} =
             Hyperlang.Test.program(
               source,
               erlang_public(%{limits: %{max_source_bytes: byte_size(source) - 1}})
             )

    assert {:error, [%{category: :lexer, message: "source line count exceeds limit"}]} =
             Hyperlang.Test.program(
               source,
               erlang_public(%{limits: %{max_line_count: 1}})
             )
  end

  test "program cache distinguishes result roots" do
    source = """
    main(Input) -> Input + 1.
    result(Input) -> Input + 2.
    """

    {:ok, main_program} =
      Hyperlang.Test.program(source, erlang_public(%{result: %{name: "main"}}))

    {:ok, result_program} =
      Hyperlang.Test.program(source, erlang_public(%{result: %{name: "result"}}))

    refute main_program.content_hash == result_program.content_hash

    main_instance = {main_program, [bindings: %{}, policy: %{}]}
    result_instance = {result_program, [bindings: %{}, policy: %{}]}

    assert eval(main_instance, 1) == {:ok, 2}
    assert eval(result_instance, 1) == {:ok, 3}
  end
end
