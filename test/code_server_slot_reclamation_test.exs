defmodule CodeServerSlotReclamationTest do
  use ExUnit.Case, async: false

  # The generated-code pool is a bounded, RECLAIMED resource: a slot whose
  # artifact is no longer wanted (release) or whose window is oversubscribed
  # returns to the pool once no process runs its module. These tests hold the
  # pool to a window far smaller than the number of artifacts they load.

  @window 6
  @run_spec %{bindings: %{}, policy: %{}}

  defp program!(value) do
    {:ok, program} =
      Hyperlang.program(%{
        entry: "prog.erl",
        files: %{"prog.erl" => "#{value}.\n"},
        manifest: %{code_pool: %{size: @window}}
      })

    program
  end

  defp slot_id(module) do
    [_, id] = Regex.run(~r/^hyperlang_slot_0*(\d+)$/, Atom.to_string(module))
    String.to_integer(id)
  end

  defp slot_states do
    Hyperlang.CodeServer
    |> Process.whereis()
    |> :sys.get_state()
    |> Map.fetch!(:slots)
  end

  test "a window smaller than the artifact count reuses slots instead of exhausting" do
    slot_ids =
      for value <- 1..(@window * 2) do
        program = program!(value)
        module = Hyperlang.module(program)
        assert {:ok, ^value, _meta} = Hyperlang.run(@run_spec, program, :entry, [0])
        slot_id(module)
      end

    assert Enum.all?(slot_ids, &(&1 <= @window)),
           "loads escaped the requested window: #{inspect(Enum.uniq(slot_ids))}"

    assert length(Enum.uniq(slot_ids)) < length(slot_ids),
           "no slot was reused across #{length(slot_ids)} artifacts in a #{@window}-slot window"
  end

  test "a reclaimed artifact reloads on its next use" do
    program = program!(4242)
    first = Hyperlang.module(program)

    # Oversubscribe the window so the artifact above loses its slot.
    for value <- 5000..(5000 + @window * 2), do: Hyperlang.module(program!(value))

    second = Hyperlang.module(program)

    assert :code.is_loaded(second) != false
    assert {:ok, 4242, _meta} = Hyperlang.run(@run_spec, program, :entry, [0])
    assert slot_id(first) <= @window and slot_id(second) <= @window
  end

  test "release purges the module and frees the slot" do
    program = program!(7001)
    module = Hyperlang.module(program)
    id = slot_id(module)

    assert %{state: :used, content_hash: hash} = Map.fetch!(slot_states(), id)
    assert hash == program.content_hash

    assert :ok = Hyperlang.CodeServer.release(program.content_hash)

    assert %{state: :free, content_hash: nil} = Map.fetch!(slot_states(), id)
    assert :code.is_loaded(module) == false

    # The released artifact is not lost: the door reloads it on next use.
    assert {:ok, 7001, _meta} = Hyperlang.run(@run_spec, program, :entry, [0])
  end

  test "a released slot keeps its version so stale runtimes cannot be replayed into it" do
    program = program!(7002)
    id = program |> Hyperlang.module() |> slot_id()
    version = Map.fetch!(slot_states(), id).version

    assert :ok = Hyperlang.CodeServer.release(program.content_hash)

    # `Runtime.new_context/3` matches a caller's runtime against the version
    # baked into the loaded module. A freed slot that restarted at version 1
    # would let a stale runtime from an earlier occupant pass that check, so
    # the version is monotonic per slot for the life of the VM.
    assert %{state: :free, version: ^version} = Map.fetch!(slot_states(), id)
    assert version > 0
  end
end
