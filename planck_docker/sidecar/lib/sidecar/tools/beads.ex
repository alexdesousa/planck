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
  Resolve the calling agent's durable identity as a beads actor string, or
  `nil` when it can't be found. `agent_id` (`:crypto.strong_rand_bytes(8)`,
  regenerated every restart) isn't durable — `team_name`/`name` (straight
  from `TEAM.json`) are, so that's what gets recorded as the actor.

  `Planck.Agent.whereis/1` checks the connected `planck_headless` node too,
  not just this (sidecar) node's own `Registry` — needed here, since this
  code runs on the sidecar node while the calling agent's real process runs
  on `planck_headless`. Before `whereis/1` covered that, this crashed with
  a `{:badmatch, {:error, :not_found}}` the first time `bd_create` was
  actually run against a real connected sidecar, not just tested same-node.

  `nil`, not the bare `agent_id`, in the (should-be unreachable in practice)
  case the calling agent can't be found anywhere — a meaningless ephemeral
  hex string recorded as "who did this" in the beads audit trail would be
  actively misleading, not just imprecise. `require_actor/1` is what every
  mutating tool actually calls, turning `nil` into a real `{:error, ...}`
  before it ever reaches an API call.
  """
  @spec resolve_actor(String.t()) :: String.t() | nil
  def resolve_actor(agent_id) do
    case Planck.Agent.whereis(agent_id) do
      {:ok, pid} ->
        state = Planck.Agent.get_state(pid)
        "#{state.team_name}:#{state.name}"

      {:error, :not_found} ->
        nil
    end
  end

  @doc """
  `resolve_actor/1`, but fails the call outright instead of handing a
  mutating tool a `nil` actor to (mis)use. Every `bd_claim`/`bd_create`/
  `bd_delete`/`bd_done` call goes through this, not `resolve_actor/1`
  directly — an unresolvable identity should mean "this call fails, loudly",
  not "silently record `null`/some placeholder as who did this."
  """
  @spec require_actor(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def require_actor(agent_id) do
    case resolve_actor(agent_id) do
      nil -> {:error, "Could not resolve your identity — try the call again."}
      actor -> {:ok, actor}
    end
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
