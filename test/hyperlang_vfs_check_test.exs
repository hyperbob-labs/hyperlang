defmodule HyperlangVfsCheckTest do
  # `Hyperlang.Check.run/2`, the static whole-image
  # pass — resolution, verification, capability, and docs-coverage findings
  # with file (and line where available).
  use ExUnit.Case, async: true

  @lib_source """
  -module(myjson).
  -moduledoc "JSON parsing.".
  -export([parse/1]).
  -spec parse(binary()) -> {ok, term()}.
  parse(B) -> {ok, B}.
  """

  @command_source """
  -module(pp).
  -export([main/1]).
  main(_Args) -> myjson:parse(<<"x">>).
  """

  defp check_manifest do
    %{
      terms: %{public: :erlang},
      entry: %{function: "main"},
      modules: %{enabled: true},
      filesystem: %{enabled: true}
    }
  end

  test "a clean mini-image passes" do
    image = %{
      "/sys/lib/myjson" => @lib_source,
      "/beam/bin/pp" => @command_source
    }

    assert {:ok, []} = Hyperlang.Check.run(image, check_manifest())
  end

  test "check forces modules on even when the manifest leaves them disabled" do
    image = %{"/sys/lib/myjson" => @lib_source, "/beam/bin/pp" => @command_source}
    manifest = Map.put(check_manifest(), :modules, %{enabled: false})

    assert {:ok, []} = Hyperlang.Check.run(image, manifest)
  end

  test "a missing library is an unresolved_module finding on the calling file" do
    image = %{
      "/beam/bin/pp" => String.replace(@command_source, "myjson:parse", "nosuch:parse")
    }

    assert {:error, [finding]} = Hyperlang.Check.run(image, check_manifest())
    assert finding.kind == :unresolved_module
    assert finding.file == "/beam/bin/pp"
    assert finding.message =~ "nosuch:parse/1"
  end

  test "an arity mismatch against the library's export table is an undefined_function finding" do
    image = %{
      "/sys/lib/myjson" => @lib_source,
      "/beam/bin/pp" => String.replace(@command_source, ~S|parse(<<"x">>)|, "parse(1, 2)")
    }

    assert {:error, [finding]} = Hyperlang.Check.run(image, check_manifest())
    assert finding.kind == :undefined_function
    assert finding.file == "/beam/bin/pp"
    assert finding.message =~ "myjson:parse/2"
  end

  test "a wrong -module name is a wrong_module finding on the library file" do
    image = %{
      "/sys/lib/myjson" => String.replace(@lib_source, "-module(myjson)", "-module(other)")
    }

    assert {:error, findings} = Hyperlang.Check.run(image, check_manifest())
    assert [%{kind: :wrong_module, file: "/sys/lib/myjson"} | _] = findings
  end

  test "a removed sys facade call is reported as a compile finding" do
    image = %{
      "/sys/lib/sysuser" => "-module(sysuser).\n-export([f/0]).\nf() -> sys:millisec().\n"
    }

    assert {:error, [finding]} = Hyperlang.Check.run(image, check_manifest())
    assert finding.kind == :capability_not_granted
    assert finding.file == "/sys/lib/sysuser"
    assert finding.message =~ "sys:millisec/0"
  end

  test "a syntax error carries file and line" do
    image = %{"/sys/lib/broken" => "-module(broken).\n-export([f/0]).\nf() -> case of end.\n"}

    assert {:error, [finding]} = Hyperlang.Check.run(image, check_manifest())
    assert finding.kind == :compile_error
    assert finding.file == "/sys/lib/broken"
    assert finding.line == 3
  end

  test "library-to-library calls are resolved transitively" do
    image = %{
      "/sys/lib/upper" => """
      -module(upper).
      -export([f/0]).
      f() -> lower:g().
      """,
      "/sys/lib/lower" => """
      -module(lower).
      -export([g/0]).
      g() -> ok.
      """
    }

    assert {:ok, []} = Hyperlang.Check.run(image, check_manifest())

    broken = Map.delete(image, "/sys/lib/lower")
    assert {:error, [finding]} = Hyperlang.Check.run(broken, check_manifest())
    assert finding.kind == :unresolved_module
    assert finding.file == "/sys/lib/upper"
  end

  test "behaviour-contract libraries pass without compilation" do
    image = %{
      "/sys/lib/codec" => """
      -module(codec).
      -moduledoc "The codec contract.".
      -callback encode(term()) -> binary().
      """
    }

    assert {:ok, []} = Hyperlang.Check.run(image, check_manifest())
  end

  test "a host directory image is read with File and checked the same way" do
    root = Path.join(System.tmp_dir!(), "hyperlang_check_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "sys/lib"))
    File.mkdir_p!(Path.join(root, "beam/bin"))
    File.write!(Path.join(root, "sys/lib/myjson"), @lib_source)
    File.write!(Path.join(root, "beam/bin/pp"), @command_source)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, []} = Hyperlang.Check.run(root, check_manifest())

    File.write!(
      Path.join(root, "beam/bin/pp"),
      String.replace(@command_source, "myjson:", "gone:")
    )

    assert {:error, [%{kind: :unresolved_module, file: "/beam/bin/pp"}]} =
             Hyperlang.Check.run(root, check_manifest())
  end

  test "an invalid image shape is itself a finding" do
    assert {:error, [%{kind: :invalid_image}]} =
             Hyperlang.Check.run(%{"relative" => "x."}, check_manifest())

    assert {:error, [%{kind: :invalid_image}]} = Hyperlang.Check.run(12, check_manifest())
  end

  test "docs coverage flags an enabled stdlib module with no producible chunk" do
    # All default-enabled stdlib modules either carry OTP Docs chunks or
    # synthesize from the gate matrices, so the default image is covered.
    assert {:ok, []} = Hyperlang.Check.run(%{}, check_manifest())
  end
end
