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
        status: %Schema{
          type: :string,
          enum: ["idle", "streaming", "executing_tools"]
        }
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
          description:
            "Team alias or path. Pass \"dynamic\" for the built-in lone-orchestrator team. " <>
              "Omit for the default team (default_team config, else dynamic)."
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

  defmodule CancelQueued do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :object,
      properties: %{
        message_id: %Schema{
          type: :string,
          description:
            "The agent-side string id of the queued message to cancel. " <>
              "Only messages still unpersisted (not yet flushed to the session) can be cancelled."
        }
      },
      required: [:message_id],
      example: %{message_id: "a1b2c3d4e5f6g7h8"}
    })
  end

  defmodule ApprovalRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :object,
      properties: %{
        call_id: %Schema{type: :string},
        tool_name: %Schema{type: :string},
        args: %Schema{type: :object},
        reason: %Schema{type: :string}
      },
      required: [:call_id, :tool_name, :args, :reason],
      example: %{
        call_id: "t1",
        tool_name: "bash",
        args: %{"command" => "rm -rf _build"},
        reason: "destructive command"
      }
    })
  end

  defmodule ApprovalList do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :array,
      items: ApprovalRequest,
      example: [
        %{
          call_id: "t1",
          tool_name: "bash",
          args: %{"command" => "rm -rf _build"},
          reason: "destructive command"
        }
      ]
    })
  end

  defmodule ApproveToolCall do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :object,
      properties: %{
        call_id: %Schema{type: :string, description: "The tool call id to approve."}
      },
      required: [:call_id],
      example: %{call_id: "t1"}
    })
  end

  defmodule DenyToolCall do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :object,
      properties: %{
        call_id: %Schema{type: :string, description: "The tool call id to deny."},
        reason: %Schema{
          type: :string,
          nullable: true,
          description: "Optional reason shown to the model."
        }
      },
      required: [:call_id],
      example: %{call_id: "t1", reason: "not now"}
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
        type: %Schema{type: :string, enum: ["llm", "rlcd"]},
        context_window: %Schema{type: :integer},
        base_url: %Schema{type: :string, nullable: true}
      },
      required: [:provider, :id, :type, :context_window],
      example: %{
        provider: "openai",
        id: "qwen-3.8-flash-next",
        type: "llm",
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
        %{
          provider: "openai",
          id: "qwen-3.8-flash-next",
          type: "llm",
          context_window: 200_000,
          base_url: nil
        },
        %{
          provider: "typesafe",
          id: "jev-1.13",
          type: "rlcd",
          context_window: 200_000,
          base_url: nil
        }
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

    event: tool_blocked
    data: {"agent_id":"orch-id","id":"t1","name":"bash","args":{"command":"rm -rf _build"},"reason":"destructive command","mode":"await_approval"}

    event: tool_end
    data: {"agent_id":"orch-id","id":"t1","name":"read","result":"defmodule App do\\n...","error":false}

    event: turn_end
    data: {"agent_id":"orch-id"}
    """
  end
end
