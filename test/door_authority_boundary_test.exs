defmodule DoorAuthorityBoundaryTest do
  use ExUnit.Case, async: true

  defmodule KV do
    @behaviour Hyperlang.Binding
    @impl true
    def exports, do: [get: 1]
    @impl true
    def call(fun, :get, [value]), do: fun.(value)
  end

  defmodule OtherKV do
    @behaviour Hyperlang.Binding
    @impl true
    def exports, do: [get: 1]
    @impl true
    def call(fun, :get, [value]), do: fun.(value)
  end

  @manifest %{
    terms: %{public: :erlang, allowed_atoms: [:first, :second]},
    bindings: %{"kv" => KV}
  }

  setup do
    {:ok, program} =
      Hyperlang.program(%{
        entry: "authority_boundary.erl",
        files: %{
          "authority_boundary.erl" =>
            "-module(authority_boundary).\n-export([result/1]).\nresult(Input) -> kv:get(Input).\n"
        },
        manifest: @manifest
      })

    %{program: program}
  end

  test "the same immutable program receives different authority from each spec", %{
    program: program
  } do
    first = %{bindings: %{"kv" => {KV, fn value -> {:first, value} end}}, policy: %{}}
    second = %{bindings: %{"kv" => {KV, fn value -> {:second, value} end}}, policy: %{}}

    assert {:ok, {:first, 1}, _meta} = Hyperlang.run(first, program, :entry, [1])
    assert {:ok, {:second, 1}, _meta} = Hyperlang.run(second, program, :entry, [1])
  end

  test "a missing capability cannot be recovered from ambient process state", %{program: program} do
    Process.put(:kv, {KV, fn value -> value end})

    assert {:error,
            %{category: :manifest, details: %{"reason" => "missing binding implementations"}}} =
             Hyperlang.run(%{bindings: %{}, policy: %{}}, program, :entry, [1])
  end

  test "a run cannot substitute a different module for a declared binding", %{program: program} do
    spec = %{bindings: %{"kv" => {OtherKV, fn value -> value end}}, policy: %{}}

    assert {:error, %{category: :manifest, details: %{"reason" => reason}}} =
             Hyperlang.run(spec, program, :entry, [1])

    assert reason =~ "declared module"
  end

  test "a run cannot add bindings the program did not declare", %{program: program} do
    spec = %{
      bindings: %{"kv" => {KV, fn value -> value end}, "net" => {OtherKV, fn value -> value end}},
      policy: %{}
    }

    assert {:error, %{category: :manifest, details: %{"reason" => reason}}} =
             Hyperlang.run(spec, program, :entry, [1])

    assert reason =~ "does not declare"
  end

  test "the binding MFA set is fixed by the program and enters its hash" do
    source = "-module(authority_boundary).\n-export([result/1]).\nresult(I) -> kv:get(I).\n"
    files = %{"authority_boundary.erl" => source}

    {:ok, kv} =
      Hyperlang.program(%{entry: "authority_boundary.erl", files: files, manifest: @manifest})

    {:ok, other} =
      Hyperlang.program(%{
        entry: "authority_boundary.erl",
        files: files,
        manifest: %{@manifest | bindings: %{"kv" => OtherKV}}
      })

    refute kv.content_hash == other.content_hash

    undeclared =
      "-module(authority_boundary).\n-export([result/1]).\nresult(I) -> kv:put(I, I).\n"

    assert {:error, [_ | _]} =
             Hyperlang.program(%{
               entry: "authority_boundary.erl",
               files: %{"authority_boundary.erl" => undeclared},
               manifest: @manifest
             })
  end

  test "an undeclared atom cannot cross the input boundary", %{program: program} do
    fresh = :"door_input_#{:erlang.unique_integer([:positive])}"
    spec = %{bindings: %{"kv" => {KV, fn value -> value end}}, policy: %{}}

    assert {:error, error} = Hyperlang.run(spec, program, :entry, [fresh])
    assert inspect(error) =~ "atom_not_allowed"
  end

  test "an undeclared atom cannot cross a capability return boundary", %{program: program} do
    fresh = :"door_return_#{:erlang.unique_integer([:positive])}"
    spec = %{bindings: %{"kv" => {KV, fn _value -> fresh end}}, policy: %{}}

    assert {:error, error} = Hyperlang.run(spec, program, :entry, [1])
    assert inspect(error) =~ "atom_not_allowed"
  end

  test "run policy atoms may narrow but never widen the program atom set", %{program: program} do
    spec = fn atoms ->
      %{bindings: %{"kv" => {KV, fn value -> value end}}, policy: %{atoms: atoms}}
    end

    assert {:ok, :first, _meta} = Hyperlang.run(spec.([:first]), program, :entry, [:first])

    assert {:error, error} = Hyperlang.run(spec.([:first]), program, :entry, [:second])
    assert inspect(error) =~ "atom_not_allowed"

    assert {:error, %{category: :manifest, details: %{"reason" => reason}}} =
             Hyperlang.run(spec.([:first, :door_widened]), program, :entry, [:first])

    assert reason =~ "narrow"
  end
end
