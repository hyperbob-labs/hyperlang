Code.require_file("support/probe.ex", __DIR__)

defmodule Hyperlang.Isolation.FindingsTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 45_000
  alias Hyperlang.Isolation.Peer

  test "each run has fresh reductions across distinct programs" do
    assert %{result: %{observed: r}} = Peer.run(:pooled_budget)
    assert r.categories == List.duplicate(:ok, 16)
    assert {:ok, 2, %{reductions: n}} = r.victim
    assert {:ok, 2, _} = r.clean
    assert n < 200_000
    assert r.groups == []
  end

  test "guest children terminate when their owning run ends" do
    assert %{result: %{observed: r}} = Peer.run(:child_lifetime)
    assert {:ok, 1, _} = r.run
    assert r.after_100ms == nil
    assert r.after_200ms == nil
    assert r.members == []
  end

  test "timer quota and handles are isolated by host scope" do
    assert %{result: %{observed: r}} = Peer.run(:timers)
    assert [{:ok, a, _}, {:ok, b, _}, {:error, _}] = r.tenant_a
    assert a != b and a > 65_536 and b > 65_536
    assert {:ok, _, _} = r.tenant_b
    assert {:ok, false, _} = r.cancellation_from_b
    assert {:ok, false, _} = r.read_from_b
    assert {:ok, remaining, _} = r.own_cancel
    assert remaining > 0
    assert {:ok, _, _} = r.after_cancel
  end

  test "workers use on heap mailboxes under default and explicit heap limits" do
    assert %{result: %{observed: r}} = Peer.run(:queue_flag)
    assert {:ok, default, _} = r.default
    assert {:ok, explicit, _} = r.explicit
    assert default =~ "message_queue_data: :on_heap"
    assert explicit =~ "message_queue_data: :on_heap"
    assert default =~ "include_shared_binaries: true"
  end

  test "start channel owners have independent monitored lifetimes" do
    assert %{result: %{observed: r}} = Peer.run(:startchans)
    refute r.owned_by_first
    assert r.table_after_owner_exit != :undefined
    assert r.first_rows_after_exit == []
    assert r.second_receive == 7
    assert r.rows_after_receive == 0
  end

  test "actor status and crash logs redact host secrets with every guest formatter" do
    assert %{result: rows} = Peer.run(:actor_hygiene)
    assert length(rows) >= 3

    for %{observed: r} <- rows do
      refute r.status_contains_secret
      refute r.raw_event_contains_secret
      refute r.formatted_log_contains_secret
      refute r.formatted_log_contains_spec
      refute r.formatter_failed
      assert r.log_events > 0
    end
  end

  test "apply_guest_fun rejects host funs at the helper as well as ingress" do
    assert %{result: %{observed: r}} = Peer.run(:fun_admission)
    assert r.internal_external == {:rejected, {:sandbox, :badfun, :provenance}}
    assert r.internal_local == {:rejected, {:sandbox, :badfun, :provenance}}
    assert r.internal_spoofed == {:rejected, {:sandbox, :badfun, :provenance}}
    assert {:ok, 3, _} = r.local
    assert {:error, %{category: :input}} = r.external_input
    assert {:error, %{category: :import}} = r.external_import
  end

  test "run groups are reclaimed after completed calls and host caller exits" do
    assert %{result: r} = Peer.run(:leaks_chunk, [:normal, 100])
    assert r.observed.outcomes == %{ok: 100}
    assert r.delta.groups == 0
    assert r.delta.processes == 0
  end
end
