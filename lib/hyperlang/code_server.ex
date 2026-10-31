defmodule Hyperlang.CodeServer do
  @moduledoc false

  use GenServer

  @default_size 128
  # Sanity ceiling the `:code_pool_size` config may raise the pool to. Slots are
  # reclaimed (see reclaim/3), so the ceiling is no longer a workaround for a
  # leaking pool — it only bounds how many generated module names one VM may
  # mint. Hosts that keep thousands of artifacts resident configure
  # `config :hyperlang, code_pool_size: N`.
  @max_size 65536
  @compile_options [
    :binary,
    :return_errors,
    :return_warnings,
    :deterministic,
    :no_docs,
    :no_auto_import,
    :no_spawn_compiler_process,
    # `sys_core_alias` names its pattern aliases `@rN` from a per-function
    # counter; generated code keeps the compiler's name set fixed.
    :no_alias
  ]
  # Candidate victims examined on one exhausted load before the pool is
  # declared full. A victim still running guest code is skipped, so the cap
  # bounds the work a fully non-quiescent pool can force per miss.
  @reclaim_attempts 8
  @compile_options_hash_key {__MODULE__, :compile_options_hash}
  @loaded_artifact_key {__MODULE__, :loaded_artifact}
  @slot_versions :hyperlang_code_slot_versions
  @pin_table :hyperlang_code_pins

  # A loaded artifact. `program` is the canonical program value for the
  # content hash, stored once as a `:persistent_term` literal: every run and
  # every actor of the program references it without copying it onto its
  # heap. Its lifetime is the slot's: reclamation erases the record.
  #
  # A live OTP actor (`Hyperlang.Actor`) loads and pins its program's slot
  # in one server call (`pin/2`), so the pinned slot holds exactly the
  # program the actor was started with. A pinned slot is never reclaimed or
  # released, so the actor's generated module and its program literal stay
  # loaded for the actor's whole life, and the literal is never copied onto
  # its heap. A `release/1` of a pinned slot takes effect when the last pin
  # goes. Pins are charged to the actor's scope: one scope pins at most
  # `max_code_pins` distinct slots (a `Hyperlang.Scope` policy key). The pins
  # of a process go when it exits.
  defmodule Slot do
    @moduledoc false
    defstruct [:id, :module, :version, :program]
  end

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc false
  def valid_slot?(module, version) do
    :ets.lookup(@slot_versions, module) == [{module, version}]
  rescue
    ArgumentError -> false
  end

  # One pool, one identity: dedup is keyed on content identity alone. Two
  # artifacts with the same content hash are the same loaded module no matter
  # who loads them (a program entry, a verified library binding). The returned
  # slot carries the canonical program literal; callers use it in place of
  # their own heap copy.
  def load(%Hyperlang.Program{content_hash: content_hash} = program)
      when is_binary(content_hash) do
    case :persistent_term.get({@loaded_artifact_key, content_hash}, nil) do
      %Slot{module: module} = slot ->
        if :code.is_loaded(module) == false do
          load_slow(program)
        else
          {:ok, slot}
        end

      nil ->
        load_slow(program)
    end
  end

  defp load_slow(program) do
    ensure_started()
    GenServer.call(__MODULE__, {:load, program, Hyperlang.Scope.current()}, :infinity)
  end

  # Release an artifact's slot back to the pool. The caller states that the
  # artifact is no longer wanted (cache eviction); whether the slot can be
  # reused right now is decided by the same quiescence gate reclamation uses.
  def release(content_hash) when is_binary(content_hash) do
    ensure_started()
    GenServer.call(__MODULE__, {:release, content_hash}, :infinity)
  end

  # Load `program` if needed and pin its slot for the calling process,
  # charged to `scope`; return the slot's program literal. The pin holds
  # until the process exits.
  def pin(%Hyperlang.Program{content_hash: content_hash} = program, scope)
      when is_binary(content_hash) do
    ensure_started()
    GenServer.call(__MODULE__, {:pin, program, self(), scope}, :infinity)
  end

  # Owned by the application, so pins survive a restart of this server.
  def create_pin_table do
    :ets.new(@pin_table, [:named_table, :public, :set])
  end

  def code_pool_size do
    Application.get_env(:hyperlang, :code_pool_size, @default_size)
    |> min(@max_size)
    |> max(1)
  end

  def compile_options_hash do
    # Keyed by the CURRENT option data, not one global slot: changing
    # code_pool_size via app env must change the artifact
    # identity (the Modload alias-follows-identity invariant). Unchanged
    # option sets still hit one persistent_term read; the SHA is paid once
    # per distinct option set.
    data = compile_options_hash_data()

    case :persistent_term.get({@compile_options_hash_key, data}, nil) do
      nil -> put_compile_options_hash!(data)
      hash -> hash
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@slot_versions, [:named_table, :protected, :set, read_concurrency: true])
    put_compile_options_hash!(compile_options_hash_data())

    slots =
      1..code_pool_size()
      |> Enum.map(fn id ->
        module = :"hyperlang_slot_#{String.pad_leading(Integer.to_string(id), 6, "0")}"

        {id,
         %{
           module: module,
           version: 0,
           state: :free,
           content_hash: nil,
           loaded_at: 0,
           pins: 0,
           released?: false
         }}
      end)
      |> Map.new()

    {slots, artifacts, clock} = restore_loaded_artifacts(slots)

    for {_id, slot} <- slots, slot.state == :used do
      :ets.insert(@slot_versions, {slot.module, slot.version})
    end

    state = %{
      slots: slots,
      artifacts: artifacts,
      clock: clock,
      pins: %{},
      scope_pins: %{}
    }

    {:ok, restore_pins(state)}
  end

  @impl true
  def handle_call({:load, program, scope}, _from, state) do
    {reply, state} = load_artifact(state, program, scope)
    {:reply, reply, state}
  end

  def handle_call({:release, content_hash}, _from, state) do
    case Map.fetch(state.artifacts, content_hash) do
      {:ok, id} ->
        case Map.fetch!(state.slots, id) do
          %{pins: 0} -> {:reply, :ok, elem(reclaim(state, id), 1)}
          _pinned -> {:reply, :ok, put_in(state, [:slots, id, :released?], true)}
        end

      :error ->
        {:reply, :ok, state}
    end
  end

  # Load and pin in one server call: no release or reclamation can run
  # between them, so the pinned slot holds exactly `program`. The scope bound
  # is checked before a load, so a scope at its bound cannot make the pool
  # load anything.
  def handle_call({:pin, program, pid, scope}, _from, state) do
    held = Map.get(state.scope_pins, scope, %{})

    {loaded, literal} =
      case loaded_artifact(state, program.content_hash) do
        {:ok, %Slot{id: id, program: literal}} -> {id, literal}
        :miss -> {nil, nil}
      end

    cond do
      loaded != nil and pinned?(state, pid, loaded) ->
        {:reply, {:ok, literal}, state}

      Map.has_key?(held, loaded) or map_size(held) < Hyperlang.Scope.policy(scope).max_code_pins ->
        case load_artifact(state, program, scope) do
          {{:ok, %Slot{id: id, program: literal}}, state} ->
            {:reply, {:ok, literal}, add_pin(state, pid, id, scope)}

          {{:error, error}, state} ->
            {:reply, {:error, error}, state}
        end

      true ->
        {:reply,
         {:error,
          Hyperlang.Error.new(:code_pool, "scope code pin limit reached",
            details: %{reason: :pin_limit}
          )}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.fetch(state.pins, pid) do
      {:ok, {^ref, held}} -> {:noreply, drop_pins(state, pid, held)}
      _other -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp pinned?(state, pid, id) do
    case Map.fetch(state.pins, pid) do
      {:ok, {_ref, held}} -> Map.has_key?(held, id)
      :error -> false
    end
  end

  defp add_pin(state, pid, id, scope) do
    ref =
      case Map.fetch(state.pins, pid) do
        {:ok, {ref, _held}} -> ref
        :error -> Process.monitor(pid)
      end

    :ets.insert(@pin_table, {{pid, id}, scope})
    count_pin(state, pid, ref, id, scope)
  end

  defp count_pin(state, pid, ref, id, scope) do
    held = state.pins |> Map.get(pid, {ref, %{}}) |> elem(1) |> Map.put(id, scope)

    state
    |> put_in([:pins, pid], {ref, held})
    |> update_in([:slots, id, :pins], &(&1 + 1))
    |> update_in([:scope_pins], fn scopes ->
      Map.update(scopes, scope, %{id => 1}, &Map.update(&1, id, 1, fn n -> n + 1 end))
    end)
  end

  # A process exited: its pins go, and a slot whose release waited for its
  # last pin is reclaimed now.
  defp drop_pins(state, pid, held) do
    state = update_in(state.pins, &Map.delete(&1, pid))

    Enum.reduce(held, state, fn {id, scope}, state ->
      :ets.delete(@pin_table, {pid, id})

      scope_pins =
        case Map.fetch!(state.scope_pins, scope) do
          %{^id => 1} = slots when map_size(slots) == 1 ->
            Map.delete(state.scope_pins, scope)

          %{^id => 1} = slots ->
            Map.put(state.scope_pins, scope, Map.delete(slots, id))

          slots ->
            Map.put(state.scope_pins, scope, Map.update!(slots, id, &(&1 - 1)))
        end

      state = update_in(%{state | scope_pins: scope_pins}, [:slots, id, :pins], &(&1 - 1))

      case Map.fetch!(state.slots, id) do
        %{pins: 0, released?: true} -> elem(reclaim(state, id), 1)
        _slot -> state
      end
    end)
  end

  # Pins outlive a restart of this server: the pin table belongs to the
  # application. Each pinning process is monitored again; a process that died
  # meanwhile delivers its `:DOWN` at once and drops its pins.
  defp restore_pins(state) do
    if :ets.whereis(@pin_table) == :undefined, do: create_pin_table()

    @pin_table
    |> :ets.tab2list()
    |> Enum.group_by(fn {{pid, _id}, _scope} -> pid end)
    |> Enum.reduce(state, fn {pid, rows}, state ->
      ref = Process.monitor(pid)

      Enum.reduce(rows, state, fn {{^pid, id}, scope}, state ->
        if match?(%{state: :used}, Map.get(state.slots, id)) do
          count_pin(state, pid, ref, id, scope)
        else
          :ets.delete(@pin_table, {pid, id})
          state
        end
      end)
    end)
  end

  # Load `program` into a slot of its window, or find it already loaded.
  # Runs inside the server, so a pin taken right after it in the same call
  # (`pin/2`) holds exactly this program.
  defp load_artifact(state, program, scope) do
    %Hyperlang.Program{content_hash: content_hash, artifact: %{forms: forms, manifest: manifest}} =
      program

    case loaded_artifact(state, content_hash) do
      {:ok, slot} ->
        {{:ok, slot}, state}

      :miss ->
        case take_slot(state, manifest.code_pool.size) do
          {:none, state} ->
            {{:error, Hyperlang.Error.new(:code_pool, "no generated code slots available")},
             state}

          {id, slot_state, state} ->
            # The slot version NEVER resets, not even across reclamation: a
            # stale runtime that still names this module carries the version it
            # was bound to, and `Runtime.new_context/3` refuses a mismatch. That
            # monotonic version is what makes slot reuse fail closed
            # (`:invalid_token`) instead of running one guest's call against
            # another guest's code.
            version = slot_state.version + 1
            module = slot_state.module
            loaded_forms = Hyperlang.Codegen.replace_module_and_version(forms, module, version)

            result =
              with :ok <- Hyperlang.Codegen.verify_generated_forms(loaded_forms, module),
                   :ok <-
                     Hyperlang.Scope.with_scope(scope, fn ->
                       compile_and_load(module, loaded_forms, manifest.limits)
                     end) do
                :ok
              end

            case result do
              :ok ->
                key = {@loaded_artifact_key, content_hash}
                clock = state.clock + 1
                # Published from inside the server: reclamation erases these
                # keys, so an artifact must never publish one after the fact.
                :persistent_term.put(
                  key,
                  %Slot{id: id, module: module, version: version, program: program}
                )

                slot = :persistent_term.get(key)
                :ets.insert(@slot_versions, {module, version})

                new_state =
                  state
                  |> put_in(
                    [:slots, id],
                    Map.merge(slot_state, %{
                      state: :used,
                      version: version,
                      content_hash: content_hash,
                      loaded_at: clock,
                      released?: false
                    })
                  )
                  |> put_in([:artifacts, content_hash], id)
                  |> Map.put(:clock, clock)

                {{:ok, slot}, new_state}

              {:error, error} ->
                # The slot was taken but never loaded: hand it straight back.
                {{:error, error}, put_in(state, [:slots, id], Map.put(slot_state, :state, :free))}
            end
        end
    end
  end

  defp loaded_artifact(state, content_hash) do
    with {:ok, id} <- Map.fetch(state.artifacts, content_hash),
         %{state: :used, module: module, version: version} <- Map.get(state.slots, id),
         true <- :code.is_loaded(module) != false,
         %Slot{id: ^id, module: ^module, version: ^version} = slot <-
           :persistent_term.get({@loaded_artifact_key, content_hash}, nil) do
      {:ok, slot}
    else
      _ -> :miss
    end
  end

  defp restore_loaded_artifacts(slots) do
    Enum.reduce(:persistent_term.get(), {slots, %{}, 0}, fn
      {{@loaded_artifact_key, content_hash}, %Slot{id: id, module: module, version: version}},
      {slots, artifacts, clock} ->
        slot = Map.get(slots, id)

        if match?(%{module: ^module}, slot) and :code.is_loaded(module) != false do
          clock = clock + 1

          slots =
            Map.put(
              slots,
              id,
              Map.merge(slot, %{
                state: :used,
                version: version,
                content_hash: content_hash,
                loaded_at: clock
              })
            )

          {slots, Map.put(artifacts, content_hash, id), clock}
        else
          :persistent_term.erase({@loaded_artifact_key, content_hash})
          {slots, artifacts, clock}
        end

      _entry, acc ->
        acc
    end)
  end

  defp compile_and_load(module, forms, limits) do
    opts = @compile_options

    with {:ok, result} <- bounded_noenv_forms(forms, opts, limits),
         {:ok, ^module, binary, _warnings} <- result do
      purge(module)

      case :code.load_binary(module, ~c"hyperlang_generated", binary) do
        {:module, ^module} ->
          :ok

        {:error, reason} ->
          {:error,
           Hyperlang.Error.new(:load, "failed to load generated module",
             details: %{reason: reason}
           )}
      end
    else
      {:ok, ^module, binary} ->
        purge(module)

        case :code.load_binary(module, ~c"hyperlang_generated", binary) do
          {:module, ^module} ->
            :ok

          {:error, reason} ->
            {:error,
             Hyperlang.Error.new(:load, "failed to load generated module",
               details: %{reason: reason}
             )}
        end

      {:error, errors, warnings} ->
        {:error,
         Hyperlang.Error.new(:compile, "OTP compiler rejected generated forms",
           details: %{errors: errors, warnings: warnings}
         )}

      {:error, error} ->
        {:error, error}

      other ->
        {:error,
         Hyperlang.Error.new(:compile, "unexpected compiler result",
           details: %{result: inspect(other)}
         )}
    end
  end

  defp bounded_noenv_forms(forms, opts, limits) do
    # The same compile-worker bound as the front end: a program the manifest
    # admits must also be loadable (a 1,500-function graph needs more than the
    # former fixed 2M-word cap and was killed mid-compile).
    # The OTP compiler names the local functions it makes for funs,
    # comprehensions and receive loops after the enclosing function. Generated
    # code draws those names from a fixed set (`GeneratedAtoms`); promise the
    # ones this compile can still add before it runs, so Hyperlang keeps the
    # atom-table reserve free.
    bound = Hyperlang.GeneratedAtoms.compiler_atom_bound(forms)

    case Hyperlang.GeneratedAtoms.with_atom_headroom(bound, fn ->
           Hyperlang.Compiler.run_bounded(limits, fn ->
             {:ok, :compile.noenv_forms(forms, opts)}
           end)
         end) do
      {:error, :atom_table_reserve} -> {:error, Hyperlang.GeneratedAtoms.reserve_error()}
      result -> result
    end
  end

  # Take the lowest free slot inside the caller's window; on exhaustion reclaim
  # the least recently loaded artifact that no longer runs anywhere.
  defp take_slot(state, requested) do
    case first_free_slot(state, requested) do
      {id, slot_state} -> {id, Map.put(slot_state, :state, :used), state}
      nil -> reclaim_slot(state, requested)
    end
  end

  defp first_free_slot(state, requested) do
    state.slots
    |> Enum.filter(fn {id, slot} -> id <= requested and slot.state == :free end)
    |> Enum.min_by(&elem(&1, 0), fn -> nil end)
  end

  # Least recently loaded first. A pinned slot is never a victim. A victim
  # still running guest code stays occupied (`:draining`) and the next
  # candidate is tried; a pool with nothing unpinned and quiescent reports
  # exhaustion.
  defp reclaim_slot(state, requested) do
    state.slots
    |> Enum.filter(fn {id, slot} ->
      id <= requested and slot.state != :free and slot.pins == 0
    end)
    |> Enum.sort_by(fn {_id, slot} -> slot.loaded_at end)
    |> Enum.take(@reclaim_attempts)
    |> Enum.reduce_while({:none, state}, fn {id, _slot}, {:none, state} ->
      case reclaim(state, id) do
        {:free, state} ->
          {:halt, {id, Map.put(Map.fetch!(state.slots, id), :state, :used), state}}

        {:draining, state} ->
          {:cont, {:none, state}}
      end
    end)
  end

  # Reclamation, in this order: drop the artifact mapping so nothing new can
  # resolve to this module, then establish quiescence. A module a guest process
  # still runs is left `:draining` — it holds no artifact any more and a later
  # miss retries it. Reclamation NEVER hard-purges: a hard purge kills the guest
  # processes running that code.
  defp reclaim(state, id) do
    slot_state = Map.fetch!(state.slots, id)
    :ets.delete(@slot_versions, slot_state.module)

    state =
      case slot_state.content_hash do
        nil ->
          state

        content_hash ->
          :persistent_term.erase({@loaded_artifact_key, content_hash})
          update_in(state.artifacts, &Map.delete(&1, content_hash))
      end

    slot_state =
      Map.merge(slot_state, %{
        content_hash: nil,
        released?: false,
        state: if(quiescent?(slot_state.module), do: :free, else: :draining)
      })

    {slot_state.state, put_in(state, [:slots, id], slot_state)}
  end

  # `:code.delete/1` turns current code into old code; `:code.soft_purge/1`
  # then reports whether any process still runs it. A `:draining` slot has
  # already been deleted, so the leading soft purge answers on its own.
  defp quiescent?(module) do
    cond do
      not :code.soft_purge(module) ->
        false

      :code.is_loaded(module) == false ->
        true

      true ->
        :code.delete(module)
        :code.soft_purge(module)
    end
  end

  defp purge(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
    :ok
  end

  defp compile_options_hash_data do
    %{compile_options: @compile_options, code_pool_size: code_pool_size()}
  end

  defp put_compile_options_hash!(data) do
    hash = Hyperlang.Program.sha256_hex(data)
    :persistent_term.put({@compile_options_hash_key, data}, hash)
    hash
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        {:ok, _} = start_link([])
        :ok

      _pid ->
        :ok
    end
  end
end
