defmodule Hyperlang.Area2VerifierCodegenProbeTest do
  # AREA 2: verifier/codegen mismatch. A construct the verifier accepts must not
  # compile to something it did not check. These assert SAFE behaviour
  # (regression locks) and spec-mandated safety.
  use ExUnit.Case, async: false
  import Hyperlang.SandboxProbe

  describe "try/catch cannot swallow host-enforced termination" do
    test "catch-all does not swallow a reduction-watchdog kill" do
      out =
        run(
          "result(_) -> try (fun L() -> L() end)() catch _:_ -> escaped end.",
          %{limits: %{wall_ms: 80}}
        )

      # The infinite loop must be killed by the host, not caught by the guest.
      assert match?(
               {:error, %{category: cat}} when cat in [:reduction_watchdog, :timeout, :heap],
               out
             ),
             "try/catch swallowed a host kill: #{inspect(out)}"

      refute match?({:ok, :escaped, _}, out)
    end

    test "catch-all does not swallow a wall-timeout kill on a native sleep loop" do
      out =
        run(
          "result(_) -> try (fun L() -> timer:sleep(1), L() end)() catch _:_ -> escaped end.",
          %{limits: %{wall_ms: 80}}
        )

      refute match?({:ok, :escaped, _}, out)
    end
  end

  describe "catch stack variable is sanitized to []" do
    test "shallow catch stack is empty" do
      assert {:ok, {_class, _reason, []}, _} =
               run("result(_) -> try erlang:error(x) catch C:R:S -> {C, R, S} end.")
    end

    test "deep call stack still yields an empty catch stack" do
      assert {:ok, 0, _} =
               run(
                 "f(0) -> erlang:error(boom); f(N) -> f(N - 1).\nresult(_) -> try f(25) catch _:_:S -> erlang:length(S) end.",
                 %{terms: %{public: :erlang, allowed_atoms: [:boom]}}
               )
    end
  end

  describe "a never-interned catch class does not crash the host" do
    test "returns a clean typed error, never a raised exception" do
      result =
        compile("result(_) -> try hd([1]) catch zqxv_never_interned_999:_E -> ok end.")

      # Clean typed door error (currently :codegen) or compiled — never a crash.
      assert match?({:error, [%{category: _}]}, result) or match?({:ok, _}, result)
    end
  end

  describe "comprehensions verify their generators, bodies and filters" do
    for {name, body} <- [
          {"list-comp body forbidden", "[os:cmd(X) || X <- [\"a\"]]"},
          {"list-comp filter forbidden", "[X || X <- [1], erlang:halt() =:= X]"},
          {"list-comp generator forbidden", "[X || X <- os:cmd(\"id\")]"},
          {"binary-comp body forbidden", "<< <<(os:getpid())>> || _ <- [1] >>"},
          {"map-comp body forbidden", "\#{K => os:cmd(K) || K <- [\"a\"]}"}
        ] do
      test "reject #{name}" do
        assert rejected?("result(_) -> #{unquote(body)}.")
      end
    end

    test "a safe list comprehension still compiles and runs" do
      assert {:ok, [2, 3, 4], _} = run("result(_) -> [X + 1 || X <- [1, 2, 3]].")
    end
  end

  describe "nested and named funs verify their bodies" do
    for {name, body} <- [
          {"nested anon fun body", "F = fun() -> fun() -> os:cmd(\"id\") end end, (F())()"},
          {"named fun body forbidden",
           "F = fun Loop(0) -> erlang:halt(); Loop(N) -> Loop(N - 1) end, F(1)"},
          {"fun capturing forbidden local", "fun() -> self() end"}
        ] do
      test "reject #{name}" do
        assert rejected?("result(_) -> #{unquote(body)}.")
      end
    end

    test "a safe nested fun compiles and runs" do
      assert {:ok, 42, _} = run("result(_) -> F = fun() -> fun() -> 42 end end, (F())().")
    end
  end

  describe "guards cannot reach authority or atom creation" do
    for {name, body} <- [
          {"node in guard", "case 1 of X when node() =:= a -> X end"},
          {"self in guard", "case 1 of X when self() =:= X -> X end"},
          {"forbidden call in if guard", "if erlang:halt() -> ok; true -> no end"}
        ] do
      test "reject #{name}" do
        assert rejected?(
                 "result(_) -> #{unquote(body)}.",
                 %{terms: %{public: :erlang, allowed_atoms: [:a, :ok, :no]}}
               )
      end
    end

    test "legitimate guard BIFs compile and run" do
      assert {:ok, :is_int, _} =
               run(
                 "result(_) -> case 5 of X when is_integer(X), X > 0 -> is_int end.",
                 %{terms: %{public: :erlang, allowed_atoms: [:is_int]}}
               )
    end
  end

  describe "records do not lower into forbidden calls" do
    test "a record field default calling a forbidden fn is rejected" do
      src = """
      -module(m).
      -export([result/1]).
      -record(r, {x = os:cmd("id")}).
      result(_) -> #r{}.
      """

      assert rejected?(src)
    end

    test "a benign record compiles and round-trips a field" do
      src = """
      -module(m).
      -export([result/1]).
      -record(r, {x = 0, y = 1}).
      result(_) -> R = #r{x = 7}, R#r.x.
      """

      assert {:ok, 7, _} = run(src)
    end
  end

  describe "receive/after lowering stays confined" do
    test "a bare receive with after returns the after body (no raw messages visible)" do
      assert {:ok, :timeout, _} =
               run(
                 "result(_) -> receive X -> X after 0 -> timeout end.",
                 %{terms: %{public: :erlang, allowed_atoms: [:timeout]}}
               )
    end

    test "receive without a resolver cannot send, and a bare send fails closed" do
      out =
        run("result(_) -> self_pid ! msg.", %{
          terms: %{public: :erlang, allowed_atoms: [:msg, :self_pid]}
        })

      assert match?({:error, %{category: :runtime}}, out)
    end
  end

  describe "function identity rules hold" do
    test "a local function named module_info is rejected" do
      assert rejected?("module_info() -> secret.\nresult(_) -> module_info().")
    end

    test "defining a local that shadows a stdlib name dispatches locally, not to OTP" do
      assert {:ok, :local, _} =
               run(
                 "map(_) -> local.\nresult(_) -> map(ignored).",
                 %{terms: %{public: :erlang, allowed_atoms: [:local, :ignored]}}
               )
    end
  end

  describe "guards admit guard tests only, checked at verify time" do
    # A fun, try, case, if or comprehension inside a guard used to pass the
    # verifier; its body (verified in expression mode) then reached codegen's
    # guard lowering, which emitted a raw stdlib call that only the
    # generated-form verifier or erl_lint caught.
    for {name, guard} <- [
          {"fun", ~S'a =:= fun() -> lists:reverse([1]) end'},
          {"named fun", ~S'a =:= fun F() -> F end'},
          {"try", ~S'a =:= try 1 catch _:_ -> 2 end'},
          {"case", ~S'a =:= case 1 of _ -> 1 end'},
          {"if", ~S'a =:= if true -> 1 end'},
          {"list comprehension", ~S'a =:= [Y || Y <- [1]]'},
          {"binary comprehension", ~S'a =:= << <<Y>> || Y <- [1] >>'},
          {"map comprehension", ~S'a =:= #{Y => Y || Y <- [1]}'}
        ] do
      test "#{name} in a guard is a verify error" do
        assert {:error, [%{category: :verify} | _]} =
                 compile("result(_) -> if #{unquote(guard)} -> b; true -> c end.")
      end
    end

    test "ordinary guard sequences still compile and run" do
      src = """
      f(X) when is_integer(X), X > 0; X =:= zero -> pos;
      f(_) -> other.
      result(_) -> {f(1), f(zero), f(-1)}.
      """

      assert {:ok, {"pos", "pos", "other"}, _} = run(src)
    end
  end
end
