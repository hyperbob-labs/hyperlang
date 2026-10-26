defmodule Hyperlang.Isolation.Round2Peer do
  @moduledoc false
  alias Hyperlang.Isolation.Peer

  @cap_kib 4 * 1024 * 1024

  def start(opts \\ []) do
    session = Peer.start(opts)

    Peer.bootstrap(session, fn ->
      :peer.call(session.peer, Code, :require_file, [__ENV__.file], 30_000)
    end)

    session
  end

  def stop(session), do: Peer.stop(session)

  def run(name, args \\ [], opts \\ []) do
    session = start(opts)

    try do
      call(session, name, args, Keyword.get(opts, :timeout, 60_000))
    after
      stop(session)
    end
  end

  def call(session, name, args \\ [], timeout \\ 60_000) do
    owner = self()
    ref = make_ref()

    {runner, monitor} =
      spawn_monitor(fn ->
        result =
          :peer.call(
            session.peer,
            Hyperlang.Isolation.Round2Probe,
            name,
            args,
            max(1_000, timeout - 500)
          )

        send(owner, {ref, result})
      end)

    started = System.monotonic_time(:millisecond)
    result = watch(session, ref, monitor, runner, started, 0, timeout)
    record(name, result)
    result
  end

  defp watch(session, ref, monitor, runner, started, peak, timeout) do
    rss =
      case System.cmd("ps", ["-o", "rss=", "-p", session.os_pid]) do
        {out, 0} ->
          case Integer.parse(String.trim(out)) do
            {n, _} -> n
            _ -> 0
          end

        _ ->
          0
      end

    peak = max(peak, rss)
    elapsed = System.monotonic_time(:millisecond) - started

    cond do
      rss > @cap_kib or elapsed >= timeout ->
        System.cmd("kill", ["-KILL", session.os_pid])
        Process.exit(runner, :kill)
        Process.demonitor(monitor, [:flush])

        %{
          watchdog: if(rss > @cap_kib, do: :rss_over_4_gib, else: :wall_timeout),
          elapsed_ms: elapsed,
          peak_rss_kib: peak
        }

      true ->
        receive do
          {^ref, result} ->
            Process.demonitor(monitor, [:flush])
            %{result: result, elapsed_ms: elapsed, peak_rss_kib: peak}

          {:DOWN, ^monitor, :process, ^runner, reason} ->
            %{peer_failure: inspect(reason), elapsed_ms: elapsed, peak_rss_kib: peak}
        after
          40 -> watch(session, ref, monitor, runner, started, peak, timeout)
        end
    end
  end

  defp record(name, data) do
    if dir = System.get_env("ISOLATION_EVIDENCE_DIR") do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "round2_#{name}.etf"), :erlang.term_to_binary(data))

      File.write!(
        Path.join(dir, "round2_evidence.log"),
        inspect({name, data}, limit: :infinity, printable_limit: 8_000, width: 140) <> "\n",
        [:append]
      )
    end
  end
end

defmodule Hyperlang.Isolation.NestedBinding do
  @moduledoc false
  @behaviour Hyperlang.Binding
  alias Hyperlang.Test, as: Kit

  @impl true
  def exports, do: [descend: 1]

  @impl true
  def call(state, :descend, [0]) do
    if Map.get(state, :hold_leaf?, false) do
      send(state.owner, {:nested_leaf, self()})

      receive do
        :release_leaf -> :ok
      end
    end

    0
  end

  def call(state, :descend, [depth]) when is_integer(depth) and depth > 0 do
    scope =
      case state.mode do
        :same -> state.scope
        :other -> make_ref()
      end

    if state.mode == :other,
      do: :ok = Hyperlang.Scope.configure(scope, state.scope_policy)

    send(state.owner, {:nested_enter, self(), depth, scope})
    nested_state = %{state | scope: scope}

    result =
      Kit.run(state.program, :entry, [depth - 1],
        bindings: %{"nested" => {__MODULE__, nested_state}},
        policy: %{scope: scope, max_reductions: nil}
      )

    if state.mode == :other, do: Hyperlang.Scope.close(scope)

    case result do
      {:ok, value, _meta} when is_integer(value) -> value + 1
      {:ok, value, _meta} -> value
      {:error, %{category: category, details: %{"reason" => reason}}} -> "#{category}:#{reason}"
      {:error, %{category: category, reason: reason}} -> "#{category}:#{reason}"
      {:error, error} -> inspect(error)
    end
  end
end

defmodule Hyperlang.Isolation.BlockingBinding do
  @moduledoc false
  @behaviour Hyperlang.Binding

  @impl true
  def exports, do: [wait: 0]

  @impl true
  def call(owner, :wait, []) do
    send(owner, {:blocking_binding, self()})

    receive do
      :release_binding -> 1
    after
      30_000 -> 1
    end
  end
end

defmodule Hyperlang.Isolation.RaisingBinding do
  @moduledoc false
  @behaviour Hyperlang.Binding

  @impl true
  def exports, do: [fail: 0]

  @impl true
  def call(_state, :fail, []), do: raise("round2 binding failure")
end

defmodule Hyperlang.Isolation.Round2Storage do
  @moduledoc false
  @behaviour Hyperlang.Binding

  @impl true
  def exports, do: [get: 2, put: 2]

  @impl true
  def call(%{table: table, ns: ns}, :get, [key, default]) do
    case :ets.lookup(table, {ns, key}) do
      [{{^ns, ^key}, value}] -> value
      [] -> default
    end
  end

  def call(%{table: table, log: log, ns: ns} = state, :put, [key, value]) do
    :ets.insert(log, {System.unique_integer([:monotonic]), self(), :enter, value})
    if owner = Map.get(state, :notify), do: send(owner, {:storage_enter, self(), ns, value})
    if delay = Map.get(state, :delay_ms), do: Process.sleep(delay)
    true = :ets.insert(table, {{ns, key}, value})
    :ets.insert(log, {System.unique_integer([:monotonic]), self(), :exit, value})
    :ok
  end
end

defmodule Hyperlang.Isolation.Round2Probe do
  @moduledoc false
  alias Hyperlang.Isolation.Probe
  alias Hyperlang.Test, as: Kit

  @soak_key {__MODULE__, :soak_programs}
  @timer_tag :"$hyperlang_msg"

  def nested_admission do
    program =
      Kit.program!("result(N) -> nested:descend(N).", %{
        bindings: %{"nested" => Hyperlang.Isolation.NestedBinding},
        terms: %{public: :erlang}
      })

    policy = %{max_queue: 16, wait_ms: 40}

    same_scope =
      for width <- 1..4, depth <- 1..4 do
        scope = make_ref()
        :ok = Hyperlang.Scope.configure(scope, Map.put(policy, :max_concurrent_runs, width))

        state = %{
          mode: :same,
          owner: self(),
          program: program,
          scope: scope,
          scope_policy: policy
        }

        {us, result} =
          :timer.tc(fn ->
            Kit.run(program, :entry, [depth],
              bindings: %{"nested" => {Hyperlang.Isolation.NestedBinding, state}},
              policy: %{scope: scope, max_reductions: nil}
            )
          end)

        stats = Hyperlang.Scope.stats(scope)
        :ok = Hyperlang.Scope.close(scope)
        %{width: width, depth: depth, time_us: us, outcome: simplify(result), stats: stats}
      end

    other_scope =
      for depth <- 1..4 do
        scope = make_ref()
        :ok = Hyperlang.Scope.configure(scope, Map.put(policy, :max_concurrent_runs, 1))

        state = %{
          mode: :other,
          owner: self(),
          program: program,
          scope: scope,
          scope_policy: Map.put(policy, :max_concurrent_runs, 1)
        }

        result =
          Kit.run(program, :entry, [depth],
            bindings: %{"nested" => {Hyperlang.Isolation.NestedBinding, state}},
            policy: %{scope: scope, max_reductions: nil}
          )

        :ok = Hyperlang.Scope.close(scope)
        %{depth: depth, outcome: simplify(result)}
      end

    %{same_scope: same_scope, other_scope: other_scope}
  end

  def nested_parent_kill do
    program =
      Kit.program!("result(N) -> nested:descend(N).", %{
        bindings: %{"nested" => Hyperlang.Isolation.NestedBinding},
        terms: %{public: :erlang}
      })

    scope = make_ref()

    :ok =
      Hyperlang.Scope.configure(scope, %{max_concurrent_runs: 1, max_queue: 4, wait_ms: 5_000})

    owner = self()

    caller =
      spawn(fn ->
        state = %{
          mode: :same,
          owner: owner,
          program: program,
          scope: scope,
          scope_policy: %{},
          hold_leaf?: true
        }

        result =
          Kit.run(program, :entry, [2],
            bindings: %{"nested" => {Hyperlang.Isolation.NestedBinding, state}},
            policy: %{scope: scope, max_reductions: nil}
          )

        send(owner, {:nested_result, result})
      end)

    receive do
      {:nested_enter, _worker, _depth, ^scope} -> :ok
    after
      1_000 -> raise "nested caller did not enter"
    end

    receive do
      {:nested_leaf, _pid} -> :ok
    after
      1_000 -> raise "nested leaf did not enter"
    end

    Process.exit(caller, :kill)
    wait(fn -> match?(%{runs: 0, queued: 0, members: 0}, Hyperlang.Scope.stats(scope)) end)
    stats = Hyperlang.Scope.stats(scope)
    :ok = Hyperlang.Scope.close(scope)
    stats
  end

  def scope_lifecycle do
    scope = make_ref()
    :ok = Hyperlang.Scope.configure(scope, %{max_concurrent_runs: 1, max_queue: 2, wait_ms: 500})

    blocking =
      Kit.program!("result(_) -> blocker:wait().", %{
        bindings: %{"blocker" => Hyperlang.Isolation.BlockingBinding},
        terms: %{public: :erlang}
      })

    quick = Kit.program!("result(_) -> 1.", %{terms: %{public: :erlang}})
    owner = self()

    first =
      spawn(fn ->
        result =
          Kit.run(blocking, :entry, [nil],
            bindings: %{"blocker" => {Hyperlang.Isolation.BlockingBinding, owner}},
            policy: %{scope: scope, max_reductions: nil}
          )

        send(owner, {:scope_first, result})
      end)

    receive do
      {:blocking_binding, _worker} -> :ok
    after
      1_000 -> raise "blocking run did not enter"
    end

    second =
      spawn(fn ->
        send(owner, {:scope_second, Kit.run(quick, :entry, [nil], policy: %{scope: scope})})
      end)

    wait(fn -> Hyperlang.Scope.stats(scope).queued == 1 end)
    {_handle, broker} = Hyperlang.Chan.newchan(scope, 1)
    {:ok, timer_id} = Hyperlang.MsgTimerServer.start_timer(scope, 8, 60_000, timer_entry(:held))
    before = Hyperlang.Scope.stats(scope)
    close_started = System.monotonic_time(:microsecond)
    :ok = Hyperlang.Scope.close(scope)
    close_us = System.monotonic_time(:microsecond) - close_started

    first_result = receive_result(:scope_first)
    second_result = receive_result(:scope_second)
    wait(fn -> not Process.alive?(broker) end)
    timers = :sys.get_state(Hyperlang.MsgTimerServer)

    Process.exit(first, :kill)
    Process.exit(second, :kill)

    :ok = Hyperlang.Scope.configure(scope, %{max_concurrent_runs: 1})
    reused = Kit.run(quick, :entry, [nil], policy: %{scope: scope})
    :ok = Hyperlang.Scope.close(scope)

    %{
      before: before,
      close_us: close_us,
      first: simplify(first_result),
      second: simplify(second_result),
      broker_alive: Process.alive?(broker),
      timer_retained: Map.has_key?(timers.timers, {scope, timer_id}),
      stats_after: Hyperlang.Scope.stats(scope),
      reused: simplify(reused)
    }
  end

  def owner_reuse_race(iterations) do
    failures =
      for iteration <- 1..iterations, reduce: [] do
        failures ->
          id = {:reuse, iteration, make_ref()}
          parent = self()

          owner =
            spawn(fn ->
              :ok = Hyperlang.Scope.configure(id, %{})

              {:ok, timer} =
                Hyperlang.MsgTimerServer.start_timer(id, 2, 60_000, timer_entry(:old_owner))

              send(parent, {:owner_ready, self(), timer})
              Process.sleep(:infinity)
            end)

          old_timer =
            receive do
              {:owner_ready, ^owner, timer} -> timer
            after
              1_000 -> raise "scope owner did not start"
            end

          Process.exit(owner, :kill)
          wait(fn -> Hyperlang.Scope.stats(id) == nil end)

          wait(fn ->
            not Map.has_key?(:sys.get_state(Hyperlang.MsgTimerServer).timers, {id, old_timer})
          end)

          :ok = Hyperlang.Scope.configure(id, %{max_channels: 2})

          {:ok, new_timer} =
            Hyperlang.MsgTimerServer.start_timer(id, 2, 60_000, timer_entry(:new_owner))

          {handle, broker} = Hyperlang.Chan.newchan(id, 0)
          Process.sleep(2)

          timer_alive =
            Map.has_key?(:sys.get_state(Hyperlang.MsgTimerServer).timers, {id, new_timer})

          failures =
            cond do
              not Process.alive?(broker) ->
                [%{iteration: iteration, failure: :stale_close_killed_reused_channel} | failures]

              not timer_alive ->
                [%{iteration: iteration, failure: :stale_close_cancelled_reused_timer} | failures]

              true ->
                failures
            end

          Hyperlang.MsgTimerServer.cancel(id, new_timer)
          Hyperlang.Chan.freechan(id, handle, broker)
          :ok = Hyperlang.Scope.close(id)
          failures
      end

    %{iterations: iterations, failures: Enum.reverse(failures)}
  end

  def close_configure_race(iterations) do
    outcomes =
      for iteration <- 1..iterations do
        id = {:close_configure, iteration, make_ref()}
        parent = self()

        owner =
          spawn(fn ->
            :ok = Hyperlang.Scope.configure(id, %{})
            send(parent, {:configured_owner, self()})

            receive do
              :race_configure ->
                result = Hyperlang.Scope.configure(id, %{max_queue: rem(iteration, 4)})
                send(parent, {:configure_result, self(), result})
            end

            Process.sleep(:infinity)
          end)

        receive do
          {:configured_owner, ^owner} -> :ok
        after
          1_000 -> raise "scope owner did not start"
        end

        closer = Task.async(fn -> Hyperlang.Scope.close(id) end)
        send(owner, :race_configure)

        configured =
          receive do
            {:configure_result, ^owner, result} -> result
          after
            1_000 -> :no_reply
          end

        closed = Task.await(closer, 1_000)
        Process.exit(owner, :kill)
        wait(fn -> Hyperlang.Scope.stats(id) == nil end)
        %{configured: configured, closed: closed}
      end

    %{iterations: iterations, outcomes: outcomes}
  end

  # R2-3 claim (SECURITY_SPECIFICATION, Timers): expiry delivery, including the
  # trusted host resolver, runs in one ordered worker per scope, so a stalled
  # resolver in one scope never delays another scope's delivery.
  #
  # The slow scope's resolver is held open until the victim has been delivered,
  # so head-of-line blocking cannot pass by timing luck: it never delivers the
  # victim. Latency is measured against a bare BEAM control timer with the same
  # delay, armed in the same peer just after the victim timer. Both share the
  # BEAM timer service, so the difference is the delay that Hyperlang delivery
  # adds. Absolute overshoot is BEAM timer-service lateness and is reported only.
  def timer_head_of_line do
    rows = for _ <- 1..20, do: timer_head_of_line_once()
    sorted = fn key -> rows |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sort() end

    %{
      samples: 20,
      slow_started: Enum.all?(rows, & &1.slow_started),
      victim_delivered_while_slow_held: Enum.all?(rows, & &1.victim_delivered_while_slow_held),
      victim_excess_us: percentile(sorted.(:victim_excess_us), 0.99),
      p50_excess_us: percentile(sorted.(:victim_excess_us), 0.50),
      victim_overshoot_us: percentile(sorted.(:victim_overshoot_us), 0.99),
      control_overshoot_us: percentile(sorted.(:control_overshoot_us), 0.99),
      p50_overshoot_us: percentile(sorted.(:victim_overshoot_us), 0.50),
      observer_delay_p99_us: percentile(sorted.(:observer_delay_us), 0.99),
      requested_ms: 21
    }
  end

  defp timer_head_of_line_once do
    owner = self()
    tag = make_ref()
    server = Process.whereis(Hyperlang.MsgTimerServer)

    Application.put_env(:hyperlang, :guest_msg_resolver, fn target, ctx ->
      if Map.has_key?(ctx, :timer_sender_ctx) and target == "victim" do
        send(owner, {tag, :victim_delivered_at, System.monotonic_time(:microsecond)})
      end

      if Map.has_key?(ctx, :timer_sender_ctx) and target == "slow" do
        send(owner, {tag, :slow_delivery_started, self()})

        receive do
          :release_slow -> send(owner, {tag, :slow_delivery_left})
        after
          5_000 -> send(owner, {tag, :slow_delivery_left})
        end
      end

      {:ok, owner, %{sender_ctx: target}}
    end)

    program =
      Kit.program!("result({Delay, Target}) -> erlang:send_after(Delay, Target, Target).", %{
        terms: %{public: :erlang}
      })

    slow_scope = make_ref()
    victim_scope = make_ref()
    :ok = Hyperlang.Scope.configure(slow_scope, %{})
    :ok = Hyperlang.Scope.configure(victim_scope, %{})

    try do
      {:ok, _, _} = Kit.run(program, :entry, [{20, "slow"}], policy: %{scope: slow_scope})
      started = System.monotonic_time(:microsecond)
      {:ok, _, _} = Kit.run(program, :entry, [{21, "victim"}], policy: %{scope: victim_scope})

      spawn(fn ->
        :erlang.start_timer(21, self(), :control)

        receive do
          {:timeout, _, :control} ->
            send(owner, {tag, :control_fired_at, System.monotonic_time(:microsecond)})
        end
      end)

      slow =
        receive do
          {^tag, :slow_delivery_started, pid} -> pid
        after
          1_000 -> nil
        end

      victim_at =
        receive do
          {^tag, :victim_delivered_at, delivered_at} -> delivered_at
        after
          2_000 -> nil
        end

      # The slow resolver reports when it leaves its hold. No such report yet
      # means the victim was delivered while the slow delivery was still held.
      slow_held =
        receive do
          {^tag, :slow_delivery_left} -> false
        after
          0 -> slow != nil
        end

      if slow, do: send(slow, :release_slow)
      if is_nil(victim_at), do: raise("victim delivery blocked behind the slow scope")
      observer_at = receive_timer("victim", started + 2_000_000)

      if slow do
        receive do
          {^tag, :slow_delivery_left} -> :ok
        after
          1_000 -> raise "slow delivery was not released"
        end

        receive_timer("slow", started + 3_000_000)
      end

      control_at =
        receive do
          {^tag, :control_fired_at, fired_at} -> fired_at
        after
          1_000 -> raise "control timer missing"
        end

      %{
        slow_started: slow != nil,
        victim_delivered_while_slow_held: slow_held,
        requested_ms: 21,
        victim_excess_us: victim_at - control_at,
        observer_delay_us: observer_at - victim_at,
        victim_overshoot_us: victim_at - started - 21_000,
        control_overshoot_us: control_at - started - 21_000,
        server_mailbox: elem(Process.info(server, :message_queue_len), 1)
      }
    after
      Hyperlang.Scope.close(slow_scope)
      Hyperlang.Scope.close(victim_scope)
      Application.delete_env(:hyperlang, :guest_msg_resolver)
      flush_timer_messages()
    end
  end

  def timer_stress(scope_count, timers_per_scope) do
    owner = self()

    Application.put_env(:hyperlang, :guest_msg_resolver, fn target, _ctx ->
      {:ok, owner, %{sender_ctx: target}}
    end)

    scopes = for n <- 1..scope_count, do: {:timer_stress, n, make_ref()}
    Enum.each(scopes, &(:ok = Hyperlang.Scope.configure(&1, %{})))
    total = scope_count * timers_per_scope
    delay_ms = 30
    started = System.monotonic_time(:microsecond)

    try do
      for {scope, scope_index} <- Enum.with_index(scopes), timer_index <- 1..timers_per_scope do
        due = System.monotonic_time(:microsecond) + delay_ms * 1_000

        {:ok, _id} =
          Hyperlang.MsgTimerServer.start_timer(
            scope,
            timers_per_scope + 10,
            delay_ms,
            timer_entry({scope_index, timer_index, due})
          )
      end

      create_us = System.monotonic_time(:microsecond) - started
      {lateness, max_mailbox} = collect_timer_storm(total, [], 0, started + 5_000_000)
      sorted = Enum.sort(lateness)

      race_scope = make_ref()
      :ok = Hyperlang.Scope.configure(race_scope, %{})

      ids =
        for n <- 1..100 do
          {:ok, id} =
            Hyperlang.MsgTimerServer.start_timer(
              race_scope,
              200,
              60_000,
              timer_entry({:race, n})
            )

          id
        end

      races =
        Enum.map(ids, fn id ->
          cancel = Task.async(fn -> Hyperlang.MsgTimerServer.cancel(race_scope, id) end)
          read = Task.async(fn -> Hyperlang.MsgTimerServer.read(race_scope, id) end)
          {Task.await(cancel), Task.await(read)}
        end)

      :ok = Hyperlang.Scope.close(race_scope)

      %{
        scopes: scope_count,
        timers: total,
        create_us: create_us,
        throughput_per_s: total * 1_000_000 / create_us,
        lateness_p50_us: percentile(sorted, 0.50),
        lateness_p99_us: percentile(sorted, 0.99),
        lateness_max_us: List.last(sorted),
        max_server_mailbox: max_mailbox,
        race_results_valid:
          Enum.all?(races, fn {cancel, read} ->
            (cancel == false or is_integer(cancel)) and (read == false or is_integer(read))
          end)
      }
    after
      Enum.each(scopes, &Hyperlang.Scope.close/1)
      Application.delete_env(:hyperlang, :guest_msg_resolver)
      flush_timer_messages()
    end
  end

  def soak_start do
    normal = Kit.program!("result(_) -> 1.", %{terms: %{public: :erlang}})
    wall = Kit.program!("result(_) -> spin(). spin() -> spin().", %{terms: %{public: :erlang}})
    reductions = wall

    heap =
      Kit.program!("result(_) -> grow([]). grow(L) -> grow([1|L]).", %{terms: %{public: :erlang}})

    crash = Kit.program!("result(_) -> erlang:error(boom).", %{terms: %{public: :erlang}})

    binding =
      Kit.program!("result(_) -> broken:fail().", %{
        bindings: %{"broken" => Hyperlang.Isolation.RaisingBinding},
        terms: %{public: :erlang}
      })

    :persistent_term.put(@soak_key, %{
      normal: normal,
      wall: wall,
      reductions: reductions,
      heap: heap,
      crash: crash,
      binding: binding
    })

    for _ <- 1..100, do: Kit.run(normal, :entry, [nil])

    programs = :persistent_term.get(@soak_key)

    for mode <- [:wall, :reductions, :heap, :crash, :binding], _ <- 1..5 do
      soak_run(mode, programs, nil)
    end

    busy_scope = {:soak_warm_busy, make_ref()}
    :ok = Hyperlang.Scope.configure(busy_scope, %{max_concurrent_runs: 1, max_queue: 0})
    {:ok, lease} = Hyperlang.Scope.acquire(busy_scope)
    soak_run(:busy, programs, busy_scope)
    :ok = Hyperlang.Scope.release(lease)
    :ok = Hyperlang.Scope.close(busy_scope)
    :ok = Hyperlang.Scope.close(Hyperlang.Scope.current())
    Process.sleep(20)
    :erlang.garbage_collect()
    gc_services()
    expanded_snapshot()
  end

  def soak_batch(batch) do
    programs = :persistent_term.get(@soak_key)
    scope = {:soak_busy, batch, make_ref()}
    :ok = Hyperlang.Scope.configure(scope, %{max_concurrent_runs: 1, max_queue: 0})
    {:ok, lease} = Hyperlang.Scope.acquire(scope)

    modes =
      List.duplicate(:normal, 940) ++
        List.duplicate(:wall, 10) ++
        List.duplicate(:reductions, 10) ++
        List.duplicate(:heap, 10) ++
        List.duplicate(:crash, 10) ++
        List.duplicate(:binding, 10) ++ List.duplicate(:busy, 10)

    {us, outcomes} =
      :timer.tc(fn ->
        modes
        |> Enum.map(fn mode ->
          Task.async(fn -> soak_run(mode, programs, scope) end)
          |> Task.await(2_000)
          |> then(&{mode, category(&1)})
        end)
        |> Enum.frequencies()
      end)

    :ok = Hyperlang.Scope.release(lease)
    :ok = Hyperlang.Scope.close(scope)
    Process.sleep(5)
    :erlang.garbage_collect()

    %{batch: batch, count: 1_000, time_us: us, outcomes: outcomes, snapshot: expanded_snapshot()}
  end

  def soak_finish do
    :persistent_term.erase(@soak_key)
    Process.sleep(50)
    :erlang.garbage_collect()
    gc_services()
    expanded_snapshot()
  end

  def durable_actor_stress do
    table = :ets.new(:round2_storage, [:public, :set])
    log = :ets.new(:round2_storage_log, [:public, :ordered_set])

    source = """
    init(Id) -> {ok, storage:get(<<"n">>, 0)}.
    handle_call(<<"inc">>, _, N) -> ok = storage:put(<<"n">>, N+1), {reply, N+1, N+1};
    handle_call(<<"slow">>, _, N) -> ok = storage:put(<<"n">>, N+1), {reply, N+1, N+1};
    handle_call(<<"inc_crash">>, _, N) -> ok = storage:put(<<"n">>, N+1), erlang:error(boom);
    handle_call(<<"get">>, _, N) -> {reply, N, N}.
    """

    program =
      Kit.program!(source, %{
        result: %{name: "init", arity: 1},
        terms: %{public: :erlang, allowed_atoms: [:ok, :reply, :boom]},
        bindings: %{"storage" => Hyperlang.Isolation.Round2Storage}
      })

    start = fn ns, opts ->
      storage =
        {Hyperlang.Isolation.Round2Storage, Map.merge(%{table: table, log: log, ns: ns}, opts)}

      Kit.start_actor!(program, ns, bindings: %{"storage" => storage})
    end

    actors = for n <- 1..8, do: {"actor-#{n}", start.("actor-#{n}", %{})}

    concurrent =
      for {ns, actor} <- actors do
        results =
          for _ <- 1..25, do: Task.async(fn -> GenServer.call(actor, "inc", 5_000) end)

        values = Enum.map(results, &Task.await(&1, 5_000))
        %{ns: ns, ordered_values: Enum.sort(values), stored: stored(table, ns)}
      end

    Enum.each(actors, fn {_ns, actor} -> GenServer.stop(actor) end)

    crash_ns = "crash-loop"

    crash_values =
      for expected <- 1..10 do
        actor = start.(crash_ns, %{})
        monitor = Process.monitor(actor)

        try do
          GenServer.call(actor, "inc_crash", 2_000)
        catch
          :exit, _ -> :ok
        end

        receive do
          {:DOWN, ^monitor, :process, ^actor, _} -> :ok
        after
          2_000 -> raise "durable actor did not crash"
        end

        {expected, stored(table, crash_ns)}
      end

    reloaded = start.(crash_ns, %{})
    crash_reload = GenServer.call(reloaded, "get")
    GenServer.stop(reloaded)

    kill_ns = "killed-caller"
    killed_actor = start.(kill_ns, %{notify: self(), delay_ms: 20})
    caller = spawn(fn -> GenServer.call(killed_actor, "slow", 5_000) end)

    receive do
      {:storage_enter, ^killed_actor, ^kill_ns, 1} -> Process.exit(caller, :kill)
    after
      1_000 -> raise "killed caller did not enter storage"
    end

    Process.sleep(40)
    killed_caller_value = GenServer.call(killed_actor, "get")
    GenServer.stop(killed_actor)

    overload_ns = "mailbox-overload"
    overload = start.(overload_ns, %{delay_ms: 1})
    parent = self()

    callers =
      for n <- 1..200 do
        spawn(fn ->
          send(parent, {:overload_result, n, GenServer.call(overload, "inc", 10_000)})
        end)
      end

    {overload_results, max_queue} = collect_actor_results(200, [], 0, overload)
    GenServer.stop(overload)

    phases_ok =
      log
      |> :ets.tab2list()
      |> Enum.group_by(fn {_seq, pid, _phase, _value} -> pid end)
      |> Enum.all?(fn {_pid, rows} ->
        expected = List.duplicate([:enter, :exit], div(length(rows), 2)) |> List.flatten()
        Enum.map(rows, &elem(&1, 2)) == expected
      end)

    Enum.each(callers, fn pid -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    %{
      concurrent: concurrent,
      crash_values: crash_values,
      crash_reload: crash_reload,
      killed_caller_value: killed_caller_value,
      overload_values: overload_results |> Enum.map(&elem(&1, 1)) |> Enum.sort(),
      overload_stored: stored(table, overload_ns),
      max_mailbox: max_queue,
      serialized_writes: phases_ok
    }
  end

  def noisy_extra(mode, tenants, profile? \\ false) when mode in [:channel, :timer] do
    victim =
      Kit.program!("result(N) -> loop(N). loop(0) -> 1; loop(N) -> loop(N-1).", %{
        terms: %{public: :erlang}
      })

    victim_scope = make_ref()
    :ok = Hyperlang.Scope.configure(victim_scope, %{priority: :latency})
    victim_policy = %{scope: victim_scope, max_reductions: nil}
    for _ <- 1..100, do: Kit.run(victim, :entry, [500], policy: victim_policy)
    owner = self()

    attackers =
      for n <- 1..tenants//1 do
        spawn_monitor(fn ->
          Process.monitor(owner)
          scope = {:extra_noise, mode, n, make_ref()}
          :ok = Hyperlang.Scope.configure(scope, %{max_channels: 32, max_buffer_slots: 64})
          send(owner, {:extra_ready, self()})
          extra_noise_loop(mode, scope, owner)
        end)
      end

    Enum.each(attackers, fn {pid, _monitor} ->
      receive do
        {:extra_ready, ^pid} -> :ok
      after
        1_000 -> raise "extra noise did not start"
      end
    end)

    profiler = if profile?, do: start_channel_profile(mode, tenants)

    samples =
      for _ <- 1..1_000 do
        {us, result} =
          :timer.tc(fn -> Kit.run(victim, :entry, [500], policy: victim_policy) end)

        {us, category(result)}
      end

    profile = stop_channel_profile(profiler)
    Enum.each(attackers, fn {pid, _} -> send(pid, :stop) end)

    Enum.each(attackers, fn {pid, monitor} ->
      receive do
        {:DOWN, ^monitor, :process, ^pid, :normal} -> :ok
      after
        10_000 ->
          Process.exit(pid, :kill)
          raise "extra noise cleanup did not finish"
      end
    end)

    sorted = samples |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    Hyperlang.Scope.close(victim_scope)

    %{
      mode: mode,
      tenants: tenants,
      samples: 1_000,
      p50_us: percentile(sorted, 0.50),
      p99_us: percentile(sorted, 0.99),
      p999_us: percentile(sorted, 0.999),
      outcomes: Enum.frequencies_by(samples, &elem(&1, 1)),
      profile: profile
    }
  end

  def measurement(file, function, args) do
    Code.require_file(file)
    apply(Hyperlang.Round3Measurements, function, args)
  end

  defp start_channel_profile(:channel, 64) do
    owner = self()
    spawn(fn -> channel_profile_loop(owner, []) end)
  end

  defp start_channel_profile(_, _), do: nil

  defp stop_channel_profile(nil), do: []

  defp stop_channel_profile(pid) do
    send(pid, :stop)

    receive do
      {:channel_profile, ^pid, rows} -> rows
    after
      5_000 -> raise "channel profiler did not stop"
    end
  end

  defp channel_profile_loop(owner, rows) do
    services =
      for name <- [
            Hyperlang.Scope,
            Hyperlang.Limits,
            Hyperlang.CodeServer,
            Hyperlang.Chan.Registry,
            Hyperlang.Chan.BrokerSupervisor
          ],
          into: %{} do
        pid = Process.whereis(name)

        {name,
         if(pid,
           do: Process.info(pid, [:message_queue_len, :reductions, :status, :current_function])
         )}
      end

    partitions =
      for {pool, partition, pid} <- Hyperlang.Chan.BrokerSupervisor.partitions(), into: %{} do
        {{pool, partition},
         Process.info(pid, [:message_queue_len, :reductions, :status, :current_function])}
      end

    row = %{
      services: Map.merge(services, partitions),
      run_queues: :erlang.statistics(:run_queue_lengths)
    }

    receive do
      :stop -> send(owner, {:channel_profile, self(), Enum.reverse([row | rows])})
    after
      2 -> channel_profile_loop(owner, [row | rows])
    end
  end

  def throttle_reaction(mode) when mode in [:cpu, :churn, :compile] do
    scope = make_ref()

    policy =
      case mode do
        :cpu ->
          %{rate: %{quota: 5_000, period_ms: 50}, max_violations: 2, sample_ms: 1}

        :compile ->
          %{compile_rate: %{quota: 5_000, period_ms: 50}, max_violations: 2, sample_ms: 1}

        :churn ->
          %{churn: %{heap_words: 2_000, gcs: 2, period_ms: 50}, max_violations: 2, sample_ms: 1}
      end

    :ok = Hyperlang.Scope.configure(scope, policy)

    worker =
      spawn(fn ->
        receive do
          :go -> if(mode == :churn, do: churn(), else: spin())
        end
      end)

    monitor = Process.monitor(worker)
    kind = if mode == :compile, do: :compile, else: :run
    :ok = Hyperlang.Scope.attach(scope, worker, kind)
    started = System.monotonic_time(:microsecond)
    send(worker, :go)
    wait(fn -> Hyperlang.Scope.stats(scope).throttles > 0 end)
    first = Hyperlang.Scope.stats(scope)
    throttle_us = System.monotonic_time(:microsecond) - started

    killed_at =
      receive do
        {:DOWN, ^monitor, :process, ^worker, _} -> System.monotonic_time(:microsecond)
      after
        1_000 ->
          Process.exit(worker, :kill)
          nil
      end

    final = Hyperlang.Scope.stats(scope)
    :ok = Hyperlang.Scope.close(scope)

    %{
      mode: mode,
      throttle_us: throttle_us,
      kill_us: if(killed_at, do: killed_at - started),
      reaction_bound_us: first.max_reaction_us,
      final: final
    }
  end

  def randomized(seeds, steps) do
    failures =
      Enum.flat_map(seeds, fn seed ->
        case randomized_seed(seed, steps) do
          :ok -> []
          {:error, reason} -> [%{seed: seed, reason: reason}]
        end
      end)

    %{seeds: seeds, steps: steps, failures: failures, final: expanded_snapshot()}
  end

  def expanded_snapshot do
    base = Probe.snapshot()
    timers = :sys.get_state(Hyperlang.MsgTimerServer)
    scopes = Hyperlang.Scope.runtime_snapshot()
    channels = :sys.get_state(Hyperlang.Chan.Registry)
    limits = :sys.get_state(Hyperlang.Limits)

    service_memory =
      Map.new(
        [
          Hyperlang.AtomUniverse,
          Hyperlang.Scope,
          Hyperlang.MsgTimerServer,
          Hyperlang.Chan.Registry,
          Hyperlang.CodeServer,
          Hyperlang.Limits,
          Hyperlang.Cache
        ],
        fn name ->
          value =
            case Process.whereis(name) do
              nil -> nil
              pid -> elem(Process.info(pid, :memory), 1)
            end

          {name, value}
        end
      )

    base
    |> Map.put(:timers, map_size(timers.timers))
    |> Map.put(:timer_scopes, map_size(timers.counts))
    |> Map.put(:scopes, map_size(scopes.scopes))
    |> Map.put(:channel_aliases, map_size(channels.brokers))
    |> Map.put(:broker_aliases, map_size(channels.broker_aliases))
    |> Map.put(:broker_ref_index, map_size(channels.ref_brokers))
    |> Map.put(:scope_leases, map_size(scopes.leases))
    |> Map.put(:scope_lease_owners, map_size(scopes.lease_owners))
    |> Map.put(:runtime_scopes, map_size(scopes.runtime_scopes))
    |> Map.put(:scope_queue, length(scopes.queue))
    |> Map.put(:runtime_permits, map_size(scopes.runtime_permits))
    |> Map.put(:runtime_slots, :ets.info(:hyperlang_runtime_slots, :size))
    |> Map.put(
      :runtime_queue,
      length(scopes.runtime_queue) +
        Enum.sum(Enum.map(scopes.runtime_parked, fn {_, q} -> length(q) end))
    )
    |> Map.put(:runnable, scopes.run_count)
    |> Map.put(:background_runnable, scopes.background_count)
    |> Map.put(:scope_monitors, map_size(scopes.monitors))
    |> Map.put(:limits_monitors, map_size(limits.monitors))
    |> Map.put(:limits_active, MapSet.size(limits.active))
    |> Map.put(:service_memory, service_memory)
  end

  defp randomized_seed(seed, steps) do
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})
    scopes = for n <- 1..4, do: {:random_scope, seed, n}

    Enum.each(
      scopes,
      &(:ok = Hyperlang.Scope.configure(&1, %{max_concurrent_runs: 2, wait_ms: 20}))
    )

    program = Kit.program!("result(X) -> X.", %{terms: %{public: :erlang}})
    timed = Kit.program!("receive after 1 -> 1 end.", %{terms: %{public: :erlang}})
    crash = Kit.program!("result(_) -> erlang:error(boom).", %{terms: %{public: :erlang}})
    :ok = Hyperlang.Scope.close(Hyperlang.Scope.current())

    try do
      Enum.reduce_while(1..steps, :ok, fn step, :ok ->
        scope = Enum.at(scopes, :rand.uniform(length(scopes)) - 1)

        result =
          case :rand.uniform(9) do
            1 ->
              Kit.run(program, :entry, [step], policy: %{scope: scope})

            2 ->
              Kit.run(crash, :entry, [nil], policy: %{scope: scope})

            3 ->
              with {:ok, lease} <- Hyperlang.Scope.acquire(scope) do
                Hyperlang.Scope.release(lease)
              end

            4 ->
              {handle, broker} = Hyperlang.Chan.newchan(scope, rem(step, 3))
              Hyperlang.Chan.freechan(scope, handle, broker)

            5 ->
              {:ok, id} =
                Hyperlang.MsgTimerServer.start_timer(scope, 16, 60_000, timer_entry(step))

              _ = Hyperlang.MsgTimerServer.read(scope, id)
              _ = Hyperlang.MsgTimerServer.cancel(scope, id)
              :ok

            6 ->
              :ok = Hyperlang.Scope.close(scope)
              Hyperlang.Scope.configure(scope, %{max_concurrent_runs: 2, wait_ms: 20})

            7 ->
              :ok = Hyperlang.Scope.configure(scope, %{max_concurrent_runs: 2, wait_ms: 20})

            8 ->
              Kit.run(timed, :entry, [nil], policy: %{scope: scope, wall_ms: 100})

            9 ->
              random_runtime_lifecycle(scope)
          end

        stats = Hyperlang.Scope.stats(scope)

        valid_result =
          match?({:ok, _, _}, result) or match?({:error, _}, result) or result == :ok

        valid_stats =
          is_nil(stats) or
            (stats.runs >= 0 and stats.compiles >= 0 and stats.queued >= 0 and
               stats.members >= 0 and stats.channels >= 0)

        runtime = Hyperlang.Scope.runtime_snapshot()
        active = Enum.filter(runtime.runtime_permits, fn {_, e} -> e.active? end)
        queue = runtime.runtime_queue ++ Enum.flat_map(runtime.runtime_parked, fn {_, q} -> q end)

        indexed =
          Enum.flat_map(runtime.runtime_scopes, fn {id, tokens} ->
            Enum.map(tokens, fn token -> {token, id} end)
          end)

        valid_runtime =
          length(indexed) == map_size(runtime.runtime_permits) and
            Enum.all?(indexed, fn {token, id} -> runtime.runtime_permits[token].scope == id end) and
            runtime.lease_owners == Enum.frequencies_by(Map.values(runtime.leases), & &1.owner) and
            runtime.run_count == length(active) and
            runtime.background_count == Enum.count(active, fn {_, e} -> e.background? end) and
            runtime.run_count >= 0 and runtime.background_count >= 0 and
            length(Enum.uniq_by(queue, & &1.token)) == length(queue) and
            Enum.all?(queue, fn r ->
              match?(%{active?: false}, runtime.runtime_permits[r.token])
            end)

        channels = :sys.get_state(Hyperlang.Chan.Registry)

        reverse =
          Enum.flat_map(channels.broker_aliases, fn {broker, aliases} ->
            Enum.map(aliases, &{&1, broker})
          end)

        valid_channels =
          Map.new(reverse) == channels.brokers and
            length(reverse) == map_size(channels.brokers) and
            map_size(channels.ref_brokers) == map_size(channels.broker_refs) and
            Enum.all?(channels.broker_refs, fn {broker, ref} ->
              channels.ref_brokers[ref] == broker
            end)

        if valid_result and valid_stats and valid_runtime and valid_channels,
          do: {:cont, :ok},
          else: {:halt, {:error, %{step: step, result: result, stats: stats}}}
      end)
    rescue
      error -> {:error, %{exception: Exception.message(error), stack: __STACKTRACE__}}
    catch
      kind, reason -> {:error, %{caught: {kind, inspect(reason)}}}
    after
      Enum.each(scopes, &Hyperlang.Scope.close/1)
    end
  end

  defp random_runtime_lifecycle(scope) do
    owner = self()

    {pid, mon} =
      spawn_monitor(fn ->
        {:ok, lease} = Hyperlang.Scope.acquire(scope)

        try do
          :ok = Hyperlang.Scope.attach(scope, self())

          Hyperlang.Scope.running(scope, fn ->
            Hyperlang.Scope.blocking(fn ->
              send(owner, {:runtime_parked, self()})

              receive do
                :resume -> :ok
              after
                1 -> :timeout
              end
            end)
          end)
        catch
          :throw, {:hyperlang_scope_busy, _} -> :ok
        after
          Hyperlang.Scope.detach(scope, self())
          Hyperlang.Scope.release(lease)
        end
      end)

    receive do
      {:runtime_parked, ^pid} -> :ok
    after
      1000 -> raise "runtime lifecycle did not park"
    end

    case :rand.uniform(4) do
      1 ->
        send(pid, :resume)

      2 ->
        Process.exit(pid, :kill)

      3 ->
        Hyperlang.Scope.close(scope)
        Hyperlang.Scope.configure(scope, %{max_concurrent_runs: 2, wait_ms: 20})

      4 ->
        :ok
    end

    receive do
      {:DOWN, ^mon, :process, ^pid, _} -> :ok
    after
      1000 -> raise "runtime lifecycle did not finish"
    end

    wait(fn ->
      state = Hyperlang.Scope.runtime_snapshot()

      not Enum.any?(state.runtime_permits, fn {_, e} -> e.owner == pid end) and
        not Enum.any?(state.leases, fn {_, e} -> e.owner == pid end)
    end)

    :ok
  end

  defp soak_run(:normal, p, _scope), do: Kit.run(p.normal, :entry, [nil])

  defp soak_run(:wall, p, _scope),
    do: Kit.run(p.wall, :entry, [nil], policy: %{max_reductions: nil, wall_ms: 1})

  defp soak_run(:reductions, p, _scope),
    do: Kit.run(p.reductions, :entry, [nil], policy: %{max_reductions: 10_000, wall_ms: 500})

  defp soak_run(:heap, p, _scope),
    do: Kit.run(p.heap, :entry, [nil], policy: %{max_reductions: nil, heap_words: 100_000})

  defp soak_run(:crash, p, _scope), do: Kit.run(p.crash, :entry, [nil])

  defp soak_run(:binding, p, _scope) do
    Kit.run(p.binding, :entry, [nil],
      bindings: %{"broken" => {Hyperlang.Isolation.RaisingBinding, nil}}
    )
  end

  defp soak_run(:busy, p, scope), do: Kit.run(p.normal, :entry, [nil], policy: %{scope: scope})

  defp extra_noise_loop(mode, scope, owner) do
    receive do
      :stop ->
        Hyperlang.Scope.close(scope)

      {:DOWN, _, :process, ^owner, _} ->
        :ok
    after
      0 ->
        case mode do
          :channel ->
            channels = for _ <- 1..32, do: Hyperlang.Chan.newchan(scope, 1)

            Enum.each(channels, fn {handle, broker} ->
              Hyperlang.Chan.freechan(scope, handle, broker)
            end)

          :timer ->
            for n <- 1..32 do
              {:ok, id} =
                Hyperlang.MsgTimerServer.start_timer(scope, 64, 60_000, timer_entry(n))

              Hyperlang.MsgTimerServer.cancel(scope, id)
            end
        end

        extra_noise_loop(mode, scope, owner)
    end
  end

  defp collect_actor_results(0, acc, max_queue, _actor), do: {acc, max_queue}

  defp collect_actor_results(left, acc, max_queue, actor) do
    queue =
      case Process.info(actor, :message_queue_len) do
        {:message_queue_len, n} -> n
        nil -> 0
      end

    receive do
      {:overload_result, n, value} ->
        collect_actor_results(left - 1, [{n, value} | acc], max(max_queue, queue), actor)
    after
      10_000 -> raise "actor overload callers did not finish"
    end
  end

  defp collect_timer_storm(0, lateness, max_mailbox, _deadline),
    do: {lateness, max_mailbox}

  defp collect_timer_storm(left, lateness, max_mailbox, deadline) do
    server = Process.whereis(Hyperlang.MsgTimerServer)
    mailbox = elem(Process.info(server, :message_queue_len), 1)
    remaining = max(0, div(deadline - System.monotonic_time(:microsecond), 1_000))

    receive do
      {@timer_tag, _sender, {_scope, _index, due}} ->
        late = max(0, System.monotonic_time(:microsecond) - due)
        collect_timer_storm(left - 1, [late | lateness], max(max_mailbox, mailbox), deadline)
    after
      remaining -> raise "timer storm lost #{left} expiries"
    end
  end

  defp receive_timer(expected, deadline) do
    remaining = max(0, div(deadline - System.monotonic_time(:microsecond), 1_000))

    receive do
      {@timer_tag, _sender, ^expected} -> System.monotonic_time(:microsecond)
      {@timer_tag, _sender, _other} -> receive_timer(expected, deadline)
    after
      remaining -> raise "timer #{inspect(expected)} not delivered"
    end
  end

  defp flush_timer_messages do
    receive do
      {@timer_tag, _, _} -> flush_timer_messages()
    after
      0 -> :ok
    end
  end

  defp timer_entry(message) do
    %{kind: :send_after, target: :round2, msg: message, context: %{timer_sender_ctx: :round2}}
  end

  defp receive_result(tag) do
    receive do
      {^tag, result} -> result
    after
      2_000 -> :no_reply
    end
  end

  defp stored(table, ns) do
    case :ets.lookup(table, {ns, "n"}) do
      [{{^ns, "n"}, value}] -> value
      [] -> 0
    end
  end

  defp simplify({:ok, value, _meta}), do: {:ok, value}

  defp simplify({:error, %{category: category, details: %{"reason" => reason}}}),
    do: {:error, category, reason}

  defp simplify({:error, %{category: category, reason: reason}}), do: {:error, category, reason}
  defp simplify({:error, %{category: category}}), do: {:error, category}
  defp simplify(other), do: other

  defp category({:ok, _, _}), do: :ok
  defp category({:error, %{category: category}}), do: category
  defp category(other), do: other

  defp percentile(sorted, fraction) do
    index = max(0, ceil(length(sorted) * fraction) - 1)
    Enum.at(sorted, index)
  end

  defp gc_services do
    for name <- [Hyperlang.Scope, Hyperlang.Limits, Hyperlang.MsgTimerServer] do
      if pid = Process.whereis(name), do: :erlang.garbage_collect(pid)
    end

    :ok
  end

  defp wait(fun, attempts \\ 500)
  defp wait(_fun, 0), do: raise("state did not converge")

  defp wait(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(2)
      wait(fun, attempts - 1)
    end
  end

  defp spin, do: spin()

  defp churn do
    list = Enum.to_list(1..20_000)
    :erlang.garbage_collect()
    if length(list) == 20_000, do: churn()
  end
end
