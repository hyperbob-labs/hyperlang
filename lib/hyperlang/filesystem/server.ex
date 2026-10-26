defmodule Hyperlang.Filesystem.Server do
  @moduledoc false

  use GenServer
  require Logger

  alias Hyperlang.Filesystem
  alias Hyperlang.Filesystem.OtpFacade

  @entry_metadata_bytes 64
  @tombstone_metadata_bytes 32
  @request_id_key {__MODULE__, :request_id}

  def child_spec(arg) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [arg]},
      restart: :temporary,
      type: :worker
    }
  end

  def start_link({filesystem, opts}) do
    GenServer.start_link(__MODULE__, {filesystem, opts})
  end

  @impl true
  def init({filesystem, opts}) do
    limits = Map.fetch!(filesystem, :limits)

    Process.flag(:message_queue_data, :off_heap)

    Process.flag(:max_heap_size, %{
      size:
        Keyword.get(
          opts,
          :heap_words,
          heap_words_for_bytes(limits[:max_total_memory_bytes] || 1_000_000)
        ),
      kill: true,
      error_logger: false,
      include_shared_binaries: true
    })

    with {:ok, entries} <- seed_entries(filesystem) do
      {:ok,
       %{
         filesystem: filesystem,
         entries: entries,
         tombstones: MapSet.new(),
         open_handles: %{},
         write_bytes: %{},
         transactions: %{},
         active_call_ids: MapSet.new(),
         completed_call_ids: MapSet.new(),
         owner_monitors: %{},
         owner_monitor_refs: %{},
         queue_limit: Keyword.get(opts, :request_queue_limit, 1_000),
         pending_request_ids: MapSet.new()
       }}
    else
      {:error, error} -> {:stop, error}
    end
  end

  defp heap_words_for_bytes(bytes) when is_integer(bytes) and bytes > 0,
    do:
      max(1_024, div(bytes + :erlang.system_info(:wordsize) - 1, :erlang.system_info(:wordsize)))

  defp heap_words_for_bytes(_bytes), do: 1_024

  @impl true
  def handle_call({:filesystem_request, request_id, request}, _from, state) do
    case queue_ok?(state) do
      :ok ->
        state = begin_request(state, request_id)
        {reply, state} = safe_apply_request(state, request_id, request)
        state = finish_request(state, request_id)

        {:reply, reply, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:filesystem_task_reply, request_id, _reply}, state) do
    stale_reply(state, request_id)
  end

  def handle_info({:filesystem_task_reply, request_id, _pid, _reply}, state) do
    stale_reply(state, request_id)
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.owner_monitor_refs, ref) do
      {:ok, call_id} ->
        state =
          state
          |> forget_owner_monitor(call_id, ref)
          |> abort_eval_state(call_id)

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp stale_reply(state, request_id) do
    if MapSet.member?(state.pending_request_ids, request_id) do
      {:noreply, finish_request(state, request_id)}
    else
      {:noreply, state}
    end
  end

  defp restore_request_id(:undefined), do: Process.delete(@request_id_key)
  defp restore_request_id(request_id), do: Process.put(@request_id_key, request_id)

  defp safe_apply_request(state, request_id, request) do
    previous_request_id = Process.get(@request_id_key, :undefined)
    Process.put(@request_id_key, request_id)

    try do
      apply_request(state, request_id, request)
    rescue
      exception ->
        log_safe_apply_request_failure(:error, exception, __STACKTRACE__, request_id, request)
        {{:error, :eacces}, state}
    catch
      class, reason ->
        log_safe_apply_request_failure(class, reason, __STACKTRACE__, request_id, request)
        {{:error, :eacces}, state}
    after
      restore_request_id(previous_request_id)
    end
  end

  defp log_safe_apply_request_failure(class, reason, stack, request_id, request) do
    Logger.error(fn ->
      [
        "Hyperlang filesystem request failed; returning eacces",
        " request_id=",
        inspect(request_id),
        " operation=",
        inspect(request_operation(request)),
        " class=",
        inspect(class),
        " reason=",
        Exception.format_banner(class, reason),
        "\n",
        stack |> Enum.take(8) |> Exception.format_stacktrace()
      ]
    end)
  end

  defp request_operation({:eval_request, _call_id, request}), do: request_operation(request)
  defp request_operation({operation, _path}) when is_atom(operation), do: operation
  defp request_operation({operation, _from, _to}) when is_atom(operation), do: operation
  defp request_operation(operation) when is_atom(operation), do: operation
  defp request_operation(_request), do: :unknown

  defp apply_request(state, request_id, :server_info) do
    {{:ok,
      %{
        pid_visible_to_guest: false,
        message_queue_data: elem(Process.info(self(), :message_queue_data), 1),
        max_heap_size: elem(Process.info(self(), :max_heap_size), 1),
        request_queue_limit: state.queue_limit,
        supervisor: Hyperlang.Filesystem.Supervisor,
        open_handle_count: map_size(state.open_handles),
        transaction_count: map_size(state.transactions),
        pending_request_count:
          state.pending_request_ids |> MapSet.delete(request_id) |> MapSet.size()
      }}, state}
  end

  defp apply_request(state, _request_id, :tree) do
    {{:ok, tree_snapshot(state)}, state}
  end

  defp apply_request(state, _request_id, :snapshot) do
    {{:ok,
      %{
        cwd: state.filesystem.cwd,
        tree: tree_snapshot(state),
        diff: current_diff(state)
      }}, state}
  end

  defp apply_request(state, _request_id, :export) do
    case export_state(state) do
      {:ok, exported} -> {{:ok, exported}, state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp apply_request(state, _request_id, {:stale_reply, request_id}) do
    send(self(), {:filesystem_task_reply, request_id, self(), :old})
    {{:ok, :ignored}, state}
  end

  defp apply_request(state, request_id, {:eval_request, call_id, request}) do
    if active_call?(state, call_id) do
      apply_active_eval_request(state, request_id, call_id, request)
    else
      {{:error, :stale_eval_request}, state}
    end
  end

  defp apply_request(state, _request_id, {:begin_eval, call_id}) do
    begin_eval_request(state, call_id, nil)
  end

  defp apply_request(state, _request_id, {:begin_eval, call_id, owner_pid}) do
    begin_eval_request(state, call_id, owner_pid)
  end

  defp apply_request(state, _request_id, {:finish_eval, call_id, outcome}) do
    if active_call?(state, call_id) do
      case finish_transaction(state, call_id, outcome) do
        {:ok, state} -> {{:ok, :ok}, finish_eval_state(state, call_id)}
        {:error, reason, state} -> {{:error, reason}, finish_eval_state(state, call_id)}
      end
    else
      {{:error, :stale_eval_request}, state}
    end
  end

  defp apply_request(state, _request_id, :diff) do
    case pending_manual_transaction(state) do
      {:ok, {_call_id, %{staged: staged} = transaction}} ->
        {{:ok, transaction_diff(transaction.snapshot, staged)}, state}

      :error ->
        {{:ok, %{created: [], modified: [], deleted: []}}, state}
    end
  end

  defp apply_request(state, _request_id, :commit) do
    case pending_manual_transaction(state) do
      {:ok, {call_id, %{staged: staged}}} ->
        transaction = Map.fetch!(state.transactions, call_id)

        case merge_transaction_snapshot(state, transaction.snapshot, staged) do
          {:ok, state} ->
            {{:ok, :ok}, Map.update!(state, :transactions, &Map.delete(&1, call_id))}

          {:error, reason} ->
            {{:error, reason}, Map.update!(state, :transactions, &Map.delete(&1, call_id))}
        end

      :error ->
        {{:ok, :ok}, state}
    end
  end

  defp apply_request(state, _request_id, :rollback) do
    case pending_manual_transaction(state) do
      {:ok, {call_id, _transaction}} ->
        {{:ok, :ok}, Map.update!(state, :transactions, &Map.delete(&1, call_id))}

      :error ->
        {{:ok, :ok}, state}
    end
  end

  defp apply_request(state, _request_id, :get_cwd) do
    {{:ok, state.filesystem.cwd}, state}
  end

  defp apply_request(state, _request_id, :limits) do
    {{:ok, state.filesystem.limits}, state}
  end

  defp apply_request(state, _request_id, {:seed_file, path, content}) do
    seed_file_request(state, path, content)
  end

  defp apply_request(state, _request_id, {:seed_dir, path}) do
    seed_dir_request(state, path)
  end

  defp apply_request(state, _request_id, {:write_limit, path}) do
    with {:ok, resolved} <- resolve_memory(state.filesystem, path, :write_file, :write) do
      {{:ok, resolved.mount.limits.max_single_write_bytes}, state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp apply_request(state, _request_id, {:close_call_handles, call_id}) do
    {{:ok, :ok}, abort_eval_state(state, call_id)}
  end

  defp apply_request(state, _request_id, {:set_cwd, path}) do
    with {:ok, cwd} <- normalize_cwd(state.filesystem, path),
         {:ok, resolved} <- resolve_access(state.filesystem, cwd, :read_file_info, :stat),
         :ok <- require_resolved_dir(state.entries, resolved) do
      {{:ok, :ok}, %{state | filesystem: %{state.filesystem | cwd: cwd}}}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp apply_request(state, _request_id, {:read_file, path}) do
    with {:ok, resolved} <- resolve_access(state.filesystem, path, :read_file, :read),
         {:ok, content} <- read_resolved_file(state.entries, state.tombstones, resolved) do
      {{:ok, content}, state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp apply_request(state, _request_id, {:source_read_file, path}) do
    with {:ok, resolved} <- resolve_source_read(state.filesystem, path),
         {:ok, content} <- read_resolved_file(state.entries, state.tombstones, resolved) do
      {{:ok, content}, state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp apply_request(state, _request_id, {:write_file, path, content}) do
    write_file_request(state, path, content)
  end

  defp apply_request(state, _request_id, {:append_file, path, content}) do
    with {:ok, resolved} <- resolve_memory(state.filesystem, path, :write_file, :write),
         {:ok, delta} <- normalize_write_content(content, resolved.mount.limits),
         {:ok, appended} <- append_content(state.entries, state.tombstones, resolved, delta),
         :ok <- parent_dir_exists(state.entries, state.tombstones, resolved),
         :ok <- ensure_not_dir(state.entries, state.tombstones, resolved),
         :ok <-
           check_file_count(state.entries, resolved.path, resolved.mount, resolved.mount.limits),
         :ok <-
           check_overlay_entry_count(
             state.entries,
             state.tombstones,
             resolved.path,
             resolved.mount,
             resolved.mount.limits
           ),
         :ok <-
           check_total_path_bytes(
             state.entries,
             resolved.path,
             resolved.mount,
             resolved.mount.limits
           ),
         :ok <-
           check_total_memory(
             state.entries,
             state.tombstones,
             resolved.path,
             appended,
             resolved.mount,
             resolved.mount.limits
           ),
         :ok <-
           check_write_budget_bytes(
             state,
             resolved.mount.virtual,
             byte_size(delta),
             resolved.mount.limits
           ) do
      entries =
        Map.put(state.entries, resolved.path, file_entry(appended, 0o644, resolved.mount.virtual))

      tombstones = clear_tombstone(state.tombstones, resolved.path, resolved.mount.virtual)
      write_bytes = bump_write_bytes(state.write_bytes, resolved.mount.virtual, byte_size(delta))

      {{:ok, :ok}, %{state | entries: entries, tombstones: tombstones, write_bytes: write_bytes}}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  rescue
    ArgumentError -> {{:error, :badarg}, state}
  end

  defp apply_request(state, _request_id, {:exclusive_write_file, path, content}) do
    with {:ok, resolved} <- resolve_memory(state.filesystem, path, :write_file, :write),
         {:ok, _content} <- normalize_write_content(content, resolved.mount.limits) do
      stat_reply =
        case stat_resolved_path(state.entries, state.tombstones, resolved) do
          {:ok, stat} -> {:ok, stat}
          {:error, :enoent} -> {:error, :enoent}
          {:error, reason} -> {:error, reason}
        end

      case stat_reply do
        {:ok, _stat} -> {{:error, :eexist}, state}
        {:error, :enoent} -> write_file_request(state, path, content)
        {:error, reason} -> {{:error, reason}, state}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  rescue
    ArgumentError -> {{:error, :badarg}, state}
  end

  defp apply_request(state, _request_id, {:open, path, operation, call_id}) do
    with {:ok, resolved} <-
           resolve_memory(state.filesystem, path, :read_file, open_permission(operation)),
         {:ok, entry} <- open_entry(state.entries, resolved.path, resolved.mount, operation),
         {:ok, entries} <-
           maybe_commit_open_entry(state.entries, resolved.path, entry, resolved.mount, operation),
         {:ok, handle, open_handles} <-
           register_open_handle(
             state.open_handles,
             resolved.path,
             entry,
             resolved.mount,
             operation,
             call_id
           ) do
      {{:ok, handle}, %{state | entries: entries, open_handles: open_handles}}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp apply_request(state, _request_id, {:handle_close, handle, call_id}) do
    with {:ok, id} <- fetch_handle_id(state.open_handles, handle, call_id) do
      {{:ok, :ok}, %{state | open_handles: Map.delete(state.open_handles, id)}}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp apply_request(state, _request_id, {:handle_read, handle, count, call_id}) do
    with {:ok, id} <- fetch_handle_id(state.open_handles, handle, call_id),
         {:ok, open} <- Map.fetch(state.open_handles, id),
         :ok <- readable_handle(open),
         {:ok, count} <- read_count(count),
         {:ok, entry} <- fetch_entry(state.entries, open.path),
         :ok <- not_tombstoned(state.tombstones, open.path),
         :ok <- require_file(entry) do
      available = max(byte_size(entry.content) - open.position, 0)

      if available == 0 do
        {{:ok, :eof}, state}
      else
        size = min(count, available)
        data = binary_part(entry.content, open.position, size)
        open_handles = Map.put(state.open_handles, id, %{open | position: open.position + size})
        {{:ok, data}, %{state | open_handles: open_handles}}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp apply_request(state, _request_id, {:handle_write, handle, content, call_id}) do
    with {:ok, id} <- fetch_handle_id(state.open_handles, handle, call_id),
         {:ok, open} <- Map.fetch(state.open_handles, id),
         :ok <- writable_handle(open),
         {:ok, content} <- normalize_write_content(content, open.limits),
         {:ok, entry} <- fetch_entry(state.entries, open.path),
         :ok <- require_file(entry),
         {:ok, new_content, new_position} <- write_handle_content(entry.content, open, content),
         :ok <-
           check_total_memory(
             state.entries,
             state.tombstones,
             open.path,
             new_content,
             open.mount,
             open.limits
           ),
         :ok <- check_write_budget(state, open.mount.virtual, content, open.limits) do
      entries =
        Map.put(state.entries, open.path, file_entry(new_content, 0o644, open.mount.virtual))

      write_bytes = bump_write_bytes(state.write_bytes, open.mount.virtual, byte_size(content))
      open_handles = Map.put(state.open_handles, id, %{open | position: new_position})

      {{:ok, :ok},
       %{state | entries: entries, write_bytes: write_bytes, open_handles: open_handles}}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp apply_request(state, _request_id, {:handle_write_limit, handle, call_id}) do
    with {:ok, id} <- fetch_handle_id(state.open_handles, handle, call_id),
         {:ok, open} <- Map.fetch(state.open_handles, id),
         :ok <- writable_handle(open) do
      {{:ok, open.limits.max_single_write_bytes}, state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp apply_request(state, _request_id, {:list_dir, path}) do
    with {:ok, resolved} <- resolve_access(state.filesystem, path, :list_dir, :list),
         {:ok, names} <- list_resolved_dir(state.entries, state.tombstones, resolved) do
      {{:ok, names}, state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp apply_request(state, _request_id, {:make_dir, path}) do
    with {:ok, resolved} <- resolve_memory(state.filesystem, path, :make_dir, :mkdir),
         :ok <- entry_absent(state.entries, state.tombstones, resolved),
         :ok <- parent_dir_exists(state.entries, state.tombstones, resolved),
         :ok <-
           check_file_count(state.entries, resolved.path, resolved.mount, resolved.mount.limits),
         :ok <-
           check_overlay_entry_count(
             state.entries,
             state.tombstones,
             resolved.path,
             resolved.mount,
             resolved.mount.limits
           ),
         :ok <-
           check_total_path_bytes(
             state.entries,
             resolved.path,
             resolved.mount,
             resolved.mount.limits
           ),
         :ok <-
           check_total_memory_after_put_entry(
             state.entries,
             state.tombstones,
             resolved.path,
             dir_entry(resolved.mount.virtual),
             resolved.mount,
             resolved.mount.limits
           ) do
      entries = Map.put(state.entries, resolved.path, dir_entry(resolved.mount.virtual))
      tombstones = clear_tombstone(state.tombstones, resolved.path, resolved.mount.virtual)
      {{:ok, :ok}, %{state | entries: entries, tombstones: tombstones}}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp apply_request(state, _request_id, {:ensure_dir, path}) do
    with {:ok, resolved} <- resolve_memory(state.filesystem, path, :make_dir, :mkdir),
         {:ok, entries} <- ensure_dir_path(state.entries, resolved.path, resolved.mount) do
      {{:ok, :ok}, %{state | entries: entries}}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp apply_request(state, _request_id, {:del_dir, path}) do
    with {:ok, resolved} <- resolve_memory(state.filesystem, path, :delete, :delete),
         :ok <- reject_root_mutation(resolved),
         {:ok, entry} <- fetch_entry(state.entries, state.tombstones, resolved),
         :ok <- require_dir(entry),
         :ok <- dir_empty(state.entries, state.tombstones, resolved),
         {:ok, state} <-
           delete_entry_state(state, resolved.path, resolved.mount.virtual, resolved.mount.limits) do
      {{:ok, :ok}, state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp apply_request(state, _request_id, {:delete, path}) do
    with {:ok, resolved} <- resolve_memory(state.filesystem, path, :delete, :delete),
         :ok <- reject_root_mutation(resolved),
         {:ok, entry} <- fetch_entry(state.entries, state.tombstones, resolved),
         :ok <- require_file(entry),
         {:ok, state} <-
           delete_entry_state(state, resolved.path, resolved.mount.virtual, resolved.mount.limits) do
      {{:ok, :ok}, state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp apply_request(state, _request_id, {:stat, path}) do
    with {:ok, resolved} <- resolve_access(state.filesystem, path, :read_file_info, :stat),
         {:ok, stat} <- stat_resolved_path(state.entries, state.tombstones, resolved),
         :ok <- check_stat_result_size(stat, resolved.mount.limits) do
      {{:ok, stat}, state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp apply_request(state, _request_id, {:link_stat, path}) do
    with {:ok, resolved} <- resolve_access(state.filesystem, path, :read_link_info, :lstat),
         {:ok, stat} <- link_stat_resolved_path(state.entries, state.tombstones, resolved),
         :ok <- check_stat_result_size(stat, resolved.mount.limits) do
      {{:ok, stat}, state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp apply_request(state, _request_id, {:rename, from, to}) do
    with {:ok, from_resolved} <- resolve_access(state.filesystem, from, :rename, :rename),
         {:ok, to_resolved} <- resolve_access(state.filesystem, to, :rename, :rename),
         :ok <- same_mount(from_resolved, to_resolved),
         :ok <- entry_backed_mount(from_resolved.mount),
         :ok <- entry_backed_mount(to_resolved.mount),
         :ok <- reject_root_mutation(from_resolved),
         :ok <- reject_root_mutation(to_resolved),
         :ok <- parent_dir_exists(state.entries, state.tombstones, to_resolved),
         {:ok, state, source} <- materialize_rename_source(state, from_resolved),
         :ok <-
           valid_rename_target(
             state.entries,
             state.tombstones,
             source,
             from_resolved.path,
             to_resolved.path
           ),
         :ok <- valid_overlay_rename_target(state.entries, state.tombstones, source, to_resolved),
         :ok <-
           check_total_memory_after_rename(
             state.entries,
             state.tombstones,
             from_resolved.path,
             to_resolved.path,
             from_resolved.mount,
             from_resolved.mount.limits
           ),
         :ok <-
           check_total_path_bytes_after_rename(
             state.entries,
             from_resolved.path,
             to_resolved.path,
             from_resolved.mount,
             from_resolved.mount.limits
           ),
         {:ok, state} <-
           rename_entry_state(
             state,
             from_resolved.path,
             to_resolved.path,
             from_resolved.mount.virtual,
             from_resolved.mount.limits
           ) do
      {{:ok, :ok}, state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp apply_request(state, _request_id, _request) do
    {{:error, :unsupported_filesystem_request}, state}
  end

  defp begin_eval_request(state, call_id, owner_pid) do
    cond do
      active_call?(state, call_id) ->
        begin_eval_call(state, call_id, owner_pid)

      completed_call?(state, call_id) ->
        {{:error, :stale_eval_request}, state}

      true ->
        begin_eval_call(state, call_id, owner_pid)
    end
  end

  defp apply_active_eval_request(state, request_id, call_id, request) do
    case Map.fetch(state.transactions, call_id) do
      {:ok, %{status: :active, staged: staged} = transaction} ->
        staged_state = restore_snapshot(staged, state)
        {reply, staged_state} = safe_apply_request(staged_state, request_id, request)
        transaction = %{transaction | staged: snapshot_state(staged_state)}
        {reply, %{state | transactions: Map.put(state.transactions, call_id, transaction)}}

      _other ->
        if state.filesystem.commit_policy == :per_request do
          safe_apply_request(state, request_id, request)
        else
          {{:error, :stale_eval_request}, state}
        end
    end
  end

  defp begin_eval_call(state, call_id, owner_pid) do
    case begin_transaction(state, call_id) do
      {:ok, state} ->
        state =
          state
          |> activate_call(call_id)
          |> monitor_eval_owner(call_id, owner_pid)

        {{:ok, :ok}, state}

      {:error, reason} ->
        # A lifecycle id is single-use even when admission fails. Otherwise a
        # delayed/replayed begin can become valid after a manual transaction is
        # committed and mutate a later evaluation under stale authority.
        {{:error, reason}, complete_call(state, call_id)}
    end
  end

  defp finish_eval_state(state, call_id) do
    state
    |> close_call_handles_state(call_id)
    |> deactivate_call(call_id)
    |> demonitor_eval_owner(call_id)
    |> complete_call(call_id)
  end

  defp abort_eval_state(state, call_id) do
    case Map.fetch(state.transactions, call_id) do
      {:ok, %{status: :active}} ->
        case finish_transaction(state, call_id, :failure) do
          {:ok, state} -> finish_eval_state(state, call_id)
          {:error, _reason, state} -> finish_eval_state(state, call_id)
        end

      _other ->
        finish_eval_state(state, call_id)
    end
  end

  defp close_call_handles_state(state, call_id) do
    handles =
      Map.reject(state.open_handles, fn {_id, handle} ->
        handle.call_id == call_id
      end)

    Hyperlang.Filesystem.release_guest_handles(call_id)

    %{state | open_handles: handles}
  end

  defp write_file_request(state, path, content) do
    with {:ok, resolved} <- resolve_memory(state.filesystem, path, :write_file, :write),
         {:ok, content} <- normalize_write_content(content, resolved.mount.limits),
         :ok <- parent_dir_exists(state.entries, state.tombstones, resolved),
         :ok <- ensure_not_dir(state.entries, state.tombstones, resolved),
         :ok <-
           check_file_count(state.entries, resolved.path, resolved.mount, resolved.mount.limits),
         :ok <-
           check_overlay_entry_count(
             state.entries,
             state.tombstones,
             resolved.path,
             resolved.mount,
             resolved.mount.limits
           ),
         :ok <-
           check_total_path_bytes(
             state.entries,
             resolved.path,
             resolved.mount,
             resolved.mount.limits
           ),
         :ok <-
           check_total_memory(
             state.entries,
             state.tombstones,
             resolved.path,
             content,
             resolved.mount,
             resolved.mount.limits
           ),
         :ok <- check_write_budget(state, resolved.mount.virtual, content, resolved.mount.limits) do
      entries =
        Map.put(
          state.entries,
          resolved.path,
          file_entry(content, 0o644, resolved.mount.virtual)
        )

      tombstones = clear_tombstone(state.tombstones, resolved.path, resolved.mount.virtual)

      write_bytes =
        bump_write_bytes(state.write_bytes, resolved.mount.virtual, byte_size(content))

      {{:ok, :ok}, %{state | entries: entries, tombstones: tombstones, write_bytes: write_bytes}}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp seed_file_request(state, path, content) do
    with {:ok, resolved} <- resolve_entry_backed(state.filesystem, path),
         {:ok, content} <- normalize_write_content(content, resolved.mount.limits),
         {:ok, entries} <-
           ensure_dir_path(state.entries, Path.dirname(resolved.path), resolved.mount),
         :ok <- ensure_not_dir(entries, state.tombstones, resolved) do
      entries =
        Map.put(entries, resolved.path, file_entry(content, 0o644, resolved.mount.virtual))

      tombstones = clear_tombstone(state.tombstones, resolved.path, resolved.mount.virtual)

      case check_mount_limits(entries, tombstones, state.write_bytes, resolved.mount) do
        :ok -> {{:ok, :ok}, %{state | entries: entries, tombstones: tombstones}}
        {:error, reason} -> {{:error, reason}, state}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp seed_dir_request(state, path) do
    with {:ok, resolved} <- resolve_entry_backed(state.filesystem, path),
         {:ok, entries} <- ensure_dir_path(state.entries, resolved.path, resolved.mount) do
      tombstones = clear_tombstone(state.tombstones, resolved.path, resolved.mount.virtual)

      case check_mount_limits(entries, tombstones, state.write_bytes, resolved.mount) do
        :ok -> {{:ok, :ok}, %{state | entries: entries, tombstones: tombstones}}
        {:error, reason} -> {{:error, reason}, state}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp seed_entries(filesystem) do
    filesystem.mounts
    |> Enum.reduce_while({:ok, %{"/" => dir_entry("/")}}, fn mount, {:ok, entries} ->
      with {:ok, entries} <- seed_mount(filesystem, mount, entries) do
        {:cont, {:ok, entries}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp seed_mount(filesystem, %{backend: :memory} = mount, entries) do
    with :ok <- check_mount_root_path_bytes(entries, mount.virtual, mount, mount.limits),
         entries <- Map.put(entries, mount.virtual, dir_entry(mount.virtual)),
         {:ok, entries} <- seed_dirs(filesystem, mount, entries),
         {:ok, entries} <- seed_files(filesystem, mount, entries),
         {:ok, entries} <- seed_symlinks(filesystem, mount, entries) do
      {:ok, entries}
    end
  end

  defp seed_mount(
         _filesystem,
         %{backend: {:host, host_root}, mode: :snapshot} = mount,
         entries
       ) do
    with :ok <- check_mount_root_path_bytes(entries, mount.virtual, mount, mount.limits),
         entries <- Map.put(entries, mount.virtual, dir_entry(mount.virtual)),
         {:ok, entries} <- snapshot_host_dir(host_root, mount.virtual, mount, entries) do
      {:ok, entries}
    end
  end

  defp seed_mount(_filesystem, %{backend: {:host, _host_root}, mode: :overlay} = mount, entries) do
    with :ok <- check_mount_root_path_bytes(entries, mount.virtual, mount, mount.limits) do
      {:ok, Map.put(entries, mount.virtual, dir_entry(mount.virtual))}
    end
  end

  defp seed_mount(_filesystem, _mount, entries), do: {:ok, entries}

  defp seed_dirs(filesystem, mount, entries) do
    mount.seed.dirs
    |> Enum.reduce_while({:ok, entries}, fn path, {:ok, entries} ->
      with {:ok, resolved} <-
             resolve_memory(filesystem, path, :make_dir, :mkdir, skip_allow: true),
           :ok <- ensure_mount(resolved, mount),
           :ok <- seed_parent_dir_exists(entries, resolved.path),
           :ok <- check_file_count(entries, resolved.path, mount, mount.limits),
           :ok <- check_total_path_bytes(entries, resolved.path, mount, mount.limits),
           {:ok, entries} <- put_seed_dir(entries, resolved.path) do
        {:cont, {:ok, entries}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp seed_files(filesystem, mount, entries) do
    mount.seed.files
    |> Enum.reduce_while({:ok, entries}, fn seed, {:ok, entries} ->
      with {:ok, resolved} <-
             resolve_memory(filesystem, seed.path, :write_file, :write, skip_allow: true),
           :ok <- ensure_mount(resolved, mount),
           :ok <- seed_parent_dir_exists(entries, resolved.path),
           :ok <- entry_absent(entries, resolved.path),
           :ok <- check_file_count(entries, resolved.path, mount, mount.limits),
           :ok <- check_total_path_bytes(entries, resolved.path, mount, mount.limits),
           :ok <- check_total_memory(entries, resolved.path, seed.content, mount, mount.limits) do
        entry = file_entry(seed.content, seed.mode, mount.virtual)
        {:cont, {:ok, Map.put(entries, resolved.path, entry)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp seed_symlinks(filesystem, mount, entries) do
    mount.seed.symlinks
    |> Enum.reduce_while({:ok, entries}, fn seed, {:ok, entries} ->
      with {:ok, resolved} <-
             resolve_memory(filesystem, seed.path, :make_dir, :mkdir, skip_allow: true),
           :ok <- ensure_mount(resolved, mount),
           :ok <- seed_parent_dir_exists(entries, resolved.path),
           :ok <- entry_absent(entries, resolved.path),
           :ok <- check_file_count(entries, resolved.path, mount, mount.limits),
           :ok <- check_total_path_bytes(entries, resolved.path, mount, mount.limits) do
        entry = symlink_entry(seed.target, seed.escape, mount.virtual)
        {:cont, {:ok, Map.put(entries, resolved.path, entry)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp snapshot_host_dir(host_dir, virtual_dir, mount, entries) do
    with {:ok, names} <- host_list_names_at_path(host_dir, mount) do
      names
      |> Enum.reduce_while({:ok, entries}, fn name, {:ok, entries} ->
        host_path = Path.join(host_dir, name)
        virtual_path = virtual_child_path(virtual_dir, name)

        with {:ok, entries} <- snapshot_host_entry(host_path, virtual_path, mount, entries) do
          {:cont, {:ok, entries}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp snapshot_host_entry(host_path, virtual_path, mount, entries) do
    with {:ok, stat} <- host_lstat(host_path, mount) do
      case stat.type do
        :directory ->
          with :ok <- check_file_count(entries, virtual_path, mount, mount.limits),
               :ok <- check_total_path_bytes(entries, virtual_path, mount, mount.limits),
               entries <- Map.put(entries, virtual_path, dir_entry(mount.virtual)) do
            snapshot_host_dir(host_path, virtual_path, mount, entries)
          end

        :regular ->
          with {:ok, content} <- host_read_limited(host_path, mount),
               :ok <- check_file_count(entries, virtual_path, mount, mount.limits),
               :ok <- check_total_path_bytes(entries, virtual_path, mount, mount.limits),
               :ok <- check_total_memory(entries, virtual_path, content, mount, mount.limits) do
            entry = file_entry(content, OtpFacade.safe_permission_mode(stat.mode), mount.virtual)
            {:ok, Map.put(entries, virtual_path, entry)}
          end

        :symlink ->
          with :ok <- check_file_count(entries, virtual_path, mount, mount.limits),
               :ok <- check_total_path_bytes(entries, virtual_path, mount, mount.limits),
               {:ok, entry} <- host_symlink_entry(host_path, mount) do
            {:ok, Map.put(entries, virtual_path, entry)}
          end
      end
    end
  end

  defp virtual_child_path("/", name), do: "/" <> name
  defp virtual_child_path(parent, name), do: parent <> "/" <> name

  defp resolve_memory(filesystem, path, resolver_operation, permission, opts \\ []) do
    with {:ok, resolved} <- resolve_access(filesystem, path, resolver_operation, permission, opts),
         :ok <- entry_backed_mount(resolved.mount) do
      {:ok, resolved}
    end
  end

  defp resolve_access(filesystem, path, resolver_operation, permission, opts \\ []) do
    with {:ok, resolver_mode} <- Filesystem.resolver_mode_for(resolver_operation),
         {:ok, resolved} <- Filesystem.authorize(filesystem, path, permission, opts) do
      {:ok,
       resolved
       |> Map.put(:resolver_mode, resolver_mode)
       |> Map.put(:filesystem, filesystem)}
    else
      {:error, %{category: :filesystem} = error} -> {:error, filesystem_error_reason(error)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp entry_backed_mount(%{backend: :memory}), do: :ok
  defp entry_backed_mount(%{mode: :snapshot}), do: :ok
  defp entry_backed_mount(%{mode: :overlay, overlay: :memory}), do: :ok
  defp entry_backed_mount(_mount), do: {:error, :enotsup}

  defp resolve_entry_backed(filesystem, path) do
    with {:ok, resolved} <- Hyperlang.Filesystem.resolve_mount(filesystem, path),
         :ok <- entry_backed_mount(resolved.mount) do
      {:ok, resolved}
    else
      {:error, %{category: :filesystem} = error} -> {:error, filesystem_error_reason(error)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_source_read(filesystem, path) do
    with {:ok, resolved} <- Hyperlang.Filesystem.authorize_source_compile_read(filesystem, path) do
      {:ok, resolved}
    else
      {:error, %{category: :filesystem} = error} -> {:error, filesystem_error_reason(error)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_resolved_file(entries, tombstones, %{mount: %{backend: :memory} = mount, path: path}) do
    with {:ok, entry} <- fetch_entry(entries, path),
         :ok <- not_tombstoned(tombstones, path),
         :ok <- require_file(entry),
         :ok <- check_read_size(entry.content, mount.limits) do
      {:ok, entry.content}
    end
  end

  defp read_resolved_file(entries, tombstones, %{
         mount: %{mode: :snapshot} = mount,
         path: path
       }) do
    with {:ok, entry} <- fetch_entry(entries, path),
         :ok <- not_tombstoned(tombstones, path),
         :ok <- require_file(entry),
         :ok <- check_read_size(entry.content, mount.limits) do
      {:ok, entry.content}
    end
  end

  defp read_resolved_file(entries, tombstones, %{mount: %{mode: :overlay}} = resolved) do
    case fetch_entry(entries, resolved.path) do
      {:ok, entry} ->
        with :ok <- not_tombstoned(tombstones, resolved.path),
             :ok <- require_file(entry),
             :ok <- check_read_size(entry.content, resolved.mount.limits) do
          {:ok, entry.content}
        end

      {:error, :enoent} ->
        with :ok <- not_tombstoned(tombstones, resolved.path) do
          read_host_overlay_file(resolved)
        end
    end
  end

  defp read_resolved_file(
         _entries,
         _tombstones,
         %{mount: %{backend: {:host, _root}} = mount} = resolved
       ) do
    host_read(resolved, mount)
  end

  defp read_resolved_file(_entries, _tombstones, _resolved), do: {:error, :enotsup}

  defp list_resolved_dir(entries, tombstones, %{mount: %{backend: :memory} = mount, path: path}) do
    with {:ok, entry} <- fetch_entry(entries, path),
         :ok <- not_tombstoned(tombstones, path),
         :ok <- require_dir(entry),
         {:ok, names} <- list_names(entries, tombstones, path, mount.limits) do
      {:ok, names}
    end
  end

  defp list_resolved_dir(entries, tombstones, %{
         mount: %{mode: :snapshot} = mount,
         path: path
       }) do
    with {:ok, entry} <- fetch_entry(entries, path),
         :ok <- not_tombstoned(tombstones, path),
         :ok <- require_dir(entry),
         {:ok, names} <- list_names(entries, tombstones, path, mount.limits) do
      {:ok, names}
    end
  end

  defp list_resolved_dir(entries, tombstones, %{mount: %{mode: :overlay}} = resolved) do
    with :ok <- require_overlay_dir(entries, tombstones, resolved),
         {:ok, names} <- overlay_list_names(entries, tombstones, resolved) do
      {:ok, names}
    end
  end

  defp list_resolved_dir(
         _entries,
         _tombstones,
         %{mount: %{backend: {:host, _root}} = mount} = resolved
       ) do
    with {:ok, stat} <- host_stat(resolved),
         :ok <- require_host_dir(stat),
         {:ok, names} <- host_list_names(resolved, mount) do
      {:ok, names}
    end
  end

  defp list_resolved_dir(_entries, _tombstones, _resolved), do: {:error, :enotsup}

  defp stat_resolved_path(entries, tombstones, %{mount: %{backend: :memory}} = resolved) do
    stat_follow_path(entries, tombstones, resolved, 0)
  end

  defp stat_resolved_path(entries, tombstones, %{mount: %{mode: :snapshot}} = resolved) do
    stat_follow_path(entries, tombstones, resolved, 0)
  end

  defp stat_resolved_path(entries, tombstones, %{mount: %{mode: :overlay}} = resolved) do
    stat_follow_path(entries, tombstones, resolved, 0)
  end

  defp stat_resolved_path(_entries, _tombstones, %{mount: %{backend: {:host, _root}}} = resolved) do
    with {:ok, entry} <- host_stat_entry(resolved, :stat) do
      {:ok, entry}
    end
  end

  defp stat_resolved_path(_entries, _tombstones, _resolved), do: {:error, :enotsup}

  defp stat_follow_path(_entries, _tombstones, _resolved, depth) when depth > 32,
    do: {:error, :eacces}

  defp stat_follow_path(entries, tombstones, %{mount: %{mode: :overlay}} = resolved, depth) do
    case fetch_entry(entries, resolved.path) do
      {:ok, entry} ->
        with :ok <- not_tombstoned(tombstones, resolved.path) do
          stat_follow_entry(entries, tombstones, entry, resolved, depth)
        end

      {:error, :enoent} ->
        with :ok <- not_tombstoned(tombstones, resolved.path) do
          stat_host_overlay_path(resolved)
        end
    end
  end

  defp stat_follow_path(
         _entries,
         _tombstones,
         %{mount: %{backend: {:host, _root}}} = resolved,
         _depth
       ) do
    with {:ok, entry} <- host_stat_entry(resolved, :stat) do
      {:ok, entry}
    end
  end

  defp stat_follow_path(entries, tombstones, %{path: path} = resolved, depth) do
    with {:ok, entry} <- fetch_entry(entries, path),
         :ok <- not_tombstoned(tombstones, path) do
      stat_follow_entry(entries, tombstones, entry, resolved, depth)
    end
  end

  defp stat_follow_entry(entries, tombstones, %{type: :symlink} = entry, resolved, depth) do
    with {:ok, target} <- symlink_target_path(entry, resolved),
         {:ok, target_resolved} <- resolve_symlink_target(resolved, target) do
      stat_follow_path(entries, tombstones, target_resolved, depth + 1)
    end
  end

  defp stat_follow_entry(_entries, _tombstones, entry, _resolved, _depth) do
    {:ok, stat_entry(entry)}
  end

  defp symlink_target_path(%{type: :symlink, escape: true}, _resolved), do: {:error, :eacces}

  defp symlink_target_path(%{type: :symlink, target: target}, _resolved)
       when not is_binary(target),
       do: {:error, :eacces}

  defp symlink_target_path(%{type: :symlink, target: target}, %{mount: %{virtual: root}}) do
    if Filesystem.mount_matches?(root, target), do: {:ok, target}, else: {:error, :eacces}
  end

  defp resolve_symlink_target(%{filesystem: filesystem}, target) do
    resolve_access(filesystem, target, :read_file_info, :stat)
  end

  defp resolve_symlink_target(resolved, target), do: {:ok, resolved_at(resolved, target)}

  defp link_stat_resolved_path(entries, tombstones, %{
         mount: %{backend: :memory},
         path: path
       }) do
    with {:ok, entry} <- fetch_entry(entries, path),
         :ok <- not_tombstoned(tombstones, path) do
      {:ok, stat_entry(entry)}
    end
  end

  defp link_stat_resolved_path(entries, tombstones, %{
         mount: %{mode: :snapshot},
         path: path
       }) do
    with {:ok, entry} <- fetch_entry(entries, path),
         :ok <- not_tombstoned(tombstones, path) do
      {:ok, stat_entry(entry)}
    end
  end

  defp link_stat_resolved_path(entries, tombstones, %{mount: %{mode: :overlay}} = resolved) do
    case fetch_entry(entries, resolved.path) do
      {:ok, entry} ->
        with :ok <- not_tombstoned(tombstones, resolved.path) do
          {:ok, stat_entry(entry)}
        end

      {:error, :enoent} ->
        with :ok <- not_tombstoned(tombstones, resolved.path) do
          link_stat_host_overlay_path(resolved)
        end
    end
  end

  defp link_stat_resolved_path(
         _entries,
         _tombstones,
         %{mount: %{backend: {:host, _root}}} = resolved
       ) do
    with {:ok, entry} <- host_stat_entry(resolved, :lstat) do
      {:ok, entry}
    end
  end

  defp link_stat_resolved_path(_entries, _tombstones, _resolved), do: {:error, :enotsup}

  defp require_resolved_dir(entries, %{mount: %{backend: :memory}, path: path}) do
    with {:ok, entry} <- fetch_entry(entries, path) do
      require_dir(entry)
    end
  end

  defp require_resolved_dir(entries, %{mount: %{mode: :snapshot}, path: path}) do
    with {:ok, entry} <- fetch_entry(entries, path) do
      require_dir(entry)
    end
  end

  defp require_resolved_dir(entries, %{mount: %{mode: :overlay}, path: path}) do
    with {:ok, entry} <- fetch_entry(entries, path) do
      require_dir(entry)
    end
  end

  defp require_resolved_dir(_entries, %{mount: %{backend: {:host, _root}}} = resolved) do
    with {:ok, stat} <- host_stat(resolved) do
      require_host_dir(stat)
    end
  end

  defp require_resolved_dir(_entries, _resolved), do: {:error, :enotsup}

  defp read_host_overlay_file(%{mount: mount} = resolved) do
    host_overlay_read(resolved, mount)
  end

  defp stat_host_overlay_path(resolved) do
    with {:ok, stat} <- host_lstat(resolved),
         :ok <- reject_host_symlink(stat),
         {:ok, entry} <- host_stat_entry(stat) do
      {:ok, entry}
    end
  end

  defp link_stat_host_overlay_path(resolved) do
    with {:ok, entry} <- host_stat_entry(resolved, :lstat) do
      {:ok, entry}
    end
  end

  defp host_overlay_type_entry(%{mount: %{mode: :overlay} = mount} = resolved) do
    with {:ok, stat} <- host_lstat(resolved) do
      case stat.type do
        :regular ->
          {:ok, file_entry(<<>>, OtpFacade.safe_permission_mode(stat.mode), mount.virtual)}

        :directory ->
          {:ok, dir_entry(mount.virtual)}

        :symlink ->
          host_symlink_entry(resolved)
      end
    end
  end

  defp host_overlay_type_entry(_resolved), do: {:error, :enoent}

  defp resolved_at(%{mount: %{virtual: root}} = resolved, path) do
    %{resolved | path: path, relative_path: Filesystem.relative_path(root, path)}
  end

  defp require_overlay_dir(entries, tombstones, %{path: path} = resolved) do
    case fetch_entry(entries, path) do
      {:ok, entry} ->
        with :ok <- not_tombstoned(tombstones, path) do
          require_dir(entry)
        end

      {:error, :enoent} ->
        with :ok <- not_tombstoned(tombstones, path),
             {:ok, stat} <- host_lstat(resolved),
             :ok <- reject_host_symlink(stat) do
          require_host_dir(stat)
        end
    end
  end

  defp overlay_list_names(entries, tombstones, %{mount: mount, path: path} = resolved) do
    overlay_names = direct_visible_child_names(entries, tombstones, path)

    host_names =
      case host_list_overlay_names(resolved) do
        {:ok, names} -> names
        {:error, :enoent} -> []
        {:error, :eacces} -> []
        {:error, _reason} -> []
      end

    hidden = tombstoned_direct_child_names(tombstones, path)

    names =
      host_names
      |> Enum.reject(&MapSet.member?(hidden, &1))
      |> Kernel.++(overlay_names)
      |> Enum.uniq()
      |> Enum.sort()

    result_bytes = Enum.reduce(names, 0, fn name, acc -> acc + byte_size(name) end)

    cond do
      length(names) > mount.limits.max_dir_entries -> {:error, :eoverflow}
      result_bytes > mount.limits.max_dir_result_bytes -> {:error, :eoverflow}
      true -> {:ok, names}
    end
  end

  defp host_list_overlay_names(%{mount: mount} = resolved) do
    with {:ok, stat} <- host_lstat(resolved),
         :ok <- reject_host_symlink(stat),
         :ok <- require_host_dir(stat),
         {:ok, names} <- host_list_names(resolved, mount) do
      {:ok, names}
    end
  end

  defp normalize_cwd(filesystem, path) do
    case Hyperlang.Filesystem.set_cwd(filesystem, path) do
      {:ok, updated} -> {:ok, updated.cwd}
      {:error, %{category: :filesystem} = error} -> {:error, filesystem_error_reason(error)}
    end
  end

  # Confinement and permission failures carry their POSIX reason atom; the
  # server never classifies them by reading the message prose.
  defp filesystem_error_reason(%{details: %{reason: reason}}) when is_atom(reason), do: reason

  defp open_permission(%{read: true, write: false}), do: :read
  defp open_permission(%{write: true}), do: :write
  defp open_permission(_operation), do: :read

  defp open_entry(entries, path, _mount, %{read: true, write: false}) do
    with {:ok, entry} <- fetch_entry(entries, path),
         :ok <- require_file(entry) do
      {:ok, entry}
    end
  end

  defp open_entry(entries, path, mount, %{write: true, exclusive: true} = operation) do
    cond do
      Map.has_key?(entries, path) ->
        {:error, :eexist}

      true ->
        create_open_entry(entries, path, mount, operation)
    end
  end

  defp open_entry(entries, path, mount, %{write: true, append: true} = operation) do
    case Map.fetch(entries, path) do
      {:ok, entry} ->
        with :ok <- require_file(entry), do: {:ok, entry}

      :error ->
        create_open_entry(entries, path, mount, operation)
    end
  end

  defp open_entry(entries, path, mount, %{write: true, read: true} = operation) do
    case Map.fetch(entries, path) do
      {:ok, entry} ->
        with :ok <- require_file(entry), do: {:ok, entry}

      :error ->
        create_open_entry(entries, path, mount, operation)
    end
  end

  defp open_entry(entries, path, mount, %{write: true} = operation) do
    case Map.fetch(entries, path) do
      {:ok, %{type: :dir}} ->
        {:error, :eisdir}

      _ ->
        create_open_entry(entries, path, mount, operation)
    end
  end

  defp create_open_entry(entries, path, mount, _operation) do
    with :ok <- parent_dir_exists(entries, path),
         :ok <- ensure_not_dir(entries, path),
         :ok <- check_file_count(entries, path, mount, mount.limits),
         :ok <- check_total_path_bytes(entries, path, mount, mount.limits),
         :ok <- check_total_memory(entries, path, <<>>, mount, mount.limits) do
      {:ok, file_entry(<<>>, 0o644, mount.virtual)}
    end
  end

  defp maybe_commit_open_entry(entries, path, _entry, mount, %{
         write: true,
         read: false,
         append: false
       }) do
    entry = file_entry(<<>>, 0o644, mount.virtual)
    {:ok, Map.put(entries, path, entry)}
  end

  defp maybe_commit_open_entry(entries, path, entry, _mount, %{write: true}) do
    {:ok, Map.put(entries, path, entry)}
  end

  defp maybe_commit_open_entry(entries, _path, _entry, _mount, _operation), do: {:ok, entries}

  defp register_open_handle(open_handles, path, entry, mount, operation, call_id) do
    handle = Hyperlang.Filesystem.make_guest_handle(call_id)

    open = %{
      id: handle,
      call_id: call_id,
      path: path,
      read: operation.read,
      write: operation.write,
      append: operation.append,
      position: if(operation.append, do: stat_entry(entry).size, else: 0),
      mount: mount,
      limits: mount.limits
    }

    {:ok, handle, Map.put(open_handles, handle, open)}
  end

  defp fetch_handle_id(open_handles, handle, call_id) do
    with true <- Hyperlang.Filesystem.guest_handle?(handle),
         {:ok, open} <- Map.fetch(open_handles, handle),
         true <- open.call_id == call_id do
      {:ok, handle}
    else
      false -> {:error, :ebadf}
      :error -> {:error, :ebadf}
      _ -> {:error, :badarg}
    end
  end

  defp readable_handle(%{read: true}), do: :ok
  defp readable_handle(_open), do: {:error, :ebadf}

  defp writable_handle(%{write: true}), do: :ok
  defp writable_handle(_open), do: {:error, :ebadf}

  defp read_count(count) when is_integer(count) and count >= 0, do: {:ok, count}
  defp read_count(_count), do: {:error, :badarg}

  defp write_handle_content(existing, %{append: true}, content) do
    new = existing <> content
    {:ok, new, byte_size(new)}
  end

  defp write_handle_content(existing, %{position: position}, content)
       when is_integer(position) and position >= 0 do
    size = byte_size(existing)
    content_size = byte_size(content)

    prefix =
      if position <= size do
        binary_part(existing, 0, position)
      else
        existing <> :binary.copy(<<0>>, position - size)
      end

    suffix_start = min(position + content_size, size)
    suffix_size = max(size - suffix_start, 0)
    suffix = binary_part(existing, suffix_start, suffix_size)

    {:ok, prefix <> content <> suffix, position + content_size}
  end

  defp write_handle_content(_existing, _open, _content), do: {:error, :badarg}

  defp ensure_mount(%{mount: %{virtual: virtual}}, %{virtual: virtual}), do: :ok
  defp ensure_mount(_resolved, _mount), do: {:error, :exdev}

  defp queue_ok?(state) do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, size} when size > state.queue_limit ->
        {:error, :filesystem_queue_limit}

      _ ->
        :ok
    end
  end

  defp begin_request(state, request_id) do
    %{state | pending_request_ids: MapSet.put(state.pending_request_ids, request_id)}
  end

  defp finish_request(state, request_id) do
    %{state | pending_request_ids: MapSet.delete(state.pending_request_ids, request_id)}
  end

  defp begin_transaction(%{filesystem: %{commit_policy: :per_request}} = state, _call_id),
    do: {:ok, state}

  defp begin_transaction(state, call_id) do
    cond do
      Map.has_key?(state.transactions, call_id) ->
        {:ok, state}

      state.filesystem.commit_policy == :manual and pending_manual_transaction(state) != :error ->
        {:error, :manual_commit_pending}

      true ->
        snapshot = snapshot_state(state)

        transaction = %{
          status: :active,
          snapshot: snapshot,
          staged: snapshot
        }

        {:ok, %{state | transactions: Map.put(state.transactions, call_id, transaction)}}
    end
  end

  defp active_call?(state, call_id),
    do: MapSet.member?(Map.get(state, :active_call_ids, MapSet.new()), call_id)

  defp completed_call?(state, call_id),
    do: MapSet.member?(Map.get(state, :completed_call_ids, MapSet.new()), call_id)

  defp activate_call(state, call_id) do
    Map.update(state, :active_call_ids, MapSet.new([call_id]), &MapSet.put(&1, call_id))
  end

  defp deactivate_call(state, call_id) do
    Map.update(state, :active_call_ids, MapSet.new(), &MapSet.delete(&1, call_id))
  end

  defp complete_call(state, call_id) do
    Map.update(state, :completed_call_ids, MapSet.new([call_id]), &MapSet.put(&1, call_id))
  end

  defp monitor_eval_owner(state, call_id, owner_pid) when is_pid(owner_pid) do
    if Map.has_key?(state.owner_monitors, call_id) do
      state
    else
      ref = Process.monitor(owner_pid)

      %{
        state
        | owner_monitors: Map.put(state.owner_monitors, call_id, ref),
          owner_monitor_refs: Map.put(state.owner_monitor_refs, ref, call_id)
      }
    end
  end

  defp monitor_eval_owner(state, _call_id, _owner_pid), do: state

  defp demonitor_eval_owner(state, call_id) do
    case Map.fetch(state.owner_monitors, call_id) do
      {:ok, ref} ->
        Process.demonitor(ref, [:flush])
        forget_owner_monitor(state, call_id, ref)

      :error ->
        state
    end
  end

  defp forget_owner_monitor(state, call_id, ref) do
    %{
      state
      | owner_monitors: Map.delete(state.owner_monitors, call_id),
        owner_monitor_refs: Map.delete(state.owner_monitor_refs, ref)
    }
  end

  defp finish_transaction(
         %{filesystem: %{commit_policy: :per_request}} = state,
         _call_id,
         _outcome
       ),
       do: {:ok, state}

  defp finish_transaction(state, call_id, outcome) do
    case Map.fetch(state.transactions, call_id) do
      {:ok, transaction} ->
        do_finish_transaction(state, call_id, transaction, outcome)

      :error ->
        {:ok, state}
    end
  end

  defp do_finish_transaction(
         %{filesystem: %{commit_policy: :on_eval_success}} = state,
         call_id,
         transaction,
         :success
       ) do
    staged = close_snapshot_handles(transaction.staged, call_id)

    case merge_transaction_snapshot(state, transaction.snapshot, staged) do
      {:ok, state} ->
        {:ok, Map.update!(state, :transactions, &Map.delete(&1, call_id))}

      {:error, reason} ->
        {:error, reason, Map.update!(state, :transactions, &Map.delete(&1, call_id))}
    end
  end

  defp do_finish_transaction(
         %{filesystem: %{commit_policy: :on_eval_success}} = state,
         call_id,
         _transaction,
         _outcome
       ) do
    {:ok, Map.update!(state, :transactions, &Map.delete(&1, call_id))}
  end

  defp do_finish_transaction(
         %{filesystem: %{commit_policy: :manual}} = state,
         call_id,
         transaction,
         :success
       ) do
    staged = transaction.staged |> close_snapshot_handles(call_id)

    transaction =
      transaction
      |> Map.put(:status, :pending_manual)
      |> Map.put(:staged, staged)

    {:ok, Map.update!(state, :transactions, &Map.put(&1, call_id, transaction))}
  end

  defp do_finish_transaction(
         %{filesystem: %{commit_policy: :manual}} = state,
         call_id,
         _transaction,
         _outcome
       ) do
    {:ok, Map.update!(state, :transactions, &Map.delete(&1, call_id))}
  end

  defp do_finish_transaction(state, _call_id, _transaction, _outcome), do: {:ok, state}

  defp snapshot_state(state) do
    %{
      filesystem: state.filesystem,
      entries: state.entries,
      tombstones: state.tombstones,
      open_handles: state.open_handles,
      write_bytes: state.write_bytes
    }
  end

  defp restore_snapshot(snapshot, state) do
    %{
      state
      | filesystem: snapshot.filesystem,
        entries: snapshot.entries,
        tombstones: snapshot.tombstones,
        open_handles: snapshot.open_handles,
        write_bytes: snapshot.write_bytes
    }
  end

  defp close_snapshot_handles(snapshot, call_id) do
    handles =
      Map.reject(snapshot.open_handles, fn {_id, handle} ->
        handle.call_id == call_id
      end)

    %{snapshot | open_handles: handles}
  end

  defp tree_snapshot(state) do
    state.entries
    |> Enum.reject(fn {path, _entry} -> MapSet.member?(state.tombstones, path) end)
    |> Enum.map(fn {path, entry} ->
      case entry do
        %{type: :dir} ->
          {path, %{type: :dir}}

        %{type: :file, content: content, mode: mode} ->
          {path, %{type: :file, size: byte_size(content), mode: mode}}

        %{type: :symlink, target: target, mode: mode} ->
          {path, %{type: :symlink, size: byte_size(target || ""), mode: mode}}
      end
    end)
    |> Map.new()
  end

  defp current_diff(state) do
    case pending_manual_transaction(state) do
      {:ok, {_call_id, %{staged: staged} = transaction}} ->
        transaction_diff(transaction.snapshot, staged)

      :error ->
        %{created: [], modified: [], deleted: []}
    end
  end

  defp export_state(state) do
    Enum.reduce_while(state.filesystem.mounts, {:ok, empty_export()}, fn mount, {:ok, acc} ->
      case export_path(state, mount.virtual, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, export} ->
        {:ok,
         %{
           directories: export.directories |> MapSet.to_list() |> Enum.sort(),
           files: Enum.sort_by(export.files, & &1.path)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp empty_export, do: %{directories: MapSet.new(), files: []}

  defp export_path(state, path, acc) do
    with {:ok, resolved} <-
           Hyperlang.Filesystem.resolve_operation(state.filesystem, path, :read_file_info),
         {:ok, stat} <- stat_resolved_path(state.entries, state.tombstones, resolved) do
      case stat.type do
        :directory ->
          with {:ok, names} <- list_resolved_dir(state.entries, state.tombstones, resolved) do
            acc = %{acc | directories: MapSet.put(acc.directories, path)}

            Enum.reduce_while(names, {:ok, acc}, fn name, {:ok, acc} ->
              child = virtual_child_path(path, name)

              case export_path(state, child, acc) do
                {:ok, acc} -> {:cont, {:ok, acc}}
                {:error, reason} -> {:halt, {:error, reason}}
              end
            end)
          end

        :regular ->
          with {:ok, content} <- read_resolved_file(state.entries, state.tombstones, resolved) do
            {:ok,
             %{
               acc
               | files: [
                   %{path: path, content: content, mode: stat.mode, size: byte_size(content)}
                   | acc.files
                 ]
             }}
          end

        _other ->
          {:ok, acc}
      end
    else
      {:error, :enoent} -> {:ok, acc}
      {:error, reason} -> {:error, reason}
    end
  end

  defp merge_transaction_snapshot(state, snapshot, staged) do
    state =
      state
      |> Map.put(:filesystem, staged.filesystem)
      |> merge_entries(snapshot.entries, staged.entries)
      |> merge_tombstones(snapshot.tombstones, staged.tombstones)
      |> merge_write_bytes(snapshot.write_bytes, staged.write_bytes)

    case check_all_mount_limits(
           state.entries,
           state.tombstones,
           state.write_bytes,
           state.filesystem
         ) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp merge_entries(state, before_entries, after_entries) do
    removed_paths =
      before_entries
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.difference(after_entries |> Map.keys() |> MapSet.new())

    entries =
      state.entries
      |> Map.drop(MapSet.to_list(removed_paths))
      |> Map.merge(changed_entries(before_entries, after_entries))

    %{state | entries: entries}
  end

  defp changed_entries(before_entries, after_entries) do
    after_entries
    |> Enum.reject(fn {path, entry} ->
      Map.get(before_entries, path, :hyperlang_missing) == entry
    end)
    |> Map.new()
  end

  defp merge_tombstones(state, before_tombstones, after_tombstones) do
    added = MapSet.difference(after_tombstones, before_tombstones)
    removed = MapSet.difference(before_tombstones, after_tombstones)

    tombstones =
      state.tombstones
      |> MapSet.union(added)
      |> MapSet.difference(removed)

    %{state | tombstones: tombstones}
  end

  defp merge_write_bytes(state, before_write_bytes, after_write_bytes) do
    roots =
      before_write_bytes
      |> Map.keys()
      |> Kernel.++(Map.keys(after_write_bytes))
      |> Enum.uniq()

    write_bytes =
      Enum.reduce(roots, state.write_bytes, fn root, acc ->
        delta = Map.get(after_write_bytes, root, 0) - Map.get(before_write_bytes, root, 0)
        Map.update(acc, root, max(delta, 0), &max(&1 + delta, 0))
      end)

    %{state | write_bytes: write_bytes}
  end

  defp check_all_mount_limits(entries, tombstones, write_bytes, filesystem) do
    Enum.reduce_while(filesystem.mounts, :ok, fn mount, :ok ->
      case check_mount_limits(entries, tombstones, write_bytes, mount) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp check_mount_limits(
         entries,
         tombstones,
         write_bytes,
         %{virtual: root, limits: limits} = mount
       ) do
    with :ok <- check_mount_file_count(entries, root, limits),
         :ok <- check_mount_root_path_bytes(entries, root, mount, limits),
         :ok <- check_projected_state_limits(entries, tombstones, root, limits),
         :ok <- check_mount_write_bytes(write_bytes, root, limits) do
      :ok
    end
  end

  defp check_mount_file_count(entries, root, limits) do
    if mount_entry_count(entries, root) <= limits.max_file_count do
      :ok
    else
      {:error, :enospc}
    end
  end

  defp check_mount_write_bytes(write_bytes, root, limits) do
    if Map.get(write_bytes, root, 0) <= limits.max_write_bytes do
      :ok
    else
      {:error, :enospc}
    end
  end

  defp pending_manual_transaction(state) do
    state.transactions
    |> Enum.find(fn {_call_id, transaction} -> transaction.status == :pending_manual end)
    |> case do
      nil -> :error
      transaction -> {:ok, transaction}
    end
  end

  defp transaction_diff(snapshot, staged) do
    before_entries = visible_entries(snapshot.entries, snapshot.tombstones)
    after_entries = visible_entries(staged.entries, staged.tombstones)

    before_paths = Map.keys(before_entries) |> MapSet.new()
    after_paths = Map.keys(after_entries) |> MapSet.new()

    %{
      created: after_paths |> MapSet.difference(before_paths) |> sorted_paths(),
      deleted: before_paths |> MapSet.difference(after_paths) |> sorted_paths(),
      modified:
        before_paths
        |> MapSet.intersection(after_paths)
        |> Enum.filter(&(Map.fetch!(before_entries, &1) != Map.fetch!(after_entries, &1)))
        |> Enum.sort()
    }
  end

  defp visible_entries(entries, tombstones) do
    entries
    |> Enum.reject(fn {path, _entry} -> MapSet.member?(tombstones, path) end)
    |> Map.new()
  end

  defp sorted_paths(paths), do: paths |> MapSet.to_list() |> Enum.sort()

  defp normalize_write_content(content, limits) do
    case :erlang.iolist_size(content) do
      size when size <= limits.max_single_write_bytes ->
        {:ok, IO.iodata_to_binary(content)}

      _size ->
        {:error, :enospc}
    end
  rescue
    ArgumentError -> {:error, :badarg}
  end

  defp append_content(entries, tombstones, resolved, delta) do
    case read_resolved_file(entries, tombstones, resolved) do
      {:ok, existing} -> {:ok, existing <> delta}
      {:error, :enoent} -> {:ok, delta}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_read_size(content, limits) do
    if byte_size(content) <= limits.max_read_bytes, do: :ok, else: {:error, :eoverflow}
  end

  defp check_file_count(entries, path, %{virtual: root}, limits) do
    if Map.has_key?(entries, path) or
         mount_entry_count(entries, root) + 1 <= limits.max_file_count do
      :ok
    else
      {:error, :enospc}
    end
  end

  defp check_overlay_entry_count(
         entries,
         tombstones,
         path,
         %{mode: :overlay, virtual: root},
         limits
       ) do
    increment = if path == root or Map.has_key?(entries, path), do: 0, else: 1

    if overlay_entry_count(entries, tombstones, root) + increment <= limits.max_overlay_entries do
      :ok
    else
      {:error, :enospc}
    end
  end

  defp check_overlay_entry_count(_entries, _tombstones, _path, _mount, _limits), do: :ok

  defp check_total_path_bytes(entries, path, %{virtual: root}, limits) do
    new_bytes =
      if Map.has_key?(entries, path) do
        mount_path_bytes(entries, root)
      else
        mount_path_bytes(entries, root) + path_accounted_bytes(path, root)
      end

    if new_bytes <= limits.max_total_path_bytes do
      :ok
    else
      {:error, :enospc}
    end
  end

  defp check_mount_root_path_bytes(entries, _path, %{virtual: root}, limits) do
    new_bytes = mount_path_bytes(entries, root)
    if new_bytes <= limits.max_total_path_bytes, do: :ok, else: {:error, :enospc}
  end

  defp check_total_memory(entries, path, content, %{virtual: root}, limits) do
    check_total_memory(entries, MapSet.new(), path, content, %{virtual: root}, limits)
  end

  defp check_total_memory(entries, tombstones, path, content, %{virtual: root}, limits) do
    entry = file_entry(content, 0o644, root)
    check_total_memory_after_put_entry(entries, tombstones, path, entry, %{virtual: root}, limits)
  end

  defp check_total_memory_after_put_entry(
         entries,
         tombstones,
         path,
         entry,
         %{virtual: root},
         limits
       ) do
    entries = Map.put(entries, path, entry)
    check_memory_limit(entries, tombstones, root, limits)
  end

  defp check_memory_limit(entries, tombstones, root, limits) do
    if mount_memory_bytes(entries, tombstones, root) <= limits.max_total_memory_bytes do
      :ok
    else
      {:error, :enospc}
    end
  end

  defp check_tombstone_limit(tombstones, root, limits) do
    if mount_tombstone_count(tombstones, root) <= limits.max_tombstones do
      :ok
    else
      {:error, :enospc}
    end
  end

  defp check_overlay_limit(entries, tombstones, root, limits) do
    if overlay_entry_count(entries, tombstones, root) <= limits.max_overlay_entries do
      :ok
    else
      {:error, :enospc}
    end
  end

  defp check_projected_state_limits(entries, tombstones, root, limits) do
    with :ok <- check_tombstone_limit(tombstones, root, limits),
         :ok <- check_overlay_limit(entries, tombstones, root, limits),
         :ok <- check_memory_limit(entries, tombstones, root, limits) do
      :ok
    end
  end

  defp check_total_memory_after_rename(entries, tombstones, from, to, %{virtual: root}, limits) do
    {entries, tombstones} =
      projected_rename_entries_and_tombstones(entries, tombstones, from, to, root)

    check_memory_limit(entries, tombstones, root, limits)
  end

  defp check_total_path_bytes_after_rename(entries, from, to, %{virtual: root}, limits) do
    moved =
      entries
      |> Enum.filter(fn
        {path, %{mount_root: ^root}} -> path == from or String.starts_with?(path, from <> "/")
        _entry -> false
      end)
      |> Enum.map(fn {path, _entry} -> path end)

    old_bytes = Enum.reduce(moved, 0, fn path, acc -> acc + path_accounted_bytes(path, root) end)

    new_bytes =
      Enum.reduce(moved, mount_path_bytes(entries, root) - old_bytes, fn path, acc ->
        suffix = binary_part(path, byte_size(from), byte_size(path) - byte_size(from))
        acc + path_accounted_bytes(to <> suffix, root)
      end)

    if new_bytes <= limits.max_total_path_bytes, do: :ok, else: {:error, :enospc}
  end

  defp check_stat_result_size(stat, limits) do
    if byte_size(:erlang.term_to_binary(stat)) <= limits.max_stat_result_bytes do
      :ok
    else
      {:error, :eoverflow}
    end
  end

  defp check_write_budget(state, root, content, limits) do
    check_write_budget_bytes(state, root, byte_size(content), limits)
  end

  defp check_write_budget_bytes(state, root, bytes, limits) do
    if Map.get(state.write_bytes, root, 0) + bytes <= limits.max_write_bytes do
      :ok
    else
      {:error, :enospc}
    end
  end

  defp bump_write_bytes(write_bytes, root, bytes) do
    Map.update(write_bytes, root, bytes, &(&1 + bytes))
  end

  defp host_read(%{mount: %{backend: {:host, root}}, relative_path: relative}, mount)
       when is_binary(root) do
    with {:ok, path} <- host_path(root, relative),
         {:ok, stat} <- host_stat_path(path),
         :ok <- require_host_file(stat),
         {:ok, content} <- host_read_path(path, mount.limits) do
      {:ok, content}
    end
  end

  defp host_read(%{mount: %{backend: {:host, _root}}}, _mount), do: {:error, :eacces}

  defp host_overlay_read(%{mount: %{backend: {:host, root}}, relative_path: relative}, mount)
       when is_binary(root) do
    with {:ok, path} <- host_path(root, relative),
         {:ok, stat} <- host_lstat_path(path),
         :ok <- require_host_file(stat),
         {:ok, content} <- host_read_path(path, mount.limits) do
      {:ok, content}
    end
  end

  defp host_overlay_read(%{mount: %{backend: {:host, _root}}}, _mount), do: {:error, :eacces}

  defp host_list_names(%{mount: %{backend: {:host, root}}, relative_path: relative}, mount)
       when is_binary(root) do
    with {:ok, path} <- host_path(root, relative),
         {:ok, stat} <- host_stat_path(path),
         :ok <- require_host_dir(stat),
         {:ok, names} <- host_list_path(path, mount.limits) do
      {:ok, names}
    end
  end

  defp host_list_names(%{mount: %{backend: {:host, _root}}}, _mount), do: {:error, :eacces}

  defp host_stat(%{mount: %{backend: {:host, root}}, relative_path: relative})
       when is_binary(root) do
    with {:ok, path} <- host_path(root, relative) do
      host_stat_path(path)
    end
  end

  defp host_stat(%{mount: %{backend: {:host, _root}}}), do: {:error, :eacces}

  defp host_lstat(%{mount: %{backend: {:host, root}}, relative_path: relative})
       when is_binary(root) do
    with {:ok, path} <- host_path(root, relative) do
      host_lstat_path(path)
    end
  end

  defp host_lstat(%{mount: %{backend: {:host, _root}}}), do: {:error, :eacces}

  defp host_stat_entry(resolved, :stat) do
    with {:ok, stat} <- host_stat(resolved) do
      host_stat_entry(stat)
    end
  end

  defp host_stat_entry(resolved, :lstat) do
    with {:ok, stat} <- host_lstat(resolved) do
      host_stat_entry(stat)
    end
  end

  defp host_path_for_resolved(%{mount: %{backend: {:host, root}}, relative_path: "/"}), do: root

  defp host_path_for_resolved(%{mount: %{backend: {:host, root}}, relative_path: relative}) do
    relative
    |> String.trim_leading("/")
    |> then(&Path.join(root, &1))
  end

  defp host_lstat(path, %{backend: {:host, root}}) when is_binary(root) do
    with {:ok, relative} <- host_relative_path(root, path),
         {:ok, host_path} <- host_path(root, relative) do
      host_lstat_path(host_path)
    end
  end

  defp host_lstat(_path, %{backend: {:host, _root}}), do: {:error, :eacces}

  defp host_read_limited(path, %{backend: {:host, root}, limits: limits}) when is_binary(root) do
    with {:ok, relative} <- host_relative_path(root, path),
         {:ok, host_path} <- host_path(root, relative),
         {:ok, stat} <- host_stat_path(host_path),
         :ok <- require_host_file(stat),
         {:ok, content} <- host_read_path(host_path, limits) do
      {:ok, content}
    end
  end

  defp host_read_limited(_path, %{backend: {:host, _root}}), do: {:error, :eacces}

  defp host_list_names_at_path(path, %{backend: {:host, root}, limits: limits})
       when is_binary(root) do
    with {:ok, relative} <- host_relative_path(root, path),
         {:ok, host_path} <- host_path(root, relative),
         {:ok, stat} <- host_stat_path(host_path),
         :ok <- require_host_dir(stat),
         {:ok, names} <- host_list_path(host_path, limits) do
      {:ok, names}
    end
  end

  defp host_list_names_at_path(_path, %{backend: {:host, _root}}), do: {:error, :eacces}

  defp host_relative_path(root, path) do
    path = Path.expand(path)

    cond do
      path == root ->
        {:ok, "/"}

      String.starts_with?(path, root <> "/") ->
        {:ok,
         "/" <> binary_part(path, byte_size(root) + 1, byte_size(path) - byte_size(root) - 1)}

      true ->
        {:error, :eacces}
    end
  end

  defp require_host_dir(%{type: :directory}), do: :ok
  defp require_host_dir(%{type: :regular}), do: {:error, :enotdir}

  defp require_host_file(%{type: :regular}), do: :ok
  defp require_host_file(%{type: :directory}), do: {:error, :eisdir}
  defp require_host_file(%{type: :symlink}), do: {:error, :eacces}

  defp reject_host_symlink(%{type: :symlink}), do: {:error, :eacces}
  defp reject_host_symlink(_stat), do: :ok

  defp host_stat_entry(%{type: :regular, size: size, mode: mode}),
    do: {:ok, %{type: :regular, size: size, mode: OtpFacade.safe_permission_mode(mode)}}

  defp host_stat_entry(%{type: :directory, mode: mode}),
    do: {:ok, %{type: :directory, size: 0, mode: OtpFacade.safe_permission_mode(mode)}}

  defp host_stat_entry(%{type: :symlink, size: size, mode: mode}),
    do: {:ok, %{type: :symlink, size: size, mode: OtpFacade.safe_permission_mode(mode)}}

  defp host_path(root, relative) when is_binary(root) and is_binary(relative) do
    with {:ok, parts} <- host_relative_parts(relative) do
      {:ok, Enum.reduce(parts, root, &Path.join(&2, &1))}
    end
  end

  defp host_path(_root, _relative), do: {:error, :eacces}

  defp host_relative_parts("/"), do: {:ok, []}

  defp host_relative_parts(relative) when is_binary(relative) do
    if String.starts_with?(relative, "/") do
      parts = String.split(String.trim_leading(relative, "/"), "/", trim: true)

      if Enum.any?(parts, &unsafe_host_component?/1),
        do: {:error, :invalid_path},
        else: {:ok, parts}
    else
      {:error, :invalid_path}
    end
  end

  defp unsafe_host_component?(component),
    do: component in [".", "..", ""] or String.contains?(component, <<0>>)

  defp host_stat_path(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size, mode: mode}} ->
        {:ok, %{type: :regular, size: size, mode: mode}}

      {:ok, %File.Stat{type: :directory, mode: mode}} ->
        {:ok, %{type: :directory, size: 0, mode: mode}}

      {:ok, _stat} ->
        {:error, :eacces}

      {:error, reason} ->
        {:error, host_file_error(reason)}
    end
  end

  defp host_lstat_path(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size, mode: mode}} ->
        {:ok, %{type: :regular, size: size, mode: mode}}

      {:ok, %File.Stat{type: :directory, mode: mode}} ->
        {:ok, %{type: :directory, size: 0, mode: mode}}

      {:ok, %File.Stat{type: :symlink, size: size, mode: mode}} ->
        {:ok, %{type: :symlink, size: size, mode: mode}}

      {:ok, _stat} ->
        {:error, :eacces}

      {:error, reason} ->
        {:error, host_file_error(reason)}
    end
  end

  defp host_read_path(path, limits) do
    max_bytes = limits.max_read_bytes

    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        data = IO.binread(io, max_bytes + 1)
        File.close(io)

        case data do
          :eof -> {:ok, <<>>}
          {:error, reason} -> {:error, host_file_error(reason)}
          data when is_binary(data) and byte_size(data) <= max_bytes -> {:ok, data}
          data when is_binary(data) -> {:error, :eoverflow}
        end

      {:error, reason} ->
        {:error, host_file_error(reason)}
    end
  end

  defp host_list_path(path, limits) do
    with {:ok, names} <- host_file_list(path) do
      result_bytes = Enum.reduce(names, 0, fn name, acc -> acc + byte_size(name) end)

      cond do
        length(names) > limits.max_dir_entries -> {:error, :eoverflow}
        result_bytes > limits.max_dir_result_bytes -> {:error, :eoverflow}
        true -> {:ok, names}
      end
    end
  end

  defp host_file_list(path) do
    case File.ls(path) do
      {:ok, names} -> {:ok, Enum.sort(names)}
      {:error, reason} -> {:error, host_file_error(reason)}
    end
  end

  defp host_symlink_entry(%{mount: mount} = resolved) do
    with {:ok, path} <- host_path_for_entry(resolved) do
      host_symlink_entry(path, mount)
    end
  end

  defp host_symlink_entry(path, %{backend: {:host, root}, virtual: virtual})
       when is_binary(root) do
    case File.read_link(path) do
      {:ok, target} ->
        target = host_symlink_target_path(path, target)

        case host_relative_path(root, target) do
          {:ok, relative} ->
            {:ok,
             symlink_entry(virtual_path_for_host_relative(virtual, relative), false, virtual)}

          {:error, _reason} ->
            {:ok, symlink_entry(nil, true, virtual)}
        end

      {:error, reason} ->
        {:error, host_file_error(reason)}
    end
  end

  defp host_symlink_entry(_path, _mount), do: {:error, :eacces}

  defp host_path_for_entry(%{mount: %{backend: {:host, root}}, relative_path: relative})
       when is_binary(root),
       do: host_path(root, relative)

  defp host_path_for_entry(_resolved), do: {:error, :eacces}

  defp host_symlink_target_path(link_path, target) do
    if Path.type(target) == :relative do
      Path.expand(target, Path.dirname(link_path))
    else
      Path.expand(target)
    end
  end

  defp virtual_path_for_host_relative(virtual, "/"), do: virtual

  defp virtual_path_for_host_relative(virtual, relative) do
    suffix = String.trim_leading(relative, "/")
    if virtual == "/", do: "/" <> suffix, else: virtual <> "/" <> suffix
  end

  defp host_file_error(:enoent), do: :enoent
  defp host_file_error(:enotdir), do: :enotdir
  defp host_file_error(:eisdir), do: :eisdir
  defp host_file_error(:eacces), do: :eacces
  defp host_file_error(:enametoolong), do: :enametoolong
  defp host_file_error(:enospc), do: :enospc
  defp host_file_error(:eexist), do: :eexist
  defp host_file_error(:enotempty), do: :enotempty
  defp host_file_error(:exdev), do: :exdev
  defp host_file_error(_reason), do: :eacces

  defp mount_memory_bytes(entries, tombstones, root) do
    entry_bytes =
      Enum.reduce(entries, 0, fn
        {path, %{mount_root: ^root} = entry}, acc ->
          acc + path_accounted_bytes(path, root) + entry_memory_bytes(entry)

        _entry, acc ->
          acc
      end)

    entry_bytes + tombstone_memory_bytes(tombstones, root)
  end

  defp entry_memory_bytes(%{type: :file, content: content}),
    do: @entry_metadata_bytes + byte_size(content)

  defp entry_memory_bytes(%{type: :symlink, target: target}) when is_binary(target),
    do: @entry_metadata_bytes + byte_size(target)

  defp entry_memory_bytes(_entry), do: @entry_metadata_bytes

  defp tombstone_memory_bytes(tombstones, root) do
    Enum.reduce(tombstones, 0, fn path, acc ->
      if Filesystem.mount_matches?(root, path) and path != root do
        acc + @tombstone_metadata_bytes + path_accounted_bytes(path, root)
      else
        acc
      end
    end)
  end

  defp mount_tombstone_count(tombstones, root) do
    Enum.count(tombstones, &(Filesystem.mount_matches?(root, &1) and &1 != root))
  end

  defp overlay_entry_count(entries, tombstones, root) do
    entry_count =
      Enum.count(entries, fn
        {^root, _entry} -> false
        {_path, %{mount_root: ^root}} -> true
        _entry -> false
      end)

    entry_count + mount_tombstone_count(tombstones, root)
  end

  defp mount_entry_count(entries, root) do
    Enum.count(entries, fn
      {^root, _entry} -> false
      {_path, %{mount_root: ^root}} -> true
      _entry -> false
    end)
  end

  defp mount_path_bytes(entries, root) do
    Enum.reduce(entries, 0, fn
      {path, %{mount_root: ^root}}, acc -> acc + path_accounted_bytes(path, root)
      _entry, acc -> acc
    end)
  end

  defp path_accounted_bytes(path, root) do
    cond do
      path == "/" ->
        0

      path == root ->
        0

      true ->
        byte_size(path)
    end
  end

  defp fetch_entry(entries, path) do
    case Map.fetch(entries, path) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :enoent}
    end
  end

  defp fetch_entry(entries, tombstones, %{mount: %{mode: :overlay}, path: path} = resolved) do
    cond do
      MapSet.member?(tombstones, path) ->
        {:error, :enoent}

      Map.has_key?(entries, path) ->
        Map.fetch(entries, path)

      true ->
        host_overlay_type_entry(resolved)
    end
  end

  defp fetch_entry(entries, tombstones, %{path: path}) do
    with {:ok, entry} <- fetch_entry(entries, path),
         :ok <- not_tombstoned(tombstones, path) do
      {:ok, entry}
    end
  end

  defp entry_absent(entries, path), do: entry_absent(entries, MapSet.new(), path)

  defp entry_absent(entries, tombstones, path) when is_binary(path) do
    if Map.has_key?(entries, path) and not MapSet.member?(tombstones, path),
      do: {:error, :eexist},
      else: :ok
  end

  defp entry_absent(entries, tombstones, %{mount: %{mode: :overlay}, path: path} = resolved) do
    cond do
      Map.has_key?(entries, path) and not MapSet.member?(tombstones, path) ->
        {:error, :eexist}

      MapSet.member?(tombstones, path) ->
        :ok

      true ->
        case host_overlay_type_entry(resolved) do
          {:ok, _entry} -> {:error, :eexist}
          {:error, :enoent} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp entry_absent(entries, tombstones, %{path: path}) do
    entry_absent(entries, tombstones, path)
  end

  defp parent_dir_exists(entries, path) do
    parent_dir_exists(entries, MapSet.new(), path)
  end

  defp parent_dir_exists(entries, tombstones, path) when is_binary(path) do
    parent = parent_path(path)

    case Map.fetch(entries, parent) do
      {:ok, %{type: :dir}} -> not_tombstoned(tombstones, parent)
      {:ok, _entry} -> {:error, :enotdir}
      :error -> {:error, :enoent}
    end
  end

  defp parent_dir_exists(entries, tombstones, %{mount: %{mode: :overlay}, path: path} = resolved) do
    parent = parent_path(path)
    parent_resolved = resolved_at(resolved, parent)

    cond do
      MapSet.member?(tombstones, parent) ->
        {:error, :enoent}

      match?(%{type: :dir}, Map.get(entries, parent)) ->
        :ok

      Map.has_key?(entries, parent) ->
        {:error, :enotdir}

      true ->
        case host_overlay_type_entry(parent_resolved) do
          {:ok, %{type: :dir}} -> :ok
          {:ok, _entry} -> {:error, :enotdir}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp parent_dir_exists(entries, tombstones, %{path: path}) do
    parent_dir_exists(entries, tombstones, path)
  end

  defp seed_parent_dir_exists(entries, path) do
    parent_dir_exists(entries, path)
  end

  defp put_seed_dir(entries, path) do
    case Map.get(entries, path) do
      nil -> {:ok, Map.put(entries, path, dir_entry(mount_root_for_path(entries, path)))}
      %{type: :dir} -> {:ok, entries}
      %{type: :file} -> {:error, :enotdir}
    end
  end

  defp ensure_not_dir(entries, path), do: ensure_not_dir(entries, MapSet.new(), path)

  defp ensure_not_dir(entries, tombstones, path) when is_binary(path) do
    if MapSet.member?(tombstones, path) do
      :ok
    else
      case Map.get(entries, path) do
        %{type: :dir} -> {:error, :eisdir}
        _ -> :ok
      end
    end
  end

  defp ensure_not_dir(entries, tombstones, %{mount: %{mode: :overlay}, path: path} = resolved) do
    cond do
      MapSet.member?(tombstones, path) ->
        :ok

      match?(%{type: :dir}, Map.get(entries, path)) ->
        {:error, :eisdir}

      Map.has_key?(entries, path) ->
        :ok

      true ->
        case host_overlay_type_entry(resolved) do
          {:ok, %{type: :dir}} -> {:error, :eisdir}
          {:ok, %{type: :symlink}} -> {:error, :eacces}
          {:ok, _entry} -> :ok
          {:error, :enoent} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp ensure_not_dir(entries, tombstones, %{path: path}) do
    ensure_not_dir(entries, tombstones, path)
  end

  defp require_file(%{type: :file}), do: :ok
  defp require_file(%{type: :dir}), do: {:error, :eisdir}
  defp require_file(%{type: :symlink}), do: {:error, :eacces}

  defp require_dir(%{type: :dir}), do: :ok
  defp require_dir(%{type: :file}), do: {:error, :enotdir}
  defp require_dir(%{type: :symlink}), do: {:error, :eacces}

  defp reject_root_mutation(%{path: "/", mount: _mount}), do: {:error, :einval}
  defp reject_root_mutation(%{path: path, mount: %{virtual: path}}), do: {:error, :eacces}
  defp reject_root_mutation(%{path: path}), do: reject_root_mutation(path)
  defp reject_root_mutation("/"), do: {:error, :einval}
  defp reject_root_mutation(_path), do: :ok

  defp dir_empty(entries, tombstones, path) when is_binary(path) do
    if Enum.any?(Map.keys(entries), &(child_of?(&1, path) and not MapSet.member?(tombstones, &1))) do
      {:error, :enotempty}
    else
      :ok
    end
  end

  defp dir_empty(entries, tombstones, %{mount: %{mode: :overlay}} = resolved) do
    case overlay_list_names(entries, tombstones, resolved) do
      {:ok, []} -> :ok
      {:ok, _names} -> {:error, :enotempty}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dir_empty(entries, tombstones, %{path: path}) do
    dir_empty(entries, tombstones, path)
  end

  defp list_names(entries, tombstones, path, limits) do
    names =
      direct_visible_child_names(entries, tombstones, path)

    result_bytes = Enum.reduce(names, 0, fn name, acc -> acc + byte_size(name) end)

    cond do
      length(names) > limits.max_dir_entries -> {:error, :eoverflow}
      result_bytes > limits.max_dir_result_bytes -> {:error, :eoverflow}
      true -> {:ok, names}
    end
  end

  defp direct_visible_child_names(entries, tombstones, path) do
    entries
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(tombstones, &1))
    |> Enum.flat_map(&direct_child_name(&1, path))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp tombstoned_direct_child_names(tombstones, path) do
    tombstones
    |> Enum.flat_map(&direct_child_name(&1, path))
    |> MapSet.new()
  end

  defp not_tombstoned(tombstones, path) do
    if MapSet.member?(tombstones, path), do: {:error, :enoent}, else: :ok
  end

  defp same_mount(%{mount: %{virtual: root}}, %{mount: %{virtual: root}}), do: :ok
  defp same_mount(_from, _to), do: {:error, :exdev}

  defp valid_rename_target(entries, tombstones, source, from, to) when source.type == :dir do
    cond do
      to == from or String.starts_with?(to, from <> "/") ->
        {:error, :einval}

      match?(%{type: :file}, Map.get(entries, to)) ->
        {:error, :enotdir}

      match?(%{type: :dir}, Map.get(entries, to)) ->
        dir_empty(entries, tombstones, to)

      true ->
        :ok
    end
  end

  defp valid_rename_target(_entries, _tombstones, %{type: :symlink}, _from, _to),
    do: {:error, :eacces}

  defp valid_rename_target(entries, _tombstones, source, _from, to) do
    case Map.get(entries, to) do
      nil -> :ok
      %{type: type} when type == source.type -> :ok
      %{type: :dir} -> {:error, :eisdir}
      %{type: :file} -> {:error, :enotdir}
    end
  end

  defp valid_overlay_rename_target(
         entries,
         tombstones,
         source,
         %{mount: %{mode: :overlay}, path: path} = resolved
       ) do
    cond do
      Map.has_key?(entries, path) and not MapSet.member?(tombstones, path) ->
        :ok

      MapSet.member?(tombstones, path) ->
        :ok

      true ->
        case host_overlay_type_entry(resolved) do
          {:ok, %{type: :dir}} when source.type == :file -> {:error, :eisdir}
          {:ok, %{type: :file}} when source.type == :dir -> {:error, :enotdir}
          {:ok, %{type: :symlink}} -> {:error, :eacces}
          {:ok, _entry} -> :ok
          {:error, :enoent} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp valid_overlay_rename_target(_entries, _tombstones, _source, _resolved), do: :ok

  defp materialize_rename_source(state, %{path: path} = resolved) do
    cond do
      MapSet.member?(state.tombstones, path) ->
        {:error, :enoent}

      Map.has_key?(state.entries, path) ->
        with {:ok, source} <- Map.fetch(state.entries, path) do
          {:ok, state, source}
        end

      true ->
        materialize_host_overlay_source(state, resolved)
    end
  end

  defp materialize_host_overlay_source(state, %{mount: %{mode: :overlay} = mount} = resolved) do
    with {:ok, stat} <- host_lstat(resolved) do
      case stat.type do
        :regular ->
          with {:ok, content} <- host_overlay_read(resolved, mount),
               :ok <- check_file_count(state.entries, resolved.path, mount, mount.limits),
               :ok <-
                 check_overlay_entry_count(
                   state.entries,
                   state.tombstones,
                   resolved.path,
                   mount,
                   mount.limits
                 ),
               :ok <- check_total_path_bytes(state.entries, resolved.path, mount, mount.limits),
               :ok <-
                 check_total_memory(
                   state.entries,
                   state.tombstones,
                   resolved.path,
                   content,
                   mount,
                   mount.limits
                 ) do
            source = file_entry(content, OtpFacade.safe_permission_mode(stat.mode), mount.virtual)
            state = %{state | entries: Map.put(state.entries, resolved.path, source)}
            {:ok, state, source}
          end

        :directory ->
          with {:ok, entries} <-
                 materialize_host_overlay_tree(
                   host_path_for_resolved(resolved),
                   resolved.path,
                   mount,
                   state.entries,
                   state.tombstones
                 ),
               {:ok, source} <- Map.fetch(entries, resolved.path) do
            {:ok, %{state | entries: entries}, source}
          end

        :symlink ->
          with {:ok, source} <- host_symlink_entry(resolved),
               :ok <- check_file_count(state.entries, resolved.path, mount, mount.limits),
               :ok <-
                 check_overlay_entry_count(
                   state.entries,
                   state.tombstones,
                   resolved.path,
                   mount,
                   mount.limits
                 ),
               :ok <- check_total_path_bytes(state.entries, resolved.path, mount, mount.limits),
               :ok <-
                 check_total_memory_after_put_entry(
                   state.entries,
                   state.tombstones,
                   resolved.path,
                   source,
                   mount,
                   mount.limits
                 ) do
            state = %{state | entries: Map.put(state.entries, resolved.path, source)}
            {:ok, state, source}
          end
      end
    end
  end

  defp materialize_host_overlay_source(_state, _resolved), do: {:error, :enoent}

  defp materialize_host_overlay_tree(host_path, virtual_path, mount, entries, tombstones) do
    cond do
      MapSet.member?(tombstones, virtual_path) ->
        {:ok, entries}

      match?(%{type: :file}, Map.get(entries, virtual_path)) ->
        {:ok, entries}

      match?(%{type: :symlink}, Map.get(entries, virtual_path)) ->
        {:ok, entries}

      true ->
        with {:ok, stat} <- host_lstat(host_path, mount) do
          materialize_host_overlay_entry(
            host_path,
            virtual_path,
            stat,
            mount,
            entries,
            tombstones
          )
        end
    end
  end

  defp materialize_host_overlay_entry(host_path, virtual_path, stat, mount, entries, tombstones) do
    case stat.type do
      :directory ->
        with :ok <- check_file_count(entries, virtual_path, mount, mount.limits),
             :ok <-
               check_overlay_entry_count(entries, tombstones, virtual_path, mount, mount.limits),
             :ok <- check_total_path_bytes(entries, virtual_path, mount, mount.limits),
             :ok <-
               check_total_memory_after_put_entry(
                 entries,
                 tombstones,
                 virtual_path,
                 dir_entry(mount.virtual),
                 mount,
                 mount.limits
               ),
             entries <- Map.put_new(entries, virtual_path, dir_entry(mount.virtual)),
             {:ok, names} <- host_list_names_at_path(host_path, mount) do
          Enum.reduce_while(names, {:ok, entries}, fn name, {:ok, entries} ->
            child_host_path = Path.join(host_path, name)
            child_virtual_path = virtual_child_path(virtual_path, name)

            case materialize_host_overlay_tree(
                   child_host_path,
                   child_virtual_path,
                   mount,
                   entries,
                   tombstones
                 ) do
              {:ok, entries} -> {:cont, {:ok, entries}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)
        end

      :regular ->
        with {:ok, content} <- host_read_limited(host_path, mount),
             :ok <- check_file_count(entries, virtual_path, mount, mount.limits),
             :ok <-
               check_overlay_entry_count(entries, tombstones, virtual_path, mount, mount.limits),
             :ok <- check_total_path_bytes(entries, virtual_path, mount, mount.limits),
             :ok <-
               check_total_memory(entries, tombstones, virtual_path, content, mount, mount.limits) do
          entry = file_entry(content, OtpFacade.safe_permission_mode(stat.mode), mount.virtual)
          {:ok, Map.put_new(entries, virtual_path, entry)}
        end

      :symlink ->
        with {:ok, entry} <- host_symlink_entry(host_path, mount),
             :ok <- check_file_count(entries, virtual_path, mount, mount.limits),
             :ok <-
               check_overlay_entry_count(entries, tombstones, virtual_path, mount, mount.limits),
             :ok <- check_total_path_bytes(entries, virtual_path, mount, mount.limits),
             :ok <-
               check_total_memory_after_put_entry(
                 entries,
                 tombstones,
                 virtual_path,
                 entry,
                 mount,
                 mount.limits
               ) do
          {:ok, Map.put_new(entries, virtual_path, entry)}
        end

      _other ->
        {:ok, entries}
    end
  end

  defp delete_entry_state(state, path, root, limits) do
    entries = Map.delete(state.entries, path)

    tombstones =
      if Filesystem.mount_matches?(root, path) do
        MapSet.put(state.tombstones, path)
      else
        state.tombstones
      end

    with :ok <- check_projected_state_limits(entries, tombstones, root, limits) do
      {:ok, %{state | entries: entries, tombstones: tombstones}}
    end
  end

  defp rename_entry_state(state, from, to, root, limits) do
    {entries, tombstones} =
      projected_rename_entries_and_tombstones(state.entries, state.tombstones, from, to, root)

    with :ok <- check_projected_state_limits(entries, tombstones, root, limits) do
      {:ok, %{state | entries: entries, tombstones: tombstones}}
    end
  end

  defp projected_rename_entries_and_tombstones(entries, tombstones, from, to, root) do
    moved_paths = moved_entry_paths(entries, from, root)
    entries = rename_entries(entries, from, to, root)

    new_paths =
      Enum.map(moved_paths, fn path ->
        suffix = binary_part(path, byte_size(from), byte_size(path) - byte_size(from))
        to <> suffix
      end)

    tombstones =
      tombstones
      |> copy_tombstones_under_rename(from, to, root)
      |> then(fn tombstones -> Enum.reduce(moved_paths, tombstones, &MapSet.put(&2, &1)) end)
      |> then(fn tombstones -> Enum.reduce(new_paths, tombstones, &MapSet.delete(&2, &1)) end)

    {entries, tombstones}
  end

  defp moved_entry_paths(entries, from, root) do
    entries
    |> Enum.filter(fn
      {path, %{mount_root: ^root}} -> path == from or String.starts_with?(path, from <> "/")
      _entry -> false
    end)
    |> Enum.map(fn {path, _entry} -> path end)
  end

  defp clear_tombstone(tombstones, path, root) do
    if Filesystem.mount_matches?(root, path),
      do: MapSet.delete(tombstones, path),
      else: tombstones
  end

  defp ensure_dir_path(entries, "/", _mount), do: {:ok, entries}

  defp ensure_dir_path(entries, path, mount) do
    case Map.get(entries, path) do
      %{type: :dir} ->
        {:ok, entries}

      %{type: :file} ->
        {:error, :eexist}

      %{type: :symlink, escape: true} ->
        {:error, :eacces}

      %{type: :symlink} ->
        {:error, :eexist}

      nil ->
        parent = parent_path(path)

        with {:ok, entries} <- ensure_dir_path(entries, parent, mount),
             :ok <- check_file_count(entries, path, mount, mount.limits),
             :ok <- check_total_path_bytes(entries, path, mount, mount.limits) do
          {:ok, Map.put(entries, path, dir_entry(mount.virtual))}
        end
    end
  end

  defp rename_entries(entries, from, to, root) do
    entries
    |> Enum.reduce(entries, fn {path, entry}, acc ->
      cond do
        entry.mount_root != root ->
          acc

        path == from ->
          acc
          |> Map.delete(path)
          |> Map.put(to, entry)

        String.starts_with?(path, from <> "/") ->
          suffix = binary_part(path, byte_size(from), byte_size(path) - byte_size(from))

          acc
          |> Map.delete(path)
          |> Map.put(to <> suffix, entry)

        true ->
          acc
      end
    end)
  end

  defp copy_tombstones_under_rename(tombstones, from, to, root) do
    Enum.reduce(tombstones, tombstones, fn path, acc ->
      cond do
        not Filesystem.mount_matches?(root, path) ->
          acc

        path == from ->
          MapSet.put(acc, to)

        String.starts_with?(path, from <> "/") ->
          suffix = binary_part(path, byte_size(from), byte_size(path) - byte_size(from))
          MapSet.put(acc, to <> suffix)

        true ->
          acc
      end
    end)
  end

  defp stat_entry(%{type: :dir, mode: mode}), do: %{type: :directory, size: 0, mode: mode}

  defp stat_entry(%{type: :file, content: content, mode: mode}),
    do: %{type: :regular, size: byte_size(content), mode: mode}

  defp stat_entry(%{type: :symlink, target: target, mode: mode}),
    do: %{type: :symlink, size: byte_size(target || ""), mode: mode}

  defp file_entry(content, mode, mount_root),
    do: %{type: :file, content: content, mode: mode, mount_root: mount_root}

  defp dir_entry(mount_root), do: %{type: :dir, mode: 0o755, mount_root: mount_root}

  defp symlink_entry(target, escape, mount_root),
    do: %{type: :symlink, target: target, escape: escape, mode: 0o777, mount_root: mount_root}

  defp parent_path("/"), do: "/"

  defp parent_path(path) do
    case Path.dirname(path) do
      "." -> "/"
      parent -> parent
    end
  end

  defp direct_child_name(path, path), do: []

  defp direct_child_name(child, parent) do
    prefix = if parent == "/", do: "/", else: parent <> "/"

    if String.starts_with?(child, prefix) do
      suffix = binary_part(child, byte_size(prefix), byte_size(child) - byte_size(prefix))

      case String.split(suffix, "/", parts: 2) do
        [name] when name != "" -> [name]
        [name, _rest] when name != "" -> [name]
        _ -> []
      end
    else
      []
    end
  end

  defp child_of?(path, parent) do
    path != parent and String.starts_with?(path, if(parent == "/", do: "/", else: parent <> "/"))
  end

  defp mount_root_for_path(entries, path) do
    entries
    |> Enum.flat_map(fn
      {entry_path, %{type: :dir, mount_root: root}} when entry_path == root ->
        if Filesystem.mount_matches?(root, path), do: [root], else: []

      _entry ->
        []
    end)
    |> Enum.max_by(&byte_size/1, fn -> "/" end)
  end
end
