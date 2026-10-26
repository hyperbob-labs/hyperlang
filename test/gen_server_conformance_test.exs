defmodule GenServerConformanceTest do
  use ExUnit.Case, async: false

  @resolver_key :guest_msg_resolver
  @spawn_hook_key :guest_spawn_hook
  @name_hook_key :guest_name_hook
  @monitor_hook_key :guest_monitor_hook
  @link_hook_key :guest_link_hook
  @unset {__MODULE__, :unset}

  @manifest %{
    capabilities: %{gen_server: true},
    terms: %{
      public: :erlang,
      allowed_atoms: [
        :already_seen,
        :boom,
        :boot,
        :call,
        :call_reply,
        :cast,
        :cast_ordering,
        :changed,
        :code_changed,
        :continue,
        :crash,
        :crashed,
        :down,
        :dropped,
        :error,
        :events,
        :exit,
        :explicit_reply,
        :get,
        :got,
        :ignore,
        :infinity,
        :init,
        :init_ack,
        :info,
        :later,
        :late,
        :module,
        :named_server,
        :normal,
        :ok,
        :ping,
        :running,
        :slow,
        :stop,
        :stop_call,
        :stop_reason,
        :stopped,
        :terminate,
        :timeout,
        :unexpected,
        :active,
        :any_significant,
        :brutal_kill,
        :child,
        :child2,
        :one_for_all,
        :one_for_one,
        :permanent,
        :rest_for_one,
        :restarted,
        :simple_one_for_one,
        :specs,
        :start_link,
        :supervisor,
        :temporary,
        :transient,
        :undefined,
        :worker,
        :workers,
        :supervisors,
        :validate_transient,
        :validate_significant,
        :init_failure,
        :max_intensity,
        :shutdown,
        :bad_init,
        :fail,
        :significant,
        :s,
        :t,
        :state_functions,
        :handle_event_function,
        :state_enter,
        :event_clear,
        :state_survive,
        :state_clear,
        :generic_fire,
        :generic_cancel,
        :postpone,
        :next_order,
        :reply_single,
        :reply_multi,
        :reply,
        :call_timeout,
        :stop_callback,
        :crash_callback,
        :single,
        :first,
        :second,
        :one,
        :two,
        :retried,
        :fired,
        :named,
        :locked,
        :open,
        :state,
        :pulse,
        :arm_generic,
        :cancel_generic,
        :unlock,
        :order,
        :repeat,
        :count,
        :hold,
        :release,
        :never,
        :mode,
        :add_delete,
        :notify_order,
        :sync_notify,
        :call_handler,
        :crash_containment,
        :sup_notifications,
        :swap_handler,
        :which_handlers,
        :handler_ids,
        :stop_manager,
        :a,
        :b,
        :good,
        :bad,
        :hello,
        :left,
        :right,
        :handoff,
        :delete,
        :swap,
        :boom,
        :event,
        :event_handler,
        :gen_event_EXIT,
        :awaited,
        :start_fun,
        :start_mfa,
        :start_link_fun,
        :start_link_mfa
      ]
    },
    modules: %{enabled: true},
    filesystem: %{enabled: true, source_compile: true},
    limits: %{wall_ms: 2_000, max_source_bytes: 120_000}
  }

  defmodule HostCounter do
    @behaviour :gen_server

    def start(args \\ 0), do: :gen_server.start(__MODULE__, args, [])

    def start_named(args \\ 0),
      do: :gen_server.start({:local, :named_server}, __MODULE__, args, [])

    @impl true
    def init({:agent, agent, value}) do
      Agent.update(agent, &(&1 ++ [{:init, value}]))
      {:ok, {:agent, agent, value}}
    end

    def init({:stop, reason}), do: {:stop, reason}
    def init(:ignore), do: :ignore
    def init(value), do: {:ok, value}

    @impl true
    def handle_call(:get, _from, state), do: {:reply, state, state}

    def handle_call(:slow, _from, state) do
      receive do
      after
        50 -> {:reply, :later, state}
      end
    end

    def handle_call(:stop_call, _from, {:agent, agent, value}) do
      {:stop, :stop_reason, :stopped, {:agent, agent, value}}
    end

    def handle_call(:stop_call, _from, state), do: {:stop, :stop_reason, :stopped, state}
    def handle_call(:boom, _from, _state), do: :erlang.error(:crashed)

    @impl true
    def handle_cast(:inc, state), do: {:noreply, state + 1}

    @impl true
    def handle_info(:ping, state), do: {:noreply, {:info, state}}
    def handle_info(_info, state), do: {:noreply, state}

    @impl true
    def terminate(reason, {:agent, agent, value}) do
      Agent.update(agent, &(&1 ++ [{:terminate, reason, value}]))
      :ok
    end

    def terminate(_reason, _state), do: :ok
  end

  setup do
    previous = %{
      @resolver_key => Application.get_env(:hyperlang, @resolver_key, @unset),
      @spawn_hook_key => Application.get_env(:hyperlang, @spawn_hook_key, @unset),
      @name_hook_key => Application.get_env(:hyperlang, @name_hook_key, @unset),
      @monitor_hook_key => Application.get_env(:hyperlang, @monitor_hook_key, @unset),
      @link_hook_key => Application.get_env(:hyperlang, @link_hook_key, @unset)
    }

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          @unset -> Application.delete_env(:hyperlang, key)
          value -> Application.put_env(:hyperlang, key, value)
        end
      end
    end)

    :ok
  end

  test "start/init ack ordering" do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    {:ok, pid} = HostCounter.start({:agent, agent, :init_ack})
    assert Agent.get(agent, & &1) == [{:init, :init_ack}]
    :gen_server.stop(pid)

    source = """
    -module(counter).
    -export([result/1]).

    result(_) ->
      {ok, Server} = gen_server:start(counter, init_ack, []),
      Events = host:events(),
      gen_server:stop(Server),
      Events.

    init(Value) ->
      host:mark({init, Value}),
      {ok, Value}.

    handle_call(get, _From, State) -> {reply, State, State}.
    handle_cast(_Msg, State) -> {noreply, State}.
    terminate(Reason, State) -> host:mark({terminate, Reason, State}), ok.
    """

    assert guest_result(source) == [{:init, :init_ack}]
  end

  test "call reply" do
    {:ok, pid} = HostCounter.start(7)
    assert :gen_server.call(pid, :get) == 7
    :gen_server.stop(pid)

    assert guest_result(counter_source("0 = 0, gen_server:call(Server, get).", "")) == 7
  end

  test "call timeout" do
    {:ok, pid} = HostCounter.start(0)
    assert catch_exit(:gen_server.call(pid, :slow, 1)) |> elem(0) == :timeout
    :gen_server.stop(pid)

    source =
      counter_source(
        """
        try gen_server:call(Server, slow, 1) of
          _ -> got
        catch
          exit:{timeout, _Where} -> timeout
        end.
        """,
        ""
      )

    assert guest_result(source) == :timeout
  end

  test "cast ordering" do
    {:ok, pid} = HostCounter.start(7)
    :ok = :gen_server.cast(pid, :inc)
    :ok = :gen_server.cast(pid, :inc)
    assert :gen_server.call(pid, :get) == 9
    :gen_server.stop(pid)

    source =
      counter_source(
        """
        ok = gen_server:cast(Server, inc),
        ok = gen_server:cast(Server, inc),
        gen_server:call(Server, get).
        """,
        ""
      )

    assert guest_result(source) == 9
  end

  test "handle_info" do
    {:ok, pid} = HostCounter.start(7)
    Kernel.send(pid, :ping)
    assert eventually(fn -> :gen_server.call(pid, :get) == {:info, 7} end)
    :gen_server.stop(pid)

    source =
      counter_source(
        """
        Server ! ping,
        receive after 10 -> ok end,
        gen_server:call(Server, get).
        """,
        """
        handle_info(ping, State) -> {noreply, {info, State}}.
        """
      )

    assert guest_result(source) == {:info, 7}
  end

  test "stop reason invokes terminate" do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    {:ok, pid} = HostCounter.start({:agent, agent, 5})
    assert :gen_server.stop(pid, :stop_reason, :infinity) == :ok
    assert Agent.get(agent, & &1) == [{:init, 5}, {:terminate, :stop_reason, 5}]

    source = """
    -module(counter).
    -export([result/1]).

    result(_) ->
      {ok, Server} = gen_server:start(counter, 5, []),
      ok = gen_server:stop(Server, stop_reason, infinity),
      host:events().

    init(Value) -> {ok, Value}.
    handle_call(get, _From, State) -> {reply, State, State}.
    handle_cast(_Msg, State) -> {noreply, State}.
    terminate(Reason, State) -> host:mark({terminate, Reason, State}), ok.
    """

    assert guest_result(source) == [{:terminate, :stop_reason, 5}]
  end

  test "stop reply return from handle_call invokes terminate" do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    {:ok, pid} = HostCounter.start({:agent, agent, 8})
    assert :gen_server.call(pid, :stop_call) == :stopped
    assert Agent.get(agent, & &1) == [{:init, 8}, {:terminate, :stop_reason, 8}]

    source = """
    -module(counter).
    -export([result/1]).

    result(_) ->
      {ok, Server} = gen_server:start(counter, 8, []),
      stopped = gen_server:call(Server, stop_call),
      host:events().

    init(Value) -> {ok, Value}.
    handle_call(stop_call, _From, State) -> {stop, stop_reason, stopped, State}.
    handle_cast(_Msg, State) -> {noreply, State}.
    terminate(Reason, State) -> host:mark({terminate, Reason, State}), ok.
    """

    assert guest_result(source) == [{:terminate, :stop_reason, 8}]
  end

  test "init stop and ignore" do
    assert HostCounter.start({:stop, :stop_reason}) == {:error, :stop_reason}
    assert HostCounter.start(:ignore) == :ignore

    source = """
    -module(counter).
    -export([result/1]).

    result(_) ->
      {gen_server:start(counter, {stop, stop_reason}, []), gen_server:start(counter, ignore, [])}.

    init({stop, Reason}) -> {stop, Reason};
    init(ignore) -> ignore;
    init(Value) -> {ok, Value}.
    handle_call(get, _From, State) -> {reply, State, State}.
    handle_cast(_Msg, State) -> {noreply, State}.
    handle_info(_Info, State) -> {noreply, State}.
    """

    assert guest_result(source) == {{:error, :stop_reason}, :ignore}
  end

  test "start timeout kills the still-initializing child" do
    source = """
    -module(counter).
    -export([result/1]).

    result(_) ->
      Ret = gen_server:start(counter, slow, [{timeout, 1}]),
      receive after 80 -> ok end,
      {Ret, host:events()}.

    init(slow) ->
      host:mark(init),
      receive after 50 -> ok end,
      host:mark(late),
      {ok, slow}.
    handle_call(get, _From, State) -> {reply, State, State}.
    handle_cast(_Msg, State) -> {noreply, State}.
    handle_info(_Info, State) -> {noreply, State}.
    """

    assert guest_result(source) == {{:error, :timeout}, [:init]}
  end

  test "named start and call by name" do
    {:ok, pid} = HostCounter.start_named(9)
    assert :gen_server.call(:named_server, :get) == 9
    :gen_server.stop(pid)

    source = """
    -module(counter).
    -export([result/1]).

    result(_) ->
      {ok, _Server} = gen_server:start({local, named_server}, counter, 9, []),
      Value = gen_server:call(named_server, get),
      ok = gen_server:stop(named_server),
      Value.

    init(Value) -> {ok, Value}.
    handle_call(get, _From, State) -> {reply, State, State}.
    handle_cast(_Msg, State) -> {noreply, State}.
    handle_info(_Info, State) -> {noreply, State}.
    """

    assert guest_result(source) == 9
  end

  test "crash inside handle_call propagates structurally to caller" do
    {:ok, pid} = HostCounter.start(0)
    assert catch_exit(:gen_server.call(pid, :boom, 100))
    refute Process.alive?(pid)

    source =
      counter_source(
        """
        try gen_server:call(Server, boom, 100) of
          _ -> got
        catch
          exit:{_Cause, {gen_server, call, _Args}} -> crash
        end.
        """,
        ""
      )

    assert guest_result(source) == :crash
  end

  test "unhandled messages are dropped without guest logging surface" do
    {:ok, pid} = HostCounter.start(3)
    Kernel.send(pid, :unexpected)
    assert eventually(fn -> :gen_server.call(pid, :get) == 3 end)
    :gen_server.stop(pid)

    source = """
    -module(counter).
    -export([result/1]).

    result(_) ->
      {ok, Server} = gen_server:start(counter, 3, []),
      Server ! unexpected,
      receive after 10 -> ok end,
      Value = gen_server:call(Server, get),
      gen_server:stop(Server),
      {dropped, Value}.

    init(Value) -> {ok, Value}.
    handle_call(get, _From, State) -> {reply, State, State}.
    handle_cast(_Msg, State) -> {noreply, State}.
    handle_info(_Info, State) -> {noreply, State}.
    """

    assert guest_result(source) == {:dropped, 3}
  end

  test "handle_continue code_change and format_status dispatch dynamically" do
    source = """
    -module(counter).
    -export([result/1]).

    result(_) ->
      {ok, Server} = gen_server:start(counter, boot, []),
      continued = gen_server:call(Server, get),
      ok = otp_sys:change_code(Server, counter, old, extra),
      {changed, continued, extra} = otp_sys:get_state(Server),
      {status, _Pid, {module, gen_server}, [_PDict, running, _Parent, _Debug, formatted]} =
        otp_sys:get_status(Server),
      ok = gen_server:stop(Server),
      code_changed.

    init(boot) -> {ok, init, {continue, boot}}.
    handle_continue(boot, init) -> {noreply, continued}.
    handle_call(get, _From, State) -> {reply, State, State}.
    handle_cast(_Msg, State) -> {noreply, State}.
    code_change(old, State, extra) -> {ok, {changed, State, extra}}.
    format_status(_Status) -> formatted.
    terminate(_Reason, _State) -> ok.
    """

    assert guest_result(source) == :code_changed
  end

  test "two callback modules run as separate gen_server instances in one snapshot" do
    files = [
      source_file("/src/main.erl", """
      -module(main).
      -export([result/1]).

      result(_) ->
        {ok, A} = gen_server:start(counter_a, 10, []),
        {ok, B} = gen_server:start(counter_b, 20, []),
        Reply = {gen_server:call(A, get), gen_server:call(B, get)},
        ok = gen_server:stop(A),
        ok = gen_server:stop(B),
        Reply.
      """),
      source_file("/src/counter_a.erl", callback_module_source("counter_a")),
      source_file("/src/counter_b.erl", callback_module_source("counter_b"))
    ]

    assert guest_result(files, "/src/main.erl") == {10, 20}
  end

  test "callback module calls another snapshot module from handle_call" do
    files = [
      source_file("/src/main.erl", """
      -module(main).
      -export([result/1]).

      result(_) ->
        {ok, Server} = gen_server:start(counter, 21, []),
        Reply = gen_server:call(Server, get),
        ok = gen_server:stop(Server),
        Reply.
      """),
      source_file("/src/counter.erl", """
      -module(counter).
      init(Value) -> {ok, Value}.
      handle_call(get, _From, State) -> {reply, helper:double(State), State}.
      handle_cast(_Msg, State) -> {noreply, State}.
      terminate(_Reason, _State) -> ok.
      """),
      source_file("/src/helper.erl", """
      -module(helper).
      double(N) -> N * 2.
      """)
    ]

    assert guest_result(files, "/src/main.erl") == 42
  end

  test "capability off leaves gen_server absent and calls rejected" do
    files = [
      source_file("/src/counter.erl", """
      -module(counter).
      -export([result/1]).
      result(_) -> gen_server:start(counter, 0, []).
      init(Value) -> {ok, Value}.
      handle_call(get, _From, State) -> {reply, State, State}.
      handle_cast(_Msg, State) -> {noreply, State}.
      """)
    ]

    manifest = put_in(@manifest, [:capabilities, :gen_server], false)

    assert {:error, [%{message: message} | _]} =
             compile_guest(files, "/src/counter.erl", manifest)

    assert message =~ "gen_server:start/3"
  end

  test "snapshot cannot declare injected gen_server module name" do
    files = [
      source_file("/src/gen_server.erl", """
      -module(gen_server).
      -export([result/1]).
      result(_) -> ok.
      """)
    ]

    assert {:error, [%{message: message, details: %{module: "gen_server"}} | _]} =
             compile_guest(files, "/src/gen_server.erl", @manifest)

    assert message =~ "collides"
  end

  test "snapshot cannot declare the renamed injected otp_sys module name" do
    files = [
      source_file("/src/otp_sys.erl", """
      -module(otp_sys).
      -export([result/1]).
      result(_) -> ok.
      """)
    ]

    assert {:error, [%{message: message, details: %{module: "otp_sys"}} | _]} =
             compile_guest(files, "/src/otp_sys.erl", @manifest)

    assert message =~ "collides"
  end

  defp counter_source(result_expr, extra_callbacks) do
    """
    -module(counter).
    -export([result/1]).

    result(_) ->
      {ok, Server} = gen_server:start(counter, 7, []),
      #{result_expr}

    init(Value) -> {ok, Value}.
    handle_call(get, _From, State) -> {reply, State, State};
    handle_call(slow, _From, State) -> receive after 50 -> {reply, later, State} end;
    handle_call(boom, _From, _State) -> erlang:error(crashed).
    handle_cast(inc, State) -> {noreply, State + 1};
    handle_cast(_Msg, State) -> {noreply, State}.
    #{extra_callbacks}
    """
  end

  defp callback_module_source(module) do
    """
    -module(#{module}).
    init(Value) -> {ok, Value}.
    handle_call(get, _From, State) -> {reply, State, State}.
    handle_cast(_Msg, State) -> {noreply, State}.
    terminate(_Reason, _State) -> ok.
    """
  end

  defp guest_result(source) when is_binary(source) do
    assert {:ok, result, %{stdout: []}} = guest_eval(source)
    result
  end

  def guest_result(files, entry) when is_list(files) do
    assert {:ok, result, %{stdout: []}} = guest_eval(files, entry)
    result
  end

  def guest_result(files, entry, input) when is_list(files) do
    assert {:ok, result, %{stdout: []}} = guest_eval(files, entry, input)
    result
  end

  def guest_eval(source, entry \\ nil, input \\ :ok)

  def guest_eval(source, nil, input) when is_binary(source) do
    module = source_module(source)
    guest_eval([source_file("/src/#{module}.erl", source)], "/src/#{module}.erl", input)
  end

  def guest_eval(files, entry, input) when is_list(files) and is_binary(entry) do
    cleanup_fake_kernel = Hyperlang.FakeGuestKernel.install()
    {:ok, events} = Agent.start_link(fn -> [] end)

    host = %{
      "host" => %{
        mark: fn event ->
          Agent.update(events, &(&1 ++ [event]))
          :ok
        end,
        events: fn -> Agent.get(events, & &1) end
      }
    }

    manifest =
      @manifest
      |> Map.put(:bindings, host)
      |> put_in([:modules, :guest_modules], source_modules(files))
      |> put_in([:filesystem, :mounts], [
        %{
          virtual: "/src",
          backend: "memory",
          mode: :memory,
          allow: [:read],
          files: files
        }
      ])

    result =
      case compile_guest(files, entry, manifest) do
        {:ok, program} ->
          try do
            Hyperlang.Test.run(program, :entry, [input], bindings: host)
          after
            if Process.alive?(events), do: Agent.stop(events)
          end

        {:error, errors} ->
          if Process.alive?(events), do: Agent.stop(events)
          {:error, errors}
      end

    cleanup_fake_kernel.()
    result
  end

  defp compile_guest(files, entry, manifest) do
    manifest =
      manifest
      |> put_in([:modules, :guest_modules], source_modules(files))
      |> put_in([:filesystem, :mounts], [
        %{
          virtual: "/src",
          backend: "memory",
          mode: :memory,
          allow: [:read],
          files: files
        }
      ])

    {:ok, normalized} = Hyperlang.Manifest.normalize(Map.delete(manifest, :bindings))
    {:ok, handle} = Hyperlang.Filesystem.start(normalized.filesystem)

    try do
      Hyperlang.DoorTestSupport.build_from_filesystem(
        handle,
        %{entry: entry, sources: Enum.map(files, & &1.path)},
        manifest
      )
    after
      Hyperlang.Filesystem.stop(handle)
    end
  end

  def source_file(path, content), do: %{path: path, content: content}

  defp source_module(source) do
    [_, module] = Regex.run(~r/-module\(([a-z][A-Za-z0-9_@]*)\)\./, source)
    module
  end

  defp source_modules(files) do
    Enum.flat_map(files, fn
      %{path: path, content: content} when is_binary(path) ->
        if Path.extname(path) == ".ex" do
          []
        else
          [source_module(content)]
        end
    end)
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
