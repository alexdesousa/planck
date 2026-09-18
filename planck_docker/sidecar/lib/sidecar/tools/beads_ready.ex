defmodule Sidecar.Tools.BeadsReady do
  @moduledoc """
  Lists beads (shared tasks) with no open blockers — the LLM's entry point
  onto the shared task board. Read-only; workers opt in via `TEAM.json`.

  Calls `Sidecar.Beads.ready/1`, not `list/1` — a genuinely different
  endpoint restricted to `status=open` AND no unresolved blockers, matching
  `bd ready --json`. Attaches a `ui:` payload opening the board widget so
  the human can see the same data the model just read.
  """

  @doc "Returns the `bd_ready` tool definition."
  @spec tool() :: Planck.Agent.Tool.t()
  def tool do
    Planck.Agent.Tool.new(
      name: "bd_ready",
      description:
        "Use when you want to see what shared tasks (beads) are ready to work on — " <>
          "unblocked and not yet claimed.",
      parameters: %{"type" => "object", "properties" => %{}},
      execute_fn: fn _agent_id, _id, _args ->
        case Sidecar.Beads.ready() do
          {:ok, %{"items" => items}} ->
            {:ok, format_ready(items), %{ui: Sidecar.Tools.Beads.board_ui()}}

          {:error, reason} ->
            {:error, "Failed to list ready beads: #{inspect(reason)}"}
        end
      end,
      widget: Sidecar.Widgets.Beads
    )
  end

  @spec format_ready([map()]) :: String.t()
  defp format_ready([]), do: "No beads are ready right now."

  defp format_ready(items) do
    Enum.map_join(items, "\n\n", fn issue ->
      header =
        "#{issue["id"]}: #{issue["title"]} (#{issue["issue_type"]}, priority #{issue["priority"]})"

      # IssueWithCounts (the actual response element type) carries description
      # same as Issue does — surfaced here so an agent can judge fit before
      # claiming, not just from the title.
      Sidecar.Tools.Beads.with_description(header, issue)
    end)
  end
end
