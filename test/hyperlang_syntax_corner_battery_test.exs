defmodule HyperlangSyntaxCornerBatteryTest do
  use ExUnit.Case, async: false

  @oracle_module :hyperlang_oracle_syntax_corner_battery
  @manifest %{
    terms: %{
      public: :erlang,
      allowed_atoms: [
        :a,
        :all,
        :alpha,
        :b,
        :badarith,
        :bar,
        :baz,
        :binary,
        :c,
        :capture,
        :case_clause,
        :compact,
        :decimals,
        :done,
        :drop,
        :empty,
        :error,
        :foo,
        :gamma,
        :global,
        :head,
        :high,
        :ignore,
        :keep,
        :left,
        :low,
        :match,
        :missing,
        nil,
        :no,
        :none,
        :nomatch,
        :ok,
        :one,
        :other,
        :pair,
        :pos,
        :return,
        :right,
        :same,
        :skip,
        :small,
        :some,
        :tag,
        :tail,
        :three,
        :trim,
        :two,
        :up,
        :utf8,
        :value,
        :x,
        :y,
        :yes,
        :z,
        :zero
      ]
    }
  }

  defp assert_safe_expr(source, input \\ :ok, manifest \\ @manifest) do
    {:ok, program} = Hyperlang.Test.program(source, manifest)

    assert eval(program, input) == {:ok, oracle_expr!(source, input)}
  end

  defp assert_safe_program(source, input, manifest \\ @manifest) do
    {:ok, program} = Hyperlang.Test.program(source, manifest)

    assert eval(program, input) == {:ok, oracle_program!(source, input)}
  end

  defp assert_unsafe_compile(source, manifest \\ @manifest) do
    assert {:error, [_ | _]} = Hyperlang.Test.program(source, manifest)
  end

  defp assert_safe_compile(source, manifest \\ @manifest) do
    assert {:ok, _program} = Hyperlang.Test.program(source, manifest)
  end

  defp assert_unsafe_eval(source, input \\ :ok, manifest \\ @manifest, options \\ %{}) do
    {:ok, program} = Hyperlang.Test.program(source, manifest)

    assert {:error, _reason} = eval(program, input, options)
  end

  defp eval(program, input, policy \\ %{}) do
    case Hyperlang.Test.run(program, :entry, [input], policy: policy) do
      {:ok, result, %{stdout: []}} -> {:ok, result}
      other -> other
    end
  end

  defp oracle_expr!(source, input) do
    forms = [
      {:attribute, 0, :module, @oracle_module},
      {:attribute, 0, :export, [result: 1]},
      {:function, 0, :result, 1, [{:clause, 0, [{:var, 0, :Input}], [], oracle_exprs(source)}]}
    ]

    compile_and_call_oracle!(forms, input)
  end

  defp oracle_program!(source, input) do
    source =
      source
      |> strip_module_attrs()
      |> then(&("-module(#{@oracle_module}).\n-export([result/1]).\n" <> &1))

    forms = parse_forms!(source)
    compile_and_call_oracle!(forms, input)
  end

  defp compile_and_call_oracle!(forms, input) do
    :code.purge(@oracle_module)
    :code.delete(@oracle_module)

    {:ok, @oracle_module, binary, _warnings} =
      :compile.noenv_forms(forms, [:binary, :return_warnings])

    {:module, @oracle_module} = :code.load_binary(@oracle_module, ~c"hyperlang_oracle", binary)

    try do
      apply(@oracle_module, :result, [input])
    after
      :code.purge(@oracle_module)
      :code.delete(@oracle_module)
      :code.purge(@oracle_module)
    end
  end

  defp oracle_exprs(source) do
    source = ensure_dot(source)
    {:ok, tokens, _} = :erl_scan.string(String.to_charlist(source), {1, 1}, [:text])
    {:ok, exprs} = :erl_parse.parse_exprs(tokens)
    exprs
  end

  defp parse_forms!(source) do
    {:ok, tokens, _} = :erl_scan.string(String.to_charlist(source), {1, 1}, [:text])

    tokens
    |> split_forms()
    |> Enum.map(fn form_tokens ->
      {:ok, form} = :erl_parse.parse_form(form_tokens)
      form
    end)
  end

  defp split_forms(tokens) do
    {segments, current} =
      Enum.reduce(tokens, {[], []}, fn token, {segments, current} ->
        current = [token | current]

        if elem(token, 0) == :dot do
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

  defp strip_module_attrs(source) do
    source
    |> String.replace(~r/^\s*-module\s*\([^)]*\)\s*\.\s*/m, "")
    |> String.replace(~r/^\s*-export\s*\([^)]*\)\s*\.\s*/m, "")
  end

  defp ensure_dot(source) do
    if source |> String.trim_trailing() |> String.ends_with?(".") do
      source
    else
      source <> "."
    end
  end

  test "syntax corner battery is manually enumerated" do
    source = File.read!(__ENV__.file)
    assert Regex.scan(~r/^\s*test "safe syntax \d{3}/m, source) |> length() >= 120
    assert Regex.scan(~r/^\s*test "unsafe syntax \d{3}/m, source) |> length() >= 30
  end

  test "safe syntax 001 integer base literal" do
    assert_safe_expr("16#ff.")
  end

  test "safe syntax 002 binary base literal" do
    assert_safe_expr("2#101010.")
  end

  test "safe syntax 003 signed arithmetic precedence" do
    assert_safe_expr("-1 + +2 * 3.")
  end

  test "safe syntax 004 parenthesized arithmetic precedence" do
    assert_safe_expr("(1 + 2) * (3 + 4).")
  end

  test "safe syntax 005 float exponent literal" do
    assert_safe_expr("1.5e2 + 0.25.")
  end

  test "safe syntax 006 integer division and remainder" do
    assert_safe_expr("{17 div 5, 17 rem 5}.")
  end

  test "safe syntax 007 bitwise operators" do
    assert_safe_expr("{5 band 3, 5 bor 2, 5 bxor 1, bnot 0}.")
  end

  test "safe syntax 008 shift operators" do
    assert_safe_expr("{1 bsl 5, 64 bsr 3}.")
  end

  test "safe syntax 009 list concat and subtract operators" do
    assert_safe_expr("{[1, 2] ++ [3], [1, 2, 3] -- [2]}.")
  end

  test "safe syntax 010 exact equality operators" do
    assert_safe_expr("{1 =:= 1, 1 =/= 2, 1 == 1.0, 1 /= 1.0}.")
  end

  test "safe syntax 011 term ordering operators" do
    assert_safe_expr("{a < b, 3 >= 2, {a, 1} =< {a, 2}}.")
  end

  test "safe syntax 012 boolean short circuit operators" do
    assert_safe_expr("{true andalso false, false orelse true}.")
  end

  test "safe syntax 013 strict boolean operators" do
    assert_safe_expr("{true and true, true xor false, false or true}.")
  end

  test "safe syntax 014 unary not operator" do
    assert_safe_expr("not false.")
  end

  test "safe syntax 015 character literal" do
    assert_safe_expr("$A.")
  end

  test "safe syntax 016 string literal as list" do
    assert_safe_expr("\"abc\".")
  end

  test "safe syntax 017 escaped string literal" do
    assert_safe_expr("\"a\\n\\t\\\\b\".")
  end

  test "safe syntax 018 unicode binary literal" do
    assert_safe_expr("<<\"hello\">>.")
  end

  test "safe syntax 019 adjacent expression block" do
    assert_safe_expr("A = 1, B = 2, A + B.")
  end

  test "safe syntax 020 begin block expression" do
    assert_safe_expr("begin A = 2, A * A end.")
  end

  test "safe syntax 021 wildcard top-level match" do
    assert_safe_expr("_ = Input, ok.", {:a, 1})
  end

  test "safe syntax 022 tuple wildcard match" do
    assert_safe_expr("{_, X, _} = {a, 2, c}, X.")
  end

  test "safe syntax 023 nested tuple match" do
    assert_safe_expr("{{_, X}, {Y, _}} = {{a, 1}, {2, b}}, X + Y.")
  end

  test "safe syntax 024 list pattern match" do
    assert_safe_expr("[A, _, C] = [1, 2, 3], A + C.")
  end

  test "safe syntax 025 cons pattern match" do
    assert_safe_expr("[H | T] = [1, 2, 3], {H, T}.")
  end

  test "safe syntax 026 nested cons pattern match" do
    assert_safe_expr("[A, B | Rest] = [1, 2, 3, 4], {A, B, Rest}.")
  end

  test "safe syntax 027 empty list pattern match" do
    assert_safe_expr("[] = [], ok.")
  end

  test "safe syntax 028 map exact pattern match" do
    assert_safe_expr(~S|#{a := X, b := _} = #{a => 1, b => 2}, X.|)
  end

  test "safe syntax 029 map dynamic key pattern match" do
    assert_safe_expr(~S|K = a, #{K := V} = #{a => 9}, V.|)
  end

  test "safe syntax 030 binary byte pattern match" do
    assert_safe_expr("<<A, B, C>> = <<1, 2, 3>>, {A, B, C}.")
  end

  test "safe syntax 031 binary tail pattern match" do
    assert_safe_expr("<<A, Rest/binary>> = <<1, 2, 3>>, {A, Rest}.")
  end

  test "safe syntax 032 binary wildcard tail pattern match" do
    assert_safe_expr("<<A, _/binary>> = <<1, 2, 3>>, A.")
  end

  test "safe syntax 033 binary sized wildcard pattern match" do
    assert_safe_expr("<<_:4, X:4>> = <<16#AB>>, X.")
  end

  test "safe syntax 034 binary dynamic size pattern match" do
    assert_safe_expr("N = 2, <<X:N/binary, _/binary>> = <<\"abcd\">>, X.")
  end

  test "safe syntax 035 utf8 binary pattern match" do
    assert_safe_expr("<<C/utf8>> = <<\"A\">>, C.")
  end

  test "safe syntax 036 utf16 binary pattern match" do
    assert_safe_expr("<<C/utf16>> = <<0, 65>>, C.")
  end

  test "safe syntax 037 little endian integer pattern match" do
    assert_safe_expr("<<X:16/little-unsigned-integer>> = <<1, 0>>, X.")
  end

  test "safe syntax 038 signed integer pattern match" do
    assert_safe_expr("<<X:8/signed-integer>> = <<255>>, X.")
  end

  test "safe syntax 039 float binary pattern match" do
    assert_safe_expr("<<F:64/float>> = <<1.5:64/float>>, F.")
  end

  test "safe syntax 040 binary construction bytes" do
    assert_safe_expr("A = 1, B = 2, <<A, B, 3>>.")
  end

  test "safe syntax 041 binary construction sized integer" do
    assert_safe_expr("<<1:4, 2:4>>.")
  end

  test "safe syntax 042 binary construction unit modifier" do
    assert_safe_expr("<<1:2/unit:4>>.")
  end

  test "safe syntax 043 binary construction splice" do
    assert_safe_expr("A = <<\"ab\">>, <<A/binary, \"cd\">>.")
  end

  test "safe syntax 044 binary construction utf8" do
    assert_safe_expr("<<65/utf8>>.")
  end

  test "safe syntax 045 binary construction float little" do
    assert_safe_expr("<<1.5:64/float-little>>.")
  end

  test "safe syntax 046 case with literals" do
    assert_safe_expr("case Input of ok -> 1; error -> 2; _ -> 3 end.", :ok)
  end

  test "safe syntax 047 case with tuple pattern" do
    assert_safe_expr("case {ok, 5} of {ok, X} -> X; _ -> 0 end.")
  end

  test "safe syntax 048 case with list pattern" do
    assert_safe_expr("case [1, 2, 3] of [_, X | _] -> X end.")
  end

  test "safe syntax 049 case with map pattern" do
    assert_safe_expr(~S|case #{a => 1, b => 2} of #{b := B} -> B end.|)
  end

  test "safe syntax 050 case with binary pattern" do
    assert_safe_expr("case <<1, 2, 3>> of <<_, X, _>> -> X end.")
  end

  test "safe syntax 051 case with guard sequence" do
    assert_safe_expr("case 4 of X when is_integer(X), X > 3 -> ok; _ -> error end.")
  end

  test "safe syntax 052 case with guard alternatives" do
    assert_safe_expr("case a of X when X =:= b; X =:= a -> ok; _ -> error end.")
  end

  test "safe syntax 053 if with arithmetic guard" do
    assert_safe_expr("X = 5, if X rem 2 =:= 1 -> ok; true -> error end.")
  end

  test "safe syntax 054 if with multiple guard tests" do
    assert_safe_expr("X = 6, if is_integer(X), X > 5 -> ok; true -> error end.")
  end

  test "safe syntax 055 if with guard alternative" do
    assert_safe_expr("X = a, if X =:= b; X =:= a -> ok; true -> error end.")
  end

  test "safe syntax 056 simple try catch" do
    assert_safe_expr("try 1 div 0 catch error:badarith -> ok end.")
  end

  test "safe syntax 057 try catch class variable" do
    assert_safe_expr("try 1 div 0 catch Class:badarith -> Class end.")
  end

  test "safe syntax 058 try catch reason variable" do
    assert_safe_expr("try 1 div 0 catch error:Reason -> Reason end.")
  end

  test "safe syntax 058b try of catch" do
    assert_safe_expr("try 2 of 1 -> one; 2 -> two catch error:badarith -> error end.")
  end

  test "safe syntax 058c try of sees body bindings" do
    assert_safe_expr("try X = 1 of Y -> {X, Y} catch _:_ -> error end.")
  end

  test "safe syntax 059 anonymous fun call" do
    assert_safe_expr("F = fun(X) -> X + 1 end, F(2).")
  end

  test "safe syntax 060 anonymous fun multi clause" do
    assert_safe_expr("F = fun(0) -> zero; (N) when N > 0 -> pos end, F(3).")
  end

  test "safe syntax 061 named recursive fun" do
    assert_safe_expr("F = fun Loop(0) -> 0; Loop(N) -> N + Loop(N - 1) end, F(4).")
  end

  test "safe syntax 062 closure captures binding" do
    assert_safe_expr("A = 10, F = fun(X) -> A + X end, F(5).")
  end

  test "safe syntax 063 fun passed to lists map" do
    assert_safe_expr("F = fun(X) -> X * 2 end, lists:map(F, [1, 2, 3]).")
  end

  test "safe syntax 064 fun passed to lists filter" do
    assert_safe_expr("lists:filter(fun(X) -> X rem 2 =:= 0 end, [1, 2, 3, 4]).")
  end

  test "safe syntax 065 fun passed to lists foldl" do
    assert_safe_expr("lists:foldl(fun(X, Acc) -> X + Acc end, 0, [1, 2, 3]).")
  end

  test "safe syntax 066 list comprehension simple" do
    assert_safe_expr("[X * 2 || X <- [1, 2, 3]].")
  end

  test "safe syntax 067 list comprehension with filter" do
    assert_safe_expr("[X || X <- [1, 2, 3, 4], X rem 2 =:= 0].")
  end

  test "safe syntax 068 list comprehension tuple pattern" do
    assert_safe_expr("[V || {ok, V} <- [{ok, 1}, error, {ok, 2}]].")
  end

  test "safe syntax 069 list comprehension binary pattern" do
    assert_safe_expr("[X || <<X>> <= <<1, 2, 3>>].")
  end

  test "safe syntax 070 binary comprehension simple" do
    assert_safe_expr("<< <<(X + 1)>> || X <- [1, 2, 3] >>.")
  end

  test "safe syntax 071 binary comprehension binary generator" do
    assert_safe_expr("<< <<X>> || <<X>> <= <<1, 2, 3>>, X > 1 >>.")
  end

  test "safe syntax 072 binary comprehension wildcard generator" do
    assert_safe_expr("[X || <<_:4, X:4>> <= <<16#AB, 16#CD>>].")
  end

  test "safe syntax 073 map comprehension simple" do
    assert_safe_expr(~S"""
    #{X => X * 10 || X <- [1, 2, 3]}.
    """)
  end

  test "safe syntax 074 map comprehension tuple generator" do
    assert_safe_expr(~S"""
    #{K => V || {K, V} <- [{a, 1}, {b, 2}]}.
    """)
  end

  test "safe syntax 075 map comprehension with filter" do
    assert_safe_expr(~S"""
    #{X => X || X <- [1, 2, 3, 4], X > 2}.
    """)
  end

  test "safe syntax 076 map literal mixed keys" do
    assert_safe_expr(~S|#{a => 1, <<"b">> => 2, 3 => c}.|)
  end

  test "safe syntax 077 map exact update existing key" do
    assert_safe_expr(~S|M = #{a => 1}, M#{a := 2}.|)
  end

  test "safe syntax 078 map assoc update insert key" do
    assert_safe_expr(~S|M = #{a => 1}, M#{b => 2}.|)
  end

  test "safe syntax 079 map assoc update replace key" do
    assert_safe_expr(~S|M = #{a => 1}, M#{a => 3}.|)
  end

  test "safe syntax 080 map dynamic assoc update key" do
    assert_safe_expr(~S|K = a, M = #{}, M#{K => 1}.|)
  end

  test "safe syntax 081 map dynamic exact update key" do
    assert_safe_expr(~S|K = a, M = #{a => 1}, M#{K := 2}.|)
  end

  test "safe syntax 082 nested map update" do
    assert_safe_expr(~S|M = #{a => #{b => 1}}, Inner = maps:get(a, M), M#{a := Inner#{b => 2}}.|)
  end

  test "safe syntax 083 maps find case" do
    assert_safe_expr(~S|case maps:find(a, #{a => 1}) of {ok, V} -> V; error -> 0 end.|)
  end

  test "safe syntax 084 maps get default" do
    assert_safe_expr(~S|maps:get(missing, #{a => 1}, none).|)
  end

  test "safe syntax 085 maps iterator free to list" do
    assert_safe_expr(~S|lists:sort(maps:to_list(#{b => 2, a => 1})).|)
  end

  test "safe syntax 086 tuple element update chain" do
    assert_safe_expr("setelement(2, {a, b, c}, z).")
  end

  test "safe syntax 087 tuple append and delete" do
    assert_safe_expr("erlang:delete_element(2, erlang:append_element({a, b}, c)).")
  end

  test "safe syntax 088 tuple insert" do
    assert_safe_expr("erlang:insert_element(2, {a, c}, b).")
  end

  test "safe syntax 089 tuple to list and back" do
    assert_safe_expr("list_to_tuple(tuple_to_list({a, b, c})).")
  end

  test "safe syntax 090 list to bitstring and bitstring to list" do
    assert_safe_expr("bitstring_to_list(list_to_bitstring([<<1:8>>, <<2:8>>])).")
  end

  test "safe syntax 091 binary part tuple argument" do
    assert_safe_expr("binary_part(<<\"abcdef\">>, {1, 3}).")
  end

  test "safe syntax 092 binary part position length" do
    assert_safe_expr("binary_part(<<\"abcdef\">>, 2, 2).")
  end

  test "safe syntax 093 iolist to binary nested" do
    assert_safe_expr("iolist_to_binary([<<\"a\">>, [\"b\", <<\"c\">>]]).")
  end

  test "safe syntax 094 binary match options" do
    assert_safe_expr("binary:match(<<\"abcabc\">>, <<\"bc\">>).")
  end

  test "safe syntax 095 binary split global" do
    assert_safe_expr("binary:split(<<\"a,b,c\">>, <<\",\">>, [global]).")
  end

  test "safe syntax 096 binary replace global" do
    assert_safe_expr("binary:replace(<<\"banana\">>, <<\"na\">>, <<\"NA\">>, [global]).")
  end

  test "safe syntax 097 string lowercase binary" do
    assert_safe_expr("string:lowercase(<<\"ABC\">>).")
  end

  test "safe syntax 098 string trim list" do
    assert_safe_expr("string:trim(\"  abc  \").")
  end

  test "safe syntax 099 unicode characters to binary" do
    assert_safe_expr("unicode:characters_to_binary(\"abc\").")
  end

  test "safe syntax 100 base64 round trip" do
    assert_safe_expr("base64:decode(base64:encode(<<\"abc\">>)).")
  end

  test "safe syntax 101 regex run binary capture" do
    assert_safe_expr(
      "re:run(<<\"abc123\">>, <<\"([a-z]+)([0-9]+)\">>, [{capture, all, binary}])."
    )
  end

  test "safe syntax 102 regex split trim" do
    assert_safe_expr("re:split(<<\"a,b,c\">>, <<\",\">>, [trim]).")
  end

  test "safe syntax 103 regex replace return binary" do
    assert_safe_expr(
      "re:replace(<<\"banana\">>, <<\"a\">>, <<\"x\">>, [global, {return, binary}])."
    )
  end

  test "safe syntax 104 calendar date tuple" do
    assert_safe_expr("calendar:date_to_gregorian_days({2026, 5, 16}).")
  end

  test "safe syntax 105 calendar valid date" do
    assert_safe_expr("calendar:valid_date(2026, 2, 28).")
  end

  test "safe syntax 106 math nested calls" do
    assert_safe_expr("math:pow(math:sqrt(9.0), 2.0).")
  end

  test "safe syntax 107 queue expression" do
    assert_safe_expr("queue:to_list(queue:in(3, queue:from_list([1, 2]))).")
  end

  test "safe syntax 108 sets expression" do
    assert_safe_expr("lists:sort(sets:to_list(sets:add_element(c, sets:from_list([a, b])))).")
  end

  test "safe syntax 109 gb sets expression" do
    assert_safe_expr("gb_sets:to_list(gb_sets:add(3, gb_sets:from_list([1, 2]))).")
  end

  test "safe syntax 110 ordsets expression" do
    assert_safe_expr("ordsets:union(ordsets:from_list([b, a]), ordsets:from_list([c])).")
  end

  test "safe syntax 111 proplists expression" do
    assert_safe_expr("proplists:get_value(a, [{a, 1}], none).")
  end

  test "safe syntax 112 uri string quote" do
    assert_safe_expr("uri_string:quote(<<\"a b\">>).")
  end

  test "safe syntax 113 function program multi clause recursion" do
    assert_safe_program(
      """
      result(Input) -> sum(Input).
      sum([]) -> 0;
      sum([H | T]) -> H + sum(T).
      """,
      [1, 2, 3]
    )
  end

  test "safe syntax 114 function program guard clauses" do
    assert_safe_program(
      """
      result(Input) -> classify(Input).
      classify(N) when N < 0 -> left;
      classify(0) -> none;
      classify(N) when N > 0 -> right.
      """,
      7
    )
  end

  test "safe syntax 115 function head tuple pattern" do
    assert_safe_program(
      """
      result(Input) -> pick(Input).
      pick({ok, V}) -> V;
      pick(error) -> 0.
      """,
      {:ok, 9}
    )
  end

  test "safe syntax 116 function head map pattern" do
    assert_safe_program(
      ~S"""
      result(Input) -> pick(Input).
      pick(#{<<"x">> := X}) -> X;
      pick(_) -> 0.
      """,
      %{<<"x">> => 11}
    )
  end

  test "safe syntax 117 function head binary pattern" do
    assert_safe_program(
      """
      result(Input) -> first(Input).
      first(<<X, _/binary>>) -> X;
      first(<<>>) -> 0.
      """,
      <<5, 6, 7>>
    )
  end

  test "safe syntax 118 function head list wildcard" do
    assert_safe_program(
      """
      result(Input) -> second(Input).
      second([_, X | _]) -> X;
      second(_) -> 0.
      """,
      [1, 8, 9]
    )
  end

  test "safe syntax 119 inert module and export attributes" do
    assert_safe_program(
      """
      -module(codemode_program).
      -export([result/1]).
      result(Input) -> helper(Input).
      helper(X) -> X + 1.
      """,
      4
    )
  end

  test "safe syntax 120 helper binary dynamic match" do
    assert_safe_program(
      """
      result(Input) -> take(Input, 2).
      take(Bin, N) ->
        <<Prefix:N/binary, _/binary>> = Bin,
        Prefix.
      """,
      <<"abcd">>
    )
  end

  test "safe syntax 121 map exact pattern accepted by OTP" do
    assert_safe_expr(~S|case #{a => 1} of #{a := X} -> X end.|)
  end

  test "safe syntax 122 quoted allowed atom literal" do
    assert_safe_expr("'foo'.")
  end

  test "safe syntax 123 underscore-prefixed variable is still bindable" do
    assert_safe_expr("_Hidden = 41, _Hidden + 1.")
  end

  test "safe syntax 124 repeated variable tuple pattern success" do
    assert_safe_expr("{X, X} = {7, 7}, X.")
  end

  test "safe syntax 125 repeated variable list pattern success" do
    assert_safe_expr("[X, X | Rest] = [3, 3, 4], {X, Rest}.")
  end

  test "safe syntax 126 repeated variable map pattern success" do
    assert_safe_expr(~S|#{a := X, b := X} = #{a => 5, b => 5}, X.|)
  end

  test "safe syntax 127 repeated variable nested case pattern" do
    assert_safe_expr("case {pair, {2, 2}} of {pair, {X, X}} -> same; _ -> other end.")
  end

  test "safe syntax 128 improper list expression" do
    assert_safe_expr("case [head | tail] of [H | T] -> {H, T} end.")
  end

  test "safe syntax 129 improper list pattern match" do
    assert_safe_expr("[H | T] = [head | tail], {H, T}.")
  end

  test "safe syntax 130 function head improper list pattern" do
    assert_safe_program(
      """
      result(_Input) -> pair([head | tail]).
      pair([H | T]) -> {H, T}.
      """,
      :ok
    )
  end

  test "safe syntax 131 literal match expression" do
    assert_safe_expr("1 = 1, ok.")
  end

  test "safe syntax 132 remote quoted module and function names" do
    assert_safe_expr("'lists':'reverse'([1, 2, 3]).")
  end

  test "safe syntax 133 quoted local helper function name" do
    assert_safe_program(
      """
      result(Input) -> 'plus_one'(Input).
      'plus_one'(X) -> X + 1.
      """,
      9
    )
  end

  test "safe syntax 134 comments between forms are ignored" do
    assert_safe_program(
      """
      %% leading comment
      result(Input) ->
        %% body comment
        helper(Input).
      helper(X) ->
        X * 2.
      """,
      12
    )
  end

  test "safe syntax 135 same helper name with different arities" do
    assert_safe_program(
      """
      result(Input) -> add(Input) + add(Input, 3).
      add(X) -> X + 1.
      add(X, Y) -> X + Y.
      """,
      4
    )
  end

  test "safe syntax 136 helper used before declaration" do
    assert_safe_program(
      """
      result(Input) -> later(Input).
      later(X) -> X * X.
      """,
      6
    )
  end

  test "safe syntax 137 list comprehension with two generators" do
    assert_safe_expr("[{X, Y} || X <- [1, 2], Y <- [a, b]].")
  end

  test "safe syntax 138 list comprehension with pattern and guard sequence" do
    assert_safe_expr("[V || {ok, V} <- [{ok, 1}, {error, 2}, {ok, 3}], is_integer(V), V > 1].")
  end

  test "safe syntax 139 list comprehension result begin block" do
    assert_safe_expr("[begin Y = X * 2, Y + 1 end || X <- [1, 2, 3]].")
  end

  test "safe syntax 140 binary comprehension from list generator with filter" do
    assert_safe_expr("<< <<X>> || X <- [1, 2, 3, 4], X rem 2 =:= 0 >>.")
  end

  test "safe syntax 141 binary comprehension two-byte generator pattern" do
    assert_safe_expr("[{A, B} || <<A, B>> <= <<1, 2, 3, 4>>].")
  end

  test "safe syntax 142 binary pattern bitstring tail wildcard" do
    assert_safe_expr("<<_:3, _/bits>> = <<16#ff>>, ok.")
  end

  test "safe syntax 143 binary pattern bitstring tail binding used internally" do
    assert_safe_expr("<<_:3, Rest/bits>> = <<16#ff>>, bit_size(Rest).")
  end

  test "safe syntax 144 binary construction signed big integer" do
    assert_safe_expr("<<-2:16/signed-big-integer>>.")
  end

  test "safe syntax 145 binary construction unsigned little integer" do
    assert_safe_expr("<<16#1234:16/unsigned-little-integer>>.")
  end

  test "safe syntax 146 binary construction utf16 and utf32" do
    assert_safe_expr("<<65/utf16, 66/utf32>>.")
  end

  test "safe syntax 147 binary construction dynamic integer size" do
    assert_safe_expr("N = 16, <<258:N/integer>>.")
  end

  test "safe syntax 147b inlined helper substitutes binary segment size" do
    assert_safe_program(
      """
      result(_Input) -> wrap().
      wrap() -> sized(7, 1).
      sized(W, V) -> loop(W, W - 1, V, <<0:(W * 8)>>).
      loop(_W, I, _V, A) when I < 0 -> A;
      loop(W, I, V, A) -> loop(W, I - 1, V bsr 3, A).
      """,
      :ok
    )
  end

  test "safe syntax 148 binary pattern dynamic unit size" do
    assert_safe_expr("N = 2, <<X:N/unit:4>> = <<16#ab>>, X.")
  end

  test "safe syntax 149 binary float little pattern" do
    assert_safe_expr("<<F:32/float-little>> = <<1.25:32/float-little>>, F.")
  end

  test "safe syntax 150 try with multiple catch clauses" do
    assert_safe_expr("try 1 div 0 catch throw:_ -> error; error:badarith -> ok end.")
  end

  test "safe syntax 151 try catches case clause reason" do
    assert_safe_expr("try case a of b -> 1 end catch error:{case_clause, a} -> ok end.")
  end

  test "safe syntax 152 anonymous fun with tuple pattern clauses" do
    assert_safe_expr("F = fun({ok, V}) -> V; ({error, _}) -> 0 end, F({ok, 8}).")
  end

  test "safe syntax 153 anonymous fun used from comprehension" do
    assert_safe_expr("F = fun(X) -> X + 10 end, [F(X) || X <- [1, 2, 3]].")
  end

  test "safe syntax 154 maps map with anonymous fun" do
    assert_safe_expr(~S|maps:map(fun(_K, V) -> V * 2 end, #{a => 1, b => 2}).|)
  end

  test "safe syntax 155 maps filter with anonymous fun" do
    assert_safe_expr(~S|maps:filter(fun(_K, V) -> V > 1 end, #{a => 1, b => 2}).|)
  end

  test "safe syntax 156 lists zipwith with anonymous fun" do
    assert_safe_expr("lists:zipwith(fun(A, B) -> A + B end, [1, 2], [10, 20]).")
  end

  test "safe syntax 157 guard map key bif" do
    assert_safe_expr(~S|M = #{a => 1}, case M of X when is_map_key(a, X) -> ok; _ -> error end.|)
  end

  test "safe syntax 158 guard map get bif" do
    assert_safe_expr(
      ~S|M = #{a => 1}, case M of X when map_get(a, X) =:= 1 -> ok; _ -> error end.|
    )
  end

  test "safe syntax 159 guard tuple and byte sizes" do
    assert_safe_expr(
      "case {{a, b}, <<1, 2>>} of {T, B} when tuple_size(T) =:= 2, byte_size(B) =:= 2 -> ok end."
    )
  end

  test "safe syntax 160 guard bit size on bitstring" do
    assert_safe_expr("case <<1:3>> of B when bit_size(B) =:= 3 -> ok end.")
  end

  test "safe syntax 161 guard is_record local bif" do
    assert_safe_expr("case {tag, 1} of X when is_record(X, tag, 2) -> ok; _ -> error end.")
  end

  test "safe syntax 162 erlang is_record remote call" do
    assert_safe_expr("erlang:is_record({tag, 1}, tag, 2).")
  end

  test "safe syntax 163 short circuit andalso avoids badarith" do
    assert_safe_expr("false andalso (1 div 0 =:= 1).")
  end

  test "safe syntax 164 short circuit orelse avoids badarith" do
    assert_safe_expr("true orelse (1 div 0 =:= 1).")
  end

  test "safe syntax 165 match same value after binding" do
    assert_safe_expr("X = 1, X = 1, X.")
  end

  test "safe syntax 166 case clause with binary and map nested pattern" do
    assert_safe_expr(~S|case {<<"ab">>, #{x => 4}} of {<<A, _>>, #{x := X}} -> A + X end.|)
  end

  test "safe syntax 167 map comprehension duplicate keys follow Erlang" do
    assert_safe_expr(~S"""
    #{K => V || {K, V} <- [{a, 1}, {a, 2}, {b, 3}]} .
    """)
  end

  test "safe syntax 168 function clause guard alternatives" do
    assert_safe_program(
      """
      result(Input) -> bucket(Input).
      bucket(X) when X < 0; X =:= 0 -> low;
      bucket(X) when X > 10 -> high;
      bucket(_) -> small.
      """,
      11
    )
  end

  test "safe syntax 169 binary function head with size argument" do
    assert_safe_program(
      """
      result(Input) -> take(Input, 3).
      take(<<Prefix:3/binary, _/binary>>, _) -> Prefix.
      """,
      <<"abcdef">>
    )
  end

  test "safe syntax 170 module attribute may use quoted atom" do
    assert_safe_program(
      """
      -module('codemode_program').
      -export([result/1]).
      result(Input) -> Input + 2.
      """,
      5
    )
  end

  test "safe syntax 171 binary modifier order variations" do
    assert_safe_expr("<<X:16/integer-signed-little>> = <<255, 255>>, X.")
  end

  test "safe syntax 172 parenthesized match expression" do
    assert_safe_expr("(X = 4), X + 1.")
  end

  test "safe syntax 173 nested begin blocks" do
    assert_safe_expr("begin A = begin 1 + 2 end, begin A * 3 end end.")
  end

  test "safe syntax 174 empty tuple and empty map literals" do
    assert_safe_expr(~S|{ {}, #{} }.|)
  end

  test "safe syntax 175 char escape literal" do
    assert_safe_expr("$\\n + $\\t.")
  end

  test "safe syntax 176 local fun capture maps recursive helper" do
    assert_safe_program(
      """
      result(_Input) -> fibs(8).
      fib(0) -> 0;
      fib(1) -> 1;
      fib(N) -> fib(N - 1) + fib(N - 2).
      fibs(N) -> lists:map(fun fib/1, lists:seq(0, N - 1)).
      """,
      :ok
    )
  end

  test "safe syntax 177 local fun capture forward reference" do
    assert_safe_program(
      """
      result(_Input) -> lists:map(fun later/1, [1, 2, 3]).
      later(X) -> X + 10.
      """,
      :ok
    )
  end

  test "safe syntax 178 local fun capture selects arity one" do
    assert_safe_program(
      """
      result(_Input) -> lists:map(fun value/1, [1, 2, 3]).
      value() -> 99.
      value(X) -> X * 2.
      """,
      :ok
    )
  end

  test "safe syntax 179 local fun capture arity zero" do
    assert_safe_program(
      """
      result(_Input) ->
        F = fun answer/0,
        F().
      answer() -> 42.
      """,
      :ok
    )
  end

  test "safe syntax 180 quoted local fun capture" do
    assert_safe_program(
      """
      result(_Input) -> lists:map(fun 'plus one'/1, [1, 2, 3]).
      'plus one'(X) -> X + 1.
      """,
      :ok
    )
  end

  test "safe syntax 181 local fun capture inside anonymous fun" do
    assert_safe_program(
      """
      result(_Input) ->
        Wrap = fun(List) -> lists:map(fun inc/1, List) end,
        Wrap([4, 5]).
      inc(X) -> X + 1.
      """,
      :ok
    )
  end

  test "safe syntax 182 local fun capture passed through foldl" do
    assert_safe_program(
      """
      result(_Input) -> lists:foldl(fun add/2, 0, [1, 2, 3, 4]).
      add(X, Acc) -> X + Acc.
      """,
      :ok
    )
  end

  test "safe syntax 121 receive expression accepted" do
    assert_safe_compile("receive X -> X end.")
  end

  test "unsafe syntax 122 send operator rejected" do
    assert_unsafe_compile("self() ! ok.")
  end

  test "unsafe syntax 123 spawn local fails closed without policy" do
    assert_unsafe_eval("spawn(fun() -> ok end).")
  end

  test "unsafe syntax 124 apply rejected" do
    assert_unsafe_compile("apply(lists, reverse, [[1, 2]]).")
  end

  test "unsafe syntax 125 dynamic remote rejected" do
    assert_unsafe_compile("M = lists, M:reverse([1, 2]).")
  end

  test "unsafe syntax 126 external fun rejected" do
    assert_unsafe_compile("fun lists:reverse/1.")
  end

  test "unsafe syntax 127 local external fun rejected" do
    assert_unsafe_compile("fun helper/1.")
  end

  test "unsafe syntax 128 wildcard value rejected" do
    assert_unsafe_compile("_.")
  end

  test "unsafe syntax 129 wildcard match right side rejected" do
    assert_unsafe_compile("X = _, X.")
  end

  test "unsafe syntax 130 wildcard binary construction rejected" do
    assert_unsafe_compile("<<_/binary>>.")
  end

  test "unsafe syntax 131 wildcard function argument rejected" do
    assert_unsafe_compile("length(_).")
  end

  test "unsafe syntax 132 map assoc pattern rejected" do
    assert_unsafe_compile(~S|case #{a => 1} of #{a => X} -> X end.|)
  end

  test "unsafe syntax 133 map update on non map runtime" do
    assert_unsafe_eval(~S|M = 1, M#{a => 1}.|)
  end

  test "unsafe syntax 134 non byte aligned bitstring output rejected" do
    assert_unsafe_eval("<<1:1>>.")
  end

  test "unsafe syntax 135 bit syntax duplicate type rejected" do
    assert_unsafe_compile("<<1/integer-float>>.")
  end

  test "unsafe syntax 136 bit syntax unit zero rejected" do
    assert_unsafe_compile("<<1/unit:0>>.")
  end

  test "unsafe syntax 137 try after rejected" do
    assert_unsafe_compile("try 1 after 2 end.")
  end

  test "safe syntax 138 try of accepted" do
    assert_safe_expr("try 1 of X -> X catch _:_ -> ok end.")
  end

  test "unsafe syntax 139 catch expression rejected" do
    assert_unsafe_compile("catch 1.")
  end

  test "unsafe syntax 140 maybe expression rejected" do
    assert_unsafe_compile("maybe X ?= {ok, 1}, X end.")
  end

  test "unsafe syntax 141 record expression rejected" do
    assert_unsafe_compile("#state{x = 1}.")
  end

  test "unsafe syntax 142 record access rejected" do
    assert_unsafe_compile("Input#state.x.")
  end

  test "unsafe syntax 143 macro usage rejected" do
    assert_unsafe_compile("?FOO.")
  end

  test "unsafe syntax 144 compile attribute rejected" do
    assert_unsafe_compile("-compile(export_all). result(Input) -> Input.")
  end

  test "unsafe syntax 145 import attribute rejected" do
    assert_unsafe_compile("-import(lists, [reverse/1]). result(Input) -> reverse(Input).")
  end

  test "unsafe syntax 146 on load attribute rejected" do
    assert_unsafe_compile("-on_load(init/0). result(Input) -> Input.")
  end

  test "unsafe syntax 147 module info local rejected" do
    assert_unsafe_compile("module_info().")
  end

  test "unsafe syntax 148 code module rejected" do
    assert_unsafe_compile("code:which(lists).")
  end

  test "unsafe syntax 149 file module rejected" do
    assert_unsafe_compile("file:read_file(\"x\").")
  end

  test "unsafe syntax 150 os module rejected" do
    assert_unsafe_compile("os:cmd(\"whoami\").")
  end

  test "unsafe syntax 151 binary to term rejected" do
    assert_unsafe_compile("binary_to_term(<<131,100,0,3,102,111,111>>).")
  end

  test "unsafe syntax 152 binary to atom rejected" do
    assert_unsafe_compile("binary_to_atom(<<\"x\">>).")
  end

  test "unsafe syntax 153 list to atom rejected" do
    assert_unsafe_compile("list_to_atom(\"x\").")
  end

  # Process dictionary is now ALLOWED in this fork: it is process-LOCAL memory
  # (no authority / no cross-process reach), the home for Limbo module-level
  # globals in the ported Inferno userland. Each Prog runs as one fresh-spawned
  # guest process, so the dictionary cannot leak across Progs/tenants. See
  # verifier.ex / classifier.ex @forbidden_locals.
  test "syntax 154 process dictionary allowed (Inferno module state)" do
    assert_safe_expr("put(a, 1), get(a).")
  end

  test "unsafe syntax 155 guard local helper call rejected" do
    assert_unsafe_compile("""
    result(Input) -> case Input of X when helper(X) -> ok; _ -> error end.
    helper(_) -> true.
    """)
  end

  test "unsafe syntax 156 repeated variable tuple mismatch runtime" do
    assert_unsafe_eval("{X, X} = {1, 2}, X.")
  end

  test "unsafe syntax 157 repeated variable map mismatch runtime" do
    assert_unsafe_eval(~S|#{a := X, b := X} = #{a => 1, b => 2}, X.|)
  end

  test "unsafe syntax 158 exact map update missing key runtime" do
    assert_unsafe_eval(~S|M = #{a => 1}, M#{missing := 2}.|)
  end

  test "unsafe syntax 159 binary match too short runtime" do
    assert_unsafe_eval("<<A, B>> = <<1>>, {A, B}.")
  end

  test "unsafe syntax 160 literal badmatch runtime" do
    assert_unsafe_eval("1 = 2, ok.")
  end

  test "unsafe syntax 161 function clause runtime" do
    assert_unsafe_eval("F = fun(1) -> one end, F(2).")
  end

  test "unsafe syntax 162 if clause runtime" do
    assert_unsafe_eval("if false -> ok end.")
  end

  test "unsafe syntax 163 case clause runtime" do
    assert_unsafe_eval("case a of b -> ok end.")
  end

  test "unsafe syntax 164 strict boolean operator runtime" do
    assert_unsafe_eval("true and 1.")
  end

  test "unsafe syntax 165 match different value after binding runtime" do
    assert_unsafe_eval("X = 1, X = 2, X.")
  end

  test "unsafe syntax 166 mixed arity anonymous fun clauses rejected" do
    assert_unsafe_compile("fun(1) -> one; (1, 2) -> two end.")
  end

  test "unsafe syntax 167 external erlang fun rejected" do
    assert_unsafe_compile("fun erlang:length/1.")
  end

  test "unsafe syntax 168 variable module external fun rejected" do
    assert_unsafe_compile("M = lists, fun M:reverse/1.")
  end

  test "unsafe syntax 169 top level expression followed by function rejected" do
    assert_unsafe_compile("X = 1. result(_) -> X.")
  end

  test "unsafe syntax 170 file attribute rejected" do
    assert_unsafe_compile("-file(\"x.erl\", 1). result(Input) -> Input.")
  end

  test "safe syntax 171 spec attribute is inert contract metadata" do
    {:ok, program} =
      Hyperlang.Test.program(
        "-spec result(term()) -> term(). result(Input) -> Input.",
        @manifest
      )

    assert eval(program, 7) == {:ok, 7}
  end

  test "safe syntax 172 record attribute accepted" do
    assert_safe_compile("-record(state, {x}). result(Input) -> Input.")
  end

  test "unsafe syntax 173 include lib attribute rejected" do
    assert_unsafe_compile("-include_lib(\"kernel/include/file.hrl\"). result(Input) -> Input.")
  end

  test "unsafe syntax 174 export type attribute rejected" do
    assert_unsafe_compile("-export_type([t/0]). result(Input) -> Input.")
  end

  test "safe syntax 175 receive after accepted" do
    assert_safe_program("result(_Input) -> receive after 0 -> ok end.", :ok)
  end

  test "unsafe syntax 176 self call rejected directly" do
    assert_unsafe_compile("self().")
  end

  test "unsafe syntax 177 monitor call rejected directly" do
    assert_unsafe_compile("monitor(process, self()).")
  end

  test "unsafe syntax 178 process info call rejected directly" do
    assert_unsafe_compile("process_info(self()).")
  end

  test "unsafe syntax 179 erlang system info rejected" do
    assert_unsafe_compile("erlang:system_info(otp_release).")
  end

  test "unsafe syntax 180 exact map comprehension rejected" do
    assert_unsafe_compile(~S"""
    #{K := V || {K, V} <- [{a, 1}]} .
    """)
  end

  test "unsafe syntax 181 wildcard in begin value rejected" do
    assert_unsafe_compile("begin _ end.")
  end

  test "unsafe syntax 182 wildcard in guard rejected" do
    assert_unsafe_compile("case ok of _ when _ -> ok end.")
  end

  test "unsafe syntax 183 wildcard in map value expression rejected" do
    assert_unsafe_compile(~S|#{a => _}.|)
  end

  test "unsafe syntax 184 wildcard in binary segment size rejected" do
    assert_unsafe_compile("<<1:_>>.")
  end

  test "unsafe syntax 185 gen_server call is rejected at compile without the gen_server capability" do
    # The gen_server facade is gated behind capabilities.gen_server
    # (default off); without it the call
    # fails closed at COMPILE time as an undeclared remote.
    assert_unsafe_compile("result(_Input) -> gen_server:call(foo, bar).")
  end

  test "unsafe syntax 186 local fun capture wrong arity rejected" do
    assert_unsafe_compile("""
    result(_Input) -> fun fib/2.
    fib(X) -> X.
    """)
  end

  test "unsafe syntax 187 local fun capture missing function rejected" do
    assert_unsafe_compile("result(_Input) -> fun missing/1.")
  end

  test "unsafe syntax 188 remote stdlib fun capture remains rejected" do
    assert_unsafe_compile("result(_Input) -> fun lists:reverse/1.")
  end

  test "unsafe syntax 189 remote erlang fun capture remains rejected" do
    assert_unsafe_compile("result(_Input) -> fun erlang:length/1.")
  end

  test "unsafe syntax 190 dynamic remote fun capture remains rejected" do
    assert_unsafe_compile("result(_Input) -> M = lists, fun M:reverse/1.")
  end

  test "unsafe syntax 191 local fun capture cannot cross output boundary" do
    assert_unsafe_eval("""
    result(_Input) -> fun id/1.
    id(X) -> X.
    """)
  end

  test "unsafe syntax 192 local fun capture not allowed in guard" do
    assert_unsafe_compile("""
    result(Input) -> case Input of X when is_function(fun id/1, 1) -> X end.
    id(X) -> X.
    """)
  end

  test "safe syntax 193 forbidden local fun capture name is local when defined" do
    assert_safe_program(
      """
      result(_Input) ->
        F = fun spawn/1,
        F(ok).
      spawn(X) -> X.
      """,
      :ok
    )
  end
end
