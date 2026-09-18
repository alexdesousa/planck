defmodule Sidecar.Tools.BeadsClaim do
  @moduledoc """
  Claims a bead for the calling agent. Orchestrator-only — creating, deleting,
  and assigning work on behalf of the team is an orchestration decision,
  while reading the board (`bd_ready`) and marking your own work done
  (`bd_done`) are things any worker needs to do for itself.

  The LLM never supplies who's claiming; it's resolved server-side from the
  runtime-provided `agent_id`, the same way `Sidecar.Tools.UpdateMemory`
  resolves identity.

  `ClaimResponse` carries the full issue, not just a confirmation flag —
  the success message includes its description (when present), so an agent
  that only saw the title in `bd_ready`'s list gets full context right after
  claiming, not a second round-trip to find out what it just took on.

  `broadcast_refresh/0` is not called yet — Sidecar.Beads.broadcast_refresh/0
  itself doesn't exist until `Sidecar.Widgets.Beads` does, since it renders
  through that widget. Add the call here once both exist.
  """

  @doc "Returns the `bd_claim` tool definition."
  @spec tool() :: Planck.Agent.Tool.t()
  def tool do
    Planck.Agent.Tool.new(
      name: "bd_claim",
      description:
        "Use when you want to claim a shared task (bead) for yourself before starting " <>
          "work on it, by its id.",
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

        case Sidecar.Beads.claim(issue_id, actor) do
          {:ok, %{"already_claimed" => true} = body} ->
            {:ok, "You already have #{issue_id} claimed.#{describe(body)}", ui}

          {:ok, body} ->
            {:ok, "Claimed #{issue_id}.#{describe(body)}", ui}

          {:error, {409, %{"assignee" => holder}}} ->
            {:error, "#{issue_id} is already claimed by #{holder}."}

          {:error, {409, %{"issue_status" => status}}} ->
            {:error, "#{issue_id} is not claimable (status: #{status})."}

          {:error, {status, body}} ->
            {:error, "Failed to claim #{issue_id}: HTTP #{status} #{inspect(body)}"}

          {:error, reason} ->
            {:error, "Failed to claim #{issue_id}: #{inspect(reason)}"}
        end
      end
    )
  end

  @spec describe(map()) :: String.t()
  defp describe(%{"issue" => %{"description" => description}})
       when is_binary(description) and description != "" do
    "\n\n#{description}"
  end

  defp describe(_body), do: ""
end
