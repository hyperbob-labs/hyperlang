%% SPDX-License-Identifier: Apache-2.0
%% Copyright Ericsson AB 2016-2026. All Rights Reserved.
%% Modifications copyright The Hyperlang Authors.
%%
%% Hyperlang guest port of OTP stdlib-8.0.1 gen_statem.erl.
%% Vendored reference: vendor/otp_stdlib_8_0_1/src/gen_statem.erl

-module(gen_statem).

-export([start/3,start/4,start_link/3,start_link/4,
         start_monitor/3,start_monitor/4,
         stop/1,stop/3,cast/2,call/2,call/3,
         send_request/2,send_request/4,
         wait_response/1,wait_response/2,wait_response/3,
         receive_response/1,receive_response/2,receive_response/3,
         check_response/2,check_response/3,
         reqids_new/0,reqids_size/1,reqids_add/3,reqids_to_list/1,
         enter_loop/4,enter_loop/5,enter_loop/6,
         reply/1,reply/2]).
-export([init_it/6,system_continue/3,system_terminate/4,
         system_code_change/4,system_get_state/1,system_replace_state/2,
         format_status/2,format_log/1,format_log/2]).

-record(params, {parent, name, modules = [], callback_mode = state_functions,
                 state_enter = false, hibernate_after = infinity}).
-record(statem_state, {state, data, postponed = [], timers = #{}, hibernate = false}).

start(Module, Args, Opts) when is_atom(Module), is_list(Opts) ->
    gen:start(gen_statem, nolink, Module, Args, Opts);
start(Module, Args, Opts) -> erlang:error(badarg, [Module,Args,Opts]).

start(Name, Module, Args, Opts) when is_tuple(Name), is_atom(Module), is_list(Opts) ->
    gen:start(gen_statem, nolink, Name, Module, Args, Opts);
start(Name, Module, Args, Opts) -> erlang:error(badarg, [Name,Module,Args,Opts]).

start_link(Module, Args, Opts) when is_atom(Module), is_list(Opts) ->
    gen:start(gen_statem, link, Module, Args, Opts);
start_link(Module, Args, Opts) -> erlang:error(badarg, [Module,Args,Opts]).

start_link(Name, Module, Args, Opts) when is_tuple(Name), is_atom(Module), is_list(Opts) ->
    gen:start(gen_statem, link, Name, Module, Args, Opts);
start_link(Name, Module, Args, Opts) -> erlang:error(badarg, [Name,Module,Args,Opts]).

start_monitor(Module, Args, Opts) when is_atom(Module), is_list(Opts) ->
    gen:start(gen_statem, monitor, Module, Args, Opts);
start_monitor(Module, Args, Opts) -> erlang:error(badarg, [Module,Args,Opts]).

start_monitor(Name, Module, Args, Opts) when is_tuple(Name), is_atom(Module), is_list(Opts) ->
    gen:start(gen_statem, monitor, Name, Module, Args, Opts);
start_monitor(Name, Module, Args, Opts) -> erlang:error(badarg, [Name,Module,Args,Opts]).

stop(Server) -> gen:stop(Server).
stop(Server, Reason, Timeout) -> gen:stop(Server, Reason, Timeout).

cast(Server, Msg) ->
    cast_target(Server) ! {'$gen_cast',Msg},
    ok.

call(Server, Request) -> call(Server, Request, infinity).
call(Server, Request, Timeout) ->
    T = call_timeout(Timeout),
    try gen:call(Server, '$gen_call', Request, T) of
        {ok,Reply} -> Reply
    catch
        exit:Reason -> exit({Reason,{gen_statem,call,[Server,Request,Timeout]}})
    end.

send_request(Server, Request) -> gen:send_request(Server, '$gen_call', Request).
send_request(Server, Request, Label, ReqIds) ->
    gen:send_request(Server, '$gen_call', Request, Label, ReqIds).
wait_response(ReqId) -> wait_response(ReqId, infinity).
wait_response(ReqId, Timeout) -> gen:wait_response(ReqId, Timeout).
wait_response(ReqIds, Timeout, Delete) -> gen:wait_response(ReqIds, Timeout, Delete).
receive_response(ReqId) -> receive_response(ReqId, infinity).
receive_response(ReqId, Timeout) -> gen:receive_response(ReqId, Timeout).
receive_response(ReqIds, Timeout, Delete) -> gen:receive_response(ReqIds, Timeout, Delete).
check_response(Msg, ReqId) -> gen:check_response(Msg, ReqId).
check_response(Msg, ReqIds, Delete) -> gen:check_response(Msg, ReqIds, Delete).
reqids_new() -> gen:reqids_new().
reqids_size(ReqIds) -> gen:reqids_size(ReqIds).
reqids_add(ReqId, Label, ReqIds) -> gen:reqids_add(ReqId, Label, ReqIds).
reqids_to_list(ReqIds) -> gen:reqids_to_list(ReqIds).

reply({reply,From,Reply}) -> reply(From, Reply);
reply(Replies) when is_list(Replies) -> replies(Replies).
reply(From, Reply) -> gen:reply(From, Reply).

replies([{reply,From,Reply}|Rest]) -> reply(From, Reply), replies(Rest);
replies([]) -> ok.

enter_loop(_Module, _Opts, _State, _Data) -> erlang:error({unsupported,enter_loop}).
enter_loop(_Module, _Opts, _State, _Data, _Name) -> erlang:error({unsupported,enter_loop}).
enter_loop(_Module, _Opts, _State, _Data, _Name, _Actions) ->
    erlang:error({unsupported,enter_loop}).

init_it(Starter, Parent, Name0, Module, Args, Opts) ->
    Name = gen:get_proc_name(Name0),
    P0 = #params{parent=Parent,name=Name,modules=[Module],
                 hibernate_after=gen:hibernate_after(Opts)},
    try Module:init(Args) of
        Result -> init_result(Result, Starter, Name0, P0)
    catch
        throw:Result -> init_result(Result, Starter, Name0, P0);
        Class:Reason ->
            gen:unregister_name(Name0),
            proc_lib:init_ack(Starter, {error,Reason}),
            raise_class(Class, Reason)
    end.

init_result({ok,State,Data}, Starter, _Name, P0) ->
    proc_lib:init_ack(Starter, {ok,get('$self')}),
    enter(P0, #statem_state{state=State,data=Data}, []);
init_result({ok,State,Data,Actions}, Starter, _Name, P0) ->
    proc_lib:init_ack(Starter, {ok,get('$self')}),
    enter(P0, #statem_state{state=State,data=Data}, Actions);
init_result({stop,Reason}, Starter, Name, _P) ->
    gen:unregister_name(Name), proc_lib:init_ack(Starter, {error,Reason}), exit(Reason);
init_result({error,_}=Error, Starter, Name, _P) ->
    gen:unregister_name(Name), proc_lib:init_ack(Starter, Error), exit(normal);
init_result(ignore, Starter, Name, _P) ->
    gen:unregister_name(Name), proc_lib:init_ack(Starter, ignore), exit(normal);
init_result(Other, Starter, Name, _P) ->
    Reason = {bad_return_from_init,Other},
    gen:unregister_name(Name), proc_lib:init_ack(Starter, {error,Reason}), erlang:error(Reason).

enter(P0, S0, Actions) ->
    case set_callback_mode(P0) of
        {ok,P} ->
            case apply_actions(P, S0, none, Actions, true, false, [], []) of
                {ok,P1,S1,_Postpone,Next,Zero} ->
                    case P1#params.state_enter of
                        true ->
                            Result = callback(P1, enter, S1#statem_state.state, S1),
                            continue_transition(P1,S1,{enter,S1#statem_state.state},Result,false,Next,Zero);
                        false -> loop(P1,S1,Next ++ Zero)
                    end;
                {stop,Reason,S1,Replies} -> stop_with_replies(P,S1,Reason,Replies)
            end;
        {error,Reason} -> erlang:error(Reason)
    end.

loop(P, S, [{'$zero',Type,Ref,Content}|Events]) ->
    case maps:find(Type,S#statem_state.timers) of
        {ok,{Ref,Content}} ->
            S1=S#statem_state{timers=maps:remove(Type,S#statem_state.timers)},
            handle_event(P,S1,{Type,Content},Events);
        _ -> loop(P,S,Events)
    end;
loop(P, S, [Event|Events]) ->
    handle_event(P, S, Event, Events);
loop(P, S, []) ->
    receive
        Msg -> decode_msg(P,S,Msg)
    after P#params.hibernate_after ->
        loop(P,S#statem_state{hibernate=false},[])
    end.

decode_msg(P,S,{'$gen_call',From,Request}) ->
    handle_event(P,S,{{call,From},Request},[]);
decode_msg(P,S,{'$gen_cast',Request}) ->
    handle_event(P,S,{cast,Request},[]);
decode_msg(P,S,{'$gen_stop',From,Reason}) ->
    terminate_callback(P,S,Reason),
    gen:unregister_name(P#params.name),
    reply(From,ok),
    exit(Reason);
decode_msg(P,S,{timeout,Ref,Type}=Msg) when is_integer(Ref) ->
    Timers = S#statem_state.timers,
    case maps:find(Type, Timers) of
        {ok,{Ref,Content}} ->
            S1 = S#statem_state{timers=maps:remove(Type,Timers)},
            handle_event(P,S1,{Type,Content},[]);
        _ ->
            case maps:find(Ref, Timers) of
                {ok,cancelled} -> loop(P,S#statem_state{timers=maps:remove(Ref,Timers)},[]);
                _ -> handle_event(P,S,{info,Msg},[])
            end
    end;
decode_msg(P,S,{system,From,Request}) ->
    otp_sys:handle_system_msg(Request,From,P#params.parent,gen_statem,[],{P,S},S#statem_state.hibernate);
decode_msg(P,S,{'EXIT',Pid,Reason}=Msg) ->
    case P#params.parent of
        Pid -> terminate(P,S,exit,Reason);
        _ -> handle_event(P,S,{info,Msg},[])
    end;
decode_msg(P,S,Msg) -> handle_event(P,S,{info,Msg},[]).

handle_event(P,S,Event,Events) ->
    Result = callback(P, element(1,Event), element(2,Event), S),
    continue_transition(P,S,Event,Result,true,Events,[]).

callback(P=#params{modules=[Module|_],callback_mode=state_functions},Type,Content,S) ->
    try apply(Module,S#statem_state.state,[Type,Content,S#statem_state.data])
    catch
        throw:Result -> Result;
        Class:Reason -> terminate(P,S,Class,Reason)
    end;
callback(P=#params{modules=[Module|_]},Type,Content,S) ->
    try Module:handle_event(Type,Content,S#statem_state.state,S#statem_state.data)
    catch
        throw:Result -> Result;
        Class:Reason -> terminate(P,S,Class,Reason)
    end.

continue_transition(P,S,Event,Result,StateCall,Events,QueuedZero) ->
    case result_transition(Result,S,StateCall) of
        {ok,NextState,NextData,CallEnter,Actions} ->
            Changed = NextState =/= S#statem_state.state,
            S0 = cancel_automatic(S,Changed),
            SBase = S0#statem_state{state=NextState,data=NextData},
            case apply_actions(P,SBase,Event,Actions,StateCall,false,[],[]) of
                {ok,P1,S1,Postpone,NextEvents,ZeroEvents} ->
                    Postponed1 = case Postpone of true -> [Event|S1#statem_state.postponed]; false -> S1#statem_state.postponed end,
                    {Retry,S2} = case Changed of
                        true -> {lists:reverse(Postponed1),S1#statem_state{postponed=[]}};
                        false -> {[],S1#statem_state{postponed=Postponed1}}
                    end,
                    Queue0 = NextEvents ++ Retry ++ Events ++ QueuedZero ++ ZeroEvents,
                    case CallEnter andalso P1#params.state_enter of
                        true ->
                            EnterEvent = {enter,S#statem_state.state},
                            EnterResult = callback(P1,enter,S#statem_state.state,S2),
                            continue_transition(P1,S2,EnterEvent,EnterResult,false,Queue0,[]);
                        false -> loop(P1,S2,Queue0)
                    end;
                {stop,Reason,S1,Replies} -> stop_with_replies(P,S1,Reason,Replies)
            end;
        {stop,Reason,S1,Replies} -> stop_with_replies(P,S1,Reason,Replies);
        {error,Reason} -> terminate(P,S,error,Reason)
    end.

result_transition({next_state,State,Data},_S,true) -> {ok,State,Data,true,[]};
result_transition({next_state,State,Data,Actions},_S,true) -> {ok,State,Data,true,Actions};
result_transition({next_state,State,Data},S,false) when State =:= S#statem_state.state -> {ok,State,Data,false,[]};
result_transition({next_state,State,Data,Actions},S,false) when State =:= S#statem_state.state -> {ok,State,Data,false,Actions};
result_transition({keep_state,Data},S,_Call) -> {ok,S#statem_state.state,Data,false,[]};
result_transition({keep_state,Data,Actions},S,_Call) -> {ok,S#statem_state.state,Data,false,Actions};
result_transition(keep_state_and_data,S,_Call) -> {ok,S#statem_state.state,S#statem_state.data,false,[]};
result_transition({keep_state_and_data,Actions},S,_Call) -> {ok,S#statem_state.state,S#statem_state.data,false,Actions};
result_transition({repeat_state,Data},S,true) -> {ok,S#statem_state.state,Data,true,[]};
result_transition({repeat_state,Data,Actions},S,true) -> {ok,S#statem_state.state,Data,true,Actions};
result_transition(repeat_state_and_data,S,true) -> {ok,S#statem_state.state,S#statem_state.data,true,[]};
result_transition({repeat_state_and_data,Actions},S,true) -> {ok,S#statem_state.state,S#statem_state.data,true,Actions};
result_transition(stop,S,_Call) -> {stop,normal,S,[]};
result_transition({stop,Reason},S,_Call) -> {stop,Reason,S,[]};
result_transition({stop,Reason,Data},S,_Call) -> {stop,Reason,S#statem_state{data=Data},[]};
result_transition({stop_and_reply,Reason,Replies},S,_Call) -> {stop,Reason,S,listify(Replies)};
result_transition({stop_and_reply,Reason,Replies,Data},S,_Call) ->
    {stop,Reason,S#statem_state{data=Data},listify(Replies)};
result_transition(Result,_S,false) -> {error,{bad_state_enter_return_from_state_function,Result}};
result_transition(Result,_S,_Call) -> {error,{bad_return_from_state_function,Result}}.

apply_actions(P,S,_Event,Actions,StateCall,Postpone,Next,Zero) when not is_list(Actions) ->
    apply_actions(P,S,none,[Actions],StateCall,Postpone,Next,Zero);
apply_actions(P,S,_Event,[],_StateCall,Postpone,Next,Zero) ->
    {ok,P,S,Postpone,Next,Zero};
apply_actions(P,S,Event,[Action|Rest],StateCall,Postpone,Next,Zero) ->
    case Action of
        {reply,From,Reply} ->
            reply(From,Reply), apply_actions(P,S,Event,Rest,StateCall,Postpone,Next,Zero);
        postpone when StateCall ->
            apply_actions(P,S,Event,Rest,StateCall,true,Next,Zero);
        {postpone,Bool} when StateCall; Bool =:= false ->
            apply_actions(P,S,Event,Rest,StateCall,Bool,Next,Zero);
        hibernate -> apply_actions(P,S#statem_state{hibernate=true},Event,Rest,StateCall,Postpone,Next,Zero);
        {hibernate,Bool} when is_boolean(Bool) ->
            apply_actions(P,S#statem_state{hibernate=Bool},Event,Rest,StateCall,Postpone,Next,Zero);
        {next_event,Type,Content} when StateCall ->
            apply_actions(P,S,Event,Rest,StateCall,Postpone,Next++[{Type,Content}],Zero);
        {change_callback_module,Module} when StateCall, is_atom(Module) ->
            [_|Tail] = P#params.modules,
            case set_callback_mode(P#params{modules=[Module|Tail]}) of
                {ok,P1} -> apply_actions(P1,S,Event,Rest,StateCall,Postpone,Next,Zero);
                {error,R} -> {stop,R,S,[]}
            end;
        {push_callback_module,Module} when StateCall, is_atom(Module) ->
            case set_callback_mode(P#params{modules=[Module|P#params.modules]}) of
                {ok,P1} -> apply_actions(P1,S,Event,Rest,StateCall,Postpone,Next,Zero);
                {error,R} -> {stop,R,S,[]}
            end;
        pop_callback_module when StateCall ->
            case P#params.modules of
                [_Current,NextModule|Tail] ->
                    case set_callback_mode(P#params{modules=[NextModule|Tail]}) of
                        {ok,P1} -> apply_actions(P1,S,Event,Rest,StateCall,Postpone,Next,Zero);
                        {error,R} -> {stop,R,S,[]}
                    end;
                _ -> {stop,{bad_action_from_state_function,Action},S,[]}
            end;
        {Type,cancel} ->
            case timeout_type(Type) of
                true -> apply_actions(P,cancel_timeout(Type,S),Event,Rest,StateCall,Postpone,Next,Zero);
                false -> {stop,{bad_action_from_state_function,Action},S,[]}
            end;
        {Type,update,Msg} ->
            case timeout_type(Type) of
                true -> apply_actions(P,update_timeout(Type,Msg,S),Event,Rest,StateCall,Postpone,Next,Zero);
                false -> {stop,{bad_action_from_state_function,Action},S,[]}
            end;
        {Type,Time,Msg} ->
            timeout_action(P,S,Event,Rest,StateCall,Postpone,Next,Zero,Type,Time,Msg,[]);
        {Type,Time,Msg,Opts} ->
            timeout_action(P,S,Event,Rest,StateCall,Postpone,Next,Zero,Type,Time,Msg,listify(Opts));
        Time when (is_integer(Time) andalso Time >= 0) orelse Time =:= infinity ->
            timeout_action(P,S,Event,Rest,StateCall,Postpone,Next,Zero,timeout,Time,Time,[]);
        _ -> {stop,{bad_action_from_state_function,Action},S,[]}
    end.

timeout_action(P,S,Event,Rest,StateCall,Postpone,Next,Zero,Type,Time,Msg,Opts) ->
    case timeout_type(Type) andalso valid_time(Time,Opts) of
        true ->
            case Time of
                infinity -> apply_actions(P,cancel_timeout(Type,S),Event,Rest,StateCall,Postpone,Next,Zero);
                update -> apply_actions(P,update_timeout(Type,Msg,S),Event,Rest,StateCall,Postpone,Next,Zero);
                0 ->
                    S1 = cancel_timeout(Type,S), Ref=make_ref(),
                    S2 = S1#statem_state{timers=maps:put(Type,{Ref,Msg},S1#statem_state.timers)},
                    apply_actions(P,S2,Event,Rest,StateCall,Postpone,Next,
                                  Zero++[{'$zero',Type,Ref,Msg}]);
                _ ->
                    Relative = relative_time(Time,Opts),
                    S1 = cancel_timeout(Type,S),
                    Ref = erlang:start_timer(Relative,get('$self'),Type),
                    S2 = S1#statem_state{timers=maps:put(Type,{Ref,Msg},S1#statem_state.timers)},
                    apply_actions(P,S2,Event,Rest,StateCall,Postpone,Next,Zero)
            end;
        false -> {stop,{bad_action_from_state_function,{Type,Time,Msg,Opts}},S,[]}
    end.

cancel_automatic(S,Changed) ->
    S1 = cancel_timeout(timeout,S),
    case Changed of true -> cancel_timeout(state_timeout,S1); false -> S1 end.

cancel_timeout(Type,S) ->
    Timers = S#statem_state.timers,
    case maps:find(Type,Timers) of
        {ok,{Ref,_}} ->
            T1 = maps:remove(Type,Timers),
            case erlang:cancel_timer(Ref) of
                false -> S#statem_state{timers=maps:put(Ref,cancelled,T1)};
                _ -> S#statem_state{timers=T1}
            end;
        error -> S
    end.

update_timeout(Type,Msg,S) ->
    case maps:find(Type,S#statem_state.timers) of
        {ok,{Ref,_}} -> S#statem_state{timers=maps:put(Type,{Ref,Msg},S#statem_state.timers)};
        error -> S
    end.

timeout_type(timeout) -> true;
timeout_type(state_timeout) -> true;
timeout_type({timeout,_}) -> true;
timeout_type(_) -> false.

valid_time(update,[]) -> true;
valid_time(infinity,_Opts) -> true;
valid_time(Time,Opts) when is_integer(Time) ->
    case abs_option(Opts,false) of true -> true; false -> Time >= 0; error -> false end;
valid_time(_,_) -> false.

abs_option([],Abs) -> Abs;
abs_option([{abs,Bool}|Rest],_Abs) when is_boolean(Bool) -> abs_option(Rest,Bool);
abs_option(_,_) -> error.

relative_time(Time,Opts) ->
    case abs_option(Opts,false) of
        true -> max(0,Time-erlang:monotonic_time(millisecond));
        false -> Time
    end.

set_callback_mode(#params{modules=[Module|_]}=P) ->
    try Module:callback_mode() of
        Mode -> parse_callback_mode(P,listify(Mode),undefined,false,Mode)
    catch
        throw:Mode -> parse_callback_mode(P,listify(Mode),undefined,false,Mode);
        _Class:Reason -> {error,Reason}
    end.

parse_callback_mode(P,[state_functions|Rest],_Mode,Enter,Raw) ->
    parse_callback_mode(P,Rest,state_functions,Enter,Raw);
parse_callback_mode(P,[handle_event_function|Rest],_Mode,Enter,Raw) ->
    parse_callback_mode(P,Rest,handle_event_function,Enter,Raw);
parse_callback_mode(P,[state_enter|Rest],Mode,_Enter,Raw) ->
    parse_callback_mode(P,Rest,Mode,true,Raw);
parse_callback_mode(P,[],undefined,_Enter,Raw) -> {error,{bad_return_from_callback_mode,Raw}};
parse_callback_mode(P,[],Mode,Enter,_Raw) -> {ok,P#params{callback_mode=Mode,state_enter=Enter}};
parse_callback_mode(_P,_Rest,_Mode,_Enter,Raw) -> {error,{bad_return_from_callback_mode,Raw}}.

stop_with_replies(P,S,Reason,Replies) ->
    replies(Replies), terminate(P,S,exit,Reason).

terminate(P,S,Class,Reason) ->
    terminate_callback(P,S,Reason),
    gen:unregister_name(P#params.name),
    raise_class(Class,Reason).

terminate_callback(#params{modules=[Module|_]},S,Reason) ->
    try Module:terminate(Reason,S#statem_state.state,S#statem_state.data) of _ -> ok
    catch error:undef -> ok; Class:Why -> raise_class(Class,Why)
    end.

raise_class(throw,Reason) -> throw(Reason);
raise_class(error,Reason) -> erlang:error(Reason);
raise_class(exit,Reason) -> exit(Reason);
raise_class(_,Reason) -> erlang:error(Reason).

system_continue(Parent,_Debug,{P,S}) -> loop(P#params{parent=Parent},S,[]).
system_terminate(Reason,Parent,_Debug,{P,S}) -> terminate(P#params{parent=Parent},S,exit,Reason).
system_code_change({P,S},_Module,OldVsn,Extra) ->
    [Module|_] = P#params.modules,
    try Module:code_change(OldVsn,S#statem_state.state,S#statem_state.data,Extra) of
        {ok,State,Data} -> {ok,{P,S#statem_state{state=State,data=Data}}};
        Other -> Other
    catch error:undef -> {ok,{P,S}}; throw:Other -> Other
    end.
system_get_state({_P,S}) -> {ok,{S#statem_state.state,S#statem_state.data}}.
system_replace_state(Fun,{P,S}) ->
    {State,Data}=Fun({S#statem_state.state,S#statem_state.data}),
    {ok,{State,Data},{P,S#statem_state{state=State,data=Data}}}.
format_status(_Opt,{_P,S}) -> #{state=>S#statem_state.state,data=>S#statem_state.data,
                                postponed=>S#statem_state.postponed,timeouts=>maps:to_list(S#statem_state.timers)};
format_status(_Opt,Status) -> Status.
format_log(Report) -> Report.
format_log(Report,_Config) -> Report.

cast_target({local,Name}) -> Name;
cast_target(Server) -> Server.
call_timeout({dirty_timeout,T}) -> T;
call_timeout({clean_timeout,T}) -> T;
call_timeout(T) -> T.
listify(List) when is_list(List) -> List;
listify(Item) -> [Item].
