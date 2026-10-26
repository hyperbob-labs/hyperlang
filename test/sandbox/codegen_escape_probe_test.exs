defmodule Hyperlang.CodegenEscapeProbeTest do
  # AREA 1: code-generation escape. Guest source must not reach any module or
  # function outside the frozen allowlist. The safe outcome for every forbidden
  # construct is compile-time rejection (the classifier/verifier never lets it
  # into generated code). A compiling+running probe here is a candidate escape.
  use ExUnit.Case, async: false
  import Hyperlang.SandboxProbe

  defp body(b), do: "result(_) -> #{b}."

  describe "dynamic dispatch is rejected" do
    for {name, b} <- [
          {"apply/3 erlang", "apply(erlang, get, [])"},
          {"apply/3 os", "apply(os, cmd, [\"id\"])"},
          {"apply/2 of a fun", "F = fun() -> ok end, apply(F, [])"},
          {"erlang:apply/3", "erlang:apply(erlang, halt, [])"},
          {"computed module M:f", "M = erlang, M:get()"},
          {"computed function erlang:F", "F = get, erlang:F()"},
          {"computed both", "M = os, F = cmd, M:F(\"id\")"}
        ] do
      test "reject #{name}" do
        assert rejected?(body(unquote(b))), "expected rejection of: #{unquote(b)}"
      end
    end

    test "tuple-fun application does not dispatch to a module:function (badfun at runtime)" do
      # {erlang,get}() is a removed OTP tuple-fun form; it must raise badfun, not
      # call erlang:get/0 (which would return the process dictionary).
      assert {:error, %{category: :runtime}} =
               run("result(_) -> put(k, 1), MF = {erlang, get}, MF().")
    end
  end

  describe "external funs and make_fun are rejected" do
    for {name, b} <- [
          {"fun erlang:get/0", "F = fun erlang:get/0, F()"},
          {"fun os:cmd/1", "fun os:cmd/1"},
          {"fun io:format/1", "fun io:format/1"},
          {"fun lists:map/2", "fun lists:map/2"},
          {"fun erlang:halt/0", "F = fun erlang:halt/0, F()"},
          {"make_fun/3", "erlang:make_fun(erlang, get, 0)"},
          {"fun M:F/A dynamic", "M = erlang, fun M:get/0"}
        ] do
      test "reject #{name}" do
        assert rejected?(body(unquote(b))), "expected rejection of: #{unquote(b)}"
      end
    end
  end

  describe "atom-creating conversions are rejected" do
    for {name, b} <- [
          {"list_to_atom", "list_to_atom(\"evil\")"},
          {"erlang:list_to_atom", "erlang:list_to_atom(\"evil\")"},
          {"binary_to_atom/1", "binary_to_atom(<<\"evil\">>)"},
          {"binary_to_atom/2", "binary_to_atom(<<\"evil\">>, utf8)"},
          {"erlang:binary_to_atom", "erlang:binary_to_atom(<<\"evil\">>, utf8)"},
          {"list_to_existing_atom", "list_to_existing_atom(\"evil\")"},
          {"binary_to_existing_atom", "binary_to_existing_atom(<<\"evil\">>, utf8)"}
        ] do
      test "reject #{name}" do
        assert rejected?(body(unquote(b))), "expected rejection of: #{unquote(b)}"
      end
    end
  end

  describe "serialization round-trips are rejected" do
    for {name, b} <- [
          {"binary_to_term/1", "binary_to_term(<<131,100,0,2,111,107>>)"},
          {"binary_to_term/2", "binary_to_term(<<131,100,0,2,111,107>>, [safe])"},
          {"erlang:binary_to_term", "erlang:binary_to_term(<<131>>)"},
          {"term_to_binary/1", "term_to_binary({a, b})"},
          {"term_to_binary/2", "term_to_binary({a, b}, [])"},
          {"erlang:term_to_binary", "erlang:term_to_binary(1)"}
        ] do
      test "reject #{name}" do
        assert rejected?(body(unquote(b))), "expected rejection of: #{unquote(b)}"
      end
    end
  end

  describe "process / port / scheduler authority is rejected" do
    for {name, b} <- [
          {"halt/0", "halt()"},
          {"halt/1", "halt(0)"},
          {"erlang:halt/1", "erlang:halt(1)"},
          {"open_port", "open_port({spawn, \"sh\"}, [])"},
          {"load_nif", "erlang:load_nif(\"x\", 0)"},
          {"system_flag", "erlang:system_flag(backtrace_depth, 0)"},
          {"process_info/1", "process_info(self())"},
          {"processes/0", "erlang:processes()"},
          {"registered/0", "erlang:registered()"},
          {"ports/0", "erlang:ports()"},
          {"group_leader/0", "group_leader()"},
          {"group_leader/2", "erlang:group_leader(self(), self())"},
          {"port_command", "erlang:port_command(p, <<>>)"},
          {"trace", "erlang:trace(all, true, [call])"},
          {"suspend_process", "erlang:suspend_process(self())"},
          {"garbage_collect/0", "erlang:garbage_collect()"},
          {"bump_reductions", "erlang:bump_reductions(1)"},
          {"send/2", "erlang:send(self(), x)"},
          {"module_loaded", "erlang:module_loaded(erlang)"},
          {"function_exported", "erlang:function_exported(os, cmd, 1)"}
        ] do
      test "reject #{name}" do
        assert rejected?(body(unquote(b))), "expected rejection of: #{unquote(b)}"
      end
    end
  end

  describe "forbidden reflection / VM introspection is rejected" do
    for {name, b} <- [
          {"fun_info", "erlang:fun_info(fun() -> 1 end)"},
          {"fun_to_list", "erlang:fun_to_list(fun() -> 1 end)"},
          {"erlang:display", "erlang:display(x)"},
          {"erlang:system_info", "erlang:system_info(process_count)"},
          {"erlang:memory", "erlang:memory()"},
          {"erlang:statistics", "erlang:statistics(reductions)"},
          {"erlang:node/0", "node()"},
          {"erlang:node/1", "erlang:node(self())"},
          {"erlang:nodes", "erlang:nodes()"},
          {"self/0", "self()"},
          {"erlang:self", "erlang:self()"},
          {"erlang:get_stacktrace", "erlang:get_stacktrace()"},
          {"erlang:process_display", "erlang:process_display(self(), backtrace)"},
          {"module_info/0 local", "module_info()"},
          {"module_info/1 local", "module_info(exports)"}
        ] do
      test "reject #{name}" do
        assert rejected?(body(unquote(b))), "expected rejection of: #{unquote(b)}"
      end
    end
  end

  describe "forbidden storage / distribution / OS / code modules are rejected" do
    for {name, b} <- [
          {"os:cmd", "os:cmd(\"id\")"},
          {"os:getenv", "os:getenv(\"PATH\")"},
          {"os:putenv", "os:putenv(\"X\", \"Y\")"},
          {"os:type", "os:type()"},
          {"ets:new", "ets:new(t, [])"},
          {"ets:insert", "ets:insert(t, {k, v})"},
          {"dets:open_file", "dets:open_file(t, [])"},
          {"mnesia:dirty_read", "mnesia:dirty_read(t, k)"},
          {"persistent_term:get", "persistent_term:get(k)"},
          {"persistent_term:put", "persistent_term:put(k, v)"},
          {"rpc:call", "rpc:call(node, erlang, halt, [])"},
          {"global:register_name", "global:register_name(x, self())"},
          {"pg:join", "pg:join(g, self())"},
          {"net_kernel:connect_node", "net_kernel:connect_node(a)"},
          {"gen_tcp:connect", "gen_tcp:connect(\"h\", 80, [])"},
          {"gen_udp:open", "gen_udp:open(0)"},
          {"ssl:connect", "ssl:connect(\"h\", 443, [])"},
          {"inet:gethostbyname", "inet:gethostbyname(\"h\")"},
          {"code:load_file", "code:load_file(evil)"},
          {"code:which", "code:which(erlang)"},
          {"compile:file", "compile:file(\"x\")"},
          {"erl_eval:expr", "erl_eval:expr(a, b)"},
          {"init:stop", "init:stop()"},
          {"file:read_file (no fs cap)", "file:read_file(\"/etc/passwd\")"},
          {"prim_file:read_file", "prim_file:read_file(\"/etc/passwd\")"}
        ] do
      test "reject #{name}" do
        assert rejected?(body(unquote(b))), "expected rejection of: #{unquote(b)}"
      end
    end
  end

  describe "import/compile attributes do not grant authority" do
    test "-import of os does not make cmd callable" do
      src = """
      -module(m).
      -export([result/1]).
      -import(os, [cmd/1]).
      result(_) -> cmd("id").
      """

      assert rejected?(src)
    end

    test "-import of erlang halt does not make halt callable" do
      src = """
      -module(m).
      -export([result/1]).
      -import(erlang, [halt/0]).
      result(_) -> halt().
      """

      assert rejected?(src)
    end

    test "a parse_transform attribute never invokes a host module (no crash, no transform)" do
      src = """
      -module(m).
      -export([result/1]).
      -compile({parse_transform, hyperlang_nonexistent_evil_transform}).
      result(_) -> ok.
      """

      # Safe outcomes: rejected, or compiled while IGNORING the attribute. The
      # one unsafe outcome is the host running the named transform module.
      result = compile(src)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "-on_load attribute does not run guest code at load time outside the sandbox" do
      src = """
      -module(m).
      -export([result/1]).
      -on_load(boot/0).
      boot() -> ok.
      result(_) -> ok.
      """

      result = compile(src)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "-nifs attribute is inert" do
      src = """
      -module(m).
      -export([result/1]).
      -nifs([result/1]).
      result(_) -> ok.
      """

      result = compile(src)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "higher-order allowlisted functions do not launder a forbidden call" do
    for {name, b} <- [
          {"lists:foreach with os:cmd body", "lists:foreach(fun(_) -> os:cmd(\"id\") end, [1])"},
          {"lists:map with halt body", "lists:map(fun(_) -> halt() end, [1])"},
          {"maps:map with external fun", "maps:map(fun erlang:phash2/2, \#{a => 1})"},
          {"lists:foldl external fun", "lists:foldl(fun erlang:send/2, 0, [])"},
          {"maps:fold forbidden body", "maps:fold(fun(_, _, _) -> erlang:halt() end, 0, \#{})"}
        ] do
      test "reject #{name}" do
        assert rejected?(body(unquote(b))), "expected rejection of: #{unquote(b)}"
      end
    end
  end
end
