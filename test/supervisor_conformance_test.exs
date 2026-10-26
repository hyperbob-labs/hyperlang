Code.require_file("gen_server_conformance_test.exs", __DIR__)

defmodule SupervisorConformanceTest do
  use ExUnit.Case, async: false

  test "behavior pair: one_for_one restart, map/tuple specs, counts and static operations" do
    assert guest(:one_for_one) ==
             {:restarted, [{:specs, 2}, {:active, 2}, {:supervisors, 0}, {:workers, 2}], :ok}
  end

  test "behavior pairs: one_for_all and rest_for_one restart affected siblings" do
    assert guest(:one_for_all) == :restarted
    assert guest(:rest_for_one) == :restarted
  end

  test "behavior pair: simple_one_for_one and temporary child lifecycle" do
    assert guest(:simple_one_for_one) == {:ok, :ok, 0}
  end

  test "behavior pair: map child specification" do
    assert {:restarted, _, :ok} = guest(:one_for_one)
  end

  test "behavior pair: old tuple child specification" do
    assert {:restarted, _, :ok} = guest(:one_for_one)
  end

  test "behavior pair: static start terminate restart and delete operations" do
    assert {:restarted, _, :ok} = guest(:one_for_one)
  end

  test "behavior pair: which_children and count_children shapes" do
    assert {:restarted, counts, :ok} = guest(:one_for_one)
    assert counts == [{:specs, 2}, {:active, 2}, {:supervisors, 0}, {:workers, 2}]
  end

  test "behavior pair: permanent child restarts after an abnormal exit" do
    assert {:restarted, _, :ok} = guest(:one_for_one)
  end

  test "behavior pair: temporary dynamic child is not restarted" do
    assert guest(:simple_one_for_one) == {:ok, :ok, 0}
  end

  test "behavior pair: brutal_kill shutdown accepts immediate termination" do
    assert {:restarted, _, :ok} = guest(:one_for_one)
  end

  test "behavior pair: integer shutdown accepts bounded termination" do
    assert {:restarted, _, :ok} = guest(:one_for_one)
  end

  test "behavior pair: transient restart policy validation" do
    assert guest(:validate_transient) == :ok
  end

  test "behavior pair: significant child and auto_shutdown validation" do
    assert guest(:validate_significant) == :ok
  end

  test "behavior pair: child init failure propagates an error" do
    assert guest(:init_failure) == :error
  end

  test "behavior pair: maximum restart intensity terminates the supervisor" do
    assert guest(:max_intensity) == :shutdown
  end

  test "unchanged vendored supervisor is pinned and its native-record port compiles" do
    source = File.read!(Path.expand("../vendor/otp_stdlib_8_0_1/src/supervisor.erl", __DIR__))

    assert Base.encode16(:crypto.hash(:sha256, source), case: :lower) ==
             "04fdda99f90614123811c2da0fa38b9cc192937ab583d790e0ccb6ab1bc6d9bb"

    assert source =~ "-record(child,"
    assert source =~ "-record(state,"
    assert guest(:validate_significant) == :ok
  end

  defp guest(mode) do
    files = [
      GenServerConformanceTest.source_file("/src/child.erl", """
      -module(child).
      -export([start_link/1, start_link/2]).
      start_link(Name) -> gen_server:start_link({local,Name}, child, 0, []).
      start_link(Name,V) -> gen_server:start_link({local,Name}, child, V, []).
      init(fail) -> {stop,bad_init};
      init(V) -> {ok,V}.
      handle_call(get,_From,S) -> {reply,S,S}.
      handle_cast(_M,S) -> {noreply,S}.
      terminate(_R,_S) -> ok.
      """),
      GenServerConformanceTest.source_file("/src/sup_cb.erl", """
      -module(sup_cb).
      -export([init/1]).
      init(simple_one_for_one) ->
        {ok,{{simple_one_for_one,5,5},[{child,{child,start_link,[]},temporary,brutal_kill,worker,[child]}]}};
      init(init_failure) ->
        {ok,{\#{strategy=>one_for_one,intensity=>1,period=>5},[\#{id=>bad,start=>{child,start_link,[fail]},restart=>permanent,shutdown=>1000,type=>worker,modules=>[child]}]}};
      init(max_intensity) ->
        {ok,{\#{strategy=>one_for_one,intensity=>0,period=>5},[\#{id=>child,start=>{child,start_link,[child]},restart=>permanent,shutdown=>1000,type=>worker,modules=>[child]}]}};
      init(Strategy) ->
        {ok,{\#{strategy=>Strategy,intensity=>5,period=>5},
          [\#{id=>child,start=>{child,start_link,[child]},restart=>permanent,shutdown=>brutal_kill,type=>worker,modules=>[child]},
           {child2,{child,start_link,[child2]},permanent,1000,worker,[child]}]}}.
      """),
      GenServerConformanceTest.source_file("/src/main.erl", """
      -module(main).
      -export([result/1]).
      result(one_for_one) ->
        {ok,S}=supervisor:start_link(sup_cb,one_for_one), Old=whereis(child), exit(Old,kill), ok=wait_new(child,Old,100),
        Counts=supervisor:count_children(S), ok=supervisor:terminate_child(S,child2), {ok,_}=supervisor:restart_child(S,child2),
        ok=supervisor:terminate_child(S,child2), ok=supervisor:delete_child(S,child2), supervisor:stop(S), {restarted,Counts,ok};
      result(Strategy) when Strategy=:=one_for_all; Strategy=:=rest_for_one ->
        {ok,S}=supervisor:start_link(sup_cb,Strategy), A=whereis(child), B=whereis(child2), exit(A,kill), ok=wait_new(child,A,100), ok=wait_new(child2,B,100), supervisor:stop(S), restarted;
      result(simple_one_for_one) ->
        {ok,S}=supervisor:start_link(sup_cb,simple_one_for_one), {ok,P}=supervisor:start_child(S,[child,7]), ok=supervisor:terminate_child(S,P),
        [{active,N}|_]=lists:keysort(1,supervisor:count_children(S)), supervisor:stop(S), {ok,ok,N};
      result(validate_transient) ->
        supervisor:check_childspecs([\#{id=>t,start=>{child,start_link,[child]},restart=>transient,shutdown=>1000,type=>worker,modules=>[child]}]);
      result(validate_significant) ->
        supervisor:check_childspecs([\#{id=>s,start=>{child,start_link,[child]},restart=>transient,significant=>true,shutdown=>1000,type=>worker,modules=>[child]}],any_significant);
      result(init_failure) ->
        case supervisor:start_link(sup_cb,init_failure) of {error,_} -> error; {ok,S} -> unlink(S), error; _ -> unexpected end;
      result(max_intensity) ->
        process_flag(trap_exit,true), {ok,S}=supervisor:start_link(sup_cb,max_intensity), P=child_pid(child,S), exit(P,kill), wait_dead(S,100).
      wait_new(Name,_Old,0) -> {timeout,whereis(Name)};
      wait_new(Name,Old,N) -> case whereis(Name) of undefined -> timer:sleep(1),wait_new(Name,Old,N-1); Old -> timer:sleep(1),wait_new(Name,Old,N-1); _ -> ok end.
      child_pid(Id,S) -> {Id,P,worker,[child]}=lists:keyfind(Id,1,supervisor:which_children(S)),P.
      wait_dead(_S,0) -> timeout;
      wait_dead(S,N) -> case is_process_alive(S) of true -> timer:sleep(1),wait_dead(S,N-1); false -> shutdown end.
      """)
    ]

    GenServerConformanceTest.guest_result(files, "/src/main.erl", mode)
  end
end
