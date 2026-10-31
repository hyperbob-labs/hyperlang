defmodule Hyperlang.Isolation.Contention do
  @moduledoc false
  alias Hyperlang.Test, as: Kit

  defp program(source), do: Kit.program!(source, %{terms: %{public: :erlang}})
  defp category({:ok, _, _}), do: :ok
  defp category({:error, %{category: category}}), do: category
  defp category(other), do: other

  def wall do
    p = program("result(_) -> spin(). spin() -> spin().")

    for _ <- 1..20,
        do: Kit.run(p, :entry, [nil], policy: %{max_reductions: nil, wall_ms: 1})

    samples =
      for _ <- 1..1000 do
        {us, result} =
          :timer.tc(fn ->
            Kit.run(p, :entry, [nil], policy: %{max_reductions: nil, wall_ms: 1})
          end)

        {us, category(result)}
      end

    times = Enum.map(samples, &elem(&1, 0)) |> Enum.sort()

    %{
      samples: 1000,
      requested_us: 1000,
      p50_us: Enum.at(times, 499),
      p99_us: Enum.at(times, 989),
      overshoot_p99_us: Enum.at(times, 989) - 1000,
      mean_us: Enum.sum(times) / 1000,
      outcomes: Enum.frequencies_by(samples, &elem(&1, 1))
    }
  end

  def noisy(mode, n, enabled, single_scope \\ false) do
    p = program("result(N) -> loop(N). loop(0) -> 1; loop(N) -> loop(N-1).")
    cpu = program("result(_) -> spin(). spin() -> spin().")
    memory = program("result(_) -> grow(0, []). grow(N,L) -> grow(N+1, [<<N:80000>>|L]).")
    # Preload the noise code outside its measured scope: runtime CPU/heap
    # probes must not accidentally measure a throttled cold compilation.
    :ok = Hyperlang.load(cpu)
    :ok = Hyperlang.load(memory)
    victim_scope = make_ref()
    # The victim uses reserved latency capacity in both noise-policy modes.
    configure(victim_scope, %{priority: :latency, max_concurrent_runs: 1}, true)
    victim_policy = %{max_reductions: nil, scope: victim_scope}
    for _ <- 1..100, do: Kit.run(p, :entry, [500], policy: victim_policy)
    owner = self()
    common_scope = make_ref()

    attackers =
      for i <- 1..n//1 do
        scope = if single_scope, do: common_scope, else: make_ref()

        configure(
          scope,
          %{
            max_concurrent_runs: 1,
            max_queue: 1,
            priority: :background,
            rate: if(mode == :cpu, do: %{quota: 100_000, period_ms: 100}, else: nil),
            churn:
              if(mode == :memory, do: %{heap_words: 200_000, gcs: 20, period_ms: 100}, else: nil),
            compile_rate: if(mode == :compile, do: %{quota: 250_000, period_ms: 100}, else: nil),
            max_violations: 1000,
            heap_words: 4_000_000
          },
          enabled
        )

        pid =
          spawn(fn ->
            mon = Process.monitor(owner)
            send(owner, {:ready, self()})
            noise(mode, scope, enabled, cpu, memory, i, mon)
          end)

        {pid, scope}
      end

    Enum.each(attackers, fn {pid, _scope} ->
      receive do
        {:ready, ^pid} -> :ok
      after
        1000 -> raise "noise startup"
      end
    end)

    # Rate phase. CPU, churn and compile quotas refill every 100 ms. A
    # rate-limited tenant spends each period's budget in a burst after the
    # refill and stays suspended for the rest, so back-to-back requests that
    # end before the first refill never meet a burst. The k-th request starts
    # `k * 400 / 1000` ms into the window instead: the 1,000 requests cover
    # four whole periods, and each phase of the period gets the same share of
    # them, refill bursts included. Between requests the caller polls without
    # sleeping, like `quiesce/0`. Every cell, unloaded or not, policy on or
    # off, uses the same spacing.
    Process.sleep(if n == 0, do: 0, else: 50)
    window_start = System.monotonic_time(:microsecond)

    samples =
      for k <- 0..999 do
        await_us(window_start + div(k * 400_000, 1000))
        {us, result} = :timer.tc(fn -> Kit.run(p, :entry, [500], policy: victim_policy) end)
        {us, category(result)}
      end

    window_ms = div(System.monotonic_time(:microsecond) - window_start, 1000)

    Enum.each(attackers, fn {pid, _scope} -> Process.exit(pid, :kill) end)

    Enum.each(attackers, fn {pid, _scope} ->
      monitor = Process.monitor(pid)

      receive do
        {:DOWN, ^monitor, :process, ^pid, _} -> :ok
      after
        10_000 -> raise "noise cleanup did not finish"
      end
    end)

    scope_stats = if(enabled and single_scope, do: Hyperlang.Scope.stats(common_scope), else: nil)
    attackers |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.each(&Hyperlang.Scope.close/1)
    Hyperlang.Scope.close(victim_scope)
    times = Enum.map(samples, &elem(&1, 0)) |> Enum.sort()

    %{
      mode: mode,
      tenants: n,
      admission: enabled,
      one_scope: single_scope,
      samples: 1000,
      window_ms: window_ms,
      p50_us: Enum.at(times, 499),
      p99_us: Enum.at(times, 989),
      p999_us: Enum.at(times, 998),
      outcomes: Enum.frequencies_by(samples, &elem(&1, 1)),
      scope_stats: scope_stats
    }
  end

  defp await_us(deadline) do
    if System.monotonic_time(:microsecond) < deadline do
      :erlang.yield()
      await_us(deadline)
    end
  end

  # Paired latency measurement for the R2-4 bounds.
  #
  # Interleaving. The unloaded and loaded cells alternate in ABBA blocks of
  # `@block` victim requests, `@samples` requests per cell, so both cells see
  # the same host conditions and any drift in them. Every loaded block starts
  # `n` fresh tenants and stops them at its end; an unloaded block runs with
  # no tenant processes or scopes. Before each block the VM must be quiet
  # (see `quiesce/0`), and the block's first `@warmup` requests are not
  # recorded, in both cells alike.
  #
  # Rate phase. CPU and heap tenants run under a CPU or churn rate with a
  # `@period_ms` period. They spend each period's budget in a burst of a few
  # milliseconds after its refill and stay suspended for the rest, so a block
  # sees the burst only if it spans a refill. The k-th loaded block starts
  # `50 + k * @period_ms / @loaded` ms after its tenants start, which spreads
  # the loaded blocks evenly over one whole period, refill burst included.
  #
  # Host stalls. One max-priority ticker is bound to each scheduler and sleeps
  # 1 ms. The BEAM fires that timer at a fixed offset after the next-but-one
  # millisecond boundary, so a tick's delay is its wake time minus that
  # boundary, less the smallest delay seen in the trial. A max-priority
  # process waits at most for the running process's time slice, so a delay of
  # `@stall_us` or more means the scheduler thread could not run at all: the
  # operating system descheduled it, or native code or a garbage collection
  # did not yield. A request whose interval overlaps a stalled tick on any
  # scheduler is excluded from its cell. Run-queue and server queueing never
  # delay a max-priority tick, so those delays stay in the kept requests.
  # Heap trials exclude no stalled requests: a tenant's garbage collection
  # does not yield either, so the ticker cannot tell a host stall from the
  # heap pressure under test. With churn enforcement off, loaded heap blocks
  # stall dozens of times more ticks than with it on. Both cells keep host
  # stalls, and the interleaving spreads them evenly.
  #
  # Host CPU share. A loaded channel block keeps every scheduler busy. If the
  # operating system gave this OS process less than `@min_cpu_share` of the
  # schedulers' busy time as CPU time (user plus system, see `os_cpu_us/0`),
  # its threads were preempted for the rest, and the whole block is excluded.
  # Queueing inside the VM keeps the schedulers busy on the CPU, so it does
  # not lower the share. Unloaded blocks are mostly idle and are not judged
  # this way. Neither are CPU and heap blocks: their tenants are suspended for
  # most of the period, so the schedulers are mostly idle, and the 10 ms
  # resolution of `ps` would judge a short block by its rounding. Such a
  # block would be excluded more often when it spans a burst (more busy time,
  # same rounding), which hides the burst instead of host preemption.
  #
  # A trial is valid only if each cell keeps at least `@min_kept` requests.
  @block 250
  @samples 5_000
  @warmup 20
  @stall_us 500
  @min_kept div(@samples, 2)
  @min_cpu_share 0.75
  @period_ms 100
  @loaded div(@samples, @block)

  def paired(mode, n) when mode in [:cpu, :memory, :channel] do
    p = program("result(N) -> loop(N). loop(0) -> 1; loop(N) -> loop(N-1).")
    cpu = program("result(_) -> spin(). spin() -> spin().")
    memory = program("result(_) -> grow(0, []). grow(N,L) -> grow(N+1, [<<N:80000>>|L]).")
    :ok = Hyperlang.load(cpu)
    :ok = Hyperlang.load(memory)
    victim_scope = make_ref()

    victim =
      if mode == :channel,
        do: %{priority: :latency},
        else: %{priority: :latency, max_concurrent_runs: 1}

    :ok = Hyperlang.Scope.configure(victim_scope, victim)
    victim_policy = %{max_reductions: nil, scope: victim_scope}
    for _ <- 1..100, do: Kit.run(p, :entry, [500], policy: victim_policy)
    owner = self()

    tickers =
      for scheduler <- 1..:erlang.system_info(:schedulers_online) do
        :erlang.spawn_opt(fn -> tick(owner, []) end, [
          {:scheduler, scheduler},
          {:priority, :max}
        ])
      end

    layout =
      [:unloaded, :loaded, :loaded, :unloaded]
      |> List.duplicate(div(@samples, 2 * @block))
      |> List.flatten()

    :erlang.system_flag(:scheduler_wall_time, true)

    blocks =
      layout
      |> Enum.with_index()
      |> Enum.map(fn {cell, index} ->
        quiesce()
        phase = div(@period_ms * Enum.count(Enum.take(layout, index), &(&1 == :loaded)), @loaded)

        attackers =
          if cell == :loaded, do: start_paired_noise(mode, n, cpu, memory, phase), else: []

        for _ <- 1..@warmup, do: Kit.run(p, :entry, [500], policy: victim_policy)
        cpu_before = os_cpu_us()
        active_before = scheduler_active()

        rows =
          for _ <- 1..@block do
            started = System.monotonic_time(:microsecond)
            result = Kit.run(p, :entry, [500], policy: victim_policy)
            {cell, index, started, System.monotonic_time(:microsecond), category(result)}
          end

        cpu_us = os_cpu_us() - cpu_before
        active_us = scheduler_active() - active_before
        stop_paired_noise(attackers)

        %{
          index: index,
          cell: cell,
          phase_ms: if(cell == :loaded, do: phase),
          cpu_us: cpu_us,
          active_us: active_us,
          cpu_share: cpu_us / max(active_us, 1),
          starved?: mode == :channel and cell == :loaded and cpu_us < active_us * @min_cpu_share,
          rows: rows
        }
      end)

    :erlang.system_flag(:scheduler_wall_time, false)
    starved = for %{starved?: true, index: index} <- blocks, into: MapSet.new(), do: index
    samples = Enum.flat_map(blocks, & &1.rows)

    ticks =
      Enum.flat_map(tickers, fn ticker ->
        send(ticker, :stop)

        receive do
          {:ticks, ^ticker, rows} -> rows
        after
          5_000 -> raise "stall ticker did not stop"
        end
      end)

    Hyperlang.Scope.close(victim_scope)
    boundary_delay = fn {t0, t1} -> t1 - (t0 - Integer.mod(t0, 1_000)) end
    base = ticks |> Enum.map(boundary_delay) |> Enum.min()

    stalls =
      for {t0, t1} = tick <- ticks, boundary_delay.(tick) - base >= @stall_us, do: {t0, t1}

    cells =
      for cell <- [:unloaded, :loaded], into: %{} do
        rows = for {^cell, _, _, _, _} = row <- samples, do: row

        kept =
          for {_, index, a, b, _} <- rows,
              not MapSet.member?(starved, index),
              mode == :memory or not Enum.any?(stalls, fn {t0, t1} -> t0 <= b and t1 >= a end),
              do: b - a

        all = rows |> Enum.map(fn {_, _, a, b, _} -> b - a end) |> Enum.sort()
        kept = Enum.sort(kept)

        {cell,
         %{
           samples: length(rows),
           kept: length(kept),
           excluded: length(rows) - length(kept),
           p50_us: percentile(kept, 0.50),
           p99_us: percentile(kept, 0.99),
           p999_us: percentile(kept, 0.999),
           raw_p50_us: percentile(all, 0.50),
           raw_p99_us: percentile(all, 0.99),
           raw_p999_us: percentile(all, 0.999),
           outcomes: Enum.frequencies_by(rows, &elem(&1, 4))
         }}
      end

    %{
      mode: mode,
      tenants: n,
      block: @block,
      warmup: @warmup,
      stall_us: @stall_us,
      min_kept: @min_kept,
      ticks: length(ticks),
      stalled_ticks: length(stalls),
      max_tick_delay_us: ticks |> Enum.map(&(boundary_delay.(&1) - base)) |> Enum.max(),
      valid?: cells.unloaded.kept >= @min_kept and cells.loaded.kept >= @min_kept,
      unloaded: cells.unloaded,
      loaded: cells.loaded,
      min_cpu_share: @min_cpu_share,
      starved_blocks: MapSet.size(starved),
      stalls: stalls,
      blocks:
        Enum.map(blocks, fn block ->
          durations = block.rows |> Enum.map(fn {_, _, a, b, _} -> b - a end) |> Enum.sort()

          block
          |> Map.delete(:rows)
          |> Map.merge(%{p50_us: percentile(durations, 0.5), p99_us: percentile(durations, 0.99)})
        end),
      samples: Enum.map(samples, fn {cell, index, a, b, _} -> {cell, index, a, b} end)
    }
  end

  # Stopped tenants leave cleanup behind (channel retirement, scope close,
  # collection of their state). A block starts only after the VM had no
  # runnable work besides this process for 1 ms. The wait polls without
  # sleeping, so scheduler threads do not enter a deep sleep before the block.
  defp quiesce, do: quiesce(nil, System.monotonic_time(:microsecond))

  defp quiesce(quiet_since, started) do
    now = System.monotonic_time(:microsecond)

    cond do
      now - started > 2_000_000 ->
        raise "the VM did not quiesce between blocks"

      :erlang.statistics(:total_active_tasks_all) > 1 ->
        :erlang.yield()
        quiesce(nil, started)

      quiet_since && now - quiet_since >= 1_000 ->
        :ok

      true ->
        :erlang.yield()
        quiesce(quiet_since || now, started)
    end
  end

  # User plus system CPU time of this OS process, from `ps` (10 ms
  # resolution). `:erlang.statistics(:runtime)` counts user time only, and
  # system time is a large share of a channel-heavy load.
  defp os_cpu_us do
    {out, 0} = System.cmd("ps", ["-o", "utime=,stime=", "-p", System.pid()])

    out
    |> String.split()
    |> Enum.map(fn time ->
      [minutes, seconds] = String.split(time, ":")
      String.to_integer(minutes) * 60_000_000 + round(String.to_float(seconds) * 1_000_000)
    end)
    |> Enum.sum()
  end

  defp scheduler_active do
    normal = :erlang.system_info(:schedulers)

    active =
      for {id, active, _total} <- :erlang.statistics(:scheduler_wall_time),
          id <= normal,
          reduce: 0,
          do: (sum -> sum + active)

    :erlang.convert_time_unit(active, :perf_counter, :microsecond)
  end

  defp tick(owner, acc) do
    started = System.monotonic_time(:microsecond)

    receive do
      :stop -> send(owner, {:ticks, self(), acc})
    after
      1 -> tick(owner, [{started, System.monotonic_time(:microsecond)} | acc])
    end
  end

  # CPU and heap tenants use the contention matrix's scoped noise policies:
  # each tenant has its own `:background` scope with one run, plus a CPU rate
  # or a heap-churn rate.
  defp start_paired_noise(mode, n, cpu, memory, phase) when mode in [:cpu, :memory] do
    owner = self()

    attackers =
      for i <- 1..n//1 do
        scope = make_ref()

        configure(
          scope,
          %{
            max_concurrent_runs: 1,
            max_queue: 1,
            priority: :background,
            rate: if(mode == :cpu, do: %{quota: 100_000, period_ms: @period_ms}, else: nil),
            churn:
              if(mode == :memory,
                do: %{heap_words: 200_000, gcs: 20, period_ms: @period_ms},
                else: nil
              ),
            max_violations: 1000,
            heap_words: 4_000_000
          },
          true
        )

        pid =
          spawn(fn ->
            mon = Process.monitor(owner)
            send(owner, {:ready, self()})
            noise(mode, scope, true, cpu, memory, i, mon)
          end)

        {pid, scope}
      end

    await_paired_noise(attackers)
    Process.sleep(50 + phase)
    attackers
  end

  defp start_paired_noise(:channel, n, _cpu, _memory, _phase) do
    owner = self()

    attackers =
      for i <- 1..n//1 do
        pid =
          spawn(fn ->
            mon = Process.monitor(owner)
            scope = {:paired_channel_noise, i, make_ref()}
            :ok = Hyperlang.Scope.configure(scope, %{max_channels: 32, max_buffer_slots: 64})
            send(owner, {:ready, self()})
            channel_noise(scope, mon)
          end)

        {pid, nil}
      end

    await_paired_noise(attackers)
    attackers
  end

  defp await_paired_noise(attackers) do
    Enum.each(attackers, fn {pid, _scope} ->
      receive do
        {:ready, ^pid} -> :ok
      after
        1_000 -> raise "noise startup"
      end
    end)
  end

  defp stop_paired_noise(attackers) do
    monitors =
      Enum.map(attackers, fn {pid, scope} ->
        monitor = Process.monitor(pid)
        if scope, do: Process.exit(pid, :kill), else: send(pid, :stop)
        {pid, scope, monitor}
      end)

    Enum.each(monitors, fn {pid, scope, monitor} ->
      receive do
        {:DOWN, ^monitor, :process, ^pid, _} -> :ok
      after
        10_000 -> raise "noise cleanup did not finish"
      end

      if scope, do: Hyperlang.Scope.close(scope)
    end)
  end

  defp channel_noise(scope, mon) do
    receive do
      :stop -> Hyperlang.Scope.close(scope)
      {:DOWN, ^mon, _, _, _} -> :ok
    after
      0 ->
        channels = for _ <- 1..32, do: Hyperlang.Chan.newchan(scope, 1)

        Enum.each(channels, fn {handle, broker} ->
          Hyperlang.Chan.freechan(scope, handle, broker)
        end)

        channel_noise(scope, mon)
    end
  end

  defp percentile(sorted, fraction),
    do: Enum.at(sorted, max(0, ceil(length(sorted) * fraction) - 1))

  defp configure(scope, policy, true), do: Hyperlang.Scope.configure(scope, policy)
  defp configure(_, _, false), do: :ok

  defp noise(mode, scope, enabled, cpu, memory, i, mon) do
    receive do
      {:DOWN, ^mon, _, _, _} -> :ok
    after
      0 ->
        case mode do
          :cpu ->
            Kit.run(cpu, :entry, [nil],
              policy: %{max_reductions: nil, wall_ms: 100, scope: scope}
            )

          :memory ->
            Kit.run(memory, :entry, [nil],
              policy: %{
                max_reductions: nil,
                heap_words: 100_000,
                wall_ms: 100,
                scope: scope
              }
            )

          :compile ->
            src =
              "result(_) -> [" <>
                Enum.map_join(
                  1..150,
                  ",",
                  &"'noise_#{i}_#{System.unique_integer([:positive])}_#{&1}'"
                ) <> "]."

            if enabled,
              do:
                Hyperlang.Scope.with_scope(scope, fn ->
                  Kit.program(src, %{terms: %{public: :erlang}})
                end),
              else: Kit.program(src, %{terms: %{public: :erlang}})
        end

        noise(mode, scope, enabled, cpu, memory, i, mon)
    end
  end
end
