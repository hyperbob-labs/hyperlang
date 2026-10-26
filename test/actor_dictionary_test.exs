defmodule Hyperlang.ActorDictionaryTest do
  use ExUnit.Case, async: false
  alias Hyperlang.Test, as: Kit

  test "actor guest dictionaries persist across callbacks outside the OTP status dictionary" do
    program =
      Kit.program!(
        """
        init(_) -> put(count, 0), {ok, 0}.
        handle_call(_, _, S) -> N = get(count) + 1, put(count, N), {reply, N, S}.
        handle_info(_, S) -> {noreply, S}.
        """,
        %{
          result: %{name: "init", arity: 1},
          terms: %{public: :erlang, allowed_atoms: [:ok, :reply, :noreply]}
        }
      )

    actor = Kit.start_actor!(program, nil)
    assert GenServer.call(actor, 0) == 1
    assert GenServer.call(actor, 0) == 2
    {:status, ^actor, _, [dictionary | _]} = :sys.get_status(actor)
    refute Enum.any?(dictionary, fn {key, _} -> inspect(key) =~ "hyperlang_guest" end)
    assert GenServer.call(actor, 0) == 3
    GenServer.stop(actor)
  end
end
