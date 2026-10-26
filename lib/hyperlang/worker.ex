defmodule Hyperlang.Worker do
  @moduledoc false

  @owned_actor_key {__MODULE__, :owned_actor}
  @keep_bindings_key :"$hyperlang_keep_bindings"
  @guest_dictionary_owner_key :"$hyperlang_guest_dictionary_owner"
  @kernel_atom_pool_key :"$hyperlang_kernel_atom_pool"
  @guest_dictionary_frame_opt :guest_dictionary_frame_id
  @active_call_depth_key :"$hyperlang_worker_call_depth"
  @deferred_output_key :"$hyperlang_deferred_output"

  def run_export(stored, export_id, args, opts)
      when is_map(stored) and is_binary(export_id) and is_list(args) and is_list(opts) do
    do_call(stored, export_id, args, opts)
  end

  def run_entry(stored, input, opts)
      when is_map(stored) and is_list(opts) do
    with_process_bindings(stored, {:entry, input}, opts, fn ->
      do_sandbox_call(stored, {:entry, input}, opts)
    end)
  end

  defp do_call(stored, export_id, args, opts) do
    with_process_bindings(stored, {:export, export_id, args}, opts, fn ->
      do_sandbox_call(stored, {:export, export_id, args}, opts)
    end)
  end

  defp do_sandbox_call(stored, call, opts) do
    parent = self()
    ref = make_ref()
    slot = stored.slot
    call_id = :erlang.unique_integer([:positive, :monotonic])

    runtime =
      stored.runtime
      |> Map.put(:call_id, call_id)
      |> call_runtime(opts)

    token = stored.token

    with :ok <- Hyperlang.Terms.validate_runtime(runtime),
         :ok <- begin_filesystem_eval(stored, call_id) do
      run_worker_with_setup_cleanup(stored, call_id, runtime, fn ->
        run_worker(stored, call, parent, ref, slot, call_id, runtime, token, opts)
      end)
    else
      {:error, %{category: _category} = error} ->
        {:error, Hyperlang.Terms.sanitize_error(error, runtime)}

      {:error, reason} ->
        {:error,
         Hyperlang.Terms.sanitize_error(
           %{category: :filesystem, reason: reason},
           runtime
         )}
    end
  end

  # The final host state rides the reply envelope back to the host. It is
  # attached after worker-side sanitization and never crosses guest code, so
  # it stays a trusted host term: guest process-dictionary BIFs use generated
  # source atoms, while this slot is keyed by a reserved runtime atom.
  defp attach_host_state({:ok, %{result: _result, stdout: _stdout} = envelope}, true),
    do: {:ok, Map.put(envelope, :host_state, Hyperlang.SyscallHost.harvest_state())}

  defp attach_host_state(reply, _seeded?), do: reply

  # Reductions the guest call consumed in its own process (binding calls
  # included, guest-spawned children excluded). A host-side integer measured
  # outside guest code; it rides the envelope like host state.
  defp attach_reductions({:ok, %{} = envelope}, reductions),
    do: {:ok, Map.put(envelope, :reductions, max(reductions, 0))}

  defp attach_reductions(reply, _reductions), do: reply

  defp call_runtime(runtime, opts) do
    put_syscall(runtime, opts)
  end

  defp put_syscall(runtime, opts) do
    case Keyword.fetch(opts, :syscall) do
      {:ok, syscall} when is_function(syscall, 2) or is_function(syscall, 3) ->
        Map.put(runtime, :syscall, syscall)

      {:ok, {module, _state} = host} when is_atom(module) and not is_nil(module) ->
        Map.put(runtime, :syscall, host)

      {:ok, nil} ->
        Map.put(runtime, :syscall, nil)

      {:ok, _invalid} ->
        Map.put(runtime, :syscall, :invalid_syscall_callback)

      :error ->
        runtime
    end
  end

  defp run_worker(stored, call, parent, ref, slot, call_id, runtime, token, opts) do
    if Keyword.get(opts, :run_in_caller?, false) do
      run_worker_in_caller(stored, call, slot, call_id, runtime, token, opts)
    else
      run_worker_in_child(stored, call, parent, ref, slot, call_id, runtime, token, opts)
    end
  end

  defp run_worker_in_caller(stored, call, slot, call_id, runtime, token, opts) do
    fault = :atomics.new(1, [])

    # In-caller admission happens here, not in `Hyperlang.run/4`: one call
    # admits the run and attaches this process.
    admission =
      Hyperlang.Scope.acquire_run(
        runtime.host_scope,
        if(Process.get(@owned_actor_key, false), do: :actor_run, else: :host_run),
        stored.limits.max_heap_words || stored.limits.heap_words,
        fault
      )

    try do
      with {:ok, _lease, _opened?} <- admission do
        :hyperlang_msg.with_context(native_msg_context(stored), fn ->
          previous_keep_bindings = Process.get(@keep_bindings_key, :undefined)
          Process.put(@keep_bindings_key, keep_bindings?(call, opts))

          host_state = Keyword.fetch(opts, :host_state)

          watcher =
            arm_limits(
              stored,
              self(),
              caller_limits(stored.limits, opts)
            )

          case set_owner_process_limits(stored) do
            {:ok, old_limits} ->
              try do
                # Long-lived serving processes keep their guest process dictionary
                # frame across calls. The owner key prevents a different
                # instance/program/syscall from inheriting that state.
                reply =
                  sandbox_call_reply(
                    slot,
                    token,
                    runtime,
                    call,
                    host_state,
                    not keep_bindings?(call, opts)
                  )

                complete_owner_reply(stored, watcher, call_id, runtime, reply, fault)
              after
                stop_watcher(watcher)
                restore_owner_process_limits(old_limits)
                restore_keep_bindings(previous_keep_bindings)
              end

            {:error, reason} ->
              restore_keep_bindings(previous_keep_bindings)
              stop_watcher(watcher)
              cleanup_setup_failure(stored, call_id)
              setup_failure_error(runtime, reason)
          end
        end)
      else
        {:error, error} ->
          cleanup_setup_failure(stored, call_id)
          {:error, Hyperlang.Terms.sanitize_error(error, runtime)}
      end
    after
      case admission do
        {:ok, lease, opened?} -> Hyperlang.Scope.detach_run(runtime.host_scope, opened?, lease)
        _error -> :ok
      end
    end
  end

  defp run_worker_in_child(stored, call, parent, ref, slot, call_id, runtime, token, opts) do
    # A context template is a same-process fast path. Copying it into a fresh
    # worker duplicates the large manifest/import graph before guest execution
    # and charges that substrate copy to the guest heap limit. Rebuild the
    # context once in the child instead; the policy and limit stay unchanged.
    runtime = Map.delete(runtime, :context_template)
    host_state = Keyword.fetch(opts, :host_state)
    msg_context = native_msg_context(stored)
    limits_group = stored.limits_group
    limits = owner_limits(stored.limits, opts)
    fault = :atomics.new(1, [])
    lease = Hyperlang.Scope.take_lease(runtime.host_scope)

    priority = Hyperlang.Scope.priority(runtime.host_scope)

    fun = fn ->
      # A latency-class worker starts at high priority so its first scheduling
      # does not queue behind background processes, then takes its class.
      Process.flag(:priority, priority)

      # Capture only the compact message context. Capturing the full instance
      # would duplicate its manifest/import graph alongside `runtime` in the
      # child before guest execution and wrongly charge substrate state twice.
      Hyperlang.Scope.with_scope(runtime.host_scope, fn ->
        :hyperlang_msg.with_context(msg_context, fn ->
          :ok =
            Hyperlang.Scope.attach_worker(
              runtime.host_scope,
              limits.max_heap_words || limits.heap_words,
              parent,
              fault
            )

          # The worker's wall deadline, ceiling and children are a local
          # slot of the run's group: arming and finishing wait for Limits
          # only when a guest child joined the run.
          generation = Hyperlang.Limits.arm(limits_group, self(), limits)

          receive do
            {^ref, :start} -> :ok
          end

          reply = sandbox_call_reply(slot, token, runtime, call, host_state)

          reply =
            case Hyperlang.Limits.finish_run(limits_group, self(), generation) do
              {:error, :ceiling} -> reduction_budget_reply(runtime)
              {:error, :wall_ms} -> wall_budget_reply(runtime)
              :ok -> reply
            end

          :ok = Hyperlang.Scope.detach_worker(runtime.host_scope, lease)
          send(parent, {ref, reply})
        end)
      end)
    end

    spawn_opts = [
      :monitor,
      {:message_queue_data, worker_message_queue_data(stored)},
      {:priority, if(priority == :normal, do: :high, else: priority)},
      {:max_heap_size, worker_heap_limit(stored)}
    ]

    {pid, mon} =
      try do
        :erlang.spawn_opt(fun, spawn_opts)
      rescue
        error ->
          if lease, do: Hyperlang.Scope.release(lease)
          reraise error, __STACKTRACE__
      end

    watcher = %{
      type: :limits,
      group: limits_group,
      pid: pid,
      scope: runtime.host_scope,
      fault: fault
    }

    # A parent that dies orphans its worker. Scope (the member's caller
    # monitor) and Limits (the run group's owner monitor) both kill it; a
    # watcher process is needed only to finish the filesystem evaluation.
    cancel_watcher =
      case stored.filesystem do
        %Hyperlang.Filesystem.Handle{} = filesystem ->
          watch_parent(parent, pid, fn ->
            cleanup_timed_out_call(%{filesystem: filesystem}, call_id)
          end)

        _none ->
          nil
      end

    send(pid, {ref, :start})

    await_worker_reply(
      stored,
      ref,
      pid,
      mon,
      watcher,
      cancel_watcher,
      call_id,
      runtime,
      lease
    )
  end

  defp worker_heap_limit(stored) do
    Hyperlang.Limits.heap_flags(stored.limits.max_heap_words || stored.limits.heap_words)
  end

  defp worker_message_queue_data(_stored), do: :on_heap

  defp native_msg_context(stored) do
    runtime = Map.get(stored, :runtime, %{})

    %{
      run_key: stored.program_key,
      scope: runtime.host_scope,
      scope_owner: runtime.host_owner,
      limits_group: stored.limits_group,
      limits: stored.limits,
      terms: Map.get(runtime, :terms, %{}),
      atom_pool: Map.get(runtime, :atom_pool, %{}),
      atom_universe: Map.get(runtime, :atom_universe)
    }
  end

  defp owner_limits(limits, opts) do
    Map.put(limits, :wall_ms, worker_timeout(opts, limits.wall_ms))
  end

  defp caller_limits(limits, opts) do
    limits = owner_limits(limits, opts)

    if Process.get(@owned_actor_key, false),
      do: limits,
      else: Map.put(limits, :kill, &ignore_owner_kill/2)
  end

  @doc false
  def with_owned_actor(fun) do
    previous = Process.put(@owned_actor_key, true)

    try do
      fun.()
    after
      if is_nil(previous),
        do: Process.delete(@owned_actor_key),
        else: Process.put(@owned_actor_key, previous)
    end
  end

  # An explicit in-caller evaluation shares the host's process and authority.
  # Record expiry, then return the typed budget fault when control comes back.
  defp ignore_owner_kill(_pid, _reason), do: :ok

  defp run_worker_with_setup_cleanup(stored, call_id, runtime, fun) do
    try do
      fun.()
    rescue
      e in ArgumentError ->
        setup_failure_reply(stored, call_id, runtime, {:badarg, Exception.message(e)})
    catch
      :error, reason ->
        setup_failure_reply(stored, call_id, runtime, reason)
    end
  end

  defp setup_failure_reply(stored, call_id, runtime, reason) do
    cleanup_setup_failure(stored, call_id)
    setup_failure_error(runtime, reason)
  end

  defp cleanup_setup_failure(stored, call_id) do
    cleanup_timed_out_call(stored, call_id)
    Hyperlang.Runtime.clear_guest_dictionary()
    Process.delete(@guest_dictionary_owner_key)
    Hyperlang.SyscallHost.clear_state()
    :ok
  end

  defp setup_failure_error(runtime, reason) do
    {:error, Hyperlang.Terms.sanitize_error(%{category: :lifecycle, reason: reason}, runtime)}
  end

  defp set_owner_process_limits(stored) do
    try do
      old_heap = Process.flag(:max_heap_size, worker_heap_limit(stored))

      old_queue = Process.flag(:message_queue_data, :on_heap)
      old_priority = Process.flag(:priority, Hyperlang.Scope.priority(stored.runtime.host_scope))

      {:ok, {old_heap, old_queue, old_priority}}
    rescue
      e in ArgumentError ->
        {:error, {:badarg, Exception.message(e)}}
    catch
      :error, reason ->
        {:error, reason}
    end
  end

  defp restore_owner_process_limits({old_heap, old_queue, old_priority}) do
    _ = Process.flag(:max_heap_size, old_heap)
    _ = Process.flag(:priority, old_priority)

    if old_queue != :unchanged do
      _ = Process.flag(:message_queue_data, old_queue)
    end

    :ok
  end

  defp with_process_bindings(stored, call, opts, fun) do
    if active_worker_call?() do
      with_nested_process_bindings(fn ->
        with_guest_dictionary_frame(stored, opts, fn ->
          with_guest_dictionary_entries(opts, fun)
        end)
      end)
    else
      prepare_process_bindings(stored, call, opts)

      with_guest_dictionary_frame(stored, opts, fn ->
        with_guest_dictionary_entries(opts, fun)
      end)
    end
  end

  defp with_guest_dictionary_frame(stored, opts, fun) when is_function(fun, 0) do
    case guest_dictionary_frame_id(stored, opts) do
      nil ->
        fun.()

      frame_id ->
        previous = Hyperlang.Runtime.select_guest_dictionary_frame(frame_id)

        try do
          fun.()
        after
          Hyperlang.Runtime.restore_guest_dictionary_frame(previous)
        end
    end
  end

  defp guest_dictionary_frame_id(stored, opts) do
    Keyword.get(opts, @guest_dictionary_frame_opt) ||
      stored.program_key
  end

  defp with_guest_dictionary_entries(opts, fun) when is_list(opts) and is_function(fun, 0) do
    case Keyword.get(opts, :guest_dictionary_entries) do
      entries when is_list(entries) ->
        if Keyword.get(opts, :restore_guest_dictionary_entries?, true) do
          previous = Hyperlang.Runtime.snapshot_guest_dictionary_state()
          :ok = Hyperlang.Runtime.restore_guest_dictionary(entries)

          try do
            fun.()
          after
            :ok = Hyperlang.Runtime.restore_guest_dictionary_snapshot(previous)
          end
        else
          :ok = Hyperlang.Runtime.restore_guest_dictionary(entries)
          fun.()
        end

      _other ->
        fun.()
    end
  end

  defp with_nested_process_bindings(fun) do
    previous_keep_bindings = Process.get(@keep_bindings_key, :undefined)
    previous_owner = Process.get(@guest_dictionary_owner_key, :undefined)
    previous_host_state = Hyperlang.SyscallHost.snapshot_state()
    Process.delete(@keep_bindings_key)
    Process.delete(@guest_dictionary_owner_key)
    Hyperlang.SyscallHost.clear_state()

    Hyperlang.ModuleLoader.with_bindings(%{}, fn ->
      try do
        fun.()
      after
        Hyperlang.ModuleLoader.current_bindings()
        |> Hyperlang.ModuleLoader.release_binding_map()

        restore_keep_bindings(previous_keep_bindings)
        restore_guest_dictionary_owner(previous_owner)
        Hyperlang.SyscallHost.restore_state(previous_host_state)
      end
    end)
  end

  defp prepare_process_bindings(stored, call, opts) do
    if keep_bindings?(call, opts) do
      owner = binding_owner(stored, opts)

      if Process.get(@guest_dictionary_owner_key) != owner do
        Hyperlang.ModuleLoader.release_bindings()
        Process.put(@guest_dictionary_owner_key, owner)
      end
    else
      Hyperlang.ModuleLoader.release_bindings()
      Process.delete(@guest_dictionary_owner_key)
      Process.delete(@keep_bindings_key)
    end
  end

  defp keep_bindings?(_call, opts) do
    Keyword.get(opts, :run_in_caller?, false) and Keyword.get(opts, :keep_bindings, false)
  end

  defp binding_owner(stored, opts) do
    {
      Keyword.get(opts, @guest_dictionary_frame_opt),
      stored.program_key,
      stored.slot.module,
      stored.slot.version,
      Map.get(stored.runtime, :host_scope),
      Keyword.get(opts, :syscall, :stored_syscall)
    }
  end

  defp restore_keep_bindings(:undefined), do: Process.delete(@keep_bindings_key)
  defp restore_keep_bindings(value), do: Process.put(@keep_bindings_key, value)

  defp restore_guest_dictionary_owner(:undefined), do: Process.delete(@guest_dictionary_owner_key)
  defp restore_guest_dictionary_owner(value), do: Process.put(@guest_dictionary_owner_key, value)

  defp sandbox_call_reply(
         slot,
         token,
         runtime,
         call,
         host_state,
         release_guest_dictionary? \\ true
       ) do
    nested_call? = active_worker_call?()
    {seeded?, previous_host_state} = prepare_call_host_state(host_state, nested_call?)
    {:reductions, reductions_before} = Process.info(self(), :reductions)

    reply =
      with_active_worker_call(fn ->
        reply =
          try do
            Hyperlang.Scope.running(runtime.host_scope, fn ->
              apply_sandbox_call(slot.module, token, runtime, call)
            end)
          rescue
            e in MatchError ->
              {:error,
               Hyperlang.Runtime.trim_error(
                 :error,
                 {:badmatch, Map.get(e, :term, :badmatch)},
                 __STACKTRACE__,
                 runtime
               )}

            _e in UndefinedFunctionError ->
              {:error, Hyperlang.Runtime.trim_error(:error, :undef, __STACKTRACE__, runtime)}

            e in ErlangError ->
              {:error,
               Hyperlang.Runtime.trim_error(
                 :error,
                 Map.get(e, :original, e),
                 __STACKTRACE__,
                 runtime
               )}

            e ->
              {:error,
               Hyperlang.Runtime.trim_error(
                 :error,
                 {:exception, e.__struct__},
                 __STACKTRACE__,
                 runtime
               )
               |> Map.put(:exception, e.__struct__)}
          catch
            :throw, {:hyperlang_scope_busy, error} ->
              {:error, Hyperlang.Terms.sanitize_error(error, runtime)}

            :exit, reason ->
              {:error, %{category: :sandbox_crash, reason: reason}}

            :throw, {:hyperbob_os_exec_overlay, %{} = result} ->
              {:ok, %{result: result, stdout: []}}

            :throw, {:hyperlang_exits, status} ->
              Hyperlang.Runtime.finish_exit(runtime, status)

            class, reason ->
              {:error, Hyperlang.Runtime.trim_error(class, reason, __STACKTRACE__, runtime)}
          end

        maybe_trust_reply_output(reply, call, runtime)
      end)

    {:reductions, reductions_after} = Process.info(self(), :reductions)
    kernel_atom_pool = Hyperlang.KernelAtomPool.snapshot()

    try do
      if release_guest_dictionary? and not nested_call? do
        Hyperlang.ModuleLoader.release_bindings()
      end

      reply
      |> attach_reductions(reductions_after - reductions_before)
      |> attach_host_state(seeded?)
      |> attach_kernel_atom_pool(kernel_atom_pool)
    after
      restore_call_host_state(nested_call?, previous_host_state)
    end
  end

  defp prepare_call_host_state(host_state, nested_call?) do
    previous_host_state =
      if nested_call? do
        Hyperlang.SyscallHost.snapshot_state()
      else
        :absent
      end

    {seed_host_state(host_state), previous_host_state}
  end

  defp seed_host_state({:ok, state}) do
    Hyperlang.SyscallHost.seed_state(state)
    true
  end

  defp seed_host_state(:error) do
    Hyperlang.SyscallHost.clear_state()
    false
  end

  defp restore_call_host_state(true, previous_host_state),
    do: Hyperlang.SyscallHost.restore_state(previous_host_state)

  defp restore_call_host_state(false, _previous_host_state),
    do: Hyperlang.SyscallHost.clear_state()

  defp active_worker_call?, do: Process.get(@active_call_depth_key, 0) > 0

  defp with_active_worker_call(fun) do
    depth = Process.get(@active_call_depth_key, 0)
    Process.put(@active_call_depth_key, depth + 1)

    try do
      fun.()
    after
      if depth == 0 do
        Process.delete(@active_call_depth_key)
      else
        Process.put(@active_call_depth_key, depth)
      end
    end
  end

  # A worker replies only after it deleted its limits group and released the
  # offered lease with its membership. Any other exit leaves both to the caller.
  # A latency-class caller waits at high priority, so the worker's reply resumes
  # it without queueing behind background processes; it drops back on wake-up.
  defp await_worker_reply(stored, ref, pid, mon, watcher, cancel_watcher, call_id, runtime, lease) do
    previous =
      if Hyperlang.Scope.priority(runtime.host_scope) == :normal,
        do: Process.flag(:priority, :high)

    received =
      receive do
        {^ref, reply} -> {:reply, reply}
        {:DOWN, ^mon, :process, ^pid, reason} -> {:down, reason}
      end

    if previous, do: Process.flag(:priority, previous)

    case received do
      {:reply, reply} ->
        Hyperlang.Limits.finished(stored.limits_group)
        complete_worker_reply(stored, mon, cancel_watcher, call_id, runtime, reply)

      {:down, reason} ->
        if lease, do: Hyperlang.Scope.release(lease)
        worker_down_reply(stored, watcher, cancel_watcher, call_id, runtime, reason)
    end
  end

  # The worker completes its own limits membership before it replies and folds
  # a wall or ceiling fault into `reply`, so the caller needs no Limits call.
  defp complete_worker_reply(stored, mon, cancel_watcher, call_id, runtime, reply) do
    stop_parent_watcher(cancel_watcher)
    Process.demonitor(mon, [:flush])
    finish_reply = finish_filesystem_eval(stored, call_id, reply_outcome(reply))
    cleanup_call_handles(stored, call_id)
    finish_worker_reply(finish_reply, reply, runtime)
  end

  defp complete_owner_reply(stored, watcher, call_id, runtime, reply, fault) do
    limit = complete_owner_watcher(watcher)
    scope_result = Hyperlang.Scope.fault_reason(fault)
    result = if scope_result == :ok, do: limit, else: scope_result

    case result do
      {:error, %{category: :busy} = error} ->
        _ = finish_filesystem_eval(stored, call_id, :failure)
        cleanup_call_handles(stored, call_id)
        {:error, Hyperlang.Terms.sanitize_error(error, runtime)}

      :ok ->
        finish_reply = finish_filesystem_eval(stored, call_id, reply_outcome(reply))
        cleanup_call_handles(stored, call_id)
        finish_worker_reply(finish_reply, reply, runtime)

      {:error, limit} ->
        _ = finish_filesystem_eval(stored, call_id, :failure)
        cleanup_call_handles(stored, call_id)
        owner_limit_budget_reply(limit, runtime)
    end
  end

  defp owner_limit_budget_reply(:max_reductions, runtime), do: reduction_budget_reply(runtime)
  defp owner_limit_budget_reply(:wall_ms, runtime), do: wall_budget_reply(runtime)

  defp reduction_budget_reply(runtime) do
    {:error,
     Hyperlang.Terms.sanitize_error(
       %{category: :reduction_watchdog, reason: :max_reductions},
       runtime
     )}
  end

  defp wall_budget_reply(runtime) do
    {:error, Hyperlang.Terms.sanitize_error(%{category: :timeout, reason: :wall_ms}, runtime)}
  end

  defp worker_down_reply(stored, watcher, cancel_watcher, call_id, runtime, reason) do
    stop_watcher(watcher)
    stop_parent_watcher(cancel_watcher)
    _ = finish_filesystem_eval(stored, call_id, :failure)
    cleanup_call_handles(stored, call_id)

    {:error, Hyperlang.Terms.sanitize_error(crash_error(reason, watcher), runtime)}
  end

  defp worker_timeout(opts, default) do
    case Keyword.get(opts, :wall_timeout, default) do
      :infinity -> :infinity
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _other -> default
    end
  end

  defp apply_sandbox_call(module, token, runtime, {:entry, input}) do
    apply(module, :"$safe_entry", [token, input, runtime])
  end

  defp apply_sandbox_call(module, token, runtime, {:export, export_id, args}) do
    apply(module, :"$safe_export", [token, export_id, args, runtime])
  end

  defp maybe_trust_export_reply(
         {:ok, %{result: _result, stdout: _stdout} = envelope},
         {:export, _id, _args}
       ),
       do: {:ok, Map.put(envelope, @deferred_output_key, :already_sanitized)}

  defp maybe_trust_export_reply(reply, _call), do: reply

  defp maybe_trust_reply_output(reply, {:export, _id, _args} = call, _runtime) do
    maybe_trust_export_reply(reply, call)
  end

  defp maybe_trust_reply_output(reply, _call, _runtime), do: reply

  defp begin_filesystem_eval(%{filesystem: %Hyperlang.Filesystem.Handle{} = handle}, call_id) do
    case Hyperlang.Filesystem.begin_eval(handle, call_id, self()) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp begin_filesystem_eval(_stored, _call_id), do: :ok

  defp finish_filesystem_eval(
         %{filesystem: %Hyperlang.Filesystem.Handle{} = handle},
         call_id,
         outcome
       ) do
    case Hyperlang.Filesystem.finish_eval(handle, call_id, outcome) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish_filesystem_eval(_stored, _call_id, _outcome), do: :ok

  defp reply_outcome({:ok, _value}), do: :success
  defp reply_outcome(_reply), do: :failure

  defp cleanup_call_handles(%{filesystem: %Hyperlang.Filesystem.Handle{} = handle}, call_id) do
    _ = Hyperlang.Filesystem.close_call_handles(handle, call_id)
    :ok
  end

  defp cleanup_call_handles(_stored, _call_id), do: :ok

  defp attach_kernel_atom_pool(reply, :undefined), do: reply

  defp attach_kernel_atom_pool({:ok, %{} = envelope}, snapshot),
    do: {:ok, Map.put(envelope, @kernel_atom_pool_key, snapshot)}

  defp attach_kernel_atom_pool({:error, %{} = error}, snapshot),
    do: {:error, Map.put(error, @kernel_atom_pool_key, snapshot)}

  defp attach_kernel_atom_pool(reply, _snapshot), do: reply

  defp finish_worker_reply(finish_reply, reply, runtime) do
    with_kernel_atom_pool(reply, fn clean_reply ->
      maybe_sanitize_reply(finish_reply, clean_reply, runtime)
    end)
  end

  defp with_kernel_atom_pool({tag, %{} = value}, fun)
       when tag in [:ok, :error] and is_function(fun, 1) do
    case Map.pop(value, @kernel_atom_pool_key) do
      {nil, clean} ->
        fun.({tag, clean})

      {snapshot, clean} ->
        previous = Hyperlang.KernelAtomPool.snapshot()
        Hyperlang.KernelAtomPool.restore(snapshot)

        try do
          fun.({tag, clean})
        after
          Hyperlang.KernelAtomPool.restore(previous)
        end
    end
  end

  defp with_kernel_atom_pool(reply, fun), do: fun.(reply)

  # Host state is a trusted host term attached after the guest finished; it
  # crosses back to the host unsanitized and never enters guest code.
  defp carry_opaque_envelope_fields(sanitized, envelope) do
    sanitized
    |> carry_host_state(envelope)
    |> carry_exit_status(envelope)
    |> carry_reductions(envelope)
  end

  defp carry_reductions(sanitized, %{reductions: reductions}),
    do: Map.put(sanitized, :reductions, reductions)

  defp carry_reductions(sanitized, _envelope), do: sanitized

  defp carry_host_state(sanitized, %{host_state: host_state}),
    do: Map.put(sanitized, :host_state, host_state)

  defp carry_host_state(sanitized, _envelope), do: sanitized

  defp carry_exit_status(sanitized, %{exit_status: status}),
    do: Map.put(sanitized, :exit_status, status)

  defp carry_exit_status(sanitized, _envelope), do: sanitized

  defp maybe_sanitize_reply(
         :ok,
         {:ok,
          %{@deferred_output_key => :already_sanitized, result: _result, stdout: _stdout} =
            envelope},
         _runtime
       ) do
    {:ok,
     envelope
     |> Map.delete(@deferred_output_key)
     |> carry_opaque_envelope_fields(envelope)}
  end

  defp maybe_sanitize_reply(:ok, reply, runtime) do
    Hyperlang.Terms.sanitize_reply(reply, runtime, &carry_opaque_envelope_fields/2)
  end

  defp maybe_sanitize_reply({:error, reason}, _reply, runtime) do
    {:error,
     Hyperlang.Terms.sanitize_error(
       %{category: :filesystem, reason: reason},
       runtime
     )}
  end

  defp crash_error({:hyperlang_limit, :ceiling}, _watcher),
    do: %{category: :reduction_watchdog, reason: :max_reductions}

  defp crash_error({:hyperlang_limit, :wall_ms}, _watcher),
    do: %{category: :timeout, reason: :wall_ms}

  defp crash_error({:hyperlang_limit, :scope}, _watcher),
    do: %{category: :busy, reason: :scope_terminated}

  defp crash_error(:killed, %{fault: fault}) do
    case Hyperlang.Scope.fault_reason(fault) do
      {:error, error} -> error
      :ok -> %{category: :heap, reason: :max_heap_size}
    end
  end

  defp crash_error(:killed, _watcher), do: %{category: :heap, reason: :max_heap_size}

  defp crash_error(reason, _watcher), do: %{category: :sandbox_crash, reason: reason}

  defp arm_limits(stored, pid, limits) do
    generation = Hyperlang.Limits.arm(stored.limits_group, pid, limits)
    %{type: :ephemeral_limit, group: stored.limits_group, pid: pid, generation: generation}
  end

  defp stop_watcher(nil), do: :ok

  defp stop_watcher(%{type: :ephemeral_limit} = watcher) do
    _ = Hyperlang.Limits.disarm(watcher.group, watcher.pid, watcher.generation)
    :ok
  end

  defp stop_watcher(%{type: :limits} = watcher) do
    Hyperlang.Limits.detach(watcher.group, watcher.pid)
  end

  defp complete_owner_watcher(nil), do: :ok

  defp complete_owner_watcher(%{type: :ephemeral_limit} = watcher) do
    case Hyperlang.Limits.disarm(watcher.group, watcher.pid, watcher.generation) do
      {:error, :ceiling} -> {:error, :max_reductions}
      result -> result
    end
  end

  defp cleanup_timed_out_call(stored, call_id) do
    _ = finish_filesystem_eval(stored, call_id, :failure)
    cleanup_call_handles(stored, call_id)
  end

  defp stop_parent_watcher(nil), do: :ok
  defp stop_parent_watcher(watcher), do: Process.exit(watcher, :kill)

  defp watch_parent(parent, worker, cleanup) do
    spawn(fn ->
      ref = Process.monitor(parent)

      receive do
        {:DOWN, ^ref, :process, ^parent, _reason} ->
          Process.exit(worker, :kill)
          cleanup.()
      end
    end)
  end
end
