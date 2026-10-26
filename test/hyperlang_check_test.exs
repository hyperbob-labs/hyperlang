defmodule HyperlangCheckTest do
  use ExUnit.Case, async: true

  defp check_manifest do
    %{
      terms: %{public: :erlang},
      entry: %{function: "main"},
      modules: %{enabled: true},
      filesystem: %{enabled: true}
    }
  end

  test "docs coverage still covers enabled sticky stdlib modules" do
    assert {:ok, []} = Hyperlang.Check.run(%{}, check_manifest())
  end
end
