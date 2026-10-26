%% SPDX-License-Identifier: Apache-2.0
%% Copyright Ericsson AB 1996-2026. All Rights Reserved.
%% Modifications copyright The Hyperlang Authors.
%%
%% Hyperlang guest port of OTP stdlib-8.0.1 proc_lib.erl.
%% Vendored reference: vendor/otp_stdlib_8_0_1/src/proc_lib.erl

-module(proc_lib).

-export([spawn/1, spawn_link/1, spawn/2, spawn_link/2,
         spawn/3, spawn_link/3, spawn/4, spawn_link/4,
         spawn_opt/2, spawn_opt/3, spawn_opt/4, spawn_opt/5]).

-export([start/3, start/4, start/5,
         start_link/3, start_link/4, start_link/5,
         start_monitor/3, start_monitor/4, start_monitor/5]).

-export([hibernate/3, init_ack/1, init_ack/2, init_fail/2, init_fail/3,
         init_p/3, init_p/5, format/1, format/2, format/3, report_cb/2,
         initial_call/1, translate_initial_call/1,
         set_label/1, get_label/1, stop/1, stop/3, wake_up/3]).

spawn(F) when is_function(F, 0) ->
    erlang:spawn(fun() -> init_p(parent, [], F) end).

spawn_link(F) when is_function(F, 0) ->
    erlang:spawn_link(fun() -> init_p(parent, [], F) end).

spawn(_Node, F) when is_function(F, 0) ->
    spawn(F).

spawn_link(_Node, F) when is_function(F, 0) ->
    spawn_link(F).

spawn(M, F, A) ->
    erlang:spawn(fun() -> init_p(parent, [], M, F, A) end).

spawn_link(M, F, A) ->
    erlang:spawn_link(fun() -> init_p(parent, [], M, F, A) end).

spawn(_Node, M, F, A) ->
    spawn(M, F, A).

spawn_link(_Node, M, F, A) ->
    spawn_link(M, F, A).

spawn_opt(F, Opts) when is_function(F, 0) ->
    maybe_monitor(spawn(F), Opts).

spawn_opt(_Node, F, Opts) when is_function(F, 0) ->
    spawn_opt(F, Opts).

spawn_opt(M, F, A, Opts) ->
    maybe_monitor(spawn(M, F, A), Opts).

spawn_opt(_Node, M, F, A, Opts) ->
    spawn_opt(M, F, A, Opts).

maybe_monitor(Pid, Opts) ->
    case member(monitor, Opts) of
        true -> {Pid, monitor(process, Pid)};
        false -> Pid
    end.

start(M, F, A) ->
    start(M, F, A, infinity, []).

start(M, F, A, Timeout) ->
    start(M, F, A, Timeout, []).

start(M, F, A, Timeout, _Opts) ->
    {Return, _Mon} = start_spawn(nolink, M, F, A, Timeout),
    Return.

start_link(M, F, A) ->
    start_link(M, F, A, infinity, []).

start_link(M, F, A, Timeout) ->
    start_link(M, F, A, Timeout, []).

start_link(M, F, A, Timeout, _Opts) ->
    {Return, _Mon} = start_spawn(link, M, F, A, Timeout),
    Return.

start_monitor(M, F, A) ->
    start_monitor(M, F, A, infinity, []).

start_monitor(M, F, A, Timeout) ->
    start_monitor(M, F, A, Timeout, []).

start_monitor(M, F, A, Timeout, _Opts) ->
    start_spawn(monitor, M, F, A, Timeout).

start_spawn(link, M, F, A, Timeout) ->
    start_spawn_linked(link, M, F, A, Timeout);
start_spawn(_Link, M, F, A, Timeout) ->
    start_spawn_linked(nolink, M, F, A, Timeout).

start_spawn_linked(Link, M, F, A, Timeout) ->
    Boot = start_boot(M, F, A),
    Pid = erlang:spawn_link(Boot),
    Mon = monitor(process, Pid),
    Pid ! {proc_lib_start, Pid},
    receive
        {proc_lib_parent, Pid, Parent} ->
            case get('$self') of undefined -> put('$self', Parent); _ -> ok end,
            case Link of nolink -> unlink(Pid); link -> ok end,
            Pid ! {proc_lib_go, Mon, Parent},
            {sync_start(Pid, Mon, Timeout), Mon}
    after Timeout ->
        kill_flush_exit(Pid),
        await_down(Pid, Mon),
        {{error, timeout}, Mon}
    end.

start_boot(M, F, A) ->
    fun() ->
        receive
            {proc_lib_start, SelfCarrier} ->
                [Parent|_] = element(2, process_info(self(), links)),
                Parent ! {proc_lib_parent, SelfCarrier, Parent},
                receive
                    {proc_lib_go, StartRef, Parent} ->
                        put('$self', SelfCarrier),
                        put('$parent', Parent),
                        put('$start_ref', StartRef),
                        call_start(M, F, replace_parent(A, Parent))
                end
        end
    end.

sync_start(Pid, Mon, Timeout) ->
    receive
        {ack, Pid, Return} ->
            Return;
        {nack, Pid, Return} ->
            Return;
        {'DOWN', Mon, process, _Pid, Reason} ->
            {error, Reason}
    after Timeout ->
        kill_flush_exit(Pid),
        await_down(Pid, Mon),
        {error, timeout}
    end.

kill_flush_exit(Pid) ->
    unlink(Pid),
    exit(Pid, kill),
    receive {'EXIT', Pid, _} -> ok after 0 -> ok end.

await_down(Pid, Mon) ->
    receive
        {'DOWN', Mon, process, Pid, _Reason} -> ok;
        {'DOWN', Mon, process, _Pid, _Reason} -> ok
    after 1000 -> ok
    end.

init_ack(Return) ->
    init_ack(get('$parent'), Return).

init_ack(Parent, Return) ->
    Parent ! {ack, get('$self'), Return},
    ok.

init_fail(Return, Exception) ->
    init_fail(get('$parent'), Return, Exception).

init_fail(Parent, Return, {exit, Reason}) ->
    Parent ! {nack, get('$self'), Return},
    exit(Reason);
init_fail(Parent, Return, {error, Reason}) ->
    Parent ! {nack, get('$self'), Return},
    erlang:error(Reason);
init_fail(Parent, Return, Reason) ->
    Parent ! {nack, get('$self'), Return},
    exit(Reason).

init_p(Parent, Ancestors, Fun) ->
    put('$parent', Parent),
    put('$ancestors', Ancestors),
    Fun().

init_p(Parent, Ancestors, M, F, A) ->
    put('$parent', Parent),
    put('$ancestors', Ancestors),
    call_start(M, F, A).

hibernate(M, F, A) ->
    call_start(M, F, A).

wake_up(M, F, A) ->
    call_start(M, F, A).

format(Term) -> Term.
format(Term, _Opts) -> Term.
format(Term, _Opts, _Depth) -> Term.
report_cb(_Report, _Extra) -> ok.
initial_call(_Pid) -> false.
translate_initial_call(Call) -> Call.
set_label(Label) -> put('$label', Label), ok.
get_label(_Pid) -> get('$label').
stop(Pid) -> stop(Pid, normal, infinity).
stop(Pid, Reason, Timeout) -> gen_server:stop(Pid, Reason, Timeout).

call_start(M, init_it, [A, B, C, D, E, F]) ->
    M:init_it(A, B, C, D, E, F);
call_start(M, init_it, [A, B, C, D, E, F, G]) ->
    M:init_it(A, B, C, D, E, F, G);
call_start(M, system_continue, [A, B, C]) ->
    M:system_continue(A, B, C);
call_start(M, system_terminate, [A, B, C, D]) ->
    M:system_terminate(A, B, C, D);
call_start(M, system_code_change, [A, B, C, D]) ->
    M:system_code_change(A, B, C, D);
call_start(_M, _F, _A) ->
    erlang:error({unsupported, proc_lib_apply}).

member(Item, [Item | _Rest]) -> true;
member(Item, [_Other | Rest]) -> member(Item, Rest);
member(_Item, []) -> false.

replace_parent([parent | Rest], StartRef) ->
    [StartRef | replace_parent(Rest, StartRef)];
replace_parent([Item | Rest], StartRef) ->
    [Item | replace_parent(Rest, StartRef)];
replace_parent([], _StartRef) ->
    [].
