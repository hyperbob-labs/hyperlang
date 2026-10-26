defmodule HyperlangFilesystemBackendParityTest do
  use ExUnit.Case, async: false

  defp erlang_public(manifest) do
    Map.update(manifest, :terms, %{public: :erlang}, &Map.put(&1, :public, :erlang))
  end

  defp compile_eval!(source, manifest, options \\ %{}) do
    {:ok, program} = Hyperlang.Test.program(source, manifest)

    assert {:ok, result, %{stdout: []}} =
             Hyperlang.Test.run(program, :entry, [:ok], policy: options)

    result
  end

  defp filesystem_manifest(seed) do
    erlang_public(%{
      filesystem: %{
        enabled: true,
        file_compat: true,
        handle_compat: true,
        filelib_compat: true,
        source_compile: true,
        mounts: [
          %{
            virtual: "/mem",
            backend: "memory",
            mode: :memory,
            allow: [:read, :write, :list, :mkdir, :delete, :rename, :stat, :lstat],
            dirs: Keyword.get(seed, :dirs, []),
            files: Keyword.get(seed, :files, [])
          }
        ]
      }
    })
  end

  test "Hyperlang filesystem backend supports normal file operations" do
    source = ~S"""
    ok = file:write_file("/mem/work/a.txt", <<"one">>),
    ok = file:write_file("/mem/work/a.txt", <<"two">>, [append]),
    {ok, <<"onetwo">>} = file:read_file("/mem/work/a.txt"),
    ok = file:write_file("/mem/work/b.txt", <<"fresh">>, [exclusive]),
    {error, eexist} = file:write_file("/mem/work/b.txt", <<"again">>, [exclusive]),
    ok = file:make_dir("/mem/work/dir"),
    {ok, Names0} = file:list_dir("/mem/work"),
    ok = file:rename("/mem/work/a.txt", "/mem/work/c.txt"),
    {error, enoent} = file:read_file("/mem/work/a.txt"),
    {ok, <<"onetwo">>} = file:read_file("/mem/work/c.txt"),
    {ok, Info} = file:read_file_info("/mem/work/b.txt"),
    {ok, LinkInfo} = file:read_link_info("/mem/work/b.txt"),
    ok = file:delete("/mem/work/c.txt"),
    ok = file:del_dir("/mem/work/dir"),
    {ok, Names1} = file:list_dir("/mem/work"),
    #{
      <<"names0">> => lists:sort([list_to_binary(Name) || Name <- Names0]),
      <<"names1">> => lists:sort([list_to_binary(Name) || Name <- Names1]),
      <<"info_size">> => element(2, Info),
      <<"info_type">> => element(3, Info),
      <<"link_info_type">> => element(3, LinkInfo)
    }.
    """

    assert compile_eval!(source, filesystem_manifest(dirs: ["/mem/work"], files: [])) == %{
             <<"names0">> => [<<"a.txt">>, <<"b.txt">>, <<"dir">>],
             <<"names1">> => [<<"b.txt">>],
             <<"info_size">> => 5,
             <<"info_type">> => :regular,
             <<"link_info_type">> => :regular
           }
  end

  test "Hyperlang filesystem backend supports sequential handles and io devices" do
    source = ~S"""
    {ok, R} = file:open("/mem/work/in.txt", [read, binary]),
    {ok, <<"ab">>} = file:read(R, 2),
    {ok, <<"c">>} = file:read(R, 10),
    eof = file:read(R, 1),
    ok = file:close(R),
    {error, ebadf} = file:read(R, 1),

    {ok, W} = file:open("/mem/work/out.txt", [write, binary]),
    ok = file:write(W, [<<"x">>, "y"]),
    ok = io:put_chars(W, "-io"),
    ok = io:nl(W),
    ok = io:format(W, "~s", ["tail"]),
    ok = file:close(W),
    {error, ebadf} = file:write(W, <<"after-close">>),

    {ok, A} = file:open("/mem/work/out.txt", [append, binary]),
    ok = file:write(A, <<"z">>),
    ok = file:close(A),
    {ok, Out} = file:read_file("/mem/work/out.txt"),
    Out.
    """

    assert compile_eval!(
             source,
             filesystem_manifest(
               dirs: ["/mem/work"],
               files: [%{path: "/mem/work/in.txt", content: "abc"}]
             )
           ) == <<"xy-io\ntailz">>
  end

  test "compile_from_filesystem builds immutable source snapshots from the standalone backend" do
    manifest =
      filesystem_manifest(
        dirs: ["/mem/src"],
        files: [
          %{
            path: "/mem/src/demo.erl",
            content: "-module(demo).\nresult(_) -> 42.\n"
          }
        ]
      )

    {:ok, normalized} = Hyperlang.Manifest.normalize(manifest)
    {:ok, filesystem} = Hyperlang.Filesystem.start(normalized.filesystem)

    on_exit(fn -> Hyperlang.Filesystem.stop(filesystem) end)

    assert {:ok, program} =
             Hyperlang.DoorTestSupport.build_from_filesystem(
               filesystem,
               %{entry: "/mem/src/demo.erl", sources: ["/mem/src/demo.erl"]},
               manifest
             )

    assert {:ok, 42, %{stdout: []}} =
             Hyperlang.Test.run(program, :entry, [:ok], policy: %{filesystem: filesystem})
  end
end
