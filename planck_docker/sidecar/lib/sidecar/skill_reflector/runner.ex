defmodule Sidecar.SkillReflector.Runner do
  @moduledoc """
  Transient GenServer that manages one skill-reflection cycle.

  Lifecycle:
  1. Starts an ephemeral `Planck.Agent` with `list_skills`, `load_skill`, and
     `write_skill` tools and the SkillReflector prompt.
  2. Prompts the mini-agent once with the parent turn context.
  3. Subscribes to the mini-agent's PubSub topic.
  4. On `:turn_end` — the agent finished its work. If `write_skill` was called,
     injects a `create_skill` or `update_skill` synthetic tool result into the
     parent agent's history via `Agent.inject_tool_result/3`.
  5. Stops itself; the linked mini-agent terminates with it.
  """

  use GenServer

  require Logger

  alias Planck.Agent
  alias Planck.Agent.Skill

  @reflect_max_turns 10

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Start a runner for `parent_agent_id` using the given turn messages."
  @spec start(String.t(), [Agent.Message.t()]) :: {:ok, pid()} | {:error, term()}
  def start(parent_agent_id, turn_messages) do
    GenServer.start(__MODULE__, %{
      parent_agent_id: parent_agent_id,
      turn_messages: turn_messages
    })
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(%{parent_agent_id: parent_agent_id, turn_messages: turn_messages}) do
    Process.flag(:trap_exit, true)

    with {:ok, parent_pid} <- Agent.whereis(parent_agent_id),
         parent_state <- Agent.get_state(parent_pid),
         {:ok, mini_id, mini_pid} <- start_mini_agent(parent_state, turn_messages) do
      Process.link(mini_pid)
      Agent.subscribe(mini_id)

      Agent.prompt(
        mini_pid,
        "Review the completed turn and determine if a skill should be captured."
      )

      {:ok,
       %{
         parent_pid: parent_pid,
         mini_id: mini_id,
         mini_pid: mini_pid,
         turn_count: 0,
         skill_result: nil
       }}
    else
      error ->
        Logger.warning("[SkillReflector.Runner] could not start: #{inspect(error)}")
        {:stop, :normal}
    end
  end

  @impl true
  def handle_info({:agent_event, :tool_end, %{name: "write_skill", result: {:ok, result}}}, state) do
    {:noreply, %{state | skill_result: result}}
  end

  def handle_info({:agent_event, :turn_end, _payload}, state) do
    new_count = state.turn_count + 1

    if new_count >= @reflect_max_turns do
      Logger.warning(
        "[SkillReflector.Runner] max turns (#{@reflect_max_turns}) reached — stopping"
      )
    end

    inject_and_stop(%{state | turn_count: new_count})
  end

  def handle_info({:EXIT, pid, reason}, %{mini_pid: pid} = state) do
    unless reason == :normal do
      Logger.warning("[SkillReflector.Runner] mini-agent exited: #{inspect(reason)}")
    end

    {:stop, :normal, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{mini_pid: pid} = _state) when is_pid(pid) do
    if Process.alive?(pid), do: Agent.stop(pid)
  end

  def terminate(_reason, _state), do: :ok

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec start_mini_agent(Agent.t(), [Agent.Message.t()]) ::
          {:ok, String.t(), pid()} | {:error, term()}
  defp start_mini_agent(parent_state, turn_messages) do
    workspace = Sidecar.Config.workspace_dir!()
    skills_dir = Path.join([workspace, ".planck", "skills"])
    skills = Skill.load_all([skills_dir])

    load_skill =
      Skill.load_skill_tool(skills, skill_refresh_fn: fn -> Skill.load_all([skills_dir]) end)

    tools = [
      Sidecar.Tools.ListSkills.tool(),
      load_skill,
      Sidecar.Tools.WriteSkill.tool()
    ]

    system_prompt =
      Sidecar.SkillReflector.Prompt.build(
        turn_messages,
        parent_state.name || "agent"
      )

    mini_id = "reflector-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    opts = [
      id: mini_id,
      model: parent_state.model,
      system_prompt: system_prompt,
      tools: tools
    ]

    case DynamicSupervisor.start_child(Planck.Agent.AgentSupervisor, {Planck.Agent, opts}) do
      {:ok, pid} -> {:ok, mini_id, pid}
      error -> error
    end
  end

  @spec inject_and_stop(map()) :: {:stop, :normal, map()}
  defp inject_and_stop(%{skill_result: nil} = state) do
    {:stop, :normal, state}
  end

  defp inject_and_stop(%{skill_result: result, parent_pid: parent_pid} = state) do
    case String.split(result, ":", parts: 2) do
      [action, name] ->
        Agent.inject_tool_result(parent_pid, action, name)

      _ ->
        Logger.warning(
          "[SkillReflector.Runner] unexpected write_skill result: #{inspect(result)}"
        )
    end

    {:stop, :normal, state}
  end
end
