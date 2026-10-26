iterations =
  case System.get_env("HYPERLANG_BENCH_ITERATIONS") do
    nil -> 100_000
    value -> String.to_integer(value)
  end

source = "Input."

measure = fn label, limits ->
  {:ok, program} = Hyperlang.program(source)
  spec = %{bindings: %{}, policy: Map.merge(%{run_in_caller?: true}, limits)}

  call = fn ->
    {:ok, 42, _metrics} = Hyperlang.run(spec, program, :entry, [42])
  end

  Enum.each(1..2_000, fn _ -> call.() end)

  started = System.monotonic_time(:nanosecond)
  Enum.each(1..iterations, fn _ -> call.() end)
  elapsed = System.monotonic_time(:nanosecond) - started

  ns_per_op = elapsed / iterations
  IO.puts("#{label}: #{Float.round(ns_per_op, 2)} ns/op (#{iterations} iterations)")
  ns_per_op
end

disabled =
  measure.("limits_disabled", %{
    wall_ms: :infinity,
    max_reductions: nil,
    max_heap_words: nil
  })

armed =
  measure.("limits_armed", %{
    wall_ms: 60_000,
    max_reductions: 1_000_000_000,
    max_heap_words: nil
  })

IO.puts("armed_overhead: #{Float.round(armed - disabled, 2)} ns/op")
