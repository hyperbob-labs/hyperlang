defmodule HyperlangReadmeExamplesTest do
  # Every `<!-- hyperlang:example run -->` Elixir block in README.md runs here
  # exactly as written. Each block is self-contained and asserts its own
  # results with pattern matches, so a stale example fails the suite.
  # (`hyperlang:example compile` Erlang blocks are run by HyperlangTest
  # against a fixed filesystem manifest. JavaScript blocks are Cloudflare
  # reference code and are not executed.)
  use ExUnit.Case, async: false

  @readme Path.expand("../README.md", __DIR__)
  @external_resource @readme

  @examples @readme
            |> File.read!()
            |> then(
              &Regex.scan(~r/<!--\s*hyperlang:example\s+run\s*-->\s*```elixir\n(.*?)\n```/s, &1,
                capture: :all_but_first
              )
            )
            |> Enum.map(fn [code] -> code end)

  test "the README has runnable examples and no unmarked Elixir blocks" do
    assert length(@examples) >= 9

    readme = File.read!(@readme)
    elixir_blocks = Regex.scan(~r/```elixir\n/, readme) |> length()
    assert elixir_blocks == length(@examples)
  end

  @mirrors @readme
           |> File.read!()
           |> then(
             &Regex.scan(~r/<!--\s*hyperlang:example\s+mirror\s*-->\s*```erlang\n(.*?)\n```/s, &1,
               capture: :all_but_first
             )
           )
           |> Enum.map(fn [code] -> code end)

  # The side-by-side table shows guest Erlang lifted out of the runnable
  # examples. Each snippet must appear verbatim (modulo whitespace and the
  # `\n` escapes of one-line source strings) in some run example.
  test "every side-by-side Erlang snippet is copied from a runnable example" do
    assert length(@mirrors) >= 6
    squash = &(&1 |> String.replace("\\n", "\n") |> String.replace(~r/\s+/, ""))
    corpus = @examples |> Enum.map(squash) |> Enum.join()

    for snippet <- @mirrors do
      assert String.contains?(corpus, squash.(snippet)),
             "README mirror snippet not found in any run example:\n#{snippet}"
    end
  end

  for {code, index} <- Enum.with_index(@examples, 1) do
    first_line = code |> String.split("\n") |> hd()

    @tag readme_example: index
    test "README example #{index}: #{first_line}" do
      {_result, _binding} = Code.eval_string(unquote(code), [], file: @readme)
    end
  end
end
