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
    Hyperlang.module(cpu)
    Hyperlang.module(memory)
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

    Process.sleep(if n == 0, do: 0, else: 50)

    samples =
      for _ <- 1..1000 do
        {us, result} = :timer.tc(fn -> Kit.run(p, :entry, [500], policy: victim_policy) end)
        {us, category(result)}
      end

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
      p50_us: Enum.at(times, 499),
      p99_us: Enum.at(times, 989),
      p999_us: Enum.at(times, 998),
      outcomes: Enum.frequencies_by(samples, &elem(&1, 1)),
      scope_stats: scope_stats
    }
  end

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
