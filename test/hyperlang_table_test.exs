defmodule HyperlangTableTest do
  use ExUnit.Case, async: true

  defp table_manifest(limit_overrides \\ %{}) do
    %{
      terms: %{public: :erlang},
      limits: %{wall_ms: 1_000, max_reductions: 50_000_000},
      tables: %{
        enabled: true,
        limits:
          Map.merge(
            %{
              max_tables: 8,
              max_objects_per_table: 1_000,
              max_memory_bytes_per_table: 1_000_000
            },
            limit_overrides
          )
      }
    }
  end

  defp compile_program!(source, manifest \\ table_manifest()) do
    assert {:ok, program} = Hyperlang.Test.program(source, manifest)
    program
  end

  defp eval_result!(program, input \\ :ok) do
    assert {:ok, result, %{stdout: []}} =
             Hyperlang.Test.run(program, :entry, [input])

    result
  end

  defp public_error_field(error, :reason), do: get_in(error, [:details, "reason"])
  defp public_error_field(error, field), do: Map.get(error, field)

  test "manifest table service is closed, configurable, and disabled by default" do
    assert {:ok, defaults} = Hyperlang.Manifest.normalize(%{})
    refute defaults.tables.enabled

    assert defaults.tables.limits == %{
             max_tables: 32,
             max_objects_per_table: 50_000,
             max_memory_bytes_per_table: 8 * 1024 * 1024
           }

    assert {:ok, configured} =
             Hyperlang.Manifest.normalize(%{
               tables: %{
                 enabled: true,
                 limits: %{
                   max_tables: "2",
                   max_objects_per_table: "3",
                   max_memory_bytes_per_table: "4096"
                 }
               }
             })

    assert configured.tables == %{
             enabled: true,
             limits: %{
               max_tables: 2,
               max_objects_per_table: 3,
               max_memory_bytes_per_table: 4096
             }
           }

    assert {:error, %{category: :manifest, message: unknown_message}} =
             Hyperlang.Manifest.normalize(%{tables: %{limits: %{max_rows: 1}}})

    assert unknown_message =~ "unknown table limit key"

    assert {:error, %{category: :manifest, message: invalid_message}} =
             Hyperlang.Manifest.normalize(%{tables: %{limits: %{max_tables: -1}}})

    assert invalid_message =~ "non-negative integers"
  end

  test "facade is manifest gated and raw ets remains forbidden" do
    assert {:error, [%{category: :verify, message: disabled_message}]} =
             Hyperlang.Test.program("hyperlang_table:new(set).", %{})

    assert disabled_message =~ "forbidden remote call hyperlang_table:new/1"

    assert {:error, [%{category: :verify, message: ets_message}]} =
             Hyperlang.Test.program(
               "ets:new(raw, [set, public]).",
               table_manifest()
             )

    assert ets_message =~ "forbidden remote call ets:new/2"
  end

  test "set tables support named and anonymous new, batch insert, lookup, and delete" do
    source = """
    result(_) ->
      T = hyperlang_table:new(
            compiler_state,
            [set, public, {read_concurrency, true}, {write_concurrency, true}]
          ),
      true = hyperlang_table:insert(
               T,
               [{<<"alpha">>, 1}, {<<"beta">>, 2}, {<<"alpha">>, 3}]
             ),
      Before = {
        hyperlang_table:lookup(T, <<"alpha">>),
        hyperlang_table:lookup(T, <<"missing">>)
      },
      true = hyperlang_table:delete(T, <<"alpha">>),
      After = hyperlang_table:lookup(T, <<"alpha">>),
      true = hyperlang_table:delete(T),
      {Before, After}.
    """

    program = compile_program!(source)

    assert eval_result!(program) == {{[{<<"alpha">>, 3}], []}, []}
  end

  test "bag variants and fold preserve their ets-shaped object semantics" do
    source = """
    result(_) ->
      Duplicates = hyperlang_table:new([duplicate_bag, private]),
      true = hyperlang_table:insert(
               Duplicates,
               [
                 {<<"a">>, 1},
                 {<<"a">>, 1},
                 {<<"a">>, 2},
                 {<<"b">>, 3}
               ]
             ),
      DuplicateObjects =
        lists:sort(hyperlang_table:lookup(Duplicates, <<"a">>)),
      Sum =
        hyperlang_table:fold(
          Duplicates,
          fun({_Key, Value}, Acc) -> Value + Acc end,
          0
        ),

      Bag = hyperlang_table:new(bag),
      true = hyperlang_table:insert(Bag, [{<<"a">>, 1}, {<<"a">>, 1}, {<<"a">>, 2}]),
      BagObjects = lists:sort(hyperlang_table:lookup(Bag, <<"a">>)),
      {DuplicateObjects, Sum, BagObjects}.
    """

    program = compile_program!(source)

    assert eval_result!(program) ==
             {
               [{<<"a">>, 1}, {<<"a">>, 1}, {<<"a">>, 2}],
               7,
               [{<<"a">>, 1}, {<<"a">>, 2}]
             }
  end

  test "max table quota is an uncatchable worker kill" do
    source = """
    result(_) ->
      try
        _First = hyperlang_table:new(set),
        _Second = hyperlang_table:new(set),
        <<"survived">>
      catch
        _:_ -> <<"caught">>
      end.
    """

    program =
      compile_program!(source, table_manifest(%{max_tables: 1}))

    assert_quota_kill(program, "max_tables")
  end

  defp assert_quota_kill(program, expected_limit) do
    assert {:error, error} = Hyperlang.Test.run(program, :entry, [:ok])
    assert public_error_field(error, :category) == :sandbox_crash

    reason = public_error_field(error, :reason)
    assert reason =~ "hyperlang_table_quota"
    assert reason =~ expected_limit
  end
end
