defmodule HyperlangStdlibDirectCodegenTest do
  use ExUnit.Case, async: false

  defp forms!(source, manifest) do
    {:ok, normalized} = Hyperlang.Manifest.normalize(manifest)
    normalized = Hyperlang.DoorTestSupport.seed_atom_universe(normalized)
    {:ok, compiled} = Hyperlang.Compiler.compile(source, normalized)
    {:ok, forms, _metadata} = Hyperlang.Codegen.to_forms(compiled, normalized)
    forms
  end

  defp eval!(source, manifest), do: eval!(source, manifest, nil)

  defp eval!(source, manifest, input) do
    {:ok, program} = Hyperlang.Test.program(source, manifest)

    Hyperlang.Test.run(program, :entry, [input])
  end

  defp error_category(error), do: Map.get(error, :category)
  defp error_reason(error), do: get_in(error, [:details, "reason"])

  defp calls(term), do: walk_calls(term, [])

  defp walk_calls(
         {:call, _anno, {:remote, _ra, {:atom, _ma, module}, {:atom, _fa, function}}, args},
         acc
       ) do
    Enum.reduce(args, [{module, function, length(args)} | acc], &walk_calls/2)
  end

  defp walk_calls(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.reduce(acc, &walk_calls/2)

  defp walk_calls(list, acc) when is_list(list), do: Enum.reduce(list, acc, &walk_calls/2)
  defp walk_calls(_term, acc), do: acc

  test "deterministic direct stdlib calls compile to BEAM calls instead of Runtime.stdlib" do
    forms =
      forms!(
        ~S"""
        maps:get(<<"x">>, #{<<"x">> => 1}) +
          lists:foldl(fun(Value, Acc) -> Value + Acc end, 0, [2, 3]).
        """,
        %{terms: %{public: :erlang}}
      )

    calls = calls(forms)

    # Canonical Hyperlang already lowers maps:get/2 to the equivalent
    # erlang:map_get/2 BIF; either direct form proves the runtime hop is absent.
    assert {:erlang, :map_get, 2} in calls or {:maps, :get, 2} in calls
    assert {:lists, :foldl, 3} in calls
    refute {Hyperlang.Runtime, :stdlib, 4} in calls
  end

  test "wrapped and nondeterministic stdlib calls keep the runtime boundary" do
    wrapped_calls = calls(forms!(~S|re:run(<<"a">>, <<"a">>).|, %{terms: %{public: :erlang}}))

    nondeterministic_calls =
      calls(
        forms!(
          "erlang:system_time().",
          %{capabilities: [:nondeterminism], terms: %{public: :erlang}}
        )
      )

    assert {Hyperlang.Runtime, :stdlib, 4} in wrapped_calls
    refute {:re, :run, 2} in wrapped_calls

    assert {Hyperlang.Runtime, :stdlib, 4} in nondeterministic_calls
    refute {:erlang, :system_time, 0} in nondeterministic_calls
  end

  test "expanding direct stdlib targets keep the runtime sanitizer boundary" do
    forms =
      forms!(
        ~S"""
        lists:duplicate(1000, ok),
        zlib:gunzip(Input),
        ok.
        """,
        %{terms: %{public: :erlang, allowed_atoms: [:ok]}}
      )

    calls = calls(forms)

    assert {Hyperlang.Runtime, :stdlib, 4} in calls
    refute {:lists, :duplicate, 2} in calls
    refute {:zlib, :gunzip, 1} in calls

    assert {:error, duplicate_error} =
             eval!(
               "lists:duplicate(1000, ok), ok.",
               %{limits: %{max_list_length: 10}, terms: %{public: :erlang, allowed_atoms: [:ok]}}
             )

    assert error_category(duplicate_error) == :stdlib
    assert get_in(duplicate_error, [:details, "error", "reason"]) == "list_length"

    compressed = :zlib.gzip(:binary.copy("a", 1000))

    assert byte_size(compressed) <= 64

    assert {:error, inflate_error} =
             eval!(
               "zlib:gunzip(Input), ok.",
               %{
                 limits: %{max_binary_bytes: 64},
                 terms: %{public: :erlang, allowed_atoms: [:ok]}
               },
               compressed
             )

    assert error_category(inflate_error) == :stdlib
    assert get_in(inflate_error, [:details, "error", "reason"]) == "binary_bytes"
  end

  test "unsafe mediated direct-target results are stopped at the stdlib boundary" do
    assert {:error, error} = eval!(~S|maps:iterator(#{}).|, %{terms: %{public: :erlang}})
    assert error_category(error) == :stdlib
    assert error_reason(error) == "stdlib_error"
  end
end
