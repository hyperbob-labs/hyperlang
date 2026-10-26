defmodule Hyperlang.Binding do
  @moduledoc """
  A named host capability that guest code calls statically.

  A binding is a trusted host module. It declares the closed list of guest-
  callable functions with `exports/0` and implements them in `call/3`:

      defmodule MyHost.KV do
        @behaviour Hyperlang.Binding

        @impl true
        def exports, do: [get: 1, put: 2]

        @impl true
        def call(%{ns: ns}, :get, [key]), do: MyHost.Store.get(ns, key)
        def call(%{ns: ns}, :put, [key, value]), do: MyHost.Store.put(ns, key, value)
      end

  The program names the binding once, in its manifest:

      Hyperlang.program(%{entry: "main.erl", files: files,
                          manifest: %{bindings: %{"kv" => MyHost.KV}}})

  `Hyperlang.program/1` calls `exports/0` and pins the derived MFA set
  (`kv:get/1`, `kv:put/2`) into the normalized manifest, so the set is part
  of the program hash. Guest code calls `kv:get(Key)` as an ordinary static
  remote call; any other `kv:` function is a compile error.

  A run supplies the same module with its per-run state:

      Hyperlang.run(%{bindings: %{"kv" => {MyHost.KV, %{ns: tenant}}}},
                    program, :entry, [key])

  A run that omits a declared binding, names an undeclared one, or supplies a
  different module fails before guest code starts. `state` never reaches the
  guest, so secrets, tenant ids, and connection handles belong there.

  ## Export options

  An export may carry options as a third tuple element,
  `{name, arity, opts}`:

    * `:limits` — term limits applied to the call's arguments and return
      value (same keys as manifest `limits`)
    * `:nondeterministic` — `true` marks the call as nondeterministic; the
      manifest must then enable `capabilities.nondeterminism`
    * `:effects` — free-form effect labels recorded in the manifest
    * `:docs` — `%{moduledoc:, doc:, signature:}` text served by the guest
      `code:get_doc/1` surface

  ## Call contract

  `call/3` runs synchronously in the guest's process, inside the metered
  call. Arguments arrive sanitized; the return value is sanitized before the
  guest sees it. A raise or throw becomes a guest `import` fault.
  """

  @type export :: {atom(), arity()} | {atom(), arity(), keyword() | map()}

  @callback exports() :: [export()]
  @callback call(state :: term(), function :: atom(), args :: list()) :: term()
end
