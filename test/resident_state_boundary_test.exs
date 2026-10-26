defmodule HyperlangResidentStateBoundaryTest do
  use ExUnit.Case, async: true

  @manifest %{
    terms: %{public: :erlang},
    exports: %{
      functions: %{
        "roundtrip" => %{function: "roundtrip", arity: 1},
        "poison" => %{function: "poison", arity: 1}
      }
    }
  }

  @source """
  result(_) -> ok.
  roundtrip(State) -> {ok, State}.
  poison(_State) -> {bad, fun() -> ok end}.
  """

  # Neither `trusted_state` nor `resident_state` is a door option: both
  # state directives were removed. A stale key must stay inert: it is neither
  # an error nor a validation bypass, so a forbidden term still fails the
  # output walk.
  test "stale state-directive options are inert and do not skip validation" do
    {:ok, program} = Hyperlang.Test.program(@source, @manifest)

    opts = [
      run_in_caller?: true,
      trusted_state: %{return_state: 1},
      resident_state: %{return_state: 1, reply: 0}
    ]

    assert {:ok, {:ok, [1, 2, 3]}, _} =
             Hyperlang.Test.run(program, "roundtrip", [[1, 2, 3]], policy: opts)

    assert {:error, error} =
             Hyperlang.Test.run(program, "poison", [[1, 2, 3]], policy: opts)

    assert error.category == :output
    assert inspect(error) =~ "forbidden_term"
  end
end
