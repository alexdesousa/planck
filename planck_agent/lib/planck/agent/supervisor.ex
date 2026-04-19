defmodule Planck.Agent.Supervisor do
  @moduledoc """
  Top-level supervisor for the `planck_agent` runtime.

  Starts and supervises:
  - `Planck.Agent.PubSub` — `Phoenix.PubSub` for agent event broadcasting
  - `Planck.Agent.Registry` — duplicate-key Registry for team discovery and agent lookup
  - `Planck.Agent.TaskSupervisor` — `Task.Supervisor` for stream tasks
  - `Planck.Agent.SessionSupervisor` — `DynamicSupervisor` for session processes
  - `Planck.Agent.AgentSupervisor` — `DynamicSupervisor` for agent processes

  Uses `:one_for_all` so the Registry and TaskSupervisor always restart together
  with the agents — a stale Registry after a crash would leave agents unable to
  find each other.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Phoenix.PubSub, name: Planck.Agent.PubSub},
      {Registry, keys: :duplicate, name: Planck.Agent.Registry},
      {Task.Supervisor, name: Planck.Agent.TaskSupervisor},
      {DynamicSupervisor, name: Planck.Agent.SessionSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Planck.Agent.AgentSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
