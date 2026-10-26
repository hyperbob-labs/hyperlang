defmodule Hyperlang.Area5CrossGuestProbeTest do
  # AREA 5: cross-guest isolation. A guest must not read or write another guest's
  # process dictionary, stdout, or identity, and each run starts from clean
  # per-run state. Without a host-installed message resolver a guest cannot reach
  # any other process at all.
  use ExUnit.Case, async: false
  import Hyperlang.SandboxProbe
  alias Hyperlang.Test, as: Kit

  describe "per-run process dictionary is fresh and private" do
    test "a dictionary write in one run is invisible to the next run" do
      {:ok, p} =
        compile(
          "result(_) -> Prev = get(marker), put(marker, set), Prev.",
          %{terms: %{public: :erlang, allowed_atoms: [:marker, :set, :undefined]}}
        )

      assert {:ok, :undefined, _} = Kit.run(p, :entry, [nil])
      # A second run of the same program must not see the first run's write.
      assert {:ok, :undefined, _} = Kit.run(p, :entry, [nil])
    end

    test "get() is empty at the start of a run" do
      assert {:ok, [], _} = run("result(_) -> get().")
    end

    for key <- [
          "'$ancestors'",
          "'$initial_call'",
          "'$hyperlang_msg_context'",
          "'$hyperlang_guest_process_dictionary_value'"
        ] do
      test "host/runtime dict key #{key} reads as undefined" do
        assert {:ok, :undefined, _} =
                 run("result(_) -> get(#{unquote(key)}).", %{
                   terms: %{public: :erlang, allowed_atoms: [:undefined]}
                 })
      end
    end
  end

  describe "stdout is isolated per run" do
    test "one run's stdout does not appear in another run's meta" do
      {:ok, p1} =
        compile(
          ~S|result(_) -> io:put_chars("first-guest-output"), ok.|,
          %{terms: %{public: :erlang, allowed_atoms: [:ok]}}
        )

      {:ok, p2} =
        compile(~S|result(_) -> ok.|, %{terms: %{public: :erlang, allowed_atoms: [:ok]}})

      assert {:ok, :ok, %{stdout: s1}} = Kit.run(p1, :entry, [nil])
      assert Enum.join(s1) =~ "first-guest-output"

      assert {:ok, :ok, %{stdout: s2}} = Kit.run(p2, :entry, [nil])
      refute Enum.join(s2) =~ "first-guest-output"
      assert s2 == []
    end
  end

  describe "a guest cannot obtain or reach another process" do
    for {name, body} <- [
          {"self", "self()"},
          {"spawn without hook returns no pid", "spawn(fun() -> ok end)"},
          {"send without resolver", "p ! m"}
        ] do
      test "#{name} does not yield a usable process handle" do
        out =
          run("result(_) -> #{unquote(body)}.", %{
            terms: %{public: :erlang, allowed_atoms: [:ok, :m, :p]}
          })

        # Either compile-rejected (self) or a fail-closed runtime error (spawn/send
        # without a host policy hook). Never an ok with a pid/ref.
        refute match?({:ok, v, _} when is_pid(v) or is_reference(v), out)
      end
    end
  end

  describe "run metadata carries only host-measured integers, no guest internals" do
    test "meta has exactly stdout/reductions/wall_us with safe shapes" do
      assert {:ok, 1, meta} = run("result(_) -> 1.")
      assert Map.keys(meta) |> Enum.sort() == [:reductions, :stdout, :wall_us]
      assert is_integer(meta.reductions) and meta.reductions >= 0
      assert is_integer(meta.wall_us) and meta.wall_us >= 0
      assert meta.stdout == []
      assert leaks_in(text(meta)) == []
    end
  end
end
