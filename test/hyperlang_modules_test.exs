defmodule HyperlangModulesTest do
  use ExUnit.Case, async: true

  alias Hyperlang.Manifest

  test "modules section normalizes explicit values" do
    assert {:ok, normalized} =
             Manifest.normalize(%{
               modules: %{enabled: true, path: ["/sys/lib", "/usr/glenda/lib"], max_depth: 2}
             })

    assert normalized.modules.enabled == true
    assert normalized.modules.path == ["/sys/lib", "/usr/glenda/lib"]
    assert normalized.modules.guest_modules == []
    assert normalized.modules.max_depth == 2
    assert normalized.modules.max_modules == 32
  end

  test "modules section normalizes declared guest module names" do
    assert {:ok, normalized} =
             Manifest.normalize(%{
               modules: %{
                 enabled: true,
                 guest_modules: ["string", :random, "string", "8bit_stob", "euc-jp_btos"]
               }
             })

    assert normalized.modules.guest_modules == [
             "8bit_stob",
             "euc-jp_btos",
             "random",
             "string"
           ]
  end

  test "modules path may be empty, otherwise entries must be absolute, clean, non-empty" do
    assert {:ok, normalized} = Manifest.normalize(%{modules: %{path: []}})
    assert normalized.modules.path == []

    for bad <- [["relative"], ["/a/../b"], ["/a//b"], [123]] do
      assert {:error, error} = Manifest.normalize(%{modules: %{path: bad}})
      assert error.category == :manifest
    end
  end

  test "modules rejects unknown keys and bad limits" do
    assert {:error, _} = Manifest.normalize(%{modules: %{bogus: 1}})
    assert {:error, _} = Manifest.normalize(%{modules: %{max_modules: 0}})
    assert {:error, _} = Manifest.normalize(%{modules: %{max_depth: -1}})
    assert {:error, _} = Manifest.normalize(%{modules: %{guest_modules: ["Bad"]}})
    assert {:error, _} = Manifest.normalize(%{modules: %{guest_modules: "string"}})
  end
end
