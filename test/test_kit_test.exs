defmodule HyperlangTestKitTest do
  use ExUnit.Case, async: true

  import Hyperlang.Test

  @manifest %{terms: %{public: :erlang}}
  @source "-module(kit).\n-export([result/1]).\nresult(K) -> io:format(\"k~n\"), kv:get(K).\n"

  test "fake bindings compile and run through the public door" do
    kv = %{"kv" => %{get: fn key -> {key, :ok} end}}
    manifest = Map.put(@manifest, :terms, %{public: :erlang, allowed_atoms: [:ok]})

    assert {"a", :ok} = run!(@source, :entry, ["a"], bindings: kv, manifest: manifest)

    program = program!(@source, Map.put(manifest, :bindings, kv))
    assert {:ok, {"b", :ok}, meta} = run(program, :entry, ["b"], bindings: kv)
    assert assert_stdout(meta, ["k\n"]) == ["k\n"]
    assert_stdout(meta, ~r/^k/)
  end

  test "the same fake shape at compile and run time names the same module" do
    compile_time = %{"kv" => %{get: fn _ -> :unused end}}
    run_time = %{"kv" => %{get: fn key -> key end}}

    program = program!(@source, Map.put(@manifest, :bindings, compile_time))
    assert 7 = run!(program, :entry, [7], bindings: run_time)

    other_shape = %{"kv" => %{get: fn key -> key end, put: fn _k, _v -> :ok end}}
    assert {:error, %{category: :manifest}} = run(program, :entry, [7], bindings: other_shape)
  end

  test "assert_stdout fails with an assertion error on mismatch" do
    {:ok, _value, meta} =
      run(@source, :entry, [1], bindings: %{"kv" => %{get: & &1}}, manifest: @manifest)

    assert_raise ExUnit.AssertionError, fn -> assert_stdout(meta, "nope") end
  end

  test "program! and run! raise with diagnostics" do
    assert_raise ArgumentError, ~r/program failed/, fn -> program!("result(_) -> (") end

    assert_raise ArgumentError, ~r/run failed/, fn ->
      run!(@source, :entry, [1], manifest: @manifest)
    end
  end

  test "start_actor! starts the callback module with bindings and policy" do
    source = """
    -module(kit_actor).
    -behaviour(gen_server).
    -export([init/1, handle_call/3]).
    init(N) -> {ok, kv:get(N)}.
    handle_call(<<"get">>, _From, N) -> {reply, N, N}.
    """

    kv = %{"kv" => %{get: fn n -> n * 10 end}}

    program =
      program!(source,
        result: %{name: "init", arity: 1},
        terms: %{public: :erlang},
        bindings: kv
      )

    pid = start_actor!(program, 4, bindings: kv, policy: %{wall_ms: 1_000})
    assert GenServer.call(pid, "get") == 40
    GenServer.stop(pid)
  end
end
