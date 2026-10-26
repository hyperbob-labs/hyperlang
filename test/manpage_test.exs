defmodule HyperlangManpageTest do
  use ExUnit.Case, async: true

  test "renders only allowlisted functions from the OTP docs chunk" do
    assert {:ok, page} = Hyperlang.Manpage.render(:lists)
    page = IO.iodata_to_binary(page)

    assert page =~ ".TH LISTS 2"
    assert page =~ "keysort"
    refute page =~ ~r/^\.[^A-Za-z]/m

    assert {:ok, binary_page} = Hyperlang.Manpage.render(:binary)
    binary_page = IO.iodata_to_binary(binary_page)
    assert binary_page =~ "split"
    refute binary_page =~ ~r/^\.B "?compile_pattern\(/m
  end

  test "binary module names resolve and unknown modules fail closed" do
    assert {:ok, _page} = Hyperlang.Manpage.render("lists")
    assert {:error, _reason} = Hyperlang.Manpage.render("hyperlang_no_such_module_name")
  end
end
