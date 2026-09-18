defmodule Sidecar.Tools.BeadsList do
  @moduledoc """
  Lists every shared task (bead), grouped by status. Orchestrator-only —
  seeing the whole board (including what's already done) is an
  orchestration concern, not a per-worker one; a worker deciding what to
  pick up next wants `bd_ready` instead.

  Calls `Sidecar.Beads.list/1` with `all: true` — the default view that
  endpoint returns already excludes `closed` (and any custom done/frozen
  status), which is the one thing an overview must not do.
  """

  @status_order ["open", "in_progress", "blocked", "closed"]

  @doc """
  Returns the `bd_list` tool definition. `opts` is not part of the LLM-facing
  schema — it accepts `:client` (see `Sidecar.Beads`'s moduledoc) so a test
  can point this tool at a mock server without touching `Sidecar.Config`.
  """
  @spec tool(keyword()) :: Planck.Agent.Tool.t()
  def tool(opts \\ []) do
    Planck.Agent.Tool.new(
      name: "bd_list",
      description:
        "Use when you want an overview of every shared task (bead), grouped by status " <>
          "(open, in progress, blocked, closed) — to see what's done and what's still " <>
          "pending across the whole team, not just what's unblocked and ready to claim.",
      parameters: %{"type" => "object", "properties" => %{}},
      execute_fn: fn _agent_id, _id, _args ->
        list_opts = [all: true] ++ opts

        case Sidecar.Beads.list(list_opts) do
          {:ok, %{"items" => items}} ->
            {:ok, format_overview(items), %{ui: Sidecar.Tools.Beads.board_ui()}}

          {:error, reason} ->
            {:error, "Failed to list beads: #{inspect(reason)}"}
        end
      end
    )
  end

  @spec format_overview([map()]) :: String.t()
  defp format_overview([]), do: "No beads exist yet."

  defp format_overview(items) do
    by_status = Enum.group_by(items, & &1["status"])
    known = Enum.filter(@status_order, &Map.has_key?(by_status, &1))
    other = by_status |> Map.keys() |> Kernel.--(@status_order) |> Enum.sort()

    (known ++ other)
    |> Enum.map_join("\n\n", &format_group(&1, Map.fetch!(by_status, &1)))
  end

  @spec format_group(String.t(), [map()]) :: String.t()
  defp format_group(status, issues) do
    "#{status} (#{length(issues)}):\n" <> Enum.map_join(issues, "\n", &format_line/1)
  end

  @spec format_line(map()) :: String.t()
  defp format_line(issue) do
    assignee = if issue["assignee"], do: " [#{issue["assignee"]}]", else: ""
    "  #{issue["id"]}: #{issue["title"]}#{assignee}"
  end
end
