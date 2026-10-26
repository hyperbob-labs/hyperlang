defmodule StdlibBoundaryPolicyTest do
  # Security regression for the Hyperlang host<->guest boundary and stdlib policy:
  #
  #   1. `validate_runtime` memoization — the host-built token/limits/terms are
  #      validated ONCE (stamped at instantiate) instead of re-scanned on every
  #      crossing. These tests prove a forbidden primitive (pid/port/ref) in
  #      token/limits/terms is STILL rejected, and a FORGED stamp on a runtime
  #      whose token/limits/terms differ from the stamped triple is NOT honored.
  #
  #   2. Expanding stdlib calls are mediated boundaries. Intrinsic calls operate on
  #      guest-resident terms, higher-order calls validate callback slots, wrapped
  #      calls enforce function-specific bounds, and mediated returns enforce the
  #      full term policy before guest code can retain them.
  use ExUnit.Case, async: false

  alias Hyperlang.Terms

  defp erlang_public(manifest \\ %{}) do
    Map.update(manifest, :terms, %{public: :erlang}, &Map.put(&1, :public, :erlang))
  end

  defp compile_and_instance(source, manifest) do
    {:ok, program} = Hyperlang.Test.program(source, manifest)
    program
  end

  defp eval(program) do
    case Hyperlang.Test.run(program, :entry, [nil]) do
      {:ok, result, %{stdout: []}} -> {:ok, result}
      other -> other
    end
  end

  defp error_category(error), do: Map.get(error, :category)

  defp error_reason(%{details: %{"error" => %{"reason" => reason}}}), do: reason
  defp error_reason(error), do: get_in(error, [:details, "reason"])

  # ===========================================================================
  # (1) Atom-bomb defense — atom-creating BIFs are verifier-blocked before they
  #     can reach stdlib runtime dispatch.
  # ===========================================================================

  test "a guest closure survives a mediated stdlib return" do
    program =
      compile_and_instance(
        ~S"""
        result(_) ->
          M = maps:merge(#{inc => fun(X) -> X + 1 end}, #{base => 41}),
          F = maps:get(inc, M),
          F(maps:get(base, M)).
        """,
        erlang_public()
      )

    assert {:ok, 42} = eval(program)
  end

  test "setelement runs direct yet its result still meets the output boundary" do
    program =
      compile_and_instance(
        ~S"""
        result(_) ->
          T = setelement(2, {a, b, c}, 42),
          {element(2, T), setelement(1, T, fun(X) -> X end)}.
        """,
        erlang_public()
      )

    assert {:error, %{details: details}} = eval(program)
    assert inspect(details) =~ "forbidden_term"

    ok =
      compile_and_instance(
        ~S"result(_) -> element(2, setelement(2, {a, b, c}, 42)).",
        erlang_public()
      )

    assert {:ok, 42} = eval(ok)
  end

  test "atom-creating BIFs are still rejected before stdlib dispatch" do
    for {source, needle} <- [
          {~S|result(_) -> list_to_atom("x" ++ "y").|, "list_to_atom"},
          {~S|result(_) -> binary_to_atom(<<"forged">>, utf8).|, "binary_to_atom"},
          {~S|result(_) -> binary_to_existing_atom(<<"forged">>, utf8).|,
           "binary_to_existing_atom"},
          {~S|result(_) -> binary_to_term(<<131,100,0,3,97,98,99>>).|, "binary_to_term"},
          {~S|result(_) -> list_to_existing_atom("forged").|, "list_to_existing_atom"}
        ] do
      assert {:error, [%{category: :verify, message: message}]} =
               Hyperlang.Test.program(source, erlang_public()),
             "expected #{needle} to be verifier-rejected"

      assert message =~ needle
    end
  end

  test "an atom-bomb LOOP via list_to_atom cannot be compiled" do
    # The classic atom-exhaustion attack: synthesize VM-global atoms in a loop.
    # list_to_atom is verifier-blocked, so the loop never even compiles.
    source = ~S"""
    bomb(0) -> [];
    bomb(N) -> [list_to_atom(integer_to_list(N)) | bomb(N - 1)].
    result(_) -> bomb(100000).
    """

    assert {:error, [%{category: :verify, message: message}]} =
             Hyperlang.Test.program(source, erlang_public())

    assert message =~ "list_to_atom"
  end

  # ===========================================================================
  # (2) Memory-bomb defense — amplifying stdlib calls are still caught by their
  #     function wrapper, heap guard, or the real output boundary.
  # ===========================================================================

  test "lists:duplicate amplification is still caught" do
    # duplicate(1000, 1) fits the heap but exceeds a small max_list_length.
    instance =
      compile_and_instance(
        ~S|result(_) -> lists:duplicate(1000, 1).|,
        erlang_public(%{limits: %{max_list_length: 256}})
      )

    assert {:error, error} = eval(instance)
    assert error_category(error) in [:heap, :stdlib]
    assert error_reason(error) == "list_length"
  end

  test "lists:seq amplification is still caught" do
    instance =
      compile_and_instance(
        ~S|result(_) -> lists:seq(1, 100000).|,
        erlang_public(%{limits: %{max_list_length: 256}})
      )

    assert {:error, error} = eval(instance)
    assert error_category(error) in [:heap, :stdlib]
    assert error_reason(error) == "list_length"
  end

  test "binary:copy amplification is still caught by the binary wrapper" do
    instance =
      compile_and_instance(
        ~S|result(_) -> binary:copy(<<"AB">>, 100000).|,
        erlang_public(%{limits: %{max_binary_bytes: 1024}})
      )

    assert {:error, error} = eval(instance)
    assert error_category(error) == :stdlib
    assert error_reason(error) == "binary_bytes"
  end

  test "a huge/deep term build still hits a limit (no amplification escapes)" do
    # Build a wide list through stdlib; its mediated return enforces max_total_words.
    instance =
      compile_and_instance(
        ~S|result(_) -> lists:duplicate(50000, [1,2,3]).|,
        erlang_public(%{limits: %{max_list_length: 1024, max_total_words: 4096}})
      )

    assert {:error, error} = eval(instance)
    assert error_category(error) in [:heap, :stdlib]
  end

  # ===========================================================================
  # (3) Forged primitives — pid/ref/port construction is verifier-blocked, so a
  #     guest can never place one into a guest-resident term.
  # ===========================================================================

  test "pid construction remains rejected while make_ref is a gated native lowering" do
    assert {:error, [%{category: :verify, message: message}]} =
             Hyperlang.Test.program(~S|result(_) -> self().|, erlang_public())

    assert message =~ "self"

    assert {:ok, _program} =
             Hyperlang.Test.program(~S|result(_) -> make_ref().|, erlang_public())

    Application.delete_env(:hyperlang, :guest_spawn_hook)
    instance = compile_and_instance(~S|result(_) -> spawn(fun() -> ok end).|, erlang_public())

    assert {:error, error} = eval(instance)
    assert inspect(error_reason(error)) =~ "no_spawn_policy"
  end

  # ===========================================================================
  # (4) validate_runtime memoization soundness — the stamp is honored ONLY for
  #     the exact validated token/limits/terms triple; a forbidden primitive is
  #     still rejected, and a forged/stale stamp falls through to the full scan.
  # ===========================================================================

  defp valid_runtime do
    %{
      token: 12345,
      limits: %{max_term_depth: 8},
      terms: %{allowed_atoms: MapSet.new([:ok])}
    }
  end

  test "validate_runtime still rejects a forbidden primitive in token/limits/terms" do
    base = valid_runtime()

    assert_raise ArgumentError, fn -> Terms.validate_runtime(%{base | token: self()}) end
    assert_raise ArgumentError, fn -> Terms.validate_runtime(%{base | limits: %{a: self()}}) end

    assert_raise ArgumentError, fn ->
      Terms.validate_runtime(%{base | terms: %{a: make_ref()}})
    end
  end

  test "stamp_validated_runtime raises (and never stamps) a forbidden runtime" do
    bad = %{valid_runtime() | terms: %{poison: self()}}
    assert_raise ArgumentError, fn -> Terms.stamp_validated_runtime(bad) end
  end

  test "a valid runtime is stamped and the stamp short-circuits the re-scan" do
    stamped = Terms.stamp_validated_runtime(valid_runtime())
    # The stamp is present and validate_runtime honors it (no raise).
    assert is_map(stamped)
    assert :ok == Terms.validate_runtime(stamped)
  end

  test "a FORGED stamp is NOT honored when token/limits/terms differ from it" do
    stamped = Terms.stamp_validated_runtime(valid_runtime())

    # Lift the (legitimate) stamp value off a validated runtime and graft it onto
    # a DIFFERENT runtime carrying a forbidden primitive. The stamp's identity
    # guard compares the stamped triple against the live token/limits/terms; since
    # they differ, the stamp is ignored and the full scan runs and rejects.
    [stamp_key] =
      Enum.filter(Map.keys(stamped), fn k ->
        is_atom(k) and Atom.to_string(k) =~ "validated"
      end)

    stamp_value = Map.fetch!(stamped, stamp_key)

    forged =
      valid_runtime()
      |> Map.put(:terms, %{poison: self()})
      |> Map.put(stamp_key, stamp_value)

    assert_raise ArgumentError, fn -> Terms.validate_runtime(forged) end
  end

  # ===========================================================================
  # (5) Stdlib behaviour preservation — intrinsic calls return correct results,
  #     and a wrapped call that can exceed a size limit is still bounded.
  # ===========================================================================

  test "intrinsic maps/lists/binary projections return correct results" do
    src =
      ~s|result(_) -> {maps:get(a, \#{a => 1}), lists:reverse([1,2,3]), element(2, {x, y}), binary_part(<<"hello">>, 1, 3)}.|

    instance = compile_and_instance(src, erlang_public(%{terms: %{allowed_atoms: [:a, :x, :y]}}))

    # `:erlang` public mode keeps allowed atoms as atoms; the element lookup,
    # reversed list, map value, and sub-binary are all correct.
    assert {:ok, {1, [3, 2, 1], :y, "ell"}} = eval(instance)
  end

  test "wrapped binary:split still enforces its list-length bound" do
    # A global split that would produce ~500 fragments, capped at max_list_length
    # 16. binary:split's own bounded-list-length check still runs and rejects.
    instance =
      compile_and_instance(
        ~S|result(_) -> binary:split(binary:copy(<<"a,">>, 500), <<",">>, [global]).|,
        erlang_public(%{terms: %{allowed_atoms: [:global]}, limits: %{max_list_length: 16}})
      )

    assert {:error, error} = eval(instance)
    assert error_category(error) == :stdlib
    assert error_reason(error) == "list_length"
  end
end
