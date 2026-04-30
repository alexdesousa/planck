defmodule Planck.Web.API.Schemas do
  @moduledoc "OpenAPI schema definitions for the Planck HTTP API."

  alias OpenApiSpex.Schema

  defmodule Error do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :object,
      properties: %{error: %Schema{type: :string}},
      required: [:error],
      example: %{error: "Session not found"}
    })
  end

  defmodule Ok do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :object,
      properties: %{ok: %Schema{type: :boolean}},
      required: [:ok],
      example: %{ok: true}
    })
  end

  defmodule Session do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        name: %Schema{type: :string},
        status: %Schema{type: :string, enum: ["active", "closed"]},
        team: %Schema{type: :string, nullable: true}
      },
      required: [:id, :name, :status],
      example: %{id: "a1b2c3d4", name: "liquid-kiwi", status: "active", team: "build-team"}
    })
  end

  defmodule SessionList do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :array,
      items: Session,
      example: [%{id: "a1b2c3d4", name: "liquid-kiwi", status: "active", team: "build-team"}]
    })
  end

  defmodule AgentInfo do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        name: %Schema{type: :string, nullable: true},
        type: %Schema{type: :string, nullable: true},
        status: %Schema{type: :string, enum: ["idle", "streaming", "executing_tools"]}
      },
      required: [:id, :status],
      example: %{id: "orch-id", name: "orchestrator", type: "orchestrator", status: "idle"}
    })
  end

  defmodule SessionDetail do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        name: %Schema{type: :string},
        status: %Schema{type: :string, enum: ["active", "closed"]},
        team: %Schema{type: :string, nullable: true},
        agents: %Schema{type: :array, items: AgentInfo}
      },
      required: [:id, :name, :status, :agents],
      example: %{
        id: "a1b2c3d4",
        name: "liquid-kiwi",
        status: "active",
        team: "build-team",
        agents: [
          %{id: "orch-id", name: "orchestrator", type: "orchestrator", status: "idle"},
          %{id: "work-id", name: "Builder", type: "builder", status: "streaming"}
        ]
      }
    })
  end

  defmodule CreateSession do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :object,
      properties: %{
        template: %Schema{
          type: :string,
          description: "Team alias or path. Omit for the default dynamic team."
        },
        name: %Schema{
          type: :string,
          description: "Session name. Auto-generated if omitted."
        }
      },
      example: %{template: "build-team", name: "my-session"}
    })
  end

  defmodule Prompt do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :object,
      properties: %{text: %Schema{type: :string, description: "The prompt text to send."}},
      required: [:text],
      example: %{text: "Refactor lib/app.ex to use a GenServer"}
    })
  end

  defmodule TeamSummary do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :object,
      properties: %{
        alias: %Schema{type: :string},
        name: %Schema{type: :string, nullable: true},
        description: %Schema{type: :string, nullable: true}
      },
      required: [:alias],
      example: %{
        alias: "build-team",
        name: "Build Team",
        description: "Plan and implement changes"
      }
    })
  end

  defmodule TeamList do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :array,
      items: TeamSummary,
      example: [%{alias: "build-team", name: "Build Team", description: nil}]
    })
  end

  defmodule TeamMember do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :object,
      properties: %{
        type: %Schema{type: :string},
        name: %Schema{type: :string, nullable: true},
        model_id: %Schema{type: :string, nullable: true}
      },
      required: [:type],
      example: %{type: "builder", name: "Builder", model_id: "claude-sonnet-4-5"}
    })
  end

  defmodule TeamDetail do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :object,
      properties: %{
        alias: %Schema{type: :string},
        name: %Schema{type: :string, nullable: true},
        members: %Schema{type: :array, items: TeamMember}
      },
      required: [:alias, :members],
      example: %{
        alias: "build-team",
        name: "Build Team",
        members: [
          %{type: "orchestrator", name: "orchestrator", model_id: "claude-sonnet-4-6"},
          %{type: "builder", name: "Builder", model_id: "claude-sonnet-4-5"}
        ]
      }
    })
  end

  defmodule ModelInfo do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :object,
      properties: %{
        provider: %Schema{type: :string},
        id: %Schema{type: :string},
        context_window: %Schema{type: :integer},
        base_url: %Schema{type: :string, nullable: true}
      },
      required: [:provider, :id, :context_window],
      example: %{
        provider: "anthropic",
        id: "claude-sonnet-4-6",
        context_window: 200_000,
        base_url: nil
      }
    })
  end

  defmodule ModelList do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :array,
      items: ModelInfo,
      example: [
        %{provider: "anthropic", id: "claude-sonnet-4-6", context_window: 200_000, base_url: nil}
      ]
    })
  end

  @doc "Example SSE frame sequence for documentation."
  @spec sse_example() :: String.t()
  def sse_example do
    """
    event: turn_start
    data: {"agent_id":"orch-id"}

    event: text_delta
    data: {"agent_id":"orch-id","text":"I'll start by reading the file."}

    event: tool_start
    data: {"agent_id":"orch-id","id":"t1","name":"read","args":{"path":"lib/app.ex"}}

    event: tool_end
    data: {"agent_id":"orch-id","id":"t1","name":"read","result":"defmodule App do\\n...","error":false}

    event: turn_end
    data: {"agent_id":"orch-id"}
    """
  end
end
