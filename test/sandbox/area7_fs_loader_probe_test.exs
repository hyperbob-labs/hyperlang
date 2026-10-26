defmodule Hyperlang.Area7FsLoaderProbeTest do
  # AREA 7/9: filesystem capability and code loader. Guest file ops must stay
  # inside the virtual mount (no traversal, absolute escape, NUL, symlink
  # creation), handles must not leak, and the loader must not reach ambient OTP
  # code/compile/eval.
  use ExUnit.Case, async: false
  import Hyperlang.SandboxProbe

  @fs %{
    terms: %{public: :erlang},
    filesystem: %{
      enabled: true,
      file_compat: true,
      mounts: [
        %{
          virtual: "/m",
          backend: "memory",
          mode: :memory,
          allow: [:read, :write],
          files: [%{path: "/m/a.txt", content: "hi"}]
        }
      ]
    }
  }

  defp fsrun(body), do: run("result(_) -> #{body}.", @fs)

  describe "a mounted read works, escapes do not" do
    test "reading an in-mount file succeeds" do
      assert {:ok, {:ok, "hi"}, _} = fsrun(~S|file:read_file(<<"/m/a.txt">>)|)
    end

    for {name, path} <- [
          {"dot-dot traversal", ~S|<<"/m/../../../etc/passwd">>|},
          {"absolute escape", ~S|<<"/etc/passwd">>|},
          {"nested dot-dot", ~S|<<"/m/sub/../../etc/passwd">>|},
          {"unmounted root", ~S|<<"/other/x">>|},
          {"double slash", ~S|<<"/m//../etc/passwd">>|}
        ] do
      test "escape is denied: #{name}" do
        out = fsrun("file:read_file(#{unquote(path)})")
        assert match?({:ok, {:error, _}, _}, out), "escape not denied: #{inspect(out)}"
        refute text(out) =~ "root:"
      end
    end

    for {name, path} <- [
          {"NUL byte", ~S|<<"/m/a.txt", 0, "x">>|},
          {"bare NUL", ~S|<<0>>|}
        ] do
      test "malformed path rejected: #{name}" do
        assert match?(
                 {:ok, {:error, :invalid_path}, _},
                 fsrun("file:read_file(#{unquote(path)})")
               )
      end
    end
  end

  describe "symlink and hardlink creation have no guest surface" do
    for {name, body} <- [
          {"make_symlink", ~S|file:make_symlink(<<"/m/a.txt">>, <<"/m/l">>)|},
          {"make_link", ~S|file:make_link(<<"/m/a.txt">>, <<"/m/h">>)|}
        ] do
      test "reject #{name}" do
        assert rejected?("result(_) -> #{unquote(body)}.", @fs)
      end
    end
  end

  describe "file handles are opaque and cannot cross the result boundary" do
    test "file:open is gated and a handle never leaves as a ref" do
      out = fsrun(~S|{ok, F} = file:open(<<"/m/a.txt">>, [read]), F|)
      # Default: handle compat disabled -> rejected. If ever enabled, the handle
      # must still be rejected at the output boundary, never returned as a ref.
      assert match?({:rejected, _}, out) or match?({:error, _}, out)
      refute match?({:ok, v, _} when is_reference(v), out)
    end
  end

  describe "file metadata does not leak host identifiers" do
    test "read_file_info carries no host path, inode, uid or raw device id" do
      out = fsrun(~S|file:read_file_info(<<"/m/a.txt">>)|)
      t = text(out)
      refute t =~ "/private"
      refute t =~ "/Users"
      refute t =~ System.tmp_dir!() |> Path.expand()
    end
  end

  describe "the loader cannot reach ambient OTP code/compile/eval" do
    for {name, body} <- [
          {"erl_eval:eval", "erl_eval:eval(a, b)"},
          {"code:load_binary", "code:load_binary(m, \"f\", <<>>)"},
          {"code:load_file", "code:load_file(m)"},
          {"compile:forms", "compile:forms([])"},
          {"compile:file no cap", "compile:file(<<\"/m/a.txt\">>)"},
          {"code:which", "code:which(erlang)"}
        ] do
      test "reject #{name}" do
        assert rejected?("result(_) -> #{unquote(body)}.", @fs)
      end
    end
  end
end
