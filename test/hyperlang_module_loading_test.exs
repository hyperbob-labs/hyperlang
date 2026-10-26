defmodule HyperlangModuleLoadingTest do
  use ExUnit.Case, async: true

  defp manifest(files, opts) do
    %{
      terms: %{public: :erlang},
      modules: %{enabled: true, guest_modules: Keyword.get(opts, :guest_modules, [])},
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

  defp compile_snapshot!(files, entry) do
    manifest = manifest(files, guest_modules: source_modules(files))
    {:ok, normalized} = Hyperlang.Manifest.normalize(manifest)
    {:ok, handle} = Hyperlang.Filesystem.start(normalized.filesystem)

    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)

    assert {:ok, program} =
             Hyperlang.DoorTestSupport.build_from_filesystem(
               handle,
               %{entry: entry, sources: Enum.map(files, & &1.path)},
               manifest
             )

    program
  end

  defp source_modules(files) do
    Enum.map(files, fn %{content: source} ->
      [_, module] = Regex.run(~r/-module\(([a-z][A-Za-z0-9_]*)\)\./, source)
      module
    end)
  end

  test "source snapshots link modules into one generated BEAM image" do
    files = [
      %{
        path: "/src/main.erl",
        content: """
        -module(main).
        -export([result/1]).
        result(Input) -> helper:double(Input).
        """
      },
      %{
        path: "/src/helper.erl",
        content: """
        -module(helper).
        -export([double/1]).
        double(X) -> X * 2.
        """
      }
    ]

    program = compile_snapshot!(files, "/src/main.erl")

    assert {:ok, 42, _} = Hyperlang.Test.run(program, :entry, [21])
  end

  test "linked snapshot modules share one guest process dictionary namespace" do
    files = [
      %{
        path: "/src/main.erl",
        content: """
        -module(main).
        -export([result/1]).
        result(_) ->
          helper:seed(<<"shared">>, <<"left">>),
          {get(<<"shared">>), helper:fetch(<<"shared">>), get()}.
        """
      },
      %{
        path: "/src/helper.erl",
        content: """
        -module(helper).
        -export([seed/2, fetch/1]).
        seed(Key, Value) -> put(Key, Value).
        fetch(Key) -> get(Key).
        """
      }
    ]

    program = compile_snapshot!(files, "/src/main.erl")

    assert {:ok, {<<"left">>, <<"left">>, [{<<"shared">>, <<"left">>}]}, _meta} =
             Hyperlang.Test.run(program, :entry, [:ok])
  end
end
