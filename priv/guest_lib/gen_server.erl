%% SPDX-License-Identifier: Apache-2.0
%% Copyright Ericsson AB 1996-2026. All Rights Reserved.
%% Modifications copyright The Hyperlang Authors.
%%
%% Hyperlang guest port of OTP stdlib-8.0.1 gen_server.erl.
%% Vendored reference: vendor/otp_stdlib_8_0_1/src/gen_server.erl
%%
%% This is executable guest code injected into compile_from_filesystem snapshots
%% when capabilities.gen_server=true and modules.enabled=true. Callback-module
%% calls such as Mod:init/1 and Mod:handle_call/3 are true dynamic snapshot
%% dispatches over the manifest guest_modules set.

-module(gen_server).

-export([start/3, start/4,
         start_link/3, start_link/4,
         start_monitor/3, start_monitor/4,
         stop/1, stop/3,
         call/2, call/3,
         send_request/2, send_request/4,
         wait_response/2, receive_response/2, check_response/2,
         wait_response/3, receive_response/3, check_response/3,
         reqids_new/0, reqids_size/1,
         reqids_add/3, reqids_to_list/1,
         cast/2, reply/2,
         abcast/2, abcast/3,
         multi_call/2, multi_call/3, multi_call/4,
         enter_loop/3, enter_loop/4, enter_loop/5]).

-export([system_continue/3,
         system_terminate/4,
         system_code_change/4,
         system_get_state/1,
         system_replace_state/2,
         format_status/2]).

-export([format_log/1, format_log/2]).
-export([init_it/6]).

start(Module, Args, Options) when is_atom(Module), is_list(Options) ->
    gen:start(gen_server, nolink, Module, Args, Options);
start(Module, Args, Options) ->
    erlang:error(badarg, [Module, Args, Options]).

start(ServerName, Module, Args, Options)
  when is_tuple(ServerName), is_atom(Module), is_list(Options) ->
    gen:start(gen_server, nolink, ServerName, Module, Args, Options);
start(ServerName, Module, Args, Options) ->
    erlang:error(badarg, [ServerName, Module, Args, Options]).

start_link(Module, Args, Options) when is_atom(Module), is_list(Options) ->
    gen:start(gen_server, link, Module, Args, Options);
start_link(Module, Args, Options) ->
    erlang:error(badarg, [Module, Args, Options]).

start_link(ServerName, Module, Args, Options)
  when is_tuple(ServerName), is_atom(Module), is_list(Options) ->
    gen:start(gen_server, link, ServerName, Module, Args, Options);
start_link(ServerName, Module, Args, Options) ->
    erlang:error(badarg, [ServerName, Module, Args, Options]).

start_monitor(Module, Args, Options) when is_atom(Module), is_list(Options) ->
    gen:start(gen_server, monitor, Module, Args, Options);
start_monitor(Module, Args, Options) ->
    erlang:error(badarg, [Module, Args, Options]).

start_monitor(ServerName, Module, Args, Options)
  when is_tuple(ServerName), is_atom(Module), is_list(Options) ->
    gen:start(gen_server, monitor, ServerName, Module, Args, Options);
start_monitor(ServerName, Module, Args, Options) ->
    erlang:error(badarg, [ServerName, Module, Args, Options]).

stop(ServerRef) ->
    gen:stop(ServerRef).

stop(ServerRef, Reason, Timeout) ->
    gen:stop(ServerRef, Reason, Timeout).

call(ServerRef, Request) ->
    call(ServerRef, Request, 5000).

call(ServerRef, Request, Timeout) ->
    try gen:call(ServerRef, '$gen_call', Request, Timeout) of
        {ok, Reply} ->
            Reply
    catch
        exit:Reason ->
            exit({Reason, {gen_server, call, [ServerRef, Request, Timeout]}})
    end.

cast(ServerRef, Request) ->
    Target = cast_target(ServerRef),
    Target ! {'$gen_cast', Request},
    ok.

reply({To, Tag}, Reply) ->
    To ! {Tag, Reply},
    ok;
reply(To, Reply) ->
    To ! {To, Reply},
    ok.

send_request(ServerRef, Request) ->
    gen:send_request(ServerRef, '$gen_call', Request).

send_request(ServerRef, Request, Label, ReqIdCol) ->
    gen:send_request(ServerRef, '$gen_call', Request, Label, ReqIdCol).

wait_response(ReqId, Timeout) -> gen:wait_response(ReqId, Timeout).
receive_response(ReqId, Timeout) -> gen:receive_response(ReqId, Timeout).
check_response(Msg, ReqId) -> gen:check_response(Msg, ReqId).
wait_response(ReqIdCol, Timeout, Delete) -> gen:wait_response(ReqIdCol, Timeout, Delete).
receive_response(ReqIdCol, Timeout, Delete) -> gen:receive_response(ReqIdCol, Timeout, Delete).
check_response(Msg, ReqIdCol, Delete) -> gen:check_response(Msg, ReqIdCol, Delete).
reqids_new() -> gen:reqids_new().
reqids_size(ReqIds) -> gen:reqids_size(ReqIds).
reqids_add(ReqId, Label, ReqIds) -> gen:reqids_add(ReqId, Label, ReqIds).
reqids_to_list(ReqIds) -> gen:reqids_to_list(ReqIds).

abcast(Request, Name) ->
    cast(Name, Request).

abcast(_Nodes, Name, Request) ->
    abcast(Request, Name).

multi_call(Name, Request) ->
    multi_call([node], Name, Request, infinity).

multi_call(Name, Request, Timeout) ->
    multi_call([node], Name, Request, Timeout).

multi_call(_Nodes, Name, Request, Timeout) ->
    try {Replies, Bad} = {[{node, call(Name, Request, Timeout)}], []}, {Replies, Bad}
    catch exit:_ -> {[], [node]}
    end.

enter_loop(_Module, _Options, _State) ->
    erlang:error({unsupported, enter_loop}).

enter_loop(_Module, _Options, _State, _ServerName) ->
    erlang:error({unsupported, enter_loop}).

enter_loop(_Module, _Options, _State, _ServerName, _Action) ->
    erlang:error({unsupported, enter_loop}).

init_it(Starter, Parent, Name, Mod, Args, Options) ->
    Debug = gen:debug_options(Name, Options),
    ServerData = {server_data, Parent, Name, Mod, Debug},
    try Mod:init(Args) of
        Result ->
            handle_init_result(Result, Starter, Name, ServerData)
    catch
        exit:Reason ->
            gen:unregister_name(Name),
            proc_lib:init_ack(Starter, {error, Reason}),
            exit(Reason);
        error:Reason ->
            gen:unregister_name(Name),
            proc_lib:init_ack(Starter, {error, Reason}),
            erlang:error(Reason)
    end.

handle_init_result(Result, Starter, Name, ServerData) ->
    case Result of
        {ok, State} ->
            proc_lib:init_ack(Starter, {ok, get('$self')}),
            loop(ServerData, State, infinity);
        {ok, State, Action} ->
            proc_lib:init_ack(Starter, {ok, get('$self')}),
            loop(ServerData, State, Action);
        {stop, Reason} ->
            gen:unregister_name(Name),
            proc_lib:init_ack(Starter, {error, Reason}),
            exit(Reason);
        ignore ->
            gen:unregister_name(Name),
            proc_lib:init_ack(Starter, ignore),
            ok;
        Else ->
            gen:unregister_name(Name),
            proc_lib:init_ack(Starter, {error, {bad_return_value, Else}}),
            erlang:error({bad_return_value, Else})
    end.

system_continue(_Parent, _Debug, {ServerData, State}) ->
    loop(ServerData, State, infinity).

system_terminate(Reason, _Parent, _Debug, {ServerData, State}) ->
    terminate_server(ServerData, Reason, State),
    exit(Reason).

system_code_change({ServerData, State}, _Module, OldVsn, Extra) ->
    Mod = data_mod(ServerData),
    case try_code_change(Mod, OldVsn, State, Extra) of
        {ok, NewState} -> {ok, {ServerData, NewState}};
        Other -> Other
    end.

system_get_state({_ServerData, State}) ->
    {ok, State};
system_get_state(State) ->
    {ok, State}.

system_replace_state(StateFun, {ServerData, State}) ->
    NewState = StateFun(State),
    {ok, NewState, {ServerData, NewState}};
system_replace_state(StateFun, State) ->
    NewState = StateFun(State),
    {ok, NewState, NewState}.

format_status(_Opt, {ServerData, State} = Status) ->
    Mod = data_mod(ServerData),
    try_format_status(Mod, Status, State);
format_status(_Opt, Status) ->
    Status.

format_log(Report) -> Report.
format_log(Report, _Config) -> Report.

loop(ServerData, State, Action) ->
    case normalize_action(Action) of
        {continue, Continue} ->
            handle_msg_continue(ServerData, Continue, State);
        {timeout, 0, Message, true} ->
            dispatch(Message, ServerData, State);
        {timeout, Timeout, Message, _Immediate} ->
            receive_loop(ServerData, State, Timeout, Message);
        infinity ->
            receive_loop(ServerData, State, infinity, timeout);
        hibernate ->
            receive_loop(ServerData, State, infinity, timeout);
        {bad_action, Bad} ->
            erlang:error({bad_return_value, Bad})
    end.

receive_loop(ServerData, State, infinity, _TimeoutMessage) ->
    receive
        Msg -> dispatch(Msg, ServerData, State)
    end;
receive_loop(ServerData, State, Timeout, TimeoutMessage) ->
    case get('$self') of
        Self when is_integer(Self) ->
            TRef = erlang:start_timer(Timeout, Self, TimeoutMessage),
            receive
                {timeout, TRef, TimeoutMessage} ->
                    dispatch(TimeoutMessage, ServerData, State);
                Msg ->
                    cancel_timer_flush(TRef),
                    dispatch(Msg, ServerData, State)
            end;
        _ ->
            receive
                Msg -> dispatch(Msg, ServerData, State)
            after Timeout ->
                dispatch(TimeoutMessage, ServerData, State)
            end
    end.

dispatch({'$gen_call', From, Request}, ServerData, State) ->
    handle_call(ServerData, Request, From, State);
dispatch({'$gen_cast', Request}, ServerData, State) ->
    handle_cast(ServerData, Request, State);
dispatch({'$gen_stop', From, Reason}, ServerData, State) ->
    terminate_server(ServerData, Reason, State),
    reply(From, ok),
    exit(Reason);
dispatch({system, From, Msg}, ServerData, State) ->
    otp_sys:handle_system_msg(Msg, From, data_parent(ServerData), gen_server,
                          data_debug(ServerData), {ServerData, State});
dispatch(Info, ServerData, State) ->
    Mod = data_mod(ServerData),
    Result =
        try Mod:handle_info(Info, State)
        catch
            error:undef -> {noreply, State}
        end,
    handle_noreply_result(ServerData, Result).

handle_call(ServerData, Request, From, State) ->
    Mod = data_mod(ServerData),
    case Mod:handle_call(Request, From, State) of
        {reply, Reply, NewState} ->
            reply(From, Reply),
            loop(ServerData, NewState, infinity);
        {reply, Reply, NewState, Action} ->
            reply(From, Reply),
            loop(ServerData, NewState, Action);
        {noreply, NewState} ->
            loop(ServerData, NewState, infinity);
        {noreply, NewState, Action} ->
            loop(ServerData, NewState, Action);
        {stop, Reason, Reply, NewState} ->
            terminate_server(ServerData, Reason, NewState),
            reply(From, Reply),
            exit(Reason);
        {stop, Reason, NewState} ->
            terminate_server(ServerData, Reason, NewState),
            exit(Reason);
        Else ->
            erlang:error({bad_return_value, Else})
    end.

handle_cast(ServerData, Request, State) ->
    Mod = data_mod(ServerData),
    handle_noreply_result(ServerData, Mod:handle_cast(Request, State)).

handle_msg_continue(ServerData, Continue, State) ->
    Mod = data_mod(ServerData),
    handle_noreply_result(ServerData, Mod:handle_continue(Continue, State)).

handle_noreply_result(ServerData, Result) ->
    case Result of
        {noreply, NewState} ->
            loop(ServerData, NewState, infinity);
        {noreply, NewState, Action} ->
            loop(ServerData, NewState, Action);
        {stop, Reason, NewState} ->
            terminate_server(ServerData, Reason, NewState),
            exit(Reason);
        Else ->
            erlang:error({bad_return_value, Else})
    end.

terminate_server(ServerData, Reason, State) ->
    Mod = data_mod(ServerData),
    try Mod:terminate(Reason, State) of
        _ -> ok
    catch
        error:undef -> ok;
        _:_ -> ok
    end,
    gen:unregister_name(data_name(ServerData)),
    ok.

try_code_change(Mod, OldVsn, State, Extra) ->
    try Mod:code_change(OldVsn, State, Extra)
    catch
        error:undef -> {ok, State}
    end.

try_format_status(Mod, Status, _State) ->
    try Mod:format_status(Status)
    catch
        error:undef -> Status
    end.

normalize_action(Action) when is_integer(Action), Action >= 0 ->
    {timeout, Action, timeout, false};
normalize_action(infinity) ->
    infinity;
normalize_action(hibernate) ->
    hibernate;
normalize_action({continue, Continue}) ->
    {continue, Continue};
normalize_action({timeout, Timeout, Message}) ->
    {timeout, Timeout, Message, true};
normalize_action({hibernate, Timeout, Message}) ->
    {timeout, Timeout, Message, true};
normalize_action({timeout, Timeout, Message, _Options}) ->
    {timeout, Timeout, Message, true};
normalize_action({hibernate, Timeout, Message, _Options}) ->
    {timeout, Timeout, Message, true};
normalize_action(Action) ->
    {bad_action, Action}.

cast_target({local, Name}) -> Name;
cast_target(ServerRef) -> ServerRef.

data_parent({server_data, Parent, _Name, _Mod, _Debug}) -> Parent.
data_name({server_data, _Parent, Name, _Mod, _Debug}) -> Name.
data_mod({server_data, _Parent, _Name, Mod, _Debug}) -> Mod.
data_debug({server_data, _Parent, _Name, _Mod, Debug}) -> Debug.

cancel_timer_flush(TRef) ->
    case erlang:cancel_timer(TRef) of
        false -> receive {timeout, TRef, _Msg} -> ok after 0 -> ok end;
        _Remaining -> ok
    end.
