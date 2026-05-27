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

  alias Planck.Agent.Message

  @tool_threshold 5

  @impl Planck.Agent.Hooks.TurnEnd
  def reflect(agent_id, turn_messages) do
    tool_call_count = count_tool_calls(turn_messages)

    if @tool_threshold <= tool_call_count do
      do_reflect(agent_id, turn_messages)
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec count_tool_calls([Message.t()]) :: non_neg_integer()
  defp count_tool_calls(messages) do
    messages
    |> Enum.flat_map(& &1.content)
    |> Enum.count(&match?({:tool_call, _, _, _}, &1))
  end

  @spec do_reflect(String.t(), [Message.t()]) :: :ok
  defp do_reflect(agent_id, turn_messages) do
    case Sidecar.SkillReflector.Runner.start(agent_id, turn_messages) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Sidecar.SkillReflector] runner failed to start: #{inspect(reason)}")
        :ok
    end
  end
end
