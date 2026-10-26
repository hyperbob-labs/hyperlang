defmodule Hyperlang.Isolation.Native do
  @moduledoc false
  alias Hyperlang.Test, as: Kit

  # These are guest-reachable calls with explicit larger host-selected term
  # limits. Markers surround the call; arming the scope CPU policy after entry
  # measures kill-request-to-door-return delay while native work is in flight.
  def interruptions do
    cases = [
      {:binary_copy, "B = binary:copy(<<0>>, N), byte_size(B)", 32_000_000},
      {:phash2, "erlang:phash2(lists:duplicate(N, 1))", 1_000_000},
      {:bignum_multiply, "X = 1 bsl N, Y = X * X, Y band 1", 4_000_000},
      {:regex, "re:run(lists:duplicate(N, 97) ++ [33], <<\"^(a+)+$\">>)", 100_000},
      {:unicode, "B = unicode:characters_to_binary(lists:duplicate(N, 16#10ffff)), byte_size(B)",
       100_000},
      {:format_width, "length(io_lib:format(\"~1000000c\", [65]))", 0}
    ]

    Enum.map(cases, fn {name, expression, input} ->
      owner = self()

      bindings = %{
        "mark" => %{
          enter: fn ->
            send(owner, {:native_begin, self(), System.monotonic_time(:microsecond)})
            nil
          end,
          leave: fn ->
            send(owner, {:native_end, self(), System.monotonic_time(:microsecond)})
            nil
          end
        }
      }

      p =
        Kit.program!(
          "result(N) -> mark:enter(), R = begin " <> expression <> " end, mark:leave(), R.",
          %{
            bindings: bindings,
            terms: %{public: :erlang},
            limits: %{
              max_binary_bytes: 32_000_000,
              max_integer_bits: 8_000_100,
              max_list_length: 1_000_001,
              max_total_words: 16_000_000,
              max_output_bytes: 32_000_000
            }
          }
        )

      Hyperlang.module(p)

      samples =
        for _ <- 1..20 do
          scope = make_ref()
          policy = %{sample_ms: 1, priority: :latency, heap_words: 64_000_000, max_violations: 1}
          :ok = Hyperlang.Scope.configure(scope, policy)

          task =
            Task.async(fn ->
              Kit.run(p, :entry, [input],
                bindings: bindings,
                policy: %{
                  scope: scope,
                  max_reductions: nil,
                  wall_ms: 1000,
                  heap_words: 32_000_000
                }
              )
            end)

          marker =
            receive do
              {:native_begin, pid, at} -> {pid, at}
            after
              1000 -> :not_entered
            end

          armed = System.monotonic_time(:microsecond)

          :ok =
            Hyperlang.Scope.configure(scope, Map.put(policy, :rate, %{quota: 1, period_ms: 1000}))

          result = Task.await(task, 2000)
          returned = System.monotonic_time(:microsecond)
          stats = Hyperlang.Scope.stats(scope)

          duration =
            case marker do
              {pid, at} ->
                receive do
                  {:native_end, ^pid, done} -> done - at
                after
                  0 -> nil
                end

              _ ->
                nil
            end

          :ok = Hyperlang.Scope.close(scope)

          %{
            outcome: category(result),
            native_section_us: duration,
            armed_to_return_us: returned - armed,
            killed: stats.killed?,
            kill_to_return_us:
              if(stats.killed?, do: returned - stats.last_throttle_us, else: nil),
            reaction_bound_us: stats.max_reaction_us
          }
        end

      %{operation: name, input: input, samples: samples}
    end)
  end

  defp category({:ok, _, _}), do: :ok
  defp category({:error, %{category: category}}), do: category
  defp category(other), do: other
end
