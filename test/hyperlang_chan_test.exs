defmodule HyperlangChanTest do
  use ExUnit.Case, async: false

  alias Hyperlang.Chan

  @scope_key :guest_channel_scope
  @unset {__MODULE__, :unset}
  @proc_scope_key {__MODULE__, :scope}
  @known_handles_key {Hyperlang.Chan, :known_channel_handles}

  defmodule Hook do
    def close({parent, label}, swept), do: send(parent, {:fileio_closed, label, swept})
  end

  setup do
    previous = Application.get_env(:hyperlang, @scope_key, @unset)
    default_scope = {:scope, self(), make_ref()}
    Process.put(@proc_scope_key, default_scope)
    Process.delete(@known_handles_key)

    Application.put_env(:hyperlang, @scope_key, fn ->
      Process.get(@proc_scope_key, default_scope)
    end)

    on_exit(fn ->
      Chan.close_scope(default_scope)
      Process.delete(@proc_scope_key)
      Process.delete(@known_handles_key)

      case previous do
        @unset -> Application.delete_env(:hyperlang, @scope_key)
        value -> Application.put_env(:hyperlang, @scope_key, value)
      end
    end)

    {:ok, scope: default_scope}
  end

  test "guest operations fail closed without a scope hook" do
    previous = Application.get_env(:hyperlang, @scope_key, @unset)
    Application.delete_env(:hyperlang, @scope_key)

    try do
      assert Chan.current_scope() == {:error, :no_scope}
      assert Chan.newchan(0) == {:error, :no_scope}
      assert Chan.csend(123, :value) == {:error, :no_scope}
      assert Chan.crecv(123) == {:error, :no_scope}
      assert Chan.alt([{:recv, 123}, :default]) == {:error, :no_scope}
    after
      case previous do
        @unset -> Application.delete_env(:hyperlang, @scope_key)
        value -> Application.put_env(:hyperlang, @scope_key, value)
      end
    end
  end

  test "unbuffered rendezvous consumes N sends FIFO", %{scope: scope} do
    {handle, _broker} = Chan.newchan(scope, 0)
    parent = self()

    sender =
      spawn(fn ->
        put_scope(scope)

        for value <- 1..8 do
          assert Chan.csend(handle, value) == handle
          send(parent, {:sent, value})
        end
      end)

    for value <- 1..8 do
      assert Chan.crecv(handle) == value
      assert_receive {:sent, ^value}, 500
    end

    assert_process_down(sender)
  end

  test "buffered channel drains FIFO and recv frees a slot for a parked sender", %{scope: scope} do
    {handle, _broker} = Chan.newchan(scope, 2)

    assert Chan.csend(handle, :a) == handle
    assert Chan.csend(handle, :b) == handle

    parent = self()

    sender =
      spawn(fn ->
        put_scope(scope)
        result = Chan.csend(handle, :c)
        send(parent, {:parked_sender_done, result})
      end)

    refute_receive {:parked_sender_done, _}, 100

    assert Chan.crecv(handle) == :a
    assert_receive {:parked_sender_done, ^handle}, 500
    assert Chan.crecv(handle) == :b
    assert Chan.crecv(handle) == :c

    assert_process_down(sender)
  end

  test "alt selects the ready recv arm by original index", %{scope: scope} do
    {h1, _b1} = Chan.newchan(scope, 0)
    {h2, _b2} = Chan.newchan(scope, 1)

    assert Chan.csend(h2, :ready) == h2
    assert Chan.alt([{:recv, h1}, {:recv, h2}]) == {:recv, 1, :ready}
  end

  test "alt default fires when no channel operation is ready", %{scope: scope} do
    {handle, _broker} = Chan.newchan(scope, 0)

    assert Chan.alt([{:recv, handle}, :default]) == :default
  end

  test "alt blocks then commits exactly once when two recv arms race", %{scope: scope} do
    {h1, _b1} = Chan.newchan(scope, 0)
    {h2, _b2} = Chan.newchan(scope, 0)
    parent = self()

    alt_pid =
      spawn(fn ->
        put_scope(scope)
        send(parent, {:alt_result, Chan.alt([{:recv, h1}, {:recv, h2}])})
      end)

    Process.sleep(50)

    s1 = scoped_sender(scope, h1, :one, 1)
    s2 = scoped_sender(scope, h2, :two, 2)

    assert_receive {:alt_result, {:recv, index, value}}, 1_000
    assert {index, value} in [{0, :one}, {1, :two}]

    assert_receive {:sender_done, done_id, done_result}, 1_000
    assert done_result in [h1, h2]

    losing_handle = if done_id == 1, do: h2, else: h1
    losing_id = if done_id == 1, do: 2, else: 1
    refute_receive {:sender_done, ^losing_id, _}, 100

    assert Chan.crecv(losing_handle) in [:one, :two]
    assert_receive {:sender_done, ^losing_id, ^losing_handle}, 1_000

    assert_process_down(alt_pid)
    assert_process_down(s1)
    assert_process_down(s2)
  end

  test "alt rejects send and recv arms on the same channel" do
    c = Chan.cnewc(:test, Chan.movtmp(), 0)

    try do
      assert_raise RuntimeError, "alt send/recv on same chan", fn ->
        Chan.alt([{:send, c, :payload}, {:recv, c}])
      end
    after
      Chan.close_broker(c)
    end
  end

  test "alt can commit a send arm in a mixed send and recv alt" do
    recv_idle = Chan.cnewc(:idle, Chan.movtmp(), 0)
    send_ready = Chan.cnewc(:send_ready, Chan.movtmp(), 0)
    parent = self()

    receiver =
      spawn(fn ->
        send(parent, {:receiver, Chan.crecv(send_ready)})
      end)

    try do
      eventually(fn -> :queue.len(:sys.get_state(send_ready).recvq) == 1 end)

      assert Chan.alt([{:recv, recv_idle}, {:send, send_ready, :payload}]) == {:send, 1}
      assert_receive {:receiver, :payload}, 500
      assert_process_down(receiver)
    after
      Chan.close_broker(recv_idle)
      Chan.close_broker(send_ready)
    end
  end

  test "opposing blocked alt send and recv calls rendezvous exactly once" do
    c = Chan.cnewc(:test, Chan.movtmp(), 0)

    try do
      recv_task = Task.async(fn -> Chan.alt([{:recv, c}]) end)
      Process.sleep(30)
      send_task = Task.async(fn -> Chan.alt([{:send, c, :payload}]) end)

      assert Task.await(send_task, 1_000) == {:send, 0}
      assert Task.await(recv_task, 1_000) == {:recv, 0, :payload}
    after
      Chan.close_broker(c)
    end
  end

  test "killed parked sender is purged and its dead value is not delivered" do
    c = Chan.cnewc(:test, Chan.movtmp(), 0)
    parent = self()

    sender =
      spawn(fn ->
        result = Chan.csend(c, :dead)
        send(parent, {:dead_sender_returned, result})
      end)

    try do
      eventually(fn -> :queue.len(:sys.get_state(c).sendq) == 1 end)
      Process.exit(sender, :kill)
      assert_process_down(sender, :killed)
      eventually(fn -> :queue.len(:sys.get_state(c).sendq) == 0 end)

      receiver =
        spawn(fn ->
          send(parent, {:receiver_value, Chan.crecv(c)})
        end)

      eventually(fn -> :queue.len(:sys.get_state(c).recvq) == 1 end)
      refute_receive {:receiver_value, :dead}, 100
      refute_receive {:dead_sender_returned, _}, 100

      assert Chan.csend(c, :live) == :ok
      assert_receive {:receiver_value, :live}, 500
      assert_process_down(receiver)
    after
      Chan.close_broker(c)
    end
  end

  test "broker survives allocator death and close_scope reaps the last reference" do
    scope = {:allocator_scope, make_ref()}
    :ok = Hyperlang.Scope.configure(scope, %{})
    on_exit(fn -> Chan.close_scope(scope) end)
    parent = self()

    creator =
      spawn(fn ->
        {handle, broker} = Chan.newchan(scope, 0)
        send(parent, {:created, handle, broker})
        exit(:creator_crash)
      end)

    creator_ref = Process.monitor(creator)
    assert_receive {:created, handle, broker}, 1_000
    assert_receive {:DOWN, ^creator_ref, :process, ^creator, :creator_crash}, 1_000

    broker_ref = Process.monitor(broker)
    refute_receive {:DOWN, ^broker_ref, :process, ^broker, _}, 100
    assert Chan.resolve(scope, handle) == broker

    Chan.close_scope(scope)
    assert_receive {:DOWN, ^broker_ref, :process, ^broker, _}, 1_000
    assert Chan.resolve(scope, handle) == nil
  end

  test "fork_scope carries aliases and fresh child channels do not collide" do
    old_scope = {:old_scope, make_ref()}
    new_scope = {:new_scope, make_ref()}

    on_exit(fn ->
      Chan.close_scope(old_scope)
      Chan.close_scope(new_scope)
    end)

    {inherited, inherited_broker} = Chan.newchan(old_scope, 0)
    Chan.fork_scope(new_scope, old_scope)

    assert Chan.resolve(new_scope, inherited) == inherited_broker
    {fresh, fresh_broker} = Chan.newchan(new_scope, 0)
    refute fresh == inherited

    parent = self()

    child =
      spawn(fn ->
        put_scope(new_scope)
        send(parent, {:child_send, Chan.csend(inherited, :from_child)})
      end)

    assert Chan.crecv(inherited_broker) == :from_child
    assert_receive {:child_send, ^inherited}, 500
    assert_process_down(child)

    inherited_ref = Process.monitor(inherited_broker)
    fresh_ref = Process.monitor(fresh_broker)
    Chan.close_scope(old_scope)
    refute_receive {:DOWN, ^inherited_ref, :process, ^inherited_broker, _}, 100

    Chan.close_scope(new_scope)
    assert_receive {:DOWN, ^inherited_ref, :process, ^inherited_broker, _}, 1_000
    assert_receive {:DOWN, ^fresh_ref, :process, ^fresh_broker, _}, 1_000
  end

  test "handle_free payload skips handle walking across scopes" do
    sender_scope = {:sender_scope, make_ref()}
    receiver_scope = {:receiver_scope, make_ref()}
    {stream, stream_broker} = Chan.newchan(sender_scope, 1, :handle_free)
    {private, private_broker} = Chan.newchan(sender_scope, 0)

    on_exit(fn ->
      Chan.close_broker(stream_broker)
      Chan.close_broker(private_broker)
      Chan.close_scope(sender_scope)
      Chan.close_scope(receiver_scope)
    end)

    assert Chan.handle_for(receiver_scope, stream_broker) == stream

    put_scope(sender_scope)
    assert Chan.csend(stream, {:private, private}) == stream

    put_scope(receiver_scope)
    assert Chan.crecv(stream) == {:private, private}
    assert Chan.resolve(receiver_scope, private) == nil
  end

  test "may_contain_handles retags known handles and aliases on cross-scope receive" do
    sender_scope = {:sender_scope, make_ref()}
    receiver_scope = {:receiver_scope, make_ref()}
    {stream, stream_broker} = Chan.newchan(sender_scope, 1, :may_contain_handles)
    {reply, reply_broker} = Chan.newchan(sender_scope, 0, :handle_free)

    on_exit(fn ->
      Chan.close_broker(stream_broker)
      Chan.close_broker(reply_broker)
      Chan.close_scope(sender_scope)
      Chan.close_scope(receiver_scope)
    end)

    assert Chan.handle_for(receiver_scope, stream_broker) == stream

    put_scope(sender_scope)
    assert Chan.csend(stream, {:reply, [reply]}) == stream

    put_scope(receiver_scope)
    assert Chan.crecv(stream) == {:reply, [reply]}
    assert Chan.resolve(receiver_scope, reply) == reply_broker

    parent = self()

    ack_sender =
      spawn(fn ->
        put_scope(receiver_scope)
        send(parent, {:ack_sent, Chan.csend(reply, :ack)})
      end)

    put_scope(sender_scope)
    assert Chan.crecv(reply) == :ack
    assert_receive {:ack_sent, ^reply}, 500
    assert_process_down(ack_sender)
  end

  test "ordinary integers are not promoted into handles", %{scope: scope} do
    receiver_scope = {:receiver_scope, make_ref()}
    {stream, stream_broker} = Chan.newchan(scope, 1, :may_contain_handles)
    {private, private_broker} = Chan.newchan(scope, 0)

    on_exit(fn ->
      Chan.close_broker(stream_broker)
      Chan.close_broker(private_broker)
      Chan.close_scope(receiver_scope)
    end)

    assert Chan.handle_for(receiver_scope, stream_broker) == stream
    parent = self()

    sender =
      spawn(fn ->
        put_scope(scope)
        Process.delete(@known_handles_key)
        send(parent, {:plain_int_sent, Chan.csend(stream, private)})
      end)

    assert_receive {:plain_int_sent, ^stream}, 1_000
    assert_process_down(sender)

    put_scope(receiver_scope)
    assert Chan.crecv(stream) == private
    assert Chan.resolve(receiver_scope, private) == nil
  end

  test "startchan is a negative one-shot send-then-recv rendezvous" do
    handle = Chan.new_startchan()
    assert is_integer(handle)
    assert handle < 0
    parent = self()

    sender =
      spawn(fn ->
        send(parent, {:startchan_send, Chan.csend(handle, {:pid, self()})})
      end)

    assert {:pid, sender_pid} = Chan.crecv(handle)
    assert is_pid(sender_pid)
    assert_receive {:startchan_send, ^handle}, 500
    assert_process_down(sender)

    assert Chan.crecv(handle) == {:error, :badchan}
    assert Chan.csend(handle, :again) == {:error, :badchan}
  end

  test "the startchan table outlives the process that minted the first startchan" do
    parent = self()

    minter =
      spawn(fn ->
        send(parent, {:minted, Chan.new_startchan()})
      end)

    assert_receive {:minted, first}, 500
    assert is_integer(first)
    assert_process_down(minter)

    assert :ets.whereis(:hyperlang_startchans) != :undefined
    second = Chan.new_startchan()
    assert is_integer(second) and second < 0

    sender = spawn(fn -> send(parent, {:sent, Chan.csend(second, :ping)}) end)
    assert Chan.crecv(second) == :ping
    assert_receive {:sent, ^second}, 500
    assert_process_down(sender)
  end

  test "retype close hook fires and link_fileio_pair tears down peer on owner death" do
    read = Chan.cnewc(:read, Chan.movtmp(), 0)
    write = Chan.cnewc(:write, Chan.movtmp(), 0)
    Chan.retype(read, {Hook, :close, {self(), :read}})
    Chan.retype(write, {Hook, :close, {self(), :write}})
    Chan.link_fileio_pair(read, write)

    owner =
      spawn(fn ->
        Chan.crecv(read)
      end)

    try do
      eventually(fn -> :sys.get_state(read).owner == owner end)

      read_ref = Process.monitor(read)
      write_ref = Process.monitor(write)
      Process.exit(owner, :kill)

      assert_receive {:DOWN, ^read_ref, :process, ^read, _}, 1_000
      assert_receive {:DOWN, ^write_ref, :process, ^write, _}, 1_000
      assert_receive {:fileio_closed, :read, 0}, 1_000
      assert_receive {:fileio_closed, :write, 0}, 1_000
    after
      Chan.close_broker(read)
      Chan.close_broker(write)
    end
  end

  test "csendalt grows past size without parking and drains FIFO" do
    c = Chan.cnewc(:test, Chan.movtmp(), 1)

    try do
      assert Chan.csendalt(c, :a, -1) == 1
      assert Chan.csendalt(c, :b, -1) == 1
      assert Chan.csendalt(c, :c, -1) == 1

      assert Chan.crecv(c) == :a
      assert Chan.crecv(c) == :b
      assert Chan.crecv(c) == :c
    after
      Chan.close_broker(c)
    end
  end

  test "retype close hook fires on explicit close_broker" do
    c = Chan.cnewc(:test, Chan.movtmp(), 0)
    Chan.retype(c, {Hook, :close, {self(), :single}})

    Chan.close_broker(c)

    assert_receive {:fileio_closed, :single, 0}, 1_000
  end

  test "freeing a shared alias preserves its peer and retirement fires its hook once", %{
    scope: scope
  } do
    other = make_ref()
    :ok = Hyperlang.Scope.configure(other, %{})
    {handle, broker} = Chan.newchan(scope, 1)
    Chan.retype(broker, {Hook, :close, {self(), :retired}})
    :ok = Chan.fork_scope(other, scope)
    :ok = Chan.freechan(scope, handle, broker)
    assert Chan.resolve(scope, handle) == nil
    assert Chan.resolve(other, handle) == broker
    refute_receive {:fileio_closed, :retired, _}, 20
    :ok = Chan.freechan(other, handle, broker)
    assert_receive {:fileio_closed, :retired, 0}, 1000
    refute_receive {:fileio_closed, :retired, _}, 20
    Hyperlang.Scope.close(other)
  end

  test "retirement releases this scope's suspension hold", %{scope: scope} do
    {handle, broker} = Chan.newchan(scope, 1)
    Chan.retype(broker, {Hook, :close, {self(), :suspended_retirement}})
    monitor = Process.monitor(broker)

    controller = Hyperlang.Scope.Channels.address(scope)

    :sys.replace_state(controller, fn state ->
      :erlang.suspend_process(broker)
      put_in(state, [:members, broker, :suspended?], true)
    end)

    Chan.freechan(scope, handle, broker)
    assert_receive {:fileio_closed, :suspended_retirement, 0}, 1000
    assert_receive {:DOWN, ^monitor, :process, ^broker, :normal}, 1000
  end

  test "scope-owner death retires brokers with their close hooks" do
    parent = self()

    {owner, owner_ref} =
      spawn_monitor(fn ->
        scope = make_ref()
        :ok = Hyperlang.Scope.configure(scope, %{})
        {_handle, broker} = Chan.newchan(scope, 1)
        Chan.retype(broker, {Hook, :close, {parent, :scope_death}})
        send(parent, {:scope_broker, broker})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:scope_broker, broker}
    monitor = Process.monitor(broker)
    send(owner, :stop)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    assert_receive {:fileio_closed, :scope_death, 0}, 1000
    assert_receive {:DOWN, ^monitor, :process, ^broker, :normal}, 1000
  end

  defp scoped_sender(scope, handle, value, id) do
    parent = self()

    spawn(fn ->
      put_scope(scope)
      send(parent, {:sender_done, id, Chan.csend(handle, value)})
    end)
  end

  defp put_scope(scope) do
    Process.put(@proc_scope_key, scope)
    :ok
  end

  defp assert_process_down(pid, reason \\ :normal) do
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, actual_reason}
                   when actual_reason in [reason, :noproc],
                   500
  end

  defp eventually(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition did not become true before timeout")
      else
        Process.sleep(10)
        do_eventually(fun, deadline)
      end
    end
  end
end
