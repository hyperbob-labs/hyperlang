defmodule Hyperlang.Table do
  @moduledoc false

  use GenServer

  defmodule Handle do
    @moduledoc false
    @enforce_keys [:pid]
    defstruct [:pid]
  end

  @guest_module "hyperlang_table"
  @table_types ~w(set bag duplicate_bag)
  @ignored_options ~w(public private protected named_table)
  @concurrency_options ~w(read_concurrency write_concurrency decentralized_counters)
  @known_options @table_types ++ @ignored_options ++ @concurrency_options

  @calls %{
    {"new", 1} => :new,
    {"new", 2} => :new_named,
    {"insert", 2} => :insert,
    {"lookup", 2} => :lookup,
    {"delete", 1} => :delete_table,
    {"delete", 2} => :delete_key,
    {"fold", 3} => :fold
  }

  @supported_mfas @calls
                  |> Map.keys()
                  |> Enum.map(fn {function, arity} -> {@guest_module, function, arity} end)
                  |> Enum.sort()

  def supported_mfas, do: @supported_mfas

  def call_target(%{tables: %{enabled: true}}, @guest_module, function, arity),
    do: Map.get(@calls, {function, arity}, :error)

  def call_target(_manifest, _module, _function, _arity), do: :error

  def start(%{limits: limits}) when is_map(limits) do
    case GenServer.start(__MODULE__, limits) do
      {:ok, pid} -> {:ok, %Handle{pid: pid}}
      {:error, reason} -> {:error, reason}
    end
  end

  def stop(%Handle{pid: pid}) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, :infinity)
    :ok
  catch
    :exit, _reason -> :ok
  end

  def stop(_handle), do: :ok

  def dispatch(ctx, :new, [options]) do
    with {:ok, type} <- normalize_table_type(options, ctx) do
      ctx
      |> service_call({:new, type})
      |> guest_reply()
    else
      {:error, reason} -> table_error(reason)
    end
  end

  def dispatch(ctx, :new_named, [name, options]) do
    with {:ok, _name} <- sanitize_term(name, ctx) do
      dispatch(ctx, :new, [options])
    else
      {:error, reason} -> table_error({:term_rejected, reason})
    end
  end

  def dispatch(ctx, :insert, [handle, objects]) do
    with {:ok, objects} <- sanitize_objects(objects, ctx) do
      ctx
      |> service_call({:insert, handle, objects})
      |> guest_reply()
    else
      {:error, reason} -> table_error({:term_rejected, reason})
    end
  end

  def dispatch(ctx, :lookup, [handle, key]) do
    with {:ok, key} <- sanitize_term(key, ctx) do
      ctx
      |> service_call({:lookup, handle, key})
      |> guest_reply()
    else
      {:error, reason} -> table_error({:term_rejected, reason})
    end
  end

  def dispatch(ctx, :delete_table, [handle]) do
    ctx
    |> service_call({:delete_table, handle})
    |> guest_reply()
  end

  def dispatch(ctx, :delete_key, [handle, key]) do
    with {:ok, key} <- sanitize_term(key, ctx) do
      ctx
      |> service_call({:delete_key, handle, key})
      |> guest_reply()
    else
      {:error, reason} -> table_error({:term_rejected, reason})
    end
  end

  def dispatch(ctx, :fold, [handle, function, accumulator]) when is_function(function, 2) do
    objects =
      ctx
      |> service_call({:objects, handle})
      |> guest_reply()

    Enum.reduce(objects, accumulator, function)
  end

  def dispatch(_ctx, :fold, [_handle, _function, _accumulator]), do: table_error(:badarg)
  def dispatch(_ctx, _operation, _args), do: table_error(:badarg)

  @doc false
  def info(%Handle{pid: pid}) when is_pid(pid), do: GenServer.call(pid, :info, :infinity)

  @impl true
  def init(limits) do
    {:ok, %{limits: limits, tables: %{}, next_handle: 1}}
  end

  @impl true
  def handle_call({:new, type}, _from, state) when type in [:set, :bag, :duplicate_bag] do
    if map_size(state.tables) >= state.limits.max_tables do
      {:reply, {:error, {:quota, :max_tables}}, state}
    else
      # Handles count per table service, so a guest sees the same handles on
      # every run; a node-wide counter would be a live nondeterministic value
      # and would reveal other tenants' table activity.
      handle = state.next_handle

      table = %{
        type: type,
        rows: %{},
        object_count: 0,
        memory_bytes: 0
      }

      state = %{state | next_handle: handle + 1}
      {:reply, {:ok, handle}, put_in(state, [:tables, handle], table)}
    end
  end

  def handle_call({:insert, handle, objects}, _from, state) do
    with {:ok, table} <- fetch_table(state, handle),
         candidate <- Enum.reduce(objects, table, &put_object/2),
         :ok <- check_table_quota(candidate, state.limits) do
      {:reply, {:ok, true}, put_in(state, [:tables, handle], candidate)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:lookup, handle, key}, _from, state) do
    with {:ok, table} <- fetch_table(state, handle) do
      {:reply, {:ok, lookup_objects(table, key)}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete_table, handle}, _from, state) do
    if Map.has_key?(state.tables, handle) do
      {:reply, {:ok, true}, %{state | tables: Map.delete(state.tables, handle)}}
    else
      {:reply, {:error, :badarg}, state}
    end
  end

  def handle_call({:delete_key, handle, key}, _from, state) do
    with {:ok, table} <- fetch_table(state, handle) do
      {:reply, {:ok, true}, put_in(state, [:tables, handle], drop_key(table, key))}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:objects, handle}, _from, state) do
    with {:ok, table} <- fetch_table(state, handle) do
      {:reply, {:ok, all_objects(table)}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:info, _from, state) do
    tables =
      Map.new(state.tables, fn {handle, table} ->
        {handle,
         %{
           type: table.type,
           object_count: table.object_count,
           memory_bytes: table.memory_bytes
         }}
      end)

    {:reply, %{limits: state.limits, tables: tables}, state}
  end

  defp service_call(%{table_service: %Handle{pid: pid}}, request) when is_pid(pid) do
    GenServer.call(pid, request, :infinity)
  catch
    :exit, _reason -> {:error, :service_unavailable}
  end

  defp service_call(_ctx, _request), do: {:error, :service_unavailable}

  defp guest_reply({:ok, value}), do: value
  defp guest_reply({:error, {:quota, reason}}), do: quota_kill(reason)
  defp guest_reply({:error, reason}), do: table_error(reason)

  defp quota_kill(reason) do
    Process.exit(self(), {:hyperlang_table_quota, reason})

    receive do
    after
      :infinity -> :ok
    end
  end

  defp table_error(reason), do: :erlang.error({:sandbox, :table_error, reason})

  defp normalize_table_type(options, ctx) when is_atom(options) do
    case guest_atom_name(options, ctx) do
      type when type in @table_types -> {:ok, String.to_existing_atom(type)}
      _other -> {:error, :badarg}
    end
  end

  defp normalize_table_type(options, ctx) when is_list(options) do
    Enum.reduce_while(options, {:ok, nil}, fn option, {:ok, type} ->
      case normalize_table_option(option, ctx) do
        {:type, candidate} when type in [nil, candidate] -> {:cont, {:ok, candidate}}
        {:type, _candidate} -> {:halt, {:error, :badarg}}
        :ignored -> {:cont, {:ok, type}}
        :error -> {:halt, {:error, :badarg}}
      end
    end)
    |> case do
      {:ok, nil} -> {:ok, :set}
      {:ok, type} -> {:ok, type}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_table_type(_options, _ctx), do: {:error, :badarg}

  defp normalize_table_option(option, ctx) when is_atom(option) do
    case guest_atom_name(option, ctx) do
      type when type in @table_types -> {:type, String.to_existing_atom(type)}
      option when option in @ignored_options -> :ignored
      _other -> :error
    end
  end

  defp normalize_table_option({option, value}, ctx) when is_atom(option) and is_boolean(value) do
    if guest_atom_name(option, ctx) in @concurrency_options, do: :ignored, else: :error
  end

  defp normalize_table_option(_option, _ctx), do: :error

  defp guest_atom_name(atom, ctx) do
    Hyperlang.Terms.atom_source(atom, ctx) ||
      case Atom.to_string(atom) do
        known when known in @known_options -> known
        _other -> nil
      end
  end

  defp sanitize_objects(objects, ctx) when is_tuple(objects) do
    with {:ok, object} <- sanitize_term(objects, ctx),
         true <- valid_object?(object) do
      {:ok, [object]}
    else
      false -> {:error, :badarg}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sanitize_objects(objects, ctx) when is_list(objects) do
    with {:ok, objects} <- sanitize_term(objects, ctx),
         true <- Enum.all?(objects, &valid_object?/1) do
      {:ok, objects}
    else
      false -> {:error, :badarg}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sanitize_objects(_objects, _ctx), do: {:error, :badarg}

  defp sanitize_term(term, ctx), do: Hyperlang.Terms.sanitize(term, ctx, :table)

  defp valid_object?(object), do: is_tuple(object) and tuple_size(object) > 0

  defp fetch_table(state, handle) when is_integer(handle) do
    case Map.fetch(state.tables, handle) do
      {:ok, table} -> {:ok, table}
      :error -> {:error, :badarg}
    end
  end

  defp fetch_table(_state, _handle), do: {:error, :badarg}

  defp put_object(object, %{type: :set} = table) do
    key = elem(object, 0)
    size = object_memory_bytes(object)

    case Map.fetch(table.rows, key) do
      {:ok, {_previous, previous_size}} ->
        %{
          table
          | rows: Map.put(table.rows, key, {object, size}),
            memory_bytes: table.memory_bytes - previous_size + size
        }

      :error ->
        %{
          table
          | rows: Map.put(table.rows, key, {object, size}),
            object_count: table.object_count + 1,
            memory_bytes: table.memory_bytes + size
        }
    end
  end

  defp put_object(object, %{type: :bag} = table) do
    key = elem(object, 0)
    size = object_memory_bytes(object)
    row = Map.get(table.rows, key, %{})

    if Map.has_key?(row, object) do
      table
    else
      %{
        table
        | rows: Map.put(table.rows, key, Map.put(row, object, size)),
          object_count: table.object_count + 1,
          memory_bytes: table.memory_bytes + size
      }
    end
  end

  defp put_object(object, %{type: :duplicate_bag} = table) do
    key = elem(object, 0)
    size = object_memory_bytes(object)
    row = Map.get(table.rows, key, [])

    %{
      table
      | rows: Map.put(table.rows, key, [{object, size} | row]),
        object_count: table.object_count + 1,
        memory_bytes: table.memory_bytes + size
    }
  end

  defp lookup_objects(%{type: :set, rows: rows}, key) do
    case Map.fetch(rows, key) do
      {:ok, {object, _size}} -> [object]
      :error -> []
    end
  end

  defp lookup_objects(%{type: :bag, rows: rows}, key),
    do: rows |> Map.get(key, %{}) |> Map.keys()

  defp lookup_objects(%{type: :duplicate_bag, rows: rows}, key),
    do: rows |> Map.get(key, []) |> Enum.map(&elem(&1, 0))

  defp drop_key(table, key) do
    case Map.pop(table.rows, key) do
      {nil, _rows} ->
        table

      {row, rows} ->
        {count, bytes} = row_usage(table.type, row)

        %{
          table
          | rows: rows,
            object_count: table.object_count - count,
            memory_bytes: table.memory_bytes - bytes
        }
    end
  end

  defp row_usage(:set, {_object, size}), do: {1, size}

  defp row_usage(:bag, row),
    do: {map_size(row), Enum.reduce(row, 0, fn {_object, size}, total -> total + size end)}

  defp row_usage(:duplicate_bag, row),
    do: {length(row), Enum.reduce(row, 0, fn {_object, size}, total -> total + size end)}

  defp all_objects(%{type: :set, rows: rows}),
    do: Enum.map(rows, fn {_key, {object, _size}} -> object end)

  defp all_objects(%{type: :bag, rows: rows}),
    do: Enum.flat_map(rows, fn {_key, row} -> Map.keys(row) end)

  defp all_objects(%{type: :duplicate_bag, rows: rows}),
    do: Enum.flat_map(rows, fn {_key, row} -> Enum.map(row, &elem(&1, 0)) end)

  defp check_table_quota(table, limits) do
    cond do
      table.object_count > limits.max_objects_per_table ->
        {:error, {:quota, :max_objects_per_table}}

      table.memory_bytes > limits.max_memory_bytes_per_table ->
        {:error, {:quota, :max_memory_bytes_per_table}}

      true ->
        :ok
    end
  end

  defp object_memory_bytes(object), do: :erlang.external_size(object, [:deterministic])
end
