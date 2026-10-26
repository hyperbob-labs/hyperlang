defmodule Hyperlang.Isolation.Round3AdmissionTest do
  use ExUnit.Case, async: false
  alias Hyperlang.{Chan, Scope}
  alias Hyperlang.Test, as: Kit

  defmodule HostChildHook do
    def spawn(fun, _context) do
      observer = :persistent_term.get({__MODULE__, :observer})

      pid =
        Kernel.spawn(fn ->
          group = Hyperlang.Limits.group(%{})
          :ok = Hyperlang.Limits.attach(group, self(), %{owner?: true})

          try do
            result = fun.()
            send(observer, {:host_child_finished, self(), result})
          after
            Hyperlang.Limits.delete(group)
          end
        end)

      send(observer, {:host_child, pid})
      {:ok, 99, %{pid: pid}}
    end
  end

  setup do
    old = Application.get_env(:hyperlang, :runtime_concurrency)
    Application.put_env(:hyperlang, :runtime_concurrency, 3)
    scope = make_ref()
    :ok = Scope.configure(scope, %{wait_ms: 10})

    on_exit(fn ->
      Scope.close(scope)

      if old,
        do: Application.put_env(:hyperlang, :runtime_concurrency, old),
        else: Application.delete_env(:hyperlang, :runtime_concurrency)
    end)

    %{scope: scope}
  end

  test "uncontended handoffs reuse one lifetime record and release before host work", %{
    scope: scope
  } do
    Scope.running(scope, fn ->
      [{token, entry}] =
        Scope.runtime_snapshot().runtime_permits
        |> Enum.filter(fn {_, e} -> e.owner == self() end)

      for _ <- 1..100 do
        Scope.blocking(fn -> assert Scope.stats(scope).runnable == 0 end)
      end

      same = Scope.runtime_snapshot().runtime_permits[token]
      assert same.monitor == entry.monitor
      assert same.cell == entry.cell
      assert Scope.stats(scope).runnable == 1
    end)

    assert Scope.stats(scope).runnable == 0
  end

  test "death recovers a slot reserved before the local state commit", %{scope: scope} do
    owner = self()

    pid =
      spawn(fn ->
        Scope.running(scope, fn ->
          Scope.blocking(fn ->
            send(owner, {:journal_ready, self()})
            Process.sleep(:infinity)
          end)
        end)
      end)

    assert_receive {:journal_ready, ^pid}
    snapshot = Scope.runtime_snapshot()
    [{token, entry}] = Enum.filter(snapshot.runtime_permits, fn {_, e} -> e.owner == pid end)
    gate = snapshot.runtime_gate
    row = {1, token, make_ref(), true}
    assert :ets.insert_new(:hyperlang_runtime_slots, row)
    Hyperlang.Scope.Runtime.pause(entry.cell)
    Hyperlang.Scope.Runtime.suspend(gate, entry.cell, token, self())
    assert [] = :ets.lookup(:hyperlang_runtime_slots, 1)
    # Simulate the interrupted insertion occurring after the suspension cleanup.
    assert :ets.insert_new(:hyperlang_runtime_slots, row)
    Process.exit(pid, :kill)
    wait(fn -> not Map.has_key?(Scope.runtime_snapshot().runtime_permits, token) end)
    assert [] = :ets.lookup(:hyperlang_runtime_slots, 1)
    assert Scope.runtime_snapshot().run_count == 0
  end

  test "scope suspension reclaims a reservation interrupted before local commit", %{scope: scope} do
    owner = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        :ok = Scope.attach(scope, self(), :run)

        Scope.running(scope, fn ->
          Scope.blocking(fn ->
            send(owner, {:scope_partial_ready, self()})
            Process.sleep(:infinity)
          end)
        end)
      end)

    assert_receive {:scope_partial_ready, ^pid}
    snapshot = Scope.runtime_snapshot()
    [{token, _entry}] = Enum.filter(snapshot.runtime_permits, fn {_, e} -> e.owner == pid end)
    assert :ets.insert_new(:hyperlang_runtime_slots, {1, token, make_ref(), true})
    :erlang.suspend_process(pid)

    :sys.replace_state(Scope, fn state ->
      state
      |> put_in([:scopes, scope, :members, pid, :suspended?], true)
      |> put_in(
        [:scopes, scope, :suspended_until],
        System.monotonic_time(:microsecond) + 1_000_000
      )
    end)

    generation = snapshot.scopes[scope].generation
    send(Scope, {:sampled, scope, generation, %{}})
    wait(fn -> Scope.runtime_snapshot().run_count == 0 end)
    assert :ets.info(:hyperlang_runtime_slots, :size) == 0
    Scope.close(scope)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1000
  end

  test "receive after zero remains immediate and caller wall expiry preserves its owner", %{
    scope: scope
  } do
    ready =
      Kit.program!("result(_) -> receive never -> 0 after 0 -> 1 end.", %{
        terms: %{public: :erlang}
      })

    assert {:ok, 1, _} = Kit.run(ready, :entry, [nil], policy: %{scope: scope})

    slow =
      Kit.program!("result(_) -> sys:sleep(25), 1.", %{
        sys: %{enabled: true},
        terms: %{public: :erlang}
      })

    owner = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          Kit.run(slow, :entry, [nil],
            policy: %{run_in_caller?: true, wall_ms: 1, max_reductions: nil}
          )

        send(owner, {:expired_caller_returned, self(), result})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:expired_caller_returned, ^pid, {:error, %{category: :timeout}}}, 1000
    assert Process.alive?(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
  end

  test "message policy keeps atom-key precedence and validates quota once" do
    previous = Application.get_env(:hyperlang, :guest_msg_resolver)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hyperlang, :guest_msg_resolver, previous),
        else: Application.delete_env(:hyperlang, :guest_msg_resolver)
    end)

    options = %{
      "max_mailbox" => 0,
      :max_mailbox => nil,
      "sender_ctx" => :wrong_sender,
      :sender_ctx => nil,
      :from => :chosen_sender
    }

    Application.put_env(:hyperlang, :guest_msg_resolver, fn _, _ -> {:ok, self(), options} end)
    assert :hello = :hyperlang_msg.send(:target, :hello)
    assert_receive {:"$hyperlang_msg", :chosen_sender, :hello}

    Application.put_env(:hyperlang, :guest_msg_resolver, fn _, _ ->
      {:ok, self(), %{"max_mailbox" => 1000, "sender_ctx" => :string_sender}}
    end)

    assert :hello = :hyperlang_msg.send(:target, :hello)
    assert_receive {:"$hyperlang_msg", :string_sender, :hello}

    Application.put_env(:hyperlang, :guest_msg_resolver, fn _, _ ->
      {:ok, self(), %{"max_mailbox" => 1000, :max_mailbox => :invalid}}
    end)

    assert {:hyperlang_send, :bad_msg_policy} = catch_error(:hyperlang_msg.send(:target, :hello))
  end

  test "closing a scope kills a runtime executor even without a separate member attachment", %{
    scope: scope
  } do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        Scope.running(scope, fn ->
          send(parent, {:unattached_running, self()})

          receive do
            :stop -> :ok
          end
        end)
      end)

    assert_receive {:unattached_running, ^pid}
    Scope.close(scope)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}

    wait(fn ->
      not Enum.any?(Scope.runtime_snapshot().runtime_permits, fn {_, e} -> e.owner == pid end)
    end)
  end

  test "nine communicating guest stages complete with only two background permits", %{
    scope: scope
  } do
    previous = Application.get_env(:hyperlang, :guest_channel_scope)
    Application.put_env(:hyperlang, :guest_channel_scope, fn -> scope end)
    on_exit(fn -> restore(:guest_channel_scope, previous) end)
    channels = for _ <- 0..9, do: Chan.newchan(scope, 0)

    p =
      Kit.program!("result({In, Out}) -> V = sys:crecv(In), sys:csend(Out, V+1), V.", %{
        sys: %{enabled: true},
        terms: %{public: :erlang}
      })

    tasks =
      for n <- 0..8 do
        {input, _} = Enum.at(channels, n)
        {output, _} = Enum.at(channels, n + 1)

        Task.async(fn ->
          Kit.run(p, :entry, [{input, output}], policy: %{scope: scope, wall_ms: 3000})
        end)
      end

    {_, first} = hd(channels)
    {_, last} = List.last(channels)
    sender = Task.async(fn -> Chan.csend(first, 0) end)
    assert Chan.crecv(last) == 9
    assert Task.await(sender) == :ok
    assert Enum.map(tasks, &Task.await(&1)) |> Enum.all?(&match?({:ok, _, _}, &1))
    assert %{runs: 0, runnable: 0, runtime_queued: 0} = Scope.stats(scope)
  end

  test "resident receives with and without timeout leave capacity for a new guest", %{
    scope: scope
  } do
    for source <- ["receive X -> X end.", "receive X -> X after 2000 -> 0 end."] do
      p = Kit.program!(source, %{terms: %{public: :erlang}})

      tasks =
        for _ <- 1..9 do
          Task.async(fn -> Kit.run(p, :entry, [nil], policy: %{scope: scope, wall_ms: 3000}) end)
        end

      wait(fn -> Scope.stats(scope).members == 9 and Scope.stats(scope).runnable == 0 end)
      assert Scope.stats(scope).runs == 9
      quick = Kit.program!("42.")
      assert {:ok, 42, _} = Kit.run(quick, :entry, [nil], policy: %{scope: scope})
      state = Scope.runtime_snapshot()
      for {pid, _} <- state.scopes[scope].members, do: send(pid, {:"$hyperlang_msg", nil, 7})
      for task <- tasks, do: assert({:ok, 7, _} = Task.await(task))
    end
  end

  test "reacquisition is FIFO and outlives wait_ms while latency retains its reservation", %{
    scope: scope
  } do
    parent = self()
    holders = for n <- 1..2, do: holder(scope, parent, n)
    for n <- 1..2, do: assert_receive({:holding, ^n})

    waiters =
      for n <- 3..6 do
        pid = holder(scope, parent, n)
        wait(fn -> Scope.stats(scope).runtime_queued == n - 2 end)
        pid
      end

    Process.sleep(30)
    assert Scope.stats(scope).runtime_queued == 4
    latency = make_ref()
    :ok = Scope.configure(latency, %{priority: :latency, wait_ms: 1})
    on_exit(fn -> Scope.close(latency) end)
    Scope.running(latency, fn -> assert Scope.stats(latency).runnable == 1 end)
    Enum.each(holders, &send(&1, :stop))

    for n <- 3..6 do
      assert_receive {:holding, ^n}, 1000
      send(Enum.at(waiters, n - 3), :stop)
    end

    wait(fn -> Scope.stats(scope).runnable == 0 and Scope.stats(scope).runtime_queued == 0 end)
  end

  test "many blocking tenants cannot starve a latency guest", %{scope: scope} do
    latency = make_ref()
    :ok = Scope.configure(latency, %{priority: :latency})
    on_exit(fn -> Scope.close(latency) end)

    p =
      Kit.program!(
        "result(N) -> loop(N). loop(0) -> 1; loop(N) -> receive after 1 -> loop(N-1) end.",
        %{terms: %{public: :erlang}}
      )

    tasks =
      for _ <- 1..24,
          do:
            Task.async(fn -> Kit.run(p, :entry, [30], policy: %{scope: scope, wall_ms: 5000}) end)

    quick = Kit.program!("42.")

    for _ <- 1..50,
        do: assert({:ok, 42, _} = Kit.run(quick, :entry, [nil], policy: %{scope: latency}))

    for task <- tasks, do: assert({:ok, 1, _} = Task.await(task))
  end

  test "a host wait cannot reset scope rate or escape suspension", %{scope: scope} do
    # host_run cannot be suspended by the scope; resumption must nevertheless
    # queue until refill, even with an empty global pool.
    :ok =
      Scope.configure(scope, %{
        rate: %{quota: 1, period_ms: 150},
        max_violations: 100,
        sample_ms: 1
      })

    :ok = Scope.attach(scope, self(), :host_run)

    try do
      Scope.running(scope, fn ->
        refill =
          Scope.blocking(fn ->
            wait(fn -> Scope.stats(scope).throttles > 0 end)
            before = Scope.stats(scope)
            assert before.runnable == 0
            assert before.usage_reductions > 0
            Scope.runtime_snapshot().scopes[scope].suspended_until
          end)

        assert System.monotonic_time(:microsecond) >= refill
        assert Scope.stats(scope).throttles > 0
      end)

      assert Scope.stats(scope).usage_reductions > 0
    after
      Scope.detach(scope, self())
    end
  end

  test "per-run rate suspension also surrenders and reacquires a runnable permit", %{scope: scope} do
    parent = self()
    group = Hyperlang.Limits.group(%{rate: %{quota: 1000, period_ms: 120}})

    {pid, mon} =
      spawn_monitor(fn ->
        :ok = Scope.attach(scope, self())
        :ok = Hyperlang.Limits.attach(group, self(), %{wall_ms: 300})

        Scope.running(scope, fn ->
          send(parent, :rate_started)
          spin()
        end)
      end)

    assert_receive :rate_started
    wait(fn -> Hyperlang.Limits.stat(group).nr_throttled > 0 end)
    assert Scope.stats(scope).runnable == 0
    assert Scope.stats(scope).runtime_queued == 1
    assert_receive {:DOWN, ^mon, :process, ^pid, {:hyperlang_limit, :wall_ms}}, 1000
    Hyperlang.Limits.delete(group)
    wait(fn -> Scope.stats(scope).runnable == 0 and Scope.stats(scope).runtime_queued == 0 end)
  end

  test "overlapping rate groups retain no permit until the last suspension refills", %{
    scope: scope
  } do
    a = Hyperlang.Limits.group(%{rate: %{quota: 1000, period_ms: 100}})
    b = Hyperlang.Limits.group(%{rate: %{quota: 1000, period_ms: 1000}})

    {pid, monitor} =
      spawn_monitor(fn ->
        :ok = Scope.attach(scope, self())
        :ok = Hyperlang.Limits.attach(a, self(), %{wall_ms: 3000})
        :ok = Hyperlang.Limits.attach(b, self(), %{wall_ms: 3000})
        Scope.running(scope, fn -> spin() end)
        Scope.detach(scope, self())
      end)

    wait(fn ->
      Hyperlang.Limits.stat(a).nr_throttled > 0 and Hyperlang.Limits.stat(b).nr_throttled > 0
    end)

    Process.sleep(200)
    assert Process.info(pid, :status) == {:status, :suspended}
    assert Scope.stats(scope).runnable == 0
    send(pid, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2000
    Hyperlang.Limits.delete(a)
    Hyperlang.Limits.delete(b)
    wait(fn -> Scope.stats(scope).runtime_queued == 0 end)
  end

  test "blocked lifetime cannot resume into a reused scope", %{scope: scope} do
    parent = self()

    pid =
      spawn(fn ->
        result =
          try do
            Scope.running(scope, fn ->
              Scope.blocking(fn ->
                send(parent, :blocked)

                receive do
                  :resume -> :ok
                end
              end)
            end)
          catch
            :throw, {:hyperlang_scope_busy, error} -> error
          end

        send(parent, {:resumed, result})
      end)

    assert_receive :blocked
    :ok = Scope.close(scope)
    :ok = Scope.configure(scope, %{})
    send(pid, :resume)
    assert_receive {:resumed, %{category: :busy, reason: :scope_closed}}
    assert Scope.stats(scope).runnable == 0
  end

  test "door waits, sleep and channel alt surrender capacity without losing wall accounting", %{
    scope: scope
  } do
    parent = self()

    binding = %{
      wait: fn ->
        send(parent, {:door_waiting, self()})

        receive do
          :return -> 42
        end
      end
    }

    p = Kit.program!("door:wait().", bindings: %{"door" => binding})

    tasks =
      for _ <- 1..9 do
        Task.async(fn ->
          Kit.run(p, :entry, [nil],
            bindings: %{"door" => binding},
            policy: %{scope: scope, wall_ms: 3000}
          )
        end)
      end

    workers =
      for _ <- 1..9 do
        assert_receive {:door_waiting, pid}, 1000
        pid
      end

    assert Scope.stats(scope).runnable == 0
    for pid <- workers, do: send(pid, :return)
    for task <- tasks, do: assert({:ok, 42, _} = Task.await(task))

    {_h, broker} = Chan.newchan(scope, 0)
    waiter = Task.async(fn -> Scope.running(scope, fn -> Chan.alt([{:recv, broker}]) end) end)

    wait(fn ->
      Scope.stats(scope).runnable == 0 and
        :sys.get_state(broker).altq != []
    end)

    assert :ok = Chan.csend(broker, 5)
    assert {:recv, 0, 5} = Task.await(waiter)

    sleep = Kit.program!("sys:sleep(100).", %{sys: %{enabled: true}})

    assert {:error, %{category: :timeout}} =
             Kit.run(sleep, :entry, [nil], policy: %{scope: scope, wall_ms: 5})

    wait(fn -> Scope.stats(scope).runnable == 0 and Scope.stats(scope).runtime_queued == 0 end)
  end

  test "randomized saturated admission, blocking, close, kill and deadlines leave no permits", %{
    scope: scope
  } do
    parent = self()

    for seed <- 1..20 do
      :rand.seed(:exsss, {seed, seed + 1, seed + 2})

      workers =
        for _ <- 1..6 do
          {pid, mon} =
            spawn_monitor(fn ->
              try do
                Scope.running(scope, fn ->
                  send(parent, {:runnable_started, self()})

                  receive do
                    :block ->
                      Scope.blocking(fn ->
                        send(parent, {:random_parked, self()})

                        receive do
                          :resume -> :ok
                        after
                          2 -> :timeout
                        end
                      end)

                    :stop ->
                      :ok
                  after
                    50 -> :timeout
                  end
                end)
              catch
                :throw, {:hyperlang_scope_busy, _} -> :ok
              end
            end)

          {pid, mon}
        end

      wait(fn -> Scope.stats(scope).runtime_queued >= 4 end)
      for {pid, _} <- Enum.take(workers, 2), do: send(pid, :block)

      if rem(seed, 3) == 0 do
        Scope.close(scope)
        Scope.configure(scope, %{wait_ms: 1})
      end

      for {pid, _} <- Enum.shuffle(workers) do
        if :rand.uniform(2) == 1, do: send(pid, :stop), else: Process.exit(pid, :kill)
      end

      for {pid, mon} <- workers, do: assert_receive({:DOWN, ^mon, :process, ^pid, _}, 1000)

      wait(fn ->
        state = Scope.runtime_snapshot()

        state.run_count == 0 and state.background_count == 0 and
          map_size(state.runtime_permits) == 0 and state.runtime_queue == [] and
          state.runtime_parked == %{}
      end)

      state = Scope.runtime_snapshot()
      assert state.queue == []
      assert state.leases == %{}
    end
  end

  test "a host-metered resident child keeps runnable admission after its spawning host exits" do
    previous = Application.get_env(:hyperlang, :guest_spawn_hook)
    :persistent_term.put({HostChildHook, :observer}, self())

    Application.put_env(
      :hyperlang,
      :guest_spawn_hook,
      {HostChildHook, :spawn, %{host_metered?: true}}
    )

    on_exit(fn ->
      restore(:guest_spawn_hook, previous)
      :persistent_term.erase({HostChildHook, :observer})
    end)

    program =
      Kit.program!("result(_) -> spawn(fun() -> receive X -> X end end).", %{
        terms: %{public: :erlang}
      })

    observer = self()

    {parent, monitor} =
      spawn_monitor(fn -> send(observer, {:spawn_result, Kit.run(program, :entry, [nil])}) end)

    assert_receive {:host_child, child}, 1000
    assert_receive {:spawn_result, {:ok, 99, _}}, 1000
    assert_receive {:DOWN, ^monitor, :process, ^parent, :normal}, 1000
    wait(fn -> Scope.stats({Scope, parent}) == nil end)
    assert Process.alive?(child)
    send(child, {:"$hyperlang_msg", nil, 42})
    assert_receive {:host_child_finished, ^child, 42}, 1000
    wait(fn -> Scope.stats({Scope, child}) == nil end)
  end

  test "closing a scope retains protected execution and releases an eligible parked host", %{
    scope: scope
  } do
    :ok = Scope.configure(scope, %{rate: %{quota: 1000, period_ms: 1000}, max_violations: 100})
    group = Hyperlang.Limits.group(%{rate: %{quota: 1000, period_ms: 100}})
    observer = self()

    pid =
      spawn(fn ->
        :ok = Scope.attach(scope, self(), :host_run)
        :ok = Hyperlang.Limits.attach(group, self(), %{wall_ms: 3000})
        Scope.running(scope, fn -> spin() end)
        :ok = Scope.detach(scope, self())
        send(observer, :protected_finished)
      end)

    wait(fn ->
      state = Scope.runtime_snapshot()
      Enum.any?(Map.get(state.runtime_parked, scope, []), &Map.has_key?(&1, :notify))
    end)

    assert Scope.stats(scope).runnable == 0
    Scope.close(scope)
    state = Scope.runtime_snapshot()
    assert state.run_count == 1

    assert Enum.any?(state.runtime_permits, fn {_, entry} ->
             entry.owner == pid and entry.closed?
           end)

    send(pid, :stop)
    assert_receive :protected_finished, 1000
    Hyperlang.Limits.delete(group)
    wait(fn -> Scope.runtime_snapshot().run_count == 0 end)
    refute Map.has_key?(Scope.runtime_snapshot().runtime_scopes, scope)
  end

  test "reverse channel indexes retain shared ownership and empty after the last close", %{
    scope: scope
  } do
    other = make_ref()
    :ok = Scope.configure(other, %{})
    on_exit(fn -> Scope.close(other) end)
    priority = Process.info(self(), :priority)
    {handle, broker} = Chan.newchan(scope, 1)
    assert Process.info(self(), :priority) == priority
    assert Process.info(broker, :priority) == {:priority, :low}
    assert :ok = Chan.fork_scope(other, scope)
    state = :sys.get_state(Chan.Registry)
    assert MapSet.size(state.broker_aliases[broker]) == 2
    assert state.ref_brokers[state.broker_refs[broker]] == broker
    :ok = Scope.close(scope)
    assert Process.alive?(broker)
    assert Chan.resolve(other, handle) == broker
    :ok = Scope.close(other)

    wait(fn ->
      state = :sys.get_state(Chan.Registry)

      not Map.has_key?(state.broker_aliases, broker) and
        not Map.has_key?(state.broker_refs, broker) and
        not Enum.any?(state.ref_brokers, fn {_, pid} -> pid == broker end)
    end)
  end

  test "stale sampler results cannot cross a member lifetime and sampler failure closes its scope",
       %{scope: scope} do
    :ok = Scope.attach(scope, self(), :host_run)
    state = Scope.runtime_snapshot()
    old_ref = state.scopes[scope].members[self()].sample_ref
    :ok = Scope.detach(scope, self())
    :ok = Scope.attach(scope, self(), :host_run)
    state = Scope.runtime_snapshot()

    reading = %{
      reductions: 1_000_000_000,
      heap: 1_000_000_000,
      gcs: 1000,
      memory_words: 1_000_000_000
    }

    send(
      Scope,
      {:sampled, scope, state.scopes[scope].generation, %{self() => {old_ref, reading}}}
    )

    refute Scope.stats(scope).killed?
    assert Scope.stats(scope).heap_words < 1_000_000_000
    sampler = state.scopes[scope].sampler
    monitor = Process.monitor(sampler)
    Process.exit(sampler, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^sampler, :killed}
    wait(fn -> Scope.stats(scope) == nil end)
    state = Scope.runtime_snapshot()
    refute Enum.any?(state.monitors, fn {_, value} -> value == {:sampler, scope} end)
    assert Process.alive?(self())
  end

  defp spin do
    receive do
      :stop -> :ok
    after
      0 -> spin()
    end
  end

  defp holder(scope, parent, n) do
    spawn(fn ->
      Scope.running(scope, fn ->
        send(parent, {:holding, n})
        # This trusted test barrier deliberately simulates CPU occupying a slot.
        receive do
          :stop -> :ok
        end
      end)
    end)
  end

  defp wait(fun, n \\ 1000)
  defp wait(_, 0), do: flunk("admission did not converge")

  defp wait(fun, n) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(1)
          wait(fun, n - 1)
        )
  end

  defp restore(key, nil), do: Application.delete_env(:hyperlang, key)
  defp restore(key, value), do: Application.put_env(:hyperlang, key, value)
end
