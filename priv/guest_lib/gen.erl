%% SPDX-License-Identifier: Apache-2.0
%% Copyright Ericsson AB 1996-2025. All Rights Reserved.
%% Modifications copyright The Hyperlang Authors.
%%
%% Hyperlang guest port of OTP stdlib-8.0.1 gen.erl.
%% Vendored reference: vendor/otp_stdlib_8_0_1/src/gen.erl

-module(gen).

-export([start/5, start/6, debug_options/2, hibernate_after/1,
         name/1, unregister_name/1, get_proc_name/1, get_parent/0,
         call/3, call/4, reply/2,
         send_request/3, send_request/5,
         wait_response/2, receive_response/2, check_response/2,
         wait_response/3, receive_response/3, check_response/3,
         reqids_new/0, reqids_size/1,
         reqids_add/3, reqids_to_list/1,
         stop/1, stop/3]).

-export([init_it/6, init_it/7]).
-export([format_status_header/2, format_status/4]).
-export(['@wait_response_recv_opt'/3]).

start(GenMod, LinkP, Mod, Args, Options) ->
    do_spawn(GenMod, LinkP, Mod, Args, Options).

start(GenMod, LinkP, Name, Mod, Args, Options) ->
    case where(Name) of
        undefined ->
            do_spawn(GenMod, LinkP, Name, Mod, Args, Options);
        Pid ->
            {error, {already_started, Pid}}
    end.

do_spawn(GenMod, link, Mod, Args, Options) ->
    proc_lib:start_link(gen, init_it,
                        [GenMod, parent, parent, Mod, Args, Options],
                        timeout(Options), spawn_opts(Options));
do_spawn(GenMod, monitor, Mod, Args, Options) ->
    Ret = proc_lib:start_monitor(gen, init_it,
                                 [GenMod, parent, parent, Mod, Args, Options],
                                 timeout(Options), spawn_opts(Options)),
    monitor_return(Ret);
do_spawn(GenMod, _LinkP, Mod, Args, Options) ->
    proc_lib:start(gen, init_it,
                   [GenMod, parent, parent, Mod, Args, Options],
                   timeout(Options), spawn_opts(Options)).

do_spawn(GenMod, link, Name, Mod, Args, Options) ->
    Ret = proc_lib:start_link(gen, init_it,
                              [GenMod, parent, parent, Name, Mod, Args, Options],
                              timeout(Options), spawn_opts(Options)),
    ensure_registered(Name, Ret);
do_spawn(GenMod, monitor, Name, Mod, Args, Options) ->
    Ret = proc_lib:start_monitor(gen, init_it,
                                 [GenMod, parent, parent, Name, Mod, Args, Options],
                                 timeout(Options), spawn_opts(Options)),
    ensure_registered(Name, monitor_return(Ret));
do_spawn(GenMod, _LinkP, Name, Mod, Args, Options) ->
    Ret = proc_lib:start(gen, init_it,
                         [GenMod, parent, parent, Name, Mod, Args, Options],
                         timeout(Options), spawn_opts(Options)),
    ensure_registered(Name, Ret).

monitor_return({{ok, Pid}, Mon}) ->
    {ok, {Pid, Mon}};
monitor_return({Error, _Mon}) ->
    Error.

init_it(GenMod, Starter, Parent, Mod, Args, Options) ->
    init_it2(GenMod, Starter, Parent, get('$self'), Mod, Args, Options).

init_it(GenMod, Starter, Parent, Name, Mod, Args, Options) ->
    case register_name(Name) of
        true ->
            init_it2(GenMod, Starter, Parent, Name, Mod, Args, Options);
        {false, Pid} ->
            proc_lib:init_fail(Starter, {error, {already_started, Pid}}, {exit, normal})
    end.

init_it2(GenMod, Starter, Parent, Name, Mod, Args, Options) ->
    GenMod:init_it(Starter, Parent, Name, Mod, Args, Options).

call(Process, Label, Request) ->
    call(Process, Label, Request, 5000).

call(Process, Label, Request, Timeout) ->
    Target = resolved_target(Process),
    Ref = monitor(process, Target),
    Target ! {Label, {get('$self'), Ref}, Request},
    call_receive(Ref, Target, Request, Timeout).

call_receive(Ref, _Target, _Request, infinity) ->
    receive
        {Ref, Reply} ->
            demonitor(Ref, [flush]),
            {ok, Reply};
        {'DOWN', Ref, process, _Pid, Reason} ->
            exit(Reason)
    end;
call_receive(Ref, Target, Request, Timeout) ->
    case get('$self') of
        Self when is_integer(Self) ->
            TRef = erlang:start_timer(Timeout, Self, timeout),
            receive
                {Ref, Reply} ->
                    cancel_timer_flush(TRef),
                    demonitor(Ref, [flush]),
                    {ok, Reply};
                {'DOWN', Ref, process, _Pid, Reason} ->
                    cancel_timer_flush(TRef),
                    exit(Reason);
                {timeout, TRef, timeout} ->
                    demonitor(Ref, [flush]),
                    exit(timeout)
            end;
        _ ->
            receive
                {Ref, Reply} ->
                    demonitor(Ref, [flush]),
                    {ok, Reply};
                {'DOWN', Ref, process, _Pid, Reason} ->
                    exit(Reason)
            after Timeout ->
                demonitor(Ref, [flush]),
                exit(timeout)
            end
    end.

reply({To, Tag}, Reply) ->
    To ! {Tag, Reply},
    ok;
reply(To, Reply) ->
    To ! {To, Reply},
    ok.

stop(Process) ->
    stop(Process, normal, infinity).

stop(Process, Reason, Timeout) ->
    Target = resolved_target(Process),
    Ref = monitor(process, Target),
    Target ! {'$gen_stop', {get('$self'), Ref}, Reason},
    receive
        {Ref, ok} ->
            demonitor(Ref, [flush]),
            ok;
        {'DOWN', Ref, process, _Pid, Reason} ->
            ok;
        {'DOWN', Ref, process, _Pid, OtherReason} ->
            exit(OtherReason)
    after Timeout ->
        demonitor(Ref, [flush]),
        exit(timeout)
    end.

send_request(Process, Tag, Request) ->
    Target = resolved_target(Process),
    Ref = monitor(process, Target),
    Target ! {Tag, {get('$self'), Ref}, Request},
    Ref.

send_request(Process, Tag, Request, Label, ReqIdCol) ->
    maps:put(send_request(Process, Tag, Request), Label, ReqIdCol).

wait_response(ReqId, Timeout) ->
    receive_response(ReqId, Timeout).

receive_response(ReqId, Timeout) ->
    receive
        {ReqId, Reply} ->
            demonitor(ReqId, [flush]),
            {reply, Reply};
        {'DOWN', ReqId, process, Object, Reason} ->
            {error, {Reason, Object}}
    after Timeout ->
        timeout
    end.

check_response({ReqId, Reply}, ReqId) ->
    demonitor(ReqId, [flush]),
    {reply, Reply};
check_response({'DOWN', ReqId, process, Object, Reason}, ReqId) ->
    {error, {Reason, Object}};
check_response(_Msg, _ReqId) ->
    no_reply.

wait_response(ReqIdCol, Timeout, Delete) ->
    receive_response(ReqIdCol, Timeout, Delete).

receive_response(ReqIdCol, Timeout, Delete) when is_map(ReqIdCol) ->
    receive
        {ReqId, _Reply} = Msg when is_map_key(ReqId, ReqIdCol) ->
            collection_result(Msg, ReqIdCol, Delete);
        {'DOWN', ReqId, process, _Object, _Reason} = Msg when is_map_key(ReqId, ReqIdCol) ->
            collection_result(Msg, ReqIdCol, Delete)
    after Timeout ->
        timeout
    end.

check_response(Msg, ReqIdCol, Delete) when is_map(ReqIdCol) ->
    case Msg of
        {ReqId, _Reply} when is_map_key(ReqId, ReqIdCol) ->
            collection_result(Msg, ReqIdCol, Delete);
        {'DOWN', ReqId, process, _Object, _Reason} when is_map_key(ReqId, ReqIdCol) ->
            collection_result(Msg, ReqIdCol, Delete);
        _ ->
            no_reply
    end.

collection_result({ReqId, Reply}, ReqIdCol, Delete) ->
    collection_result({reply, Reply}, ReqId, ReqIdCol, Delete);
collection_result({'DOWN', ReqId, process, Object, Reason}, ReqIdCol, Delete) ->
    collection_result({error, {Reason, Object}}, ReqId, ReqIdCol, Delete).

collection_result(Resp, ReqId, ReqIdCol, false) ->
    {Resp, maps:get(ReqId, ReqIdCol), ReqIdCol};
collection_result(Resp, ReqId, ReqIdCol, true) ->
    {Label, New} = maps:take(ReqId, ReqIdCol),
    {Resp, Label, New}.

reqids_new() -> #{}.
reqids_size(ReqIds) when is_map(ReqIds) -> map_size(ReqIds).
reqids_add(ReqId, Label, ReqIds) when is_map(ReqIds) -> maps:put(ReqId, Label, ReqIds).
reqids_to_list(ReqIds) when is_map(ReqIds) -> maps:to_list(ReqIds).

name({local, Name}) -> Name;
name(Name) -> Name.

unregister_name({local, Name}) -> unregister(Name);
unregister_name(Name) when is_atom(Name) -> unregister(Name);
unregister_name(_Name) -> ok.

get_proc_name(Pid) -> Pid.
get_parent() -> get('$parent').

debug_options(_Name, Options) ->
    option(debug, Options, []).

hibernate_after(Options) ->
    option(hibernate_after, Options, infinity).

format_status_header(Mod, Name) ->
    [Mod, Name].

format_status(_Header, _PDict, _SysState, Misc) ->
    Misc.

'@wait_response_recv_opt'(_Process, _Tag, _Request) ->
    ok.

where({local, Name}) -> whereis(Name);
where(Name) when is_atom(Name) -> whereis(Name);
where(Pid) when is_integer(Pid) -> Pid;
where(_) -> undefined.

register_name({local, Name}) ->
    register_name(Name);
register_name(Name) when is_atom(Name) ->
    case whereis(Name) of
        undefined ->
            true = register(Name, get('$self')),
            true;
        Pid ->
            {false, Pid}
    end;
register_name(_Name) ->
    true.

ensure_registered(Name, {ok, Pid} = Ret) ->
    case where(Name) of
        undefined ->
            register_name_to(Name, Pid),
            Ret;
        _Existing ->
            Ret
    end;
ensure_registered(_Name, Ret) ->
    Ret.

register_name_to({local, Name}, Pid) ->
    register(Name, Pid);
register_name_to(Name, Pid) when is_atom(Name) ->
    register(Name, Pid);
register_name_to(_Name, _Pid) ->
    ok.

call_target({local, Name}) -> Name;
call_target(Name) -> Name.

resolved_target(Process) ->
    Target = call_target(Process),
    case where(Target) of
        undefined -> Target;
        Pid -> Pid
    end.

cancel_timer_flush(TRef) ->
    case erlang:cancel_timer(TRef) of
        false -> receive {timeout, TRef, _Msg} -> ok after 0 -> ok end;
        _Remaining -> ok
    end.

timeout(Options) ->
    option(timeout, Options, infinity).

spawn_opts(Options) ->
    option(spawn_opt, Options, []).

option(Key, [{Key, Value} | _Rest], _Default) ->
    Value;
option(Key, [_Other | Rest], Default) ->
    option(Key, Rest, Default);
option(_Key, [], Default) ->
    Default.
