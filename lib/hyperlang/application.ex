defmodule Hyperlang.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Owned here so the guest-handle table outlives every filesystem server,
    # worker and registry restart.
    Hyperlang.Filesystem.create_guest_handle_registry()
    # Code-slot pins likewise outlive a CodeServer restart.
    Hyperlang.CodeServer.create_pin_table()

    children = [
      Hyperlang.AtomUniverse,
      Hyperlang.Scope,
      Hyperlang.MsgTimerServer,
      Hyperlang.Chan.Registry,
      Hyperlang.Chan.BrokerSupervisor,
      Hyperlang.CodeServer,
      Hyperlang.Limits,
      Hyperlang.Cache,
      Hyperlang.Filesystem.Registry,
      {DynamicSupervisor, strategy: :one_for_one, name: Hyperlang.Filesystem.Supervisor},
      {Task.Supervisor, name: Hyperlang.Filesystem.TaskSupervisor}
    ]

    # AtomUniverse owns the generated-atom assignment table used by cached BEAMs.
    # If it restarts, the code/cache processes after it must restart too so no
    # cached program can survive with stale atom-slot assumptions.
    opts = [strategy: :rest_for_one, name: Hyperlang.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
