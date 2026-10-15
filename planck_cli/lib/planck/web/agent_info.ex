defmodule Planck.Web.AgentInfo do
  @moduledoc """
  Builds the read-only details map rendered by `Planck.Web.Live.AgentDetails`
  in the orchestrator info modal and the worker overlay's sliding details pane.
  """

  alias Planck.Agent
  alias Planck.Headless

  @builtin_commands [
    %{
      name: "clear",
      description: "Delete all messages in the session.",
      kind: :builtin,
      disable_model_invocation: true,
      help: "/clear"
    },
    %{
      name: "compact",
      description: "Compact the session using the compactor.",
      kind: :builtin,
      disable_model_invocation: true,
      help: "/compact [prompt]"
    }
  ]

  @spec build(String.t()) :: {:ok, map()} | {:error, :not_found | :agent_not_found}
  def build(agent_id) do
    with {:ok, pid} <- Agent.whereis(agent_id),
         {:ok, prompt} <- Headless.system_prompt(agent_id) do
      state = Agent.get_state(pid)
      ctx = state.context

      tools =
        ctx.tools
        |> Map.values()
        |> Enum.sort_by(& &1.name)
        |> Enum.map(&%{name: &1.name, description: &1.description})

      {:ok,
       %{
         tools: tools,
         hooks: hooks_list(state.hooks),
         # Skills are the agent's own context; commands are the user-facing
         # trigger surface (builtins + custom + every store skill), so a skill
         # may legitimately appear in both lists.
         skills: skills_list(ctx),
         commands: command_list(),
         system_prompt: prompt
       }}
    end
  end

  @spec hooks_list(Planck.Agent.Hooks.t()) :: [map()]
  def hooks_list(hooks) do
    [
      compactor: hooks.compactor,
      persistence: hooks.persistence,
      prompt: hooks.prompt,
      turn_start: hooks.turn_start,
      turn_end: hooks.turn_end,
      tool_start: hooks.tool_start,
      tool_end: hooks.tool_end
    ]
    |> Enum.reject(fn {_kind, module} -> is_nil(module) end)
    |> Enum.map(fn {kind, module} ->
      %{kind: kind, module: inspect(module), node: hooks.sidecar_node}
    end)
  end

  @spec skills_list(Planck.Agent.Context.t()) :: [map()]
  def skills_list(ctx) do
    ctx.skills_pool
    |> Enum.sort_by(& &1.name)
    |> Enum.map(
      &%{
        name: &1.name,
        description: &1.description,
        always_present: &1.always_present,
        granted: &1.name in ctx.skills_names
      }
    )
  end

  @spec command_list() :: [map()]
  def command_list do
    store = Planck.Headless.ResourceStore.get()

    commands =
      store.commands
      |> Enum.map(
        &%{
          name: &1.name,
          description: &1.description,
          kind: :command,
          disable_model_invocation: &1.disable_model_invocation,
          help: &1.help
        }
      )
      |> Enum.sort_by(& &1.name)

    skills =
      store.skills
      |> Enum.map(
        &%{
          name: &1.name,
          description: &1.description,
          kind: :skill,
          disable_model_invocation: &1.disable_model_invocation,
          help: nil
        }
      )
      |> Enum.sort_by(& &1.name)

    @builtin_commands ++ commands ++ skills
  end
end
