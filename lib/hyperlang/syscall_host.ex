defmodule Hyperlang.SyscallHost do
  @moduledoc """
  The host syscall door contract.

  A host (for example the hyperbob_os kernel) supplies guest syscalls as a bound
  module rather than an anonymous closure: `{module, state}` where `module`
  implements this behaviour and `state` is an opaque host term resolved when
  the instance/eval is wired. Every guest syscall is then a single static
  remote call:

      module.syscall(state, operation, args)

  Return-value convention:

    * any term — the syscall value, passed back to the guest facade as-is
      (Plan 9 C-style values: fd integers, `{n, bytes}`, `0`/`-1`, `nil`)
    * `{:hyperlang_syscall_error, reason}` — a host-side denial or failure,
      surfaced to the runtime as `{:error, reason}`

  Closures remain supported for tests and ad-hoc hosts: `normalize/2` wraps a
  2- or 3-arity closure in an internal adapter module automatically.
  """

  @type op :: atom()
  @type state :: term()

  @callback syscall(state, op, args :: list()) :: term()
  @doc """
  Return true only when `sys:spawn` argv is an opaque same-program guest transfer.

  The runtime still validates the spawned export name, argv list shape, and opts,
  but it does not recursively project the argv into public host terms. This is
  for scheduler-style hosts such as hyperbob_os, where `spawn` immediately
  re-enters the same verified guest program with those args and the host does
  not inspect or retain the payload as host data. Ad-hoc function hosts and
  bindings that consume argv as ordinary host input must leave this callback
  undefined or return false.
  """
  @callback opaque_spawn_args?(state) :: boolean()

  @doc """
  Normalize a host-supplied `:syscall` option into `{module, state}`.

  Accepts a `{module, state}` pair, a 2-arity closure `fun.(op, args)`, or a
  3-arity closure `fun.(op, args, host_scope)`; returns `nil` when no host is
  attached and `:error` for anything else.
  """
  @spec normalize(term(), term()) :: {module(), state()} | nil | :error
  def normalize(host, host_scope \\ nil)

  def normalize(nil, _host_scope), do: nil

  def normalize({module, state}, _host_scope) when is_atom(module) and not is_nil(module),
    do: {module, state}

  def normalize(fun, _host_scope) when is_function(fun, 2),
    do: {Hyperlang.SyscallHost.Fun, {:arity2, fun}}

  def normalize(fun, host_scope) when is_function(fun, 3),
    do: {Hyperlang.SyscallHost.Fun, {:arity3, fun, host_scope}}

  def normalize(_host, _host_scope), do: :error

  @optional_callbacks opaque_spawn_args?: 1

  # Per-eval host state. The worker seeds this slot in its own process
  # dictionary before the guest entry runs; the host door reads and mutates
  # it on every syscall (one pdict access, no shared-table round-trip); the
  # worker harvests the final value into the reply envelope. Limbo guest code
  # has process-local put/get for module globals, so the host key must remain a
  # reserved runtime atom that guest source atoms cannot name directly.

  @host_state_key :"$hyperlang_host_state"

  @doc "Read the per-eval host state (door-side accessor)."
  @spec get_state() :: state()
  def get_state do
    case Process.get(@host_state_key) do
      {:present, state} -> state
      _absent -> nil
    end
  end

  @doc "Replace the per-eval host state (door-side accessor)."
  @spec put_state(state()) :: :ok
  def put_state(state) do
    Process.put(@host_state_key, {:present, state})
    :ok
  end

  @doc false
  def seed_state(state), do: put_state(state)

  @doc false
  def harvest_state, do: get_state()

  @doc false
  def snapshot_state, do: Process.get(@host_state_key, :absent)

  @doc false
  def clear_state, do: Process.delete(@host_state_key)

  @doc false
  def restore_state(:absent), do: Process.delete(@host_state_key)

  def restore_state({:present, _state} = snapshot) do
    Process.put(@host_state_key, snapshot)
    :ok
  end
end

defmodule Hyperlang.SyscallHost.Fun do
  # Closure adapter: lets tests and ad-hoc hosts keep supplying anonymous
  # functions while the runtime speaks only the SyscallHost contract.
  @moduledoc false

  @behaviour Hyperlang.SyscallHost

  @impl true
  def syscall({:arity2, fun}, operation, args), do: fun.(operation, args)
  def syscall({:arity3, fun, host_scope}, operation, args), do: fun.(operation, args, host_scope)
end
