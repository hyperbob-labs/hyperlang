defmodule Hyperlang.SandboxProbe do
  @moduledoc """
  Shared helpers for the sandbox-lane escape probes (Round 2).

  Each probe asserts the SAFE outcome, so a failing probe is a candidate
  finding. Everything goes through the public door via `Hyperlang.Test`, so a
  probe exercises exactly the path production code takes.
  """

  @doc "Default erlang term policy with a `public` atom set so results round-trip as erlang terms."
  def pub(m \\ %{}) do
    Map.update(m, :terms, %{public: :erlang}, fn t -> Map.put_new(t, :public, :erlang) end)
  end

  @doc """
  Compile `src` and run `:entry` with `[input]`. Returns `{:rejected, errors}`
  if compilation fails, otherwise the `Hyperlang.run/4` result.
  """
  def run(src, manifest \\ %{}, input \\ nil, opts \\ []) do
    case Hyperlang.Test.program(src, pub(manifest)) do
      {:ok, p} -> Hyperlang.Test.run(p, :entry, [input], opts)
      {:error, e} -> {:rejected, e}
    end
  end

  @doc "Compile `src` only. `{:ok, program}` or `{:error, errors}`."
  def compile(src, manifest \\ %{}) do
    Hyperlang.Test.program(src, pub(manifest))
  end

  @doc "True iff the source is rejected at compile time (a verify/source/manifest error)."
  def rejected?(src, manifest \\ %{}), do: match?({:error, _}, compile(src, manifest))

  @doc "True iff the source compiles."
  def compiles?(src, manifest \\ %{}), do: match?({:ok, _}, compile(src, manifest))

  @doc "Inspect any term fully, for substring leak checks."
  def text(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  @doc "Run and return the full inspected text of the result (for leak scans)."
  def run_text(src, manifest \\ %{}, input \\ nil, opts \\ []),
    do: text(run(src, manifest, input, opts))

  @doc "Internal-name leak tokens that must never appear in any public output."
  def leak_tokens,
    do: [
      "hyperlang_slot_",
      "safe_f_",
      "safe_entry",
      "safe_export",
      "$safe_",
      "hyperlang_atom_",
      "hyperlang_var_",
      "hyperlang_msg",
      "io_lib_format",
      "io_lib_pretty",
      "hyperlang_runtime",
      "Hyperlang.Terms",
      "Hyperlang.Runtime",
      "Hyperlang.Worker"
    ]

  @doc "Assert-free leak scan: returns the list of leak tokens present in `text`."
  def leaks_in(text) when is_binary(text) do
    Enum.filter(leak_tokens(), &String.contains?(text, &1))
  end

  @doc "Current VM atom count (for exhaustion probes)."
  def atom_count, do: :erlang.system_info(:atom_count)
end
