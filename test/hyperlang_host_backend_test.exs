defmodule HyperlangHostBackendTest do
  # The two-skin contract on the host backend: with
  # `filesystem.backend: :host`, the Erlang `file:`/`filelib:`/`io:` mirror
  # and the Plan 9 `sys:` facade lower onto the same host syscall callback and
  # share one fd token, so descriptors opened through either skin are usable
  # through the other.
  use ExUnit.Case, async: false

  defp erlang_public(manifest) do
    Map.update(manifest, :terms, %{public: :erlang}, &Map.put(&1, :public, :erlang))
  end

  defp host_manifest(limits \\ %{}) do
    erlang_public(%{
      filesystem:
        %{
          enabled: true,
          backend: :host,
          file_compat: true,
          filelib_compat: true,
          handle_compat: true
        }
        |> then(fn filesystem ->
          if limits == %{}, do: filesystem, else: Map.put(filesystem, :limits, limits)
        end),
      sys: %{enabled: true}
    })
  end

  # A static Plan 9 namespace: `sys:stat` by name, `sys:open`/`sys:dirread`/
  # `sys:close` for directory enumeration. The kernel has no lstat syscall and
  # no symlinks, which is why the shared wildcard bridge is handed the same
  # callback for `:stat` and `:lstat` on this backend.
  defmodule HostTree do
    @behaviour Hyperlang.SyscallHost

    import Bitwise

    @dmdir 0x80000000

    @tree %{
      "/a" => :dir,
      "/a/b" => :dir,
      "/a/b/c.txt" => {:file, "c"},
      "/a/x.txt" => {:file, "x"}
    }

    @impl true
    def syscall(_bound, :open, [path, _mode]) do
      path = normalize(path)

      if Map.has_key?(@tree, path) do
        fds = fds()
        fd = 3 + map_size(fds)
        :ok = Hyperlang.SyscallHost.put_state(Map.put(fds, fd, %{path: path, listed: false}))
        fd
      else
        nil
      end
    end

    def syscall(_bound, :dirread, [fd]) do
      fds = fds()

      case Map.fetch(fds, fd) do
        {:ok, %{path: path, listed: false}} ->
          entries =
            @tree
            |> Enum.filter(fn {child, _entry} ->
              child != path and Path.dirname(child) == path
            end)
            |> Enum.map(fn {child, entry} -> dir_map(child, entry) end)

          :ok = Hyperlang.SyscallHost.put_state(put_in(fds[fd].listed, true))
          {length(entries), entries}

        {:ok, _listed} ->
          {0, []}

        :error ->
          {-1, []}
      end
    end

    def syscall(_bound, :close, [fd]) do
      :ok = Hyperlang.SyscallHost.put_state(Map.delete(fds(), fd))
      0
    end

    def syscall(_bound, :stat, [path]) do
      case Map.fetch(@tree, normalize(path)) do
        {:ok, entry} -> {0, dir_map(normalize(path), entry)}
        :error -> {-1, %{}}
      end
    end

    def syscall(_bound, _operation, _args), do: {:hyperlang_syscall_error, :enotsup}

    defp fds, do: Hyperlang.SyscallHost.get_state() || %{}

    defp normalize(path) when is_binary(path), do: path
    defp normalize(path) when is_list(path), do: List.to_string(path)

    defp dir_map(path, entry) do
      {mode, length} =
        case entry do
          :dir -> {@dmdir ||| 0o777, 0}
          {:file, content} -> {0o644, byte_size(content)}
        end

      %{
        <<"name">> => Path.basename(path),
        <<"mode">> => mode,
        <<"length">> => length,
        <<"qid">> => %{<<"type">> => 0, <<"version">> => 0, <<"path">> => 0},
        <<"uid">> => <<>>,
        <<"gid">> => <<>>,
        <<"muid">> => <<>>,
        <<"atime">> => 0,
        <<"mtime">> => 0,
        <<"type">> => 0,
        <<"dev">> => 0
      }
    end
  end

  defp host_tree_result(source, limits \\ %{}) do
    {:ok, program} = Hyperlang.Test.program(source, host_manifest(limits))

    Hyperlang.Test.run(program, :entry, [:ok], syscall: {HostTree, nil})
  end

  defp compile_eval!(source, manifest, options) do
    {:ok, program} = Hyperlang.Test.program(source, manifest)

    assert {:ok, result, %{stdout: []}} =
             Hyperlang.Test.run(program, :entry, [:ok], policy: options)

    result
  end

  # -- tests ------------------------------------------------------------------

  test "host backend fails closed instead of falling back to attached own VFS" do
    own_manifest =
      erlang_public(%{
        filesystem: %{
          enabled: true,
          file_compat: true,
          mounts: [
            %{
              virtual: "/mem",
              backend: :memory,
              allow: [:read],
              files: [%{path: "/mem/a.txt", content: "own"}]
            }
          ]
        }
      })

    {:ok, normalized} = Hyperlang.Manifest.normalize(own_manifest)
    {:ok, filesystem} = Hyperlang.Filesystem.start(normalized.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(filesystem) end)

    {:ok, program} =
      Hyperlang.Test.program(~S|file:read_file("/mem/a.txt").|, host_manifest())

    assert {:ok, {:error, :eacces}, %{stdout: []}} =
             Hyperlang.Test.run(program, :entry, [:ok],
               policy: %{filesystem: [attach: filesystem]}
             )
  end

  test "own backend is the default and stays on the mediated filesystem" do
    manifest =
      erlang_public(%{
        filesystem: %{
          enabled: true,
          file_compat: true,
          mounts: [
            %{
              virtual: "/mem",
              backend: :memory,
              allow: [:list, :read, :write],
              files: [%{path: "/mem/a.txt", content: "own"}]
            }
          ]
        }
      })

    {:ok, normalized} = Hyperlang.Manifest.normalize(manifest)
    {:ok, filesystem} = Hyperlang.Filesystem.start(normalized.filesystem)
    on_exit(fn -> Hyperlang.Filesystem.stop(filesystem) end)

    result =
      compile_eval!(
        ~S|{ok, Bin} = file:read_file("/mem/a.txt"), Bin.|,
        manifest,
        %{filesystem: filesystem}
      )

    assert result == "own"
    refute_received {:syscall, _operation, _args}
  end

  # The Plan 9 namespace has no symlinks and the syscall surface has no lstat,
  # so the host backend supplies ONE stat callback for both info calls. This
  # pins that decision: both report the same entry, and both see the directory
  # bit. The own VFS backend keeps the real split (see the file_info metadata
  # test in hyperlang_test.exs), which the shared bridge preserves.
  test "host read_file_info and read_link_info report the same entry" do
    assert {:ok, result, _} =
             host_tree_result(~S"""
             {ok, FileInfo} = file:read_file_info("/a/x.txt"),
             {ok, LinkInfo} = file:read_link_info("/a/x.txt"),
             {ok, DirInfo} = file:read_link_info("/a/b"),
             {FileInfo =:= LinkInfo, element(3, FileInfo), element(3, DirInfo)}.
             """)

    assert result == {true, :regular, :directory}
  end

  test "host wildcard enumerates the namespace through the shared bridge" do
    assert {:ok, result, _} = host_tree_result(~S|filelib:wildcard("/a/*/*.txt").|)

    assert result == [~c"/a/b/c.txt"]
  end

  # The wildcard limits come from the CONFIGURED manifest limits, never from a
  # hardcoded default and never silently off.
  test "host wildcard enforces the configured max_wildcard_depth" do
    assert {:error, error} =
             host_tree_result(~S|filelib:wildcard("/a/*/*.txt").|, %{max_wildcard_depth: 1})

    assert inspect(error) =~ "eoverflow"
  end

  test "host wildcard enforces the configured max_wildcard_matches" do
    assert {:error, error} =
             host_tree_result(~S|filelib:wildcard("/a/*/*.txt").|, %{max_wildcard_matches: 1})

    assert inspect(error) =~ "eoverflow"
  end
end
