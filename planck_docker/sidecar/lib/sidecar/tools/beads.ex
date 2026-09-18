defmodule Sidecar.Tools.Beads do
  @moduledoc """
  Shared support for the `bd_*` tools (`Sidecar.Tools.BeadsReady`,
  `BeadsGet`, `BeadsDone`, `BeadsClaim`, `BeadsCreate`, `BeadsDelete`) — not
  a tool itself, so it's not registered in Sidecar.Planck.tools/0.

  Holds what those tools would otherwise duplicate: actor identity
  resolution, the `ui:` payload that opens the shared board, and appending
  an issue's description to a formatted header. Every board interaction
  gets the `ui:` button on success now, not just `bd_ready` — an agent that
  claims, creates, marks done, deletes, or re-fetches without ever calling
  `bd_ready` first would otherwise leave the human with no way to open the
  board from that turn at all.
  """

  @doc """
  Resolve the calling agent's durable identity as a beads actor string.
  `agent_id` (`:crypto.strong_rand_bytes(8)`, regenerated every restart)
  isn't durable — `team_name`/`name` (straight from `TEAM.json`) are, so
  that's what gets recorded as the actor.
  """
  @spec resolve_actor(String.t()) :: String.t()
  def resolve_actor(agent_id) do
    {:ok, pid} = Planck.Agent.whereis(agent_id)
    state = Planck.Agent.get_state(pid)
    "#{state.team_name}:#{state.name}"
  end

  @doc "The `ui:` payload every beads tool attaches on success, opening the shared board."
  @spec board_ui() :: Planck.Agent.Tool.ui_content()
  def board_ui, do: %{kind: :widget, label: "View kanban board", widget: "beads-board", data: nil}

  @doc """
  Append `issue["description"]` to `header` on its own line, when present
  and non-empty — otherwise `header` unchanged. Shared by `bd_ready` and
  `bd_get`, which each build a different header line (the fields worth
  showing differ) but decide whether to append the description identically.
  """
  @spec with_description(String.t(), map()) :: String.t()
  def with_description(header, issue) do
    case issue["description"] do
      description when is_binary(description) and description != "" ->
        "#{header}\n#{description}"

      _ ->
        header
    end
  end
end
