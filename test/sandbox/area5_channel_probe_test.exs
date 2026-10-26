defmodule Hyperlang.Area5ChannelProbeTest do
  # AREA 5: channels (sys:csend/crecv/alt via Hyperlang.Chan). Guest channel
  # sends follow the `!` carrier rule, handles are scope-keyed, and channels
  # fail closed without a host-installed scope hook.
  use ExUnit.Case, async: false
  alias Hyperlang.Chan
  import Hyperlang.SandboxProbe

  @scope_key :guest_channel_scope
  @unset {__MODULE__, :unset}
  @proc_scope_key {__MODULE__, :scope}

  setup do
    previous = Application.get_env(:hyperlang, @scope_key, @unset)
    scope = {:scope, self(), make_ref()}
    Process.put(@proc_scope_key, scope)
    Application.put_env(:hyperlang, @scope_key, fn -> Process.get(@proc_scope_key, scope) end)

    on_exit(fn ->
      Chan.close_scope(scope)
      Process.delete(@proc_scope_key)

      case previous do
        @unset -> Application.delete_env(:hyperlang, @scope_key)
        value -> Application.put_env(:hyperlang, @scope_key, value)
      end
    end)

    {:ok, scope: scope}
  end

  test "channels fail closed without a scope hook" do
    previous = Application.get_env(:hyperlang, @scope_key, @unset)
    Application.delete_env(:hyperlang, @scope_key)

    try do
      assert Chan.newchan(0) == {:error, :no_scope}
      assert Chan.csend(123, :value) == {:error, :no_scope}
      assert Chan.crecv(123) == {:error, :no_scope}
    after
      case previous do
        @unset -> Application.delete_env(:hyperlang, @scope_key)
        value -> Application.put_env(:hyperlang, @scope_key, value)
      end
    end
  end

  test "a handle from one scope is not usable from another scope", %{scope: scope_a} do
    {handle, _broker} = Chan.newchan(scope_a, 1)
    scope_b = {:scope, self(), make_ref()}

    # Switch this process to scope B and try to use scope A's handle.
    Process.put(@proc_scope_key, scope_b)

    try do
      assert Chan.csend(handle, :x) == {:error, :badchan}
      assert Chan.crecv(handle) == {:error, :badchan}
    after
      Process.put(@proc_scope_key, scope_a)
      Chan.close_scope(scope_b)
    end
  end

  # C2: the guest channel send paths follow the `!` carrier rule. Host kernels
  # that hold broker pids use Hyperlang.Chan directly and stay trusted, so the
  # probe drives the guest door (`sys:csend`, `sys:alt` send arms).
  describe "C2: guest channel sends reject forbidden carriers like !" do
    for {name, body} <- [
          {"csend of a fun", "sys:csend(C, fun() -> ok end)"},
          {"csend of a nested fun", "sys:csend(C, {wrap, [\#{k => fun() -> ok end}]})"},
          {"alt send arm with a fun", "sys:alt([{send, C, fun() -> ok end}])"},
          {"labelled alt send arm with a fun", "sys:alt([{lbl, send, C, fun() -> ok end}])"}
        ] do
      test "#{name} is refused before delivery" do
        src = """
        result(_) ->
          C = sys:newchan(1),
          Sent = try #{unquote(body)} of _ -> delivered catch error:_ -> refused end,
          {Sent, sys:alt([{recv, C}, default])}.
        """

        assert {:ok, {:refused, :default}, _} =
                 run(src, %{
                   sys: %{enabled: true},
                   terms: %{allowed_atoms: [:delivered, :refused, :default]}
                 })
      end
    end

    test "plain data still crosses a guest channel" do
      src = """
      result(_) ->
        C = sys:newchan(1),
        sys:csend(C, {data, [1, 2]}),
        sys:crecv(C).
      """

      assert {:ok, {"data", [1, 2]}, _} = run(src, %{sys: %{enabled: true}})
    end
  end
end
