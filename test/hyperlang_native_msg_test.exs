defmodule HyperlangNativeMsgTest do
  use ExUnit.Case, async: false

  @resolver_key :guest_msg_resolver
  @spawn_hook_key :guest_spawn_hook
  @name_hook_key :guest_name_hook
  @monitor_hook_key :guest_monitor_hook
  @link_hook_key :guest_link_hook
  @timer_quota_key :guest_timer_max_outstanding
  @unset {__MODULE__, :unset}

  @manifest %{
    terms: %{
      public: :erlang,
      allowed_atoms: [
        :alpha,
        :anon,
        :custom_from,
        :done,
        :down,
        :flushed,
        :forbidden_term,
        :get,
        :got,
        :inc,
        :inner,
        :links,
        :mailbox_quota_exceeded,
        :matched,
        :named,
        :no_msg_policy,
        :no_spawn_policy,
        :no_policy,
        :error,
        :ok,
        :outer,
        :payload,
        :raw_kernel,
        :self_target,
        :stop,
        :stopped,
        :target,
        :timeout,
        :tuple_resolver
      ]
    },
    limits: %{wall_ms: 1_000}
  }

  defmodule TupleResolver do
    def resolve(_target, _ctx), do: {:ok, self(), %{sender_ctx: :tuple_resolver}}
  end

  defmodule TupleSpawnHook do
    def spawn(fun, _ctx) do
      Kernel.spawn(fun)
      {:ok, 44}
    end
  end

  defmodule HostMeteredSpawnHook do
    # A host that places every child in its OWN Hyperlang.Limits group installs
    # the spawn hook with `%{host_metered?: true}`; the test parent registers
    # itself under this key to observe the child.
    def spawn(fun, _ctx) do
      pid = Kernel.spawn(fun)
      Kernel.send(:persistent_term.get({__MODULE__, :observer}), {:child, pid})
      {:ok, 9, %{pid: pid}}
    end
  end

  setup do
    previous = %{
      @resolver_key => Application.get_env(:hyperlang, @resolver_key, @unset),
      @spawn_hook_key => Application.get_env(:hyperlang, @spawn_hook_key, @unset),
      @name_hook_key => Application.get_env(:hyperlang, @name_hook_key, @unset),
      @monitor_hook_key => Application.get_env(:hyperlang, @monitor_hook_key, @unset),
      @link_hook_key => Application.get_env(:hyperlang, @link_hook_key, @unset),
      @timer_quota_key => Application.get_env(:hyperlang, @timer_quota_key, @unset)
    }

    Enum.each(Map.keys(previous), &Application.delete_env(:hyperlang, &1))

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

  test "manifest limits accept and round-trip native spawn watchdog fields" do
    assert {:ok, manifest} =
             Hyperlang.Manifest.normalize(%{
               limits: %{
                 max_heap_words: 123_456,
                 ceiling: 1_000_000,
                 rate: %{quota: 10_000, period_ms: 100},
                 max_procs: 8
               }
             })

    assert manifest.limits.max_heap_words == 123_456
    assert manifest.limits.ceiling == 1_000_000
    assert manifest.limits.rate == %{quota: 10_000, period_ms: 100}
    assert manifest.limits.max_procs == 8

    public = Hyperlang.Manifest.public_manifest(manifest)
    assert public.limits.max_heap_words == 123_456
    assert public.limits.ceiling == 1_000_000
    assert public.limits.rate == %{quota: 10_000, period_ms: 100}
    assert public.limits.max_procs == 8

    assert {:ok, default_manifest} = Hyperlang.Manifest.normalize(%{})
    assert is_nil(default_manifest.limits.max_heap_words)
    assert is_nil(default_manifest.limits.max_procs)
  end

  test "send expression returns the sent message and receive sees the envelope payload" do
    install_self_resolver()

    source = """
    result(_) ->
      Msg = {payload, 42},
      Value = target ! Msg,
      Got =
        receive
          {payload, N} -> {payload, N}
        after 100 -> timeout
        end,
      {Value, Got}.
    """

    assert eval_result(source) == {{:payload, 42}, {:payload, 42}}
  end

  test "bare raw mailbox messages are invisible to guest receive and remain queued" do
    install_self_resolver()

    manifest =
      @manifest

    host = %{
      "host" => %{
        inject_raw: fn ->
          Kernel.send(self(), :raw_kernel)
          :ok
        end,
        raw_present: fn ->
          {:messages, messages} = Process.info(self(), :messages)
          Enum.member?(messages, :raw_kernel)
        end
      }
    }

    source = """
    result(_) ->
      ok = host:inject_raw(),
      target ! {payload, 7},
      Received =
        receive
          {payload, N} -> N
        after 100 -> timeout
        end,
      {Received, host:raw_present()}.
    """

    assert eval_result(source, :ok, manifest, host) == {7, true}
  end

  test "receive after fires when no envelope matches" do
    source = """
    result(_) ->
      receive
        {payload, _N} -> matched
      after 0 -> timeout
      end.
    """

    assert eval_result(source) == :timeout
  end

  test "bindings guards nested receive and receive inside named and anonymous funs are preserved" do
    install_self_resolver()

    source = """
    result(_) ->
      Target = target,
      Target ! {outer, 3},
      Outer =
        receive
          {outer, X} when X > 2 ->
            Target ! {inner, X + 1},
            receive
              {inner, Y} when Y =:= 4 -> Y
            after 100 -> timeout
            end
        after 100 -> timeout
        end,
      Named =
        fun Loop(0) -> done;
            Loop(N) ->
              Target ! {named, N},
              receive
                {named, N} -> Loop(N - 1)
              after 100 -> timeout
              end
        end,
      Anon =
        fun(N) ->
          Target ! {anon, N},
          receive
            {anon, V} when V =:= N -> V
          after 100 -> timeout
          end
        end,
      {Outer, Named(1), Anon(9)}.
    """

    assert eval_result(source) == {4, :done, 9}
  end

  test "resolver hook fun and MFA forms are honored and missing resolver fails closed" do
    parent = self()

    Application.put_env(:hyperlang, @resolver_key, fn target, ctx ->
      Kernel.send(parent, {:resolver_called, target, ctx})
      {:ok, self(), %{sender_ctx: :custom_from}}
    end)

    assert :hyperlang_msg.send(:target, :payload) == :payload
    assert_receive {:resolver_called, :target, %{pid: pid}} when is_pid(pid)
    assert_receive {:"$hyperlang_msg", :custom_from, :payload}

    Application.put_env(:hyperlang, @resolver_key, {TupleResolver, :resolve})
    assert :hyperlang_msg.send(:target, :payload) == :payload
    assert_receive {:"$hyperlang_msg", :tuple_resolver, :payload}

    Application.delete_env(:hyperlang, @resolver_key)

    source = """
    result(_) -> target ! payload.
    """

    # Uncaught guest error surfaces as a runtime eval error (in-guest it is
    # catchable like any erlang:error).
    {:ok, program} = Hyperlang.Test.program(source, @manifest)

    assert {:error, %{category: :runtime, details: %{"reason" => reason}}} =
             Hyperlang.Test.run(program, :entry, [:ok])

    assert reason =~ "no_msg_policy"
  end

  test "payload rejects pids refs ports and funs at depth before delivery" do
    install_self_resolver()
    port = Port.open({:spawn, "cat"}, [:binary])

    carriers = [
      self(),
      make_ref(),
      port,
      fn -> :ok end
    ]

    try do
      for carrier <- carriers do
        assert {:hyperlang_send, :forbidden_term} =
                 catch_error(:hyperlang_msg.send(:target, {:payload, [%{nested: carrier}]}))
      end
    after
      if Port.info(port), do: Port.close(port)
      flush_port(port)
    end

    refute_received {:"$hyperlang_msg", _from, _msg}
  end

  test "mailbox quota rejects over quota sends without dropping" do
    receiver =
      spawn(fn ->
        receive do
          :stop -> :ok
        after
          5_000 -> :ok
        end
      end)

    Kernel.send(receiver, :quota_fill)

    Application.put_env(:hyperlang, @resolver_key, fn _target, _ctx ->
      {:ok, receiver, %{max_mailbox: 1}}
    end)

    assert {:hyperlang_send, :mailbox_quota_exceeded} =
             catch_error(:hyperlang_msg.send(:target, :payload))

    assert Process.info(receiver, :message_queue_len) == {:message_queue_len, 1}
    Kernel.send(receiver, :stop)
  end

  test "guest source cannot construct the reserved message envelope atom" do
    for source <- [
          "'$hyperlang_msg'.",
          "{'$hyperlang_msg', from, payload}.",
          "[{payload, ['$hyperlang_msg']}].",
          "target ! {'$hyperlang_msg', from, payload}."
        ] do
      assert {:error, [%{category: :verify, message: message}]} =
               Hyperlang.Test.program(source, @manifest)

      assert message =~ "reserved Hyperlang internal name"
    end
  end

  test "spawn expression fails closed without a policy hook" do
    source = """
    result(_) ->
      spawn(fun() -> ok end).
    """

    {:ok, program} = Hyperlang.Test.program(source, @manifest)

    assert {:error, %{category: :runtime, details: %{"reason" => reason}}} =
             Hyperlang.Test.run(program, :entry, [:ok])

    assert reason =~ "no_spawn_policy"
  end

  test "spawn hook success returns the carrier expression value" do
    parent = self()

    Application.put_env(:hyperlang, @spawn_hook_key, fn fun, ctx ->
      Kernel.send(parent, {:spawn_called, is_function(fun, 0), ctx})
      Kernel.spawn(fun)
      {:ok, 1234}
    end)

    source = """
    result(_) ->
      spawn(fun() -> ok end).
    """

    assert eval_result(source) == 1234
    assert_receive {:spawn_called, true, %{pid: pid}} when is_pid(pid)

    Application.put_env(:hyperlang, @spawn_hook_key, {TupleSpawnHook, :spawn})
    assert eval_result(source) == 44
  end

  test "spawn hook error raises a guest-catchable hyperlang_spawn error" do
    Application.put_env(:hyperlang, @spawn_hook_key, fn _fun, _ctx -> {:error, :denied} end)

    assert {:hyperlang_spawn, :denied} = catch_error(:hyperlang_msg.spawn(fn -> :ok end))
  end

  test "name hook fails closed, receives source atom names, and errors raise hyperlang_name" do
    source = """
    result(_) ->
      register(service_name, 1234),
      Found = whereis(service_name),
      unregister(service_name),
      Found.
    """

    {:ok, program} = Hyperlang.Test.program(source, @manifest)

    assert {:error, %{category: :runtime, details: %{"reason" => reason}}} =
             Hyperlang.Test.run(program, :entry, [:ok])

    assert reason =~ "hyperlang_name"
    assert reason =~ "no_policy"

    parent = self()

    Application.put_env(:hyperlang, @name_hook_key, fn op, arg ->
      Kernel.send(parent, {:name_hook, op, arg})

      case {op, arg} do
        {:register, {"service_name", 1234}} -> {:ok, true}
        {:whereis, "service_name"} -> {:ok, 1234}
        {:unregister, "service_name"} -> {:ok, true}
      end
    end)

    assert eval_result(source) == 1234
    assert_receive {:name_hook, :register, {"service_name", 1234}}
    assert_receive {:name_hook, :whereis, "service_name"}
    assert_receive {:name_hook, :unregister, "service_name"}

    Application.put_env(:hyperlang, @name_hook_key, fn :register, _arg ->
      {:error, :name_taken}
    end)

    assert {:hyperlang_name, :name_taken} = catch_error(:hyperlang_msg.register(:service_name, 1))
  end

  test "whereis returns carrier or undefined through the name hook" do
    Application.put_env(:hyperlang, @name_hook_key, fn
      :whereis, "known_name" -> {:ok, 55}
      :whereis, "missing_name" -> {:ok, :undefined}
    end)

    source = """
    result(_) ->
      {whereis(known_name), whereis(missing_name)}.
    """

    assert eval_result(source) == {55, :undefined}
  end

  test "monitor hook fails closed, returns refs, and demonitor flush drains DOWN" do
    source = """
    result(_) ->
      Ref = monitor(process, 4321),
      ok = host:inject_down(Ref),
      true = demonitor(Ref, [flush]),
      receive
        {'DOWN', Ref, process, 4321, <<"noproc">>} -> got
      after 0 -> flushed
      end.
    """

    manifest =
      @manifest

    host = %{
      "host" => %{
        inject_down: fn ref ->
          Kernel.send(
            self(),
            {:"$hyperlang_msg", :kernel, {:DOWN, ref, :process, 4321, <<"noproc">>}}
          )

          :ok
        end
      }
    }

    {:ok, program} = Hyperlang.Test.program(source, Map.put(manifest, :bindings, host))

    assert {:error, %{category: :runtime, details: %{"reason" => reason}}} =
             Hyperlang.Test.run(program, :entry, [:ok], bindings: host)

    assert reason =~ "hyperlang_monitor"
    assert reason =~ "no_policy"

    Application.put_env(:hyperlang, @monitor_hook_key, fn
      :monitor, 4321 -> {:ok, 9876}
      :demonitor, 9876 -> {:ok, true}
    end)

    assert eval_result(source, :ok, manifest, host) == :flushed

    Application.put_env(:hyperlang, @monitor_hook_key, fn :monitor, _arg ->
      {:error, :noproc}
    end)

    assert {:hyperlang_monitor, :noproc} = catch_error(:hyperlang_msg.monitor(4321))
  end

  test "spawn_monitor lowers to spawn then monitor and returns carrier ref tuple" do
    parent = self()

    Application.put_env(:hyperlang, @spawn_hook_key, fn fun, _ctx ->
      Kernel.send(parent, {:spawn_monitor_order, :spawn, is_function(fun, 0)})
      Kernel.spawn(fun)
      {:ok, 2222}
    end)

    Application.put_env(:hyperlang, @monitor_hook_key, fn :monitor, 2222 ->
      Kernel.send(parent, {:spawn_monitor_order, :monitor, 2222})
      {:ok, 3333}
    end)

    source = """
    result(_) ->
      spawn_monitor(fun() -> ok end).
    """

    assert eval_result(source) == {2222, 3333}
    assert_receive {:spawn_monitor_order, :spawn, true}
    assert_receive {:spawn_monitor_order, :monitor, 2222}
  end

  test "make_ref shares the monitor hook ref space and preserves match semantics" do
    {:ok, counter} = Agent.start_link(fn -> 10_000 end)

    Application.put_env(:hyperlang, @monitor_hook_key, fn :make_ref, nil ->
      Agent.get_and_update(counter, fn ref -> {{:ok, ref}, ref + 1} end)
    end)

    source = """
    result(_) ->
      A = make_ref(),
      B = erlang:make_ref(),
      {A =:= A, A =:= B, A, B}.
    """

    assert eval_result(source) == {true, false, 10_000, 10_001}
  end

  test "make_ref and is_process_alive fail closed and liveness accepts only pid carriers" do
    assert {:hyperlang_monitor, :no_policy} = catch_error(:hyperlang_msg.make_ref())
    assert {:hyperlang_monitor, :no_policy} = catch_error(:hyperlang_msg.is_process_alive(42))
    assert :badarg = catch_error(:hyperlang_msg.is_process_alive(:not_a_pid))

    Application.put_env(:hyperlang, @monitor_hook_key, fn
      :alive?, 42 -> {:ok, true}
      :alive?, 43 -> {:ok, false}
    end)

    assert eval_result("result(_) -> {is_process_alive(42), erlang:is_process_alive(43)}.") ==
             {true, false}
  end

  test "restricted process_info self links lowers through link hook" do
    Application.put_env(:hyperlang, @link_hook_key, fn :links, nil -> {:ok, [11, 22]} end)

    assert eval_result("result(_) -> process_info(self(), links).") == {:links, [11, 22]}

    for source <- [
          "result(_) -> process_info(11, links).",
          "result(_) -> process_info(self(), status)."
        ] do
      assert {:error, [%{message: message} | _]} =
               Hyperlang.Test.program(source, @manifest)

      assert message =~ "process_info: only (self(), links) is supported"
    end
  end

  test "link hook fails closed, receives targets, and errors raise hyperlang_link" do
    source = """
    result(_) ->
      true = link(4321),
      true = erlang:link(service_name),
      true = unlink(4321),
      true = erlang:unlink(<<"service_name">>),
      ok.
    """

    {:ok, program} = Hyperlang.Test.program(source, @manifest)

    assert {:error, %{category: :runtime, details: %{"reason" => reason}}} =
             Hyperlang.Test.run(program, :entry, [:ok])

    assert reason =~ "hyperlang_link"
    assert reason =~ "no_policy"

    parent = self()

    Application.put_env(:hyperlang, @link_hook_key, fn op, arg ->
      Kernel.send(parent, {:link_hook, op, arg})

      case op do
        op when op in [:link, :unlink] -> {:ok, true}
      end
    end)

    assert eval_result(source) == :ok
    assert_receive {:link_hook, :link, 4321}
    assert_receive {:link_hook, :link, "service_name"}
    assert_receive {:link_hook, :unlink, 4321}
    assert_receive {:link_hook, :unlink, "service_name"}

    Application.put_env(:hyperlang, @link_hook_key, fn :link, _arg ->
      {:error, :noproc}
    end)

    assert {:hyperlang_link, :noproc} = catch_error(:hyperlang_msg.link(4321))
  end

  test "process_flag trap_exit lowers to the link hook and returns previous value" do
    parent = self()

    Application.put_env(:hyperlang, @link_hook_key, fn :trap_exit, bool ->
      Kernel.send(parent, {:link_hook, :trap_exit, bool})
      {:ok, false}
    end)

    source = """
    result(_) ->
      process_flag(trap_exit, true).
    """

    assert eval_result(source) == false
    assert_receive {:link_hook, :trap_exit, true}
  end

  test "exit/2 lowers through the link hook with pid and name targets" do
    parent = self()

    Application.put_env(:hyperlang, @link_hook_key, fn :exit_signal, arg ->
      Kernel.send(parent, {:link_hook, :exit_signal, arg})
      {:ok, true}
    end)

    source = """
    result(_) ->
      true = exit(4321, normal),
      true = erlang:exit(service_name, {payload, 7}),
      ok.
    """

    assert eval_result(source) == :ok
    assert_receive {:link_hook, :exit_signal, {4321, :normal}}
    assert_receive {:link_hook, :exit_signal, {"service_name", {:payload, 7}}}

    Application.put_env(:hyperlang, @link_hook_key, fn :exit_signal, _arg ->
      {:error, :noproc}
    end)

    assert {:hyperlang_link, :noproc} = catch_error(:hyperlang_msg.exit(4321, :normal))
  end

  test "native timers deliver envelopes, expose integer refs, and cancel" do
    parent = self()
    {:ok, target_agent} = Agent.start_link(fn -> parent end)
    on_exit(fn -> if Process.alive?(target_agent), do: Agent.stop(target_agent) end)

    Application.put_env(:hyperlang, @resolver_key, fn _target, _ctx ->
      {:ok, Agent.get(target_agent, & &1), %{sender_ctx: :custom_from}}
    end)

    send_ref = :hyperlang_msg.send_after(5, :target, :payload)
    assert is_integer(send_ref)
    assert_receive {:"$hyperlang_msg", :custom_from, :payload}, 200

    manifest =
      @manifest

    host = %{
      "host" => %{
        remember_target: fn ->
          caller = self()
          Agent.update(target_agent, fn _pid -> caller end)
          :ok
        end
      }
    }

    source = """
    result(_) ->
      ok = host:remember_target(),
      Ref = erlang:start_timer(5, target, payload),
      Shape =
        receive
          {timeout, Ref, payload} -> is_integer(Ref)
        after 100 -> timeout
        end,
      CancelRef = erlang:start_timer(100, target, payload),
      Remaining = erlang:cancel_timer(CancelRef),
      Again = erlang:cancel_timer(CancelRef),
      {Shape, is_integer(Remaining) orelse Remaining =:= false, Again}.
    """

    assert eval_result(source, :ok, manifest, host) == {true, true, false}
  end

  test "timer survives setter death within its host scope and drops for a dead target" do
    parent = self()
    scope = Hyperlang.Scope.current()
    :ok = Hyperlang.Scope.ensure(scope, parent)

    Application.put_env(:hyperlang, @resolver_key, fn
      target, _ctx when target in [:live, "live"] ->
        {:ok, parent, %{sender_ctx: :custom_from}}

      target, _ctx when target in [:target, "target"] ->
        case Process.get(:timer_target_pid) do
          pid when is_pid(pid) ->
            if Process.alive?(pid),
              do: {:ok, pid, %{sender_ctx: :custom_from}},
              else: {:error, :noproc}

          _ ->
            {:error, :noproc}
        end
    end)

    setter =
      Kernel.spawn(fn ->
        :hyperlang_msg.with_context(%{scope: scope, scope_owner: parent}, fn ->
          _ = :hyperlang_msg.send_after(10, :live, :payload)
        end)
      end)

    ref = Process.monitor(setter)
    assert_receive {:DOWN, ^ref, :process, ^setter, _reason}, 200
    assert_receive {:"$hyperlang_msg", :custom_from, :payload}, 200

    target =
      Kernel.spawn(fn ->
        receive do
          {:"$hyperlang_msg", from, payload} ->
            Kernel.send(parent, {:timer_target_received, from, payload})
        after
          200 -> :ok
        end
      end)

    Process.put(:timer_target_pid, target)
    _ = :hyperlang_msg.send_after(25, :target, :payload)
    target_ref = Process.monitor(target)
    Process.exit(target, :kill)
    assert_receive {:DOWN, ^target_ref, :process, ^target, _reason}, 200
    refute_receive {:timer_target_received, _from, _payload}, 100
    Process.delete(:timer_target_pid)
  end

  test "timer quota fails closed and raw send_after without resolver fails closed" do
    parent = self()

    Application.put_env(:hyperlang, @resolver_key, fn _target, _ctx ->
      {:ok, parent, %{sender_ctx: :custom_from}}
    end)

    Application.put_env(:hyperlang, @timer_quota_key, 1)
    first = :hyperlang_msg.start_timer(1_000, :target, :payload)
    assert is_integer(first)

    assert {:hyperlang_timer, :timer_quota_exceeded} =
             catch_error(:hyperlang_msg.start_timer(1_000, :target, :payload))

    remaining = :hyperlang_msg.cancel_timer(first)
    assert is_integer(remaining) or remaining == false

    Application.delete_env(:hyperlang, @resolver_key)

    source = """
    result(_) ->
      erlang:send_after(1, target, payload).
    """

    {:ok, program} = Hyperlang.Test.program(source, @manifest)

    assert {:error, %{category: :runtime, details: %{"reason" => reason}}} =
             Hyperlang.Test.run(program, :entry, [:ok])

    assert reason =~ "hyperlang_timer"
    assert reason =~ "no_msg_policy"
  end

  test "timer sleep lowers to the sys facade" do
    source = """
    result(_) ->
      timer:sleep(0).
    """

    assert eval_result(source) == :ok
  end

  test "spawn_link lowers to spawn then link and returns the carrier" do
    parent = self()

    Application.put_env(:hyperlang, @spawn_hook_key, fn fun, _ctx ->
      Kernel.send(parent, {:spawn_link_order, :spawn, is_function(fun, 0)})
      Kernel.spawn(fun)
      {:ok, 2222}
    end)

    Application.put_env(:hyperlang, @link_hook_key, fn :link, 2222 ->
      Kernel.send(parent, {:spawn_link_order, :link, 2222})
      {:ok, true}
    end)

    source = """
    result(_) ->
      spawn_link(fun() -> ok end).
    """

    assert eval_result(source) == 2222
    assert_receive {:spawn_link_order, :spawn, true}
    assert_receive {:spawn_link_order, :link, 2222}
  end

  test "EXIT messages arrive as ordinary guest receive payloads with fixed atoms" do
    manifest =
      @manifest

    host = %{
      "host" => %{
        inject_exit: fn ->
          Kernel.send(self(), {:"$hyperlang_msg", :system, {:EXIT, 44, <<"linked:gone">>}})
          :ok
        end
      }
    }

    source = """
    result(_) ->
      ok = host:inject_exit(),
      receive
        {'EXIT', 44, <<"linked:gone">>} -> got
      after 100 -> timeout
      end.
    """

    assert eval_result(source, :ok, manifest, host) == :got
  end

  test "process_flag rejects non trap_exit flags at compile time" do
    for source <- [
          "result(_) -> process_flag(priority, true).",
          "result(Flag) -> process_flag(Flag, true).",
          "result(_) -> erlang:process_flag(priority, true)."
        ] do
      assert {:error, [%{category: :verify, message: message} | _]} =
               Hyperlang.Test.program(source, @manifest)

      assert message =~ "process_flag/2 only supports trap_exit"
    end
  end

  test "DOWN messages arrive as ordinary guest receive payloads with fixed atoms" do
    manifest =
      @manifest

    host = %{
      "host" => %{
        inject_down: fn ->
          Kernel.send(self(), {:"$hyperlang_msg", :kernel, {:DOWN, 44, :process, 99, <<"gone">>}})
          :ok
        end
      }
    }

    source = """
    result(_) ->
      ok = host:inject_down(),
      receive
        {'DOWN', 44, process, 99, <<"gone">>} -> got
      after 100 -> timeout
      end.
    """

    assert eval_result(source, :ok, manifest, host) == :got
  end

  test "spawn arities above one remain verifier violations" do
    for {source, arity} <- [
          {"result(_) -> spawn(node, fun() -> ok end).", 2},
          {"result(_) -> erlang:spawn(node, fun() -> ok end).", 2},
          {"result(_) -> spawn(m, f, []).", 3},
          {"result(_) -> erlang:spawn(m, f, []).", 3}
        ] do
      assert {:error, [%{category: :verify, message: message}]} =
               Hyperlang.Test.program(source, @manifest)

      assert message =~ "spawn/#{arity}"
    end
  end

  test "max_heap_words sets guest worker heap and on-heap message queue flags" do
    manifest =
      @manifest
      |> put_in([:limits, :max_heap_words], 234_567)

    host = %{
      "host" => %{
        worker_limits: fn ->
          {:max_heap_size, heap} = Process.info(self(), :max_heap_size)
          {:message_queue_data, queue_data} = Process.info(self(), :message_queue_data)

          {
            Map.fetch!(heap, :size),
            Map.fetch!(heap, :kill),
            Map.fetch!(heap, :include_shared_binaries),
            queue_data == :on_heap
          }
        end
      }
    }

    source = """
    result(_) ->
      host:worker_limits().
    """

    assert eval_result(source, :ok, manifest, host) == {234_567, true, true, true}
  end

  test "gen_server facade starts a counter server, calls, casts, and observes stop DOWN" do
    Hyperlang.FakeGuestKernel.install()

    source = """
    -module(counter).
    -export([result/1]).

    result(_) ->
      {ok, Server} = gen_server:start(counter, 0, []),
      0 = gen_server:call(Server, get),
      ok = gen_server:cast(Server, inc),
      1 = gen_server:call(Server, get, 1000),
      Ref = monitor(process, Server),
      stopped = gen_server:call(Server, stop),
      receive
        {'DOWN', Ref, process, Server, <<"normal">>} -> down
      after 1000 -> timeout
      end.

    init(N) -> {ok, N}.

    handle_call(get, _From, State) ->
      {reply, State, State};
    handle_call(stop, _From, State) ->
      {stop, <<"normal">>, stopped, State}.

    handle_cast(inc, State) ->
      {noreply, State + 1}.

    handle_info(_Info, State) ->
      {noreply, State}.
    """

    gen_server_manifest =
      @manifest
      |> put_in([:capabilities], %{gen_server: true})
      |> put_in([:modules], %{enabled: true, guest_modules: ["counter"]})
      |> put_in([:filesystem], %{enabled: true, source_compile: true})
      |> put_in([:limits, :max_source_bytes], 120_000)

    assert eval_snapshot_result(source, :ok, gen_server_manifest) == :down
  end

  test "gen_server facade is rejected without the gen_server capability" do
    source = """
    result(_) -> gen_server:cast(1, ping).
    """

    assert {:error, [%{message: message} | _]} =
             Hyperlang.Test.program(source, @manifest)

    assert message =~ "gen_server"
  end

  test "sandboxed pure-term message traffic matches plain Erlang observable behavior" do
    install_self_resolver()

    source = """
    result(Target) ->
      First = Target ! {alpha, 1},
      Second = Target ! {alpha, 2},
      receive
        {alpha, 1} ->
          receive
            {alpha, N} when N =:= 2 -> {First, Second, N}
          after 100 -> timeout
          end
      after 100 -> timeout
      end.
    """

    sandboxed = eval_result(source, :self_target)
    plain = plain_result(source, self())

    assert sandboxed == plain
  end

  defp install_self_resolver(opts \\ %{}) do
    Application.put_env(:hyperlang, @resolver_key, fn _target, _ctx -> {:ok, self(), opts} end)
  end

  describe "guest child metering" do
    test "a guest child inherits the evaluation group's heap cap and reduction ceiling" do
      parent = self()
      group = Hyperlang.Limits.group(%{ceiling: 50_000})

      Application.put_env(:hyperlang, @spawn_hook_key, fn fun, _ctx ->
        pid = Kernel.spawn(fun)
        Kernel.send(parent, {:child, pid})
        {:ok, 7, %{pid: pid}}
      end)

      child =
        fn ->
          Kernel.send(
            parent,
            {:child_flags, Process.info(self(), :max_heap_size),
             Process.info(self(), :message_queue_data)}
          )

          burn = fn burn -> burn.(burn) end
          burn.(burn)
        end

      context = %{
        limits_group: group,
        limits: %{max_heap_words: 20_000, max_reductions: 50_000}
      }

      assert :hyperlang_msg.with_context(context, fn -> :hyperlang_msg.spawn(child) end) == 7

      assert_receive {:child, child_pid}, 1_000
      ref = Process.monitor(child_pid)

      assert_receive {:child_flags, {:max_heap_size, %{size: 20_000, kill: true}},
                      {:message_queue_data, :on_heap}},
                     1_000

      assert_receive {:DOWN, ^ref, :process, ^child_pid, {:hyperlang_limit, :ceiling}}, 5_000
    end

    test "children register before executing even when a hook omits PID metadata" do
      parent = self()
      group = Hyperlang.Limits.group(%{max_procs: 1, ceiling: 50_000})

      Application.put_env(:hyperlang, @spawn_hook_key, fn fun, _ ->
        pid = Kernel.spawn(fun)
        Kernel.send(parent, {:child, pid})
        {:ok, 7, %{}}
      end)

      child = fn ->
        stat = Hyperlang.Limits.stat(group)
        Kernel.send(parent, {:registered_before_execution, stat.procs})
        burn = fn burn -> burn.(burn) end
        burn.(burn)
      end

      context = %{
        limits_group: group,
        limits: %{max_heap_words: 20_000, max_reductions: 50_000, max_procs: 1}
      }

      assert :hyperlang_msg.with_context(context, fn -> :hyperlang_msg.spawn(child) end) == 7
      assert_receive {:child, pid}
      monitor = Process.monitor(pid)
      assert_receive {:registered_before_execution, 1}
      assert_receive {:DOWN, ^monitor, :process, ^pid, {:hyperlang_limit, :ceiling}}, 1000
      Hyperlang.Limits.delete(group)
    end

    test "a host_metered? spawn hook keeps the eval group away from the child" do
      parent = self()
      group = Hyperlang.Limits.group(%{ceiling: 50_000})
      :persistent_term.put({HostMeteredSpawnHook, :observer}, parent)

      Application.put_env(
        :hyperlang,
        @spawn_hook_key,
        {HostMeteredSpawnHook, :spawn, %{host_metered?: true}}
      )

      child =
        fn ->
          Kernel.send(parent, {:child_flags, Process.info(self(), :max_heap_size)})

          spin = fn spin, n ->
            if n > 0, do: spin.(spin, n - 1), else: Kernel.send(parent, :survived)
          end

          spin.(spin, 2_000_000)
        end

      context = %{
        limits_group: group,
        limits: %{max_heap_words: 20_000, max_reductions: 50_000, max_procs: 0}
      }

      # max_procs 0 would reject an eval-metered spawn outright; a host-metered
      # hook is not admitted, wrapped, attached or counted by the eval group.
      assert :hyperlang_msg.with_context(context, fn -> :hyperlang_msg.spawn(child) end) == 9

      assert_receive {:child, child_pid}, 1_000
      ref = Process.monitor(child_pid)

      assert_receive {:child_flags, {:max_heap_size, %{size: size}}}, 1_000
      refute size == 20_000

      assert_receive :survived, 5_000
      refute_receive {:DOWN, ^ref, :process, ^child_pid, {:hyperlang_limit, _reason}}, 100
      assert Hyperlang.Limits.stat(group).procs == 0
    after
      :persistent_term.erase({HostMeteredSpawnHook, :observer})
    end

    test "max_procs rejects a guest spawn with eagain and the door frees the slots" do
      parent = self()

      Application.put_env(:hyperlang, @spawn_hook_key, fn fun, _ctx ->
        pid = Kernel.spawn(fun)
        Kernel.send(parent, {:child, pid})
        {:ok, :erlang.unique_integer([:positive]), %{pid: pid}}
      end)

      manifest = put_in(@manifest, [:limits], %{wall_ms: 5_000, max_procs: 1})

      one = """
      result(_) ->
        spawn(fun() -> receive after 1000 -> ok end end),
        ok.
      """

      two = """
      result(_) ->
        spawn(fun() -> receive after 1000 -> ok end end),
        spawn(fun() -> receive after 1000 -> ok end end),
        ok.
      """

      {:ok, program} = Hyperlang.Test.program(two, manifest)

      assert {:error, error} = Hyperlang.Test.run(program, :entry, [:ok])
      assert inspect(error) =~ "eagain"

      # The surviving children are killed when the door releases the group, so
      # the next evaluation starts with a full max_procs budget.
      {:ok, program} = Hyperlang.Test.program(one, manifest)

      assert {:ok, :ok, _} = Hyperlang.Test.run(program, :entry, [:ok])
      assert {:ok, :ok, _} = Hyperlang.Test.run(program, :entry, [:ok])
    end
  end

  defp eval_result(source, input \\ :ok, manifest \\ @manifest, bindings \\ %{}) do
    {:ok, program} = Hyperlang.Test.program(source, Map.put(manifest, :bindings, bindings))

    assert {:ok, result, %{stdout: []}} =
             Hyperlang.Test.run(program, :entry, [input], bindings: bindings)

    result
  end

  defp eval_snapshot_result(source, input, manifest) do
    module = source_module(source)
    path = "/src/#{module}.erl"
    files = [%{path: path, content: source}]

    manifest =
      manifest
      |> put_in([:modules, :guest_modules], [module])
      |> put_in([:filesystem, :mounts], [
        %{
          virtual: "/src",
          backend: "memory",
          mode: :memory,
          allow: [:read],
          files: files
        }
      ])

    {:ok, normalized} = Hyperlang.Manifest.normalize(manifest)
    {:ok, handle} = Hyperlang.Filesystem.start(normalized.filesystem)

    try do
      {:ok, program} =
        Hyperlang.DoorTestSupport.build_from_filesystem(
          handle,
          %{entry: path, sources: [path]},
          manifest
        )

      assert {:ok, result, %{stdout: []}} =
               Hyperlang.Test.run(program, :entry, [input])

      result
    after
      Hyperlang.Filesystem.stop(handle)
    end
  end

  defp source_module(source) do
    [_, module] = Regex.run(~r/-module\(([a-z][A-Za-z0-9_@]*)\)\./, source)
    module
  end

  defp plain_result(source, input) do
    module = :"hyperlang_native_msg_plain_#{System.unique_integer([:positive])}"

    forms =
      source
      |> then(&("-module(#{module}).\n-export([result/1]).\n" <> &1))
      |> parse_forms!()

    :code.purge(module)
    :code.delete(module)

    {:ok, ^module, binary, _warnings} =
      :compile.noenv_forms(forms, [:binary, :return_warnings])

    {:module, ^module} = :code.load_binary(module, ~c"hyperlang_native_msg_plain", binary)

    try do
      apply(module, :result, [input])
    after
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
    end
  end

  defp parse_forms!(source) do
    {:ok, tokens, _} = :erl_scan.string(String.to_charlist(source), {1, 1}, [:text])

    tokens
    |> split_forms()
    |> Enum.map(fn form_tokens ->
      {:ok, form} = :erl_parse.parse_form(form_tokens)
      form
    end)
  end

  defp split_forms(tokens) do
    {segments, current} =
      Enum.reduce(tokens, {[], []}, fn token, {segments, current} ->
        current = [token | current]

        if elem(token, 0) == :dot do
          {[Enum.reverse(current) | segments], []}
        else
          {segments, current}
        end
      end)

    segments =
      if current == [] do
        segments
      else
        [Enum.reverse(current) | segments]
      end

    Enum.reverse(segments)
  end

  defp flush_port(port) do
    receive do
      {^port, _message} -> flush_port(port)
    after
      0 -> :ok
    end
  end
end
