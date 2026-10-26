defmodule HyperlangSyscallHostTest do
  # The host syscall door: a bound {module, state} implementing
  # Hyperlang.SyscallHost, with per-eval host state seeded into the worker
  # pdict and harvested into the reply envelope. One static call per syscall;
  # no closures, no shared-table round-trips.
  use ExUnit.Case, async: false

  alias Hyperlang.Chan

  @scope_hook_key :guest_channel_scope
  @unset {__MODULE__, :unset}

  defmodule Door do
    @behaviour Hyperlang.SyscallHost

    @impl true
    def syscall(_bound, :open, [path, _mode]) do
      state = Hyperlang.SyscallHost.get_state() || %{opens: []}
      :ok = Hyperlang.SyscallHost.put_state(%{state | opens: state.opens ++ [to_string(path)]})
      3
    end

    def syscall(_bound, :read, [fd, _buf, _count]) when is_integer(fd), do: {2, <<"hi">>}
    def syscall(_bound, :close, [_fd]), do: 0

    def syscall(test_pid, operation, args)
        when is_pid(test_pid) and operation in [:fwstat, :wstat, :spawn, :newns] do
      send(test_pid, {:door_call, operation, args})
      0
    end

    def syscall(_bound, _operation, _args), do: {:hyperlang_syscall_error, :enotsup}
  end

  defp compile!(source, manifest) do
    {:ok, program} = Hyperlang.Test.program(source, manifest)
    program
  end

  defp channel_manifest(entries) do
    # The classification key is {function, arity, newchan_index} of the
    # COMPILED guest function — so the function must exist as a declared
    # export; a bare result-root body compiles under a synthetic name and the
    # key never matches (silently degrading to :may_contain_handles).
    %{
      terms: %{public: :erlang},
      sys: %{
        enabled: true,
        channel_element_types: entries
      },
      exports: %{functions: %{"result/1" => %{function: "result", arity: 1}}}
    }
  end

  test "snapshots distinguish absent state from present nil state" do
    previous = Hyperlang.SyscallHost.snapshot_state()

    try do
      Hyperlang.SyscallHost.clear_state()
      assert Hyperlang.SyscallHost.get_state() == nil
      assert Hyperlang.SyscallHost.snapshot_state() == :absent

      assert :ok = Hyperlang.SyscallHost.put_state(nil)
      assert Hyperlang.SyscallHost.get_state() == nil
      assert Hyperlang.SyscallHost.harvest_state() == nil
      assert Hyperlang.SyscallHost.snapshot_state() == {:present, nil}
    after
      Hyperlang.SyscallHost.restore_state(previous)
    end
  end

  test "sys:newns() performs the newns syscall and sys:rfcnameg() is the flag" do
    program =
      compile!("{sys:newns(), sys:rfcnameg()}.", %{
        terms: %{public: :erlang},
        sys: %{enabled: true}
      })

    assert {:ok, {0, 4}, _} =
             Hyperlang.Test.run(program, :entry, [:ok], syscall: {Door, self()})

    assert_received {:door_call, :newns, []}
  end

  test "typed newchan threads handle-free classification to the runtime" do
    with_channel_scope(fn ->
      program =
        compile!(
          "result(_) -> sys:newchan(0).",
          channel_manifest([
            %{function: "result", arity: 1, index: 0, type: "binary"}
          ])
        )

      assert {:ok, handle, _} = Hyperlang.Test.run(program, :entry, [:ok])
      assert is_integer(handle)

      # Deterministic assertion (the previous global :erlang.trace capture was
      # racy under the parallel suite): the classification the codegen threaded
      # through is whatever the runtime STORED for the created channel's
      # broker. Resolve the handle in the test scope and read it back.
      scope = Application.fetch_env!(:hyperlang, :guest_channel_scope).()
      broker = Hyperlang.Chan.resolve(scope, handle)
      assert is_pid(broker)
      assert Hyperlang.Chan.channel_classification(broker) == :handle_free
    end)
  end

  test "channel type classifier is conservative for dynamic or channel-bearing types" do
    assert Hyperlang.ChannelTypes.classify("binary") == :handle_free

    assert Hyperlang.ChannelTypes.classify(%{
             type: "record",
             fields: %{payload: "binary", count: "int"}
           }) == :handle_free

    assert Hyperlang.ChannelTypes.classify("any") == :may_contain_handles

    assert Hyperlang.ChannelTypes.classify({:tuple, [:binary, {:chan, :binary}]}) ==
             :may_contain_handles

    assert Hyperlang.ChannelTypes.classify({:unknown_user_type, []}) == :may_contain_handles
  end

  test "chan of any can carry a nested channel handle and receiver can use it" do
    with_channel_scope(fn ->
      source = ~S"""
      result(_) ->
        C = sys:newchan(1),
        D = sys:newchan(1),
        sys:csend(C, {nested, [D]}),
        {nested, [Received]} = sys:crecv(C),
        sys:csend(Received, <<"works">>),
        sys:crecv(D).
      """

      program =
        compile!(
          source,
          channel_manifest([
            %{function: "result", arity: 1, index: 0, type: "any"},
            %{function: "result", arity: 1, index: 1, type: "binary"}
          ])
        )

      assert {:ok, <<"works">>, _} = Hyperlang.Test.run(program, :entry, [:ok])
    end)
  end

  test "guest alt facade uses the runtime channel implementation" do
    with_channel_scope(fn ->
      source = ~S"""
      result(_) ->
        C = sys:newchan(1),
        sys:csend(C, <<"v">>),
        sys:alt([{recv, C}]).
      """

      program =
        compile!(
          source,
          channel_manifest([
            %{function: "result", arity: 1, index: 0, type: "binary"}
          ])
        )

      assert {:ok, {0, <<"v">>}, _} =
               Hyperlang.Test.run(program, :entry, [:ok])
    end)
  end

  defp with_channel_scope(fun) when is_function(fun, 0) do
    previous = Application.get_env(:hyperlang, @scope_hook_key, @unset)
    scope = {:syscall_host_test_scope, self(), make_ref()}

    Application.put_env(:hyperlang, @scope_hook_key, fn -> scope end)

    try do
      fun.()
    after
      Chan.close_scope(scope)

      case previous do
        @unset -> Application.delete_env(:hyperlang, @scope_hook_key)
        value -> Application.put_env(:hyperlang, @scope_hook_key, value)
      end
    end
  end
end
