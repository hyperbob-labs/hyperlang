# Cost of a Hyperlang guest: cold start, cached start, call latency, compute
# against the same Erlang compiled natively, and memory per idle actor.
# Run: mix run bench/guest_cost.exs  (HYPERLANG_BENCH_ROUNDS sets the rounds)
rounds = String.to_integer(System.get_env("HYPERLANG_BENCH_ROUNDS") || "5")

source = fn salt ->
  """
  -module(k).
  -export([id/1, fib/1, salt/0]).
  salt() -> #{salt}.
  id(X) -> X.
  fib(N) when N < 2 -> N;
  fib(N) -> fib(N - 1) + fib(N - 2).
  """
end

manifest = %{
  terms: %{public: :erlang},
  exports: %{
    functions: %{"id" => %{function: "id", arity: 1}, "fib" => %{function: "fib", arity: 1}}
  }
}

program = fn salt ->
  {:ok, p} =
    Hyperlang.program(%{entry: "k.erl", files: %{"k.erl" => source.(salt)}, manifest: manifest})

  p
end

actor_source = ~S"""
-module(counter).
-behaviour(gen_server).
-export([init/1, handle_call/3]).
init(_Id) -> {ok, 0}.
handle_call(<<"inc">>, _From, N) -> {reply, N + 1, N + 1}.
"""

{:ok, actor} =
  Hyperlang.program(%{
    entry: "counter.erl",
    files: %{"counter.erl" => actor_source},
    manifest: %{
      result: %{name: "init", arity: 1},
      terms: %{public: :erlang, allowed_atoms: [:ok]}
    }
  })

# The same Erlang source compiled natively, as the no-isolation reference.
{:ok, tokens, _} = :erl_scan.string(String.to_charlist(source.(0)))

forms =
  tokens
  |> Enum.chunk_while(
    [],
    fn
      {:dot, _} = t, acc -> {:cont, Enum.reverse([t | acc]), []}
      t, acc -> {:cont, [t | acc]}
    end,
    fn acc -> {:cont, acc} end
  )
  |> Enum.reject(&(&1 == []))
  |> Enum.map(fn t ->
    {:ok, f} = :erl_parse.parse_form(t)
    f
  end)

{:ok, :k, beam} = :compile.forms(forms, [:binary])
{:module, :k} = :code.load_binary(:k, ~c"k.erl", beam)

per_call_us = fn fun, n ->
  Enum.each(1..min(n, 100), fn _ -> fun.() end)
  {us, _} = :timer.tc(fn -> Enum.each(1..n, fn _ -> fun.() end) end)
  us / n
end

median = fn xs -> xs |> Enum.sort() |> Enum.at(div(length(xs), 2)) end

# Native reference in a fresh process, like the guest's run worker.
native_spawned = fn ->
  parent = self()
  spawn(fn -> send(parent, {:native, :k.fib(25)}) end)

  receive do
    {:native, 75025} -> :ok
  end
end

load = fn ->
  :os.cmd(~c"uptime") |> to_string() |> String.split("averages:") |> List.last() |> String.trim()
end

warm = program.(0)
{:ok, mod_pid} = GenServer.start(Hyperlang.module(actor), {%{}, "bench"})
key = {:guest_cost_bench, System.unique_integer([:positive])}

{:ok, _} =
  Hyperlang.program(key, fn ->
    %{entry: "k.erl", files: %{"k.erl" => source.(0)}, manifest: manifest}
  end)

measures = [
  {"cold start: program/1 + first run (ms)",
   fn r ->
     {us, _} =
       :timer.tc(fn ->
         {:ok, 42, _} =
           Hyperlang.run(%{}, program.(1000 * r + System.unique_integer([:positive])), "id", [42])
       end)

     us / 1000
   end},
  {"cached start: program/2 hit + run (ms)",
   fn _ ->
     per_call_us.(
       fn ->
         {:ok, p} = Hyperlang.program(key, fn -> raise "miss" end)
         {:ok, 42, _} = Hyperlang.run(%{}, p, "id", [42])
       end,
       1000
     ) / 1000
   end},
  {"run/4 of id/1 in a worker (us)",
   fn _ -> per_call_us.(fn -> {:ok, 42, _} = Hyperlang.run(%{}, warm, "id", [42]) end, 2000) end},
  {"actor GenServer.call (us)",
   fn _ -> per_call_us.(fn -> GenServer.call(mod_pid, "inc") end, 5000) end},
  {"guest fib(25) via run/4 (ms)",
   fn _ ->
     per_call_us.(fn -> {:ok, 75025, _} = Hyperlang.run(%{}, warm, "fib", [25]) end, 10) / 1000
   end},
  {"native fib(25) in a fresh process, same VM, no isolation (ms)",
   fn _ -> per_call_us.(native_spawned, 10) / 1000 end}
]

for {label, f} <- measures do
  samples = for r <- 1..rounds, do: f.(r)

  IO.puts(
    "#{label}: median #{Float.round(median.(samples) / 1, 3)} (min #{Float.round(Enum.min(samples) / 1, 3)}, max #{Float.round(Enum.max(samples) / 1, 3)}; load #{load.()})"
  )
end

# Guest/native ratio from alternating single calls, so both see the same load.
ratios =
  for _ <- 1..(rounds * 10) do
    {g, _} = :timer.tc(fn -> {:ok, 75025, _} = Hyperlang.run(%{}, warm, "fib", [25]) end)
    {n, _} = :timer.tc(native_spawned)
    g / n
  end

IO.puts(
  "guest/native fib(25) ratio, alternating calls: median #{Float.round(median.(ratios), 2)} (min #{Float.round(Enum.min(ratios), 2)}, max #{Float.round(Enum.max(ratios), 2)}; load #{load.()})"
)

gc = fn -> Enum.each(Process.list(), &:erlang.garbage_collect/1) end
gc.()
m0 = :erlang.memory(:total)

pids =
  for i <- 1..1000 do
    {:ok, pid} = GenServer.start(Hyperlang.module(actor), {%{}, "t#{i}"})
    1 = GenServer.call(pid, "inc")
    pid
  end

gc.()

IO.puts(
  "memory per idle actor: #{div(:erlang.memory(:total) - m0, 1000)} bytes (1000 actors, one program; load #{load.()})"
)

Enum.each(pids, &GenServer.stop/1)
