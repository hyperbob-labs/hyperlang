%% SPDX-License-Identifier: Apache-2.0
%% Copyright Ericsson AB 1996-2025. All Rights Reserved.
%% Modifications copyright The Hyperlang Authors.
%%
%% Hyperlang guest port of OTP stdlib-8.0.1 sys.erl.
%% Vendored reference: vendor/otp_stdlib_8_0_1/src/sys.erl

-module(otp_sys).

-export([suspend/1, suspend/2, resume/1, resume/2,
         get_status/1, get_status/2, get_state/1, get_state/2,
         replace_state/2, replace_state/3,
         change_code/4, change_code/5,
         terminate/2, terminate/3]).

-export([log/2, log/3, trace/2, trace/3,
         statistics/2, statistics/3,
         log_to_file/2, log_to_file/3,
         no_debug/1, no_debug/2,
         install/2, install/3, remove/2, remove/3]).

-export([handle_system_msg/6, handle_system_msg/7,
         handle_debug/4, print_log/1, get_log/1,
         get_debug/3, debug_options/1, suspend_loop_hib/6]).

-export([callback_mode/0, init/1, handle_event/2, handle_event/4,
         handle_call/2, code_change/4]).

%% Optional gen_server callback link anchors. The gen_server port catches undef
%% for missing optional callbacks; these functions only keep snapshot dynamic
%% linking closed when no user module implements a given optional callback.
handle_info(_Info, State) -> {noreply, State}.
handle_continue(_Continue, State) -> {noreply, State}.
code_change(_OldVsn, State, _Extra) -> {ok, State}.
format_status(Status) -> Status.
callback_mode() -> state_functions.
init(_Args) -> {error, unsupported_callback_module}.
handle_event(_Event, State) -> {ok, State}.
handle_event(_Type, _Event, _StateName, State) -> {keep_state, State}.
handle_call(_Request, State) -> {ok, {error, unsupported_call}, State}.
code_change(_OldVsn, StateName, State, _Extra) -> {ok, StateName, State}.

suspend(Name) -> send_system_msg(Name, suspend).
suspend(Name, Timeout) -> send_system_msg(Name, suspend, Timeout).
resume(Name) -> send_system_msg(Name, resume).
resume(Name, Timeout) -> send_system_msg(Name, resume, Timeout).
get_status(Name) -> send_system_msg(Name, get_status).
get_status(Name, Timeout) -> send_system_msg(Name, get_status, Timeout).

get_state(Name) ->
    case send_system_msg(Name, get_state) of
        {ok, State} -> State;
        {error, Reason} -> erlang:error(Reason)
    end.

get_state(Name, Timeout) ->
    case send_system_msg(Name, get_state, Timeout) of
        {ok, State} -> State;
        {error, Reason} -> erlang:error(Reason)
    end.

replace_state(Name, Fun) ->
    replace_state(Name, Fun, 5000).

replace_state(Name, Fun, Timeout) ->
    case send_system_msg(Name, {replace_state, Fun}, Timeout) of
        {ok, State} -> State;
        {error, Reason} -> erlang:error(Reason)
    end.

change_code(Name, Mod, Vsn, Extra) ->
    send_system_msg(Name, {change_code, Mod, Vsn, Extra}).

change_code(Name, Mod, Vsn, Extra, Timeout) ->
    send_system_msg(Name, {change_code, Mod, Vsn, Extra}, Timeout).

terminate(Name, Reason) ->
    send_system_msg(Name, {terminate, Reason}).

terminate(Name, Reason, Timeout) ->
    send_system_msg(Name, {terminate, Reason}, Timeout).

log(_Name, _Flag) -> ok.
log(_Name, _Flag, _Timeout) -> ok.
trace(_Name, _Flag) -> ok.
trace(_Name, _Flag, _Timeout) -> ok.
statistics(_Name, _Flag) -> ok.
statistics(_Name, _Flag, _Timeout) -> ok.
log_to_file(_Name, _File) -> ok.
log_to_file(_Name, _File, _Timeout) -> ok.
no_debug(_Name) -> ok.
no_debug(_Name, _Timeout) -> ok.
install(_Name, _FuncSpec) -> ok.
install(_Name, _FuncSpec, _Timeout) -> ok.
remove(_Name, _FuncSpec) -> ok.
remove(_Name, _FuncSpec, _Timeout) -> ok.

send_system_msg(Name, Msg) ->
    send_system_msg(Name, Msg, 5000).

send_system_msg(Name, Msg, Timeout) ->
    Target = system_target(Name),
    Ref = monitor(process, Target),
    Target ! {system, {get('$self'), Ref}, Msg},
    receive
        {Ref, Reply} ->
            demonitor(Ref, [flush]),
            Reply;
        {'DOWN', Ref, process, _Pid, Reason} ->
            {error, Reason}
    after Timeout ->
        demonitor(Ref, [flush]),
        exit({timeout, {sys, send_system_msg, [Name, Msg, Timeout]}})
    end.

handle_system_msg(Msg, From, Parent, Module, Debug, Misc) ->
    handle_system_msg(Msg, From, Parent, Module, Debug, Misc, false).

handle_system_msg(suspend, From, Parent, Module, Debug, Misc, _Hibernate) ->
    reply(From, ok),
    suspend_loop(Parent, Module, Debug, Misc);
handle_system_msg(resume, From, Parent, Module, Debug, Misc, _Hibernate) ->
    reply(From, ok),
    Module:system_continue(Parent, Debug, Misc);
handle_system_msg(get_state, From, Parent, Module, Debug, Misc, _Hibernate) ->
    reply(From, Module:system_get_state(Misc)),
    Module:system_continue(Parent, Debug, Misc);
handle_system_msg({replace_state, StateFun}, From, Parent, Module, Debug, Misc, _Hibernate) ->
    {ok, State, NewMisc} = Module:system_replace_state(StateFun, Misc),
    reply(From, {ok, State}),
    Module:system_continue(Parent, Debug, NewMisc);
handle_system_msg({terminate, Reason}, From, Parent, Module, Debug, Misc, _Hibernate) ->
    reply(From, ok),
    Module:system_terminate(Reason, Parent, Debug, Misc);
handle_system_msg(get_status, From, Parent, Module, Debug, Misc, _Hibernate) ->
    Status = Module:format_status(normal, Misc),
    reply(From, {status, get('$self'), {module, Module}, [get(), running, Parent, Debug, Status]}),
    Module:system_continue(Parent, Debug, Misc);
handle_system_msg({change_code, CallbackModule, OldVsn, Extra}, From, Parent, Module, Debug, Misc,
                  _Hibernate) ->
    case Module:system_code_change(Misc, CallbackModule, OldVsn, Extra) of
        {ok, NewMisc} ->
            reply(From, ok),
            Module:system_continue(Parent, Debug, NewMisc);
        Else ->
            reply(From, Else),
            Module:system_continue(Parent, Debug, Misc)
    end;
handle_system_msg(_Msg, From, Parent, Module, Debug, Misc, _Hibernate) ->
    reply(From, {error, unsupported_system_msg}),
    Module:system_continue(Parent, Debug, Misc).

suspend_loop(Parent, Module, Debug, Misc) ->
    receive
        {system, From, Msg} ->
            handle_system_msg(Msg, From, Parent, Module, Debug, Misc);
        {'EXIT', Parent, Reason} ->
            Module:system_terminate(Reason, Parent, Debug, Misc)
    end.

suspend_loop_hib(Parent, Module, Debug, Misc, _Hibernate, _Timeout) ->
    suspend_loop(Parent, Module, Debug, Misc).

handle_debug(Debug, _Func, _State, _Event) -> Debug.
print_log(_Debug) -> ok.
get_log(_Debug) -> {ok, []}.
get_debug(Debug, _Func, _State) -> Debug.
debug_options(Options) -> Options.

reply({To, Tag}, Reply) ->
    To ! {Tag, Reply},
    ok.

system_target({local, Name}) -> Name;
system_target(Name) -> Name.
