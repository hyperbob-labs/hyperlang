defmodule HyperlangFilesystemFunctionalityTest do
  use ExUnit.Case, async: false

  defp memory_fs(opts \\ []) do
    %{
      enabled: true,
      file_compat: true,
      filelib_compat: true,
      handle_compat: true,
      allow_relative_paths: true,
      cwd: Keyword.get(opts, :cwd, "/mem"),
      commit_policy: Keyword.get(opts, :commit_policy, :per_request),
      limits: Keyword.get(opts, :limits, %{}),
      mounts: [
        %{
          virtual: "/mem",
          backend: "memory",
          mode: :memory,
          allow:
            Keyword.get(opts, :allow, [
              :read,
              :write,
              :list,
              :mkdir,
              :delete,
              :rename,
              :stat,
              :lstat
            ]),
          limits: Keyword.get(opts, :mount_limits, %{}),
          dirs: Keyword.get(opts, :dirs, ["/mem/dir", "/mem/dir/sub", "/mem/empty"]),
          files:
            Keyword.get(opts, :files, [
              %{path: "/mem/a.txt", content: "alpha"},
              %{path: "/mem/dir/b.txt", content: "bravo"},
              %{path: "/mem/dir/sub/c.erl", content: "result(_) -> ok."}
            ]),
          symlinks: Keyword.get(opts, :symlinks, [])
        }
      ]
    }
  end

  defp two_mount_fs do
    %{
      enabled: true,
      file_compat: true,
      filelib_compat: true,
      handle_compat: true,
      allow_relative_paths: true,
      cwd: "/mem",
      mounts: [
        %{
          virtual: "/mem",
          backend: "memory",
          mode: :memory,
          allow: [:read, :write, :list, :mkdir, :delete, :rename, :stat, :lstat],
          dirs: ["/mem/dir"],
          files: [%{path: "/mem/a.txt", content: "alpha"}]
        },
        %{
          virtual: "/other",
          backend: "memory",
          mode: :memory,
          allow: [:read, :write, :list, :mkdir, :delete, :rename, :stat, :lstat],
          dirs: [],
          files: [%{path: "/other/z.txt", content: "zulu"}]
        }
      ]
    }
  end

  defp host_fs(host_dir, opts) do
    %{
      enabled: true,
      file_compat: true,
      filelib_compat: true,
      handle_compat: true,
      allow_relative_paths: true,
      cwd: "/host",
      mounts: [
        %{
          virtual: "/host",
          backend: {:host, host_dir},
          mode: Keyword.get(opts, :mode, :read_only),
          allow:
            Keyword.get(opts, :allow, [
              :read,
              :write,
              :list,
              :mkdir,
              :delete,
              :rename,
              :stat,
              :lstat
            ]),
          limits: Keyword.get(opts, :mount_limits, %{})
        }
      ]
    }
  end

  defp start_fs!(filesystem) do
    {:ok, manifest} =
      Hyperlang.Manifest.normalize(%{terms: %{public: :erlang}, filesystem: filesystem})

    {:ok, handle} = Hyperlang.Filesystem.start(manifest.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(handle) end)
    {manifest, handle}
  end

  defp compile_program!(source, filesystem) do
    {:ok, program} =
      Hyperlang.Test.program(source, %{terms: %{public: :erlang}, filesystem: filesystem})

    program
  end

  defp eval_result!(source, filesystem, input \\ :ok, options \\ []) do
    program = compile_program!(source, filesystem)

    case Hyperlang.Test.run(program, :entry, [input], policy: options) do
      {:ok, result, _} -> result
      other -> flunk("expected successful eval, got #{inspect(other)}")
    end
  end

  defp tmp_dir! do
    dir = Path.join(System.tmp_dir!(), "hyperlang_fs_func_#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  test "direct memory read returns seeded file bytes" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.read_file(fs, "/mem/a.txt") == {:ok, "alpha"}
  end

  test "direct memory read rejects missing path as enoent" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.read_file(fs, "/mem/missing.txt") == {:error, :enoent}
  end

  test "direct memory read rejects directory as eisdir" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.read_file(fs, "/mem/dir") == {:error, :eisdir}
  end

  test "direct memory write creates a file under existing directory" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.write_file(fs, "/mem/dir/new.txt", "new") == {:ok, :ok}
    assert Hyperlang.Filesystem.read_file(fs, "/mem/dir/new.txt") == {:ok, "new"}
  end

  test "direct memory write replaces existing file content" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.write_file(fs, "/mem/a.txt", "omega") == {:ok, :ok}
    assert Hyperlang.Filesystem.read_file(fs, "/mem/a.txt") == {:ok, "omega"}
  end

  test "direct memory write rejects absent parent directory" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.write_file(fs, "/mem/nope/file.txt", "x") == {:error, :enoent}
  end

  test "direct memory write rejects directory target" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.write_file(fs, "/mem/dir", "x") == {:error, :eisdir}
  end

  test "direct memory write accepts nested iodata" do
    {_manifest, fs} = start_fs!(memory_fs())

    assert Hyperlang.Filesystem.write_file(fs, "/mem/iodata.bin", ["a", [<<"b">>, "c"]]) ==
             {:ok, :ok}

    assert Hyperlang.Filesystem.read_file(fs, "/mem/iodata.bin") == {:ok, "abc"}
  end

  test "direct memory write rejects invalid iodata" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.write_file(fs, "/mem/bad.bin", [make_ref()]) == {:error, :badarg}
  end

  test "direct memory write enforces single write byte limit" do
    {_manifest, fs} = start_fs!(memory_fs(files: [], mount_limits: %{max_single_write_bytes: 3}))
    assert Hyperlang.Filesystem.write_file(fs, "/mem/big.txt", "four") == {:error, :enospc}
  end

  test "direct memory list_dir returns sorted direct child names" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.list_dir(fs, "/mem") == {:ok, ["a.txt", "dir", "empty"]}
  end

  test "direct memory list_dir on file returns enotdir" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.list_dir(fs, "/mem/a.txt") == {:error, :enotdir}
  end

  test "direct memory list_dir on missing path returns enoent" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.list_dir(fs, "/mem/nope") == {:error, :enoent}
  end

  test "direct memory make_dir creates one directory" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.make_dir(fs, "/mem/newdir") == {:ok, :ok}
    assert Hyperlang.Filesystem.list_dir(fs, "/mem/newdir") == {:ok, []}
  end

  test "direct memory make_dir rejects existing directory" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.make_dir(fs, "/mem/dir") == {:error, :eexist}
  end

  test "direct memory make_dir rejects file collision" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.make_dir(fs, "/mem/a.txt") == {:error, :eexist}
  end

  test "direct memory ensure_dir creates recursive parents" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.ensure_dir(fs, "/mem/x/y/z") == {:ok, :ok}
    assert Hyperlang.Filesystem.list_dir(fs, "/mem/x/y") == {:ok, ["z"]}
  end

  test "direct memory delete removes a file" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.delete(fs, "/mem/a.txt") == {:ok, :ok}
    assert Hyperlang.Filesystem.read_file(fs, "/mem/a.txt") == {:error, :enoent}
  end

  test "direct memory delete rejects directory target" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.delete(fs, "/mem/dir") == {:error, :eisdir}
  end

  test "direct memory delete rejects missing target" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.delete(fs, "/mem/nope.txt") == {:error, :enoent}
  end

  test "direct memory del_dir removes an empty directory" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.del_dir(fs, "/mem/empty") == {:ok, :ok}
    assert Hyperlang.Filesystem.stat(fs, "/mem/empty") == {:error, :enoent}
  end

  test "direct memory del_dir rejects non-empty directory" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.del_dir(fs, "/mem/dir") == {:error, :enotempty}
  end

  test "direct memory del_dir rejects file target" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.del_dir(fs, "/mem/a.txt") == {:error, :enotdir}
  end

  test "direct memory del_dir rejects mount root" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.del_dir(fs, "/mem") == {:error, :eacces}
  end

  test "direct memory rename moves a file" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.rename(fs, "/mem/a.txt", "/mem/renamed.txt") == {:ok, :ok}
    assert Hyperlang.Filesystem.read_file(fs, "/mem/renamed.txt") == {:ok, "alpha"}
    assert Hyperlang.Filesystem.read_file(fs, "/mem/a.txt") == {:error, :enoent}
  end

  test "direct memory rename overwrites a file" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.rename(fs, "/mem/a.txt", "/mem/dir/b.txt") == {:ok, :ok}
    assert Hyperlang.Filesystem.read_file(fs, "/mem/dir/b.txt") == {:ok, "alpha"}
  end

  test "direct memory rename moves a directory subtree" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.rename(fs, "/mem/dir", "/mem/moved") == {:ok, :ok}
    assert Hyperlang.Filesystem.read_file(fs, "/mem/moved/b.txt") == {:ok, "bravo"}
  end

  test "direct memory rename rejects missing source" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.rename(fs, "/mem/missing", "/mem/target") == {:error, :enoent}
  end

  test "direct memory rename rejects missing target parent" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.rename(fs, "/mem/a.txt", "/mem/nope/target") == {:error, :enoent}
  end

  test "direct memory rename rejects root source" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.rename(fs, "/mem", "/mem/newroot") == {:error, :eacces}
  end

  test "direct memory rename rejects directory into descendant" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.rename(fs, "/mem/dir", "/mem/dir/sub/moved") == {:error, :einval}
  end

  test "direct memory rename rejects cross mount moves" do
    {_manifest, fs} = start_fs!(two_mount_fs())
    assert Hyperlang.Filesystem.rename(fs, "/mem/a.txt", "/other/a.txt") == {:error, :exdev}
  end

  test "direct memory stat reports regular file metadata" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert {:ok, %{type: :regular, size: 5}} = Hyperlang.Filesystem.stat(fs, "/mem/a.txt")
  end

  test "direct memory stat reports directory metadata" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert {:ok, %{type: :directory}} = Hyperlang.Filesystem.stat(fs, "/mem/dir")
  end

  test "direct memory stat follows internal symlink" do
    fs = memory_fs(symlinks: [%{path: "/mem/link.txt", target: "/mem/a.txt"}])
    {_manifest, handle} = start_fs!(fs)
    assert {:ok, %{type: :regular, size: 5}} = Hyperlang.Filesystem.stat(handle, "/mem/link.txt")
  end

  test "direct memory link_stat does not follow internal symlink" do
    fs = memory_fs(symlinks: [%{path: "/mem/link.txt", target: "/mem/a.txt"}])
    {_manifest, handle} = start_fs!(fs)
    assert {:ok, %{type: :symlink}} = Hyperlang.Filesystem.link_stat(handle, "/mem/link.txt")
  end

  test "direct memory stat rejects outbound symlink" do
    fs = memory_fs(symlinks: [%{path: "/mem/out", target: "/other/z.txt", escape: true}])
    {_manifest, handle} = start_fs!(fs)
    assert Hyperlang.Filesystem.stat(handle, "/mem/out") == {:error, :eacces}
  end

  test "direct memory file_info_tuple virtualizes regular file mode" do
    tuple = Hyperlang.Filesystem.file_info_tuple(%{type: :regular, size: 7, mode: 0o4777})
    assert elem(tuple, 0) == :file_info
    assert Bitwise.band(elem(tuple, 7), 0o777) == 0o777
  end

  test "direct memory tree snapshot includes files and directories" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert {:ok, tree} = Hyperlang.Filesystem.tree(fs)
    assert tree["/mem/a.txt"].type == :file
    assert tree["/mem/dir"].type == :dir
  end

  test "direct memory snapshot includes cwd tree and diff" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert {:ok, snapshot} = Hyperlang.Filesystem.snapshot(fs)
    assert snapshot.cwd == "/mem"
    assert snapshot.diff == %{created: [], modified: [], deleted: []}
  end

  test "direct memory export includes directory and file content" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert {:ok, export} = Hyperlang.Filesystem.export(fs)
    assert "/mem/dir" in export.directories
    assert Enum.any?(export.files, &(&1.path == "/mem/a.txt" and &1.content == "alpha"))
  end

  test "direct memory export can materialize to host directory" do
    dir = tmp_dir!()
    {_manifest, fs} = start_fs!(memory_fs())
    assert {:ok, export} = Hyperlang.Filesystem.export(fs, materialize_to: dir)
    assert export.materialized_to == dir
    assert File.read!(Path.join(dir, "mem/a.txt")) == "alpha"
  end

  test "direct memory rejects null byte paths" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.read_file(fs, <<"/mem/a", 0, ".txt">>) == {:error, :invalid_path}
  end

  test "direct memory rejects backslash paths" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.read_file(fs, "/mem\\a.txt") == {:error, :invalid_path}
  end

  test "direct memory rejects trailing slash file path" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.read_file(fs, "/mem/a.txt/") == {:error, :invalid_path}
  end

  test "direct memory resolves charlist paths" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.read_file(fs, ~c"/mem/a.txt") == {:ok, "alpha"}
  end

  test "direct memory rejects invalid path list" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.read_file(fs, ["/mem/a.txt"]) == {:error, :badarg}
  end

  test "direct memory no matching mount returns eacces" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert Hyperlang.Filesystem.read_file(fs, "/other/a.txt") == {:error, :eacces}
  end

  test "direct read permission denial returns eacces" do
    {_manifest, fs} =
      start_fs!(memory_fs(allow: [:write, :list, :mkdir, :delete, :rename, :stat, :lstat]))

    assert Hyperlang.Filesystem.read_file(fs, "/mem/a.txt") == {:error, :eacces}
  end

  test "direct write permission denial returns eacces" do
    {_manifest, fs} =
      start_fs!(memory_fs(allow: [:read, :list, :mkdir, :delete, :rename, :stat, :lstat]))

    assert Hyperlang.Filesystem.write_file(fs, "/mem/x.txt", "x") == {:error, :eacces}
  end

  test "direct list permission denial returns eacces" do
    {_manifest, fs} =
      start_fs!(memory_fs(allow: [:read, :write, :mkdir, :delete, :rename, :stat, :lstat]))

    assert Hyperlang.Filesystem.list_dir(fs, "/mem") == {:error, :eacces}
  end

  test "direct mkdir permission denial returns eacces" do
    {_manifest, fs} =
      start_fs!(memory_fs(allow: [:read, :write, :list, :delete, :rename, :stat, :lstat]))

    assert Hyperlang.Filesystem.make_dir(fs, "/mem/new") == {:error, :eacces}
  end

  test "direct delete permission denial returns eacces" do
    {_manifest, fs} =
      start_fs!(memory_fs(allow: [:read, :write, :list, :mkdir, :rename, :stat, :lstat]))

    assert Hyperlang.Filesystem.delete(fs, "/mem/a.txt") == {:error, :eacces}
  end

  test "direct rename permission denial returns eacces" do
    {_manifest, fs} =
      start_fs!(memory_fs(allow: [:read, :write, :list, :mkdir, :delete, :stat, :lstat]))

    assert Hyperlang.Filesystem.rename(fs, "/mem/a.txt", "/mem/b.txt") == {:error, :eacces}
  end

  test "direct stat permission denial returns eacces" do
    {_manifest, fs} =
      start_fs!(memory_fs(allow: [:read, :write, :list, :mkdir, :delete, :rename, :lstat]))

    assert Hyperlang.Filesystem.stat(fs, "/mem/a.txt") == {:error, :eacces}
  end

  test "guest file read_file returns OTP tuple" do
    result = eval_result!(~S|file:read_file("/mem/a.txt").|, memory_fs())
    assert result == {:ok, "alpha"}
  end

  test "guest file read_file accepts charlist path" do
    result = eval_result!(~S|file:read_file("/mem/a.txt").|, memory_fs())
    assert result == {:ok, "alpha"}
  end

  test "guest file write_file creates readable file" do
    result =
      eval_result!(
        ~S|
        ok = file:write_file("/mem/guest.txt", <<"guest">>),
        file:read_file("/mem/guest.txt").
        |,
        memory_fs()
      )

    assert result == {:ok, "guest"}
  end

  test "guest file write_file append mode appends" do
    result =
      eval_result!(
        ~S|
        ok = file:write_file("/mem/a.txt", <<"!">>, [append]),
        file:read_file("/mem/a.txt").
        |,
        memory_fs()
      )

    assert result == {:ok, "alpha!"}
  end

  test "guest file write_file exclusive mode rejects existing file" do
    result = eval_result!(~S|file:write_file("/mem/a.txt", <<"x">>, [exclusive]).|, memory_fs())
    assert result == {:error, :eexist}
  end

  test "guest file write_file exclusive mode creates missing file" do
    result =
      eval_result!(
        ~S|
        ok = file:write_file("/mem/new.txt", <<"new">>, [exclusive]),
        file:read_file("/mem/new.txt").
        |,
        memory_fs()
      )

    assert result == {:ok, "new"}
  end

  test "guest file write_file invalid mode returns badarg tuple" do
    result =
      eval_result!(~S|file:write_file("/mem/a.txt", <<"x">>, [definitely_bad]).|, memory_fs())

    assert result == {:error, :badarg}
  end

  test "guest file list_dir returns charlists" do
    result = eval_result!(~S|file:list_dir("/mem").|, memory_fs())
    assert result == {:ok, [~c"a.txt", ~c"dir", ~c"empty"]}
  end

  test "guest file make_dir returns ok atom" do
    result =
      eval_result!(
        ~S|
        ok = file:make_dir("/mem/made"),
        file:list_dir("/mem/made").
        |,
        memory_fs()
      )

    assert result == {:ok, []}
  end

  test "guest file del_dir returns ok for empty directory" do
    result =
      eval_result!(
        ~S|
        ok = file:del_dir("/mem/empty"),
        file:read_file_info("/mem/empty").
        |,
        memory_fs()
      )

    assert result == {:error, :enoent}
  end

  test "guest file delete returns ok for files" do
    result =
      eval_result!(
        ~S|
        ok = file:delete("/mem/a.txt"),
        file:read_file("/mem/a.txt").
        |,
        memory_fs()
      )

    assert result == {:error, :enoent}
  end

  test "guest file rename returns ok and moves file" do
    result =
      eval_result!(
        ~S|
        ok = file:rename("/mem/a.txt", "/mem/r.txt"),
        file:read_file("/mem/r.txt").
        |,
        memory_fs()
      )

    assert result == {:ok, "alpha"}
  end

  test "guest file read_file_info returns file_info record tuple" do
    result = eval_result!(~S|file:read_file_info("/mem/a.txt").|, memory_fs())
    assert {:ok, {:file_info, 5, :regular, :read_write, _, _, _, _, 1, 0, 0, 0, 0, 0}} = result
  end

  test "guest file read_link_info returns symlink metadata" do
    fs = memory_fs(symlinks: [%{path: "/mem/link.txt", target: "/mem/a.txt"}])
    result = eval_result!(~S|file:read_link_info("/mem/link.txt").|, fs)
    assert {:ok, {:file_info, _size, :symlink, _access, _, _, _, _, 1, 0, 0, 0, 0, 0}} = result
  end

  test "guest file get_cwd returns virtual cwd as charlist" do
    result = eval_result!(~S|file:get_cwd().|, memory_fs())
    assert result == {:ok, ~c"/mem"}
  end

  test "guest file get_cwd drive returns enotsup for charlist drive" do
    result = eval_result!(~S|file:get_cwd("C:").|, memory_fs())
    assert result == {:error, :enotsup}
  end

  test "guest file set_cwd changes relative path base" do
    result =
      eval_result!(
        ~S|
        ok = file:set_cwd("/mem/dir"),
        file:read_file("b.txt").
        |,
        memory_fs()
      )

    assert result == {:ok, "bravo"}
  end

  test "guest relative paths resolve from initial virtual cwd" do
    result = eval_result!(~S|file:read_file("a.txt").|, memory_fs())
    assert result == {:ok, "alpha"}
  end

  test "guest set_cwd rejects non-directory file" do
    result = eval_result!(~S|file:set_cwd("/mem/a.txt").|, memory_fs())
    assert result == {:error, :enotdir}
  end

  test "guest set_cwd rejects missing directory" do
    result = eval_result!(~S|file:set_cwd("/mem/nope").|, memory_fs())
    assert result == {:error, :enoent}
  end

  test "guest file disabled call fails at compile time" do
    assert {:error, [error]} =
             Hyperlang.Test.program(~S|file:read_file("/mem/a.txt").|, %{
               filesystem: %{enabled: false}
             })

    assert error.details.reason == :filesystem_disabled
  end

  test "guest file handle compatibility disabled rejects open" do
    fs = %{memory_fs() | handle_compat: false}

    assert {:error, [error]} =
             Hyperlang.Test.program(~S|file:open("/mem/a.txt", [read]).|, %{
               filesystem: fs
             })

    assert error.details.reason == :handle_compat_disabled
  end

  test "guest file open read can read chunks and eof" do
    result =
      eval_result!(
        ~S|
        {ok, Io} = file:open("/mem/a.txt", [read, binary]),
        {ok, A} = file:read(Io, 2),
        {ok, B} = file:read(Io, 10),
        eof = file:read(Io, 1),
        ok = file:close(Io),
        {A, B}.
        |,
        memory_fs()
      )

    assert result == {"al", "pha"}
  end

  test "guest file open read with zero count returns empty binary" do
    result =
      eval_result!(
        ~S|
        {ok, Io} = file:open("/mem/a.txt", [read, binary]),
        file:read(Io, 0).
        |,
        memory_fs()
      )

    assert result == {:ok, ""}
  end

  test "guest file open write truncates existing file" do
    result =
      eval_result!(
        ~S|
        {ok, Io} = file:open("/mem/a.txt", [write, binary]),
        ok = file:write(Io, <<"x">>),
        ok = file:close(Io),
        file:read_file("/mem/a.txt").
        |,
        memory_fs()
      )

    assert result == {:ok, "x"}
  end

  test "guest file open append writes at file end" do
    result =
      eval_result!(
        ~S|
        {ok, Io} = file:open("/mem/a.txt", [append, binary]),
        ok = file:write(Io, <<"z">>),
        ok = file:close(Io),
        file:read_file("/mem/a.txt").
        |,
        memory_fs()
      )

    assert result == {:ok, "alphaz"}
  end

  test "guest file open exclusive rejects existing file" do
    result = eval_result!(~S|file:open("/mem/a.txt", [write, exclusive, binary]).|, memory_fs())
    assert result == {:error, :eexist}
  end

  test "guest file open exclusive creates missing file" do
    result =
      eval_result!(
        ~S|
        {ok, Io} = file:open("/mem/new.bin", [write, exclusive, binary]),
        ok = file:write(Io, <<"new">>),
        ok = file:close(Io),
        file:read_file("/mem/new.bin").
        |,
        memory_fs()
      )

    assert result == {:ok, "new"}
  end

  test "guest file read on write-only handle returns ebadf" do
    result =
      eval_result!(
        ~S|
        {ok, Io} = file:open("/mem/out.bin", [write, binary]),
        file:read(Io, 1).
        |,
        memory_fs()
      )

    assert result == {:error, :ebadf}
  end

  test "guest file write on read-only handle returns ebadf" do
    result =
      eval_result!(
        ~S|
        {ok, Io} = file:open("/mem/a.txt", [read, binary]),
        file:write(Io, <<"x">>).
        |,
        memory_fs()
      )

    assert result == {:error, :ebadf}
  end

  test "guest file close already closed handle returns ebadf" do
    result =
      eval_result!(
        ~S|
        {ok, Io} = file:open("/mem/a.txt", [read, binary]),
        ok = file:close(Io),
        file:close(Io).
        |,
        memory_fs()
      )

    assert result == {:error, :ebadf}
  end

  test "guest file read invalid count returns badarg" do
    result =
      eval_result!(
        ~S|
        {ok, Io} = file:open("/mem/a.txt", [read, binary]),
        file:read(Io, -1).
        |,
        memory_fs()
      )

    assert result == {:error, :badarg}
  end

  test "guest filelib is_file true for file" do
    result = eval_result!(~S|filelib:is_file("/mem/a.txt").|, memory_fs())
    assert result == true
  end

  test "guest filelib is_file true for accessible directory path" do
    result = eval_result!(~S|filelib:is_file("/mem/dir").|, memory_fs())
    assert result == true
  end

  test "guest filelib is_dir true for directory" do
    result = eval_result!(~S|filelib:is_dir("/mem/dir").|, memory_fs())
    assert result == true
  end

  test "guest filelib is_dir false for missing path" do
    result = eval_result!(~S|filelib:is_dir("/mem/nope").|, memory_fs())
    assert result == false
  end

  test "guest filelib ensure_dir creates parent directory of file path" do
    result =
      eval_result!(
        ~S|
        ok = filelib:ensure_dir("/mem/new/child.txt"),
        filelib:is_dir("/mem/new").
        |,
        memory_fs()
      )

    assert result == true
  end

  test "guest filelib ensure_dir with trailing slash creates nested directory" do
    result =
      eval_result!(
        ~S|
        ok = filelib:ensure_dir("/mem/new/child/"),
        filelib:is_dir("/mem/new/child").
        |,
        memory_fs()
      )

    assert result == true
  end

  test "guest filelib ensure_dir reports eexist through file parent" do
    result = eval_result!(~S|filelib:ensure_dir("/mem/a.txt/child.txt").|, memory_fs())
    assert result == {:error, :eexist}
  end

  test "guest filelib wildcard matches absolute pattern" do
    result = eval_result!(~S|filelib:wildcard("/mem/*.txt").|, memory_fs())
    assert result == [~c"/mem/a.txt"]
  end

  test "guest filelib wildcard returns empty list for no match" do
    result = eval_result!(~S|filelib:wildcard("/mem/*.missing").|, memory_fs())
    assert result == []
  end

  test "guest filelib wildcard supports recursive starstar" do
    result = eval_result!(~S|filelib:wildcard("/mem/**/*.erl").|, memory_fs())
    assert result == [~c"/mem/dir/sub/c.erl"]
  end

  test "guest filelib wildcard supports cwd arity" do
    result = eval_result!(~S|filelib:wildcard("*.txt", "/mem").|, memory_fs())
    assert result == [~c"a.txt"]
  end

  test "guest filelib wildcard supports explicit file module arity" do
    result = eval_result!(~S|filelib:wildcard("*.txt", "/mem", file).|, memory_fs())
    assert result == [~c"a.txt"]
  end

  test "direct filelib wildcard rejects non-file callback module" do
    {_manifest, fs} = start_fs!(memory_fs())

    assert Hyperlang.Filesystem.dispatch(fs, :wildcard, [~c"*.txt", ~c"/mem", :other]) ==
             {:error, :badarg}
  end

  test "guest filelib compatibility disabled rejects filelib call" do
    fs = %{memory_fs() | filelib_compat: false}

    assert {:error, [error]} =
             Hyperlang.Test.program(~S|filelib:is_file("/mem/a.txt").|, %{filesystem: fs})

    assert error.details.reason == :filelib_compat_disabled
  end

  test "direct on_eval_success transaction commits successful write" do
    {_manifest, fs} = start_fs!(memory_fs(commit_policy: :on_eval_success))
    assert Hyperlang.Filesystem.begin_eval(fs, 101) == {:ok, :ok}

    assert Hyperlang.Filesystem.dispatch(fs, :write_file, ["/mem/tx.txt", "tx"], %{call_id: 101}) ==
             {:ok, :ok}

    assert Hyperlang.Filesystem.read_file(fs, "/mem/tx.txt") == {:error, :enoent}
    assert Hyperlang.Filesystem.finish_eval(fs, 101, :success) == {:ok, :ok}
    assert Hyperlang.Filesystem.read_file(fs, "/mem/tx.txt") == {:ok, "tx"}
  end

  test "direct on_eval_success transaction rolls back failed write" do
    {_manifest, fs} = start_fs!(memory_fs(commit_policy: :on_eval_success))
    assert Hyperlang.Filesystem.begin_eval(fs, 102) == {:ok, :ok}

    assert Hyperlang.Filesystem.dispatch(fs, :write_file, ["/mem/tx.txt", "tx"], %{call_id: 102}) ==
             {:ok, :ok}

    assert Hyperlang.Filesystem.finish_eval(fs, 102, :error) == {:ok, :ok}
    assert Hyperlang.Filesystem.read_file(fs, "/mem/tx.txt") == {:error, :enoent}
  end

  test "direct manual transaction exposes created diff" do
    {_manifest, fs} = start_fs!(memory_fs(commit_policy: :manual))
    assert Hyperlang.Filesystem.begin_eval(fs, 103) == {:ok, :ok}

    assert Hyperlang.Filesystem.dispatch(fs, :write_file, ["/mem/manual.txt", "m"], %{
             call_id: 103
           }) ==
             {:ok, :ok}

    assert Hyperlang.Filesystem.finish_eval(fs, 103, :success) == {:ok, :ok}

    assert Hyperlang.Filesystem.diff(fs) ==
             {:ok, %{created: ["/mem/manual.txt"], modified: [], deleted: []}}
  end

  test "direct manual transaction commit persists staged file" do
    {_manifest, fs} = start_fs!(memory_fs(commit_policy: :manual))
    assert Hyperlang.Filesystem.begin_eval(fs, 104) == {:ok, :ok}

    assert Hyperlang.Filesystem.dispatch(fs, :write_file, ["/mem/manual.txt", "m"], %{
             call_id: 104
           }) ==
             {:ok, :ok}

    assert Hyperlang.Filesystem.finish_eval(fs, 104, :success) == {:ok, :ok}
    assert Hyperlang.Filesystem.commit(fs) == {:ok, :ok}
    assert Hyperlang.Filesystem.read_file(fs, "/mem/manual.txt") == {:ok, "m"}
  end

  test "direct manual transaction rollback drops staged file" do
    {_manifest, fs} = start_fs!(memory_fs(commit_policy: :manual))
    assert Hyperlang.Filesystem.begin_eval(fs, 105) == {:ok, :ok}

    assert Hyperlang.Filesystem.dispatch(fs, :write_file, ["/mem/manual.txt", "m"], %{
             call_id: 105
           }) ==
             {:ok, :ok}

    assert Hyperlang.Filesystem.finish_eval(fs, 105, :success) == {:ok, :ok}
    assert Hyperlang.Filesystem.rollback(fs) == {:ok, :ok}
    assert Hyperlang.Filesystem.read_file(fs, "/mem/manual.txt") == {:error, :enoent}
  end

  test "direct manual transaction exposes modified diff" do
    {_manifest, fs} = start_fs!(memory_fs(commit_policy: :manual))
    assert Hyperlang.Filesystem.begin_eval(fs, 106) == {:ok, :ok}

    assert Hyperlang.Filesystem.dispatch(fs, :write_file, ["/mem/a.txt", "changed"], %{
             call_id: 106
           }) ==
             {:ok, :ok}

    assert Hyperlang.Filesystem.finish_eval(fs, 106, :success) == {:ok, :ok}

    assert Hyperlang.Filesystem.diff(fs) ==
             {:ok, %{created: [], modified: ["/mem/a.txt"], deleted: []}}
  end

  test "direct manual transaction exposes deleted diff" do
    {_manifest, fs} = start_fs!(memory_fs(commit_policy: :manual))
    assert Hyperlang.Filesystem.begin_eval(fs, 107) == {:ok, :ok}

    assert Hyperlang.Filesystem.dispatch(fs, :delete, ["/mem/a.txt"], %{call_id: 107}) ==
             {:ok, :ok}

    assert Hyperlang.Filesystem.finish_eval(fs, 107, :success) == {:ok, :ok}

    assert Hyperlang.Filesystem.diff(fs) ==
             {:ok, %{created: [], modified: [], deleted: ["/mem/a.txt"]}}
  end

  test "direct stale eval request is rejected for transactional policy" do
    {_manifest, fs} = start_fs!(memory_fs(commit_policy: :on_eval_success))

    assert Hyperlang.Filesystem.dispatch(fs, :write_file, ["/mem/stale.txt", "x"], %{call_id: 108}) ==
             {:ok, {:error, :stale_eval_request}}
  end

  test "direct lifecycle API rejects non-integer call ids" do
    {_manifest, fs} = start_fs!(memory_fs(commit_policy: :on_eval_success))
    call_id = make_ref()

    assert Hyperlang.Filesystem.begin_eval(fs, call_id) == {:error, :missing_call_id}
    assert Hyperlang.Filesystem.close_call_handles(fs, call_id) == {:error, :missing_call_id}
    assert Hyperlang.Filesystem.finish_eval(fs, call_id, :failure) == {:error, :missing_call_id}

    assert {:ok, %{open_handle_count: 0, transaction_count: 0}} =
             Hyperlang.Filesystem.server_info(fs)
  end

  test "direct stale begin_eval cannot reactivate completed transactional call" do
    {_manifest, fs} = start_fs!(memory_fs(commit_policy: :on_eval_success))
    call_id = 113
    ctx = %{call_id: call_id}

    assert Hyperlang.Filesystem.begin_eval(fs, call_id) == {:ok, :ok}

    assert Hyperlang.Filesystem.dispatch(fs, :write_file, ["/mem/replayed.txt", "first"], ctx) ==
             {:ok, :ok}

    assert Hyperlang.Filesystem.finish_eval(fs, call_id, :success) == {:ok, :ok}
    assert Hyperlang.Filesystem.read_file(fs, "/mem/replayed.txt") == {:ok, "first"}
    assert Hyperlang.Filesystem.begin_eval(fs, call_id) == {:error, :stale_eval_request}

    assert Hyperlang.Filesystem.dispatch(fs, :write_file, ["/mem/replayed.txt", "stale"], ctx) ==
             {:ok, {:error, :stale_eval_request}}

    assert Hyperlang.Filesystem.read_file(fs, "/mem/replayed.txt") == {:ok, "first"}
  end

  test "direct finish_eval closes call-scoped handles" do
    {_manifest, fs} = start_fs!(memory_fs())
    call_id = 109
    ctx = %{call_id: call_id}

    assert Hyperlang.Filesystem.begin_eval(fs, call_id) == {:ok, :ok}

    assert {:ok, _io} =
             Hyperlang.Filesystem.dispatch(fs, :open, ["/mem/a.txt", [:read, :binary]], ctx)

    assert {:ok, %{open_handle_count: 1}} = Hyperlang.Filesystem.server_info(fs)
    assert Hyperlang.Filesystem.finish_eval(fs, call_id, :success) == {:ok, :ok}

    assert {:ok, %{open_handle_count: 0, transaction_count: 0}} =
             Hyperlang.Filesystem.server_info(fs)
  end

  test "direct close_call_handles tears down transactional eval state" do
    {_manifest, fs} = start_fs!(memory_fs(commit_policy: :on_eval_success))
    call_id = 110
    ctx = %{call_id: call_id}

    assert Hyperlang.Filesystem.begin_eval(fs, call_id) == {:ok, :ok}

    assert Hyperlang.Filesystem.dispatch(fs, :write_file, ["/mem/leaked.txt", "x"], ctx) ==
             {:ok, :ok}

    assert Hyperlang.Filesystem.close_call_handles(fs, call_id) == {:ok, :ok}

    assert {:ok, %{open_handle_count: 0, transaction_count: 0}} =
             Hyperlang.Filesystem.server_info(fs)

    assert Hyperlang.Filesystem.begin_eval(fs, call_id) == {:error, :stale_eval_request}
    assert Hyperlang.Filesystem.read_file(fs, "/mem/leaked.txt") == {:error, :enoent}
  end

  test "direct stale finish_eval does not drop pending manual transaction" do
    {_manifest, fs} = start_fs!(memory_fs(commit_policy: :manual))
    call_id = 111
    ctx = %{call_id: call_id}

    assert Hyperlang.Filesystem.begin_eval(fs, call_id) == {:ok, :ok}

    assert Hyperlang.Filesystem.dispatch(fs, :write_file, ["/mem/manual.txt", "m"], ctx) ==
             {:ok, :ok}

    assert Hyperlang.Filesystem.finish_eval(fs, call_id, :success) == {:ok, :ok}
    assert Hyperlang.Filesystem.close_call_handles(fs, call_id) == {:ok, :ok}

    assert Hyperlang.Filesystem.diff(fs) ==
             {:ok, %{created: ["/mem/manual.txt"], modified: [], deleted: []}}

    assert Hyperlang.Filesystem.finish_eval(fs, call_id, :failure) ==
             {:error, :stale_eval_request}

    assert Hyperlang.Filesystem.commit(fs) == {:ok, :ok}
    assert Hyperlang.Filesystem.read_file(fs, "/mem/manual.txt") == {:ok, "m"}
  end

  test "duplicate begin_eval cannot reactivate pending manual transaction" do
    {_manifest, fs} = start_fs!(memory_fs(commit_policy: :manual))
    call_id = 112
    ctx = %{call_id: call_id}

    assert Hyperlang.Filesystem.begin_eval(fs, call_id) == {:ok, :ok}

    assert Hyperlang.Filesystem.dispatch(fs, :write_file, ["/mem/manual.txt", "m"], ctx) ==
             {:ok, :ok}

    assert Hyperlang.Filesystem.finish_eval(fs, call_id, :success) == {:ok, :ok}
    assert Hyperlang.Filesystem.begin_eval(fs, call_id) == {:error, :stale_eval_request}

    assert Hyperlang.Filesystem.finish_eval(fs, call_id, :failure) ==
             {:error, :stale_eval_request}

    assert Hyperlang.Filesystem.commit(fs) == {:ok, :ok}
    assert Hyperlang.Filesystem.read_file(fs, "/mem/manual.txt") == {:ok, "m"}
  end

  test "failed begin_eval consumes call id while manual commit is pending" do
    {_manifest, fs} = start_fs!(memory_fs(commit_policy: :manual))
    assert Hyperlang.Filesystem.begin_eval(fs, 1) == {:ok, :ok}

    assert Hyperlang.Filesystem.dispatch(fs, :write_file, ["/mem/manual.txt", "m"], %{call_id: 1}) ==
             {:ok, :ok}

    assert Hyperlang.Filesystem.finish_eval(fs, 1, :success) == {:ok, :ok}
    assert Hyperlang.Filesystem.begin_eval(fs, 2) == {:error, :manual_commit_pending}
    assert Hyperlang.Filesystem.commit(fs) == {:ok, :ok}
    assert Hyperlang.Filesystem.begin_eval(fs, 2) == {:error, :stale_eval_request}
    assert Hyperlang.Filesystem.begin_eval(fs, 3) == {:ok, :ok}
    assert Hyperlang.Filesystem.finish_eval(fs, 3, :success) == {:ok, :ok}
  end

  test "host read-only backend reads host file" do
    dir = tmp_dir!()
    File.write!(Path.join(dir, "a.txt"), "host")

    {_manifest, fs} =
      start_fs!(host_fs(dir, mode: :read_only, allow: [:read, :list, :stat, :lstat]))

    assert Hyperlang.Filesystem.read_file(fs, "/host/a.txt") == {:ok, "host"}
  end

  test "host read-only backend lists host directory" do
    dir = tmp_dir!()
    File.write!(Path.join(dir, "a.txt"), "host")
    File.mkdir_p!(Path.join(dir, "sub"))

    {_manifest, fs} =
      start_fs!(host_fs(dir, mode: :read_only, allow: [:read, :list, :stat, :lstat]))

    assert Hyperlang.Filesystem.list_dir(fs, "/host") == {:ok, ["a.txt", "sub"]}
  end

  test "host read-only backend stats host file" do
    dir = tmp_dir!()
    File.write!(Path.join(dir, "a.txt"), "host")

    {_manifest, fs} =
      start_fs!(host_fs(dir, mode: :read_only, allow: [:read, :list, :stat, :lstat]))

    assert {:ok, %{type: :regular, size: 4}} = Hyperlang.Filesystem.stat(fs, "/host/a.txt")
  end

  test "host read-only backend rejects writes as erofs" do
    dir = tmp_dir!()

    {_manifest, fs} =
      start_fs!(host_fs(dir, mode: :read_only, allow: [:read, :write, :list, :stat, :lstat]))

    assert Hyperlang.Filesystem.write_file(fs, "/host/a.txt", "x") == {:error, :erofs}
  end

  test "host read-only backend follows existing symlink reads" do
    dir = tmp_dir!()
    outside = tmp_dir!()
    File.write!(Path.join(outside, "secret.txt"), "secret")
    File.ln_s!(Path.join(outside, "secret.txt"), Path.join(dir, "link.txt"))

    {_manifest, fs} =
      start_fs!(host_fs(dir, mode: :read_only, allow: [:read, :list, :stat, :lstat]))

    assert Hyperlang.Filesystem.read_file(fs, "/host/link.txt") == {:ok, "secret"}
    assert {:ok, %{type: :regular, size: 6}} = Hyperlang.Filesystem.stat(fs, "/host/link.txt")
    assert {:ok, %{type: :symlink}} = Hyperlang.Filesystem.link_stat(fs, "/host/link.txt")
  end

  test "host backend follows swapped symlink ancestors using standard host semantics" do
    dir = tmp_dir!()
    outside = tmp_dir!()

    File.mkdir_p!(Path.join(dir, "safe"))
    File.write!(Path.join(dir, "safe/a.txt"), "inside")
    File.write!(Path.join(outside, "a.txt"), "outside")

    {_manifest, fs} =
      start_fs!(host_fs(dir, mode: :read_only, allow: [:read, :list, :stat, :lstat]))

    assert Hyperlang.Filesystem.read_file(fs, "/host/safe/a.txt") == {:ok, "inside"}
    assert {:ok, %{type: :directory}} = Hyperlang.Filesystem.stat(fs, "/host/safe")

    File.rm_rf!(Path.join(dir, "safe"))

    case File.ln_s(outside, Path.join(dir, "safe")) do
      :ok ->
        assert Hyperlang.Filesystem.read_file(fs, "/host/safe/a.txt") == {:ok, "outside"}

        assert {:ok, %{type: :regular, size: 7}} =
                 Hyperlang.Filesystem.stat(fs, "/host/safe/a.txt")

        assert Hyperlang.Filesystem.list_dir(fs, "/host/safe") == {:ok, ["a.txt"]}
        assert {:ok, %{type: :symlink}} = Hyperlang.Filesystem.link_stat(fs, "/host/safe")

      {:error, :enotsup} ->
        :ok
    end
  end

  test "host backend rejects direct mutations instead of downgrading to host writes" do
    dir = tmp_dir!()
    outside = tmp_dir!()

    File.write!(Path.join(dir, "a.txt"), "inside")
    File.write!(Path.join(outside, "secret.txt"), "outside")

    {_manifest, fs} =
      start_fs!(
        host_fs(dir,
          mode: :read_write,
          allow: [:read, :write, :list, :mkdir, :delete, :rename, :stat, :lstat]
        )
      )

    assert Hyperlang.Filesystem.write_file(fs, "/host/new.txt", "new") == {:error, :enotsup}
    assert Hyperlang.Filesystem.make_dir(fs, "/host/new-dir") == {:error, :enotsup}
    assert Hyperlang.Filesystem.delete(fs, "/host/a.txt") == {:error, :enotsup}
    assert Hyperlang.Filesystem.rename(fs, "/host/a.txt", "/host/b.txt") == {:error, :enotsup}

    refute File.exists?(Path.join(dir, "new.txt"))
    refute File.exists?(Path.join(dir, "new-dir"))
    assert File.read!(Path.join(dir, "a.txt")) == "inside"
    assert File.read!(Path.join(outside, "secret.txt")) == "outside"
  end

  test "host backend caps directory enumeration before returning names" do
    dir = tmp_dir!()
    File.write!(Path.join(dir, "a.txt"), "a")
    File.write!(Path.join(dir, "b.txt"), "b")

    {_manifest, fs} =
      start_fs!(
        host_fs(dir,
          mode: :read_only,
          allow: [:list],
          mount_limits: %{max_dir_entries: 1, max_dir_result_bytes: 1_000}
        )
      )

    assert Hyperlang.Filesystem.list_dir(fs, "/host") == {:error, :eoverflow}
  end

  test "snapshot backend freezes host file content" do
    dir = tmp_dir!()
    File.write!(Path.join(dir, "a.txt"), "one")

    {_manifest, fs} =
      start_fs!(host_fs(dir, mode: :snapshot, allow: [:read, :list, :stat, :lstat]))

    File.write!(Path.join(dir, "a.txt"), "two")
    assert Hyperlang.Filesystem.read_file(fs, "/host/a.txt") == {:ok, "one"}
  end

  test "snapshot backend includes nested host files" do
    dir = tmp_dir!()
    File.mkdir_p!(Path.join(dir, "sub"))
    File.write!(Path.join(dir, "sub/a.txt"), "nested")

    {_manifest, fs} =
      start_fs!(host_fs(dir, mode: :snapshot, allow: [:read, :list, :stat, :lstat]))

    assert Hyperlang.Filesystem.read_file(fs, "/host/sub/a.txt") == {:ok, "nested"}
  end

  test "snapshot backend is not affected by host file deletion" do
    dir = tmp_dir!()
    File.write!(Path.join(dir, "a.txt"), "one")

    {_manifest, fs} =
      start_fs!(host_fs(dir, mode: :snapshot, allow: [:read, :list, :stat, :lstat]))

    File.rm!(Path.join(dir, "a.txt"))
    assert Hyperlang.Filesystem.read_file(fs, "/host/a.txt") == {:ok, "one"}
  end

  test "overlay backend reads host file before local modification" do
    dir = tmp_dir!()
    File.write!(Path.join(dir, "a.txt"), "host")
    {_manifest, fs} = start_fs!(host_fs(dir, mode: :overlay))
    assert Hyperlang.Filesystem.read_file(fs, "/host/a.txt") == {:ok, "host"}
  end

  test "overlay backend writes shadow host file without touching host" do
    dir = tmp_dir!()
    File.write!(Path.join(dir, "a.txt"), "host")
    {_manifest, fs} = start_fs!(host_fs(dir, mode: :overlay))
    assert Hyperlang.Filesystem.write_file(fs, "/host/a.txt", "overlay") == {:ok, :ok}
    assert Hyperlang.Filesystem.read_file(fs, "/host/a.txt") == {:ok, "overlay"}
    assert File.read!(Path.join(dir, "a.txt")) == "host"
  end

  test "overlay backend delete hides host file" do
    dir = tmp_dir!()
    File.write!(Path.join(dir, "a.txt"), "host")
    {_manifest, fs} = start_fs!(host_fs(dir, mode: :overlay))
    assert Hyperlang.Filesystem.delete(fs, "/host/a.txt") == {:ok, :ok}
    assert Hyperlang.Filesystem.read_file(fs, "/host/a.txt") == {:error, :enoent}
    assert File.read!(Path.join(dir, "a.txt")) == "host"
  end

  test "overlay backend list merges host and overlay names" do
    dir = tmp_dir!()
    File.write!(Path.join(dir, "a.txt"), "host")
    {_manifest, fs} = start_fs!(host_fs(dir, mode: :overlay))
    assert Hyperlang.Filesystem.write_file(fs, "/host/b.txt", "overlay") == {:ok, :ok}
    assert Hyperlang.Filesystem.list_dir(fs, "/host") == {:ok, ["a.txt", "b.txt"]}
  end

  test "compile_from_filesystem compiles source snapshot entry" do
    {_manifest, fs} =
      start_fs!(
        memory_fs(
          files: [%{path: "/mem/main.erl", content: "-module(main).\nresult(_) -> 41 + 1."}]
        )
      )

    manifest = %{
      terms: %{public: :erlang},
      filesystem: %{enabled: true, source_compile: true, file_compat: true, mounts: []}
    }

    assert {:ok, program} =
             Hyperlang.DoorTestSupport.build_from_filesystem(
               fs,
               %{entry: "/mem/main.erl", sources: ["/mem/main.erl"]},
               manifest
             )

    assert {:ok, 42, _} = Hyperlang.Test.run(program, :entry, [:ok])
  end

  test "compile_from_filesystem rejects missing source" do
    {_manifest, fs} = start_fs!(memory_fs())

    assert {:error, [error]} =
             Hyperlang.DoorTestSupport.build_from_filesystem(
               fs,
               %{entry: "/mem/missing.erl", sources: ["/mem/missing.erl"]},
               %{filesystem: %{enabled: true, source_compile: true, file_compat: true}}
             )

    assert error.category in [:filesystem, :source]
  end

  test "guest loader compile file registers module for ensure_loaded" do
    source = ~S"""
    {ok, main} = compile:file("/mem/main.erl"),
    code:ensure_loaded(main).
    """

    fs =
      memory_fs(
        files: [
          %{path: "/mem/main.erl", content: "-module(main).\nresult(_) -> ok."}
        ]
      )
      |> Map.put(:loader_compat, true)
      |> Map.put(:source_compile, true)

    assert eval_result!(source, fs) == {:module, "main"}
  end

  test "ensure_loaded answers the sticky surface for a loader-compat guest without modules" do
    fs =
      memory_fs()
      |> Map.put(:loader_compat, true)
      |> Map.put(:source_compile, true)

    # `code:ensure_loaded/1` has ONE owner. A loader-compat guest with module
    # loading disabled now walks the same tiers every other guest walks, so it
    # sees the sticky surface; the loader's registry-only lookup used to answer
    # `{error, nofile}` for a module the guest could already call.
    assert eval_result!("code:ensure_loaded(lists).", fs) == {:module, "lists"}
  end

  test "guest loader compile file returns nofile for missing source" do
    source = ~S|compile:file("/mem/missing.erl").|

    fs =
      memory_fs()
      |> Map.put(:loader_compat, true)
      |> Map.put(:source_compile, true)

    assert eval_result!(source, fs) == {:error, :enoent}
  end

  test "filesystem server_info hides guest pid authority" do
    {_manifest, fs} = start_fs!(memory_fs())
    assert {:ok, info} = Hyperlang.Filesystem.server_info(fs)
    assert info.pid_visible_to_guest == false
    assert info.open_handle_count == 0
  end
end
