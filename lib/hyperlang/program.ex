defmodule Hyperlang.Program do
  @moduledoc """
  An immutable, content-addressed guest program.

  `Hyperlang.program/1,2` returns this struct. Treat it as an opaque value:
  pass it to `Hyperlang.run/4` or `Hyperlang.module/1`, and compare or cache
  it by `content_hash`. The same source and manifest always produce an equal
  program. `metadata` holds public program metadata (declared exports, the
  normalized manifest summary and the source snapshot listing); it never
  names generated modules or helpers.
  """

  defstruct [
    :content_hash,
    :source_hash,
    :manifest_hash,
    :compiler_version,
    :stdlib_version,
    :metadata,
    :artifact
  ]

  @typedoc "An immutable compiled program value."
  @type t :: %__MODULE__{}

  # Source-derived module identity: a `.erl` basename names a module only when
  # it is a valid Erlang atom-shaped module name. Callers shape their own
  # error (guest-facing `:badarg` vs host-facing `Hyperlang.Error`).
  @module_name ~r/^[a-z][A-Za-z0-9_@]*$/
  # Generated slot modules are Hyperlang's private namespace: guest source may
  # never claim one.
  @reserved_module_name ~r/^hyperlang_slot_\d+$/

  @doc false
  # The one content-identity primitive: lowercase sha256 hex over a binary, or
  # over a term's deterministic external representation. Plain encoding orders
  # small atom-keyed maps by atom-table index, which differs between builds and
  # nodes, so equal terms must be encoded with `:deterministic`.
  def sha256_hex(data) when is_binary(data),
    do: Base.encode16(:crypto.hash(:sha256, data), case: :lower)

  def sha256_hex(term), do: term |> :erlang.term_to_binary([:deterministic]) |> sha256_hex()

  @doc false
  def module_name_from_basename(path) when is_binary(path) do
    name = path |> Path.basename() |> String.replace_suffix(".erl", "")

    if Regex.match?(@module_name, name), do: {:ok, name}, else: :error
  end

  def module_name_from_basename(_path), do: :error

  @doc false
  def reserved_module_name?(name) when is_binary(name),
    do: Regex.match?(@reserved_module_name, name)

  def reserved_module_name?(_name), do: false
end
