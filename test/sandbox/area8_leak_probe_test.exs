defmodule Hyperlang.Area8LeakProbeTest do
  # AREA 8: error and stdout channels must not leak host internals — generated
  # slot module names, generated helper atoms (safe_f_N), host stack frames,
  # or internal pool atom names. Probes assert the SAFE outcome (no leak).
  use ExUnit.Case, async: false
  import Hyperlang.SandboxProbe

  defp err_text(src, m \\ %{}), do: text(run(src, m))

  describe "generated module / helper names must not leak in error payloads (S1)" do
    for {name, src} <- [
          {"case_clause on a fun", "result(_) -> F = fun() -> ok end, case F of 1 -> ok end."},
          {"function_clause with a fun arg", "f(1) -> ok.\nresult(_) -> f(fun() -> ok end)."},
          {"badmatch of a fun", "result(_) -> 1 = fun() -> ok end."},
          {"badfun application", "result(_) -> X = 1, X()."},
          {"tuple-fun badfun", "result(_) -> MF = {a, b}, MF()."}
        ] do
      test "no slot/helper leak: #{name}" do
        assert leaks_in(err_text(unquote(src))) == []
      end
    end
  end

  describe "pool atom names must not leak through stringifying stdlib passthrough (S2)" do
    for {name, body} <- [
          {"filename:basename", "filename:basename(zzz)"},
          {"filename:join/2", "filename:join(zzz, \"x\")"},
          {"filename:flatten", "filename:flatten([zzz])"},
          {"filename:split", "filename:split(zzz)"},
          {"io_lib:format_prompt/1", "io_lib:format_prompt(zzz)"},
          {"io_lib:format_prompt ~w", "io_lib:format_prompt({\"~w\", [zzz]})"},
          {"io_lib:write_string via char_list", "io_lib:char_list([zzz])"}
        ] do
      test "no hyperlang_atom_ leak: #{name}" do
        refute err_text("result(_) -> #{unquote(body)}.") =~ "hyperlang_atom_"
      end
    end
  end

  describe "fun rendering must not reveal slot modules (S3)" do
    for {name, body} <- [
          {"io_lib:format ~p of fun", "io_lib:format(\"~p\", [fun() -> ok end])"},
          {"io_lib:format ~w of fun", "io_lib:format(\"~w\", [fun() -> ok end])"},
          {"io_lib:format_prompt of fun", "io_lib:format_prompt({\"~p\", [fun() -> 1 end]})"}
        ] do
      test "no slot leak: #{name}" do
        refute err_text("result(_) -> #{unquote(body)}.") =~ "hyperlang_slot_"
      end
    end
  end

  describe "runtime error stacks must not contain host frames (S4)" do
    for {name, body} <- [
          {"badfun", "X = 1, X()"},
          {"element on non-tuple", "element(1, 1)"},
          {"badarith", "1 + nope"},
          {"hd of non-list", "hd(1)"},
          {"map_get missing", "map_get(k, \#{})"},
          {"explicit error", "erlang:error(custom_reason)"},
          {"throw", "throw(custom_reason)"}
        ] do
      test "no host frame in stack: #{name}" do
        out =
          err_text("result(_) -> #{unquote(body)}.", %{
            terms: %{public: :erlang, allowed_atoms: [:custom_reason, :nope, :k]}
          })

        refute out =~ "hyperlang_msg"
        refute out =~ "io_lib_format"
        refute out =~ "with_context"
      end
    end
  end

  describe "exception messages keep guest-level names (S1)" do
    defp message_of(src, m \\ %{}) do
      {:error, %{details: %{"reason" => reason}}} = run(src, m)
      reason
    end

    test "a pool atom in a message renders as its source name" do
      text = message_of("result(_) -> case zzz of 1 -> ok end.")
      assert text =~ "no case clause matching"
      assert text =~ "    :zzz"
      assert message_of("result(_) -> X = zzz, <<X:8>>.") =~ "expected an integer but got: :zzz"
      assert message_of("result(_) -> maps:get(zzz, \#{}).") =~ "key :zzz not found"
    end

    test "a fun in a message renders as a guest placeholder" do
      text = message_of("result(_) -> F = fun() -> ok end, <<F/binary>>.")
      assert text =~ "expected a binary but got: #Function<guest>"
      assert leaks_in(text) == []
    end

    test "a function clause error names the guest function and source arity" do
      text = message_of("f(1) -> ok.\nresult(_) -> f(fun() -> ok end).")
      assert text =~ "no function clause matching in guest:f/1"
    end

    test "a function clause error in a guest-callable stdlib function names the MFA" do
      assert message_of("result(_) -> lists:nth(0, [a]).") =~
               "no function clause matching in lists:nth/2"
    end

    test "messages from every exception family carry no internal names" do
      for src <- [
            "result(_) -> F = fun() -> ok end, try F of 1 -> ok catch nope -> ok end.",
            "result(_) -> F = fun() -> ok end, F + 1.",
            "result(_) -> X = zzz, X\#{k => 1}.",
            "result(_) -> F = fun() -> ok end, maps:get(F, \#{}).",
            "result(_) -> F = fun() -> ok end, element(1, F).",
            "result(_) -> erlang:error({badarg, zzz}).",
            "result(_) -> F = fun() -> ok end, binary_to_integer(F)."
          ] do
        assert leaks_in(text(run(src))) == [], src
      end
    end
  end

  describe "error stacks keep only guest frames and guest-callable stdlib frames (S4)" do
    test "a stdlib frame the guest called survives with its MFA" do
      {:error, %{details: %{"stack" => stack}}} = run("result(_) -> element(1, 1).")

      assert [%{"module" => "erlang", "function" => "element", "arity" => 2} | rest] = stack
      assert Enum.all?(rest, &(&1["module"] == "guest"))
    end

    test "frames inside guest funs map to the defining guest function" do
      {:error, %{details: %{"stack" => stack}}} =
        run("result(_) -> lists:map(fun(X) -> X + 1 end, [zzz]).")

      assert Enum.all?(stack, &(&1["module"] in ["guest", "lists"]))
      assert Enum.any?(stack, &String.contains?(&1["function"], "result"))
      assert leaks_in(text(stack)) == []
    end
  end

  describe "stringifying stdlib helpers render pool atoms by source name (S2)" do
    test "filename, lists:concat and io_lib:format_prompt render source names" do
      assert {:ok, {~c"zzz", ~c"zzz/x", [~c"zzz"], ~c"zzzayyy"}, _} =
               run(
                 ~S|result(_) -> {filename:basename(zzz), filename:join(zzz, "x"), filename:split(zzz), filename:flatten([zzz, "a", [yyy]])}.|
               )

      assert {:ok, ~c"zzz1", _} = run("result(_) -> lists:concat([zzz, 1]).")
      assert {:ok, [~c"zzz"], _} = run("result(_) -> io_lib:format_prompt(zzz).")
    end

    test "format_prompt keeps the {format, Format, Args} form" do
      assert {:ok, out, _} =
               run(~S|result(_) -> io_lib:format_prompt({format, "~s-~b", ["a", 7]}).|)

      assert IO.chardata_to_string(out) == "a-7"
    end
  end

  describe "io_lib text helpers reject funs like captured stdout (S3)" do
    for body <- [
          ~S|io_lib:format("~p", [fun() -> ok end])|,
          ~S|io_lib:fwrite("~w", [fun() -> ok end])|,
          ~S|io_lib:bformat("~p", [{x, fun() -> ok end}])|,
          ~S|io_lib:format_prompt({"~p", [fun() -> ok end]})|
        ] do
      test "#{body} fails as a sanitized stdlib error" do
        out = run("result(_) -> #{unquote(body)}.")
        assert {:error, %{category: :stdlib}} = out
        assert leaks_in(text(out)) == []
      end
    end
  end

  describe "stdout path is hardened: real io:* projects atoms and never leaks internal names" do
    for {name, body} <- [
          {"io:format ~w atom", "io:format(\"~w\", [zzz])"},
          {"io:format ~p atom", "io:format(\"~p\", [zzz])"},
          {"io:format ~p list", "io:format(\"~p\", [[zzz, yyy]])"},
          {"io:put_chars", "io:put_chars(\"plain text\")"},
          {"io:format ~p fun", "io:format(\"~p\", [fun() -> ok end])"}
        ] do
      test "stdout has no internal names: #{name}" do
        case run("result(_) -> #{unquote(body)}.") do
          {:ok, _v, %{stdout: chunks}} ->
            joined = Enum.join(chunks)
            refute joined =~ "hyperlang_atom_"
            refute joined =~ "hyperlang_slot_"
            refute joined =~ "safe_f_"

          other ->
            # A sanitized error is also acceptable here; the io:* stdout path
            # must not *render* a slot module / pool atom. (Host-frame leakage in
            # the error stack is tracked separately as S4.)
            refute text(other) =~ "hyperlang_slot_"
            refute text(other) =~ "hyperlang_atom_"
            refute text(other) =~ "safe_f_"
        end
      end
    end
  end

  describe "program metadata must not reveal generated names" do
    test "public program.metadata carries no slot module or helper atoms" do
      {:ok, program} =
        compile("""
        helper(X) -> X + 1.
        result(_) -> helper(fun() -> ok end).
        """)

      meta_text = inspect(program.metadata, limit: :infinity, printable_limit: :infinity)
      assert leaks_in(meta_text) == [], "metadata leaked: #{inspect(leaks_in(meta_text))}"
    end
  end

  describe "disallowed-atom error details are redacted" do
    test "an atom outside the universe is not echoed verbatim in the error" do
      # The run names an atom the program does not allow; the error must redact
      # it rather than echo the internal pool/sentinel atom.
      out =
        err_text("result(_) -> erlang:error(nope).", %{
          terms: %{public: :erlang, allowed_atoms: []}
        })

      refute out =~ "hyperlang_atom_"
      refute out =~ "hyperlang_slot_"
    end
  end
end
