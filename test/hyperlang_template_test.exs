defmodule HyperlangTemplateTest do
  use ExUnit.Case, async: true

  test "raw template engines and hyperbob_os webfs helpers are not Hyperlang stdlib" do
    assert {:error, [bbmustache_error]} =
             Hyperlang.Test.program(~S|bbmustache:render(<<"x">>, #{}).|, %{})

    assert bbmustache_error.category == :verify
    assert bbmustache_error.message =~ "bbmustache:render/2 is not declared"

    for source <- [
          ~S|webfs:render(<<"x">>, #{}).|,
          ~S|webfs:render_file(<<"/templates/x.mustache">>, #{}).|,
          ~S|webfs:escape_html(<<"<x>">>).|
        ] do
      assert {:error, [error]} = Hyperlang.Test.program(source, %{})
      assert error.category == :verify
      assert error.message =~ "is not declared"
    end
  end
end
