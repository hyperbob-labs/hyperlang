defmodule Hyperlang.DoorTest do
  use ExUnit.Case, async: false

  @source """
  -module(door_counter).
  -behaviour(gen_server).
  -export([init/1, handle_call/3, handle_cast/2]).

  init(N) -> {ok, kv:get(N)}.
  handle_call(<<"inc">>, _From, N) -> {reply, N + 1, N + 1}.
  handle_cast(<<"spin">>, N) -> spin(), {noreply, N}.
  spin() -> spin().
  """

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

  test "the top-level door is the complete public surface" do
    assert Hyperlang.__info__(:functions) == [load: 1, program: 1, program: 2, run: 4]

    # The actor callback module: GenServer callbacks plus `child_spec/1`.
    assert Hyperlang.Actor.__info__(:functions) |> Keyword.keys() |> Enum.uniq() |> Enum.sort() ==
             Enum.sort([
               :child_spec,
               :code_change,
               :format_status,
               :handle_call,
               :handle_cast,
               :handle_continue,
               :handle_info,
               :init,
               :terminate
             ])
  end

  test "program values are eager, immutable, and caller-key cached" do
    assert {:error, [_ | _]} = Hyperlang.program("result(_) -> (")

    assert {:ok, first} = Hyperlang.program("result(Input) -> Input.")
    assert {:ok, second} = Hyperlang.program("result(Input) -> Input.")
    assert first == second
    refute Map.has_key?(Map.from_struct(first), :id)

    counter = :atomics.new(1, signed: false)
    key = {:door_test, make_ref()}

    loader = fn ->
      :atomics.add(counter, 1, 1)
      "result(Input) -> Input."
    end

    assert {:ok, ^first} = Hyperlang.program(key, loader)
    assert {:ok, ^first} = Hyperlang.program(key, loader)
    assert :atomics.get(counter, 1) == 1

    assert {:ok, 42, %{stdout: [], reductions: reductions, wall_us: wall_us}} =
             Hyperlang.run(%{policy: %{max_reductions: nil}}, first, :entry, [42])

    assert is_integer(reductions) and reductions >= 0
    assert is_integer(wall_us) and wall_us >= 0
  end

  test "door results carry guest stdout and usage beside the value" do
    assert {:ok, program} =
             Hyperlang.program(%{
               entry: "logger.erl",
               files: %{
                 "logger.erl" =>
                   "-module(logger).\n-export([result/1]).\nresult(N) -> io:format(\"n=~p~n\", [N]), io:format(\"done~n\"), N * 2.\n"
               }
             })

    assert {:ok, 42, %{stdout: ["n=21\n", "done\n"], reductions: reductions}} =
             Hyperlang.run(%{policy: %{}}, program, :entry, [21])

    assert reductions > 0
  end

  test "door results are bare values and source metadata exposes basenames only" do
    manifest = %{
      terms: %{public: :erlang, allowed_atoms: [:ok, :status]},
      result: %{name: "result", arity: 1}
    }

    assert {:ok, program} =
             Hyperlang.program(%{
               entry: "main.erl",
               files: %{"main.erl" => "result(_) -> {status, ok}."},
               manifest: manifest
             })

    assert program.metadata.source_snapshot.entry == "main.erl"
    assert Enum.map(program.metadata.source_snapshot.sources, & &1.path) == ["main.erl"]
    refute Map.has_key?(program.metadata.source_snapshot, :contents)

    spec = %{policy: %{atoms: [:ok, :status], max_reductions: nil}}
    assert {:ok, {:status, :ok}, _meta} = Hyperlang.run(spec, program, :entry, [nil])

    assert {:ok, {:status, :ok}, _meta} =
             Hyperlang.run(%{policy: %{max_reductions: nil}}, program, :entry, [nil])
  end

  defmodule KV do
    @behaviour Hyperlang.Binding
    @impl true
    def exports, do: [get: 1]
    @impl true
    def call(%{offset: offset}, :get, [value]), do: value + offset
  end

  test "an actor is an OTP callback whose limits come from its spec" do
    manifest = %{
      terms: %{public: :erlang},
      result: %{name: "init", arity: 1},
      bindings: %{"kv" => KV}
    }

    assert {:ok, program} =
             Hyperlang.program(%{
               entry: "door_counter.erl",
               files: %{"door_counter.erl" => @source},
               manifest: manifest
             })

    spec = %{
      bindings: %{"kv" => {KV, %{offset: 10}}},
      policy: %{
        max_reductions: nil,
        wall_ms: :infinity,
        rate: %{quota: 100, period_ms: 100}
      }
    }

    assert {:ok, pid} = GenServer.start(Hyperlang.Actor, {spec, program, 0})
    assert 11 = GenServer.call(pid, "inc")

    monitor = Process.monitor(pid)
    GenServer.cast(pid, "spin")

    # The rate quota throttles the spinning actor; no host wiring is involved.
    assert wait_until(fn ->
             match?({:status, :suspended}, Process.info(pid, :status))
           end)

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000

    ceiling_spec = %{
      spec
      | policy: %{max_reductions: nil, wall_ms: :infinity, ceiling: 50_000}
    }

    assert {:ok, pid} = GenServer.start(Hyperlang.Actor, {ceiling_spec, program, 0})
    monitor = Process.monitor(pid)
    GenServer.cast(pid, "spin")
    assert_receive {:DOWN, ^monitor, :process, ^pid, {:hyperlang_limit, :ceiling}}, 2_000
  end
end
