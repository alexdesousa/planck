defmodule Sidecar.Tools.BeadsCreate do
  @moduledoc """
  Creates a new bead (shared task). Orchestrator-only — deciding what work
  exists for the team is an orchestration decision, not something every
  worker should be able to do unilaterally.

  Takes an optional `description` and `priority` alongside `title` — useful
  for a model deciding what to work on next, not just a human. The widget's
  own human-facing create action (`Sidecar.Widgets.Beads.handle_action/2`,
  not built yet) needs the same two fields in its form, not just a title, to
  stay at parity with this tool.

  `broadcast_refresh/0` is not called yet — Sidecar.Beads.broadcast_refresh/0
  itself doesn't exist until `Sidecar.Widgets.Beads` does, since it renders
  through that widget. Add the call here once both exist.
  """

  @doc "Returns the `bd_create` tool definition."
  @spec tool() :: Planck.Agent.Tool.t()
  def tool do
    Planck.Agent.Tool.new(
      name: "bd_create",
      description:
        "Use when new work needs to be tracked as a shared task (bead) for the team, " <>
          "given a title.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "title" => %{"type" => "string", "description" => "Short, descriptive task title."},
          "description" => %{
            "type" => "string",
            "description" =>
              "Full details a worker picking this up would need — context, scope, " <>
                "acceptance criteria. Omit only for genuinely self-explanatory tasks."
          },
          "priority" => %{
            "type" => "integer",
            "minimum" => 0,
            "maximum" => 4,
            "description" => "0 = P0/critical, 4 = lowest. Omit to use the workspace default."
          }
        },
        "required" => ["title"]
      },
      execute_fn: fn agent_id, _id, %{"title" => title} = args ->
        actor = Sidecar.Tools.Beads.resolve_actor(agent_id)
        opts = [description: args["description"], priority: args["priority"]]

        case Sidecar.Beads.create(title, actor, opts) do
          {:ok, %{"id" => id}} ->
            {:ok, "Created #{id}: #{title}", %{ui: Sidecar.Tools.Beads.board_ui()}}

          {:error, {status, body}} ->
            {:error, "Failed to create bead: HTTP #{status} #{inspect(body)}"}

          {:error, reason} ->
            {:error, "Failed to create bead: #{inspect(reason)}"}
        end
      end
    )
  end
end
