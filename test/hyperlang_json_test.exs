defmodule HyperlangJsonTest do
  use ExUnit.Case, async: true

  defp erlang_public(manifest \\ %{}) do
    Map.update(manifest, :terms, %{public: :erlang}, &Map.put(&1, :public, :erlang))
  end

  test "hyperbob_os webfs json helpers are not Hyperlang stdlib" do
    assert {:error, [error]} =
             Hyperlang.Test.program(
               ~S|webfs:json_encode(#{<<"name">> => <<"Ada">>}).|,
               %{}
             )

    assert error.category == :verify
    assert error.message =~ "webfs:json_encode/1 is not declared"
  end

  test "raw OTP json encoders remain rejected" do
    assert {:error, [error]} =
             Hyperlang.Test.program(
               ~S|json:encode(#{<<"name">> => <<"Ada">>}).|,
               erlang_public()
             )

    assert error.category == :verify
    assert error.message =~ "json:encode/1 is not declared"
  end
end
