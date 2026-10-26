Code.require_file("gen_server_conformance_test.exs", __DIR__)

defmodule GenEventConformanceTest do
  use ExUnit.Case, async: false

  defmodule HostHandler do
    @behaviour :gen_event

    def init({{owner, id}, handoff}), do: {:ok, {owner, id, [handoff]}}
    def init({owner, id}), do: {:ok, {owner, id, []}}

    def handle_event(:crash, {_owner, :bad, _log}), do: exit(:boom)

    def handle_event(:slow, {owner, id, log}) do
      Process.sleep(5)
      send(owner, {:event, id, :slow})
      {:ok, {owner, id, [:slow | log]}}
    end

    def handle_event(event, {owner, id, log}) do
      send(owner, {:event, id, event})
      {:ok, {owner, id, [event | log]}}
    end

    def handle_call(:boom, {_owner, :bad, _log}), do: exit(:boom)
    def handle_call(:get, state), do: {:ok, state_result(state), state}
    def handle_call(request, state), do: {:ok, request, state}

    def handle_info(info, {owner, id, log}) do
      send(owner, {:info, id, info})
      {:ok, {owner, id, log}}
    end

    def terminate(_args, {_owner, id, _log}), do: {:handoff, id}
    def code_change(_old, state, _extra), do: {:ok, state}

    defp state_result({_owner, id, log}), do: {id, Enum.reverse(log)}
  end

  for {name, scenario} <- [
        {"add and delete handler", :add_delete},
        {"notify reaches all handlers in manager order", :notify_order},
        {"sync_notify is synchronous", :sync_notify},
        {"call targets a specific handler", :call_handler},
        {"crashing handler is removed and manager survives", :crash_containment},
        {"supervised owner is notified on crash and delete", :sup_notifications},
        {"swap_handler transfers terminate state", :swap_handler},
        {"which_handlers reports identities", :which_handlers},
        {"handler tuple ids dispatch through snapshot closure", :handler_ids},
        {"stop terminates the event manager", :stop_manager}
      ] do
    test name do
      scenario = unquote(scenario)
      assert host_result(scenario) == guest_result(scenario)
    end
  end

  test "vendored OTP 29 gen_event source is pinned" do
    source = File.read!(Path.expand("../vendor/otp_stdlib_8_0_1/src/gen_event.erl", __DIR__))

    assert Base.encode16(:crypto.hash(:sha256, source), case: :lower) ==
             "95f8cda0cbe976725ee75e319e9573b701741bef911a2a30d31b8a908bd8de9b"
  end

  defp host_result(scenario) do
    {:ok, manager} = :gen_event.start()
    result = host_scenario(manager, scenario)
    if Process.alive?(manager), do: :gen_event.stop(manager)
    result
  end

  defp host_scenario(manager, :add_delete) do
    :ok = :gen_event.add_handler(manager, HostHandler, {self(), :a})
    deleted = :gen_event.delete_handler(manager, HostHandler, :delete)
    {deleted, :gen_event.which_handlers(manager)}
  end

  defp host_scenario(manager, :notify_order) do
    :ok = :gen_event.add_handler(manager, {HostHandler, :a}, {self(), :a})
    :ok = :gen_event.add_handler(manager, {HostHandler, :b}, {self(), :b})
    :ok = :gen_event.notify(manager, :ping)
    [receive_event(), receive_event()]
  end

  defp host_scenario(manager, :sync_notify) do
    :ok = :gen_event.add_handler(manager, HostHandler, {self(), :a})
    :ok = :gen_event.sync_notify(manager, :slow)
    receive_event()
  end

  defp host_scenario(manager, :call_handler) do
    :ok = :gen_event.add_handler(manager, {HostHandler, :a}, {self(), :a})
    :gen_event.call(manager, {HostHandler, :a}, :hello)
  end

  defp host_scenario(manager, :crash_containment) do
    :ok = :gen_event.add_handler(manager, {HostHandler, :good}, {self(), :good})
    :ok = :gen_event.add_handler(manager, {HostHandler, :bad}, {self(), :bad})
    error = :gen_event.call(manager, {HostHandler, :bad}, :boom)

    {normalize_error(error), normalize_handlers(:gen_event.which_handlers(manager)),
     :gen_event.call(manager, {HostHandler, :good}, :ok)}
  end

  defp host_scenario(manager, :sup_notifications) do
    :ok = :gen_event.add_sup_handler(manager, {HostHandler, :bad}, {self(), :bad})
    :ok = :gen_event.notify(manager, :crash)

    crash =
      receive do
        {:gen_event_EXIT, {HostHandler, :bad}, reason} -> normalize_reason(reason)
      after
        500 -> :timeout
      end

    :ok = :gen_event.add_sup_handler(manager, {HostHandler, :a}, {self(), :a})
    _ = :gen_event.delete_handler(manager, {HostHandler, :a}, :delete)

    deleted =
      receive do
        {:gen_event_EXIT, {HostHandler, :a}, reason} -> reason
      after
        500 -> :timeout
      end

    {crash, deleted}
  end

  defp host_scenario(manager, :swap_handler) do
    :ok = :gen_event.add_handler(manager, {HostHandler, :a}, {self(), :a})

    :ok =
      :gen_event.swap_handler(
        manager,
        {{HostHandler, :a}, :swap},
        {{HostHandler, :b}, {self(), :b}}
      )

    :gen_event.call(manager, {HostHandler, :b}, :get)
  end

  defp host_scenario(manager, :which_handlers) do
    :ok = :gen_event.add_handler(manager, {HostHandler, :a}, {self(), :a})
    :ok = :gen_event.add_handler(manager, {HostHandler, :b}, {self(), :b})
    normalize_handlers(:gen_event.which_handlers(manager))
  end

  defp host_scenario(manager, :handler_ids) do
    :ok = :gen_event.add_handler(manager, {HostHandler, :a}, {self(), :a})
    :ok = :gen_event.add_handler(manager, {HostHandler, :b}, {self(), :b})

    {:gen_event.call(manager, {HostHandler, :a}, :left),
     :gen_event.call(manager, {HostHandler, :b}, :right)}
  end

  defp host_scenario(manager, :stop_manager) do
    :ok = :gen_event.add_handler(manager, HostHandler, {self(), :a})
    :ok = :gen_event.stop(manager)
    :stopped
  end

  defp receive_event do
    receive do
      {:event, id, event} -> {id, event}
    after
      500 -> :timeout
    end
  end

  defp normalize_error({:error, reason}), do: {:error, normalize_reason(reason)}
  defp normalize_error(other), do: other
  defp normalize_reason({:EXIT, reason}), do: {:EXIT, normalize_reason(reason)}
  defp normalize_reason({reason, _stack}) when is_atom(reason), do: reason
  defp normalize_reason(reason), do: reason

  defp normalize_handlers(handlers) do
    Enum.map(handlers, fn
      {HostHandler, id} -> {:event_handler, id}
      HostHandler -> :event_handler
    end)
  end

  defp guest_result(scenario) do
    GenServerConformanceTest.guest_result(guest_files(), "/src/main.erl", scenario)
  end

  defp guest_files do
    [
      GenServerConformanceTest.source_file("/src/event_handler.erl", guest_handler()),
      GenServerConformanceTest.source_file("/src/main.erl", guest_main())
    ]
  end

  defp guest_handler do
    ~S"""
    -module(event_handler).
    init({{Owner,Id},Handoff}) -> {ok,{Owner,Id,[Handoff]}};
    init({Owner,Id}) -> {ok,{Owner,Id,[]}}.
    handle_event(crash,{_Owner,bad,_Log}) -> exit(boom);
    handle_event(slow,{Owner,Id,Log}) -> timer:sleep(5), Owner ! {event,Id,slow}, {ok,{Owner,Id,[slow|Log]}};
    handle_event(Event,{Owner,Id,Log}) -> Owner ! {event,Id,Event}, {ok,{Owner,Id,[Event|Log]}}.
    handle_call(boom,{_Owner,bad,_Log}) -> exit(boom);
    handle_call(get,State) -> {ok,state_result(State),State};
    handle_call(Request,State) -> {ok,Request,State}.
    handle_info(Info,{Owner,Id,Log}) -> Owner ! {info,Id,Info}, {ok,{Owner,Id,Log}}.
    terminate(_Args,{_Owner,Id,_Log}) -> {handoff,Id}.
    code_change(_Old,State,_Extra) -> {ok,State}.
    state_result({_Owner,Id,Log}) -> {Id,lists:reverse(Log)}.
    """
  end

  defp guest_main do
    ~S"""
    -module(main).
    -export([result/1]).
    result(Scenario) -> {ok,M}=gen_event:start(), R=run(M,Scenario), case Scenario of stop_manager->ok; _->gen_event:stop(M) end, R.
    run(M,add_delete) -> ok=gen_event:add_handler(M,event_handler,{get('$self'),a}), D=gen_event:delete_handler(M,event_handler,delete), {D,gen_event:which_handlers(M)};
    run(M,notify_order) -> ok=gen_event:add_handler(M,{event_handler,a},{get('$self'),a}), ok=gen_event:add_handler(M,{event_handler,b},{get('$self'),b}), ok=gen_event:notify(M,ping), [recv_event(),recv_event()];
    run(M,sync_notify) -> ok=gen_event:add_handler(M,event_handler,{get('$self'),a}), ok=gen_event:sync_notify(M,slow), recv_event();
    run(M,call_handler) -> ok=gen_event:add_handler(M,{event_handler,a},{get('$self'),a}), gen_event:call(M,{event_handler,a},hello);
    run(M,crash_containment) -> ok=gen_event:add_handler(M,{event_handler,good},{get('$self'),good}), ok=gen_event:add_handler(M,{event_handler,bad},{get('$self'),bad}), E=gen_event:call(M,{event_handler,bad},boom), {normalize_error(E),gen_event:which_handlers(M),gen_event:call(M,{event_handler,good},ok)};
    run(M,sup_notifications) -> ok=gen_event:add_sup_handler(M,{event_handler,bad},{get('$self'),bad}), ok=gen_event:notify(M,crash), C=receive {gen_event_EXIT,{event_handler,bad},R}->normalize_reason(R) after 500->timeout end, ok=gen_event:add_sup_handler(M,{event_handler,a},{get('$self'),a}), gen_event:delete_handler(M,{event_handler,a},delete), D=receive {gen_event_EXIT,{event_handler,a},R2}->R2 after 500->timeout end, {C,D};
    run(M,swap_handler) -> ok=gen_event:add_handler(M,{event_handler,a},{get('$self'),a}), ok=gen_event:swap_handler(M,{{event_handler,a},swap},{{event_handler,b},{get('$self'),b}}), gen_event:call(M,{event_handler,b},get);
    run(M,which_handlers) -> ok=gen_event:add_handler(M,{event_handler,a},{get('$self'),a}), ok=gen_event:add_handler(M,{event_handler,b},{get('$self'),b}), gen_event:which_handlers(M);
    run(M,handler_ids) -> ok=gen_event:add_handler(M,{event_handler,a},{get('$self'),a}), ok=gen_event:add_handler(M,{event_handler,b},{get('$self'),b}), {gen_event:call(M,{event_handler,a},left),gen_event:call(M,{event_handler,b},right)};
    run(M,stop_manager) -> ok=gen_event:add_handler(M,event_handler,{get('$self'),a}), ok=gen_event:stop(M), stopped.
    recv_event() -> receive {event,Id,E}->{Id,E} after 500->timeout end.
    normalize_error({error,R}) -> {error,normalize_reason(R)};
    normalize_error(Other) -> Other.
    normalize_reason({'EXIT',R}) -> {'EXIT',normalize_reason(R)};
    normalize_reason({R,_Stack}) when is_atom(R) -> R;
    normalize_reason(R) -> R.
    """
  end
end
