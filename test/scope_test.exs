defmodule Hyperlang.ScopeTest do
  use ExUnit.Case, async: false
  alias Hyperlang.Scope
  alias Hyperlang.Test, as: Kit

  setup do
    scope = make_ref()
    assert :ok = Scope.configure(scope, %{})
    on_exit(fn -> Scope.close(scope) end)
    %{scope: scope}
  end

  defp wait(fun, n \\ 200)
  defp wait(_, 0), do: flunk("scope state did not converge")

  defp wait(fun, n) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(2)
          wait(fun, n - 1)
        )
  end

  test "scope admission bounds its queue, expires waits, and releases callers", %{scope: scope} do
    assert :ok = Scope.configure(scope, %{max_concurrent_runs: 1, max_queue: 1, wait_ms: 20})
    assert {:ok, first} = Scope.acquire(scope)
    waiter = Task.async(fn -> Scope.acquire(scope) end)
    wait(fn -> Scope.stats(scope).queued == 1 end)
    # A third, unrelated caller (the holder itself would nest re-entrantly).
    assert {:error, %{category: :busy, reason: :queue_full}} =
             Task.await(Task.async(fn -> Scope.acquire(scope) end))

    assert {:error, %{category: :busy, reason: :wait_timeout}} = Task.await(waiter)
    assert :ok = Scope.release(first)
    assert %{runs: 0, queued: 0} = Scope.stats(scope)
  end

  test "a queued live caller is admitted after release; a dead one is removed", %{scope: scope} do
    assert :ok = Scope.configure(scope, %{max_concurrent_runs: 1})
    {:ok, first} = Scope.acquire(scope)
    dead = spawn(fn -> Scope.acquire(scope) end)
    wait(fn -> Scope.stats(scope).queued == 1 end)
    Process.exit(dead, :kill)
    wait(fn -> Scope.stats(scope).queued == 0 end)
    parent = self()

    live =
      spawn(fn ->
        {:ok, lease} = Scope.acquire(scope)
        send(parent, {:admitted, lease})

        receive do
          :stop -> Scope.release(lease)
        end
      end)

    wait(fn -> Scope.stats(scope).queued == 1 end)
    Scope.release(first)
    assert_receive {:admitted, _}
    send(live, :stop)
    wait(fn -> Scope.stats(scope).runs == 0 end)
  end

  test "compile permits are bounded per scope and cleaned on caller death", %{scope: scope} do
    assert :ok = Scope.configure(scope, %{max_concurrent_compiles: 1, max_queue: 0})
    parent = self()

    worker =
      spawn(fn ->
        {:ok, _} = Scope.acquire(scope, :compile)
        send(parent, :compile_acquired)
        Process.sleep(:infinity)
      end)

    assert_receive :compile_acquired
    assert {:error, %{category: :busy}} = Scope.acquire(scope, :compile)
    Process.exit(worker, :kill)
    wait(fn -> Scope.stats(scope).compiles == 0 end)
    assert {:ok, lease} = Scope.acquire(scope, :compile)
    Scope.release(lease)
  end

  test "CPU rates throttle across processes, resume at refill, then terminate", %{scope: scope} do
    :ok = Scope.configure(scope, %{rate: %{quota: 10_000, period_ms: 50}, max_violations: 2})

    worker =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        receive do
          :go -> spin()
        end
      end)

    monitor = Process.monitor(worker)
    :ok = Scope.attach(scope, worker)
    send(worker, :go)
    wait(fn -> Scope.stats(scope).throttles >= 1 end)
    assert {:status, :suspended} = Process.info(worker, :status)
    assert %{last_offence: :cpu, max_reaction_us: us} = Scope.stats(scope)
    assert us < 25_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 500
    assert Scope.stats(scope).killed?
    assert {:error, %{category: :busy}} = Scope.acquire(scope)
  end

  test "scope aggregate heap ceiling includes every attached member", %{scope: scope} do
    workers = for _ <- 1..2, do: spawn(fn -> Process.sleep(:infinity) end)

    heap =
      Enum.map(workers, fn pid -> elem(Process.info(pid, :total_heap_size), 1) end) |> Enum.sum()

    :ok = Scope.configure(scope, %{heap_words: heap - 1})
    for pid <- workers, do: Scope.attach(scope, pid)
    wait(fn -> Scope.stats(scope).killed? end)
    wait(fn -> Enum.all?(workers, &(not Process.alive?(&1))) end)
    assert Scope.stats(scope).last_offence == :heap
  end

  test "allocation and GC churn is charged and throttled separately from CPU", %{scope: scope} do
    :ok =
      Scope.configure(scope, %{
        churn: %{heap_words: 1000, gcs: 2, period_ms: 80},
        max_violations: 10
      })

    worker =
      spawn(fn ->
        receive do
          :go -> churn()
        end
      end)

    :ok = Scope.attach(scope, worker)
    send(worker, :go)
    wait(fn -> Scope.stats(scope).throttles > 0 end)
    assert Scope.stats(scope).last_offence == :churn
    assert {:status, :suspended} = Process.info(worker, :status)
    Scope.close(scope)
    wait(fn -> not Process.alive?(worker) end)
  end

  test "compile CPU budget throttles compile work", %{scope: scope} do
    :ok =
      Scope.configure(scope, %{compile_rate: %{quota: 10_000, period_ms: 80}, max_violations: 10})

    worker =
      spawn(fn ->
        receive do
          :go -> spin()
        end
      end)

    :ok = Scope.attach(scope, worker, :compile)
    send(worker, :go)
    wait(fn -> Scope.stats(scope).throttles > 0 end)
    assert Scope.stats(scope).last_offence == :compile
    assert {:status, :suspended} = Process.info(worker, :status)
    Scope.close(scope)
    wait(fn -> not Process.alive?(worker) end)
  end

  test "worker priorities default to low and opt into normal for latency scopes", %{scope: scope} do
    bindings = %{"host" => %{priority: fn -> inspect(Process.info(self(), :priority)) end}}

    p =
      Kit.program!("result(_) -> host:priority().", %{
        bindings: bindings,
        terms: %{public: :erlang}
      })

    assert {:ok, "{:priority, :low}", _} = Kit.run(p, :entry, [nil], bindings: bindings)
    :ok = Scope.configure(scope, %{priority: :latency})

    assert {:ok, "{:priority, :normal}", _} =
             Kit.run(p, :entry, [nil], bindings: bindings, policy: %{scope: scope})

    old = Process.info(self(), :priority)

    assert {:ok, "{:priority, :low}", _} =
             Kit.run(p, :entry, [nil], bindings: bindings, policy: %{run_in_caller?: true})

    assert Process.info(self(), :priority) == old
  end

  test "channel and buffer quotas are scoped and reclaimed", %{scope: scope} do
    :ok = Scope.configure(scope, %{max_channels: 2, max_buffer_slots: 3})
    {h, b} = Hyperlang.Chan.newchan(scope, 2)
    assert is_integer(h)
    assert %{channels: 1, buffer_slots: 2} = Scope.stats(scope)

    assert %ErlangError{original: {:hyperlang_channel, :channel_quota_exceeded}} =
             catch_error(Hyperlang.Chan.newchan(scope, 2))

    assert %{channels: 1, buffer_slots: 2} = Scope.stats(scope)
    Hyperlang.Chan.freechan(scope, h, b)
    assert %{channels: 0, buffer_slots: 0} = Scope.stats(scope)
    {_h, b} = Hyperlang.Chan.newchan(scope, 3)
    Scope.close(scope)
    wait(fn -> not Process.alive?(b) end)
  end

  test "scope owner death cancels timers and kills its channel brokers" do
    parent = self()

    owner =
      spawn(fn ->
        scope = make_ref()
        :ok = Scope.configure(scope, %{})
        {_h, broker} = Hyperlang.Chan.newchan(scope, 1)
        send(parent, {:owned, scope, broker})
        Process.sleep(:infinity)
      end)

    assert_receive {:owned, scope, broker}
    Process.exit(owner, :kill)
    wait(fn -> Scope.stats(scope) == nil and not Process.alive?(broker) end)
  end

  test "invalid scope policy fails closed without changing the current policy", %{scope: scope} do
    for policy <- [
          %{max_queue: -1},
          %{priority: :high},
          %{sample_ms: 25},
          %{rate: %{}},
          %{unknown: 1}
        ] do
      assert {:error, :invalid_scope_policy} = Scope.configure(scope, policy)
    end

    assert Scope.policy(scope).priority == :background
  end

  test "whole source compilation shares one permit and uses the configured priority", %{
    scope: scope
  } do
    :ok = Scope.configure(scope, %{priority: :latency, max_concurrent_compiles: 1, max_queue: 0})

    assert {:priority, :normal} =
             Scope.with_scope(scope, fn ->
               Hyperlang.Compiler.run_bounded(
                 %{max_compile_ms: 500, max_compile_reductions: 200_000_000},
                 fn ->
                   Hyperlang.Compiler.run_bounded(
                     %{max_compile_ms: 500, max_compile_reductions: 200_000_000},
                     fn -> Process.info(self(), :priority) end
                   )
                 end
               )
             end)

    assert Scope.stats(scope).compiles == 0
  end

  test "admission is re-entrant for a process already running inside the scope", %{
    scope: scope
  } do
    :ok = Scope.configure(scope, %{max_concurrent_runs: 1, max_queue: 0})
    assert {:ok, outer} = Scope.acquire(scope)

    # The same holder nests without a new permit; an unrelated caller is denied.
    assert {:ok, nested} = Scope.acquire(scope)
    assert Scope.stats(scope).runs == 1
    other = Task.async(fn -> Scope.acquire(scope) end)
    assert {:error, %{reason: :queue_full}} = Task.await(other)

    # An attached member (a run worker) nests too.
    parent = self()

    member =
      spawn(fn ->
        receive do
          :go -> send(parent, {:member, Scope.acquire(scope)})
        end
      end)

    :ok = Scope.attach(scope, member)
    send(member, :go)
    assert_receive {:member, {:ok, _}}
    Scope.release(nested)
    Scope.release(outer)
    wait(fn -> Scope.stats(scope).runs == 0 end)
  end

  test "the compile worker heap allowance follows the scope's compile_heap_words", %{
    scope: scope
  } do
    heap_size = fn ->
      Scope.with_scope(scope, fn ->
        Hyperlang.Compiler.run_bounded(
          %{max_compile_ms: 500, max_compile_reductions: 200_000_000},
          fn ->
            {:max_heap_size, %{size: size}} = Process.info(self(), :max_heap_size)
            size
          end
        )
      end)
    end

    assert heap_size.() == 64_000_000
    :ok = Scope.configure(scope, %{compile_heap_words: 96_000_000, heap_words: 128_000_000})
    assert heap_size.() == 96_000_000
    assert {:error, :invalid_scope_policy} = Scope.configure(scope, %{compile_heap_words: 0})
  end

  test "a compiler dies with its requesting caller while the shared scope stays live", %{
    scope: scope
  } do
    parent = self()

    caller =
      spawn(fn ->
        Scope.with_scope(scope, fn ->
          Hyperlang.Compiler.run_bounded(
            %{max_compile_ms: 5000, max_compile_reductions: 200_000_000},
            fn ->
              send(parent, {:compiler, self()})
              spin()
            end
          )
        end)
      end)

    assert_receive {:compiler, compiler}
    monitor = Process.monitor(compiler)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^compiler, :killed}, 500
    wait(fn -> Scope.stats(scope).compiles == 0 and Scope.stats(scope).members == 0 end)
    refute Scope.stats(scope).killed?
  end

  test "nested entries retain the outer process's scope accounting", %{scope: scope} do
    worker = spawn(fn -> Process.sleep(:infinity) end)
    :ok = Scope.attach(scope, worker)
    :ok = Scope.attach(scope, worker)
    :ok = Scope.detach(scope, worker)
    assert Scope.stats(scope).members == 1
    :ok = Scope.detach(scope, worker)
    assert Scope.stats(scope).members == 0
    Process.exit(worker, :kill)
  end

  defp spin, do: spin()

  defp churn do
    list = Enum.to_list(1..10_000)
    :erlang.garbage_collect()
    if length(list) == 10_000, do: churn()
  end

  test "nested compile borrows only compile permits and cannot bypass global admission", %{
    scope: scope
  } do
    {:ok, run} = Scope.acquire(scope)
    {:ok, compile} = Scope.acquire(scope, :compile)
    assert %{runs: 1, compiles: 1} = Scope.stats(scope)
    {:ok, nested} = Scope.acquire(scope, :compile)
    assert %{compiles: 1} = Scope.stats(scope)
    for lease <- [nested, compile, run], do: Scope.release(lease)
  end

  test "cross-scope nesting takes a permit and rejects a capacity cycle immediately", %{
    scope: scope
  } do
    other = make_ref()
    :ok = Scope.configure(other, %{max_concurrent_runs: 1, wait_ms: 1_000})
    on_exit(fn -> Scope.close(other) end)
    parent = self()

    holder =
      spawn(fn ->
        {:ok, _} = Scope.acquire(other)
        send(parent, :held)
        Process.sleep(:infinity)
      end)

    assert_receive :held
    {:ok, lease} = Scope.acquire(scope)
    {us, result} = :timer.tc(fn -> Scope.acquire(other) end)
    assert {:error, %{category: :busy, reason: :admission_cycle}} = result
    assert us < 50_000
    Process.exit(holder, :kill)
    wait(fn -> Scope.stats(other).runs == 0 end)
    {:ok, independent} = Scope.acquire(other)
    assert Scope.stats(other).runs == 1
    Scope.release(independent)
    Scope.release(lease)
  end

  test "runtime admission reserves capacity for latency scopes", %{scope: scope} do
    previous = Application.get_env(:hyperlang, :runtime_concurrency)
    Application.put_env(:hyperlang, :runtime_concurrency, 2)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hyperlang, :runtime_concurrency, previous),
        else: Application.delete_env(:hyperlang, :runtime_concurrency)
    end)

    parent = self()

    first =
      spawn(fn ->
        Scope.running(scope, fn ->
          send(parent, :runtime_held)

          receive do
            :stop -> :ok
          end
        end)
      end)

    assert_receive :runtime_held
    latency = make_ref()
    :ok = Scope.configure(latency, %{priority: :latency})
    on_exit(fn -> Scope.close(latency) end)
    Scope.running(latency, fn -> assert Scope.stats(latency).runnable == 1 end)
    assert Scope.stats(scope).runnable == 1
    # Live leases no longer consume node-wide runnable slots.
    {:ok, live} = Scope.acquire(scope)
    Scope.release(live)
    send(first, :stop)
    wait(fn -> Scope.stats(scope).runnable == 0 end)
  end

  test "compile heaps are independent of the runtime aggregate heap", %{scope: scope} do
    :ok = Scope.configure(scope, %{heap_words: 1, compile_heap_words: 4_000_000})

    assert 200_000 ==
             Scope.with_scope(scope, fn ->
               Hyperlang.Compiler.run_bounded(
                 %{max_compile_ms: 1_000, max_compile_reductions: 200_000_000},
                 fn ->
                   values = List.duplicate(7, 200_000)
                   Process.sleep(10)
                   length(values)
                 end
               )
             end)

    refute Scope.stats(scope).killed?
    assert Scope.stats(scope).compile_reductions > 0
  end

  test "R2-5 scope enforcement protects the scope owner on all member kill paths", %{scope: scope} do
    :ok = Scope.configure(scope, %{heap_words: 1})
    fault = :atomics.new(1, [])
    assert {:error, %{category: :busy}} = Scope.attach(scope, self(), :run, 0, nil, fault)
    assert {:error, %{category: :busy, reason: :scope_terminated}} = Scope.fault_reason(fault)
    assert Process.alive?(self())
    assert :ok = Scope.close(scope)
    assert Process.alive?(self())
  end

  test "R2-5 an in-caller host survives scope closure and returns a typed fault", %{scope: scope} do
    parent = self()

    bindings = %{
      "host" => %{
        wait: fn ->
          send(parent, {:host_entered, self()})

          receive do
            :continue -> 1
          end
        end
      }
    }

    p =
      Kit.program!("result(_) -> host:wait().", %{bindings: bindings, terms: %{public: :erlang}})

    # Preload before closing to isolate the active runtime from cold compilation.
    Hyperlang.module(p)

    host =
      spawn(fn ->
        result =
          Kit.run(p, :entry, [nil],
            bindings: bindings,
            policy: %{scope: scope, run_in_caller?: true}
          )

        send(parent, {:host_result, result, Process.alive?(self())})
      end)

    assert_receive {:host_entered, ^host}, 1_000
    Scope.close(scope)
    assert Process.alive?(host)
    send(host, :continue)

    assert_receive {:host_result,
                    {:error, %{category: :busy, details: %{"reason" => "scope_closed"}}}, true},
                   1_000
  end

  test "R2-5 an in-caller scope heap offence returns an error without killing the host", %{
    scope: scope
  } do
    p = Kit.program!("result(_) -> 1.", %{terms: %{public: :erlang}})
    Hyperlang.module(p)
    :ok = Scope.configure(scope, %{heap_words: 1})

    assert {:error, %{category: :busy, details: %{"reason" => "scope_terminated"}}} =
             Kit.run(p, :entry, [nil], policy: %{scope: scope, run_in_caller?: true})

    assert Process.alive?(self())
  end

  test "timer pending deliveries retain quota and scope closure stops their resolver", %{
    scope: scope
  } do
    parent = self()

    Application.put_env(:hyperlang, :guest_msg_resolver, fn _, _ ->
      send(parent, {:delivery_blocked, self()})

      receive do
        :release -> {:error, :noproc}
      end
    end)

    on_exit(fn -> Application.delete_env(:hyperlang, :guest_msg_resolver) end)
    entry = %{kind: :send_after, target: "slow", msg: 1, context: %{}}
    {:ok, id} = Hyperlang.MsgTimerServer.start_timer(scope, 1, 0, entry)
    assert_receive {:delivery_blocked, deliverer}

    assert {:error, :timer_quota_exceeded} =
             Hyperlang.MsgTimerServer.start_timer(scope, 1, 0, entry)

    assert false == Hyperlang.MsgTimerServer.read(scope, id)
    assert false == Hyperlang.MsgTimerServer.cancel(scope, id)
    Scope.close(scope)
    wait(fn -> not Process.alive?(deliverer) end)
    refute Map.has_key?(:sys.get_state(Hyperlang.MsgTimerServer).deliverers, scope)
  end

  test "obsolete spec and Limits aliases fail at the API boundary" do
    p = Kit.program!("result(_) -> 1.", %{terms: %{public: :erlang}})

    for key <- ["bindings", "syscall", "policy"] do
      assert {:error, %{category: :api}} = Hyperlang.run(%{key => %{}}, p, :entry, [nil])
    end

    assert {:error, %{category: :api}} = Hyperlang.run(%{policy: %{budget: 1}}, p, :entry, [nil])

    for key <- [:cpu_max, :reduction_rate, :budget, :reduction_budget] do
      assert_raise ArgumentError, fn -> Hyperlang.Limits.group(%{key => 1}) end
    end
  end

  test "nested workers share aggregate CPU limits and die with the ancestor", %{scope: scope} do
    inner = Kit.program!("result(_) -> spin(). spin() -> spin().", %{terms: %{public: :erlang}})
    Hyperlang.module(inner)

    bindings = %{
      "host" => %{
        nest: fn ->
          Kit.run(inner, :entry, [nil],
            policy: %{scope: scope, max_reductions: nil, wall_ms: 1_000}
          )
          |> inspect()
        end
      }
    }

    outer =
      Kit.program!("result(_) -> host:nest().", %{bindings: bindings, terms: %{public: :erlang}})

    Hyperlang.module(outer)

    :ok =
      Scope.configure(scope, %{
        max_concurrent_runs: 1,
        rate: %{quota: 10_000, period_ms: 100},
        max_violations: 1,
        sample_ms: 1
      })

    assert {:error, %{category: :busy}} =
             Kit.run(outer, :entry, [nil],
               bindings: bindings,
               policy: %{scope: scope, max_reductions: nil}
             )

    wait(fn -> Scope.stats(scope).members == 0 end)
    assert Scope.stats(scope).last_offence == :cpu
  end

  test "an outer wall deadline terminates its nested worker", %{scope: scope} do
    inner = Kit.program!("result(_) -> spin(). spin() -> spin().", %{terms: %{public: :erlang}})
    Hyperlang.module(inner)

    bindings = %{
      "host" => %{
        nest: fn ->
          Kit.run(inner, :entry, [nil],
            policy: %{scope: scope, max_reductions: nil, wall_ms: 1_000}
          )
          |> inspect()
        end
      }
    }

    outer =
      Kit.program!("result(_) -> host:nest().", %{bindings: bindings, terms: %{public: :erlang}})

    Hyperlang.module(outer)
    :ok = Scope.configure(scope, %{max_concurrent_runs: 1})

    assert {:error, %{category: :timeout}} =
             Kit.run(outer, :entry, [nil],
               bindings: bindings,
               policy: %{scope: scope, max_reductions: nil, wall_ms: 10}
             )

    wait(fn -> Scope.stats(scope).members == 0 end)
    assert Scope.stats(scope).runs == 0
  end

  test "termination markers survive immediate scope-name reuse", %{scope: scope} do
    parent = self()
    worker = spawn(fn -> Process.sleep(:infinity) end)
    monitor = Process.monitor(worker)
    fault = :atomics.new(1, [])
    Scope.attach(scope, worker, :run, 0, parent, fault)
    Scope.close(scope)
    Scope.configure(scope, %{})
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    assert {:error, %{reason: :scope_closed}} = Scope.fault_reason(fault)
    refute Scope.stats(scope).killed?
  end

  test "channel and buffer reservations are exact under concurrent allocation", %{scope: scope} do
    for {channels, slots, expected} <- [{7, 100, 7}, {20, 10, 5}] do
      :ok = Scope.configure(scope, %{max_channels: channels, max_buffer_slots: slots})
      parent = self()

      workers =
        for _ <- 1..64 do
          spawn_monitor(fn ->
            send(parent, {:ready, self()})

            receive do
              :allocate -> :ok
            end

            result =
              try do
                {:ok, Hyperlang.Chan.newchan(scope, 2)}
              rescue
                e in ErlangError -> {:error, e.original}
              end

            send(parent, {:allocated, self(), result})

            receive do
              :release -> :ok
            end

            case result do
              {:ok, {h, b}} -> Hyperlang.Chan.freechan(scope, h, b)
              _ -> :ok
            end
          end)
        end

      for {pid, _} <- workers, do: assert_receive({:ready, ^pid}, 5000)
      for {pid, _} <- workers, do: send(pid, :allocate)

      results =
        for {pid, _} <- workers do
          assert_receive {:allocated, ^pid, result}, 5000
          result
        end

      assert Enum.count(results, &match?({:ok, _}, &1)) == expected

      assert Enum.count(results, &(&1 == {:error, {:hyperlang_channel, :channel_quota_exceeded}})) ==
               64 - expected

      assert %{channels: ^expected, buffer_slots: used} = Scope.stats(scope)
      assert used == expected * 2
      for {pid, _} <- workers, do: send(pid, :release)

      for {pid, monitor} <- workers,
          do: assert_receive({:DOWN, ^monitor, :process, ^pid, :normal}, 5000)

      assert %{channels: 0, buffer_slots: 0} = Scope.stats(scope)
    end
  end

  test "start-channel reservations compete atomically with ordinary channels", %{scope: scope} do
    :ok = Scope.configure(scope, %{max_channels: 8, max_buffer_slots: 100})
    parent = self()

    workers =
      for n <- 1..64 do
        spawn_monitor(fn ->
          send(parent, {:ready, self()})

          receive do
            :allocate -> :ok
          end

          result =
            if rem(n, 2) == 0 do
              handle = :erlang.unique_integer([:positive])

              case Scope.reserve_startchan(scope, handle, parent) do
                :ok -> {:start, handle}
                {:error, :channel_quota_exceeded} -> :full
              end
            else
              try do
                {:channel, Hyperlang.Chan.newchan(scope, 1)}
              rescue
                ErlangError -> :full
              end
            end

          send(parent, {:reserved, self(), result})

          receive do
            :release -> :ok
          end

          case result do
            {:start, handle} -> Scope.release_startchan(scope, handle)
            {:channel, {h, b}} -> Hyperlang.Chan.freechan(scope, h, b)
            :full -> :ok
          end
        end)
      end

    for {pid, _} <- workers, do: assert_receive({:ready, ^pid}, 5000)
    for {pid, _} <- workers, do: send(pid, :allocate)

    results =
      for {pid, _} <- workers do
        assert_receive {:reserved, ^pid, result}, 5000
        result
      end

    assert Enum.count(results, &(&1 != :full)) == 8
    assert {:error, :channel_quota_exceeded} = Scope.reserve_startchan(scope, :overflow, self())
    for {pid, _} <- workers, do: send(pid, :release)

    for {pid, monitor} <- workers,
        do: assert_receive({:DOWN, ^monitor, :process, ^pid, :normal}, 5000)

    assert %{channels: 0, buffer_slots: 0} = Scope.stats(scope)
  end

  test "short-lived channel churn remains charged after free", %{scope: scope} do
    :ok =
      Scope.configure(scope, %{
        churn: %{heap_words: 1, gcs: 100, period_ms: 100},
        max_violations: 1
      })

    {handle, broker} = Hyperlang.Chan.newchan(scope, 1)
    Hyperlang.Chan.freechan(scope, handle, broker)
    wait(fn -> Scope.stats(scope).killed? end)
    assert %{channels: 0, growth_words: growth, usage_reductions: cpu} = Scope.stats(scope)
    assert growth > 1
    assert cpu > 0
  end

  test "a closing controller cannot overwrite a reused scope", %{scope: scope} do
    old = Hyperlang.Scope.Channels.address(scope)
    monitor = Process.monitor(old)
    :sys.suspend(old)
    ref = make_ref()
    send(old, {:"$gen_call", {self(), ref}, {:configure, Scope.policy(scope)}})
    Scope.close(scope)
    :ok = Scope.configure(scope, %{max_channels: 1})
    current = Hyperlang.Scope.Channels.address(scope)
    assert current != old
    :sys.resume(old)
    assert_receive {^ref, :ok}, 5000
    assert_receive {:DOWN, ^monitor, :process, ^old, :normal}, 5000
    assert Hyperlang.Scope.Channels.address(scope) == current
    {h, b} = Hyperlang.Chan.newchan(scope, 1)
    assert %{channels: 1} = Scope.stats(scope)
    Hyperlang.Chan.freechan(scope, h, b)
  end

  test "channel-only heap growth is enforced without a guest worker", %{scope: scope} do
    :ok = Scope.configure(scope, %{heap_words: 10_000})
    {_h, broker} = Hyperlang.Chan.newchan(scope, 1)
    :ok = Hyperlang.Chan.csend(broker, Enum.to_list(1..20_000))
    wait(fn -> Scope.stats(scope).killed? end)
    assert Scope.stats(scope).last_offence == :heap
    wait(fn -> Scope.stats(scope).channels == 0 end)
  end

  test "channel and worker heaps share one aggregate budget", %{scope: scope} do
    {_h, broker} = Hyperlang.Chan.newchan(scope, 1)
    :ok = Hyperlang.Chan.csend(broker, Enum.to_list(1..6_000))
    parent = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        values = Enum.to_list(1..6_000)
        send(parent, {:heap_ready, self()})

        receive do
          :count -> send(parent, length(values))
        end
      end)

    assert_receive {:heap_ready, ^worker}, 5000

    words = fn pid ->
      info = Process.info(pid, [:total_heap_size, :memory])
      max(info[:total_heap_size], div(info[:memory], :erlang.system_info(:wordsize)))
    end

    channel_heap = words.(broker)
    worker_heap = words.(worker)
    limit = max(channel_heap, worker_heap) + div(min(channel_heap, worker_heap), 2)
    :ok = Scope.configure(scope, %{heap_words: limit})
    Scope.attach(scope, worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 5000
    assert Scope.stats(scope).last_offence == :heap
    wait(fn -> Scope.stats(scope).channels == 0 end)
  end

  test "rate-throttled allocation waits outside Registry and closes without revival", %{
    scope: scope
  } do
    :ok =
      Scope.configure(scope, %{
        rate: %{quota: 1, period_ms: 1_000},
        max_violations: 100,
        sample_ms: 1
      })

    {h, b} = Hyperlang.Chan.newchan(scope, 1)
    Hyperlang.Chan.freechan(scope, h, b)
    wait(fn -> Scope.stats(scope).throttles > 0 end)

    task =
      Task.async(fn ->
        try do
          {:ok, Hyperlang.Chan.newchan(scope, 1)}
        rescue
          e in ErlangError -> {:error, e.original}
        end
      end)

    wait(fn ->
      case Process.info(task.pid, :current_stacktrace) do
        {:current_stacktrace, stack} ->
          Enum.any?(stack, fn {module, _, _, _} -> module == Hyperlang.Scope.Channels end)

        _ ->
          false
      end
    end)

    other = make_ref()
    :ok = Scope.configure(other, %{})
    {other_h, other_b} = Hyperlang.Chan.newchan(other, 1)
    Hyperlang.Chan.freechan(other, other_h, other_b)
    Scope.close(other)
    Scope.close(scope)
    assert Task.await(task, 5000) == {:error, {:hyperlang_channel, :channel_quota_exceeded}}
    assert Scope.stats(scope) == nil
  end

  defp limits_groups, do: map_size(:sys.get_state(Hyperlang.Limits).groups)

  defp runtime_state(scope) do
    snapshot = Scope.runtime_snapshot()

    %{
      leases: Enum.count(snapshot.leases, fn {_, lease} -> lease.scope == scope end),
      permits: Enum.count(snapshot.runtime_permits, fn {_, entry} -> entry.scope == scope end)
    }
  end

  test "run workers release their lease exactly once; concurrent callers never over-admit", %{
    scope: scope
  } do
    for priority <- [:background, :latency] do
      :ok =
        Scope.configure(scope, %{
          priority: priority,
          max_concurrent_runs: 2,
          max_queue: 64,
          wait_ms: 30_000
        })

      live = :atomics.new(2, [])

      bindings = %{
        "host" => %{
          enter: fn ->
            now = :atomics.add_get(live, 1, 1)

            update_max = fn update ->
              seen = :atomics.get(live, 2)

              if now > seen and :atomics.compare_exchange(live, 2, seen, now) != :ok,
                do: update.(update)
            end

            update_max.(update_max)
            Process.sleep(1)
            :atomics.sub(live, 1, 1)
            1
          end
        }
      }

      p =
        Kit.program!("result(_) -> host:enter().", %{
          bindings: bindings,
          terms: %{public: :erlang}
        })

      Hyperlang.module(p)
      groups = limits_groups()

      results =
        1..24
        |> Enum.map(fn _ ->
          Task.async(fn ->
            for _ <- 1..5,
                do: Kit.run(p, :entry, [nil], bindings: bindings, policy: %{scope: scope})
          end)
        end)
        |> Enum.flat_map(&Task.await(&1, 30_000))

      assert length(results) == 120
      assert Enum.all?(results, &match?({:ok, 1, _}, &1))
      assert :atomics.get(live, 2) == 2
      assert %{runs: 0, queued: 0, members: 0} = Scope.stats(scope)
      assert runtime_state(scope) == %{leases: 0, permits: 0}
      wait(fn -> limits_groups() == groups end)
    end
  end

  test "a run worker killed before detaching leaves no lease, lifetime or limits group", %{
    scope: scope
  } do
    p = Kit.program!("result(_) -> spin(). spin() -> spin().", %{terms: %{public: :erlang}})
    Hyperlang.module(p)
    :ok = Scope.configure(scope, %{priority: :latency, max_concurrent_runs: 1})
    groups = limits_groups()

    for _ <- 1..20 do
      assert {:error, %{category: :timeout}} =
               Kit.run(p, :entry, [nil], policy: %{scope: scope, max_reductions: nil, wall_ms: 5})
    end

    wait(fn -> runtime_state(scope) == %{leases: 0, permits: 0} end)
    assert %{runs: 0, queued: 0} = Scope.stats(scope)
    wait(fn -> limits_groups() == groups end)
    # The lease is free: the next run is admitted immediately.
    assert {:error, %{category: :timeout}} =
             Kit.run(p, :entry, [nil], policy: %{scope: scope, max_reductions: nil, wall_ms: 5})
  end

  test "a nested in-caller run inside a worker reuses the worker's runtime lifetime", %{
    scope: scope
  } do
    inner = Kit.program!("result(N) -> N + 1.", %{terms: %{public: :erlang}})
    Hyperlang.module(inner)

    bindings = %{
      "host" => %{
        nest: fn ->
          {:ok, value, _} =
            Kit.run(inner, :entry, [41], policy: %{scope: scope, run_in_caller?: true})

          value
        end
      }
    }

    outer =
      Kit.program!("result(_) -> A = host:nest(), B = host:nest(), A + B.", %{
        bindings: bindings,
        terms: %{public: :erlang}
      })

    for priority <- [:background, :latency] do
      :ok = Scope.configure(scope, %{priority: priority})

      assert {:ok, 84, _} =
               Kit.run(outer, :entry, [nil], bindings: bindings, policy: %{scope: scope})

      assert runtime_state(scope) == %{leases: 0, permits: 0}
      assert %{runs: 0, members: 0} = Scope.stats(scope)
    end
  end

  test "latency waits boost only the wait; Scope and Limits idle at high priority", %{
    scope: scope
  } do
    bindings = %{"host" => %{priority: fn -> inspect(Process.info(self(), :priority)) end}}

    p =
      Kit.program!("result(_) -> host:priority().", %{
        bindings: bindings,
        terms: %{public: :erlang}
      })

    :ok = Scope.configure(scope, %{priority: :latency})
    old = Process.info(self(), :priority)

    assert {:ok, "{:priority, :normal}", _} =
             Kit.run(p, :entry, [nil], bindings: bindings, policy: %{scope: scope})

    assert Process.info(self(), :priority) == old
    assert {:ok, _} = Scope.with_scope(scope, fn -> {:ok, Scope.stats(scope)} end)
    assert Process.info(self(), :priority) == old

    for server <- [Scope, Hyperlang.Limits] do
      pid = Process.whereis(server)
      wait(fn -> Process.info(pid, :priority) == {:priority, :high} end)
    end

    # A handler runs at normal priority, even when an idle server woke at high.
    assert Scope.idle_priority(fn -> Process.info(self(), :priority) end) ==
             {:priority, :normal}

    Process.flag(:priority, :normal)
  end
end
