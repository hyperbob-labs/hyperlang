defmodule Hyperlang.Actor do
  @moduledoc """
  The `GenServer` callback module that runs a program's OTP callbacks.

  Start an actor with the program value itself:

      GenServer.start(Hyperlang.Actor, {spec, program, arg})
      GenServer.start_link(Hyperlang.Actor, {spec, program, arg}, name: MyActor)

  `spec` is the `Hyperlang.run/4` spec (`%{bindings: ..., policy: ...,
  syscall: ...}`), and every callback runs under it. `arg` is the guest
  `init/1` argument. The program must export `init/1`; `handle_call/3`,
  `handle_cast/2`, `handle_info/2`, `handle_continue/2`, `terminate/2` and
  `code_change/3` are used when exported. As OTP does for a callback module
  without them, an actor drops a message when the program has no
  `handle_info/2` and runs nothing on exit when it has no `terminate/2`. A
  missing required callback stops the actor with the typed `run/4` error
  (`category: :export`). Guest stdout from callbacks is dropped.

  ## The actor runs exactly its program

  The actor's `init/1` loads `program` and pins its code slot in one step, so
  a release or code-pool pressure before `init/1` cannot leave the actor
  without code or with another program's code. The pin holds until the
  actor exits. It is charged to the actor's scope (`spec.policy.scope`, else
  the actor's own default scope), which may pin at most `max_code_pins`
  distinct slots. `Hyperlang.load/1` loads a program ahead of time; it is
  optional.

  ## Limits

  Every callback is one `Hyperlang.run/4` in the actor process, so the
  per-callback policy limits (`wall_ms`, `max_reductions`/`budget`,
  `heap_words`) apply to each callback. The actor-lifetime limits (`rate`,
  `ceiling`) hold for the actor's whole life, with no host wiring.

  ## Errors

  `GenServer.start/3` returns `{:error, {:hyperlang, error}}` when `init/1`
  stops:

    * `category: :api` when the init argument is not
      `{spec_map, %Hyperlang.Program{}, arg}`;
    * `category: :code_pool` with `details.reason: :pin_limit` at the scope
      bound, or `category: :code_pool` when no slot of the program's
      `code_pool` window is free;
    * the error of the guest `init/1`.

  ## Supervision

  `child_spec/1` takes the same `{spec, program, arg}` tuple:

      children = [{Hyperlang.Actor, {spec, program, arg}}]

  The child id is `Hyperlang.Actor` and the restart is `:permanent`, as for
  any `GenServer`. Supervise more than one actor under one supervisor by
  giving each its own id:

      Supervisor.child_spec({Hyperlang.Actor, {spec, program, arg}}, id: {:counter, 1})

  A restarted actor runs `init/1` again with the same program, so it pins
  and, if needed, loads the program again.
  """

  use GenServer

  defmodule State do
    @moduledoc false
    defstruct [:program, :spec, :guest, private: []]
  end

  @actor_limit_keys [:rate, :ceiling]

  @doc """
  A child specification that starts the actor with
  `GenServer.start_link(Hyperlang.Actor, {spec, program, arg})`.
  """
  @spec child_spec({map(), Hyperlang.Program.t(), term()}) :: Supervisor.child_spec()
  def child_spec(init_arg) do
    %{
      id: __MODULE__,
      start: {GenServer, :start_link, [__MODULE__, init_arg]},
      restart: :permanent
    }
  end

  # `init` loads the program and pins its slot in one
  # `Hyperlang.CodeServer.pin/2` call: no release or reclamation can come
  # between the two. The pinned slot's literal replaces the caller's value,
  # so the actor's state never holds a heap copy of the program.
  @impl true
  def init(
        {%{} = spec, %Hyperlang.Program{content_hash: hash, artifact: %{}} = program, guest_arg}
      )
      when is_binary(hash) do
    with {:ok, program} <- Hyperlang.CodeServer.pin(program, actor_scope(spec)),
         {:ok, spec} <- attach_actor_limits(spec),
         {:ok, result, private} <- invoke(spec, program, "init/1", [guest_arg]) do
      put_private(wrap_init(result, program, spec), private)
    else
      {:error, reason} -> {:stop, {:hyperlang, reason}}
    end
  end

  def init(_init_arg),
    do:
      {:stop,
       {:hyperlang, Hyperlang.Terms.sanitize_error(%{category: :api, reason: :bad_actor_init})}}

  @impl true
  def handle_call(request, from, state), do: dispatch(:handle_call, [request, from, state])

  @impl true
  def handle_cast(request, state), do: dispatch(:handle_cast, [request, state])

  @impl true
  def handle_info(message, %State{program: program} = state) do
    if exports?(program, "handle_info/2"),
      do: dispatch(:handle_info, [message, state]),
      else: {:noreply, state}
  end

  def handle_info(_message, state), do: {:stop, {:hyperlang, :invalid_callback_state}, state}

  @impl true
  def handle_continue(continue, state), do: dispatch(:handle_continue, [continue, state])

  @impl true
  def terminate(reason, %State{program: program} = state) do
    if exports?(program, "terminate/2"), do: dispatch(:terminate, [reason, state]), else: :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def code_change(old, state, extra), do: dispatch(:code_change, [old, state, extra])

  # Never send the OTP status map (which can contain program artifacts, the
  # process dictionary, host spec or policy) through the guest term boundary.
  # The host formatter owns redaction on every success and failure path.
  @impl true
  def format_status(%{} = status) do
    Map.new(status, fn
      {:state, _} -> {:state, :redacted}
      {:reason, reason} -> {:reason, safe_status_reason(reason)}
      {key, _} -> {key, :redacted}
    end)
  end

  defp dispatch(function, args) do
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

  defp exports?(
         %Hyperlang.Program{artifact: %{manifest: %{exports: %{functions: functions}}}},
         id
       ),
       do: Map.has_key?(functions, id)

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
