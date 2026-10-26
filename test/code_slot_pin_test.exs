defmodule CodeSlotPinTest do
  use ExUnit.Case, async: false

  # A live OTP actor pins the code slot its callback module names. A pinned
  # slot is never released or reclaimed, so the actor's module and program
  # literal stay loaded for the actor's whole life. Pins are charged to the
  # actor's scope and bounded by its `max_code_pins` policy; a process's pins
  # go when it exits.

  alias Hyperlang.{CodeServer, Scope}

  @counter """
  -module(counter).
  -behaviour(gen_server).
  -export([init/1, handle_call/3]).
  init(Start) -> {ok, Start}.
  handle_call(<<"inc">>, _From, N) -> {reply, N + 1, N + 1};
  handle_call({<<"spin">>, Count}, _From, N) -> {reply, spin(Count), N}.
  spin(0) -> done;
  spin(Count) -> spin(Count - 1).
  """

  defp program(salt, window, source \\ @counter, entry \\ "counter.erl") do
    source =
      String.replace(
        source,
        "init(Start) -> {ok, Start}.",
        "init(Start) -> {ok, Start + #{salt} - #{salt}}."
      )

    {:ok, program} =
      Hyperlang.program(%{
        entry: entry,
        files: %{entry => source},
        manifest: %{
          code_pool: %{size: window},
          result: %{name: "init", arity: 1},
          terms: %{public: :erlang, allowed_atoms: [:ok, :done]}
        }
      })

    program
  end

  defp start(program, start, policy),
    do: GenServer.start(Hyperlang.module(program), {%{policy: policy}, start})

  defp start!(program, start, policy \\ %{}) do
    {:ok, pid} = start(program, start, policy)
    pid
  end

  defp code_state, do: :sys.get_state(CodeServer)

  defp slot(module) do
    [_, id] = Regex.run(~r/^hyperlang_slot_0*(\d+)$/, Atom.to_string(module))
    Map.fetch!(code_state().slots, String.to_integer(id))
  end

  defp record?(program),
    do: :persistent_term.get({{CodeServer, :loaded_artifact}, program.content_hash}, nil) != nil

  # Stop an actor and wait until the CodeServer has dropped its pin.
  defp stop(pid) do
    GenServer.stop(pid)

    Enum.find_value(1..500, fn _ ->
      if Map.has_key?(code_state().pins, pid), do: Process.sleep(10) && nil, else: true
    end)

    refute Map.has_key?(code_state().pins, pid)
    :ok
  end

  # Pins of processes this test did not start (none in a clean run) are not
  # its business; everything it pinned must be gone once its processes are.
  setup do
    {:ok, baseline: pin_footprint()}
  end

  defp pin_footprint do
    state = code_state()

    %{
      pins: Map.keys(state.pins),
      scopes: Map.keys(state.scope_pins),
      slot_pins: state.slots |> Enum.map(fn {_id, slot} -> slot.pins end) |> Enum.sum(),
      rows: :ets.info(:hyperlang_code_pins, :size)
    }
  end

  # The CodeServer sees an actor's `:DOWN` independently of the test.
  defp assert_pins(baseline) do
    Enum.find_value(1..500, fn _ ->
      if pin_footprint() == baseline, do: true, else: Process.sleep(10) && nil
    end)

    assert pin_footprint() == baseline
  end

  defp await_slot(module, pattern_fun) do
    Enum.find_value(1..500, fn _ ->
      if pattern_fun.(slot(module)), do: true, else: Process.sleep(10) && nil
    end)

    slot(module)
  end

  test "release with idle actors keeps their code until the last actor exits", %{
    baseline: baseline
  } do
    program = program(1, 6)
    module = Hyperlang.module(program)
    a = start!(program, 10)
    b = start!(program, 20)
    assert %{pins: 2} = slot(module)

    assert :ok = CodeServer.release(program.content_hash)
    assert %{state: :used, released?: true, pins: 2} = slot(module)
    assert :code.is_loaded(module) != false
    assert record?(program)

    # Pool churn in the same window cannot take the pinned slot.
    for salt <- 100..115, do: Hyperlang.module(program(salt, 6))
    assert %{state: :used, content_hash: hash} = slot(module)
    assert hash == program.content_hash

    assert GenServer.call(a, "inc") == 11
    assert GenServer.call(b, "inc") == 21
    :ok = stop(a)
    assert %{state: :used, pins: 1} = slot(module)
    assert GenServer.call(b, "inc") == 22

    # The last pin carries out the release.
    :ok = stop(b)
    assert %{state: :free, content_hash: nil, pins: 0, released?: false} = slot(module)
    assert :code.is_loaded(module) == false
    refute record?(program)
    assert_pins(baseline)

    # Released, not lost: the next use loads it again.
    assert {:ok, {:ok, 5}, _meta} = Hyperlang.run(%{}, program, :entry, [5])
  end

  test "a window of pinned slots fails new loads with code_pool until a pin goes", %{
    baseline: baseline
  } do
    window = 3
    programs = for salt <- 200..(200 + window - 1), do: program(salt, window)
    actors = for {program, n} <- Enum.with_index(programs), do: start!(program, n)
    extra = program(299, window)

    assert_raise ArgumentError, ~r/code_pool/, fn -> Hyperlang.module(extra) end
    assert {:error, %{category: :code_pool}} = Hyperlang.run(%{}, extra, :entry, [1])

    for {pid, n} <- Enum.with_index(actors), do: assert(GenServer.call(pid, "inc") == n + 1)

    [first | rest] = actors
    freed = Hyperlang.module(hd(programs))
    :ok = stop(first)

    # The unpinned slot is the only victim.
    assert Hyperlang.module(extra) == freed
    assert {:ok, {:ok, 1}, _meta} = Hyperlang.run(%{}, extra, :entry, [1])
    for {pid, n} <- Enum.zip(rest, 1..2), do: assert(GenServer.call(pid, "inc") == n + 2)

    Enum.each(rest, &stop/1)
    assert_pins(baseline)
  end

  test "callbacks running during releases and pool churn all complete", %{baseline: baseline} do
    window = 4
    program = program(300, window)
    pid = start!(program, 0)
    parent = self()

    callers =
      for _ <- 1..4 do
        spawn_link(fn ->
          for _ <- 1..200 do
            GenServer.call(pid, "inc")
            :done = GenServer.call(pid, {"spin", 2_000})
          end

          send(parent, {:caller_done, self()})
        end)
      end

    for salt <- 301..340 do
      assert :ok = CodeServer.release(program.content_hash)
      Hyperlang.module(program(salt, window))
    end

    for caller <- callers, do: assert_receive({:caller_done, ^caller}, 60_000)
    assert GenServer.call(pid, "inc") == 801
    module = Hyperlang.module(program)
    :ok = stop(pid)
    assert %{state: :free} = slot(module)
    assert_pins(baseline)
  end

  test "an actor started after its slot was reclaimed fails to start and pins nothing", %{
    baseline: baseline
  } do
    program = program(400, 6)
    module = Hyperlang.module(program)
    assert :ok = CodeServer.release(program.content_hash)
    assert {:error, _reason} = GenServer.start(module, {%{}, 1})
    assert_pins(baseline)
  end

  test "one scope's pins are bounded by max_code_pins and cannot starve another scope", %{
    baseline: baseline
  } do
    scope_a = {__MODULE__, :tenant_a}
    scope_b = {__MODULE__, :tenant_b}
    :ok = Scope.configure(scope_a, %{max_code_pins: 2})
    :ok = Scope.configure(scope_b, %{max_code_pins: 2})

    [p1, p2, p3, p4] = for salt <- 500..503, do: program(salt, 16)
    a1 = start!(p1, 1, %{scope: scope_a})
    a2 = start!(p2, 2, %{scope: scope_a})
    # A second actor of an already pinned program costs no pin.
    a3 = start!(p1, 3, %{scope: scope_a})

    assert {:error, {:hyperlang, %{category: :code_pool, details: %{reason: :pin_limit}}}} =
             start(p3, 4, %{scope: scope_a})

    # The other tenant pins up to its own bound in the same pool.
    b1 = start!(p3, 5, %{scope: scope_b})
    b2 = start!(p4, 6, %{scope: scope_b})
    assert GenServer.call(b1, "inc") == 6
    assert GenServer.call(b2, "inc") == 7
    assert map_size(code_state().scope_pins[scope_a]) == 2
    assert map_size(code_state().scope_pins[scope_b]) == 2

    # A pin is charged per distinct slot: one more actor's exit frees nothing.
    :ok = stop(a1)

    assert {:error, {:hyperlang, %{details: %{reason: :pin_limit}}}} =
             start(p3, 7, %{scope: scope_a})

    :ok = stop(a3)
    a4 = start!(p3, 8, %{scope: scope_a})
    assert GenServer.call(a4, "inc") == 9

    Enum.each([a2, a4, b1, b2], &stop/1)
    assert_pins(baseline)
    :ok = Scope.close(scope_a)
    :ok = Scope.close(scope_b)
  end

  test "a process that initialises several callback modules pins each slot", %{
    baseline: baseline
  } do
    p1 = program(600, 16)
    p2 = program(601, 16)
    {m1, m2} = {Hyperlang.module(p1), Hyperlang.module(p2)}
    parent = self()

    # A host process may run the `init/1` of several callback modules (an
    # event manager does this for its handlers).
    host =
      spawn(fn ->
        {:ok, s1} = m1.init({%{}, 10})
        {:ok, s2} = m2.init({%{}, 20})
        send(parent, :pinned)

        receive do
          :call ->
            {:reply, r1, _} = m1.handle_call("inc", {self(), make_ref()}, s1)
            {:reply, r2, _} = m2.handle_call("inc", {self(), make_ref()}, s2)
            send(parent, {:replies, r1, r2})
            receive do: (:exit -> :ok)
        end
      end)

    assert_receive :pinned, 5_000
    assert %{pins: 1} = slot(m1)
    assert %{pins: 1} = slot(m2)

    assert :ok = CodeServer.release(p1.content_hash)
    assert :ok = CodeServer.release(p2.content_hash)
    send(host, :call)
    assert_receive {:replies, 11, 21}, 5_000

    send(host, :exit)
    assert %{state: :free} = await_slot(m1, &(&1.state == :free))
    assert %{state: :free} = await_slot(m2, &(&1.state == :free))
    assert_pins(baseline)
  end

  test "10,000 actor cycles with releases leak no slots, records or pins", %{baseline: baseline} do
    window = 32
    programs = for salt <- 700..719, do: program(salt, window)
    hashes = MapSet.new(programs, & &1.content_hash)

    for n <- 1..10_000 do
      program = Enum.at(programs, rem(n, 20))
      pid = start!(program, n)
      assert GenServer.call(pid, "inc") == n + 1
      if rem(n, 10) == 0, do: :ok = CodeServer.release(program.content_hash)
      GenServer.stop(pid)
    end

    # Pins go with the actors' `:DOWN`s.
    Enum.find_value(1..500, fn _ ->
      if code_state().pins == %{}, do: true, else: Process.sleep(10) && nil
    end)

    assert_pins(baseline)
    state = code_state()
    loaded = Enum.count(state.artifacts, fn {hash, _id} -> MapSet.member?(hashes, hash) end)
    assert loaded <= 20

    records =
      for {{{CodeServer, :loaded_artifact}, hash}, _} <- :persistent_term.get(),
          MapSet.member?(hashes, hash),
          do: hash

    assert length(records) == loaded
    Enum.each(programs, &CodeServer.release(&1.content_hash))

    refute Enum.any?(:persistent_term.get(), fn
             {{{CodeServer, :loaded_artifact}, hash}, _} -> MapSet.member?(hashes, hash)
             _ -> false
           end)
  end
end
