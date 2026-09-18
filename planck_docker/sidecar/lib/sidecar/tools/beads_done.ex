defmodule Sidecar.Tools.BeadsDone do
  @moduledoc """
  Marks a bead as done. Workers opt in via `TEAM.json`, alongside `bd_ready`.

  `broadcast_refresh/0` is not called yet — Sidecar.Beads.broadcast_refresh/0
  itself doesn't exist until `Sidecar.Widgets.Beads` does, since it renders
  through that widget. Add the call here once both exist.
  """

  @doc "Returns the `bd_done` tool definition."
  @spec tool() :: Planck.Agent.Tool.t()
  def tool do
    Planck.Agent.Tool.new(
      name: "bd_done",
      description:
        "Use when you've finished a shared task (bead) and want to mark it done, by its id.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "issue_id" => %{"type" => "string", "description" => "The bead's id, e.g. \"bd-abc\"."}
        },
        "required" => ["issue_id"]
      },
      execute_fn: fn agent_id, _id, %{"issue_id" => issue_id} ->
        actor = Sidecar.Tools.Beads.resolve_actor(agent_id)
        ui = %{ui: Sidecar.Tools.Beads.board_ui()}

        case Sidecar.Beads.close(issue_id, actor) do
          {:ok, %{"already_closed" => true}} ->
            {:ok, "#{issue_id} was already closed.", ui}

          {:ok, _} ->
            {:ok, "Marked #{issue_id} as done.", ui}

          {:error, {status, body}} ->
            {:error, "Failed to close #{issue_id}: HTTP #{status} #{inspect(body)}"}

          {:error, reason} ->
            {:error, "Failed to close #{issue_id}: #{inspect(reason)}"}
        end
      end
    )
  end
end
