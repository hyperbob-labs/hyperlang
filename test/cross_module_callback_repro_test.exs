defmodule CrossModuleCallbackReproTest do
  use ExUnit.Case, async: true

  @target """
  -module(cbtarget).
  -export([ping/1, keycheck/1]).
  ping(X) -> X.
  keycheck(M) ->
      case maps:get(status, M, undefined) of
          active -> <<"ok:atom_key_and_value">>;
          undefined -> <<"FAIL:atom_key_demoted">>;
          V when is_binary(V) -> <<"FAIL:value_demoted">>;
          _ -> <<"FAIL:other">>
      end.
  """

  @mutrec_a """
  -module(mutrec_a).
  -export([is_even/1]).
  is_even(0) -> <<"even">>;
  is_even(N) -> mutrec_b:is_odd(N - 1).
  """

  @mutrec_b """
  -module(mutrec_b).
  -export([is_odd/1]).
  is_odd(0) -> <<"odd">>;
  is_odd(N) -> mutrec_a:is_even(N - 1).
  """

  defp manifest(files, opts \\ []) do
    %{
      terms: %{public: :erlang},
      modules: %{
        enabled: true,
        guest_modules: Keyword.get(opts, :guest_modules, source_modules(files))
      },
      filesystem: %{
        enabled: true,
        source_compile: true,
        file_compat: true,
        mounts: [
          %{
            virtual: "/src",
            backend: "memory",
            mode: :memory,
            allow: [:read, :list, :stat],
            files: files
          }
        ]
      }
    }
  end

  defp source_file(name, source), do: %{path: "/src/" <> name <> ".erl", content: source}

  defp source_modules(files) do
    Enum.map(files, fn %{content: source} ->
      [_, module] = Regex.run(~r/-module\(([a-z][A-Za-z0-9_]*)\)\./, source)
      module
    end)
  end

  defp compile_snapshot!(files, entry) do
    assert {:ok, program} = compile_snapshot(files, entry)

    program
  end

  defp compile_snapshot(files, entry) do
    manifest = manifest(files)
    {:ok, normalized} = Hyperlang.Manifest.normalize(manifest)
    {:ok, handle} = Hyperlang.Filesystem.start(normalized.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    Hyperlang.DoorTestSupport.build_from_filesystem(
      handle,
      %{entry: entry, sources: Enum.map(files, & &1.path)},
      manifest
    )
  end

  defp eval_snapshot!(files, entry, input \\ :ok) do
    program = compile_snapshot!(files, entry)
    Hyperlang.Test.run(program, :entry, [input])
  end

  test "static linked sibling calls execute in the source snapshot graph" do
    main = """
    -module(main).
    -export([result/1]).
    result(_) ->
      {
        cbtarget:ping(<<"hi">>),
        cbtarget:keycheck(\#{status => active, count => 1})
      }.
    """

    assert {:ok, {<<"hi">>, <<"ok:atom_key_and_value">>}, _} =
             eval_snapshot!(
               [source_file("main", main), source_file("cbtarget", @target)],
               "/src/main.erl"
             )
  end

  test "dynamic Module:fn callbacks execute in source snapshots" do
    main = """
    -module(main).
    -export([result/1]).
    result(_) ->
      Module = cbtarget,
      {
        Module:ping(<<"hi">>),
        Module:keycheck(\#{status => active, count => 1})
      }.
    """

    assert {:ok, {<<"hi">>, <<"ok:atom_key_and_value">>}, _} =
             eval_snapshot!(
               [source_file("main", main), source_file("cbtarget", @target)],
               "/src/main.erl"
             )
  end

  test "mutually recursive linked modules execute without a runtime load cycle" do
    main = """
    -module(main).
    -export([result/1]).
    result(_) -> mutrec_a:is_even(4).
    """

    files = [
      source_file("main", main),
      source_file("mutrec_a", @mutrec_a),
      source_file("mutrec_b", @mutrec_b)
    ]

    assert {:ok, <<"even">>, _} = eval_snapshot!(files, "/src/main.erl")
  end
end
