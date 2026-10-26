defmodule HyperlangExpressionBatteryTest do
  use ExUnit.Case, async: false

  @guest_hook_keys [
    :guest_msg_resolver,
    :guest_spawn_hook,
    :guest_name_hook,
    :guest_monitor_hook,
    :guest_link_hook
  ]

  setup do
    previous = Map.new(@guest_hook_keys, &{&1, Application.get_env(:hyperlang, &1, :unset)})
    Enum.each(@guest_hook_keys, &Application.delete_env(:hyperlang, &1))

    on_exit(fn ->
      Enum.each(previous, fn
        {key, :unset} -> Application.delete_env(:hyperlang, key)
        {key, value} -> Application.put_env(:hyperlang, key, value)
      end)
    end)

    :ok
  end

  @oracle_module :hyperlang_oracle_expression_battery
  @safe_manifest %{
    terms: %{
      public: :erlang,
      allowed_atoms: [
        :a,
        :all,
        :b,
        :badarith,
        :bar,
        :baz,
        :binary,
        :c,
        :capture,
        :compact,
        :count,
        :day,
        :day_of_the_week,
        :decimals,
        :datetime_to_gregorian_seconds,
        :error,
        :feb,
        :foo,
        :global,
        :gregorian_seconds_to_datetime,
        :hello,
        :id,
        :ids,
        :jan,
        :latin1,
        :last_day_of_the_month,
        :leading,
        :match,
        :millisecond,
        :nomatch,
        :none,
        :ok,
        :pos,
        :price,
        :return,
        :results,
        :rfc3339_to_system_time,
        :second,
        :seconds_to_time,
        :some,
        :tenant,
        :time_to_seconds,
        :unit,
        :utf8,
        :valid_date,
        :value,
        :world,
        :x,
        :y,
        :z,
        :zero
      ]
    }
  }

  defp assert_safe(source, input \\ :ok, manifest \\ @safe_manifest) do
    {:ok, program} = Hyperlang.Test.program(source, manifest)

    assert eval(program, input) == {:ok, oracle!(source, input)}
  end

  defp eval(program, input, policy \\ %{}) do
    case Hyperlang.Test.run(program, :entry, [input], policy: policy) do
      {:ok, result, %{stdout: []}} -> {:ok, result}
      other -> other
    end
  end

  defp assert_unsafe_compile(source, manifest \\ @safe_manifest) do
    assert {:error, [_ | _]} = Hyperlang.Test.program(source, manifest)
  end

  defp assert_safe_compile(source, manifest \\ @safe_manifest) do
    assert {:ok, _program} = Hyperlang.Test.program(source, manifest)
  end

  defp assert_unsafe_eval(source, input, manifest \\ @safe_manifest, options \\ %{}) do
    {:ok, program} = Hyperlang.Test.program(source, manifest)

    assert {:error, _reason} = eval(program, input, options)
  end

  defp oracle!(source, input) do
    forms = [
      {:attribute, 0, :module, @oracle_module},
      {:attribute, 0, :export, [result: 1]},
      {:function, 0, :result, 1, [{:clause, 0, [{:var, 0, :Input}], [], oracle_exprs(source)}]}
    ]

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

  defp ensure_dot(source) do
    if source |> String.trim_trailing() |> String.ends_with?(".") do
      source
    else
      source <> "."
    end
  end

  test "oracle is test-only and battery has broad manual coverage" do
    source = File.read!(__ENV__.file)

    assert Regex.scan(~r/^\s*test "safe \d{3}/m, source) |> length() >= 150
    assert Regex.scan(~r/^\s*test "unsafe \d{3}/m, source) |> length() >= 150

    assert {:error, [%{category: :verify}]} =
             Hyperlang.Test.program("#{@oracle_module}:result(Input).", @safe_manifest)
  end

  test "safe 001 integer addition" do
    assert_safe("1 + 2.")
  end

  test "safe 002 arithmetic precedence" do
    assert_safe("1 + 2 * 3.")
  end

  test "safe 003 parenthesized arithmetic" do
    assert_safe("(1 + 2) * 3.")
  end

  test "safe 004 unary arithmetic" do
    assert_safe("-5 + +2.")
  end

  test "safe 005 integer division" do
    assert_safe("17 div 5.")
  end

  test "safe 006 integer remainder" do
    assert_safe("17 rem 5.")
  end

  test "safe 007 bitwise and" do
    assert_safe("7 band 3.")
  end

  test "safe 008 bitwise or" do
    assert_safe("4 bor 1.")
  end

  test "safe 009 bitwise xor" do
    assert_safe("7 bxor 2.")
  end

  test "safe 010 shift left" do
    assert_safe("3 bsl 4.")
  end

  test "safe 011 shift right" do
    assert_safe("64 bsr 3.")
  end

  test "safe 012 boolean andalso" do
    assert_safe("true andalso false.")
  end

  test "safe 013 boolean orelse" do
    assert_safe("false orelse true.")
  end

  test "safe 014 boolean not" do
    assert_safe("not false.")
  end

  test "safe 015 less than comparison" do
    assert_safe("2 < 3.")
  end

  test "safe 016 exact equality" do
    assert_safe("2 =:= 2.")
  end

  test "safe 017 non exact inequality" do
    assert_safe("2 =/= 3.")
  end

  test "safe 018 term equality" do
    assert_safe("2 == 2.0.")
  end

  test "safe 019 term inequality" do
    assert_safe("2 /= 3.")
  end

  test "safe 020 tuple literal" do
    assert_safe("{ok, 1, 2}.")
  end

  test "safe 021 tuple pattern case" do
    assert_safe("case {ok, 4} of {ok, X} -> X end.")
  end

  test "safe 022 list literal" do
    assert_safe("[1, 2, 3].")
  end

  test "safe 023 list append" do
    assert_safe("[1, 2] ++ [3, 4].")
  end

  test "safe 024 list subtract" do
    assert_safe("[1, 2, 3] -- [2].")
  end

  test "safe 025 proper cons syntax" do
    assert_safe("[0 | [1, 2]].")
  end

  test "safe 026 map literal" do
    assert_safe("\#{a => 1, b => 2}.")
  end

  test "safe 027 map exact update" do
    assert_safe("M = \#{a => 1}, M\#{a := 2}.")
  end

  test "safe 028 map pattern case" do
    assert_safe("case \#{a => 3} of \#{a := X} -> X end.")
  end

  test "safe 029 binary literal" do
    assert_safe("<<65, 66, 67>>.")
  end

  test "safe 030 binary construction from input" do
    assert_safe("<<Input>>.", 65)
  end

  test "safe 031 character literal" do
    assert_safe("$A.")
  end

  test "safe 032 string literal" do
    assert_safe("\"abc\".")
  end

  test "safe 033 begin block" do
    assert_safe("begin A = 1, A + 2 end.")
  end

  test "safe 034 expression sequence" do
    assert_safe("A = 1, B = 2, A + B.")
  end

  test "safe 035 case with literal arms" do
    assert_safe("case Input of 0 -> zero; _ -> pos end.", 9)
  end

  test "safe 036 case with guard" do
    assert_safe("case Input of X when X > 3 -> X; _ -> 0 end.", 5)
  end

  test "safe 037 case with alternate guards" do
    assert_safe(
      "case Input of X when is_integer(X); is_binary(X) -> ok; _ -> error end.",
      <<"x">>
    )
  end

  test "safe 037b case clause variables are scoped independently" do
    source = ~S"""
    Sessions = [#{id => 1}],
    Count = case Sessions of
      #{count := C} -> C;
      L when is_list(L) -> length(L);
      _ -> 0
    end,
    Ids = case Sessions of
      #{results := Rs} -> [maps:get(id, R) || R <- Rs, is_map_key(id, R)];
      L when is_list(L) -> [maps:get(id, R) || R <- L, is_map(R), is_map_key(id, R)];
      _ -> []
    end,
    #{count => Count, ids => Ids}.
    """

    {:ok, program} = Hyperlang.Test.program(source, @safe_manifest)

    assert eval(program, :ok) == {:ok, %{count: 1, ids: [1]}}
  end

  test "safe 038 if expression" do
    assert_safe("if Input > 0 -> pos; true -> zero end.", 1)
  end

  test "safe 039 if with compound guard" do
    assert_safe("if is_integer(Input), Input > 2 -> ok; true -> error end.", 3)
  end

  test "safe 040 try success" do
    assert_safe("try 1 + 2 catch error:badarith -> 0 end.")
  end

  test "safe 041 try catch badarith" do
    assert_safe("try 1 div 0 catch error:badarith -> ok end.")
  end

  test "safe 041b try of catch" do
    assert_safe("try Input of 1 -> ok; 2 -> error catch error:badarith -> badarith end.", 2)
  end

  test "safe 041c try of catch protects only body" do
    assert_safe("try 1 div 0 of X -> X catch error:badarith -> ok end.")
  end

  test "safe 042 list comprehension" do
    assert_safe("[X * 2 || X <- [1, 2, 3]].")
  end

  test "safe 043 list comprehension filter" do
    assert_safe("[X || X <- [1, 2, 3, 4], X rem 2 =:= 0].")
  end

  test "safe 044 list comprehension pattern" do
    assert_safe("[X || {ok, X} <- [{ok, 1}, error, {ok, 2}]].")
  end

  test "safe 045 map comprehension" do
    assert_safe("\#{X => X * 10 || X <- [1, 2, 3]}.")
  end

  test "safe 046 binary comprehension from list" do
    assert_safe("<< <<X>> || X <- [65, 66, 67] >>.")
  end

  test "safe 047 binary comprehension from binary" do
    assert_safe("<< <<X>> || <<X>> <= <<65, 66, 67>>, X > 65 >>.")
  end

  test "safe 225 lists map callback" do
    assert_safe("lists:map(fun(X) -> X + 1 end, [1, 2, 3]).")
  end

  test "safe 226 lists filter callback" do
    assert_safe("lists:filter(fun(X) -> X > 2 end, [1, 2, 3]).")
  end

  test "safe 227 lists foldl callback" do
    assert_safe("lists:foldl(fun(X, Acc) -> X + Acc end, 0, [1, 2, 3]).")
  end

  test "safe 228 lists foldr callback" do
    assert_safe("lists:foldr(fun(X, Acc) -> [X | Acc] end, [], [1, 2]).")
  end

  test "safe 229 lists all callback" do
    assert_safe("lists:all(fun(X) -> X > 0 end, [1, 2, 3]).")
  end

  test "safe 230 lists any callback" do
    assert_safe("lists:any(fun(X) -> X =:= 2 end, [1, 2, 3]).")
  end

  test "safe 231 lists sort callback" do
    assert_safe("lists:sort(fun(A, B) -> A >= B end, [1, 3, 2]).")
  end

  test "safe 232 callback captures outer input" do
    assert_safe("lists:map(fun(X) -> X + Input end, [1, 2]).", 10)
  end

  test "safe 056 erlang abs" do
    assert_safe("abs(-9).")
  end

  test "safe 057 erlang length" do
    assert_safe("length([a, b, c]).")
  end

  test "safe 058 erlang byte_size" do
    assert_safe("byte_size(<<1, 2, 3>>).")
  end

  test "safe 059 erlang tuple_size" do
    assert_safe("tuple_size({a, b, c}).")
  end

  test "safe 060 erlang map_size" do
    assert_safe("map_size(\#{a => 1, b => 2}).")
  end

  test "safe 061 erlang round" do
    assert_safe("round(3.6).")
  end

  test "safe 062 erlang trunc" do
    assert_safe("trunc(3.6).")
  end

  test "safe 063 erlang float" do
    assert_safe("float(7).")
  end

  test "safe 064 integer_to_binary decimal" do
    assert_safe("integer_to_binary(255).")
  end

  test "safe 065 integer_to_binary base" do
    assert_safe("integer_to_binary(255, 16).")
  end

  test "safe 066 binary_to_integer decimal" do
    assert_safe("binary_to_integer(<<\"123\">>).")
  end

  test "safe 067 binary_to_integer base" do
    assert_safe("binary_to_integer(<<\"ff\">>, 16).")
  end

  test "safe 247 erlang iolist_to_binary wrapped stdlib" do
    assert_safe("erlang:iolist_to_binary([<<\"a\">>, [<<\"b\">>, \"c\"]]).")
  end

  test "safe 248 erlang element direct allowlist" do
    assert_safe("element(2, {a, b, c}).")
  end

  test "safe 249 erlang setelement direct allowlist" do
    assert_safe("setelement(2, {a, b, c}, z).")
  end

  test "safe 250 erlang append element direct allowlist" do
    assert_safe("erlang:append_element({a, b}, c).")
  end

  test "safe 251 erlang insert delete element direct allowlist" do
    assert_safe("erlang:delete_element(2, erlang:insert_element(2, {a, c}, b)).")
  end

  test "safe 252 erlang make tuple direct allowlist" do
    assert_safe("erlang:make_tuple(3, a, [{2, b}]).")
  end

  test "safe 253 erlang binary part direct allowlist" do
    assert_safe("{binary_part(<<\"abcdef\">>, {1, 3}), binary_part(<<\"abcdef\">>, 2, 2)}.")
  end

  test "safe 254 erlang binary to list three arity direct allowlist" do
    assert_safe("binary_to_list(<<\"abcdef\">>, 2, 4).")
  end

  test "safe 255 erlang integer and float list conversions" do
    assert_safe("{integer_to_list(255, 16), float_to_list(1.25, [{decimals, 2}, compact])}.")
  end

  test "safe 256 erlang type predicates remain direct allowlisted" do
    assert_safe(
      ~S|{erlang:is_map_key(a, #{a => 1}), erlang:is_atom(foo), erlang:is_boolean(true)}.|
    )
  end

  test "safe 257 erlang checksum bif direct allowlist" do
    assert_safe(
      "{erlang:crc32(<<\"abc\">>), erlang:adler32(<<\"abc\">>), erlang:md5(<<\"abc\">>)}."
    )
  end

  test "safe 258 erlang checksum continuation bif direct allowlist" do
    assert_safe(
      "{erlang:crc32_combine(erlang:crc32(<<\"a\">>), erlang:crc32(<<\"bc\">>), 2), erlang:adler32_combine(erlang:adler32(<<\"a\">>), erlang:adler32(<<\"bc\">>), 2)}."
    )
  end

  test "safe 259 erlang md5 continuation bif direct allowlist" do
    assert_safe("C = erlang:md5_update(erlang:md5_init(), <<\"abc\">>), erlang:md5_final(C).")
  end

  test "safe 260 erlang phash direct allowlist" do
    assert_safe(
      "{erlang:phash2({a, 1}), erlang:phash2({a, 1}, 1000), erlang:phash({a, 1}, 1000)}."
    )
  end

  test "safe 261 erlang iolist to iovec direct allowlist" do
    assert_safe("erlang:iolist_to_iovec([<<\"a\">>, [<<\"b\">>, \"c\"]]).")
  end

  test "safe 262 erlang bitstring list conversions direct allowlist" do
    assert_safe("{bit_size(list_to_bitstring([<<1:1>>])), length(bitstring_to_list(<<1:1>>))}.")
  end

  test "safe 263 erlang list append and subtract direct allowlist" do
    assert_safe("{erlang:append([1, 2], [3]), erlang:subtract([1, 2, 3], [2])}.")
  end

  test "safe 264 erlang deterministic time conversion direct allowlist" do
    assert_safe(
      "{erlang:convert_time_unit(2, second, millisecond), erlang:posixtime_to_universaltime(0), erlang:universaltime_to_posixtime({{1970, 1, 1}, {0, 0, 0}})}."
    )
  end

  test "safe 265 erlang safe type predicates for unsupported external terms" do
    assert_safe("{is_pid(Input), is_port(Input), is_reference(Input)}.")
  end

  test "safe 068 float_to_binary compact" do
    assert_safe("float_to_binary(1.25, [compact]).")
  end

  test "safe 069 is_integer" do
    assert_safe("is_integer(Input).", 1)
  end

  test "safe 070 is_float" do
    assert_safe("is_float(Input).", 1.0)
  end

  test "safe 071 is_number" do
    assert_safe("is_number(Input).", 1.0)
  end

  test "safe 072 is_binary" do
    assert_safe("is_binary(Input).", <<"x">>)
  end

  test "safe 073 is_list" do
    assert_safe("is_list(Input).", [1, 2])
  end

  test "safe 074 is_tuple" do
    assert_safe("is_tuple(Input).", {:ok, 1})
  end

  test "safe 075 is_map" do
    assert_safe("is_map(Input).", %{a: 1})
  end

  test "safe 076 is_boolean" do
    assert_safe("is_boolean(Input).", true)
  end

  test "safe 077 erlang min" do
    assert_safe("min(4, 9).")
  end

  test "safe 078 erlang max" do
    assert_safe("max(4, 9).")
  end

  test "safe 079 math pi" do
    assert_safe("math:pi().")
  end

  test "safe 080 math tau" do
    assert_safe("math:tau().")
  end

  test "safe 081 math sin" do
    assert_safe("math:sin(0.0).")
  end

  test "safe 082 math cos" do
    assert_safe("math:cos(0.0).")
  end

  test "safe 083 math tan" do
    assert_safe("math:tan(0.5).")
  end

  test "safe 084 math asin" do
    assert_safe("math:asin(0.5).")
  end

  test "safe 085 math acos" do
    assert_safe("math:acos(0.5).")
  end

  test "safe 086 math atan" do
    assert_safe("math:atan(1.0).")
  end

  test "safe 087 math atan2" do
    assert_safe("math:atan2(1.0, 2.0).")
  end

  test "safe 088 math sinh" do
    assert_safe("math:sinh(0.5).")
  end

  test "safe 089 math cosh" do
    assert_safe("math:cosh(0.5).")
  end

  test "safe 090 math tanh" do
    assert_safe("math:tanh(0.5).")
  end

  test "safe 091 math sqrt" do
    assert_safe("math:sqrt(81.0).")
  end

  test "safe 092 math log" do
    assert_safe("math:log(10.0).")
  end

  test "safe 093 math log2" do
    assert_safe("math:log2(8.0).")
  end

  test "safe 094 math log10" do
    assert_safe("math:log10(100.0).")
  end

  test "safe 095 math exp" do
    assert_safe("math:exp(1.0).")
  end

  test "safe 096 math pow" do
    assert_safe("math:pow(2.0, 8.0).")
  end

  test "safe 097 math floor" do
    assert_safe("math:floor(3.8).")
  end

  test "safe 098 math ceil" do
    assert_safe("math:ceil(3.2).")
  end

  test "safe 099 math fmod" do
    assert_safe("math:fmod(7.5, 2.0).")
  end

  test "safe 100 math erf" do
    assert_safe("math:erf(1.0).")
  end

  test "safe 101 lists append one" do
    assert_safe("lists:append([[1], [2, 3]]).")
  end

  test "safe 102 lists append two" do
    assert_safe("lists:append([1, 2], [3]).")
  end

  test "safe 103 lists reverse one" do
    assert_safe("lists:reverse([1, 2, 3]).")
  end

  test "safe 104 lists reverse two" do
    assert_safe("lists:reverse([1, 2], [3]).")
  end

  test "safe 105 lists seq two" do
    assert_safe("lists:seq(1, 4).")
  end

  test "safe 106 lists seq three" do
    assert_safe("lists:seq(1, 7, 2).")
  end

  test "safe 107 lists sum" do
    assert_safe("lists:sum([1, 2, 3]).")
  end

  test "safe 108 lists min" do
    assert_safe("lists:min([3, 1, 2]).")
  end

  test "safe 109 lists max" do
    assert_safe("lists:max([3, 1, 2]).")
  end

  test "safe 110 lists sublist two" do
    assert_safe("lists:sublist([1, 2, 3], 2).")
  end

  test "safe 111 lists sublist three" do
    assert_safe("lists:sublist([1, 2, 3, 4], 2, 2).")
  end

  test "safe 112 lists zip" do
    assert_safe("lists:zip([a, b], [1, 2]).")
  end

  test "safe 113 lists zip3" do
    assert_safe("lists:zip3([a], [b], [c]).")
  end

  test "safe 114 lists member" do
    assert_safe("lists:member(b, [a, b, c]).")
  end

  test "safe 115 lists nth" do
    assert_safe("lists:nth(2, [a, b, c]).")
  end

  test "safe 116 lists join" do
    assert_safe("lists:join(0, [1, 2, 3]).")
  end

  test "safe 117 lists enumerate one" do
    assert_safe("lists:enumerate([a, b]).")
  end

  test "safe 118 lists enumerate two" do
    assert_safe("lists:enumerate(10, [a, b]).")
  end

  test "safe 119 maps get two" do
    assert_safe("maps:get(a, \#{a => 1}).")
  end

  test "safe 120 maps get three" do
    assert_safe("maps:get(z, \#{a => 1}, none).")
  end

  test "safe 121 maps find" do
    assert_safe("maps:find(a, \#{a => 1}).")
  end

  test "safe 122 maps is_key" do
    assert_safe("maps:is_key(a, \#{a => 1}).")
  end

  test "safe 123 maps keys" do
    assert_safe("maps:keys(\#{a => 1, b => 2}).")
  end

  test "safe 124 maps values" do
    assert_safe("maps:values(\#{a => 1, b => 2}).")
  end

  test "safe 125 maps to_list" do
    assert_safe("maps:to_list(\#{a => 1}).")
  end

  test "safe 126 maps from_list" do
    assert_safe("maps:from_list([{a, 1}, {b, 2}]).")
  end

  test "safe 127 maps put" do
    assert_safe("maps:put(b, 2, \#{a => 1}).")
  end

  test "safe 128 maps remove" do
    assert_safe("maps:remove(a, \#{a => 1, b => 2}).")
  end

  test "safe 129 maps take" do
    assert_safe("maps:take(a, \#{a => 1}).")
  end

  test "safe 130 maps merge" do
    assert_safe("maps:merge(\#{a => 1}, \#{b => 2}).")
  end

  test "safe 131 maps size" do
    assert_safe("maps:size(\#{a => 1, b => 2}).")
  end

  test "safe 132 binary at" do
    assert_safe("binary:at(<<65, 66>>, 1).")
  end

  test "safe 133 binary bin_to_list one" do
    assert_safe("binary:bin_to_list(<<65, 66>>).")
  end

  test "safe 134 binary bin_to_list two" do
    assert_safe("binary:bin_to_list(<<65, 66, 67>>, {1, 2}).")
  end

  test "safe 135 binary bin_to_list three" do
    assert_safe("binary:bin_to_list(<<65, 66, 67>>, 1, 2).")
  end

  test "safe 136 binary list_to_bin" do
    assert_safe("binary:list_to_bin([65, 66]).")
  end

  test "safe 137 binary copy one" do
    assert_safe("binary:copy(<<\"ab\">>).")
  end

  test "safe 138 binary copy two" do
    assert_safe("binary:copy(<<\"ab\">>, 2).")
  end

  test "safe 139 binary part tuple" do
    assert_safe("binary:part(<<\"abcdef\">>, {1, 3}).")
  end

  test "safe 140 binary part args" do
    assert_safe("binary:part(<<\"abcdef\">>, 2, 2).")
  end

  test "safe 141 binary match" do
    assert_safe("binary:match(<<\"abcabc\">>, <<\"bc\">>).")
  end

  test "safe 142 binary matches" do
    assert_safe("binary:matches(<<\"abcabc\">>, <<\"bc\">>).")
  end

  test "safe 143 binary split" do
    assert_safe("binary:split(<<\"a,b,c\">>, <<\",\">>, [global]).")
  end

  test "safe 144 binary replace" do
    assert_safe("binary:replace(<<\"banana\">>, <<\"na\">>, <<\"NA\">>, [global]).")
  end

  test "safe 145 binary encode hex" do
    assert_safe("binary:encode_hex(<<10, 11, 12>>).")
  end

  test "safe 146 binary decode hex" do
    assert_safe("binary:decode_hex(<<\"0A0B0C\">>).")
  end

  test "safe 147 binary join" do
    assert_safe("binary:join([<<\"a\">>, <<\"b\">>], <<\",\">>).")
  end

  test "safe 148 unicode chars to binary" do
    assert_safe("unicode:characters_to_binary(\"abc\").")
  end

  test "safe 149 unicode chars to binary enc" do
    assert_safe("unicode:characters_to_binary(\"abc\", latin1, utf8).")
  end

  test "safe 150 unicode chars to list" do
    assert_safe("unicode:characters_to_list(<<\"abc\">>, utf8).")
  end

  test "safe 151 unicode bin is 7bit" do
    assert_safe("unicode:bin_is_7bit(<<\"abc\">>).")
  end

  test "safe 152 string length" do
    assert_safe("string:length(\"abc\").")
  end

  test "safe 153 string lowercase" do
    assert_safe("string:lowercase(\"ABC\").")
  end

  test "safe 154 string uppercase" do
    assert_safe("string:uppercase(\"abc\").")
  end

  test "safe 155 string casefold" do
    assert_safe("string:casefold(\"ABC\").")
  end

  test "safe 156 string titlecase" do
    assert_safe("string:titlecase(\"hello world\").")
  end

  test "safe 157 string trim one" do
    assert_safe("string:trim(\"  abc  \").")
  end

  test "safe 158 string trim two" do
    assert_safe("string:trim(\"  abc  \", leading).")
  end

  test "safe 159 string split" do
    assert_safe("string:split(\"a,b,c\", \",\", all).")
  end

  test "safe 160 string replace" do
    assert_safe("string:replace(\"banana\", \"na\", \"NA\", all).")
  end

  test "safe 161 string prefix" do
    assert_safe("string:prefix(\"foobar\", \"foo\").")
  end

  test "safe 162 string find" do
    assert_safe("string:find(\"foobar\", \"bar\").")
  end

  test "safe 163 string pad" do
    assert_safe("string:pad(\"x\", 3).")
  end

  test "safe 164 string slice" do
    assert_safe("string:slice(\"abcdef\", 2, 3).")
  end

  test "safe 165 string join" do
    assert_safe("string:join([\"a\", \"b\"], \",\").")
  end

  test "safe 166 calendar valid date tuple" do
    assert_safe("calendar:valid_date({2024, 2, 29}).")
  end

  test "safe 167 calendar valid date args" do
    assert_safe("calendar:valid_date(2024, 2, 29).")
  end

  test "safe 168 calendar leap year" do
    assert_safe("calendar:is_leap_year(2024).")
  end

  test "safe 169 calendar last day" do
    assert_safe("calendar:last_day_of_the_month(2024, 2).")
  end

  test "safe 170 calendar date to days tuple" do
    assert_safe("calendar:date_to_gregorian_days({1970, 1, 1}).")
  end

  test "safe 171 calendar days to date" do
    assert_safe("calendar:gregorian_days_to_date(719528).")
  end

  test "safe 172 calendar day of week" do
    assert_safe("calendar:day_of_the_week({2026, 5, 14}).")
  end

  test "safe 173 calendar iso week" do
    assert_safe("calendar:iso_week_number({2026, 5, 14}).")
  end

  test "safe 174 calendar datetime seconds" do
    assert_safe("calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}}).")
  end

  test "safe 175 calendar seconds datetime" do
    assert_safe("calendar:gregorian_seconds_to_datetime(62167219200).")
  end

  test "safe 176 calendar seconds to time" do
    assert_safe("calendar:seconds_to_time(3661).")
  end

  test "safe 177 calendar time to seconds" do
    assert_safe("calendar:time_to_seconds({1, 1, 1}).")
  end

  test "safe 178 calendar system time universal" do
    assert_safe("calendar:system_time_to_universal_time(0, second).")
  end

  test "safe 179 calendar rfc3339" do
    assert_safe("calendar:system_time_to_rfc3339(0, [{unit, second}, {offset, \"Z\"}]).")
  end

  test "safe 180 calendar parse rfc3339" do
    assert_safe("calendar:rfc3339_to_system_time(\"1970-01-01T00:00:00Z\", [{unit, second}]).")
  end

  test "safe 181 sets new size" do
    assert_safe("sets:size(sets:new()).")
  end

  test "safe 182 sets from list to list" do
    assert_safe("sets:to_list(sets:from_list([3, 1, 2])).")
  end

  test "safe 183 sets add element" do
    assert_safe("sets:is_element(3, sets:add_element(3, sets:from_list([1, 2]))).")
  end

  test "safe 184 sets delete element" do
    assert_safe("sets:to_list(sets:del_element(2, sets:from_list([1, 2, 3]))).")
  end

  test "safe 185 sets union" do
    assert_safe("sets:to_list(sets:union(sets:from_list([1]), sets:from_list([2]))).")
  end

  test "safe 186 sets intersection" do
    assert_safe(
      "sets:to_list(sets:intersection(sets:from_list([1, 2]), sets:from_list([2, 3])))."
    )
  end

  test "safe 187 sets subtract" do
    assert_safe("sets:to_list(sets:subtract(sets:from_list([1, 2]), sets:from_list([2]))).")
  end

  test "safe 188 sets subset" do
    assert_safe("sets:is_subset(sets:from_list([1]), sets:from_list([1, 2])).")
  end

  test "safe 189 ordsets new" do
    assert_safe("ordsets:size(ordsets:new()).")
  end

  test "safe 190 ordsets from list" do
    assert_safe("ordsets:to_list(ordsets:from_list([3, 1, 2])).")
  end

  test "safe 191 ordsets add" do
    assert_safe("ordsets:to_list(ordsets:add_element(3, ordsets:from_list([1, 2]))).")
  end

  test "safe 192 ordsets delete" do
    assert_safe("ordsets:to_list(ordsets:del_element(2, ordsets:from_list([1, 2, 3]))).")
  end

  test "safe 193 ordsets union" do
    assert_safe("ordsets:union(ordsets:from_list([1]), ordsets:from_list([2])).")
  end

  test "safe 194 ordsets intersection" do
    assert_safe("ordsets:intersection(ordsets:from_list([1, 2]), ordsets:from_list([2, 3])).")
  end

  test "safe 195 ordsets subtract" do
    assert_safe("ordsets:subtract(ordsets:from_list([1, 2]), ordsets:from_list([2])).")
  end

  test "safe 196 ordsets subset" do
    assert_safe("ordsets:is_subset(ordsets:from_list([1]), ordsets:from_list([1, 2])).")
  end

  test "safe 197 queue new empty" do
    assert_safe("queue:is_empty(queue:new()).")
  end

  test "safe 198 queue from list" do
    assert_safe("queue:to_list(queue:from_list([1, 2])).")
  end

  test "safe 199 queue in" do
    assert_safe("queue:to_list(queue:in(3, queue:from_list([1, 2]))).")
  end

  test "safe 200 queue len" do
    assert_safe("queue:len(queue:from_list([1, 2, 3])).")
  end

  test "safe 201 gb sets empty" do
    assert_safe("gb_sets:size(gb_sets:empty()).")
  end

  test "safe 202 gb sets from list" do
    assert_safe("gb_sets:to_list(gb_sets:from_list([3, 1, 2])).")
  end

  test "safe 203 gb sets add" do
    assert_safe("gb_sets:to_list(gb_sets:add(3, gb_sets:from_list([1, 2]))).")
  end

  test "safe 204 gb sets delete any" do
    assert_safe("gb_sets:to_list(gb_sets:delete_any(2, gb_sets:from_list([1, 2, 3]))).")
  end

  test "safe 205 gb sets union" do
    assert_safe("gb_sets:to_list(gb_sets:union(gb_sets:from_list([1]), gb_sets:from_list([2]))).")
  end

  test "safe 206 gb sets intersection" do
    assert_safe(
      "gb_sets:to_list(gb_sets:intersection(gb_sets:from_list([1, 2]), gb_sets:from_list([2, 3])))."
    )
  end

  test "safe 207 gb sets subtract" do
    assert_safe(
      "gb_sets:to_list(gb_sets:subtract(gb_sets:from_list([1, 2]), gb_sets:from_list([2])))."
    )
  end

  test "safe 208 gb sets subset" do
    assert_safe("gb_sets:is_subset(gb_sets:from_list([1]), gb_sets:from_list([1, 2])).")
  end

  test "safe 209 gb trees empty size" do
    assert_safe("gb_trees:size(gb_trees:empty()).")
  end

  test "safe 210 gb trees insert get" do
    assert_safe("gb_trees:get(a, gb_trees:insert(a, 1, gb_trees:empty())).")
  end

  test "safe 211 gb trees lookup" do
    assert_safe("gb_trees:lookup(a, gb_trees:insert(a, 1, gb_trees:empty())).")
  end

  test "safe 212 gb trees to list" do
    assert_safe(
      "gb_trees:to_list(gb_trees:insert(b, 2, gb_trees:insert(a, 1, gb_trees:empty())))."
    )
  end

  test "safe 213 gb trees delete any" do
    assert_safe(
      "gb_trees:to_list(gb_trees:delete_any(a, gb_trees:insert(a, 1, gb_trees:empty())))."
    )
  end

  test "safe 214 re run match" do
    assert_safe("re:run(<<\"abc\">>, <<\"b\">>).")
  end

  test "safe 215 re run captured binary" do
    assert_safe("re:run(<<\"abc123\">>, <<\"([a-z]+)([0-9]+)\">>, [{capture, all, binary}]).")
  end

  test "safe 216 re split" do
    assert_safe("re:split(<<\"a,b,c\">>, <<\",\">>, [{return, binary}]).")
  end

  test "safe 217 re replace" do
    assert_safe("re:replace(<<\"abcabc\">>, <<\"a\">>, <<\"x\">>, [global, {return, binary}]).")
  end

  test "safe 218 nested stdlib" do
    assert_safe("lists:sum(maps:values(\#{a => 1, b => 2})).")
  end

  test "safe 219 nested binary string" do
    assert_safe("string:uppercase(unicode:characters_to_binary(\"abc\")).")
  end

  test "safe 220 nested calendar map" do
    assert_safe("\#{day => calendar:day_of_the_week({2026,5,14})}.")
  end

  test "unsafe 001 binary to atom literal creation" do
    assert_unsafe_compile("binary_to_atom(<<\"not_allowed_atom\">>).")
  end

  test "unsafe 002 module source without result root" do
    assert_unsafe_compile("-module(bad). helper(Input) -> Input.")
  end

  test "unsafe 003 export metadata without result root" do
    assert_unsafe_compile("-export([helper/1]). helper(Input) -> Input.")
  end

  test "unsafe 004 compile attribute" do
    assert_unsafe_compile("-compile(export_all). result(Input) -> Input.")
  end

  test "unsafe 005 on load attribute" do
    assert_unsafe_compile("-on_load(init/0). result(Input) -> Input.")
  end

  test "unsafe 006 include attribute" do
    assert_unsafe_compile("-include(\"x.hrl\"). result(Input) -> Input.")
  end

  test "unsafe 007 include lib attribute" do
    assert_unsafe_compile("-include_lib(\"kernel/include/file.hrl\"). result(Input) -> Input.")
  end

  test "unsafe 008 define attribute" do
    assert_unsafe_compile("-define(X, 1). result(Input) -> Input.")
  end

  test "safe 226 record attribute" do
    assert_safe_compile("-record(r, {a}). result(Input) -> Input.")
  end

  test "unsafe 010 type attribute" do
    assert_unsafe_compile("-type t() :: integer(). result(Input) -> Input.")
  end

  test "safe 011 spec attribute is inert contract metadata" do
    {:ok, program} =
      Hyperlang.Test.program(
        "-spec result(term()) -> term(). result(Input) -> Input.",
        @safe_manifest
      )

    assert eval(program, 7) == {:ok, 7}
  end

  test "unsafe 012 callback attribute" do
    assert_unsafe_compile("-callback run(term()) -> term().")
  end

  test "safe 013 behaviour attribute is inert contract metadata" do
    {:ok, program} =
      Hyperlang.Test.program(
        "-behaviour(gen_server). result(Input) -> Input.",
        @safe_manifest
      )

    assert eval(program, 7) == {:ok, 7}
  end

  test "unsafe 014 nifs attribute" do
    assert_unsafe_compile("-nifs([f/1]). result(Input) -> Input.")
  end

  test "unsafe 015 import attribute" do
    assert_unsafe_compile("-import(lists, [map/2]). result(Input) -> Input.")
  end

  test "unsafe 016 file attribute" do
    assert_unsafe_compile("-file(\"x\", 1). result(Input) -> Input.")
  end

  test "unsafe 017 opaque attribute" do
    assert_unsafe_compile("-opaque t() :: integer(). result(Input) -> Input.")
  end

  test "unsafe 018 export type attribute" do
    assert_unsafe_compile("-export_type([t/0]). result(Input) -> Input.")
  end

  test "unsafe 019 macro usage" do
    assert_unsafe_compile("?X.")
  end

  test "unsafe 020 record expression" do
    assert_unsafe_compile("#r{a = 1}.")
  end

  test "unsafe 021 record field access" do
    assert_unsafe_compile("Input#r.a.")
  end

  test "unsafe 022 record update" do
    assert_unsafe_compile("Input#r{a = 1}.")
  end

  test "safe 023 receive compiles" do
    assert_safe_compile("receive X -> X end.")
  end

  test "safe 024 receive after" do
    assert_safe("receive after 0 -> ok end.")
  end

  test "safe 025 send operator compiles" do
    assert_safe_compile("Input ! ok.")
  end

  test "unsafe 026 self local" do
    assert_unsafe_compile("self().")
  end

  test "unsafe 027 self remote" do
    assert_unsafe_compile("erlang:self().")
  end

  test "unsafe 028 spawn local fails closed without policy" do
    assert_unsafe_eval("spawn(fun() -> ok end).", :ok)
  end

  test "unsafe 029 spawn remote fails closed without policy" do
    assert_unsafe_eval("erlang:spawn(fun() -> ok end).", :ok)
  end

  test "unsafe 030 spawn link local" do
    assert_unsafe_eval("spawn_link(fun() -> ok end).", :ok)
  end

  test "unsafe 031 spawn monitor local" do
    assert_unsafe_eval("spawn_monitor(fun() -> ok end).", :ok)
  end

  test "unsafe 032 spawn opt local" do
    assert_unsafe_compile("spawn_opt(fun() -> ok end, []).")
  end

  test "unsafe 033 link local" do
    assert_unsafe_eval("link(Input).", 123)
  end

  test "unsafe 034 unlink local" do
    assert_unsafe_eval("unlink(Input).", 123)
  end

  test "unsafe 035 monitor local" do
    assert_unsafe_eval("monitor(process, Input).", 123)
  end

  test "unsafe 036 demonitor local" do
    assert_unsafe_eval("demonitor(Input).", 123)
  end

  test "unsafe 037 process flag local" do
    assert_unsafe_eval("process_flag(trap_exit, true).", :ok)
  end

  test "unsafe 038 process info local" do
    assert_unsafe_compile("process_info(Input).")
  end

  test "unsafe 039 register local" do
    assert_unsafe_eval("register(name, Input).", 123)
  end

  test "unsafe 040 whereis local" do
    assert_unsafe_eval("whereis(name).", :ok)
  end

  test "unsafe 041 group leader local" do
    assert_unsafe_compile("group_leader().")
  end

  test "unsafe 042 group leader arity two" do
    assert_unsafe_compile("group_leader(Input, Input).")
  end

  test "unsafe 043 erlang halt" do
    assert_unsafe_compile("erlang:halt().")
  end

  test "unsafe 044 erlang halt one" do
    assert_unsafe_compile("erlang:halt(1).")
  end

  test "unsafe 045 erlang open port" do
    assert_unsafe_compile("erlang:open_port({spawn, \"sh\"}, []).")
  end

  test "unsafe 046 erlang load nif" do
    assert_unsafe_compile("erlang:load_nif(\"x\", 0).")
  end

  test "unsafe 047 erlang system flag" do
    assert_unsafe_compile("erlang:system_flag(schedulers_online, 1).")
  end

  test "unsafe 048 erlang put" do
    assert_unsafe_compile("erlang:put(a, b).")
  end

  test "unsafe 049 erlang get" do
    assert_unsafe_compile("erlang:get(a).")
  end

  test "unsafe 050 erlang erase" do
    assert_unsafe_compile("erlang:erase(a).")
  end

  test "native 051 erlang send after" do
    assert_safe_compile("erlang:send_after(1, Input, ok).")
  end

  test "native 052 erlang start timer" do
    assert_safe_compile("erlang:start_timer(1, Input, ok).")
  end

  test "unsafe 053 erlang trace" do
    assert_unsafe_compile("erlang:trace(Input, true, []).")
  end

  test "unsafe 054 erlang trace pattern" do
    assert_unsafe_compile("erlang:trace_pattern({m, f, 1}, true, []).")
  end

  test "unsafe 055 erlang port command" do
    assert_unsafe_compile("erlang:port_command(Input, <<\"x\">>).")
  end

  test "unsafe 056 erlang port close" do
    assert_unsafe_compile("erlang:port_close(Input).")
  end

  test "unsafe 057 erlang port control" do
    assert_unsafe_compile("erlang:port_control(Input, 1, <<>>).")
  end

  test "unsafe 058 erlang port call" do
    assert_unsafe_compile("erlang:port_call(Input, 1, <<>>).")
  end

  test "unsafe 059 erlang apply" do
    assert_unsafe_compile("erlang:apply(foo, bar, []).")
  end

  test "unsafe 060 local apply" do
    assert_unsafe_compile("apply(foo, bar, []).")
  end

  test "unsafe 061 apply fun" do
    assert_unsafe_compile("apply(fun(X) -> X end, [1]).")
  end

  test "unsafe 062 dynamic remote variable" do
    assert_unsafe_compile("M:F().")
  end

  test "unsafe 063 dynamic remote function" do
    assert_unsafe_compile("erlang:F().")
  end

  test "safe 233 dynamic local fun application" do
    assert_safe("(fun(X) -> X end)(1).")
  end

  test "safe 234 lexical fun variable application" do
    assert_safe("F = fun(X) -> X + 1 end, F(1).")
  end

  test "safe 235 lexical fun variable callback" do
    assert_safe("F = fun(X) -> X * 2 end, lists:map(F, [1, 2, 3]).")
  end

  test "safe 236 named lexical fun recursion" do
    assert_safe("F = fun Loop(0) -> 0; Loop(N) -> Loop(N - 1) + 1 end, F(4).")
  end

  test "safe 237 sized integer bit syntax" do
    assert_safe("<<1:16>>.")
  end

  test "safe 238 endian and signed bit syntax" do
    assert_safe("<<1:16/little-unsigned-integer, -2:16/signed-integer>>.")
  end

  test "safe 239 binary segment splicing" do
    assert_safe("A = <<\"ab\">>, B = <<\"cd\">>, <<A/binary, B/binary>>.")
  end

  test "safe 240 utf8 segment match" do
    {:ok, program} = Hyperlang.Test.program("<<C/utf8>> = <<\"✦\">>, C.", @safe_manifest)

    assert eval(program, :ok) == {:ok, 0x2726}
  end

  test "safe 241 dynamic binary size pattern" do
    assert_safe("Len = 3, <<Payload:Len/binary, Rest/binary>> = <<\"abcZ\">>, {Payload, Rest}.")
  end

  test "safe 242 unit modifier construction" do
    assert_safe("<<0:4/unit:8>>.")
  end

  test "safe 243 sized binary generator" do
    assert_safe("<< <<X:4, 0:4>> || <<X:4>> <= <<16#AB>>, X > 10 >>.")
  end

  test "safe 244 float bit syntax" do
    assert_safe("<<F:64/float-little>> = <<1.5:64/float-little>>, F.")
  end

  test "safe 245 non byte aligned bitstring stays usable internally" do
    assert_safe("bit_size(<<1:1>>).")
  end

  test "safe 246 length-prefixed binary pattern" do
    assert_safe(
      "case <<3, \"abc\", \"z\">> of <<Len, Payload:Len/binary, Rest/binary>> -> {Payload, Rest} end."
    )
  end

  test "safe 266 wildcard match pattern positions" do
    assert_safe(
      ~S"""
      _ = Input,
      {_, X, {_, Y}} = {skip, 2, {ignore, 3}},
      [H | _] = [4, 5, 6],
      #{a := _} = #{a => 7},
      {X, Y, H}.
      """,
      ok: true
    )
  end

  test "safe 267 wildcard bitstring tail pattern segment" do
    assert_safe("Len = 3, <<Prefix:Len/binary, _/binary>> = <<\"abcdef\">>, Prefix.")
  end

  test "safe 268 wildcard sized bitstring pattern segments" do
    assert_safe("<<_:4, Keep:4, _Rest/binary>> = <<16#AB, 16#CD>>, Keep.")
  end

  test "safe 269 wildcard binary generator pattern segment" do
    assert_safe("[X || <<_:4, X:4>> <= <<16#AB, 16#CD>>].")
  end

  test "safe 270 wildcard nested binary case pattern" do
    assert_safe(
      "case <<2, \"hi\", \"!\">> of <<_:8, Payload:2/binary, _/binary>> -> Payload end."
    )
  end

  test "unsafe 065 external erlang fun" do
    assert_unsafe_compile("fun erlang:halt/0.")
  end

  test "unsafe 066 external local fun" do
    assert_unsafe_compile("fun helper/1.")
  end

  test "unsafe 067 dynamic external fun" do
    assert_unsafe_compile("fun M:F/1.")
  end

  test "unsafe 068 named fun output boundary" do
    assert_unsafe_eval("fun Loop(0) -> 0; Loop(N) -> Loop(N - 1) end.", :ok)
  end

  test "unsafe 069 code which" do
    assert_unsafe_compile("code:which(lists).")
  end

  test "unsafe 070 code load binary" do
    assert_unsafe_compile("code:load_binary(m, \"m\", <<>>).")
  end

  test "unsafe 071 code purge" do
    assert_unsafe_compile("code:purge(m).")
  end

  test "unsafe 072 init stop" do
    assert_unsafe_compile("init:stop().")
  end

  test "unsafe 073 os cmd" do
    assert_unsafe_compile("os:cmd(\"whoami\").")
  end

  test "unsafe 074 os getenv" do
    assert_unsafe_compile("os:getenv().")
  end

  test "unsafe 075 file read" do
    assert_unsafe_compile("file:read_file(\"x\").")
  end

  test "unsafe 076 file write" do
    assert_unsafe_compile("file:write_file(\"x\", <<>>).")
  end

  test "unsafe 077a otp file server read" do
    assert_unsafe_compile("file_server:read_file(\"x\").")
  end

  test "unsafe 077 prim file read" do
    assert_unsafe_compile("prim_file:read_file(\"x\").")
  end

  test "unsafe 078 gen tcp connect" do
    assert_unsafe_compile("gen_tcp:connect(\"localhost\", 80, []).")
  end

  test "unsafe 079 gen udp open" do
    assert_unsafe_compile("gen_udp:open(0).")
  end

  test "unsafe 080 ssl connect" do
    assert_unsafe_compile("ssl:connect(\"localhost\", 443, []).")
  end

  test "unsafe 081 inet gethost" do
    assert_unsafe_compile("inet:gethostbyname(\"localhost\").")
  end

  test "unsafe 082 ets new" do
    assert_unsafe_compile("ets:new(name, []).")
  end

  test "unsafe 083 ets lookup" do
    assert_unsafe_compile("ets:lookup(Input, key).")
  end

  test "unsafe 084 dets open" do
    assert_unsafe_compile("dets:open_file(name, []).")
  end

  test "unsafe 085 mnesia dirty read" do
    assert_unsafe_compile("mnesia:dirty_read(tab, key).")
  end

  test "unsafe 086 persistent term get" do
    assert_unsafe_compile("persistent_term:get(key).")
  end

  test "unsafe 087 persistent term put" do
    assert_unsafe_compile("persistent_term:put(key, value).")
  end

  test "unsafe 088 rpc call" do
    assert_unsafe_compile("rpc:call(node(), m, f, []).")
  end

  test "unsafe 089 net kernel connect" do
    assert_unsafe_compile("net_kernel:connect_node(node()).")
  end

  test "unsafe 090 global register" do
    assert_unsafe_compile("global:register_name(name, self()).")
  end

  test "unsafe 091 pg join" do
    assert_unsafe_compile("pg:join(group, self()).")
  end

  test "unsafe 092 binary to term" do
    assert_unsafe_compile("erlang:binary_to_term(<<131,100,0,3,102,111,111>>).")
  end

  test "unsafe 093 term to binary" do
    assert_unsafe_compile("erlang:term_to_binary(ok).")
  end

  test "unsafe 094 list to atom" do
    assert_unsafe_compile("erlang:list_to_atom(\"x\").")
  end

  test "unsafe 095 binary to atom" do
    assert_unsafe_compile("erlang:binary_to_atom(<<\"x\">>).")
  end

  test "unsafe 096 list to existing atom" do
    assert_unsafe_compile("erlang:list_to_existing_atom(\"ok\").")
  end

  test "unsafe 097 binary to existing atom" do
    assert_unsafe_compile("erlang:binary_to_existing_atom(<<\"ok\">>).")
  end

  test "unsafe 098 module loaded" do
    assert_unsafe_compile("erlang:module_loaded(lists).")
  end

  test "unsafe 099 function exported" do
    assert_unsafe_compile("erlang:function_exported(lists, map, 2).")
  end

  test "safe 221 local hd bif direct allowlist" do
    assert_safe("hd([1]).")
  end

  test "safe 222 local tl bif direct allowlist" do
    assert_safe("tl([1, 2]).")
  end

  test "safe 223 tuple_to_list bif direct allowlist" do
    assert_safe("tuple_to_list({a, b}).")
  end

  test "safe 224 list_to_tuple bif direct allowlist" do
    assert_safe("list_to_tuple([a, b]).")
  end

  test "safe 225 make_ref native lowering compiles" do
    assert_safe_compile("make_ref().")
  end

  test "unsafe 107 node bif not allowlisted" do
    assert_unsafe_compile("node().")
  end

  test "unsafe 108 nodes bif not allowlisted" do
    assert_unsafe_compile("nodes().")
  end

  test "unsafe 110 map get missing runtime" do
    assert_unsafe_eval("maps:get(a, \#{}).", :ok)
  end

  test "unsafe 111 badarith runtime" do
    assert_unsafe_eval("1 div 0.", :ok)
  end

  test "unsafe 112 case clause runtime" do
    assert_unsafe_eval("case Input of 1 -> ok end.", 2)
  end

  test "unsafe 113 if clause runtime" do
    assert_unsafe_eval("if false -> ok end.", :ok)
  end

  test "unsafe 114 function clause runtime" do
    assert_unsafe_eval("case Input of {ok, X} -> X end.", :error)
  end

  test "unsafe 115 input pid" do
    assert_unsafe_eval("Input.", self())
  end

  test "unsafe 116 input ref" do
    assert_unsafe_eval("Input.", make_ref())
  end

  test "unsafe 117 input fun" do
    assert_unsafe_eval("Input.", fn -> :ok end)
  end

  test "unsafe 118 input unknown atom" do
    assert_unsafe_eval("Input.", :not_allowed_atom)
  end

  test "unsafe 119 input oversized binary" do
    assert_unsafe_eval("Input.", <<"abcdef">>, @safe_manifest, limits: %{max_binary_bytes: 4})
  end

  test "unsafe 120 input oversized integer" do
    assert_unsafe_eval("Input.", 1024, @safe_manifest, limits: %{max_integer_bits: 4})
  end

  test "unsafe 121 input oversized tuple" do
    assert_unsafe_eval("Input.", {1, 2, 3}, @safe_manifest, limits: %{max_tuple_size: 2})
  end

  test "unsafe 122 input oversized list" do
    assert_unsafe_eval("Input.", [1, 2, 3], @safe_manifest, limits: %{max_list_length: 2})
  end

  test "unsafe 123 input oversized map" do
    assert_unsafe_eval("Input.", %{a: 1, b: 2, c: 3}, @safe_manifest, limits: %{max_map_size: 2})
  end

  test "unsafe 124 input excessive depth" do
    assert_unsafe_eval("Input.", [[[[1]]]], @safe_manifest, limits: %{max_term_depth: 2})
  end

  test "unsafe 125 output oversized binary" do
    assert_unsafe_eval("binary:copy(<<\"a\">>, 5).", :ok, @safe_manifest,
      limits: %{max_binary_bytes: 4}
    )
  end

  test "unsafe 126 output oversized integer" do
    assert_unsafe_eval("1024.", :ok, @safe_manifest, limits: %{max_integer_bits: 4})
  end

  test "unsafe 127 output oversized tuple" do
    assert_unsafe_eval("{1, 2, 3}.", :ok, @safe_manifest, limits: %{max_tuple_size: 2})
  end

  test "unsafe 128 output oversized list" do
    assert_unsafe_eval("[1, 2, 3].", :ok, @safe_manifest, limits: %{max_list_length: 2})
  end

  test "unsafe 129 output oversized map" do
    assert_unsafe_eval("\#{a => 1, b => 2, c => 3}.", :ok, @safe_manifest,
      limits: %{max_map_size: 2}
    )
  end

  test "unsafe 130 output excessive depth" do
    assert_unsafe_eval("[[[[1]]]].", :ok, @safe_manifest, limits: %{max_term_depth: 2})
  end

  test "unsafe 131 output total words" do
    assert_unsafe_eval("[1, 2, 3, 4].", :ok, @safe_manifest, limits: %{max_total_words: 3})
  end

  test "unsafe 132 disallow output tuple" do
    assert_unsafe_eval("{ok, 1}.", :ok, @safe_manifest, terms: %{allow_tuples: false})
  end

  test "unsafe 133 disallow output atom" do
    assert_unsafe_eval("ok.", :ok, @safe_manifest, terms: %{allow_atoms: false})
  end

  test "unsafe 134 fixed bit syntax expansion exceeds compile budget" do
    assert_unsafe_compile(
      "<<0:5/unit:8>>.",
      Map.put(@safe_manifest, :limits, %{max_binary_bytes: 4})
    )
  end

  test "unsafe 135 bit syntax unit zero" do
    assert_unsafe_compile("<<1/unit:0>>.")
  end

  test "unsafe 136 duplicate bit syntax type spec" do
    assert_unsafe_compile("<<1/integer-float>>.")
  end

  test "unsafe 137 non byte aligned bitstring cannot cross output boundary" do
    assert_unsafe_eval("<<1:1>>.", :ok)
  end

  test "safe 271 map update assoc inserts and replaces" do
    assert_safe("M = \#{a => 1}, {M\#{b => 2}, M\#{a => 3}}.")
  end

  test "unsafe 139 try after forbidden" do
    assert_unsafe_compile("try 1 after file:delete(\"x\") end.")
  end

  test "safe 272 try of with catch" do
    assert_safe("try 1 of X -> X catch _:_ -> ok end.")
  end

  test "safe 273 zero arity result root ignores input for compatibility" do
    {:ok, program} =
      Hyperlang.Test.program("result() -> \#{ok => true}.", @safe_manifest)

    assert eval(program, :ok) == {:ok, %{ok: true}}
  end

  test "unsafe 141 catch expression unsupported" do
    assert_unsafe_compile("catch 1 div 0.")
  end

  test "unsafe 142 maybe unsupported" do
    assert_unsafe_compile("maybe X ?= {ok, 1}, X end.")
  end

  test "unsafe 143 module info local" do
    assert_unsafe_compile("module_info().")
  end

  test "unsafe 144 module info remote" do
    assert_unsafe_compile("erlang:module_info().")
  end

  test "unsafe 145 generated slot module info" do
    assert_unsafe_compile("hyperlang_slot_000001:module_info().")
  end

  test "unsafe 146 generated entry call" do
    assert_unsafe_compile("'hyperlang_slot_000001':'$safe_entry'(1, 2, 3).")
  end

  test "unsafe 147 arbitrary remote" do
    assert_unsafe_compile("some_module:some_function(1).")
  end

  test "unsafe 148 stdlib disabled lists" do
    assert_unsafe_compile("lists:sum([1,2,3]).", %{
      stdlib: %{lists: false},
      terms: %{public: :erlang}
    })
  end

  test "unsafe 149 stdlib disabled math" do
    assert_unsafe_compile("math:sqrt(4.0).", %{stdlib: %{math: false}, terms: %{public: :erlang}})
  end

  test "unsafe 150 import undeclared" do
    assert_unsafe_compile("kv:get(a).")
  end

  test "unsafe 151 result root missing" do
    assert_unsafe_compile("helper(Input) -> Input.")
  end

  test "unsafe 152 result root wrong arity" do
    assert_unsafe_compile("result(A, B) -> A + B.")
  end

  test "unsafe 153 function arity limit" do
    assert_unsafe_compile("result(A, B) -> A + B.", %{
      limits: %{max_function_arity: 1},
      terms: %{public: :erlang}
    })
  end

  test "unsafe 154 function count limit" do
    assert_unsafe_compile("result(Input) -> Input. helper(Input) -> Input.", %{
      limits: %{max_functions: 1},
      terms: %{public: :erlang}
    })
  end

  test "unsafe 155 source byte limit" do
    assert_unsafe_compile("1 + 2.", %{limits: %{max_source_bytes: 2}, terms: %{public: :erlang}})
  end

  test "unsafe 156 token limit" do
    assert_unsafe_compile("1 + 2 + 3.", %{limits: %{max_tokens: 2}, terms: %{public: :erlang}})
  end

  test "unsafe 157 string literal byte limit" do
    assert_unsafe_compile("<<\"abcdef\">>.", %{
      limits: %{max_binary_bytes: 4},
      terms: %{public: :erlang}
    })
  end

  test "unsafe 158 integer literal bit limit" do
    assert_unsafe_compile("1024.", %{limits: %{max_integer_bits: 4}, terms: %{public: :erlang}})
  end

  test "unsafe 159 clause count limit" do
    assert_unsafe_compile("result(0) -> 0; result(1) -> 1.", %{
      limits: %{max_clauses: 1},
      terms: %{public: :erlang}
    })
  end

  test "unsafe 160 wall timeout recursive loop" do
    assert_unsafe_eval("result(Input) -> loop(Input). loop(X) -> loop(X).", 1, @safe_manifest,
      limits: %{wall_ms: 10}
    )
  end

  test "unsafe 161 argparse parser direct passthrough rejected" do
    assert_unsafe_compile("argparse:parse([], #{}).")
  end

  test "safe erlang atom_to_binary textification uses Hyperlang wrapper" do
    assert_safe("atom_to_binary(foo).")
    assert_safe("erlang:atom_to_binary(foo, utf8).")
  end

  test "unsafe 163 erlang atom_to_list textification rejected" do
    assert_unsafe_compile("erlang:atom_to_list(foo).")
  end

  test "unsafe 164 io_lib write_atom textification rejected" do
    assert_unsafe_compile("io_lib:write_atom(foo).")
  end

  test "unsafe 165 io_lib write_atom_as_latin1 textification rejected" do
    assert_unsafe_compile("io_lib:write_atom_as_latin1(foo).")
  end

  test "safe 166 io_lib generic term format textification uses Hyperlang wrapper" do
    assert_safe("io_lib:format(\"~p\", [foo]).")
  end

  test "unsafe 167 json encode_atom textification rejected" do
    assert_unsafe_compile("json:encode_atom(foo, fun(_, _) -> <<>> end).")
  end

  test "unsafe 168 json generic encode textification rejected" do
    assert_unsafe_compile("json:encode(foo).")
  end

  test "unsafe 169 bare wildcard value expression rejected" do
    assert_unsafe_compile("_.")
  end

  test "unsafe 170 wildcard value on match right side rejected" do
    assert_unsafe_compile("X = _, X.")
  end

  test "unsafe 171 wildcard binary value segment rejected" do
    assert_unsafe_compile("<<_/binary>>.")
  end

  test "unsafe 172 wildcard sized binary value segment rejected" do
    assert_unsafe_compile("<<_:8>>.")
  end

  test "unsafe 173 wildcard function argument rejected" do
    assert_unsafe_compile("length(_).")
  end

  test "unsafe 174 wildcard map value construction rejected" do
    assert_unsafe_compile(~S|#{a => _}.|)
  end
end
