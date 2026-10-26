defmodule Hyperlang.SandboxProbeTest do
  # Sandbox boundary probes (S1-S4 leaks and classic escapes). Each test asserts
  # the SAFE outcome.
  use ExUnit.Case, async: false

  defp pub(m), do: Map.update(m, :terms, %{public: :erlang}, &Map.put(&1, :public, :erlang))

  defp run(src, manifest \\ %{}) do
    case Hyperlang.Test.program(src, pub(manifest)) do
      {:ok, p} -> Hyperlang.Test.run(p, :entry, [nil])
      {:error, e} -> {:rejected, e}
    end
  end

  defp rejected?(src), do: match?({:rejected, _}, run(src))
  defp text(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  describe "S1 generated-module secrecy in error messages" do
    test "case_clause on a fun does not reveal slot module or helper names" do
      out = text(run("result(_) -> F = fun() -> ok end, case F of 1 -> ok end."))
      refute out =~ "hyperlang_slot_"
      refute out =~ "safe_f_"
    end

    test "function_clause does not reveal slot module or helper names" do
      out = text(run("f(1) -> ok.\nresult(_) -> f(fun() -> ok end)."))
      refute out =~ "hyperlang_slot_"
      refute out =~ "safe_f_"
    end
  end

  describe "S2 pool atom names stay internal" do
    for {name, body} <- [
          {"filename:basename", "filename:basename(zzz)"},
          {"filename:join", "filename:join(zzz, \"x\")"},
          {"filename:flatten", "filename:flatten([zzz])"},
          {"io_lib:format_prompt/1", "io_lib:format_prompt(zzz)"},
          {"io_lib:format_prompt ~w", "io_lib:format_prompt({\"~w\", [zzz]})"}
        ] do
      test "#{name} does not expose hyperlang_atom_N" do
        refute text(run("result(_) -> #{unquote(body)}.")) =~ "hyperlang_atom_"
      end
    end
  end

  describe "S3 fun rendering does not reveal slot modules" do
    test "io_lib:format ~p of a fun" do
      refute text(run("result(_) -> io_lib:format(\"~p\", [fun() -> ok end]).")) =~
               "hyperlang_slot_"
    end

    test "io_lib:format_prompt of a fun" do
      out = text(run("result(_) -> F = fun() -> 1 end, io_lib:format_prompt({\"~p\", [F]})."))
      refute out =~ "hyperlang_slot_"
    end
  end

  describe "S4 error stacks contain no host frames" do
    for {name, body} <- [
          {"badfun", "X = 1, X()"},
          {"element on non-tuple", "element(1, 1)"},
          {"whereis without policy", "whereis(code_server)"}
        ] do
      test "#{name}" do
        out = text(run("result(_) -> #{unquote(body)}."))
        refute out =~ "hyperlang_msg"
        refute out =~ "io_lib_format"
      end
    end
  end

  describe "regression: classic escapes stay blocked" do
    test "dynamic apply, external funs, introspection, process identity" do
      assert rejected?("result(_) -> apply(erlang, get, []).")
      assert rejected?("result(_) -> F = fun erlang:get/0, F().")
      assert rejected?("result(_) -> rand:seed_s(exsss).")
      assert rejected?("result(_) -> rand:seed_s(exsss, 1).")
      assert rejected?("result(_) -> erlang:fun_info(fun() -> 1 end).")
      assert rejected?("result(_) -> erlang:fun_to_list(fun() -> 1 end).")
      assert rejected?("result(_) -> self().")
      assert rejected?("result(_) -> node().")
    end

    test "funs never cross the result, throw, exit or tuple boundary" do
      assert {:error, %{category: :output}} = run("result(_) -> fun() -> ok end.")

      assert {:error, %{category: :output}} =
               run("result(_) -> tuple_to_list({fun() -> ok end}).")

      assert {:error, _} = run("result(_) -> throw(fun() -> ok end).")
      assert {:error, _} = run("result(_) -> exit(fun() -> ok end).")
      refute text(run("result(_) -> erlang:error({x, fun() -> ok end}).")) =~ "#Fun"
    end

    test "process dictionary is namespaced away from host keys" do
      assert {:ok, [{"a", 1}], _} = run("result(_) -> put(a, 1), get().")
      assert {:ok, :undefined, _} = run("result(_) -> get('$ancestors').")
    end

    test "catch stack variable is sanitized" do
      assert {:ok, {:error, "x", []}, _} =
               run("result(_) -> try erlang:error(x) catch C:R:S -> {C, R, S} end.")
    end
  end
end
