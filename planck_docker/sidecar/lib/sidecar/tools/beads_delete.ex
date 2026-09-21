defmodule Sidecar.Tools.BeadsDelete do
  @moduledoc """
  Deletes a bead (shared task) by id. Orchestrator-only — an irreversible,
  team-wide action, not something every worker should be able to do
  unilaterally.
  """

  @doc """
  Returns the `bd_delete` tool definition. `opts` is not part of the LLM-facing
  schema — it accepts `:client` (see `Sidecar.Beads`'s moduledoc) so a test
  can point this tool at a mock server without touching `Sidecar.Config`,
  and `:instance` for the same reason (see `Sidecar.Beads.broadcast_refresh/1`).
  Both are forwarded to `broadcast_refresh/1` too, so an injected client
  reaches the board's own re-fetch, not just this tool's own delete request.
  """
  @spec tool(keyword()) :: Planck.Agent.Tool.t()
  def tool(opts \\ []) do
    Planck.Agent.Tool.new(
      name: "bd_delete",
      description:
        "Use when a shared task (bead) is no longer needed and should be permanently " <>
          "removed, by its id. This cannot be undone.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "issue_id" => %{
            "type" => "string",
            "description" => "The bead's id, e.g. \"planck-abc\"."
          }
        },
        "required" => ["issue_id"]
      },
      execute_fn: fn agent_id, _id, %{"issue_id" => issue_id} ->
        with {:ok, actor} <- Sidecar.Tools.Beads.require_actor(agent_id),
             {:ok, _} <- Sidecar.Beads.delete([issue_id], actor, opts) do
          Sidecar.Beads.broadcast_refresh(opts)
          {:ok, "Deleted #{issue_id}.", %{ui: Sidecar.Tools.Beads.board_ui()}}
        else
          {:error, reason} when is_binary(reason) ->
            {:error, reason}

          {:error, {status, body}} ->
            {:error, "Failed to delete #{issue_id}: HTTP #{status} #{inspect(body)}"}

          {:error, reason} ->
            {:error, "Failed to delete #{issue_id}: #{inspect(reason)}"}
        end
      end
    )
  end
end
