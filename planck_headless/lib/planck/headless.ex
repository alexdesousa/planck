defmodule Planck.Headless do
  @moduledoc """
  The headless core of the Planck coding agent.

  `planck_headless` is a long-running OTP application that owns configuration,
  loads resources (tools, skills, teams, compactor) at startup, and manages
  session lifecycles. UIs (`planck_tui`, `planck_web`) depend on this module;
  they are rendering surfaces only and never call `planck_agent` directly.

  See `specs/planck-headless.md` for the full design.
  """

  alias Planck.Headless.{Config, ResourceStore}

  @doc "Return the resolved configuration."
  @spec config() :: Config.t()
  def config, do: Config.get()

  @doc "List all registered teams with alias, name, and description."
  @spec list_teams() ::
          [%{alias: String.t(), name: String.t() | nil, description: String.t() | nil}]
  def list_teams do
    ResourceStore.get().teams
    |> Enum.map(fn {alias, team} ->
      %{alias: alias, name: team.name, description: team.description}
    end)
  end

  @doc "Look up a team by alias."
  @spec get_team(String.t()) :: {:ok, Planck.Agent.Team.t()} | {:error, :not_found}
  def get_team(alias) do
    case Map.fetch(ResourceStore.get().teams, alias) do
      {:ok, team} -> {:ok, team}
      :error -> {:error, :not_found}
    end
  end

  @doc "Return models available for use (only providers with API keys configured)."
  @spec available_models() :: [Planck.AI.Model.t()]
  def available_models, do: ResourceStore.get().available_models

  @doc """
  Reload tools, skills, and teams from disk.

  In-flight sessions keep their original resources; only new sessions
  created after this call will see the updated resources.
  """
  @spec reload_resources() :: :ok
  def reload_resources, do: ResourceStore.reload()
end
