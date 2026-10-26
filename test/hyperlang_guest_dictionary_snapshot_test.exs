defmodule HyperlangGuestDictionarySnapshotTest do
  use ExUnit.Case, async: false

  alias Hyperlang.Runtime

  @h101 {<<"h">>, 101}
  @h102 {<<"h">>, 102}
  @h103 {<<"h">>, 103}
  @h201 {<<"h">>, 201}
  @h202 {<<"h">>, 202}
  @unreachable {<<"h">>, 999}

  setup do
    previous_frame = Runtime.current_guest_dictionary_frame_id()
    Runtime.clear_guest_dictionary()
    Runtime.clear_guest_dictionary_dependency_scan_count()

    on_exit(fn ->
      Runtime.clear_guest_dictionary()
      Runtime.restore_guest_dictionary_frame(previous_frame)
      Runtime.clear_guest_dictionary_dependency_scan_count()
    end)

    :ok
  end

  test "reachable snapshot matches the old full-entry walk on mixed dictionary shapes" do
    Runtime.guest_dictionary_put_ns(nil, <<"plain">>, :simple)
    Runtime.guest_dictionary_put_ns(:bufio, <<"iobuf">>, %{buffer: @h101, alt: [@h102]})
    Runtime.guest_dictionary_put_ns(:chan, <<"channel">>, {:channel, %{ref: @h201}})
    Runtime.guest_dictionary_put_ns(:bufio, <<"unreferenced ordinary">>, :still_copied)

    Runtime.guest_dictionary_put_ns(nil, @h101, {:iobuf_cell, @h103})
    Runtime.guest_dictionary_put_ns(:bufio, @h102, {:nested_cell, 2})
    Runtime.guest_dictionary_put_ns(:legacy_dup, @h101, {:same_handle_key_other_namespace, @h103})
    Runtime.guest_dictionary_put_ns(:chan, @h201, {:channel_cell, [@h202]})
    Runtime.guest_dictionary_put_ns(:chan, @h202, :channel_leaf)
    Runtime.guest_dictionary_put_ns(nil, @h103, :iobuf_leaf)
    Runtime.guest_dictionary_put_ns(:bufio, @unreachable, :not_copied)

    roots = [%{spawn_arg: @h201}, {@h101, :carried}]

    expected = old_snapshot_guest_dictionary_reachable(roots)
    actual = Runtime.snapshot_guest_dictionary_reachable(roots)

    assert actual == expected

    actual_set = MapSet.new(actual)
    assert MapSet.member?(actual_set, {nil, <<"plain">>, :simple})
    assert MapSet.member?(actual_set, {:bufio, <<"unreferenced ordinary">>, :still_copied})
    assert MapSet.member?(actual_set, {:chan, @h202, :channel_leaf})
    refute Enum.any?(actual, fn {_namespace, key, _value} -> key == @unreachable end)

    Runtime.clear_guest_dictionary()
    assert :ok = Runtime.restore_guest_dictionary(actual)

    assert Runtime.snapshot_guest_dictionary_reachable(roots) ==
             old_snapshot_guest_dictionary_reachable(roots)
  end

  test "reachable snapshot enumerates handle indexes but does not inspect unreachable values" do
    namespace = {:bulk_snapshot, System.unique_integer([:positive])}
    root = {<<"h">>, 1}
    nested = {<<"h">>, 2}

    for id <- 1..200 do
      handle = {<<"h">>, id}

      value =
        case id do
          1 -> {:root_cell, nested}
          2 -> {:nested_cell, :leaf}
          _other -> {:unreachable_cell, id, {<<"h">>, 10_000 + id}}
        end

      Runtime.guest_dictionary_put_ns(namespace, handle, value)
    end

    Runtime.reset_guest_dictionary_dependency_scan_count()

    snapshot = Runtime.snapshot_guest_dictionary_reachable([root])

    # Complexity contract: spawn-time work still enumerates the namespace index
    # to build the handle lookup, but value inspection is limited to the roots.
    # Entry value dependencies were recorded when each entry was put/restored.
    assert Runtime.guest_dictionary_dependency_scan_count() == 1

    assert MapSet.new(snapshot) ==
             MapSet.new([
               {namespace, root, {:root_cell, nested}},
               {namespace, nested, {:nested_cell, :leaf}}
             ])
  end

  test "generated process dictionary put and erase maintain dependency metadata" do
    {:ok, manifest} = Hyperlang.Manifest.normalize(erlang_public())
    manifest = Hyperlang.DoorTestSupport.seed_atom_universe(manifest)

    source = """
    result(_) ->
      put(k, {{<<"h">>, 1}, value}),
      erase(k).
    """

    {:ok, compiled} = Hyperlang.Compiler.compile(source, manifest)
    {:ok, forms, _metadata} = Hyperlang.Codegen.to_forms(compiled, manifest)
    calls = remote_calls(forms)

    assert {Hyperlang.Runtime, :guest_dictionary_store_dependencies, 3} in calls
    assert {Hyperlang.Runtime, :guest_dictionary_delete_dependencies, 2} in calls
  end

  test "overwriting process dictionary deps with a scalar clears and later restores them" do
    namespace = {:overwrite_deps, System.unique_integer([:positive])}
    key = <<"cell">>
    handle = {<<"h">>, 501}

    Runtime.guest_dictionary_put_ns(namespace, handle, :leaf)

    Runtime.reset_guest_dictionary_dependency_scan_count()
    Runtime.guest_dictionary_put_ns(namespace, key, %{ref: handle})
    assert Runtime.guest_dictionary_dependency_scan_count() == 1

    assert MapSet.new(Runtime.snapshot_guest_dictionary_reachable([])) ==
             MapSet.new([
               {namespace, key, %{ref: handle}},
               {namespace, handle, :leaf}
             ])

    Runtime.reset_guest_dictionary_dependency_scan_count()
    Runtime.guest_dictionary_put_ns(namespace, key, <<"plain">>)
    assert Runtime.guest_dictionary_dependency_scan_count() == 0

    assert MapSet.new(Runtime.snapshot_guest_dictionary_reachable([])) ==
             MapSet.new([{namespace, key, <<"plain">>}])

    Runtime.reset_guest_dictionary_dependency_scan_count()
    Runtime.guest_dictionary_put_ns(namespace, key, %{again: [handle]})
    assert Runtime.guest_dictionary_dependency_scan_count() == 1

    assert MapSet.new(Runtime.snapshot_guest_dictionary_reachable([])) ==
             MapSet.new([
               {namespace, key, %{again: [handle]}},
               {namespace, handle, :leaf}
             ])
  end

  defp erlang_public(manifest \\ %{}) do
    Map.update(manifest, :terms, %{public: :erlang}, &Map.put(&1, :public, :erlang))
  end

  # Test-only copy of the previous reachable implementation. It intentionally
  # starts from the full snapshot and walks every ordinary entry value.
  defp old_snapshot_guest_dictionary_reachable(roots) do
    Runtime.snapshot_guest_dictionary()
    |> old_reachable_guest_dictionary_entries(roots)
  end

  defp old_reachable_guest_dictionary_entries(entries, roots) do
    handle_entries =
      Enum.reduce(entries, %{}, fn
        {_namespace, key, _value} = entry, acc ->
          if guest_ref_handle_key?(key) do
            Map.update(acc, key, [entry], &[entry | &1])
          else
            acc
          end
      end)

    ordinary_entries =
      Enum.reject(entries, fn {_namespace, key, _value} -> guest_ref_handle_key?(key) end)

    included =
      Map.new(ordinary_entries, fn {namespace, key, _value} = entry ->
        {{namespace, key}, entry}
      end)

    {included, seen_handles} =
      Enum.reduce(ordinary_entries, {included, MapSet.new()}, fn {_namespace, _key, value},
                                                                 {included, seen_handles} ->
        old_collect_reachable_guest_dictionary(value, handle_entries, included, seen_handles)
      end)

    {included, _seen_handles} =
      old_collect_reachable_guest_dictionary(roots, handle_entries, included, seen_handles)

    Map.values(included)
  end

  defp old_collect_reachable_guest_dictionary(term, handle_entries, included, seen_handles) do
    cond do
      guest_ref_handle_key?(term) ->
        old_collect_guest_ref_handle(term, handle_entries, included, seen_handles)

      is_map(term) ->
        Enum.reduce(term, {included, seen_handles}, fn {key, value}, acc ->
          acc
          |> old_collect_guest_dictionary_child(key, handle_entries)
          |> old_collect_guest_dictionary_child(value, handle_entries)
        end)

      is_tuple(term) ->
        term
        |> Tuple.to_list()
        |> Enum.reduce({included, seen_handles}, fn child, acc ->
          old_collect_guest_dictionary_child(acc, child, handle_entries)
        end)

      is_list(term) ->
        Enum.reduce(term, {included, seen_handles}, fn child, acc ->
          old_collect_guest_dictionary_child(acc, child, handle_entries)
        end)

      true ->
        {included, seen_handles}
    end
  end

  defp old_collect_guest_dictionary_child({included, seen_handles}, child, handle_entries) do
    old_collect_reachable_guest_dictionary(child, handle_entries, included, seen_handles)
  end

  defp old_collect_guest_ref_handle(handle, handle_entries, included, seen_handles) do
    if MapSet.member?(seen_handles, handle) do
      {included, seen_handles}
    else
      seen_handles = MapSet.put(seen_handles, handle)

      handle_entries
      |> Map.get(handle, [])
      |> Enum.reduce({included, seen_handles}, fn {namespace, key, value} = entry,
                                                  {included, seen_handles} ->
        included = Map.put(included, {namespace, key}, entry)
        old_collect_reachable_guest_dictionary(value, handle_entries, included, seen_handles)
      end)
    end
  end

  defp guest_ref_handle_key?({<<"h">>, id}) when is_integer(id), do: true
  defp guest_ref_handle_key?(_term), do: false

  defp remote_calls(term), do: remote_calls(term, [])

  defp remote_calls({:call, _a, {:remote, _ra, {:atom, _ma, m}, {:atom, _fa, f}}, args}, acc) do
    [{m, f, length(args)} | acc]
  end

  defp remote_calls(term, acc) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.reduce(acc, &remote_calls/2)
  end

  defp remote_calls(term, acc) when is_list(term), do: Enum.reduce(term, acc, &remote_calls/2)
  defp remote_calls(_term, acc), do: acc
end
