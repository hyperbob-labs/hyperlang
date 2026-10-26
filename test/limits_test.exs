defmodule Hyperlang.LimitsTest do
  use ExUnit.Case, async: false

  defp spin do
    receive do
      :stop -> :ok
    after
      0 -> spin()
    end
  end

  defp spin(counter) do
    :atomics.add(counter, 1, 1)

    receive do
      :stop -> :ok
    after
      0 -> spin(counter)
    end
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  test "durable members are metered, throttled, resumed, and pruned" do
    group = Hyperlang.Limits.group(%{rate: %{quota: 10_000, period_ms: 100}})
    counter = :atomics.new(1, signed: false)
    pid = spawn(fn -> spin(counter) end)
    assert :ok = Hyperlang.Limits.attach(group, pid, %{})

    assert wait_until(fn -> Hyperlang.Limits.stat(group).nr_throttled > 0 end)
    assert %{usage_reductions: used, nr_throttled: throttled} = Hyperlang.Limits.stat(group)
    assert used > 0
    assert throttled > 0

    before_rollover = :atomics.get(counter, 1)
    Process.sleep(120)
    assert Process.alive?(pid)
    assert :atomics.get(counter, 1) > before_rollover
    send(pid, :stop)
    assert wait_until(fn -> not Process.alive?(pid) end)
  end

  test "ceiling and wall limits use the configured kill closure" do
    parent = self()

    kill = fn pid, reason ->
      send(parent, {:limited, pid, reason})
      Process.exit(pid, :kill)
    end

    ceiling = Hyperlang.Limits.group(%{ceiling: 100})
    ceiling_pid = spawn(fn -> spin() end)
    assert :ok = Hyperlang.Limits.attach(ceiling, ceiling_pid, %{kill: kill})
    assert_receive {:limited, ^ceiling_pid, :ceiling}, 1_000

    wall = Hyperlang.Limits.group(%{})
    wall_pid = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = Hyperlang.Limits.attach(wall, wall_pid, %{wall_ms: 20, kill: kill})
    assert_receive {:limited, ^wall_pid, :wall_ms}, 1_000
  end

  test "ephemeral slots enforce completion and reuse their atomics" do
    group = Hyperlang.Limits.group(%{})
    first = Hyperlang.Limits.arm(group, self(), %{ceiling: 1})

    Enum.reduce(1..100, 0, &+/2)
    assert {:error, :ceiling} = Hyperlang.Limits.disarm(group, self(), first)

    second = Hyperlang.Limits.arm(group, self(), %{wall_ms: 100})
    assert second > first
    assert :ok = Hyperlang.Limits.disarm(group, self(), second)
  end

  test "max_procs bounds the guest children attached to a group" do
    group = Hyperlang.Limits.group(%{max_procs: 2})
    children = for _ <- 1..2, do: spawn(fn -> Process.sleep(:infinity) end)

    for pid <- children do
      assert :ok = Hyperlang.Limits.attach(group, pid, %{spawned?: true})
    end

    assert %{procs: 2, max_procs: 2} = Hyperlang.Limits.stat(group)

    rejected = spawn(fn -> Process.sleep(:infinity) end)
    assert {:error, :eagain} = Hyperlang.Limits.attach(group, rejected, %{spawned?: true})

    # A worker is not a guest child, so it never consumes a max_procs slot.
    worker = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = Hyperlang.Limits.attach(group, worker, %{})

    # A dead child frees its slot through the group's own monitor.
    [first | _] = children
    Process.exit(first, :kill)
    assert wait_until(fn -> Hyperlang.Limits.stat(group).procs == 1 end)
    assert :ok = Hyperlang.Limits.attach(group, rejected, %{spawned?: true})

    Enum.each([rejected, worker | children], &Process.exit(&1, :kill))
  end

  test "detach_children kills the guest children and keeps the workers" do
    group = Hyperlang.Limits.group(%{max_procs: 1})
    child = spawn(fn -> Process.sleep(:infinity) end)
    worker = spawn(fn -> spin() end)

    assert :ok = Hyperlang.Limits.attach(group, child, %{spawned?: true})
    assert :ok = Hyperlang.Limits.attach(group, worker, %{})
    assert %{procs: 1} = Hyperlang.Limits.stat(group)

    assert :ok = Hyperlang.Limits.detach_children(group)
    assert %{procs: 0} = Hyperlang.Limits.stat(group)
    assert wait_until(fn -> not Process.alive?(child) end)

    # The freed slot is immediately reusable by the next evaluation.
    next = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = Hyperlang.Limits.attach(group, next, %{spawned?: true})

    before = Hyperlang.Limits.stat(group).usage_reductions
    assert wait_until(fn -> Hyperlang.Limits.stat(group).usage_reductions > before end)

    Enum.each([child, worker, next], &Process.exit(&1, :kill))
  end

  test "heap options are applied when a durable member attaches" do
    parent = self()
    group = Hyperlang.Limits.group(%{})

    pid =
      spawn(fn ->
        receive do
          {:attach, group} ->
            :ok = Hyperlang.Limits.attach(group, self(), %{heap_words: 20_000})
            send(parent, {:heap, Process.info(self(), :message_queue_data)})
        end
      end)

    send(pid, {:attach, group})
    assert_receive {:heap, {:message_queue_data, :on_heap}}, 1_000
    Hyperlang.Limits.detach(group, pid)
  end

  test "deleted groups cannot be resurrected by a late attach or limit" do
    group = Hyperlang.Limits.group(%{})
    :ok = Hyperlang.Limits.delete(group)
    assert :ok = Hyperlang.Limits.delete(group)
    assert {:error, :closed} = Hyperlang.Limits.attach(group, self(), %{})
    assert {:error, :closed} = Hyperlang.Limits.limit(group, %{ceiling: 100})
    refute Map.has_key?(:sys.get_state(Hyperlang.Limits).groups, group.id)
  end

  test "group owner death kills its children and removes all group monitors" do
    parent = self()

    owner =
      spawn(fn ->
        group = Hyperlang.Limits.group(%{})
        child = spawn(fn -> Process.sleep(:infinity) end)
        :ok = Hyperlang.Limits.attach(group, child, %{spawned?: true})
        send(parent, {:owned_group, group, child})
        Process.sleep(:infinity)
      end)

    assert_receive {:owned_group, group, child}
    monitor = Process.monitor(child)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^child, :killed}
    refute Map.has_key?(:sys.get_state(Hyperlang.Limits).groups, group.id)

    refute Enum.any?(:sys.get_state(Hyperlang.Limits).monitors, fn {_, {id, _, _}} ->
             id == group.id
           end)
  end

  test "disarmed deadline generations cannot terminate a subsequent call" do
    group = Hyperlang.Limits.group(%{})
    first = Hyperlang.Limits.arm(group, self(), %{wall_ms: 20})
    assert :ok = Hyperlang.Limits.disarm(group, self(), first)
    second = Hyperlang.Limits.arm(group, self(), %{wall_ms: 1000})
    Process.sleep(40)
    assert :ok = Hyperlang.Limits.disarm(group, self(), second)
    assert :ok = Hyperlang.Limits.delete(group)
  end

  test "deleting a throttled group resumes its surviving host owner" do
    parent = self()

    owner =
      spawn(fn ->
        group = Hyperlang.Limits.group(%{rate: %{quota: 1000, period_ms: 1000}})
        :ok = Hyperlang.Limits.attach(group, self(), %{owner?: true})
        send(parent, {:throttled_owner_group, group})
        spin()
      end)

    monitor = Process.monitor(owner)
    assert_receive {:throttled_owner_group, group}
    assert wait_until(fn -> Hyperlang.Limits.stat(group).nr_throttled > 0 end)
    assert {:status, :suspended} = Process.info(owner, :status)
    assert :ok = Hyperlang.Limits.delete(group)
    assert wait_until(fn -> Process.info(owner, :status) != {:status, :suspended} end)
    assert Process.alive?(owner)
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
  end
end
