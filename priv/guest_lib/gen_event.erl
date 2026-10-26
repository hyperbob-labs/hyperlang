%% SPDX-License-Identifier: Apache-2.0
%% Copyright Ericsson AB 1996-2026. All Rights Reserved.
%% Modifications copyright The Hyperlang Authors.
%%
%% Hyperlang guest port of OTP stdlib-8.0.1 gen_event.erl.
%% Vendored reference: vendor/otp_stdlib_8_0_1/src/gen_event.erl

-module(gen_event).

-export([start/0,start/1,start/2,start_link/0,start_link/1,start_link/2,
         start_monitor/0,start_monitor/1,start_monitor/2,stop/1,stop/3,
         notify/2,sync_notify/2,add_handler/3,add_sup_handler/3,
         delete_handler/3,swap_handler/3,swap_sup_handler/3,
         which_handlers/1,call/3,call/4,send_request/3,send_request/5,
         wait_response/2,receive_response/2,check_response/2,
         wait_response/3,receive_response/3,check_response/3,
         reqids_new/0,reqids_size/1,reqids_add/3,reqids_to_list/1,wake_hib/5]).
-export([init_it/6,system_continue/3,system_terminate/4,system_code_change/4,
         system_get_state/1,system_replace_state/2,format_status/2,
         format_log/1,format_log/2]).

-record(handler,{module,id=false,state,supervised=false}).

start() -> gen:start(gen_event,nolink,'no callback module',[],[]).
start(Options) when is_list(Options) -> gen:start(gen_event,nolink,'no callback module',[],Options);
start(Name) when is_tuple(Name) -> gen:start(gen_event,nolink,Name,'no callback module',[],[]);
start(Arg) -> erlang:error(badarg,[Arg]).
start(Name,Options) when is_tuple(Name),is_list(Options) ->
    gen:start(gen_event,nolink,Name,'no callback module',[],Options);
start(Name,Options) -> erlang:error(badarg,[Name,Options]).

start_link() -> gen:start(gen_event,link,'no callback module',[],[]).
start_link(Options) when is_list(Options) -> gen:start(gen_event,link,'no callback module',[],Options);
start_link(Name) when is_tuple(Name) -> gen:start(gen_event,link,Name,'no callback module',[],[]);
start_link(Arg) -> erlang:error(badarg,[Arg]).
start_link(Name,Options) when is_tuple(Name),is_list(Options) ->
    gen:start(gen_event,link,Name,'no callback module',[],Options);
start_link(Name,Options) -> erlang:error(badarg,[Name,Options]).

start_monitor() -> gen:start(gen_event,monitor,'no callback module',[],[]).
start_monitor(Options) when is_list(Options) -> gen:start(gen_event,monitor,'no callback module',[],Options);
start_monitor(Name) when is_tuple(Name) -> gen:start(gen_event,monitor,Name,'no callback module',[],[]);
start_monitor(Arg) -> erlang:error(badarg,[Arg]).
start_monitor(Name,Options) when is_tuple(Name),is_list(Options) ->
    gen:start(gen_event,monitor,Name,'no callback module',[],Options);
start_monitor(Name,Options) -> erlang:error(badarg,[Name,Options]).

stop(Mgr) -> gen:stop(Mgr).
stop(Mgr,Reason,Timeout) -> gen:stop(Mgr,Reason,Timeout).
notify(Mgr,Event) -> send(Mgr,{notify,Event}).
sync_notify(Mgr,Event) -> rpc(Mgr,{sync_notify,Event}).
add_handler(Mgr,Handler,Args) -> rpc(Mgr,{add_handler,Handler,Args}).
add_sup_handler(Mgr,Handler,Args) ->
    rpc(Mgr,{add_sup_handler,Handler,Args,get('$self')}).
delete_handler(Mgr,Handler,Args) -> rpc(Mgr,{delete_handler,Handler,Args}).
swap_handler(Mgr,{Handler1,Args1},{Handler2,Args2}) ->
    rpc(Mgr,{swap_handler,Handler1,Args1,Handler2,Args2}).
swap_sup_handler(Mgr,{Handler1,Args1},{Handler2,Args2}) ->
    rpc(Mgr,{swap_sup_handler,Handler1,Args1,Handler2,Args2,get('$self')}).
which_handlers(Mgr) -> rpc(Mgr,which_handlers).

call(Mgr,Handler,Query) -> call1(Mgr,Handler,Query,5000,[Mgr,Handler,Query]).
call(Mgr,Handler,Query,Timeout) -> call1(Mgr,Handler,Query,Timeout,[Mgr,Handler,Query,Timeout]).
call1(Mgr,Handler,Query,Timeout,Args) ->
    try gen:call(Mgr,get('$self'),{call,Handler,Query},Timeout) of
        {ok,Reply} -> Reply
    catch exit:Reason -> exit({Reason,{gen_event,call,Args}})
    end.

send_request(Mgr,Handler,Request) ->
    gen:send_request(Mgr,get('$self'),{call,Handler,Request}).
send_request(Mgr,Handler,Request,Label,ReqIds) ->
    gen:send_request(Mgr,get('$self'),{call,Handler,Request},Label,ReqIds).
wait_response(ReqId,Timeout) -> gen:wait_response(ReqId,Timeout).
receive_response(ReqId,Timeout) -> gen:receive_response(ReqId,Timeout).
check_response(Msg,ReqId) -> gen:check_response(Msg,ReqId).
wait_response(ReqIds,Timeout,Delete) -> gen:wait_response(ReqIds,Timeout,Delete).
receive_response(ReqIds,Timeout,Delete) -> gen:receive_response(ReqIds,Timeout,Delete).
check_response(Msg,ReqIds,Delete) -> gen:check_response(Msg,ReqIds,Delete).
reqids_new() -> gen:reqids_new().
reqids_size(ReqIds) -> gen:reqids_size(ReqIds).
reqids_add(ReqId,Label,ReqIds) -> gen:reqids_add(ReqId,Label,ReqIds).
reqids_to_list(ReqIds) -> gen:reqids_to_list(ReqIds).

rpc(Mgr,Command) ->
    {ok,Reply}=gen:call(Mgr,get('$self'),Command,infinity),
    Reply.

send({local,Name},Command) -> Name ! Command, ok;
send({global,_Name},_Command) -> ok;
send({via,_Module,_Name},_Command) -> ok;
send(Mgr,Command) -> Mgr ! Command, ok.

init_it(Starter,Parent,Name0,_Module,_Args,Options) ->
    process_flag(trap_exit,true),
    Name=gen:name(Name0),
    HibernateAfter=gen:hibernate_after(Options),
    proc_lib:init_ack(Starter,{ok,get('$self')}),
    loop(Parent,Name,[],HibernateAfter,[],false).

loop(Parent,Name,Handlers,HibernateAfter,Debug,_Hibernate) ->
    receive
        Msg -> decode_msg(Msg,Parent,Name,Handlers,HibernateAfter,Debug)
    after HibernateAfter ->
        loop(Parent,Name,Handlers,HibernateAfter,Debug,false)
    end.

wake_hib(Parent,Name,Handlers,HibernateAfter,Debug) ->
    loop(Parent,Name,Handlers,HibernateAfter,Debug,false).

decode_msg({system,From,Request},Parent,Name,Handlers,HibernateAfter,Debug) ->
    otp_sys:handle_system_msg(Request,From,Parent,gen_event,Debug,
                          [Name,Handlers,HibernateAfter,false],false);
decode_msg({'EXIT',Parent,Reason},Parent,Name,Handlers,_HibernateAfter,_Debug) ->
    terminate_server(Reason,Parent,Handlers,Name);
decode_msg({'EXIT',From,Reason},Parent,Name,Handlers,HibernateAfter,Debug) ->
    Handlers1=handle_exit(From,Reason,Handlers,Name),
    loop(Parent,Name,Handlers1,HibernateAfter,Debug,false);
decode_msg({'$gen_stop',From,Reason},Parent,Name,Handlers,_HibernateAfter,_Debug) ->
    stop_handlers(Handlers,Name), do_unlink(Parent,Handlers),
    gen:unregister_name(Name), gen:reply(From,ok), exit(Reason);
decode_msg(Msg,Parent,Name,Handlers,HibernateAfter,Debug) ->
    handle_msg(Msg,Parent,Name,Handlers,HibernateAfter,Debug).

handle_msg({notify,Event},Parent,Name,Handlers,HibernateAfter,Debug) ->
    {_Hib,Handlers1}=server_notify(Event,handle_event,Handlers,Name),
    loop(Parent,Name,Handlers1,HibernateAfter,Debug,false);
handle_msg({_Caller,From,{sync_notify,Event}},Parent,Name,Handlers,HibernateAfter,Debug) ->
    {_Hib,Handlers1}=server_notify(Event,handle_event,Handlers,Name),
    gen:reply(From,ok), loop(Parent,Name,Handlers1,HibernateAfter,Debug,false);
handle_msg({_Caller,From,{call,Handler,Query}},Parent,Name,Handlers,HibernateAfter,Debug) ->
    {_Hib,Reply,Handlers1}=server_call(Handler,Query,Handlers,Name),
    gen:reply(From,Reply), loop(Parent,Name,Handlers1,HibernateAfter,Debug,false);
handle_msg({_Caller,From,{add_handler,Handler,Args}},Parent,Name,Handlers,HibernateAfter,Debug) ->
    {_Hib,Reply,Handlers1}=server_add_handler(Handler,Args,Handlers),
    gen:reply(From,Reply), loop(Parent,Name,Handlers1,HibernateAfter,Debug,false);
handle_msg({_Caller,From,{add_sup_handler,Handler,Args,Sup}},Parent,Name,Handlers,HibernateAfter,Debug) ->
    {_Hib,Reply,Handlers1}=server_add_sup_handler(Handler,Args,Handlers,Sup),
    gen:reply(From,Reply), loop(Parent,Name,Handlers1,HibernateAfter,Debug,false);
handle_msg({_Caller,From,{delete_handler,Handler,Args}},Parent,Name,Handlers,HibernateAfter,Debug) ->
    {Reply,Handlers1}=server_delete_handler(Handler,Args,Handlers,Name),
    gen:reply(From,Reply), loop(Parent,Name,Handlers1,HibernateAfter,Debug,false);
handle_msg({_Caller,From,{swap_handler,H1,A1,H2,A2}},Parent,Name,Handlers,HibernateAfter,Debug) ->
    {_Hib,Reply,Handlers1}=server_swap_handler(H1,A1,H2,A2,Handlers,Name),
    gen:reply(From,Reply), loop(Parent,Name,Handlers1,HibernateAfter,Debug,false);
handle_msg({_Caller,From,{swap_sup_handler,H1,A1,H2,A2,Sup}},Parent,Name,Handlers,HibernateAfter,Debug) ->
    {_Hib,Reply,Handlers1}=server_swap_handler(H1,A1,H2,A2,Handlers,Sup,Name),
    gen:reply(From,Reply), loop(Parent,Name,Handlers1,HibernateAfter,Debug,false);
handle_msg({_Caller,From,which_handlers},Parent,Name,Handlers,HibernateAfter,Debug) ->
    gen:reply(From,the_handlers(Handlers)),
    loop(Parent,Name,Handlers,HibernateAfter,Debug,false);
handle_msg({_Caller,From,get_modules},Parent,Name,Handlers,HibernateAfter,Debug) ->
    gen:reply(From,get_modules(Handlers)),
    loop(Parent,Name,Handlers,HibernateAfter,Debug,false);
handle_msg({_Caller,From,stop},Parent,Name,Handlers,_HibernateAfter,_Debug) ->
    stop_handlers(Handlers,Name), do_unlink(Parent,Handlers), gen:reply(From,ok), exit(normal);
handle_msg(Other,Parent,Name,Handlers,HibernateAfter,Debug) ->
    {_Hib,Handlers1}=server_notify(Other,handle_info,Handlers,Name),
    loop(Parent,Name,Handlers1,HibernateAfter,Debug,false).

server_add_handler({Module,Id},Args,Handlers) ->
    server_add_handler(Module,#handler{module=Module,id=Id},Args,Handlers);
server_add_handler(Module,Args,Handlers) ->
    server_add_handler(Module,#handler{module=Module},Args,Handlers).
server_add_handler(Module,Handler,Args,Handlers) ->
    case caught_apply(Module,init,[Args]) of
        {ok,State} -> {false,ok,[Handler#handler{state=State}|Handlers]};
        {ok,State,hibernate} -> {true,ok,[Handler#handler{state=State}|Handlers]};
        Other -> {false,Other,Handlers}
    end.

server_add_sup_handler({Module,Id},Args,Handlers,Sup) ->
    link(Sup), server_add_handler(Module,#handler{module=Module,id=Id,supervised=Sup},Args,Handlers);
server_add_sup_handler(Module,Args,Handlers,Sup) ->
    link(Sup), server_add_handler(Module,#handler{module=Module,supervised=Sup},Args,Handlers).

server_delete_handler(Id,Args,Handlers,Name) ->
    case split(Id,Handlers) of
        {Module,Handler,Rest} ->
            {do_terminate(Module,Handler,Args,Handler#handler.state,delete,Name,normal),Rest};
        error -> {{error,module_not_found},Handlers}
    end.

server_swap_handler(H1,A1,H2,A2,Handlers,Name) ->
    {State2,Sup,Rest}=split_and_terminate(H1,A1,Handlers,Name,H2,false),
    case add_for_swap(Sup,H2,{A2,State2},Rest) of
        {Hib,ok,New} -> {Hib,ok,New};
        {Hib,What,New} -> {Hib,{error,What},New}
    end.
server_swap_handler(H1,A1,H2,A2,Handlers,Sup,Name) ->
    {State2,_OldSup,Rest}=split_and_terminate(H1,A1,Handlers,Name,H2,Sup),
    case add_for_swap(Sup,H2,{A2,State2},Rest) of
        {Hib,ok,New} -> {Hib,ok,New};
        {Hib,What,New} -> {Hib,{error,What},New}
    end.

add_for_swap(false,Handler,Args,Handlers) -> server_add_handler(Handler,Args,Handlers);
add_for_swap(Sup,Handler,Args,Handlers) -> server_add_sup_handler(Handler,Args,Handlers,Sup).

split_and_terminate(Id,Args,Handlers,Name,H2,Sup) ->
    case split(Id,Handlers) of
        {Module,Handler,Rest} ->
            OldSup=Handler#handler.supervised,
            NewSup=case Sup of false -> OldSup; _ -> Sup end,
            {do_terminate(Module,Handler,Args,Handler#handler.state,swapped,Name,
                          {swapped,H2,NewSup}),OldSup,Rest};
        error -> {error,false,Handlers}
    end.

server_notify(Event,Function,[Handler|Rest],Name) ->
    case server_update(Handler,Function,Event,Name) of
        {ok,Handler1} ->
            {Hib,NewRest}=server_notify(Event,Function,Rest,Name), {Hib,[Handler1|NewRest]};
        {hibernate,Handler1} ->
            {_Hib,NewRest}=server_notify(Event,Function,Rest,Name), {true,[Handler1|NewRest]};
        no -> server_notify(Event,Function,Rest,Name)
    end;
server_notify(_Event,_Function,[],_Name) -> {false,[]}.

server_update(Handler,Function,Event,Name) ->
    Module=Handler#handler.module, State=Handler#handler.state,
    case caught_apply(Module,Function,[Event,State]) of
        {ok,State1} -> {ok,Handler#handler{state=State1}};
        {ok,State1,hibernate} -> {hibernate,Handler#handler{state=State1}};
        {swap_handler,A1,State1,H2,A2} -> do_swap(Module,Handler,A1,State1,H2,A2,Name);
        remove_handler ->
            do_terminate(Module,Handler,remove_handler,State,remove,Name,normal), no;
        {'EXIT',undef} when Function =:= handle_info -> {ok,Handler};
        Other ->
            do_terminate(Module,Handler,{error,Other},State,Event,Name,crash), no
    end.

do_swap(Module,Handler,A1,State1,H2,A2,Name) ->
    State2=do_terminate(Module,Handler,A1,State1,swapped,Name,
                        {swapped,H2,Handler#handler.supervised}),
    {Module2,NewHandler}=new_handler(H2,Handler),
    case caught_apply(Module2,init,[{A2,State2}]) of
        {ok,NewState} -> {ok,NewHandler#handler{state=NewState}};
        _Other -> no
    end.

new_handler({Module,Id},Handler) ->
    {Module,#handler{module=Module,id=Id,supervised=Handler#handler.supervised}};
new_handler(Module,Handler) ->
    {Module,#handler{module=Module,supervised=Handler#handler.supervised}}.

server_call(Id,Query,Handlers,Name) ->
    case search(Id,Handlers) of
        {ok,Handler} ->
            case server_call_update(Handler,Query,Name) of
                {no,Reply} -> {false,Reply,delete(Id,Handlers)};
                {{ok,Handler1},Reply} -> {false,Reply,replace(Id,Handlers,Handler1)};
                {{hibernate,Handler1},Reply} -> {true,Reply,replace(Id,Handlers,Handler1)}
            end;
        false -> {false,{error,bad_module},Handlers}
    end.

server_call_update(Handler,Query,Name) ->
    Module=Handler#handler.module, State=Handler#handler.state,
    case caught_apply(Module,handle_call,[Query,State]) of
        {ok,Reply,State1} -> {{ok,Handler#handler{state=State1}},Reply};
        {ok,Reply,State1,hibernate} -> {{hibernate,Handler#handler{state=State1}},Reply};
        {swap_handler,Reply,A1,State1,H2,A2} ->
            {do_swap(Module,Handler,A1,State1,H2,A2,Name),Reply};
        {remove_handler,Reply} ->
            do_terminate(Module,Handler,remove_handler,State,remove,Name,normal), {no,Reply};
        Other ->
            do_terminate(Module,Handler,{error,Other},State,Query,Name,crash),
            {no,{error,Other}}
    end.

caught_apply(Module,Function,Args) ->
    try apply(Module,Function,Args) of Result -> Result
    catch
        throw:Result -> Result;
        exit:Reason -> {'EXIT',Reason};
        error:Reason -> {'EXIT',Reason}
    end.

do_terminate(Module,Handler,Args,State,Last,Name,How) ->
    Result = case caught_apply(Module,terminate,[Args,State]) of
        {'EXIT',undef} -> ok;
        Value -> Value
    end,
    report_terminate(Handler,How,Args,State,Last,Name,Result),
    Result.

report_terminate(Handler,crash,{error,Reason},_State,_Last,_Name,_Result) ->
    notify_supervisor(Handler,Reason);
report_terminate(Handler,How,_Args,_State,_Last,_Name,_Result) ->
    notify_supervisor(Handler,How).

notify_supervisor(#handler{supervised=false},_Reason) -> ok;
notify_supervisor(Handler,Reason) ->
    Handler#handler.supervised ! {gen_event_EXIT,handler(Handler),Reason}, ok.

handle_exit(Pid,Reason,Handlers,Name) ->
    Remaining=terminate_supervised(Pid,Reason,Handlers,Name),
    {_Hib,Notified}=server_notify({'EXIT',Pid,Reason},handle_info,Remaining,Name),
    Notified.

terminate_supervised(Pid,Reason,[Handler|Rest],Name) ->
    case Handler#handler.supervised of
        Pid ->
            do_terminate(Handler#handler.module,Handler,{stop,Reason},Handler#handler.state,
                         {parent_terminated,{Pid,Reason}},Name,shutdown),
            terminate_supervised(Pid,Reason,Rest,Name);
        _ -> [Handler|terminate_supervised(Pid,Reason,Rest,Name)]
    end;
terminate_supervised(_Pid,_Reason,[],_Name) -> [].

terminate_server(Reason,Parent,Handlers,Name) ->
    stop_handlers(Handlers,Name), do_unlink(Parent,Handlers),
    gen:unregister_name(Name), exit(Reason).

stop_handlers([Handler|Rest],Name) ->
    do_terminate(Handler#handler.module,Handler,stop,Handler#handler.state,stop,Name,shutdown),
    stop_handlers(Rest,Name);
stop_handlers([],_Name) -> [].

do_unlink(Parent,[Handler|Rest]) ->
    case Handler#handler.supervised of
        false -> ok;
        Parent -> ok;
        Sup -> unlink(Sup)
    end,
    do_unlink(Parent,Rest);
do_unlink(_Parent,[]) -> ok.

handler(#handler{id=false,module=Module}) -> Module;
handler(#handler{id=Id,module=Module}) -> {Module,Id}.
the_handlers(Handlers) -> [handler(H) || H <- Handlers].
get_modules(Handlers) -> ordsets:to_list(ordsets:from_list([H#handler.module || H <- Handlers])).

split(Id,Handlers) -> split(Id,Handlers,[]).
split({Module,Id},[H|Rest],Acc) when H#handler.module=:=Module,H#handler.id=:=Id ->
    {Module,H,lists:reverse(Acc,Rest)};
split(Module,[H|Rest],Acc) when H#handler.module=:=Module,H#handler.id=:=false ->
    {Module,H,lists:reverse(Acc,Rest)};
split(Id,[H|Rest],Acc) -> split(Id,Rest,[H|Acc]);
split(_Id,[],_Acc) -> error.

search({Module,Id},[H|_]) when H#handler.module=:=Module,H#handler.id=:=Id -> {ok,H};
search(Module,[H|_]) when H#handler.module=:=Module,H#handler.id=:=false -> {ok,H};
search(Id,[_|Rest]) -> search(Id,Rest);
search(_Id,[]) -> false.

delete({Module,Id},[H|Rest]) when H#handler.module=:=Module,H#handler.id=:=Id -> Rest;
delete(Module,[H|Rest]) when H#handler.module=:=Module,H#handler.id=:=false -> Rest;
delete(Id,[H|Rest]) -> [H|delete(Id,Rest)];
delete(_Id,[]) -> [].

replace({Module,Id},[H|Rest],New) when H#handler.module=:=Module,H#handler.id=:=Id -> [New|Rest];
replace(Module,[H|Rest],New) when H#handler.module=:=Module,H#handler.id=:=false -> [New|Rest];
replace(Id,[H|Rest],New) -> [H|replace(Id,Rest,New)];
replace(_Id,[],New) -> [New].

system_continue(Parent,Debug,[Name,Handlers,HibernateAfter,Hibernate]) ->
    loop(Parent,Name,Handlers,HibernateAfter,Debug,Hibernate).
system_terminate(Reason,Parent,_Debug,[Name,Handlers,_HibernateAfter,_Hibernate]) ->
    terminate_server(Reason,Parent,Handlers,Name).
system_code_change([Name,Handlers,HibernateAfter,Hibernate],Module,OldVsn,Extra) ->
    Handlers1=code_change_handlers(Handlers,Module,OldVsn,Extra),
    {ok,[Name,Handlers1,HibernateAfter,Hibernate]}.
code_change_handlers([H|Rest],Module,OldVsn,Extra) when H#handler.module=:=Module ->
    case caught_apply(Module,code_change,[OldVsn,H#handler.state,Extra]) of
        {ok,State} -> [H#handler{state=State}|code_change_handlers(Rest,Module,OldVsn,Extra)];
        _ -> [H|code_change_handlers(Rest,Module,OldVsn,Extra)]
    end;
code_change_handlers([H|Rest],Module,OldVsn,Extra) ->
    [H|code_change_handlers(Rest,Module,OldVsn,Extra)];
code_change_handlers([],_Module,_OldVsn,_Extra) -> [].
system_get_state([_Name,Handlers,_HibernateAfter,_Hibernate]) ->
    {ok,[{H#handler.module,H#handler.id,H#handler.state} || H <- Handlers]}.
system_replace_state(Fun,[Name,Handlers,HibernateAfter,Hibernate]) ->
    {Handlers1,States}=replace_states(Fun,Handlers,[],[]),
    {ok,lists:reverse(States),[Name,lists:reverse(Handlers1),HibernateAfter,Hibernate]}.
replace_states(Fun,[H|Rest],Handlers,States) ->
    Current={H#handler.module,H#handler.id,H#handler.state},
    try Fun(Current) of
        {Module,Id,State}=New ->
            replace_states(Fun,Rest,[H#handler{module=Module,id=Id,state=State}|Handlers],[New|States])
    catch _:_ -> replace_states(Fun,Rest,[H|Handlers],[Current|States])
    end;
replace_states(_Fun,[],Handlers,States) -> {Handlers,States}.
format_status(_Opt,[_PDict,_SysState,_Parent,_Debug,[Name,Handlers,_After,_Hib]]) ->
    {Name,[{handler(H),H#handler.state} || H <- Handlers]};
format_status(_Opt,Status) -> Status.
format_log(Report) -> Report.
format_log(Report,_Config) -> Report.
