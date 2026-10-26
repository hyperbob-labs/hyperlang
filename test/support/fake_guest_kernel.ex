defmodule Hyperlang.FakeGuestKernel do
  @moduledoc false

  # A host-side fake of the guest kernel process hooks (spawn, resolve, names,
  # monitors, links, exit signals). `install/0` replaces the hooks and returns a
  # function that restores the previous application env.

  @unset {__MODULE__, :unset}

  def install do
    previous =
      Map.new(
        [
          :guest_spawn_hook,
          :guest_msg_resolver,
          :guest_name_hook,
          :guest_monitor_hook,
          :guest_link_hook
        ],
        &{&1, Application.get_env(:hyperlang, &1, @unset)}
      )

    {:ok, agent} =
      Agent.start(fn ->
        %{
          next_carrier: 20_000,
          next_ref: 2_000_000,
          carriers: %{},
          names: %{},
          refs: %{},
          links: %{}
        }
      end)

    ExUnit.Callbacks.on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    Application.put_env(:hyperlang, :guest_spawn_hook, fn fun, ctx ->
      {carrier, child} =
        Agent.get_and_update(agent, fn state ->
          carrier = state.next_carrier

          child =
            Kernel.spawn(fn ->
              :hyperlang_msg.with_context(ctx, fun)
            end)

          {{carrier, child},
           %{state | next_carrier: carrier + 1, carriers: Map.put(state.carriers, carrier, child)}}
        end)

      {:ok, carrier, %{pid: child}}
    end)

    Application.put_env(:hyperlang, :guest_msg_resolver, fn target, _ctx ->
      case fake_kernel_resolve(agent, target) do
        pid when is_pid(pid) -> {:ok, pid}
        nil -> {:error, :noproc}
      end
    end)

    Application.put_env(:hyperlang, :guest_name_hook, fn
      :register, {name, carrier} when is_binary(name) and is_integer(carrier) ->
        Agent.get_and_update(agent, fn state ->
          existing = Map.get(state.names, name)
          existing_pid = Map.get(state.carriers, existing)

          if is_pid(existing_pid) and Process.alive?(existing_pid) do
            {{:error, :name_taken}, state}
          else
            {{:ok, true}, %{state | names: Map.put(state.names, name, carrier)}}
          end
        end)

      :whereis, name when is_binary(name) ->
        Agent.get_and_update(agent, fn state ->
          carrier = Map.get(state.names, name)
          pid = Map.get(state.carriers, carrier)

          if is_integer(carrier) and is_pid(pid) and Process.alive?(pid) do
            {{:ok, carrier}, state}
          else
            {{:ok, :undefined}, %{state | names: Map.delete(state.names, name)}}
          end
        end)

      :unregister, name when is_binary(name) ->
        Agent.update(agent, fn state -> %{state | names: Map.delete(state.names, name)} end)
        {:ok, true}
    end)

    Application.put_env(:hyperlang, :guest_monitor_hook, fn
      :make_ref, nil ->
        Agent.get_and_update(agent, fn state ->
          {{:ok, state.next_ref}, %{state | next_ref: state.next_ref + 1}}
        end)

      :alive?, target ->
        {:ok,
         case fake_kernel_resolve(agent, target) do
           pid when is_pid(pid) -> Process.alive?(pid)
           _ -> false
         end}

      :monitor, target ->
        owner = self()

        {ref, target_pid} =
          Agent.get_and_update(agent, fn state ->
            ref = state.next_ref
            carrier = if is_binary(target), do: Map.get(state.names, target), else: target
            target_pid = Map.get(state.carriers, carrier)
            {{ref, target_pid}, %{state | next_ref: ref + 1}}
          end)

        watcher =
          case target_pid do
            pid when is_pid(pid) ->
              Kernel.spawn(fn ->
                monitor = Process.monitor(pid)

                receive do
                  {:DOWN, ^monitor, :process, ^pid, reason} ->
                    Kernel.send(
                      owner,
                      {:"$hyperlang_msg", :kernel,
                       {:DOWN, ref, :process, target, down_cause(reason)}}
                    )

                  :cancel ->
                    Process.demonitor(monitor, [:flush])
                end
              end)

            nil ->
              Kernel.send(
                owner,
                {:"$hyperlang_msg", :kernel, {:DOWN, ref, :process, target, <<"noproc">>}}
              )

              nil
          end

        Agent.update(agent, fn state ->
          %{state | refs: Map.put(state.refs, ref, %{owner: owner, watcher: watcher})}
        end)

        {:ok, ref}

      :demonitor, ref ->
        Agent.get_and_update(agent, fn state ->
          {entry, refs} = Map.pop(state.refs, ref)
          {{entry, :ok}, %{state | refs: refs}}
        end)
        |> case do
          {nil, :ok} -> :ok
          {%{watcher: watcher}, :ok} when is_pid(watcher) -> Kernel.send(watcher, :cancel)
          {%{watcher: nil}, :ok} -> :ok
        end

        {:ok, true}
    end)

    Application.put_env(:hyperlang, :guest_link_hook, fn
      :link, target ->
        owner = self()

        Agent.update(agent, fn state ->
          {caller, state} = fake_kernel_ensure_carrier(state, owner)

          links =
            state.links
            |> Map.update(caller, MapSet.new([target]), &MapSet.put(&1, target))
            |> Map.update(target, MapSet.new([caller]), &MapSet.put(&1, caller))

          %{state | links: links}
        end)

        if pid = fake_kernel_resolve(agent, target) do
          Kernel.spawn(fn ->
            ref = Process.monitor(pid)

            receive do
              {:DOWN, ^ref, :process, ^pid, reason} ->
                Kernel.send(
                  owner,
                  {:"$hyperlang_msg", :kernel, {:EXIT, target, down_cause(reason)}}
                )
            end
          end)
        end

        {:ok, true}

      :unlink, target ->
        owner = self()

        Agent.update(agent, fn state ->
          case Enum.find(state.carriers, fn {_carrier, pid} -> pid == owner end) do
            {caller, _pid} ->
              links =
                state.links
                |> Map.update(caller, MapSet.new(), &MapSet.delete(&1, target))
                |> Map.update(target, MapSet.new(), &MapSet.delete(&1, caller))

              %{state | links: links}

            nil ->
              state
          end
        end)

        {:ok, true}

      :exit_signal, {target, reason} ->
        case fake_kernel_resolve(agent, target) do
          pid when is_pid(pid) -> Process.exit(pid, if(reason == :kill, do: :kill, else: reason))
          nil -> :ok
        end

        {:ok, true}

      :trap_exit, bool ->
        previous = Process.get(:fake_guest_trap_exit, false)
        Process.put(:fake_guest_trap_exit, bool)
        {:ok, previous}

      :links, nil ->
        owner = self()

        {:ok,
         Agent.get(agent, fn state ->
           case Enum.find(state.carriers, fn {_carrier, pid} -> pid == owner end) do
             {caller, _pid} -> state.links |> Map.get(caller, MapSet.new()) |> MapSet.to_list()
             nil -> []
           end
         end)}
    end)

    fn ->
      Enum.each(previous, fn
        {key, @unset} -> Application.delete_env(:hyperlang, key)
        {key, value} -> Application.put_env(:hyperlang, key, value)
      end)
    end
  end

  defp fake_kernel_ensure_carrier(state, pid) do
    case Enum.find(state.carriers, fn {_carrier, existing} -> existing == pid end) do
      {carrier, ^pid} ->
        {carrier, state}

      nil ->
        carrier = state.next_carrier

        {carrier,
         %{
           state
           | next_carrier: carrier + 1,
             carriers: Map.put(state.carriers, carrier, pid)
         }}
    end
  end

  defp fake_kernel_resolve(agent, target) when is_integer(target) do
    Agent.get(agent, fn state ->
      # Match the real kernel resolver: monitor-ref carriers are never message
      # targets. Integers resolve only through the process-carrier namespace.
      Map.get(state.carriers, target)
    end)
  end

  defp fake_kernel_resolve(agent, target) when is_binary(target) do
    Agent.get(agent, fn state ->
      with carrier when is_integer(carrier) <- Map.get(state.names, target),
           pid when is_pid(pid) <- Map.get(state.carriers, carrier) do
        pid
      else
        _ -> nil
      end
    end)
  end

  defp fake_kernel_resolve(_agent, _target), do: nil

  defp down_cause(reason) when is_binary(reason), do: reason
  defp down_cause(reason) when is_atom(reason), do: reason |> Atom.to_string() |> then(& &1)
  defp down_cause(reason), do: inspect(reason)
end
