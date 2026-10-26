defmodule Hyperlang.FuzzProbeTest do
  # AREA 9 (+ general): bounded grammar-based fuzzing of guest source. Each
  # generated program is compiled and, if it compiles, run under a tight wall
  # deadline. A program is FLAGGED only for an unambiguous sandbox failure:
  #
  #   * compile or run RAISES instead of returning a tagged tuple (host crash),
  #   * a successful result/meta carries a pid, port, ref, or fun (sanitizer
  #     bypass),
  #   * the door returns the catch-all :internal/unknown_fault_category taxonomy
  #     escape.
  #
  # Opt-in: `mix test test/sandbox/fuzz_probe_test.exs --include sandbox_fuzz`.
  # HL_FUZZ_SEED / HL_FUZZ_MUT_SEED fix the master seeds and HL_FUZZ_N /
  # HL_FUZZ_MUT_N the program counts. Set HL_FUZZ_EVIDENCE to a directory to
  # record the count summaries there.
  use ExUnit.Case, async: false
  @moduletag :sandbox_fuzz
  import Hyperlang.SandboxProbe

  @atoms ~w(ok error a b c foo bar baz node self undefined true false nil stop reply noreply)
  @allowed_atoms Enum.map(@atoms, &String.to_atom/1)

  # A mix of allowlisted, forbidden, native, and nonsense MFAs. The fuzzer does
  # not assume which are rejected — it only checks the sandbox never crashes or
  # leaks a forbidden term.
  @mfas [
    "erlang:length",
    "erlang:abs",
    "erlang:hd",
    "erlang:tl",
    "erlang:element",
    "lists:map",
    "lists:foldl",
    "lists:reverse",
    "lists:seq",
    "maps:get",
    "maps:put",
    "maps:fold",
    "binary:part",
    "binary:copy",
    "binary:split",
    "io:format",
    "io_lib:format",
    "filename:join",
    "filename:basename",
    "re:run",
    "unicode:characters_to_binary",
    "base64:encode",
    "string:length",
    "math:sqrt",
    "erlang:phash2",
    "erlang:setelement",
    "lists:sort",
    # forbidden / native / nonsense
    "os:cmd",
    "erlang:halt",
    "erlang:apply",
    "erlang:list_to_atom",
    "erlang:binary_to_term",
    "ets:new",
    "code:load_file",
    "spawn",
    "erlang:make_ref",
    "whereis",
    "register",
    "monitor",
    "frobnicate:wizzle"
  ]

  defp record_summary(name, summary) do
    IO.puts(inspect(Map.delete(summary, :flagged), pretty: true, limit: :infinity))

    case System.get_env("HL_FUZZ_EVIDENCE") do
      nil ->
        :ok

      dir ->
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, name), inspect(summary, pretty: true, limit: :infinity))
    end
  end

  defp has_forbidden?(term) do
    cond do
      is_pid(term) or is_port(term) or is_reference(term) or is_function(term) -> true
      is_tuple(term) -> term |> Tuple.to_list() |> Enum.any?(&has_forbidden?/1)
      is_list(term) -> list_any_forbidden?(term)
      is_map(term) -> Enum.any?(term, fn {k, v} -> has_forbidden?(k) or has_forbidden?(v) end)
      true -> false
    end
  end

  defp list_any_forbidden?([h | t]), do: has_forbidden?(h) or list_any_forbidden?(t)
  defp list_any_forbidden?([]), do: false
  defp list_any_forbidden?(tail), do: has_forbidden?(tail)

  # ---- grammar -------------------------------------------------------------

  defp gen_expr(0), do: gen_leaf()

  defp gen_expr(depth) do
    case :rand.uniform(16) do
      1 ->
        gen_leaf()

      2 ->
        "(#{gen_expr(depth - 1)} #{binop()} #{gen_expr(depth - 1)})"

      3 ->
        "#{call_mfa()}(#{gen_args(depth - 1)})"

      4 ->
        "[#{gen_args(depth - 1)}]"

      5 ->
        "{#{gen_args(depth - 1)}}"

      6 ->
        "\#{#{gen_map_fields(depth - 1)}}"

      7 ->
        "fun() -> #{gen_expr(depth - 1)} end"

      8 ->
        "fun(X) -> #{gen_expr(depth - 1)} end"

      9 ->
        "case #{gen_expr(depth - 1)} of #{gen_atom()} -> #{gen_expr(depth - 1)}; _ -> #{gen_expr(depth - 1)} end"

      10 ->
        "try #{gen_expr(depth - 1)} catch _:_ -> #{gen_expr(depth - 1)} end"

      11 ->
        "try #{gen_expr(depth - 1)} catch _:_:_ -> #{gen_expr(depth - 1)} end"

      12 ->
        "begin #{gen_args(depth - 1)} end"

      13 ->
        "[#{gen_expr(depth - 1)} || _ <- #{gen_list(depth - 1)}]"

      14 ->
        gen_binary(depth - 1)

      15 ->
        "if #{gen_expr(depth - 1)} =:= #{gen_expr(depth - 1)} -> #{gen_atom()}; true -> #{gen_atom()} end"

      16 ->
        "receive _ -> #{gen_atom()} after 0 -> #{gen_atom()} end"
    end
  end

  defp gen_leaf do
    case :rand.uniform(9) do
      1 -> Integer.to_string(:rand.uniform(1_000_000) - 500_000)
      2 -> "(1 bsl #{:rand.uniform(200)})"
      3 -> Float.to_string(:rand.uniform() * 1000)
      4 -> gen_atom()
      5 -> "\"#{rand_string()}\""
      6 -> "<<\"#{rand_string()}\">>"
      7 -> "X"
      8 -> "[]"
      9 -> "$" <> <<Enum.random(?a..?z)>>
    end
  end

  defp gen_binary(depth) do
    segs =
      for _ <- 1..:rand.uniform(3) do
        v = gen_expr(min(depth, 1))

        case :rand.uniform(6) do
          1 -> v
          2 -> "#{v}:#{:rand.uniform(64)}"
          3 -> "#{v}/integer"
          4 -> "#{v}/utf8"
          5 -> "#{v}:#{:rand.uniform(32)}/little-unsigned"
          6 -> "#{v}/binary"
        end
      end

    "<<" <> Enum.join(segs, ", ") <> ">>"
  end

  defp gen_map_fields(depth) do
    for(_ <- 1..:rand.uniform(3), do: "#{gen_expr(min(depth, 1))} => #{gen_expr(min(depth, 1))}")
    |> Enum.join(", ")
  end

  defp gen_list(depth), do: "[#{gen_args(depth)}]"

  defp gen_args(depth) do
    for(_ <- 1..:rand.uniform(3), do: gen_expr(max(depth, 0)))
    |> Enum.join(", ")
  end

  defp gen_atom, do: Enum.random(@atoms)
  defp call_mfa, do: Enum.random(@mfas)

  defp binop,
    do: Enum.random(~w(+ - * div rem band bor bxor bsl bsr ++ -- == =:= =/= < > andalso orelse))

  defp rand_string, do: for(_ <- 1..:rand.uniform(6), into: "", do: <<Enum.random(?a..?z)>>)

  defp gen_program do
    "result(_) -> #{gen_expr(5)}."
  end

  # ---- campaign ------------------------------------------------------------

  defp classify(src) do
    try do
      case compile(src, %{
             terms: %{public: :erlang, allowed_atoms: @allowed_atoms},
             limits: %{wall_ms: 50}
           }) do
        {:error, _} ->
          :rejected

        {:ok, program} ->
          try do
            case Hyperlang.Test.run(program, :entry, [nil]) do
              {:ok, val, meta} ->
                if has_forbidden?(val) or has_forbidden?(Map.get(meta, :stdout, [])),
                  do: {:flag, :forbidden_term_in_result},
                  else: :ran_ok

              {:error, %{category: :internal, message: msg}} ->
                {:flag, {:internal_fault, msg}}

              {:error, %{details: %{"reason" => "unknown_fault_category"}}} ->
                {:flag, :unknown_fault_category}

              {:error, _} ->
                :ran_error
            end
          rescue
            e -> {:flag, {:run_raised, Exception.message(e)}}
          catch
            k, v -> {:flag, {:run_threw, inspect({k, v})}}
          end
      end
    rescue
      e -> {:flag, {:compile_raised, Exception.message(e)}}
    catch
      k, v -> {:flag, {:compile_threw, inspect({k, v})}}
    end
  end

  test "grammar fuzzing: no generated program crashes the host or leaks a forbidden term" do
    n = String.to_integer(System.get_env("HL_FUZZ_N") || "1500")

    master =
      String.to_integer(
        System.get_env("HL_FUZZ_SEED") || Integer.to_string(:erlang.unique_integer([:positive]))
      )

    {counts, flagged} =
      Enum.reduce(1..n, {%{}, []}, fn i, {counts, flagged} ->
        :rand.seed(:exsss, {master, i, i * 2 + 1})
        src = gen_program()
        outcome = classify(src)

        tag = if match?({:flag, _}, outcome), do: :flagged, else: outcome
        counts = Map.update(counts, tag, 1, &(&1 + 1))

        flagged =
          case outcome do
            {:flag, reason} -> [%{seed: i, reason: inspect(reason), src: src} | flagged]
            _ -> flagged
          end

        {counts, flagged}
      end)

    summary = %{
      kind: "grammar",
      n: n,
      master_seed: master,
      counts: Map.new(counts, fn {k, v} -> {to_string(k), v} end),
      flagged_count: length(flagged),
      flagged: Enum.take(flagged, 50)
    }

    record_summary("fuzz_grammar_summary.json", summary)

    assert flagged == [],
           "fuzzing flagged #{length(flagged)} programs (master_seed=#{master}): " <>
             inspect(Enum.take(flagged, 5), limit: :infinity)
  end

  test "mutation fuzzing: mutlate known probe snippets without crashing the host" do
    corpus = [
      "result(_) -> apply(erlang, get, []).",
      "result(_) -> F = fun() -> ok end, case F of 1 -> ok end.",
      "result(_) -> io_lib:format(\"~p\", [fun() -> ok end]).",
      "result(_) -> 1 bsl 100000.",
      "result(_) -> [1 | 2].",
      "result(_) -> binary:part(<<1,2,3>>, 0, 10).",
      "result(_) -> try (fun L() -> L() end)() catch _:_ -> escaped end.",
      "result(_) -> maps:fold(fun(_,_,_) -> ok end, 0, \#{}).",
      "result(_) -> <<X:9999999>>.",
      "result(_) -> element(5, {1})."
    ]

    n = String.to_integer(System.get_env("HL_FUZZ_MUT_N") || "600")

    master =
      String.to_integer(
        System.get_env("HL_FUZZ_MUT_SEED") ||
          Integer.to_string(:erlang.unique_integer([:positive]))
      )

    {counts, flagged} =
      Enum.reduce(1..n, {%{}, []}, fn i, {counts, flagged} ->
        :rand.seed(:exsss, {master, i, i * 3 + 7})
        base = Enum.random(corpus)
        src = mutate(base)
        outcome = classify(src)
        tag = if match?({:flag, _}, outcome), do: :flagged, else: outcome
        counts = Map.update(counts, tag, 1, &(&1 + 1))

        flagged =
          case outcome do
            {:flag, reason} -> [%{seed: i, reason: inspect(reason), src: src} | flagged]
            _ -> flagged
          end

        {counts, flagged}
      end)

    summary = %{
      kind: "mutation",
      n: n,
      master_seed: master,
      counts: Map.new(counts, fn {k, v} -> {to_string(k), v} end),
      flagged_count: length(flagged),
      flagged: Enum.take(flagged, 50)
    }

    record_summary("fuzz_mutation_summary.json", summary)

    assert flagged == [],
           "mutation fuzzing flagged #{length(flagged)} programs (master_seed=#{master}): " <>
             inspect(Enum.take(flagged, 5), limit: :infinity)
  end

  defp mutate(src) do
    chars = String.to_charlist(src)

    Enum.reduce(1..:rand.uniform(4), chars, fn _, acc -> mutate_once(acc) end)
    |> List.to_string()
  end

  defp mutate_once(chars) do
    case {chars, :rand.uniform(4)} do
      {[], _} ->
        ~c"result(_) -> ok."

      {cs, 1} ->
        List.insert_at(cs, :rand.uniform(length(cs)) - 1, Enum.random(~c"(){}[]<>|,.: 0abfun"))

      {cs, 2} ->
        List.delete_at(cs, :rand.uniform(length(cs)) - 1)

      {cs, 3} ->
        List.replace_at(cs, :rand.uniform(length(cs)) - 1, Enum.random(~c"0123456789xyz<>{}"))

      {cs, 4} ->
        cs ++ ~c" ++ os:cmd(\"id\")"
    end
  end
end
