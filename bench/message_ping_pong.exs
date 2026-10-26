# One guest receive per request/reply. An external host echoes envelopes; no
# sleep or wall-clock delay is included in the per-block/unblock measurement.
iterations = String.to_integer(System.get_env("HYPERLANG_BENCH_ITERATIONS") || "50000")
previous = Application.get_env(:hyperlang, :guest_msg_resolver)

echo = fn echo ->
  receive do
    {:"$hyperlang_msg", sender, value} ->
      send(sender, {:"$hyperlang_msg", nil, value})
      echo.(echo)

    :stop ->
      :ok
  end
end

peer = spawn(fn -> echo.(echo) end)

Application.put_env(:hyperlang, :guest_msg_resolver, fn _, _ ->
  {:ok, peer, %{sender_ctx: self()}}
end)

try do
  p =
    Hyperlang.Test.program!(
      "result(N) -> loop(N). loop(0) -> 1; loop(N) -> target ! N, receive N -> loop(N-1) after 5000 -> 0 end.",
      %{terms: %{public: :erlang}}
    )

  spec = %{bindings: %{}, policy: %{run_in_caller?: true, max_reductions: nil, wall_ms: 60000}}
  {:ok, 1, _} = Hyperlang.run(spec, p, :entry, [1000])
  {us, {:ok, 1, _}} = :timer.tc(fn -> Hyperlang.run(spec, p, :entry, [iterations]) end)

  IO.puts(
    "#{Float.round(us / iterations, 3)} us/ping-pong (#{iterations} guest receives; host hook handoff included)"
  )
after
  send(peer, :stop)

  if previous,
    do: Application.put_env(:hyperlang, :guest_msg_resolver, previous),
    else: Application.delete_env(:hyperlang, :guest_msg_resolver)
end

# Isolate one permit release/reacquisition per round trip. The identity wrapper
# models the old lifetime-held permit; both variants use the same process,
# scheduler, echo and outer permit. Initial/final admission is amortized.
alias Hyperlang.Scope
scope = Scope.current()
:ok = Scope.ensure(scope, self())
raw_echo = spawn(fn -> echo.(echo) end)

measure_cycle = fn label, blocking ->
  {us, :ok} =
    :timer.tc(fn ->
      Scope.running(scope, fn ->
        Enum.each(1..iterations, fn n ->
          blocking.(fn ->
            send(raw_echo, {:"$hyperlang_msg", self(), n})

            receive do
              {:"$hyperlang_msg", nil, ^n} -> :ok
            end
          end)
        end)
      end)
    end)

  per_cycle = us / iterations
  IO.puts("#{label}: #{Float.round(per_cycle, 3)} us/block-unblock")
  per_cycle
end

try do
  before = measure_cycle.("lifetime_held", fn fun -> fun.() end)
  after_yield = measure_cycle.("runnable_only", &Scope.blocking/1)
  IO.puts("permit_traffic_overhead: #{Float.round(after_yield - before, 3)} us/block-unblock")
after
  send(raw_echo, :stop)
end

# The same release/resume operations without echo scheduling noise.
identity = fn fun -> fun.() end

boundary = fn blocking ->
  {us, :ok} =
    :timer.tc(fn ->
      Scope.running(scope, fn ->
        Enum.each(1..iterations, fn _ -> blocking.(fn -> :ok end) end)
      end)
    end)

  us / iterations
end

samples =
  for n <- 1..7 do
    if rem(n, 2) == 0 do
      yielded = boundary.(&Scope.blocking/1)
      held = boundary.(identity)
      yielded - held
    else
      held = boundary.(identity)
      yielded = boundary.(&Scope.blocking/1)
      yielded - held
    end
  end

median = Enum.at(Enum.sort(samples), 3)
IO.puts("uncontended_boundary_samples: #{inspect(samples)} us/block-unblock")
IO.puts("uncontended_boundary_overhead: #{Float.round(median, 3)} us/block-unblock")
