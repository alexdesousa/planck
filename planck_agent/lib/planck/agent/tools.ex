defmodule Planck.Agent.Tools do
  @moduledoc """
  Factory functions for built-in inter-agent tools.

  These tools are closures that capture the agent's runtime context (team_id,
  delegator_id, available_models) at start time. They are assembled by the
  caller when starting an agent and passed in the `tools:` list.

  ## Usage

  For a worker in a team:

      tools = Planck.Agent.Tools.worker_tools(team_id, delegator_id) ++ [my_custom_tool]

  For an orchestrator:

      tools =
        Planck.Agent.Tools.orchestrator_tools(team_id, available_models) ++
        Planck.Agent.Tools.worker_tools(team_id, nil) ++
        [my_custom_tool]

  ## Tool descriptions

  | Tool | Role | Blocking |
  |---|---|---|
  | `ask_agent` | all | yes (blocks task, not GenServer) |
  | `delegate_task` | all | no |
  | `send_response` | all | no |
  | `list_team` | all | no |
  | `spawn_agent` | orchestrator only | no |
  | `destroy_agent` | orchestrator only | no |
  | `interrupt_agent` | orchestrator only | no |
  | `list_models` | orchestrator only | no |
  """

  alias Planck.Agent
  alias Planck.Agent.Tool

  @doc """
  Returns the three inter-agent tools available to all agents in a team:
  `ask_agent`, `delegate_task`, `send_response`.

  Pass `delegator_id: nil` for orchestrators (they have no delegator to respond to).
  """
  @spec worker_tools(String.t(), String.t() | nil) :: [Tool.t()]
  def worker_tools(team_id, delegator_id) do
    [ask_agent(team_id), delegate_task(team_id), send_response(delegator_id), list_team(team_id)]
  end

  @doc """
  Returns the four orchestrator-only tools:
  `spawn_agent`, `destroy_agent`, `interrupt_agent`, `list_models`.

  These tools, combined with `worker_tools/2`, make up the full orchestrator set.
  The presence of `spawn_agent` in the tool list is what marks an agent as an
  orchestrator — `Planck.Agent` derives `role: :orchestrator` from it.

  `grantable_tools` is the list of built-in tools the orchestrator may delegate
  to spawned agents — typically the same built-in tools the orchestrator itself
  holds. Spawned agents may only receive a subset of these.
  """
  @spec orchestrator_tools(
          String.t(),
          String.t(),
          String.t(),
          [Planck.AI.Model.t()],
          [Tool.t()]
        ) :: [Tool.t()]
  def orchestrator_tools(
        session_id,
        team_id,
        orchestrator_id,
        available_models,
        grantable_tools \\ []
      ) do
    [
      spawn_agent(session_id, team_id, orchestrator_id, grantable_tools),
      destroy_agent(team_id),
      interrupt_agent(team_id),
      list_models(available_models)
    ]
  end

  # ---------------------------------------------------------------------------
  # All-agent tools
  # ---------------------------------------------------------------------------

  @doc "Build the `ask_agent` tool for a given team."
  @spec ask_agent(String.t()) :: Tool.t()
  def ask_agent(team_id) do
    Tool.new(
      name: "ask_agent",
      description: """
      Ask a question to another agent in the team and wait for its answer.
      Blocks until the target agent finishes its turn. Use for questions that
      require an answer before continuing.
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "type" => %{"type" => "string", "description" => "Agent type to ask"},
          "name" => %{"type" => "string", "description" => "Agent name to ask"},
          "id" => %{"type" => "string", "description" => "Agent id to ask"},
          "question" => %{"type" => "string", "description" => "The question to ask"},
          "timeout_ms" => %{
            "type" => "integer",
            "description" => "Max milliseconds to wait for a response (default 300000)"
          }
        },
        "required" => ["question"]
      },
      execute_fn: fn _id, args ->
        question = args["question"]
        timeout = Map.get(args, "timeout_ms", 300_000)

        with {:ok, pid} <- resolve_target(team_id, args),
             :ok <- Agent.prompt(pid, question) do
          await_turn_end(pid, timeout)
        end
      end
    )
  end

  @doc "Build the `delegate_task` tool for a given team."
  @spec delegate_task(String.t()) :: Tool.t()
  def delegate_task(team_id) do
    Tool.new(
      name: "delegate_task",
      description: """
      Delegate a task to another agent in the team. Returns immediately — the
      target agent runs the task asynchronously and calls send_response when done.
      Fails if no matching agent exists in the team.
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "type" => %{"type" => "string", "description" => "Agent type to delegate to"},
          "name" => %{"type" => "string", "description" => "Agent name to delegate to"},
          "id" => %{"type" => "string", "description" => "Agent id to delegate to"},
          "task" => %{"type" => "string", "description" => "The task to delegate"}
        },
        "required" => ["task"]
      },
      execute_fn: fn _id, args ->
        task = args["task"]

        with {:ok, pid} <- resolve_target(team_id, args) do
          Agent.prompt(pid, task)
          {:ok, "Task delegated."}
        end
      end
    )
  end

  @doc "Build the `send_response` tool for a given delegator."
  @spec send_response(String.t() | nil) :: Tool.t()
  def send_response(delegator_id) do
    Tool.new(
      name: "send_response",
      description: """
      Send a result back to the agent that delegated the current task.
      Non-blocking. Re-triggers the delegator if it is idle, or injects the
      response as context if it is currently active.
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "response" => %{"type" => "string", "description" => "The response to send back"}
        },
        "required" => ["response"]
      },
      execute_fn: fn _id, %{"response" => response} ->
        case delegator_id && Agent.whereis(delegator_id) do
          nil ->
            {:error, "No delegator to respond to."}

          {:error, :not_found} ->
            {:error, "No delegator to respond to."}

          {:ok, pid} ->
            send(pid, {:agent_response, response})
            {:ok, "Response sent."}
        end
      end
    )
  end

  # ---------------------------------------------------------------------------
  # Orchestrator-only tools
  # ---------------------------------------------------------------------------

  @doc """
  Build the `spawn_agent` tool for a given team.

  `grantable_tools` is the set of built-in tools the orchestrator may delegate.
  Spawned agents always receive the full worker inter-agent tools
  (`ask_agent`, `delegate_task`, `send_response`, `list_team`) plus whichever
  built-in tools the orchestrator selects via the `"tools"` argument.
  """
  @spec spawn_agent(String.t(), String.t(), String.t(), [Tool.t()]) :: Tool.t()
  def spawn_agent(session_id, team_id, orchestrator_id, grantable_tools \\ []) do
    grantable_map = Map.new(grantable_tools, &{&1.name, &1})
    available_names = Enum.map_join(grantable_tools, ", ", & &1.name)

    tools_description =
      if available_names == "",
        do: "No built-in tools available to grant.",
        else: "Available built-in tools to grant: #{available_names}."

    Tool.new(
      name: "spawn_agent",
      description: """
      Create a new worker agent in the team. The worker is registered in the
      team and can be addressed by type or name. Fails if an agent of the same
      type already exists. #{tools_description}
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "type" => %{"type" => "string", "description" => "Role type for the new agent"},
          "name" => %{"type" => "string", "description" => "Human-readable name"},
          "description" => %{
            "type" => "string",
            "description" => "One-line purpose shown to other agents via list_team"
          },
          "system_prompt" => %{"type" => "string", "description" => "System prompt"},
          "provider" => %{"type" => "string", "description" => "LLM provider (e.g. anthropic)"},
          "model_id" => %{
            "type" => "string",
            "description" => "Model id (e.g. claude-sonnet-4-6)"
          },
          "tools" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Built-in tool names to grant (e.g. [\"read\", \"bash\"]). Unknown names are silently ignored."
          }
        },
        "required" => ["type", "name", "description", "system_prompt", "provider", "model_id"]
      },
      execute_fn: fn _id, args ->
        try do
          type = args["type"]
          provider = String.to_existing_atom(args["provider"])
          requested = Map.get(args, "tools", [])
          granted = Enum.flat_map(requested, &List.wrap(Map.get(grantable_map, &1)))

          with {:ok, model} <-
                 Planck.Agent.AIBehaviour.client().get_model(provider, args["model_id"]),
               :ok <- ensure_type_available(team_id, type) do
            agent_id = generate_id()

            start_opts = [
              id: agent_id,
              type: type,
              name: args["name"],
              description: args["description"],
              model: model,
              system_prompt: args["system_prompt"],
              session_id: session_id,
              team_id: team_id,
              delegator_id: orchestrator_id,
              tools: worker_tools(team_id, orchestrator_id) ++ granted
            ]

            case DynamicSupervisor.start_child(
                   Planck.Agent.AgentSupervisor,
                   {Planck.Agent, start_opts}
                 ) do
              {:ok, _pid} -> {:ok, agent_id}
              {:error, reason} -> {:error, "Failed to start agent: #{inspect(reason)}"}
            end
          else
            {:error, :not_found} -> {:error, "Model not found."}
            {:error, reason} when is_binary(reason) -> {:error, reason}
          end
        rescue
          ArgumentError -> {:error, "Unknown provider: #{args["provider"]}."}
        end
      end
    )
  end

  @doc "Build the `destroy_agent` tool for a given team."
  @spec destroy_agent(String.t()) :: Tool.t()
  def destroy_agent(team_id) do
    Tool.new(
      name: "destroy_agent",
      description: "Permanently terminate a worker in the team.",
      parameters: target_parameters(),
      execute_fn: fn _id, args ->
        with {:ok, pid} <- resolve_target(team_id, args) do
          Agent.stop(pid)
          {:ok, "Agent destroyed."}
        end
      end
    )
  end

  @doc "Build the `interrupt_agent` tool for a given team."
  @spec interrupt_agent(String.t()) :: Tool.t()
  def interrupt_agent(team_id) do
    Tool.new(
      name: "interrupt_agent",
      description: """
      Abort a worker's current turn and return it to idle. The worker stays
      alive — use destroy_agent to terminate permanently.
      """,
      parameters: target_parameters(),
      execute_fn: fn _id, args ->
        with {:ok, pid} <- resolve_target(team_id, args) do
          Agent.abort(pid)
          {:ok, "Agent interrupted."}
        end
      end
    )
  end

  @doc "Build the `list_models` tool from a pre-filtered list of available models."
  @spec list_models([Planck.AI.Model.t()]) :: Tool.t()
  def list_models(available_models) do
    Tool.new(
      name: "list_models",
      description: "List the available LLM models that can be used when spawning agents.",
      parameters: %{"type" => "object", "properties" => %{}},
      execute_fn: fn _id, _args ->
        models =
          Enum.map(available_models, fn m ->
            %{provider: m.provider, id: m.id, name: m.name, context_window: m.context_window}
          end)

        {:ok, Jason.encode!(models)}
      end
    )
  end

  @doc "Build the `list_team` tool for a given team."
  @spec list_team(String.t()) :: Tool.t()
  def list_team(team_id) do
    Tool.new(
      name: "list_team",
      description:
        "List all agents currently in the team with their type, name, description, and status.",
      parameters: %{"type" => "object", "properties" => %{}},
      execute_fn: fn _id, _args ->
        members =
          Registry.lookup(Planck.Agent.Registry, {team_id, :member})
          |> Enum.map(fn {pid, meta} ->
            info =
              try do
                Agent.get_info(pid)
              catch
                _, _ -> %{status: :unknown, turn_index: nil, usage: nil}
              end

            Map.merge(meta, Map.take(info, [:status, :turn_index, :usage]))
          end)

        {:ok, Jason.encode!(members)}
      end
    )
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec resolve_target(String.t(), map()) ::
          {:ok, pid()}
          | {:error, String.t()}
  defp resolve_target(team_id, params)

  defp resolve_target(_team_id, %{"id" => id}) when is_binary(id) and id != "" do
    with {:error, :not_found} <- Agent.whereis(id) do
      {:error, "Agent not found."}
    end
  end

  defp resolve_target(team_id, %{"name" => name}) when is_binary(name) and name != "" do
    lookup_team(team_id, name)
  end

  defp resolve_target(team_id, %{"type" => type}) when is_binary(type) and type != "" do
    lookup_team(team_id, type)
  end

  defp resolve_target(_team_id, _args) do
    {:error, "Agent not found."}
  end

  @spec lookup_team(String.t(), String.t()) ::
          {:ok, pid()}
          | {:error, String.t()}
  defp lookup_team(team_id, key)

  defp lookup_team(team_id, key) do
    case Registry.lookup(Planck.Agent.Registry, {team_id, key}) do
      [{pid, _} | _] -> {:ok, pid}
      _ -> {:error, "Agent not found."}
    end
  end

  @spec ensure_type_available(String.t(), String.t()) :: :ok | {:error, String.t()}
  defp ensure_type_available(team_id, type)

  defp ensure_type_available(team_id, type) do
    case Registry.lookup(Planck.Agent.Registry, {team_id, type}) do
      [] -> :ok
      _ -> {:error, "An agent of this type already exists in the team."}
    end
  end

  @spec target_parameters() :: map()
  defp target_parameters do
    %{
      "type" => "object",
      "properties" => %{
        "type" => %{"type" => "string", "description" => "Agent type"},
        "name" => %{"type" => "string", "description" => "Agent name"},
        "id" => %{"type" => "string", "description" => "Agent id"}
      }
    }
  end

  @spec await_turn_end(pid(), pos_integer()) ::
          {:ok, String.t()}
          | {:error, String.t()}
  defp await_turn_end(pid, timeout)

  defp await_turn_end(pid, timeout) do
    Agent.subscribe(pid)

    receive do
      {:agent_event, :turn_end, %{message: msg}} ->
        text =
          Enum.reduce(msg.content, "", fn
            {:text, t}, acc -> acc <> t
            _, acc -> acc
          end)

        {:ok, text}

      {:agent_event, :error, %{reason: reason}} when is_binary(reason) ->
        {:error, reason}

      {:agent_event, :error, %{reason: reason}} ->
        {:error, inspect(reason)}
    after
      timeout -> {:error, "Agent timed out."}
    end
  end

  @spec generate_id() :: String.t()
  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
