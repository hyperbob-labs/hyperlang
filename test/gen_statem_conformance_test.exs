Code.require_file("gen_server_conformance_test.exs", __DIR__)

defmodule GenStatemConformanceTest do
  use ExUnit.Case, async: false

  defmodule HostStateFunctions do
    @behaviour :gen_statem
    def callback_mode, do: :state_functions

    def init({scenario, owner}) do
      actions =
        case scenario do
          :event_clear -> [{:timeout, 20, :fired}]
          :state_survive -> [{:state_timeout, 20, :fired}, {:next_event, :internal, :pulse}]
          :state_clear -> [{:state_timeout, 20, :fired}]
          _ -> []
        end

      {:ok, :locked, {scenario, owner, false, [], :none}, actions}
    end

    def locked({:call, from}, :mode, _data),
      do: {:keep_state_and_data, [{:reply, from, :state_functions}]}

    def locked({:call, from}, :get, {scenario, _owner, flag, log, held}),
      do: {:keep_state_and_data, [{:reply, from, result(scenario, flag, log, held)}]}

    def locked({:call, from}, :single, _data),
      do: {:keep_state_and_data, [{:reply, from, :single}]}

    def locked({:call, from}, :hold, {s, o, f, l, _}), do: {:keep_state, {s, o, f, l, from}}

    def locked({:call, from}, :release, {s, o, f, l, held}),
      do: {:keep_state, {s, o, f, l, :none}, [{:reply, held, :first}, {:reply, from, :second}]}

    def locked({:call, _from}, :never, _data), do: :keep_state_and_data

    def locked({:call, from}, :stop, data),
      do: {:stop_and_reply, :normal, {:reply, from, :stopped}, data}

    def locked({:call, _from}, :crash, _data), do: exit(:crashed)

    def locked({:call, from}, :arm_generic, _data),
      do: {:keep_state_and_data, [{:reply, from, :ok}, {{:timeout, :named}, 20, :fired}]}

    def locked({:call, from}, :cancel_generic, _data),
      do: {:keep_state_and_data, [{:reply, from, :ok}, {{:timeout, :named}, :cancel}]}

    def locked({:call, _from}, :wait, _data), do: {:keep_state_and_data, [:postpone]}
    def locked(:cast, :unlock, data), do: {:next_state, :open, data}
    def locked(:cast, :ping, _data), do: {:keep_state_and_data, []}
    def locked(:cast, :change, data), do: {:next_state, :open, data}

    def locked(:cast, :order, _data),
      do: {:keep_state_and_data, [{:next_event, :internal, :one}, {:next_event, :internal, :two}]}

    def locked(:internal, event, {s, o, f, log, h}),
      do: {:keep_state, {s, o, f, [event | log], h}}

    def locked(:timeout, :fired, {s, o, _f, l, h}), do: {:keep_state, {s, o, true, l, h}}
    def locked(:state_timeout, :fired, {s, o, _f, l, h}), do: {:keep_state, {s, o, true, l, h}}

    def locked({:timeout, :named}, :fired, {s, o, _f, l, h}),
      do: {:keep_state, {s, o, true, l, h}}

    def locked(_type, _event, _data), do: :keep_state_and_data

    def open({:call, from}, :wait, _data), do: {:keep_state_and_data, [{:reply, from, :retried}]}

    def open({:call, from}, :get, {s, _o, flag, log, held}),
      do: {:keep_state_and_data, [{:reply, from, result(s, flag, log, held)}]}

    def open(_type, _event, _data), do: :keep_state_and_data

    def terminate(_reason, _state, _data), do: :ok
    defp result(:next_order, _flag, log, _held), do: Enum.reverse(log)
    defp result(_scenario, flag, _log, _held), do: flag
  end

  defmodule HostHandleEvent do
    @behaviour :gen_statem
    def callback_mode, do: :handle_event_function
    def init(owner), do: {:ok, :state, owner}

    def handle_event({:call, from}, :mode, _state, _data),
      do: {:keep_state_and_data, [{:reply, from, :handle_event_function}]}

    def handle_event(_type, _event, _state, _data), do: :keep_state_and_data
    def terminate(_reason, _state, _data), do: :ok
  end

  defmodule HostEnter do
    @behaviour :gen_statem
    def callback_mode, do: [:state_functions, :state_enter]
    def init(owner), do: {:ok, :state, {owner, 0}}
    def state(:enter, _old, {owner, n}), do: {:keep_state, {owner, n + 1}}

    def state({:call, from}, :repeat, _data),
      do: {:repeat_state_and_data, [{:reply, from, :ok}]}

    def state({:call, from}, :count, _data),
      do: {:keep_state_and_data, [{:reply, from, 2}]}

    def state(_type, _event, _data), do: :keep_state_and_data
    def terminate(_reason, _state, _data), do: :ok
  end

  for {name, scenario} <- [
        {"state_functions callback mode", :state_functions},
        {"handle_event_function callback mode", :handle_event_function},
        {"state enter and repeat_state", :state_enter},
        {"event timeout is cleared by an event", :event_clear},
        {"state timeout survives internal events", :state_survive},
        {"state timeout is cleared on state change", :state_clear},
        {"generic named timeout fires", :generic_fire},
        {"generic named timeout cancels", :generic_cancel},
        {"postponed event retries after state change", :postpone},
        {"next_event actions preserve order", :next_order},
        {"single reply action", :reply_single},
        {"multiple reply actions", :reply_multi},
        {"call timeout exit shape", :call_timeout},
        {"stop from callback", :stop_callback},
        {"callback crash reaches caller", :crash_callback}
      ] do
    test name do
      scenario = unquote(scenario)
      assert host_result(scenario) == guest_result(scenario)
    end
  end

  test "vendored OTP 29 gen_statem source is pinned" do
    source = File.read!(Path.expand("../vendor/otp_stdlib_8_0_1/src/gen_statem.erl", __DIR__))

    assert Base.encode16(:crypto.hash(:sha256, source), case: :lower) ==
             "bf440edbf927c936137fc767378f23c476c2bc242f2d4767be4f1e55f8ad0025"
  end

  defp host_result(:handle_event_function) do
    {:ok, pid} = :gen_statem.start(HostHandleEvent, self(), [])
    result = :gen_statem.call(pid, :mode)
    :ok = :gen_statem.stop(pid)
    result
  end

  defp host_result(:state_enter) do
    {:ok, pid} = :gen_statem.start(HostEnter, self(), [])
    :ok = :gen_statem.call(pid, :repeat)
    result = :gen_statem.call(pid, :count)
    :ok = :gen_statem.stop(pid)
    result
  end

  defp host_result(scenario) do
    {:ok, pid} = :gen_statem.start(HostStateFunctions, {scenario, self()}, [])
    result = host_scenario(pid, scenario)
    if Process.alive?(pid), do: :gen_statem.stop(pid)
    result
  end

  defp host_scenario(pid, :state_functions), do: :gen_statem.call(pid, :mode)

  defp host_scenario(pid, :event_clear) do
    Process.sleep(2)
    :ok = :gen_statem.cast(pid, :ping)
    Process.sleep(35)
    :gen_statem.call(pid, :get)
  end

  defp host_scenario(pid, :state_survive) do
    Process.sleep(35)
    :gen_statem.call(pid, :get)
  end

  defp host_scenario(pid, :state_clear) do
    :ok = :gen_statem.cast(pid, :change)
    Process.sleep(35)
    :gen_statem.call(pid, :get)
  end

  defp host_scenario(pid, :generic_fire) do
    :ok = :gen_statem.call(pid, :arm_generic)
    Process.sleep(35)
    :gen_statem.call(pid, :get)
  end

  defp host_scenario(pid, :generic_cancel) do
    :ok = :gen_statem.call(pid, :arm_generic)
    :ok = :gen_statem.call(pid, :cancel_generic)
    Process.sleep(35)
    :gen_statem.call(pid, :get)
  end

  defp host_scenario(pid, :postpone) do
    req = :gen_statem.send_request(pid, :wait)
    Process.sleep(5)
    :ok = :gen_statem.cast(pid, :unlock)
    {:reply, result} = :gen_statem.wait_response(req, 500)
    result
  end

  defp host_scenario(pid, :next_order) do
    :ok = :gen_statem.cast(pid, :order)
    :gen_statem.call(pid, :get)
  end

  defp host_scenario(pid, :reply_single), do: :gen_statem.call(pid, :single)

  defp host_scenario(pid, :reply_multi) do
    req = :gen_statem.send_request(pid, :hold)
    Process.sleep(5)
    second = :gen_statem.call(pid, :release)
    {:reply, first} = :gen_statem.wait_response(req, 500)
    {first, second}
  end

  defp host_scenario(pid, :call_timeout) do
    try do
      :gen_statem.call(pid, :never, 1)
    catch
      :exit, {:timeout, _} -> :timeout
    end
  end

  defp host_scenario(pid, :stop_callback), do: :gen_statem.call(pid, :stop)

  defp host_scenario(pid, :crash_callback) do
    try do
      :gen_statem.call(pid, :crash, 100)
    catch
      :exit, {:crashed, _} -> :crashed
    end
  end

  defp guest_result(scenario) do
    GenServerConformanceTest.guest_result(guest_files(), "/src/main.erl", scenario)
  end

  defp guest_files do
    [
      GenServerConformanceTest.source_file("/src/statem_sf.erl", guest_state_functions()),
      GenServerConformanceTest.source_file("/src/statem_hef.erl", guest_handle_event()),
      GenServerConformanceTest.source_file("/src/statem_enter.erl", guest_enter()),
      GenServerConformanceTest.source_file("/src/main.erl", guest_main())
    ]
  end

  defp guest_state_functions do
    ~S"""
    -module(statem_sf).
    init({Scenario,Owner}) ->
      Actions=case Scenario of event_clear -> [{timeout,20,fired}];
        state_survive -> [{state_timeout,20,fired},{next_event,internal,pulse}];
        state_clear -> [{state_timeout,20,fired}]; _ -> [] end,
      {ok,locked,{Scenario,Owner,false,[],none},Actions}.
    callback_mode() -> state_functions.
    locked({call,From},mode,_D) -> {keep_state_and_data,[{reply,From,state_functions}]};
    locked({call,From},get,{S,_O,F,L,H}) -> {keep_state_and_data,[{reply,From,result(S,F,L,H)}]};
    locked({call,From},single,_D) -> {keep_state_and_data,[{reply,From,single}]};
    locked({call,From},hold,{S,O,F,L,_}) -> {keep_state,{S,O,F,L,From}};
    locked({call,From},release,{S,O,F,L,Held}) -> {keep_state,{S,O,F,L,none},[{reply,Held,first},{reply,From,second}]};
    locked({call,_From},never,_D) -> keep_state_and_data;
    locked({call,From},stop,D) -> {stop_and_reply,normal,{reply,From,stopped},D};
    locked({call,_From},crash,_D) -> exit(crashed);
    locked({call,From},arm_generic,_D) -> {keep_state_and_data,[{reply,From,ok},{{timeout,named},20,fired}]};
    locked({call,From},cancel_generic,_D) -> {keep_state_and_data,[{reply,From,ok},{{timeout,named},cancel}]};
    locked({call,_From},wait,_D) -> {keep_state_and_data,[postpone]};
    locked(cast,unlock,D) -> {next_state,open,D};
    locked(cast,ping,_D) -> keep_state_and_data;
    locked(cast,change,D) -> {next_state,open,D};
    locked(cast,order,_D) -> {keep_state_and_data,[{next_event,internal,one},{next_event,internal,two}]};
    locked(internal,E,{S,O,F,L,H}) -> {keep_state,{S,O,F,[E|L],H}};
    locked(timeout,fired,{S,O,_F,L,H}) -> {keep_state,{S,O,true,L,H}};
    locked(state_timeout,fired,{S,O,_F,L,H}) -> {keep_state,{S,O,true,L,H}};
    locked({timeout,named},fired,{S,O,_F,L,H}) -> {keep_state,{S,O,true,L,H}};
    locked(_T,_E,_D) -> keep_state_and_data.
    open({call,From},wait,_D) -> {keep_state_and_data,[{reply,From,retried}]};
    open({call,From},get,{S,_O,F,L,H}) -> {keep_state_and_data,[{reply,From,result(S,F,L,H)}]};
    open(_T,_E,_D) -> keep_state_and_data.
    terminate(_R,_S,_D) -> ok.
    result(next_order,_F,L,_H) -> lists:reverse(L);
    result(_S,F,_L,_H) -> F.
    """
  end

  defp guest_handle_event do
    ~S"""
    -module(statem_hef).
    init(Owner) -> {ok,state,Owner}.
    callback_mode() -> handle_event_function.
    handle_event({call,From},mode,_S,_D) -> {keep_state_and_data,[{reply,From,handle_event_function}]};
    handle_event(_T,_E,_S,_D) -> keep_state_and_data.
    terminate(_R,_S,_D) -> ok.
    """
  end

  defp guest_enter do
    ~S"""
    -module(statem_enter).
    init(Owner) -> {ok,state,{Owner,0}}.
    callback_mode() -> [state_functions,state_enter].
    state(enter,_Old,{Owner,N}) -> {keep_state,{Owner,N+1}};
    state({call,From},repeat,_D) -> {repeat_state_and_data,[{reply,From,ok}]};
    state({call,From},count,{_Owner,N}) -> {keep_state_and_data,[{reply,From,N}]};
    state(_T,_E,_D) -> keep_state_and_data.
    terminate(_R,_S,_D) -> ok.
    """
  end

  defp guest_main do
    ~S"""
    -module(main).
    -export([result/1]).
    result(handle_event_function) -> {ok,S}=gen_statem:start(statem_hef,get('$self'),[]), R=gen_statem:call(S,mode), gen_statem:stop(S), R;
    result(state_enter) -> {ok,S}=gen_statem:start(statem_enter,get('$self'),[]), ok=gen_statem:call(S,repeat), R=gen_statem:call(S,count), gen_statem:stop(S), R;
    result(Scenario) -> {ok,S}=gen_statem:start(statem_sf,{Scenario,get('$self')},[]), R=run(S,Scenario), case Scenario of stop_callback -> ok; crash_callback -> ok; _ -> gen_statem:stop(S) end, R.
    run(S,state_functions) -> gen_statem:call(S,mode);
    run(S,event_clear) -> timer:sleep(2), gen_statem:cast(S,ping), timer:sleep(35), gen_statem:call(S,get);
    run(S,state_survive) -> timer:sleep(35), gen_statem:call(S,get);
    run(S,state_clear) -> gen_statem:cast(S,change), timer:sleep(35), gen_statem:call(S,get);
    run(S,generic_fire) -> ok=gen_statem:call(S,arm_generic), timer:sleep(35), gen_statem:call(S,get);
    run(S,generic_cancel) -> ok=gen_statem:call(S,arm_generic), ok=gen_statem:call(S,cancel_generic), timer:sleep(35), gen_statem:call(S,get);
    run(S,postpone) -> Req=gen_statem:send_request(S,wait), timer:sleep(5), gen_statem:cast(S,unlock), {reply,R}=gen_statem:wait_response(Req,500), R;
    run(S,next_order) -> gen_statem:cast(S,order), gen_statem:call(S,get);
    run(S,reply_single) -> gen_statem:call(S,single);
    run(S,reply_multi) -> Req=gen_statem:send_request(S,hold), timer:sleep(5), Second=gen_statem:call(S,release), {reply,First}=gen_statem:wait_response(Req,500), {First,Second};
    run(S,call_timeout) -> try gen_statem:call(S,never,1) catch exit:{timeout,_}->timeout end;
    run(S,stop_callback) -> gen_statem:call(S,stop);
    run(S,crash_callback) -> try gen_statem:call(S,crash,100) catch exit:_Reason->crashed end.
    """
  end
end
