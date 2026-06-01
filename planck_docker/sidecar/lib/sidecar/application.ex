defmodule Sidecar.Application do
  @moduledoc false

  use Application

  @watcher if Mix.env() == :test, do: [], else: [Sidecar.Watcher]
  @indexer if Mix.env() == :test, do: [], else: [Sidecar.SessionIndexer]
  @memory if Mix.env() == :test, do: [], else: [Sidecar.Memory]
  @reloader if Mix.env() == :dev, do: [Sidecar.Reloader], else: []

  @impl true
  def start(type, args)

  def start(_type, _args) do
    if Sidecar.Config.agent_vault_url!() do
      Sidecar.Secrets.AgentVault.maybe_migrate()
    end

    connect_task =
      case System.get_env("PLANCK_HEADLESS_NODE") do
        nil -> []
        node -> [{Task, fn -> Node.connect(String.to_atom(node)) end}]
      end

    Supervisor.start_link(
      connect_task ++ @watcher ++ @indexer ++ @memory ++ @reloader,
      strategy: :one_for_one
    )
  end
end
