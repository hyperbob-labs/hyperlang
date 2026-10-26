defmodule HyperlangUtf8BinaryLiteralTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Bare string-literal binary segments encode as UTF-8 — a deliberate divergence
  from Erlang's per-character low-byte truncation, which silently corrupted
  every non-ASCII codepoint an author wrote as `<<"…">>`. Explicit segment
  modifiers keep exact Erlang semantics; ASCII literals are byte-identical
  under both readings.
  """

  @manifest %{terms: %{public: :erlang}}

  defp run!(source, input \\ :ok) do
    {:ok, program} = Hyperlang.Test.program(source, @manifest)

    {:ok, result, _} = Hyperlang.Test.run(program, :entry, [input])
    result
  end

  test "bare non-ASCII string segment constructs valid UTF-8" do
    assert run!(~S|result(_) -> <<"Acknowledged — I'll review §9.">>.|) ==
             "Acknowledged — I'll review §9."
  end

  test "bare segment matches explicit /utf8 byte for byte" do
    assert run!(~S|result(_) -> <<"§—'"/utf8>> =:= <<"§—'">>.|) == true
  end

  test "ASCII bare segments are unchanged" do
    assert run!(~S|result(_) -> <<"abc", 100, "ef">>.|) == <<"abcdef">>
  end

  test "explicit integer segments keep Erlang byte semantics" do
    assert run!(~S|result(_) -> <<167, 20>>.|) == <<167, 20>>
  end

  test "bare string literal round-trips through pattern match" do
    # Canonical hyperlang keeps unapproved source atoms pooled at the public
    # boundary; this case is about the binary pattern, not atom projection.
    assert run!(~S|result(_) -> case <<"§9">> of <<"§9">> -> matched end.|) == "matched"
  end

  test "bare string prefix pattern with rest matches UTF-8 construction" do
    source = ~S"""
    result(_) ->
      case <<"§ heading text">> of
        <<"§ ", Rest/binary>> -> Rest
      end.
    """

    assert run!(source) == "heading text"
  end

  test "constructed text is valid UTF-8 for downstream JSON encoding" do
    result = run!(~S|result(_) -> <<"week 3 — flagged, see §2">>.|)
    assert String.valid?(result)
    assert result == "week 3 — flagged, see §2"
  end

  test "sign/endianness-only modifiers do not opt a string segment out of UTF-8" do
    assert run!(~S|result(_) -> <<"— §"/little>>.|) == "— §"
    assert run!(~S|result(_) -> <<"§"/signed>>.|) == "§"
    assert run!(~S|result(_) -> <<"§"/big-unsigned>>.|) == "§"
  end

  test "explicit type modifier keeps Erlang per-character byte semantics" do
    assert run!(~S|result(_) -> <<"§"/integer>>.|) == <<167>>
  end

  test "explicit size keeps Erlang per-character semantics" do
    assert run!(~S|result(_) -> <<"AB":16>>.|) == <<0, 65, 0, 66>>
  end
end
