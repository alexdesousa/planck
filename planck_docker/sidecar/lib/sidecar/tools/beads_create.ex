defmodule Sidecar.Tools.BeadsCreate do
  @moduledoc """
  Creates a new bead (shared task). Orchestrator-only — deciding what work
  exists for the team is an orchestration decision, not something every
  worker should be able to do unilaterally.

  Takes an optional `description` and `priority` alongside `title` — useful
  for a model deciding what to work on next, not just a human. The widget's
  own human-facing create form only collects a title, unlike this tool —
  see `Sidecar.Widgets.Beads`'s moduledoc for why that's an intentional gap
  in this pass, not an oversight.
  """

  @doc """
  Returns the `bd_create` tool definition. `opts` is not part of the LLM-facing
  schema — it accepts `:client` (see `Sidecar.Beads`'s moduledoc) so a test
  can point this tool at a mock server without touching `Sidecar.Config`,
  and `:instance` for the same reason (see `Sidecar.Beads.broadcast_refresh/1`).
  Both are forwarded to `broadcast_refresh/1` too, so an injected client
  reaches the board's own re-fetch, not just this tool's own create request.
  """
  @spec tool(keyword()) :: Planck.Agent.Tool.t()
  def tool(opts \\ []) do
    Planck.Agent.Tool.new(
      name: "bd_create",
      description:
        "Use when new work needs to be tracked as a shared task (bead) for the team, " <>
          "given a title.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "title" => %{"type" => "string", "description" => "Short, descriptive task title."},
          "description" => %{
            "type" => "string",
            "description" =>
              "Full details a worker picking this up would need — context, scope, " <>
                "acceptance criteria. Omit only for genuinely self-explanatory tasks."
          },
          "priority" => %{
            "type" => "integer",
            "minimum" => 0,
            "maximum" => 4,
            "description" => "0 = P0/critical, 4 = lowest. Omit to use the workspace default."
          }
        },
        "required" => ["title"]
      },
      execute_fn: fn agent_id, _id, %{"title" => title} = args ->
        create_opts = [description: args["description"], priority: args["priority"]] ++ opts

        with {:ok, actor} <- Sidecar.Tools.Beads.require_actor(agent_id),
             {:ok, %{"id" => id}} <- Sidecar.Beads.create(title, actor, create_opts) do
          Sidecar.Beads.broadcast_refresh(opts)
          {:ok, "Created #{id}: #{title}", %{ui: Sidecar.Tools.Beads.board_ui()}}
        else
          {:error, reason} when is_binary(reason) ->
            {:error, reason}

          {:error, {status, body}} ->
            {:error, "Failed to create bead: HTTP #{status} #{inspect(body)}"}

          {:error, reason} ->
            {:error, "Failed to create bead: #{inspect(reason)}"}
        end
      end
    )
  end
end
