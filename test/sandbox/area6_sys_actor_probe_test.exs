defmodule Hyperlang.Area6SysActorProbeTest do
  # AREA 6/10: host process safety, the sys:* syscall facade, and actor-callback
  # isolation. Door-backed sys ops must fail closed without a host door; the sys
  # facade must not hand the guest ambient nondeterminism; a guest must not block
  # or crash the host.
  use ExUnit.Case, async: false
  import Hyperlang.SandboxProbe
  alias Hyperlang.Test, as: Kit

  @sys %{sys: %{enabled: true}}

  describe "nondeterminism gate (control): erlang/rand clocks need the capability" do
    for b <- [
          "erlang:monotonic_time()",
          "erlang:system_time()",
          "erlang:timestamp()",
          "rand:mwc59_seed()"
        ] do
      test "reject without capability: #{b}" do
        assert rejected?("result(_) -> #{unquote(b)}.")
      end
    end
  end

  describe "sys facade must not grant a live clock without the nondeterminism capability" do
    # C1: sys:millisec/0 is a live clock reader, gated by
    # capabilities.nondeterminism like the erlang:* / rand:* readers above.
    test "sys:millisec is gated like erlang:monotonic_time" do
      assert rejected?("result(_) -> sys:millisec().", @sys),
             "sys:millisec read a live clock with no nondeterminism capability: " <>
               inspect(run("result(_) -> sys:millisec().", @sys))
    end

    test "the rejection names the missing capability" do
      assert {:error, [%{category: :verify, message: message} | _]} =
               compile("result(_) -> sys:millisec().", @sys)

      assert message =~ "sys:millisec/0"
      assert message =~ "capabilities.nondeterminism"
    end

    test "sys:millisec runs with the nondeterminism capability" do
      assert {:ok, ms, _} =
               run(
                 "result(_) -> sys:millisec().",
                 Map.put(@sys, :capabilities, %{nondeterminism: true})
               )

      assert is_integer(ms) and ms >= 0
    end

    test "deterministic sys calls stay admitted without the capability" do
      assert {:ok, 256, _} = run("result(_) -> sys:namemax().", @sys)
      assert {:ok, 0, _} = run("result(_) -> sys:sleep(0).", @sys)
    end
  end

  describe "other live host values need the nondeterminism capability" do
    test "calendar:system_time_to_rfc3339/1 formats in the host time zone and is gated" do
      assert rejected?("result(_) -> calendar:system_time_to_rfc3339(0).", %{
               stdlib: %{calendar: true}
             })

      assert {:ok, local, _} =
               run("result(_) -> calendar:system_time_to_rfc3339(0).", %{
                 stdlib: %{calendar: true},
                 capabilities: %{nondeterminism: true}
               })

      assert is_list(local)
    end

    test "calendar:system_time_to_rfc3339/2 needs an explicit offset without the capability" do
      m = %{stdlib: %{calendar: true}}

      assert {:ok, ~c"1970-01-01T00:00:00Z", _} =
               run(~S|result(_) -> calendar:system_time_to_rfc3339(0, [{offset, "Z"}]).|, m)

      assert {:ok, ~c"1970-01-01T00:00:00+00:00", _} =
               run("result(_) -> calendar:system_time_to_rfc3339(0, [{offset, 0}]).", m)

      for options <- ["[]", "[{unit, second}]", ~S|[{offset, ""}]|] do
        assert {:error, %{category: :stdlib}} =
                 run("result(_) -> calendar:system_time_to_rfc3339(0, #{options}).", m)
      end
    end

    test "table handles are per-run counters, not a node-wide clock-like value" do
      src = "result(_) -> {hyperlang_table:new(set), hyperlang_table:new(set)}."
      m = %{tables: %{enabled: true}}
      assert {:ok, {1, 2}, _} = run(src, m)
      assert {:ok, {1, 2}, _} = run(src, m)
    end
  end

  describe "door-backed sys ops fail closed without a host syscall door" do
    for {name, body} <- [
          {"sys:open", "sys:open(<<\"/x\">>, 0)"},
          {"sys:stat", "sys:stat(<<\"/x\">>)"},
          {"sys:remove", "sys:remove(<<\"/x\">>)"},
          {"sys:chdir", "sys:chdir(<<\"/x\">>)"},
          {"sys:fd2path", "sys:fd2path(0)"},
          {"sys:bind", "sys:bind(<<\"a\">>, <<\"b\">>, 0)"}
        ] do
      test "#{name} does not reach the host and returns a fail-closed value" do
        out = run("result(_) -> #{unquote(body)}.", @sys)

        case out do
          {:ok, v, _} ->
            # Fail-closed sentinel: a negative fd, a {-1, _} tuple, or nil. Never
            # a path, binary payload, or positive handle that reached the host.
            assert v == nil or (is_integer(v) and v < 0) or
                     match?({n, _} when is_integer(n) and n < 0, v),
                   "sys op returned a non-fail-closed value: #{inspect(v)}"

          {:error, _} ->
            :ok

          {:rejected, _} ->
            :ok
        end

        assert leaks_in(text(out)) == []
      end
    end

    test "sys:* is rejected at compile time when sys is disabled" do
      assert rejected?("result(_) -> sys:millisec().")
      assert rejected?("result(_) -> sys:open(<<\"/x\">>, 0).")
    end
  end

  describe "a guest cannot block or crash the host indefinitely" do
    test "an infinite loop is bounded by the wall deadline, not the host" do
      out = run("result(_) -> (fun L() -> L() end)().", %{limits: %{wall_ms: 80}})

      assert match?(
               {:error, %{category: cat}} when cat in [:reduction_watchdog, :timeout, :heap],
               out
             )
    end

    test "an infinite native-sleep loop is bounded by the wall deadline" do
      out = run("result(_) -> (fun L() -> timer:sleep(1), L() end)().", %{limits: %{wall_ms: 80}})
      assert match?({:error, _}, out)
    end

    test "a crafted exception term returns a sanitized error, not a host crash" do
      out =
        run(
          "result(_) -> erlang:error({weird, [deep, \#{nested => stuff}]}).",
          %{terms: %{public: :erlang, allowed_atoms: [:weird, :deep, :nested, :stuff]}}
        )

      assert match?({:error, %{category: _}}, out)
      assert leaks_in(text(out)) |> Enum.reject(&(&1 in ["hyperlang_msg", "with_context"])) == []
    end
  end

  describe "actor callbacks: a fun persisted across callbacks does not escalate authority" do
    # S5 investigation: a fun created in init persists via the guest process
    # dictionary and is callable in a later callback. This is confirmed, but it
    # does not gain authority — the actor's spec (and thus binding authority) is
    # fixed at init, so the persisted fun uses exactly the current authority.
    test "a fun stashed in init runs in handle_call with current binding authority" do
      binding = %{"kv" => %{get: fn _ -> 99 end}}

      program =
        Kit.program!(
          """
          init(_) -> F = fun() -> kv:get(x) end, put(f, F), {ok, 0}.
          handle_call(_, _, S) -> G = get(f), {reply, G(), S}.
          handle_info(_, S) -> {noreply, S}.
          """,
          pub(%{
            result: %{name: "init", arity: 1},
            terms: %{public: :erlang, allowed_atoms: [:ok, :reply, :noreply, :x]},
            bindings: binding
          })
        )

      actor = Kit.start_actor!(program, nil, bindings: binding)
      assert GenServer.call(actor, 0) == 99
      GenServer.stop(actor)
    end

    test "guest process dictionary is fresh for a fresh actor (no leak between actors)" do
      program =
        Kit.program!(
          """
          init(_) -> {ok, 0}.
          handle_call(_, _, S) -> Prev = get(seen), put(seen, yes), {reply, Prev, S}.
          handle_info(_, S) -> {noreply, S}.
          """,
          pub(%{
            result: %{name: "init", arity: 1},
            terms: %{
              public: :erlang,
              allowed_atoms: [:ok, :reply, :noreply, :yes, :undefined, :seen]
            }
          })
        )

      a1 = Kit.start_actor!(program, nil)
      assert GenServer.call(a1, 0) == :undefined
      assert GenServer.call(a1, 0) == :yes
      a2 = Kit.start_actor!(program, nil)
      # A second actor starts with an empty guest dictionary.
      assert GenServer.call(a2, 0) == :undefined
      GenServer.stop(a1)
      GenServer.stop(a2)
    end
  end
end
