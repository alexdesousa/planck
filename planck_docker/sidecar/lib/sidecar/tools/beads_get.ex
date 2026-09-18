defmodule Sidecar.Tools.BeadsGet do
  @moduledoc """
  Fetches a single bead's current, full details by id. Workers opt in via
  `TEAM.json`, alongside `bd_ready`/`bd_done` — checking on your own
  claimed work's current state isn't an orchestration decision.

  Exists because nothing else gives an agent this: `bd_ready` stops
  listing a bead once it's claimed, and `bd_claim`'s own response is a
  one-time snapshot from claim time. An agent partway through a
  long-running claimed task, wanting to notice a human edited the
  description in the widget since, has no other way to check.
  """

  @doc "Returns the `bd_get` tool definition."
  @spec tool() :: Planck.Agent.Tool.t()
  def tool do
    Planck.Agent.Tool.new(
      name: "bd_get",
      description:
        "Use when you want the current, full details of a specific shared task (bead) " <>
          "by its id — e.g. to check whether its description changed since you claimed it.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "issue_id" => %{"type" => "string", "description" => "The bead's id, e.g. \"bd-abc\"."}
        },
        "required" => ["issue_id"]
      },
      execute_fn: fn _agent_id, _id, %{"issue_id" => issue_id} ->
        case Sidecar.Beads.fetch(issue_id) do
          {:ok, issue} ->
            {:ok, format_issue(issue), %{ui: Sidecar.Tools.Beads.board_ui()}}

          {:error, {404, _body}} ->
            {:error, "#{issue_id} was not found."}

          {:error, {status, body}} ->
            {:error, "Failed to fetch #{issue_id}: HTTP #{status} #{inspect(body)}"}

          {:error, reason} ->
            {:error, "Failed to fetch #{issue_id}: #{inspect(reason)}"}
        end
      end
    )
  end

  @spec format_issue(map()) :: String.t()
  defp format_issue(issue) do
    header =
      "#{issue["id"]}: #{issue["title"]} " <>
        "(#{issue["status"]}, #{issue["issue_type"]}, priority #{issue["priority"]})"

    Sidecar.Tools.Beads.with_description(header, issue)
  end
end
