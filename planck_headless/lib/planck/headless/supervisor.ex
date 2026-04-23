defmodule Planck.Headless.Supervisor do
  @moduledoc false

  use Supervisor

  @spec start_link() :: Supervisor.on_start()
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Future phases add children: Planck.Agent.Supervisor as a child,
    # Planck.Headless.AppSupervisor with ResourceStore and SessionRegistry.
    Supervisor.init([], strategy: :one_for_one)
  end
end
