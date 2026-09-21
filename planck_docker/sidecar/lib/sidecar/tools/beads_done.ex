defmodule Sidecar.Tools.BeadsDone do
  @moduledoc """
  Marks a bead as done. Workers opt in via `TEAM.json`, alongside `bd_ready`.
  """

  @doc """
  Returns the `bd_done` tool definition. `opts` is not part of the LLM-facing
  schema — it accepts `:client` (see `Sidecar.Beads`'s moduledoc) so a test
  can point this tool at a mock server without touching `Sidecar.Config`,
  and `:instance` for the same reason (see `Sidecar.Beads.broadcast_refresh/1`).
  Both are forwarded to `broadcast_refresh/1` too, so an injected client
  reaches the board's own re-fetch, not just this tool's own close request.
  """
  @spec tool(keyword()) :: Planck.Agent.Tool.t()
  def tool(opts \\ []) do
    Planck.Agent.Tool.new(
      name: "bd_done",
      description:
        "Use when you've finished a shared task (bead) and want to mark it done, by its id.",
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
        ui = %{ui: Sidecar.Tools.Beads.board_ui()}

        with {:ok, actor} <- Sidecar.Tools.Beads.require_actor(agent_id),
             {:ok, %{"already_closed" => false}} <- Sidecar.Beads.close(issue_id, actor, opts) do
          Sidecar.Beads.broadcast_refresh(opts)
          {:ok, "Marked #{issue_id} as done.", ui}
        else
          {:ok, %{"already_closed" => true}} ->
            {:ok, "#{issue_id} was already closed.", ui}

          {:error, reason} when is_binary(reason) ->
            {:error, reason}

          {:error, {status, body}} ->
            {:error, "Failed to close #{issue_id}: HTTP #{status} #{inspect(body)}"}

          {:error, reason} ->
            {:error, "Failed to close #{issue_id}: #{inspect(reason)}"}
        end
      end
    )
  end
end
