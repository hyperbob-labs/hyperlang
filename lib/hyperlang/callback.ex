defmodule Hyperlang.Callback do
  @moduledoc false

  # The OTP callback shell behind `Hyperlang.module/1`. `init` pins the code
  # slot the callback module names (`Hyperlang.CodeServer.pin/2`), so the
  # module and the program literal the actor references stay loaded until the
  # actor exits. Every callback is one
  # `Hyperlang.run/4` in the actor process (`run_in_caller?: true`), so the
  # per-callback policy limits (`wall_ms`, `max_reductions`/`budget`,
  # `heap_words`) apply to each callback. The actor-lifetime limits
  # (`rate`, `ceiling`) are owned by one `Hyperlang.Limits` group that `init`
  # creates from `spec.policy` and attaches to the actor process, so the host
  # never wires limits by hand. Guest stdout from callbacks is dropped: an
  # OTP callback return has no slot for it.

  defmodule State do
    @moduledoc false
    defstruct [:program, :spec, :guest, private: []]
  end

  @actor_limit_keys [:rate, :ceiling]

  # Never send the OTP status map (which can contain program artifacts, the
  # process dictionary, host spec or policy) through the guest term boundary.
  # The host formatter owns redaction on every success and failure path.
  def dispatch(_module, :format_status, [%{} = status]) do
    Map.new(status, fn
      {:state, _} -> {:state, :redacted}
      {:reason, reason} -> {:reason, safe_status_reason(reason)}
      {key, _} -> {key, :redacted}
    end)
  end

  def dispatch(module, :init, [init_arg]) do
    with {:ok, spec, guest_arg} <- init_authority(init_arg),
         {:ok, program} <- Hyperlang.CodeServer.pin(module, actor_scope(spec)),
         {:ok, spec} <- attach_actor_limits(spec),
         {:ok, result, private} <- invoke(spec, program, "init/1", [guest_arg]) do
      put_private(wrap_init(result, program, spec), private)
    else
      {:error, reason} -> {:stop, {:hyperlang, reason}}
    end
  end

  def dispatch(_module, function, args) do
    case split_state(function, args) do
      {:ok, %State{} = state, guest_args} ->
        case invoke(
               state.spec,
               state.program,
               export_id(function, length(guest_args)),
               guest_args,
               state.private
             ) do
          {:ok, result, private} -> wrap_reply(function, result, %{state | private: private})
          {:error, reason} -> {:stop, {:hyperlang, reason}, state}
        end

      :error ->
        {:stop, {:hyperlang, :invalid_callback_state}}
    end
  end

  defp init_authority({%{} = spec, guest_arg}), do: {:ok, spec, guest_arg}

  defp init_authority(%{spec: %{} = spec, args: guest_arg}),
    do: {:ok, spec, guest_arg}

  defp init_authority(_init_arg), do: {:error, :missing_spec}

  # The actor's code slot is pinned for the actor's life and charged to the
  # scope its callbacks run under (the scope `Hyperlang.run/4` selects).
  defp actor_scope(spec) do
    case Map.get(spec, :policy) do
      %{scope: scope} when not is_nil(scope) -> scope
      _policy -> Hyperlang.Scope.current()
    end
  end

  # Move the actor-lifetime limits out of the per-callback policy into one
  # group the actor process belongs to for its whole life. The group is
  # owned by the actor: the limits service drops it when the actor exits.
  # An actor without either limit needs no group.
  defp attach_actor_limits(spec) do
    case Map.get(spec, :policy, %{}) do
      %{} = policy ->
        actor_limits = Map.take(policy, @actor_limit_keys)
        spec = Map.put(spec, :policy, Map.drop(policy, @actor_limit_keys))

        if Enum.all?(Map.values(actor_limits), &is_nil/1) do
          {:ok, spec}
        else
          group = Hyperlang.Limits.group(actor_limits)

          case Hyperlang.Limits.attach(group, self(), %{owner?: true}) do
            :ok -> {:ok, spec}
            {:error, reason} -> {:error, reason}
          end
        end

      _other ->
        {:error, :invalid_policy}
    end
  end

  defp invoke(spec, program, export, args, private \\ []) do
    spec =
      Map.update(spec, :policy, %{run_in_caller?: true}, fn policy ->
        Map.put(policy, :run_in_caller?, true)
      end)

    {reply, private} =
      with_private_dictionary(private, fn ->
        Hyperlang.Worker.with_owned_actor(fn -> Hyperlang.run(spec, program, export, args) end)
      end)

    case reply do
      {:ok, result, _meta} -> {:ok, result, private}
      {:error, error} -> {:error, error}
    end
  end

  defp put_private({:ok, %State{} = state}, private), do: {:ok, %{state | private: private}}

  defp put_private({:ok, %State{} = state, action}, private),
    do: {:ok, %{state | private: private}, action}

  defp put_private(result, _), do: result

  # OTP sys:get_status includes the raw process dictionary outside the user
  # formatter. Keep guest dictionaries and library contexts in the redacted
  # actor state between callbacks, never in that operational status surface.
  defp with_private_dictionary(private, fun) do
    previous = private_dictionary()
    clear_private_dictionary()
    Enum.each(private, fn {key, value} -> Process.put(key, value) end)

    try do
      {fun.(), private_dictionary()}
    after
      clear_private_dictionary()
      Enum.each(previous, fn {key, value} -> Process.put(key, value) end)
    end
  end

  defp private_dictionary, do: Enum.filter(Process.get(), fn {key, _} -> private_key?(key) end)

  defp clear_private_dictionary,
    do: Enum.each(private_dictionary(), fn {key, _} -> Process.delete(key) end)

  defp private_key?(key) when is_atom(key) do
    name = Atom.to_string(key)
    String.starts_with?(name, "$hyperlang") or String.starts_with?(name, "hyperlang_")
  end

  defp private_key?(key) when is_tuple(key) and tuple_size(key) > 0 do
    head = elem(key, 0)

    private_key?(head) or
      (is_atom(head) and
         (head == Hyperlang or String.starts_with?(Atom.to_string(head), "Elixir.Hyperlang.")))
  end

  defp private_key?(_), do: false

  defp split_state(:handle_call, [request, _from, %State{} = state]),
    do: {:ok, state, [request, nil, state.guest]}

  defp split_state(_function, [arg, %State{} = state]),
    do: {:ok, state, [arg, state.guest]}

  defp split_state(:code_change, [old, %State{} = state, extra]),
    do: {:ok, state, [old, state.guest, extra]}

  defp split_state(_function, _args), do: :error

  defp wrap_init({:ok, guest}, program, spec),
    do: {:ok, %State{program: program, spec: spec, guest: guest}}

  defp wrap_init({"ok", guest}, program, spec),
    do: {:ok, %State{program: program, spec: spec, guest: guest}}

  defp wrap_init({:ok, guest, action}, program, spec),
    do: {:ok, %State{program: program, spec: spec, guest: guest}, action}

  defp wrap_init({"ok", guest, action}, program, spec),
    do: {:ok, %State{program: program, spec: spec, guest: guest}, action}

  defp wrap_init(:ignore, _program, _spec), do: :ignore
  defp wrap_init("ignore", _program, _spec), do: :ignore
  defp wrap_init({:stop, reason}, _program, _spec), do: {:stop, reason}
  defp wrap_init({"stop", reason}, _program, _spec), do: {:stop, reason}
  defp wrap_init(other, _program, _spec), do: {:stop, {:bad_callback_return, other}}

  defp wrap_reply(:handle_call, {:reply, reply, guest}, state),
    do: {:reply, reply, put_guest(state, guest)}

  defp wrap_reply(:handle_call, {"reply", reply, guest}, state),
    do: {:reply, reply, put_guest(state, guest)}

  defp wrap_reply(:handle_call, {:reply, reply, guest, action}, state),
    do: {:reply, reply, put_guest(state, guest), action}

  defp wrap_reply(:handle_call, {"reply", reply, guest, action}, state),
    do: {:reply, reply, put_guest(state, guest), action}

  defp wrap_reply(:handle_call, {:noreply, guest}, state),
    do: {:noreply, put_guest(state, guest)}

  defp wrap_reply(:handle_call, {"noreply", guest}, state),
    do: {:noreply, put_guest(state, guest)}

  defp wrap_reply(:handle_call, {:noreply, guest, action}, state),
    do: {:noreply, put_guest(state, guest), action}

  defp wrap_reply(:handle_call, {"noreply", guest, action}, state),
    do: {:noreply, put_guest(state, guest), action}

  defp wrap_reply(_function, {:noreply, guest}, state),
    do: {:noreply, put_guest(state, guest)}

  defp wrap_reply(_function, {"noreply", guest}, state),
    do: {:noreply, put_guest(state, guest)}

  defp wrap_reply(_function, {:noreply, guest, action}, state),
    do: {:noreply, put_guest(state, guest), action}

  defp wrap_reply(_function, {"noreply", guest, action}, state),
    do: {:noreply, put_guest(state, guest), action}

  defp wrap_reply(:code_change, {:ok, guest}, state), do: {:ok, put_guest(state, guest)}
  defp wrap_reply(:terminate, result, _state), do: result

  defp wrap_reply(_function, {:stop, reason, guest}, state),
    do: {:stop, reason, put_guest(state, guest)}

  defp wrap_reply(_function, {"stop", reason, guest}, state),
    do: {:stop, reason, put_guest(state, guest)}

  defp wrap_reply(:handle_call, {:stop, reason, reply, guest}, state),
    do: {:stop, reason, reply, put_guest(state, guest)}

  defp wrap_reply(:handle_call, {"stop", reason, reply, guest}, state),
    do: {:stop, reason, reply, put_guest(state, guest)}

  defp wrap_reply(_function, other, state),
    do: {:stop, {:bad_callback_return, other}, state}

  defp put_guest(state, guest), do: %{state | guest: guest}
  defp export_id(function, arity), do: Atom.to_string(function) <> "/" <> Integer.to_string(arity)

  defp safe_status_reason({:hyperlang, %{category: category}}), do: {:hyperlang, category}
  defp safe_status_reason(reason) when reason in [:normal, :shutdown], do: reason
  defp safe_status_reason(_), do: :redacted
end
