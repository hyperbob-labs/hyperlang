defmodule HyperlangVfsModulesCompatTest do
  use ExUnit.Case, async: true

  alias Hyperlang.Manifest

  test "modules section defaults to disabled with /sys/lib path" do
    assert {:ok, normalized} = Manifest.normalize(%{})

    assert normalized.modules == %{
             enabled: false,
             callback_dispatch: false,
             path: ["/sys/lib"],
             guest_modules: [],
             max_modules: 32,
             max_depth: 8,
             max_doc_chunk_bytes: 262_144
           }
  end

  test "modules section normalizes explicit values" do
    assert {:ok, normalized} =
             Manifest.normalize(%{
               modules: %{enabled: true, path: ["/sys/lib", "/usr/glenda/lib"], max_depth: 2}
             })

    assert normalized.modules.enabled == true
    assert normalized.modules.path == ["/sys/lib", "/usr/glenda/lib"]
    assert normalized.modules.max_depth == 2
    assert normalized.modules.max_modules == 32
  end

  test "modules path entries must be absolute and clean" do
    # Canonical HyperBEAM keeps an explicit empty path for compile-time-only
    # `guest_modules`; the compatibility default remains ["/sys/lib"].
    assert {:ok, normalized} = Manifest.normalize(%{modules: %{path: []}})
    assert normalized.modules.path == []

    for bad <- [["relative"], ["/a/../b"], ["/a/./b"], ["/a//b"], ["/a/b/"], [123]] do
      assert {:error, error} = Manifest.normalize(%{modules: %{path: bad}})
      assert error.category == :manifest
    end
  end

  test "modules rejects unknown keys and bad limits" do
    assert {:error, _} = Manifest.normalize(%{modules: %{bogus: 1}})
    assert {:error, _} = Manifest.normalize(%{modules: %{max_modules: 0}})
    assert {:error, _} = Manifest.normalize(%{modules: %{max_depth: -1}})
  end

  test "entry is an alias for the result root" do
    assert {:ok, normalized} = Manifest.normalize(%{entry: %{function: "main"}})
    assert normalized.result.name == "main"
    assert normalized.result.arity == 1

    assert {:error, error} =
             Manifest.normalize(%{entry: %{function: "main"}, result: %{name: "other"}})

    assert error.category == :manifest
    assert {:error, _} = Manifest.normalize(%{entry: %{}})
    assert {:error, _} = Manifest.normalize(%{entry: "main"})
  end

  test "absent entry keeps expression-program default result root" do
    assert {:ok, normalized} = Manifest.normalize(%{})
    assert normalized.result.name == "result"
    assert normalized.result_explicit? == false
  end
end

defmodule HyperlangVfsModulesRuntimeTest do
  use ExUnit.Case, async: true

  @fs_manifest %{
    terms: %{public: :erlang},
    limits: %{wall_ms: 5_000},
    modules: %{enabled: true},
    filesystem: %{
      enabled: true,
      file_compat: true,
      mounts: [
        %{
          virtual: "/",
          backend: "memory",
          mode: :memory,
          allow: [:read, :write, :list, :mkdir, :delete, :rename, :stat, :lstat]
        }
      ]
    }
  }

  defp eval!(source, manifest \\ @fs_manifest, input \\ :ok) do
    {:ok, program} = Hyperlang.Test.program(source, manifest)

    Hyperlang.Test.run(program, :entry, [input])
  end

  defp write_lib(path, body) do
    ~s|ok = file:make_dir("/sys"), ok = file:make_dir("/sys/lib"), | <>
      ~s|ok = file:write_file("#{path}", <<"#{body}">>), |
  end

  test "unknown remote call is a compile error with modules disabled" do
    assert {:error, [error]} =
             Hyperlang.Test.program(~S"double:f(21).", %{terms: %{public: :erlang}})

    assert error.category == :verify
    assert error.message =~ "not declared"
  end

  test "missing library file raises undef" do
    assert {:error, error} = eval!(~S|nosuch:f(1).|)
    assert error.details["reason"] == "undef"
  end

  test "wrong -module name raises undef" do
    source =
      write_lib("/sys/lib/alpha", "-module(beta).\\n-export([f/1]).\\nf(X) -> X.\\n") <>
        "alpha:f(1)."

    assert {:error, error} = eval!(source)
    assert error.details["reason"] == "undef"
  end

  test "sys-using library fails verification because the sys facade is removed" do
    source =
      write_lib(
        "/sys/lib/sneaky",
        "-module(sneaky).\\n-export([f/1]).\\nf(_X) -> sys:pid().\\n"
      ) <> "sneaky:f(1)."

    assert {:error, error} = eval!(source)
    assert error.category == :module
    assert error.details["reason"] == "verification_failed"
  end

  test "sticky stdlib names are never shadowed by the code path" do
    assert {:error, [error]} =
             Hyperlang.Test.program(~S"lists:nosuchfun(1).", @fs_manifest)

    assert error.category == :verify
  end
end
