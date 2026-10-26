defmodule RecordExpansionTest do
  use ExUnit.Case, async: false

  @manifest %{
    terms: %{public: :erlang, allowed_atoms: [:badrecord, :ok, :r, :s, :wrong]},
    limits: %{wall_ms: 1_000}
  }

  test "record create update access index patterns and is_record guards" do
    source = """
    -record(r, {a = 1, b = 2}).
    result(_) ->
      R0 = #r{}, R1 = R0#r{b = 7},
      {R1#r.a, R1#r.b, #r.b, match(R1), guarded(R1)}.
    match(#r{a = A, b = B}) -> {A,B}.
    guarded(X) when is_record(X, r) -> ok.
    """

    assert eval(source) == {1, 7, 3, {1, 7}, :ok}
  end

  test "nested updates and two records preserve tuple semantics" do
    source = """
    -record(r, {value}).
    -record(s, {inner}).
    result(_) ->
      S0 = #s{inner = #r{value = 1}},
      R1 = (S0#s.inner)#r{value = 9},
      S1 = S0#s{inner = R1},
      {(S1#s.inner)#r.value, S1}.
    """

    assert eval(source) == {9, {:s, {:r, 9}}}
  end

  test "badrecord is strict for wrong tags and non-tuples" do
    source = """
    -record(r, {value}).
    result(_) -> {capture({wrong,1}), capture(42)}.
    capture(X) -> try X#r.value catch error:{badrecord,_} -> badrecord end.
    """

    assert eval(source) == {:badrecord, :badrecord}
  end

  test "record-generated variables do not enter the guest atom pool" do
    {:ok, program} =
      Hyperlang.Test.program("-record(r,{x}). result(_) -> (#r{x=1})#r.x.", @manifest)

    refute inspect(program.metadata.atom_universe) =~ "rec0"
  end

  test "record_info fields and size are expanded by the OTP compiler" do
    source = "-record(r,{a,b=2}). result(_) -> {record_info(fields,r),record_info(size,r)}."
    assert eval(source) == {["a", "b"], 3}
  end

  test "undeclared records and fields are rejected before code generation" do
    assert {:error, [%{category: :verify, message: "undeclared record missing"}]} =
             Hyperlang.Test.program("result(_) -> #missing{}.", @manifest)

    assert {:error, [%{category: :verify, message: "undeclared field missing for record r"}]} =
             Hyperlang.Test.program(
               "-record(r,{x}). result(_) -> #r{missing=1}.",
               @manifest
             )
  end

  test "record tuple crosses a snapshot module boundary" do
    files = [
      %{
        path: "/src/a.erl",
        content: "-module(a). -export([make/0]). -record(r,{x}). make() -> #r{x=5}."
      },
      %{
        path: "/src/main.erl",
        content: "-module(main). -export([result/1]). result(_) -> {r,5}=a:make(), ok."
      }
    ]

    manifest =
      @manifest
      |> Map.put(:modules, %{enabled: true, guest_modules: ["a", "main"]})
      |> Map.put(:filesystem, %{
        enabled: true,
        source_compile: true,
        mounts: [
          %{virtual: "/src", backend: "memory", mode: :memory, allow: [:read], files: files}
        ]
      })

    {:ok, normalized} = Hyperlang.Manifest.normalize(manifest)
    {:ok, fs} = Hyperlang.Filesystem.start(normalized.filesystem)

    try do
      {:ok, program} =
        Hyperlang.DoorTestSupport.build_from_filesystem(
          fs,
          %{entry: "/src/main.erl", sources: Enum.map(files, & &1.path)},
          manifest
        )

      assert {:ok, :ok, _} = Hyperlang.Test.run(program, :entry, [:ok])
    after
      Hyperlang.Filesystem.stop(fs)
    end
  end

  defp eval(source) do
    {:ok, program} = Hyperlang.Test.program(source, @manifest)

    assert {:ok, result, _} = Hyperlang.Test.run(program, :entry, [:ok])
    result
  end
end
