defmodule Sidecar.Tools.ListSkills do
  @moduledoc """
  A `list_skills` tool restricted to agent-created skills (`creator: agent`).

  Used exclusively inside the SkillReflector's mini-agent so it only sees
  skills it wrote itself — user-curated skills are not surfaced to avoid
  unintended rewrites.
  """

  alias Planck.Agent.Skill

  @doc "Returns a `list_skills` tool that shows only agent-created skills."
  @spec tool() :: Planck.Agent.Tool.t()
  def tool do
    Planck.Agent.Tool.new(
      name: "list_skills",
      description:
        "List all agent-created skills with their names and descriptions. " <>
          "Always call this before write_skill to check whether a skill with " <>
          "the same purpose already exists.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => []
      },
      execute_fn: fn _agent_id, _id, _args ->
        list()
      end
    )
  end

  @doc "Returns agent-created skills from the workspace as a formatted string."
  @spec list() :: {:ok, String.t()} | {:error, String.t()}
  def list do
    workspace = Sidecar.Config.workspace_dir!()
    skills_dir = Path.join([workspace, ".planck", "skills"])

    skills =
      [skills_dir]
      |> Skill.load_all()
      |> Enum.filter(&(&1.creator == "agent"))

    case skills do
      [] ->
        {:ok, "No agent-created skills yet."}

      _ ->
        entries = Enum.map_join(skills, "\n", fn s -> "- **#{s.name}**: #{s.description}" end)
        {:ok, entries}
    end
  end
end
