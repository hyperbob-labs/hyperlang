defmodule SnapshotApplyTest do
  use ExUnit.Case, async: false

  @manifest %{
    capabilities: %{gen_server: true},
    terms: %{
      public: :erlang,
      allowed_atoms: [
        :add,
        :bad,
        :badarg,
        :boom,
        :error,
        :exit,
        :hidden,
        :lists,
        :main,
        :nope,
        :ok,
        :raise,
        :result,
        :reverse,
        :target,
        :throw,
        :undef,
        :unknown,
        :value,
        :zero
      ]
    },
    modules: %{enabled: true},
    filesystem: %{enabled: true, source_compile: true},
    limits: %{wall_ms: 2_000, max_source_bytes: 120_000}
  }

  test "snapshot apply dispatches guest arities and allowlisted stdlib" do
    files = [
      source("/src/target.erl", """
      -module(target).
      -export([zero/0, add/2]).
      zero() -> ok.
      add(A, B) -> A + B.
      """),
      source("/src/main.erl", """
      -module(main).
      -export([result/1]).
      result(_) ->
        {apply(target, zero, []),
         apply(target, add, [2, 3]),
         apply(lists, reverse, [[1, 2, 3]])}.
      """)
    ]

    assert eval(files) == {:ok, 5, [3, 2, 1]}
  end

  test "snapshot apply preserves throw error and exit classes" do
    files = [
      source("/src/target.erl", """
      -module(target).
      -export([raise/1]).
      raise(throw) -> throw(boom);
      raise(error) -> erlang:error(boom);
      raise(exit) -> exit(boom).
      """),
      source("/src/main.erl", """
      -module(main).
      -export([result/1]).
      result(_) ->
        {capture(throw), capture(error), capture(exit)}.
      capture(Kind) ->
        try apply(target, raise, [Kind]) of
          _ -> ok
        catch
          throw:boom -> throw;
          error:boom -> error;
          exit:boom -> exit
        end.
      """)
    ]

    assert eval(files) == {:throw, :error, :exit}
  end

  test "unknown targets and malformed arguments fail like apply" do
    files = [
      source("/src/main.erl", """
      -module(main).
      -export([result/1]).
      result(_) ->
        {capture(unknown, nope, []),
         capture(main, nope, []),
         capture(main, result, []),
         capture(12, result, []),
         capture(main, result, bad)}.
      capture(M, F, A) ->
        try apply(M, F, A) of
          _ -> ok
        catch
          error:undef -> undef;
          error:badarg -> badarg
        end.
      """)
    ]

    assert eval(files) == {:undef, :undef, :undef, :badarg, :badarg}
  end

  test "plain compile still rejects apply/3" do
    assert {:error, [%{message: message} | _]} =
             Hyperlang.Test.program(
               "result(_) -> apply(lists, reverse, [[1,2]]).",
               @manifest
             )

    assert message =~ "apply"
  end

  test "snapshot closure excludes modules from another compilation" do
    first = [
      source("/src/hidden.erl", """
      -module(hidden).
      -export([value/0]).
      value() -> ok.
      """),
      source("/src/main.erl", """
      -module(main).
      -export([result/1]).
      result(_) -> apply(hidden, value, []).
      """)
    ]

    assert eval(first) == :ok

    second = [
      source("/src/main.erl", """
      -module(main).
      -export([result/1]).
      result(_) ->
        try apply(hidden, value, []) catch error:undef -> undef end.
      """)
    ]

    assert eval(second) == :undef
  end

  defp eval(files) do
    guest_modules = Enum.map(files, &Path.basename(&1.path, ".erl"))

    manifest =
      @manifest
      |> put_in([:modules, :guest_modules], guest_modules)
      |> put_in([:filesystem, :mounts], [
        %{virtual: "/src", backend: "memory", mode: :memory, allow: [:read], files: files}
      ])

    {:ok, normalized} = Hyperlang.Manifest.normalize(manifest)
    {:ok, handle} = Hyperlang.Filesystem.start(normalized.filesystem)

    try do
      {:ok, program} =
        Hyperlang.DoorTestSupport.build_from_filesystem(
          handle,
          %{entry: "/src/main.erl", sources: Enum.map(files, & &1.path)},
          manifest
        )

      assert {:ok, result, _} = Hyperlang.Test.run(program, :entry, [:ok])
      result
    after
      Hyperlang.Filesystem.stop(handle)
    end
  end

  defp source(path, content) do
    %{path: path, content: content}
  end
end
