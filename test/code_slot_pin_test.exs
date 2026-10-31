defmodule CodeSlotPinTest do
  use ExUnit.Case, async: false

  # An actor (`Hyperlang.Actor`) loads and pins its program's code slot in
  # one CodeServer call. A pinned slot is never released or reclaimed, so the
  # actor's generated module and program literal stay loaded for the actor's
  # whole life, and no release or slot reuse can make an actor start without
  # code or with another program. Pins are charged to the actor's scope and
  # bounded by its `max_code_pins` policy; a process's pins go when it exits.

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

  @offset_counter """
  -module(counter).
  -export([init/1, handle_call/3]).
  init(Start) -> {ok, Start + OFFSET + SALT - SALT}.
  handle_call(<<"get">>, _From, N) -> {reply, N, N};
  handle_call(<<"inc">>, _From, N) -> {reply, N + 1, N + 1}.
  """

  defp program(salt, window, source \\ @counter, entry \\ "counter.erl") do
    source =
      source
      |> String.replace(
        "init(Start) -> {ok, Start}.",
        "init(Start) -> {ok, Start + #{salt} - #{salt}}."
      )
      |> String.replace("SALT", Integer.to_string(salt))

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
    do: GenServer.start(Hyperlang.Actor, {%{policy: policy}, program, start})

  defp start!(program, start, policy \\ %{}) do
    {:ok, pid} = start(program, start, policy)
    pid
  end

  defp code_state, do: :sys.get_state(CodeServer)

  # The generated module a program is loaded as (internal: hosts never see
  # slot names).
  defp slot_module(program) do
    {:ok, slot} = CodeServer.load(program)
    slot.module
  end

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
    a = start!(program, 10)
    module = slot_module(program)
    b = start!(program, 20)
    assert %{pins: 2} = slot(module)

    assert :ok = CodeServer.release(program.content_hash)
    assert %{state: :used, released?: true, pins: 2} = slot(module)
    assert :code.is_loaded(module) != false
    assert record?(program)

    # Pool churn in the same window cannot take the pinned slot.
    for salt <- 100..115, do: :ok = Hyperlang.load(program(salt, 6))
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

    assert {:error, %{category: :code_pool}} = Hyperlang.load(extra)
    assert {:error, %{category: :code_pool}} = Hyperlang.run(%{}, extra, :entry, [1])
    assert {:error, {:hyperlang, %{category: :code_pool}}} = start(extra, 1, %{})

    for {pid, n} <- Enum.with_index(actors), do: assert(GenServer.call(pid, "inc") == n + 1)

    [first | rest] = actors
    freed = slot_module(hd(programs))
    :ok = stop(first)

    # The unpinned slot is the only victim.
    assert slot_module(extra) == freed
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
      :ok = Hyperlang.load(program(salt, window))
    end

    for caller <- callers, do: assert_receive({:caller_done, ^caller}, 60_000)
    assert GenServer.call(pid, "inc") == 801
    module = slot_module(program)
    :ok = stop(pid)
    assert %{state: :free} = slot(module)
    assert_pins(baseline)
  end

  # The two outcomes of the former `module/1` race. A host used to start
  # `GenServer.start(Hyperlang.module(program), ...)`; a release between the
  # two calls made the start fail with `undef`, and a reuse of the slot made
  # the actor run the other program. A `Hyperlang.Actor` takes the program
  # value, and `init/1` loads and pins it in one step, so the slot's state at
  # the time of the start does not matter.
  test "a slot freed before init: the actor reloads and runs its program", %{baseline: baseline} do
    program = program(400, 1, @offset_counter |> String.replace("OFFSET", "0"))
    assert :ok = Hyperlang.load(program)
    assert :ok = CodeServer.release(program.content_hash)
    refute record?(program)

    assert {:ok, pid} = start(program, 1, %{})
    assert GenServer.call(pid, "get") == 1
    assert record?(program)

    :ok = stop(pid)
    assert_pins(baseline)
  end

  test "a slot reused by another program before init: the actor runs its own program", %{
    baseline: baseline
  } do
    mine = program(401, 1, @offset_counter |> String.replace("OFFSET", "0"))
    theirs = program(402, 1, @offset_counter |> String.replace("OFFSET", "1000"))
    module = slot_module(mine)
    assert :ok = CodeServer.release(mine.content_hash)
    assert slot_module(theirs) == module

    assert {:ok, pid} = start(mine, 1, %{})
    assert GenServer.call(pid, "get") == 1
    # The one-slot window now holds `mine` again, pinned by the actor.
    assert %{content_hash: hash, pins: 1} = slot(module)
    assert hash == mine.content_hash
    assert {:error, {:hyperlang, %{category: :code_pool}}} = start(theirs, 1, %{})

    :ok = stop(pid)
    assert {:ok, other} = start(theirs, 1, %{})
    assert GenServer.call(other, "get") == 1001
    :ok = stop(other)
    assert_pins(baseline)
  end

  test "a generated module is not an OTP callback module" do
    program = program(403, 6)
    module = slot_module(program)
    refute function_exported?(module, :init, 1)
    refute function_exported?(module, :handle_call, 3)
    assert {:error, {:undef, _}} = GenServer.start(module, {%{}, 1})
  end

  test "start_link links the actor, takes GenServer options, and rejects bad input", %{
    baseline: baseline
  } do
    program = program(406, 6)
    parent = self()

    owner =
      spawn(fn ->
        {:ok, pid} =
          GenServer.start_link(Hyperlang.Actor, {%{}, program, 1}, name: :code_slot_pin_named)

        send(parent, {:started, pid})
        receive do: (:exit -> exit(:shutdown))
      end)

    assert_receive {:started, pid}, 5_000
    assert GenServer.call(:code_slot_pin_named, "inc") == 2
    assert %{pins: 1} = slot(slot_module(program))
    monitor = Process.monitor(pid)
    send(owner, :exit)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :shutdown}, 5_000
    assert_pins(baseline)

    for bad <- [{%{}, :not_a_program, 1}, {:not_a_spec, program, 1}, {program, %{}, 1}, :bad] do
      assert {:error, {:hyperlang, %{category: :api}}} = GenServer.start(Hyperlang.Actor, bad)
    end

    assert {:error, %{category: :api}} = Hyperlang.load(:not_a_program)
    assert_pins(baseline)
  end

  test "a supervisor starts actors from child specs and restarts them", %{baseline: baseline} do
    p1 = program(407, 6)
    p2 = program(408, 6)

    children = [
      Supervisor.child_spec({Hyperlang.Actor, {%{}, p1, 10}}, id: :one),
      Supervisor.child_spec({Hyperlang.Actor, {%{}, p1, 20}}, id: :two),
      {Hyperlang.Actor, {%{}, p2, 30}}
    ]

    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)
    pids = Map.new(Supervisor.which_children(sup), fn {id, pid, :worker, _} -> {id, pid} end)
    assert Map.keys(pids) |> Enum.sort() == Enum.sort([:one, :two, Hyperlang.Actor])
    assert GenServer.call(pids.one, "inc") == 11
    assert GenServer.call(pids.two, "inc") == 21
    assert GenServer.call(pids[Hyperlang.Actor], "inc") == 31

    # A released slot under a crashed actor: the restart loads and pins again.
    :ok = CodeServer.release(p1.content_hash)
    monitor = Process.monitor(pids.one)
    Process.exit(pids.one, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}, 5_000

    restarted =
      Enum.find_value(1..500, fn _ ->
        case List.keyfind(Supervisor.which_children(sup), :one, 0) do
          {:one, pid, _, _} when is_pid(pid) and pid != pids.one -> pid
          _ -> Process.sleep(10) && nil
        end
      end)

    assert GenServer.call(restarted, "inc") == 11
    assert %{content_hash: hash} = slot(slot_module(p1))
    assert hash == p1.content_hash

    # Two actors with the default id collide, as for any GenServer.
    parent = self()

    spawn(fn ->
      Process.flag(:trap_exit, true)

      send(
        parent,
        {:duplicate,
         Supervisor.start_link(
           [{Hyperlang.Actor, {%{}, p1, 1}}, {Hyperlang.Actor, {%{}, p2, 2}}],
           strategy: :one_for_one
         )}
      )
    end)

    assert_receive {:duplicate,
                    {:error, {:start_spec, {:duplicate_child_name, Hyperlang.Actor}}}},
                   5_000

    assert %{id: Hyperlang.Actor, restart: :permanent, start: {GenServer, :start_link, _}} =
             Supervisor.child_spec({Hyperlang.Actor, {%{}, p1, 1}}, [])

    :ok = Supervisor.stop(sup)
    assert_pins(baseline)
  end

  test "an actor started with a heap copy of its program keeps only the literal", %{
    baseline: baseline
  } do
    program = program(409, 6)
    # A heap copy, as a host holds it after `Hyperlang.program/1`.
    copy = :erlang.binary_to_term(:erlang.term_to_binary(program))
    pid = start!(copy, 1)
    assert GenServer.call(pid, "inc") == 2
    {:ok, %{program: literal}} = CodeServer.load(program)
    %{program: held} = :sys.get_state(pid)
    assert :erts_debug.same(held, literal)
    :erlang.garbage_collect(pid)
    {:memory, bytes} = Process.info(pid, :memory)
    assert bytes < :erts_debug.flat_size(program) * 8, "actor holds #{bytes} bytes"
    :ok = stop(pid)
    assert_pins(baseline)
  end

  test "optional callbacks follow the program's exports", %{baseline: baseline} do
    # `@counter` exports neither handle_info/2, handle_cast/2 nor terminate/2.
    pid = start!(program(405, 6), 3)
    send(pid, :unexpected)
    assert GenServer.call(pid, "inc") == 4

    monitor = Process.monitor(pid)
    GenServer.cast(pid, "inc")
    # A required callback the program lacks is a typed stop, not `undef`.
    assert_receive {:DOWN, ^monitor, :process, ^pid, {:hyperlang, %{category: :export}}}, 5_000
    assert_pins(baseline)
  end

  test "init in a full window fails with code_pool and pins nothing", %{baseline: baseline} do
    window = 2
    extra = program(410, window)
    assert :ok = Hyperlang.load(extra)
    assert :ok = CodeServer.release(extra.content_hash)
    actors = for salt <- 411..412, do: start!(program(salt, window), 0)

    assert {:error, {:hyperlang, %{category: :code_pool}}} = start(extra, 1, %{})

    :ok = stop(hd(actors))
    assert {:ok, pid} = start(extra, 7, %{})
    assert GenServer.call(pid, "inc") == 8

    Enum.each([pid | tl(actors)], &stop/1)
    assert_pins(baseline)
  end

  test "starts racing releases and slot reuse always run their own program", %{
    baseline: baseline
  } do
    window = 2
    source = &(@offset_counter |> String.replace("OFFSET", Integer.to_string(&1)))
    programs = for offset <- [0, 1000, 2000], do: program(420 + offset, window, source.(offset))
    parent = self()

    churner =
      spawn_link(fn ->
        Stream.cycle(programs)
        |> Enum.reduce_while(0, fn program, n ->
          receive do
            :stop -> {:halt, n}
          after
            0 ->
              CodeServer.release(program.content_hash)
              Hyperlang.load(program)
              {:cont, n + 1}
          end
        end)
        |> then(&send(parent, {:churned, &1}))
      end)

    starters =
      for {program, offset} <- Enum.zip(programs, [0, 1000, 2000]) do
        Task.async(fn ->
          for n <- 1..300, reduce: %{ok: 0, code_pool: 0} do
            acc ->
              case start(program, n, %{}) do
                {:ok, pid} ->
                  # The actor runs the program it was started with, nothing else.
                  value = GenServer.call(pid, "get")
                  GenServer.stop(pid)
                  if value != n + offset, do: raise("ran #{value}, expected #{n + offset}")
                  # The pool has no admission fairness: back-to-back restarts
                  # of two programs keep a two-slot window pinned and starve
                  # the third. A pause lets every program reach a slot.
                  Process.sleep(1)
                  Map.update!(acc, :ok, &(&1 + 1))

                # A two-slot window, three programs: a start may find every
                # slot pinned. Never `undef`, never a stale program.
                {:error, {:hyperlang, %{category: :code_pool}}} ->
                  Map.update!(acc, :code_pool, &(&1 + 1))
              end
          end
        end)
      end

    counts = Task.await_many(starters, 120_000)
    send(churner, :stop)
    assert_receive {:churned, churned}, 10_000
    assert churned > 0
    assert Enum.all?(counts, &(&1.ok > 0)), inspect(counts)
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

  test "one process may pin several slots, and its exit drops each pin", %{
    baseline: baseline
  } do
    p1 = program(600, 16)
    p2 = program(601, 16)
    parent = self()

    host =
      spawn(fn ->
        {:ok, ^p1} = CodeServer.pin(p1, {__MODULE__, :host})
        {:ok, ^p2} = CodeServer.pin(p2, {__MODULE__, :host})
        send(parent, :pinned)
        receive do: (:exit -> :ok)
      end)

    assert_receive :pinned, 5_000
    {m1, m2} = {slot_module(p1), slot_module(p2)}
    assert %{pins: 1} = slot(m1)
    assert %{pins: 1} = slot(m2)

    assert :ok = CodeServer.release(p1.content_hash)
    assert :ok = CodeServer.release(p2.content_hash)
    assert %{state: :used, released?: true} = slot(m1)
    assert %{state: :used, released?: true} = slot(m2)

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
