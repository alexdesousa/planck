defmodule Sidecar.Tools.BeadsDelete do
  @moduledoc """
  Deletes a bead (shared task) by id. Orchestrator-only — an irreversible,
  team-wide action, not something every worker should be able to do
  unilaterally.

  `broadcast_refresh/0` is not called yet — Sidecar.Beads.broadcast_refresh/0
  itself doesn't exist until `Sidecar.Widgets.Beads` does, since it renders
  through that widget. Add the call here once both exist.
  """

  @doc "Returns the `bd_delete` tool definition."
  @spec tool() :: Planck.Agent.Tool.t()
  def tool do
    Planck.Agent.Tool.new(
      name: "bd_delete",
      description:
        "Use when a shared task (bead) is no longer needed and should be permanently " <>
          "removed, by its id. This cannot be undone.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "issue_id" => %{"type" => "string", "description" => "The bead's id, e.g. \"bd-abc\"."}
        },
        "required" => ["issue_id"]
      },
      execute_fn: fn agent_id, _id, %{"issue_id" => issue_id} ->
        actor = Sidecar.Tools.Beads.resolve_actor(agent_id)

        case Sidecar.Beads.delete([issue_id], actor) do
          {:ok, _} ->
            {:ok, "Deleted #{issue_id}.", %{ui: Sidecar.Tools.Beads.board_ui()}}

          {:error, {status, body}} ->
            {:error, "Failed to delete #{issue_id}: HTTP #{status} #{inspect(body)}"}

          {:error, reason} ->
            {:error, "Failed to delete #{issue_id}: #{inspect(reason)}"}
        end
      end
    )
  end
end
