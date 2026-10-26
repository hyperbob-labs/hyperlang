%% SPDX-License-Identifier: Apache-2.0
%% Copyright Ericsson AB 1996-2026. All Rights Reserved.
%% Modifications copyright The Hyperlang Authors.
%%
%% Hyperlang guest port of OTP stdlib-8.0.1 supervisor.erl.
%% Vendored reference: vendor/otp_stdlib_8_0_1/src/supervisor.erl

-module(supervisor).

-behaviour(gen_server).

-export([start_link/2, start_link/3,
	 start_child/2, restart_child/2,
	 delete_child/2, terminate_child/2,
	 which_children/1, which_child/2,
	 count_children/1, check_childspecs/1,
	 check_childspecs/2, get_childspec/2,
	 stop/1, stop/3]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-export([format_log/1, format_log/2]).

-export([get_callback_module/1]).

-record(child, {
	        pid = undefined :: child()
	                         | {restarting, pid() | undefined}
	                         | [pid()],
		id              :: child_id(),
		mfargs          :: mfargs(),
		restart_type    :: restart(),
		significant     :: significant(),
		shutdown        :: shutdown(),
		child_type      :: worker(),
		modules = []    :: modules()}).

-record(state, {name                   :: sup_name() | {pid(), module()},
		strategy = one_for_one :: strategy(),
		children = {[],#{}}    :: children(),
                dynamics               :: {'maps', #{pid() => list()}}
                                        | {'mapsets', #{pid() => []}}
                                        | 'undefined',
		intensity = 1          :: non_neg_integer(),
		period    = 5          :: pos_integer(),
		restarts = [],
                nrestarts = 0,
		dynamic_restarts = 0   :: non_neg_integer(),
		auto_shutdown = never  :: auto_shutdown(),
		hibernate_after = infinity :: timeout(),
		hibernating = false    :: boolean(),
		tag = make_ref()       :: reference(),
	        module,
	        args}).

start_link(Mod, Args) ->
    gen_server:start_link(supervisor, {self, Mod, Args}, []).

start_link(SupName, Mod, Args) ->
    gen_server:start_link(SupName, supervisor, {SupName, Mod, Args}, []).

start_child(Supervisor, ChildSpecOrExtraArgs) ->
    call(Supervisor, {start_child, ChildSpecOrExtraArgs}).

restart_child(Supervisor, Id) ->
    call(Supervisor, {restart_child, Id}).

delete_child(Supervisor, Id) ->
    call(Supervisor, {delete_child, Id}).

terminate_child(Supervisor, Id) ->
    call(Supervisor, {terminate_child, Id}).

get_childspec(Supervisor, Id) ->
    call(Supervisor, {get_childspec, Id}).

which_children(Supervisor) ->
    call(Supervisor, which_children).

which_child(Supervisor, Id) ->
    call(Supervisor, {which_child, Id}).

count_children(Supervisor) ->
    call(Supervisor, count_children).

stop(Supervisor) ->
    gen_server:stop(Supervisor).

stop(Supervisor, Reason, Timeout) ->
    gen_server:stop(Supervisor, Reason, Timeout).

call(Supervisor, Req) ->
    gen_server:call(Supervisor, Req, infinity).

check_childspecs(ChildSpecs) ->
    check_childspecs(ChildSpecs, undefined).

check_childspecs(ChildSpecs, AutoShutdown) when is_list(ChildSpecs) ->
    check_childspecs1(ChildSpecs, AutoShutdown);
check_childspecs(X, _AutoShutdown) -> {error, {badarg, X}}.

check_childspecs1(ChildSpecs, undefined) ->
    check_childspecs2(ChildSpecs, undefined);
check_childspecs1(ChildSpecs, never) ->
    check_childspecs2(ChildSpecs, never);
check_childspecs1(ChildSpecs, any_significant) ->
    check_childspecs2(ChildSpecs, any_significant);
check_childspecs1(ChildSpecs, all_significant) ->
    check_childspecs2(ChildSpecs, all_significant);
check_childspecs1(_, X) -> {error, {badarg, X}}.

check_childspecs2(ChildSpecs, AutoShutdown) ->
    case check_startspec(ChildSpecs, AutoShutdown) of
	{ok, _} -> ok;
	Error -> {error, Error}
    end.

get_callback_module(Pid) ->
    {status, _Pid, {module, _Mod},
     [_PDict, _SysState, _Parent, _Dbg, Misc]} = otp_sys:get_status(Pid),
    case lists:keyfind(supervisor, 1, Misc) of
	{supervisor, [{"Callback", Mod}]} ->
	    Mod;
	_ ->
	    [_Header, _Data, {data, [{"State", State}]} | _] = Misc,
	    State#state.module
    end.

init({SupName, Mod, Args}) ->
    process_flag(trap_exit, true),
    case Mod:init(Args) of
	{ok, {SupFlags, StartSpec}} ->
	    case init_state(SupName, SupFlags, Mod, Args) of
		{ok, State} when (State#state.strategy =:= simple_one_for_one) ->
		    init_dynamic(State, StartSpec);
		{ok, State} ->
		    init_children(State, StartSpec);
		Error ->
		    {stop, {supervisor_data, Error}}
	    end;
	ignore ->
	    ignore;
	Error ->
	    {stop, {bad_return, {Mod, init, Error}}}
    end.

init_children(State, StartSpec) ->
    SupName = State#state.name,
    case check_startspec(StartSpec, State#state.auto_shutdown) of
        {ok, Children} ->
            case start_children(Children, SupName) of
                {ok, NChildren} ->
                    {ok, State#state{children = NChildren}, hibernate_after_action(State)};
                {error, NChildren, Reason} ->
                    _ = terminate_children(NChildren, SupName),
                    {stop, {shutdown, Reason}}
            end;
        Error ->
            {stop, {start_spec, Error}}
    end.

init_dynamic(State, [StartSpec]) ->
    case check_startspec([StartSpec], State#state.auto_shutdown) of
        {ok, Children} ->
	    {ok, dyn_init(State#state{children = Children}), hibernate_after_action(State)};
        Error ->
            {stop, {start_spec, Error}}
    end;
init_dynamic(_State, StartSpec) ->
    {stop, {bad_start_spec, StartSpec}}.

start_children(Children, SupName) ->
    Start =
        fun(Id,Child) ->
                case do_start_child(SupName, Child, info_report) of
                    {ok, undefined} when (Child#child.restart_type =:= temporary) ->
                        remove;
                    {ok, Pid} ->
                        {update,Child#child{pid = Pid}};
                    {ok, Pid, _Extra} ->
                        {update,Child#child{pid = Pid}};
                    {error, Reason} ->
                        report_error(start_error, Reason, Child, SupName),
                        {abort,{failed_to_start_child,Id,Reason}}
                end
        end,
    children_map(Start,Children).

do_start_child(SupName, Child, Report) ->
    #child{mfargs = {M, F, Args}} = Child,
    case do_start_child_i(M, F, Args) of
	{ok, Pid} when is_integer(Pid) ->
	    NChild = Child#child{pid = Pid},
	    report_progress(NChild, SupName, Report),
	    {ok, Pid};
	{ok, Pid, Extra} when is_integer(Pid) ->
	    NChild = Child#child{pid = Pid},
	    report_progress(NChild, SupName, Report),
	    {ok, Pid, Extra};
        Other ->
            Other
    end.

do_start_child_i(M, F, A) ->
    try
        apply(M, F, A)
    of
        Result ->
            handle_do_start_child_i_result(Result)
    catch
        throw:Result ->
            handle_do_start_child_i_result(Result);
        exit:Reason ->
            {error, {'EXIT', Reason}};
        error:Reason:StackTrace ->
            {error, {'EXIT', {Reason, StackTrace}}}
    end.

handle_do_start_child_i_result({ok, Pid} = Result) when is_integer(Pid) ->
    Result;
handle_do_start_child_i_result({ok, Pid, _Extra} = Result) when is_integer(Pid) ->
    Result;
handle_do_start_child_i_result(ignore) ->
    {ok, undefined};
handle_do_start_child_i_result({error, _Reason} = Error) ->
    Error;
handle_do_start_child_i_result(Other) ->
    {error, Other}.

handle_call(Msg, From, #state{hibernating = true} = State) ->
    handle_call(Msg, From, wakeup(State));

handle_call({start_child, EArgs}, _From, State) when (State#state.strategy =:= simple_one_for_one) ->
    Child = get_dynamic_child(State),
    #child{mfargs = {M, F, A}} = Child,
    Args = A ++ EArgs,
    case do_start_child_i(M, F, Args) of
	{ok, undefined} ->
	    {reply, {ok, undefined}, State, hibernate_after_action(State)};
	{ok, Pid} ->
	    NState = dyn_store(Pid, Args, State),
	    {reply, {ok, Pid}, NState, hibernate_after_action(State)};
	{ok, Pid, Extra} ->
	    NState = dyn_store(Pid, Args, State),
	    {reply, {ok, Pid, Extra}, NState, hibernate_after_action(State)};
	What ->
	    {reply, What, State, hibernate_after_action(State)}
    end;

handle_call({start_child, ChildSpec}, _From, State) ->
    case check_childspec(ChildSpec, State#state.auto_shutdown) of
	{ok, Child} ->
	    {Resp, NState} = handle_start_child(Child, State),
	    {reply, Resp, NState, hibernate_after_action(State)};
	What ->
	    {reply, {error, What}, State, hibernate_after_action(State)}
    end;

handle_call({terminate_child, Id}, _From, State) when not is_integer(Id),
                                                      (State#state.strategy =:= simple_one_for_one) ->
    {reply, {error, simple_one_for_one}, State, hibernate_after_action(State)};

handle_call({terminate_child, Id}, _From, State) ->
    case find_child(Id, State) of
	{ok, Child} ->
	    do_terminate(Child, State#state.name),
            {reply, ok, del_child(Child, State), hibernate_after_action(State)};
	error ->
	    {reply, {error, not_found}, State, hibernate_after_action(State)}
    end;

handle_call({restart_child, _Id}, _From, State) when (State#state.strategy =:= simple_one_for_one) ->
    {reply, {error, simple_one_for_one}, State, hibernate_after_action(State)};

handle_call({restart_child, Id}, _From, State) ->
    case find_child(Id, State) of
	{ok, Child} when Child#child.pid =:= undefined ->
	    case do_start_child(State#state.name, Child, debug_report) of
		{ok, Pid} ->
		    NState = set_pid(Pid, Id, State),
		    {reply, {ok, Pid}, NState, hibernate_after_action(State)};
		{ok, Pid, Extra} ->
		    NState = set_pid(Pid, Id, State),
		    {reply, {ok, Pid, Extra}, NState, hibernate_after_action(State)};
		Error ->
		    {reply, Error, State, hibernate_after_action(State)}
	    end;
	{ok, #child{pid={restarting,_}}} ->
	    {reply, {error, restarting}, State, hibernate_after_action(State)};
	{ok, _} ->
	    {reply, {error, running}, State, hibernate_after_action(State)};
	_ ->
	    {reply, {error, not_found}, State, hibernate_after_action(State)}
    end;

handle_call({delete_child, _Id}, _From, State) when (State#state.strategy =:= simple_one_for_one) ->
    {reply, {error, simple_one_for_one}, State, hibernate_after_action(State)};

handle_call({delete_child, Id}, _From, State) ->
    case find_child(Id, State) of
	{ok, Child} when Child#child.pid =:= undefined ->
	    NState = remove_child(Id, State),
	    {reply, ok, NState, hibernate_after_action(State)};
	{ok, #child{pid={restarting,_}}} ->
	    {reply, {error, restarting}, State, hibernate_after_action(State)};
	{ok, _} ->
	    {reply, {error, running}, State, hibernate_after_action(State)};
	_ ->
	    {reply, {error, not_found}, State, hibernate_after_action(State)}
    end;

handle_call({get_childspec, Id}, _From, State) ->
    case find_child(Id, State) of
	{ok, Child} ->
            {reply, {ok, child_to_spec(Child)}, State, hibernate_after_action(State)};
	error ->
	    {reply, {error, not_found}, State, hibernate_after_action(State)}
    end;

handle_call(which_children, _From, State) when (State#state.strategy =:= simple_one_for_one) ->
    #child{child_type = CT,modules = Mods} = get_dynamic_child(State),
    Reply = dyn_map(fun({restarting,_}) -> {undefined, restarting, CT, Mods};
                       (Pid) -> {undefined, Pid, CT, Mods}
                    end, State),
    {reply, Reply, State, hibernate_after_action(State)};

handle_call(which_children, _From, State) ->
    Resp =
	children_to_list(
          fun(Id,#child{pid = {restarting,_},
                        child_type = ChildType, modules = Mods}) ->
                  {Id, restarting, ChildType, Mods};
             (Id,#child{pid = Pid,
                        child_type = ChildType, modules = Mods}) ->
                  {Id, Pid, ChildType, Mods}
          end,
          State#state.children),
    {reply, Resp, State, hibernate_after_action(State)};

handle_call({which_child, Id}, _From, State) when not is_integer(Id),
                                                  (State#state.strategy =:= simple_one_for_one) ->
    {reply, {error, simple_one_for_one}, State, hibernate_after_action(State)};

handle_call({which_child, Pid}, _From, State) when (State#state.strategy =:= simple_one_for_one) ->
    Result = case find_dynamic_child(Pid, State) of
		 {ok, #child{pid = {restarting,_},
			     child_type = CT, modules = Mods}} ->
		     {ok, {undefined, restarting, CT, Mods}};
		 {ok, #child{pid = Pid,
			     child_type = CT, modules = Mods}} ->
		     {ok, {undefined, Pid, CT, Mods}};
		 error ->
		     {error, not_found}
	     end,
    {reply, Result, State, hibernate_after_action(State)};

handle_call({which_child, Id}, _From, State) ->
    Result = case find_child(Id, State) of
		 {ok, #child{pid = {restarting,_},
			     child_type = CT, modules = Mods}} ->
		     {ok, {Id, restarting, CT, Mods}};
		 {ok, #child{pid = Pid,
			     child_type = CT, modules = Mods}} ->
		     {ok, {Id, Pid, CT, Mods}};
		 error ->
		     {error, not_found}
	     end,
    {reply, Result, State, hibernate_after_action(State)};

handle_call(count_children, _From,  #state{dynamic_restarts = Restarts} = State)
  when (State#state.strategy =:= simple_one_for_one) ->
    #child{child_type = CT} = get_dynamic_child(State),
    Sz = dyn_size(State),
    Active = Sz - Restarts,
    Reply = case CT of
		supervisor -> [{specs, 1}, {active, Active},
			       {supervisors, Sz}, {workers, 0}];
		worker -> [{specs, 1}, {active, Active},
			   {supervisors, 0}, {workers, Sz}]
	    end,
    {reply, Reply, State, hibernate_after_action(State)};

handle_call(count_children, _From, State) ->

    {Specs, Active, Supers, Workers} =
	children_fold(fun(_Id, Child, Counts) ->
                              count_child(Child, Counts)
                      end, {0,0,0,0}, State#state.children),

    Reply = [{specs, Specs}, {active, Active},
	     {supervisors, Supers}, {workers, Workers}],
    {reply, Reply, State, hibernate_after_action(State)}.

count_child(#child{pid = Pid, child_type = worker},
	    {Specs, Active, Supers, Workers}) ->
    case is_integer(Pid) andalso is_process_alive(Pid) of
	true ->  {Specs+1, Active+1, Supers, Workers+1};
	false -> {Specs+1, Active, Supers, Workers+1}
    end;
count_child(#child{pid = Pid, child_type = supervisor},
	    {Specs, Active, Supers, Workers}) ->
    case is_integer(Pid) andalso is_process_alive(Pid) of
	true ->  {Specs+1, Active+1, Supers+1, Workers};
	false -> {Specs+1, Active, Supers+1, Workers}
    end.

handle_cast(Msg, #state{hibernating = true} = State) ->
    handle_cast(Msg, wakeup(State));

handle_cast({try_again_restart, Tag, TryAgainId}, #state{tag = Tag} = State) ->
    case find_child_and_args(TryAgainId, State) of
	{ok, Child = #child{pid={restarting,_}}} ->
	    case restart(Child,State) of
		{ok, State1} ->
		    {noreply, State1, hibernate_after_action(State)};
		{shutdown, State1} ->
		    {stop, shutdown, State1}
	    end;
	_ ->
	    {noreply,State, hibernate_after_action(State)}
    end.

handle_info({hibernate, Tag}, #state{tag = Tag} = State) ->
    {noreply, enter_hibernation(State), hibernate};

handle_info(Msg, #state{hibernating = true} = State) ->
    handle_info(Msg, wakeup(State));

handle_info({'EXIT', Pid, Reason}, State) ->
    case restart_child(Pid, Reason, State) of
	{ok, State1} ->
	    {noreply, State1, hibernate_after_action(State)};
	{shutdown, State1} ->
	    {stop, shutdown, State1}
    end;

handle_info(Msg, State) ->
    report_unexpected(Msg),
    {noreply, State, hibernate_after_action(State)}.

terminate(_Reason, State) when (State#state.strategy =:= simple_one_for_one) ->
    terminate_dynamic_children(State);
terminate(_Reason, State) ->
    terminate_children(State#state.children, State#state.name).

code_change(_, State, _) ->
    case (State#state.module):init(State#state.args) of
	{ok, {SupFlags, StartSpec}} ->
	    case set_flags(SupFlags, State) of
		{ok, State1}  ->
                    update_childspec(State1, StartSpec);
		{invalid_type, SupFlags} ->
		    {error, {bad_flags, SupFlags}};
		Error ->
		    {error, Error}
	    end;
	ignore ->
	    {ok, State};
	Error ->
	    Error
    end.

enter_hibernation(State0) ->
    State1 = purge_restarts(State0),
    State1#state{hibernating = true}.

wakeup(State0) ->
    State1 = purge_restarts(State0),
    State1#state{hibernating = false}.

update_childspec(State, StartSpec) when (State#state.strategy =:= simple_one_for_one) ->
    case check_startspec(StartSpec, State#state.auto_shutdown) of
        {ok, {[_],_}=Children} ->
            {ok, State#state{children = Children}};
        Error ->
            {error, Error}
    end;
update_childspec(State, StartSpec) ->
    case check_startspec(StartSpec, State#state.auto_shutdown) of
	{ok, Children} ->
	    OldC = State#state.children,
	    NewC = update_childspec1(OldC, Children, []),
	    {ok, State#state{children = NewC}};
        Error ->
	    {error, Error}
    end.

update_childspec1({[Id|OldIds], OldDb}, {Ids,Db}, KeepOld) ->
    case update_chsp(maps:get(Id,OldDb), Db) of
	{ok,NewDb} ->
	    update_childspec1({OldIds,OldDb}, {Ids,NewDb}, KeepOld);
	false ->
	    update_childspec1({OldIds,OldDb}, {Ids,Db}, [Id|KeepOld])
    end;
update_childspec1({[],OldDb}, {Ids,Db}, KeepOld) ->
    KeepOldDb = maps:with(KeepOld,OldDb),

    {lists:reverse(Ids ++ KeepOld),maps:merge(KeepOldDb,Db)}.

update_chsp(#child{id=Id}=OldChild, NewDb) ->
    case maps:find(Id, NewDb) of
        {ok,Child} ->
            {ok,NewDb#{Id => Child#child{pid = OldChild#child.pid}}};
        error ->
            false
    end.

handle_start_child(Child, State) ->
    case find_child(Child#child.id, State) of
	error ->
	    case do_start_child(State#state.name, Child, debug_report) of
		{ok, undefined} when (Child#child.restart_type =:= temporary) ->
		    {{ok, undefined}, State};
		{ok, Pid} ->
		    {{ok, Pid}, save_child(Child#child{pid = Pid}, State)};
		{ok, Pid, Extra} ->
		    {{ok, Pid, Extra}, save_child(Child#child{pid = Pid}, State)};
		{error, {already_started, _Pid} = What} ->
		    {{error, What}, State};
		{error, What} ->
		    {{error, {What, Child}}, State}
	    end;
	{ok, OldChild} when is_integer(OldChild#child.pid) ->
	    {{error, {already_started, OldChild#child.pid}}, State};
	{ok, _OldChild} ->
	    {{error, already_present}, State}
    end.

restart_child(Pid, Reason, State) ->
    case find_child_and_args(Pid, State) of
        {ok, Child} ->
	    do_restart(Reason, Child, State);
	error ->
	    {ok, State}
    end.

do_restart(Reason, Child, State) when (Child#child.restart_type =:= permanent) ->
    report_error(child_terminated, Reason, Child, State#state.name),
    restart(Child, State);
do_restart(normal, Child, State) ->
    NState = del_child(Child, State),
    do_auto_shutdown(Child, NState);
do_restart(shutdown, Child, State) ->
    NState = del_child(Child, State),
    do_auto_shutdown(Child, NState);
do_restart({shutdown, _Term}, Child, State) ->
    NState = del_child(Child, State),
    do_auto_shutdown(Child, NState);
do_restart(Reason, Child, State) when (Child#child.restart_type =:= transient) ->
    report_error(child_terminated, Reason, Child, State#state.name),
    restart(Child, State);
do_restart(Reason, Child, State) when (Child#child.restart_type =:= temporary) ->
    report_error(child_terminated, Reason, Child, State#state.name),
    NState = del_child(Child, State),
    do_auto_shutdown(Child, NState).

do_auto_shutdown(_Child, State=#state{auto_shutdown = never}) ->
    {ok, State};
do_auto_shutdown(Child, State) when not (Child#child.significant =:= true) ->
    {ok, State};
do_auto_shutdown(_Child, State=#state{auto_shutdown = any_significant}) ->
    {shutdown, State};
do_auto_shutdown(_Child, State=#state{auto_shutdown = all_significant}) ->
    case
	children_any(
	    fun
		(_, #child{pid = undefined}) ->
		    false;
		(_, #child{significant = true}) ->
		    true;
		(_, _) ->
		    false
	    end,
	    State#state.children
	)
    of
	true ->
	    {ok, State};
	false ->
	    {shutdown, State}
    end.

restart(Child, State) ->
    case add_restart(State) of
	{ok, NState} ->
	    case restart(NState#state.strategy, Child, NState) of
		{{try_again, TryAgainId}, NState2} ->

                    try_again_restart(TryAgainId, NState2#state.tag),
		    {ok,NState2};
		Other ->
		    Other
	    end;
	{terminate, NState} ->
	    report_error(shutdown, reached_max_restart_intensity,
			 Child, State#state.name),
	    {shutdown, del_child(Child, NState)}
    end.

restart(simple_one_for_one, Child, State0) ->
    #child{pid = OldPid, mfargs = {M, F, A}} = Child,
    State1 = case OldPid of
		{restarting,_} ->
		    NRes = State0#state.dynamic_restarts - 1,
		    State0#state{dynamic_restarts = NRes};
		_ ->
		    State0
	    end,
    State2 = dyn_erase(OldPid, State1),
    case do_start_child_i(M, F, A) of
        {ok, undefined} ->

            {ok, State2};
	{ok, Pid} ->
            NState = dyn_store(Pid, A, State2),
	    {ok, NState};
	{ok, Pid, _Extra} ->
            NState = dyn_store(Pid, A, State2),
	    {ok, NState};
	{error, Error} ->
            ROldPid = restarting(OldPid),
	    NRestarts = State2#state.dynamic_restarts + 1,
	    State3 = State2#state{dynamic_restarts = NRestarts},
            NState = dyn_store(ROldPid, A, State3),
	    report_error(start_error, Error, Child, NState#state.name),
	    {{try_again, ROldPid}, NState}
    end;
restart(one_for_one, #child{id=Id} = Child, State) ->
    OldPid = Child#child.pid,
    case do_start_child(State#state.name, Child, info_report) of
	{ok, Pid} ->
	    NState = set_pid(Pid, Id, State),
	    {ok, NState};
	{ok, Pid, _Extra} ->
	    NState = set_pid(Pid, Id, State),
	    {ok, NState};
	{error, Reason} ->
	    NState = set_pid(restarting(OldPid), Id, State),
	    report_error(start_error, Reason, Child, State#state.name),
	    {{try_again,Id}, NState}
    end;
restart(rest_for_one, #child{id=Id} = Child, #state{name=SupName} = State) ->
    {ChAfter, ChBefore} = split_child(Id, State#state.children),
    {Return, ChAfter2} = restart_multiple_children(Child, ChAfter, SupName),
    {Return, State#state{children = append(ChAfter2,ChBefore)}};
restart(one_for_all, Child, #state{name=SupName} = State) ->
    Children1 = del_child(Child#child.id, State#state.children),
    {Return, NChildren} = restart_multiple_children(Child, Children1, SupName),
    {Return, State#state{children = NChildren}}.

restart_multiple_children(Child, Children, SupName) ->
    Children1 = terminate_children(Children, SupName),
    case start_children(Children1, SupName) of
	{ok, NChildren} ->
	    {ok, NChildren};
	{error, NChildren, {failed_to_start_child, FailedId, _Reason}} ->
            NewPid = if FailedId =:= Child#child.id ->
                             restarting(Child#child.pid);
                        true ->
                             {restarting,undefined}
                     end,
	    {{try_again, FailedId}, set_pid(NewPid,FailedId,NChildren)}
    end.

restarting(Pid) when is_integer(Pid) -> {restarting,Pid};
restarting(RPid) -> RPid.

try_again_restart(TryAgainId, Tag) ->
    gen_server:cast(get('$self'), {try_again_restart, Tag, TryAgainId}).

terminate_children(Children, SupName) ->
    Terminate =
        fun(_Id,Child) when (Child#child.restart_type =:= temporary) ->

                do_terminate(Child, SupName),
                remove;
           (_Id,Child) ->
                do_terminate(Child, SupName),
                {update,Child#child{pid=undefined}}
        end,
    {ok,NChildren} = children_map(Terminate, Children),
    NChildren.

do_terminate(Child, SupName) when is_integer(Child#child.pid) ->
    case shutdown(Child) of
        ok ->
            ok;
        {error, OtherReason} ->
            report_error(shutdown_error, OtherReason, Child, SupName)
    end,
    ok;
do_terminate(_Child, _SupName) ->
    ok.

shutdown(#child{pid=Pid, shutdown=brutal_kill} = Child) ->
    Mon = monitor(process, Pid),
    exit(Pid, kill),
    receive
        {'DOWN', Mon, process, Pid, Reason0} ->
            case unlink_flush(Pid, Reason0) of
                killed ->
                    ok;
                shutdown when not ((Child#child.restart_type =:= permanent)) ->
                    ok;
                {shutdown, _} when not ((Child#child.restart_type =:= permanent)) ->
                    ok;
                normal when not ((Child#child.restart_type =:= permanent)) ->
                    ok;
                Reason ->
                    {error, Reason}
            end
    end;
shutdown(#child{pid=Pid, shutdown=Time} = Child) ->
    Mon = monitor(process, Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Mon, process, Pid, Reason0} ->
            case unlink_flush(Pid, Reason0) of
                shutdown ->
                    ok;
                {shutdown, _} when not ((Child#child.restart_type =:= permanent)) ->
                    ok;
                normal when not ((Child#child.restart_type =:= permanent)) ->
                    ok;
                Reason ->
                    {error, Reason}
            end
    after Time ->
        exit(Pid, kill),
        receive
            {'DOWN', Mon, process, Pid, Reason0} ->
                case unlink_flush(Pid, Reason0) of
                    shutdown ->
                        ok;
                    {shutdown, _} when not ((Child#child.restart_type =:= permanent)) ->
                        ok;
                    normal when not ((Child#child.restart_type =:= permanent)) ->
                        ok;
                    Reason ->
                        {error, Reason}
                end
        end
    end.

unlink_flush(Pid, noproc) ->
    {links, Ls} = process_info(self(),links),

    Timeout = case lists:member(Pid, Ls) of
                  true -> infinity;
                  false -> 0
              end,
    receive
        {'EXIT', Pid, ExitReason} ->
            ExitReason
    after Timeout ->
            child_process_unlinked
    end;
unlink_flush(Pid, ExitReason) ->

    unlink(Pid),
    receive
        {'EXIT', Pid, _} -> ok
    after 0 -> ok
    end,
    ExitReason.

terminate_dynamic_children(State) ->
    Child = get_dynamic_child(State),
    Pids = dyn_fold(
        fun
            (P, Acc) when is_integer(P) ->
                Mon = monitor(process, P),
                case Child#child.shutdown of
                    brutal_kill -> exit(P, kill);
                    _ -> exit(P, shutdown)
                end,
                Acc#{{P, Mon} => true};
            ({restarting,_}, Acc) ->
                Acc
        end,
        #{},
        State
    ),
    TRef = case Child#child.shutdown of
        brutal_kill ->
            undefined;
        infinity ->
            undefined;
        Time ->
            erlang:start_timer(Time, get('$self'), kill)
    end,
    Sz = maps:size(Pids),
    EStack = wait_dynamic_children(Child, Pids, Sz, TRef, #{}),

    maps:foreach(fun(Reason, Ls) ->
                      report_error(shutdown_error, Reason,
                                   Child#child{pid=Ls}, State#state.name)
              end, EStack).

wait_dynamic_children(_Child, _Pids, 0, undefined, EStack) ->
    EStack;
wait_dynamic_children(_Child, _Pids, 0, TRef, EStack) ->

    _ = erlang:cancel_timer(TRef),
    receive
        {timeout, TRef, kill} ->
            EStack
    after 0 ->
            EStack
    end;
wait_dynamic_children(#child{shutdown=brutal_kill} = Child, Pids, Sz,
                      TRef, EStack) ->
    receive
        {'DOWN', Mon, process, Pid, Reason0}
          when is_map_key({Pid, Mon}, Pids) ->
            case unlink_flush(Pid, Reason0) of
                killed ->
                    wait_dynamic_children(Child, maps:remove({Pid, Mon}, Pids),
                                          Sz-1, TRef, EStack);

                shutdown when not ((Child#child.restart_type =:= permanent)) ->
                    wait_dynamic_children(Child, maps:remove({Pid, Mon}, Pids),
                                          Sz-1, TRef, EStack);

                {shutdown, _} when not ((Child#child.restart_type =:= permanent)) ->
                    wait_dynamic_children(Child, maps:remove({Pid, Mon}, Pids),
                                          Sz-1, TRef, EStack);

                normal when not ((Child#child.restart_type =:= permanent)) ->
                    wait_dynamic_children(Child, maps:remove({Pid, Mon}, Pids),
                                          Sz-1, TRef, EStack);
                Reason ->
                    wait_dynamic_children(Child, maps:remove({Pid, Mon}, Pids),
                                          Sz-1, TRef, maps_prepend(Reason, Pid,
                                                                   EStack))
            end
    end;
wait_dynamic_children(Child, Pids, Sz, TRef, EStack) ->
    receive
        {'DOWN', Mon, process, Pid, Reason0}
          when is_map_key({Pid, Mon}, Pids) ->
            case unlink_flush(Pid, Reason0) of
                shutdown ->
                    wait_dynamic_children(Child, maps:remove({Pid, Mon}, Pids),
                                          Sz-1, TRef, EStack);

                {shutdown, _} when not ((Child#child.restart_type =:= permanent)) ->
                    wait_dynamic_children(Child, maps:remove({Pid, Mon}, Pids),
                                          Sz-1, TRef, EStack);

                normal when not ((Child#child.restart_type =:= permanent)) ->
                    wait_dynamic_children(Child, maps:remove({Pid, Mon}, Pids),
                                          Sz-1, TRef, EStack);

                Reason ->
                    wait_dynamic_children(Child, maps:remove({Pid, Mon}, Pids),
                                          Sz-1, TRef, maps_prepend(Reason, Pid,
                                                                   EStack))
            end;

        {timeout, TRef, kill} ->
            maps:foreach(fun({P, _}, _) -> exit(P, kill) end, Pids),
            wait_dynamic_children(Child, Pids, Sz, undefined, EStack)
    end.

maps_prepend(Key, Value, Map) ->
    case maps:find(Key, Map) of
        {ok, Values} ->
            maps:put(Key, [Value|Values], Map);
        error ->
            maps:put(Key, [Value], Map)
    end.

save_child(#child{mfargs = {M, F, _}} = Child, State) when (Child#child.restart_type =:= temporary) ->
    do_save_child(Child#child{mfargs = {M, F, undefined}}, State);
save_child(Child, State) ->
    do_save_child(Child, State).

do_save_child(#child{id = Id} = Child, #state{children = {Ids,Db}} = State) ->
    State#state{children = {[Id|Ids],Db#{Id => Child}}}.

del_child(#child{pid = Pid}, State) when (State#state.strategy =:= simple_one_for_one) ->
    dyn_erase(Pid,State);
del_child(Child, State) when is_record(Child,child), is_record(State,state) ->
    NChildren = del_child(Child#child.id, State#state.children),
    State#state{children = NChildren};
del_child(Id, {Ids,Db}) ->
    case maps:get(Id, Db) of
        Child when Child#child.restart_type =:= temporary ->
            {lists:delete(Id, Ids), maps:remove(Id, Db)};
        Child ->
            {Ids, Db#{Id=>Child#child{pid=undefined}}}
    end.

split_child(Id, {Ids,Db}) ->
    {IdsAfter,IdsBefore} = split_ids(Id, Ids, []),
    DbBefore = maps:with(IdsBefore,Db),
    #{Id:=Ch} = DbAfter = maps:with(IdsAfter,Db),
    {{IdsAfter,DbAfter#{Id=>Ch#child{pid=undefined}}},{IdsBefore,DbBefore}}.

split_ids(Id, [Id|Ids], After) ->
    {lists:reverse([Id|After]), Ids};
split_ids(Id, [Other|Ids], After) ->
    split_ids(Id, Ids, [Other | After]).

find_child(Pid, State) when is_integer(Pid), (State#state.strategy =:= simple_one_for_one) ->
    case find_dynamic_child(Pid, State) of
        error ->
            case find_dynamic_child(restarting(Pid), State) of
                error ->
		    case erlang:is_process_alive(Pid) of
			true -> error;
			false -> {ok, get_dynamic_child(State)}
		    end;
                Other ->
                    Other
            end;
        Other ->
            Other
    end;
find_child(Id, #state{children = {_Ids,Db}}) ->
    maps:find(Id, Db).

find_child_and_args(Pid, State) when (State#state.strategy =:= simple_one_for_one) ->
    case find_dynamic_child(Pid, State) of
        {ok,#child{mfargs={M,F,_}} = Child} ->
            {ok, Args} = dyn_args(Pid, State),
            {ok, Child#child{mfargs = {M, F, Args}}};
        error ->
            error
    end;
find_child_and_args(Pid, State) when is_integer(Pid) ->
    find_child_by_pid(Pid, State);
find_child_and_args(Id, #state{children={_Ids,Db}})  ->
    maps:find(Id, Db).

find_dynamic_child(Pid, State) ->
    case dyn_exists(Pid, State) of
        true ->
            Child = get_dynamic_child(State),
            {ok, Child#child{pid=Pid}};
        false ->
            error
    end.

find_child_by_pid(Pid,#state{children={_Ids,Db}}) ->
    Fun = fun(_Id,#child{pid=P}=Ch,_) when P =:= Pid ->
                  throw(Ch);
             (_,_,error) ->
                  error
          end,
    try maps:fold(Fun,error,Db)
    catch throw:Child -> {ok,Child}
    end.

get_dynamic_child(#state{children={[Id],Db}}) ->
    #{Id := Child} = Db,
    Child.

set_pid(Pid, Id, #state{children=Children} = State) ->
    State#state{children = set_pid(Pid, Id, Children)};
set_pid(Pid, Id, {Ids, Db}) ->
    NewDb = maps:update_with(Id, fun(Child) -> Child#child{pid=Pid} end, Db),
    {Ids,NewDb}.

remove_child(Id, #state{children={Ids,Db}} = State) ->
    NewIds = lists:delete(Id,Ids),
    NewDb = maps:remove(Id,Db),
    State#state{children = {NewIds,NewDb}}.

children_map(Fun,{Ids,Db}) ->
    children_map(Fun, Ids, Db, []).

children_map(Fun,[Id|Ids],Db,Acc) ->
    case Fun(Id,maps:get(Id,Db)) of
        {update,Child} ->
            children_map(Fun,Ids,Db#{Id => Child},[Id|Acc]);
        remove ->
            children_map(Fun,Ids,maps:remove(Id,Db),Acc);
        {abort,Reason} ->
            {error,{lists:reverse(Ids)++[Id|Acc],Db},Reason}
    end;
children_map(_Fun,[],Db,Acc) ->
    {ok,{Acc,Db}}.

children_to_list(Fun,{Ids,Db}) ->
    children_to_list(Fun, Ids, Db, []).
children_to_list(Fun,[Id|Ids],Db,Acc) ->
    children_to_list(Fun,Ids,Db,[Fun(Id,maps:get(Id,Db))|Acc]);
children_to_list(_Fun,[],_Db,Acc) ->
    lists:reverse(Acc).

children_fold(Fun,Init,{_Ids,Db}) ->
    maps:fold(Fun, Init, Db).

children_any(Pred, {_Ids, Db}) ->
    Iter=maps:iterator(Db),
    children_any1(Pred, maps:next(Iter)).

children_any1(_Pred, none) ->
    false;
children_any1(Pred, {Key, Value, Iter}) ->
    Pred(Key, Value) orelse children_any1(Pred, maps:next(Iter)).

append({Ids1,Db1},{Ids2,Db2}) ->
    {Ids1++Ids2,maps:merge(Db1,Db2)}.

init_state(SupName, Type, Mod, Args) ->
    set_flags(Type, #state{name = supname(SupName,Mod),
			   module = Mod,
			   args = Args,
			   auto_shutdown = never}).

set_flags(Flags, State) ->
    try check_flags(Flags) of
	#{strategy := Strategy, intensity := MaxIntensity, period := Period,
	  auto_shutdown := AutoShutdown, hibernate_after := HibernateAfter} ->
	    {ok, State#state{strategy = Strategy,
			     intensity = MaxIntensity,
			     period = Period,
			     auto_shutdown = AutoShutdown,
			     hibernate_after = HibernateAfter}}
    catch
        throw:Thrown -> Thrown
    end.

check_flags(SupFlags) when is_map(SupFlags) ->
    case maps:merge(#{strategy => one_for_one, intensity => 1, period => 5, auto_shutdown => never}, SupFlags) of
	#{hibernate_after := _} = MergedFlags ->
	    do_check_flags(MergedFlags);
	#{strategy := Strategy} = MergedFlags ->
	    do_check_flags(MergedFlags#{hibernate_after => default_hibernate_after(Strategy)})
    end;
check_flags({Strategy, MaxIntensity, Period}) ->
    check_flags(#{strategy => Strategy,
		  intensity => MaxIntensity,
		  period => Period});
check_flags(What) ->
    throw({invalid_type, What}).

do_check_flags(#{strategy := Strategy,
		 intensity := MaxIntensity,
		 period := Period,
		 auto_shutdown := AutoShutdown,
		 hibernate_after := HibernateAfter} = Flags) ->
    validStrategy(Strategy),
    validIntensity(MaxIntensity),
    validPeriod(Period),
    validAutoShutdown(AutoShutdown),
    validAutoShutdownForStrategy(AutoShutdown, Strategy),
    validHibernateAfter(HibernateAfter),
    Flags.

validStrategy(simple_one_for_one) -> true;
validStrategy(one_for_one)        -> true;
validStrategy(one_for_all)        -> true;
validStrategy(rest_for_one)       -> true;
validStrategy(What)               -> throw({invalid_strategy, What}).

validIntensity(Max) when is_integer(Max),
                         Max >=  0 -> true;
validIntensity(What)               -> throw({invalid_intensity, What}).

validPeriod(Period) when is_integer(Period),
                         Period > 0 -> true;
validPeriod(What)                   -> throw({invalid_period, What}).

validAutoShutdown(never)           -> true;
validAutoShutdown(any_significant) -> true;
validAutoShutdown(all_significant) -> true;
validAutoShutdown(What)            -> throw({invalid_auto_shutdown, What}).

validAutoShutdownForStrategy(any_significant, simple_one_for_one) ->
    throw({bad_combination, [{auto_shutdown, any_significant}, {strategy, simple_one_for_one}]});
validAutoShutdownForStrategy(all_significant, simple_one_for_one) ->
    throw({bad_combination, [{auto_shutdown, all_significant}, {strategy, simple_one_for_one}]});
validAutoShutdownForStrategy(_AutoShutdown, _Strategy) ->
    true.

validHibernateAfter(infinity) ->
    true;
validHibernateAfter(Timeout) when is_integer(Timeout), Timeout >= 0 ->
    true;
validHibernateAfter(What) ->
    throw({invalid_hibernate_after, What}).

hibernate_after_action(#state{tag = Tag, hibernate_after = HibernateAfter}) ->
    {timeout, HibernateAfter, {hibernate, Tag}}.

default_hibernate_after(simple_one_for_one) ->
    infinity;
default_hibernate_after(_) ->
    1000.

supname(self, Mod) -> {get('$self'), Mod};
supname(N, _)      -> N.

check_startspec(Children, AutoShutdown) ->
    check_startspec(Children, [], #{}, AutoShutdown).

check_startspec([ChildSpec|T], Ids, Db, AutoShutdown) ->
    case check_childspec(ChildSpec, AutoShutdown) of
	{ok, #child{id=Id}=Child} ->
	    case maps:is_key(Id, Db) of

                true -> {duplicate_child_name, Id};
		false -> check_startspec(T, [Id | Ids], Db#{Id=>Child},
					 AutoShutdown)
	    end;
	Error -> Error
    end;
check_startspec([], Ids, Db, _AutoShutdown) ->
    {ok, {lists:reverse(Ids),Db}}.

check_childspec(ChildSpec, AutoShutdown) when is_map(ChildSpec) ->
    try
        do_check_childspec(maps:merge(#{restart => permanent, type => worker},ChildSpec),
                           AutoShutdown)
    catch
        throw:Error ->
            Error
    end;
check_childspec({Id, Func, RestartType, Shutdown, ChildType, Mods},
		AutoShutdown) ->
    check_childspec(#{id => Id,
		      start => Func,
		      restart => RestartType,
		      significant => false,
		      shutdown => Shutdown,
		      type => ChildType,
		      modules => Mods},
		    AutoShutdown);
check_childspec(X, _AutoShutdown) -> {invalid_child_spec, X}.

do_check_childspec(#{restart := RestartType,
		     type := ChildType} = ChildSpec,
		   AutoShutdown)->
    Id = case ChildSpec of
	       #{id := I} -> I;
	       _ -> throw(missing_id)
	   end,
    Func = case ChildSpec of
	       #{start := F} -> F;
	       _ -> throw(missing_start)
	   end,
    true = validId(Id),
    true = validFunc(Func),
    true = validRestartType(RestartType),
    Significant = case ChildSpec of
		      #{significant := Signf} -> Signf;
		      _ -> false
                  end,
    true = validSignificant(Significant, RestartType, AutoShutdown),
    true = validChildType(ChildType),
    Shutdown = case ChildSpec of
		   #{shutdown := S} -> S;
		   #{type := worker} -> 5000;
		   #{type := supervisor} -> infinity
	       end,
    true = validShutdown(Shutdown),
    Mods = case ChildSpec of
	       #{modules := Ms} -> Ms;
	       _ -> {M,_,_} = Func, [M]
	   end,
    true = validMods(Mods),
    {ok, #child{id = Id, mfargs = Func, restart_type = RestartType,
		significant = Significant, shutdown = Shutdown,
		child_type = ChildType, modules = Mods}}.

validChildType(supervisor) -> true;
validChildType(worker) -> true;
validChildType(What) -> throw({invalid_child_type, What}).

validId(_Id) -> true.

validFunc({M, F, A}) when is_atom(M),
                          is_atom(F),
                          is_list(A) -> true;
validFunc(Func)                      -> throw({invalid_mfa, Func}).

validRestartType(permanent)   -> true;
validRestartType(temporary)   -> true;
validRestartType(transient)   -> true;
validRestartType(RestartType) -> throw({invalid_restart_type, RestartType}).

validSignificant(true, _RestartType, never) ->
    throw({bad_combination, [{auto_shutdown, never}, {significant, true}]});
validSignificant(true, permanent, _AutoShutdown) ->
    throw({bad_combination, [{restart, permanent}, {significant, true}]});
validSignificant(Significant, _RestartType, _AutoShutdown)
  when is_boolean(Significant) ->
    true;
validSignificant(Significant, _RestartType, _AutoShutdown) ->
    throw({invalid_significant, Significant}).

validShutdown(Shutdown)
  when is_integer(Shutdown), Shutdown >= 0 -> true;
validShutdown(infinity)             -> true;
validShutdown(brutal_kill)          -> true;
validShutdown(Shutdown)             -> throw({invalid_shutdown, Shutdown}).

validMods(dynamic) -> true;
validMods(Mods) when is_list(Mods) ->
    lists:all(fun
                  (Mod) when is_atom(Mod) ->
                      true;
                  (Mod) ->
                      throw({invalid_module, Mod})
              end,
              Mods);
validMods(Mods) -> throw({invalid_modules, Mods}).

child_to_spec(#child{id = Id,
		    mfargs = Func,
		    restart_type = RestartType,
		    significant = Significant,
		    shutdown = Shutdown,
		    child_type = ChildType,
		    modules = Mods}) ->
    #{id => Id,
      start => Func,
      restart => RestartType,
      significant => Significant,
      shutdown => Shutdown,
      type => ChildType,
      modules => Mods}.

add_restart(#state{intensity = 0} = State) ->
    {terminate, State};
add_restart(#state{intensity = I, restarts = R, nrestarts = NR} = State)
  when NR < I andalso NR < 1000 ->
    {ok, State#state{restarts = [erlang:monotonic_time(second)|R], nrestarts = NR + 1}};
add_restart(#state{intensity = I, period = P, restarts = R} = State) ->
    Now = erlang:monotonic_time(second),
    Threshold = Now - P,
    case can_restart(I - 1, Threshold, R, [], 0) of
        {true, NR1, R1} ->
            {ok, State#state{restarts = [Now|R1], nrestarts = NR1 + 1}};
        {false, NR1, R1} ->
            {terminate, State#state{restarts = R1, nrestarts = NR1}}
    end.

can_restart(_, _, [], Acc, NR) ->
    {true, NR, lists:reverse(Acc)};
can_restart(_, Threshold, [Restart|_], Acc, NR) when Restart < Threshold ->
    {true, NR, lists:reverse(Acc)};
can_restart(0, _, [_|_], Acc, NR) ->
    {false, NR, lists:reverse(Acc)};
can_restart(N, Threshold, [Restart|Restarts], Acc, NR) ->
    can_restart(N - 1, Threshold, Restarts, [Restart|Acc], NR + 1).

purge_restarts(#state{period = P, restarts = [R|_]} = State) ->
    case erlang:monotonic_time(second) - P of
	Threshold when R < Threshold ->
	    State#state{restarts = [], nrestarts = 0};
	_ ->
	    State
    end;
purge_restarts(State) ->
    State.

report_progress(_Child, _SupName, _Report) -> ok.

report_error(_Error, _Reason, _Child, _SupName) -> ok.
report_unexpected(_Msg) -> ok.
format_log(Report) -> Report.
format_log(Report, _Opts) -> Report.

dyn_size(#state{dynamics = {_Kind,Db}}) ->
    map_size(Db).

dyn_erase(Pid,#state{dynamics={Kind,Db}}=State) ->
    State#state{dynamics={Kind,maps:remove(Pid,Db)}}.

dyn_store(Pid,Args,#state{dynamics={Kind,Db}}=State) ->
    case Kind of
        mapsets ->

            State#state{dynamics={mapsets,Db#{Pid => []}}};
        maps ->

            State#state{dynamics={maps,Db#{Pid => Args}}}
    end.

dyn_fold(Fun,Init,#state{dynamics={_Kind,Db}}) ->
    maps:fold(fun(Pid,_,Acc) -> Fun(Pid,Acc) end, Init, Db).

dyn_map(Fun, #state{dynamics={_Kind,Db}}) ->
    lists:map(Fun, maps:keys(Db)).

dyn_exists(Pid, #state{dynamics={_Kind, Db}}) ->
    is_map_key(Pid, Db).

dyn_args(_Pid, #state{dynamics={mapsets, _Db}}) ->
    {ok,undefined};
dyn_args(Pid, #state{dynamics={maps, Db}}) ->
    maps:find(Pid, Db).

dyn_init(State) ->
    dyn_init(get_dynamic_child(State),State).

dyn_init(Child,State) when (Child#child.restart_type =:= temporary) ->
    State#state{dynamics={mapsets,maps:new()}};
dyn_init(_Child,State) ->
    State#state{dynamics={maps,maps:new()}}.
