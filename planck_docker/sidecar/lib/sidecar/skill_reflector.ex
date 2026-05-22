defmodule Sidecar.SkillReflector do
  @moduledoc """
  `Hooks.TurnEnd` implementation that triggers skill reflection after complex turns.

  When the number of tool calls in a turn meets or exceeds `reflect_threshold/0`,
  a `Sidecar.SkillReflector.Runner` is started to evaluate whether the workflow
  should be captured as a reusable skill.

  ## TEAM.json

      { "turn_end_hook": "Sidecar.SkillReflector" }
  """

  use Planck.Agent.Hooks.TurnEnd

  require Logger

  @impl Planck.Agent.Hooks.TurnEnd
  def reflect_threshold, do: 5

  @impl Planck.Agent.Hooks.TurnEnd
  def reflect(agent_id, turn_messages) do
    case Sidecar.SkillReflector.Runner.start(agent_id, turn_messages) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Sidecar.SkillReflector] runner failed to start: #{inspect(reason)}")
        :ok
    end
  end
end
