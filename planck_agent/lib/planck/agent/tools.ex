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
        Planck.Agent.Tools.orchestrator_tools(session_id, team_id, available_models) ++
          Planck.Agent.Tools.worker_tools(team_id, nil) ++
          [my_custom_tool]

  ## Tool descriptions

  | Tool | Role | Blocking |
  |---|---|---|
  | `call_agent` | all | yes (blocks task, not GenServer) |
  | `send_agent` | all | no |
  | `respond_agent` | all | no |
  | `list_team` | all | no |
  | `spawn_agent` | orchestrator only | no |
  | `destroy_agent` | orchestrator only | no |
  | `interrupt_agent` | orchestrator only | no |
  | `list_models` | orchestrator only | no |
  | `classify` | orchestrator only when there's a :rlcd model configured | no |
  """

  alias Planck.Agent
  alias Planck.Agent.{AIBehaviour, Skill, Tool}
  alias Planck.AI.Model

  @doc """
  Returns the inter-agent tools available to all agents in a team:
  `call_agent`, `send_agent`, `respond_agent`, `list_team`.

  `delegator_id` is the agent the worker should respond to (`nil` for orchestrators).

  Pass `delegator_id: nil` for orchestrators (they have no delegator to
  respond to). The optional `sender` map is captured in `respond_agent` so
  the orchestrator knows which worker replied.
  """
  @spec worker_tools(String.t(), String.t() | nil, map() | nil) :: [Tool.t()]
  def worker_tools(team_id, delegator_id, sender \\ nil) do
    [
      call_agent(team_id),
      send_agent(team_id),
      respond_agent(delegator_id, sender),
      list_team(team_id)
    ]
  end

  @doc """
  Returns the orchestrator-only tools: `spawn_agent`, `destroy_agent`,
  `interrupt_agent`, `list_models`, plus `classify` when at least one
  configured model has `type: :rlcd`.

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
          [Model.t()],
          [Tool.t()],
          [Skill.t()],
          String.t()
        ) :: [Tool.t()]
  def orchestrator_tools(
        session_id,
        team_id,
        available_models,
        grantable_tools \\ [],
        grantable_skills \\ [],
        cwd \\ ""
      ) do
    base = [
      spawn_agent(session_id, team_id, available_models, grantable_tools, grantable_skills, cwd),
      destroy_agent(team_id),
      interrupt_agent(team_id),
      list_models(available_models)
    ]

    if Enum.any?(available_models, &(&1.type == :rlcd)) do
      base ++ [classify(available_models)]
    else
      base
    end
  end

  # ---------------------------------------------------------------------------
  # All-agent tools
  # ---------------------------------------------------------------------------

  @doc "Build the `call_agent` tool for a given team."
  @spec call_agent(String.t()) :: Tool.t()
  def call_agent(team_id) do
    Tool.new(
      name: "call_agent",
      description:
        "Use when you need another agent's answer before you can continue. " <>
          "Sends the question and blocks until the target responds (sync, blocking). " <>
          "Pass reset_previous_context: true to archive the target's prior history and give it a clean slate.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "agent_id" => %{
            "type" => "string",
            "description" => "The agent's ID (from list_team)"
          },
          "question" => %{"type" => "string", "description" => "The question to ask"},
          "reset_previous_context" => %{
            "type" => "boolean",
            "description" =>
              "When true, archives the target agent's prior history before sending the question (default: false)"
          }
        },
        "required" => ["agent_id", "question"]
      },
      execute_fn: fn agent_id, _id, args ->
        with {:ok, pid} <- resolve_target(team_id, args) do
          question = args["question"]
          target_id = Agent.get_info(pid).id

          cond do
            target_id == agent_id ->
              {:error, "Cannot ask yourself. Use a different agent."}

            circular_wait?(agent_id, target_id) ->
              {:error,
               "Deadlock detected: #{agent_id} cannot ask #{target_id} — " <>
                 "a circular wait chain already exists. Use respond_agent or " <>
                 "send_agent to communicate without blocking."}

            true ->
              if Map.get(args, "reset_previous_context", false) do
                Agent.checkpoint(pid, "Starting new task.")
              end

              # Register this wait so others can detect a cycle back to us.
              # The Registry entry is automatically removed when this task exits.
              Registry.register(Planck.Agent.Registry, {:waiting, agent_id}, target_id)
              ref = Process.monitor(pid)
              Agent.subscribe(pid)
              :ok = Agent.prompt(pid, question)
              await_turn_end(ref)
          end
        end
      end
    )
  end

  @doc "Build the `send_agent` tool for a given team."
  @spec send_agent(String.t()) :: Tool.t()
  def send_agent(team_id) do
    Tool.new(
      name: "send_agent",
      description:
        "Use when another agent should handle work in the background (async, fire-and-forget). " <>
          "Returns immediately; result arrives in a future turn via respond_agent. " <>
          "Pass reset_previous_context: true to archive the target's prior history and give it a clean slate.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "agent_id" => %{
            "type" => "string",
            "description" => "The agent's ID (from list_team)"
          },
          "task" => %{"type" => "string", "description" => "The task to delegate"},
          "reset_previous_context" => %{
            "type" => "boolean",
            "description" =>
              "When true, archives the target agent's prior history before sending the task (default: false)"
          }
        },
        "required" => ["agent_id", "task"]
      },
      execute_fn: fn agent_id, _id, args ->
        with {:ok, pid} <- resolve_target(team_id, args) do
          if Agent.get_info(pid).id == agent_id do
            {:error, "Cannot send a task to yourself. Use a different agent."}
          else
            if Map.get(args, "reset_previous_context", false) do
              Agent.checkpoint(pid, "Starting new task.")
            end

            Agent.prompt(pid, args["task"])

            {:ok,
             "Task sent. End your turn now unless you can send something else in parallel that won't be blocked by this. The result will arrive in a future turn."}
          end
        end
      end
    )
  end

  @doc """
  Build the `respond_agent` tool for a given delegator.

  The optional `sender` map (`%{id: String.t(), name: String.t()}`) is included
  in the message delivered to the delegator so it knows which worker replied.
  """
  @spec respond_agent(String.t() | nil) :: Tool.t()
  @spec respond_agent(String.t() | nil, map() | nil) :: Tool.t()
  def respond_agent(delegator_id, sender \\ nil) do
    Tool.new(
      name: "respond_agent",
      description:
        "Use when you have finished a delegated task and must return your result. " <>
          "Non-blocking; re-triggers the delegator automatically.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "response" => %{"type" => "string", "description" => "The response to send back"}
        },
        "required" => ["response"]
      },
      execute_fn: fn _agent_id, _id, %{"response" => response} ->
        case delegator_id && Agent.whereis(delegator_id) do
          nil ->
            {:error, "No delegator to respond to."}

          {:error, :not_found} ->
            {:error, "No delegator to respond to."}

          {:ok, pid} ->
            send(pid, {:agent_response, response, sender})
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

  `available_models` is the same list `list_models/1` is built from — a
  `model_id` matching one of these by `provider`/`id` resolves directly against
  it, exactly what `list_models`'s own tool description tells the LLM to pass.
  Only a `model_id` that isn't found there falls back to live/catalog
  resolution (see `resolve_spawn_model/4`).

  `grantable_tools` is the set of built-in tools the orchestrator may delegate.
  `grantable_skills` is the set of skills the orchestrator may attach to spawned
  workers — their descriptions are appended to the spawned agent's system prompt.
  Spawned agents always receive the full worker inter-agent tools
  (`call_agent`, `send_agent`, `respond_agent`, `list_team`) plus whichever
  built-in tools the orchestrator selects via the `"tools"` argument.
  """
  @spec spawn_agent(
          String.t(),
          String.t(),
          [Model.t()],
          [Tool.t()],
          [Skill.t()],
          String.t()
        ) :: Tool.t()
  def spawn_agent(
        session_id,
        team_id,
        available_models,
        grantable_tools \\ [],
        grantable_skills \\ [],
        cwd \\ ""
      ) do
    grantable_tool_map = Map.new(grantable_tools, &{&1.name, &1})
    grantable_skill_map = Map.new(grantable_skills, &{&1.name, &1})
    available_tool_names = Enum.map_join(grantable_tools, ", ", & &1.name)
    available_skill_names = Enum.map_join(grantable_skills, ", ", & &1.name)

    tools_description =
      if available_tool_names == "",
        do: "No built-in tools available to grant.",
        else: "Available built-in tools to grant: #{available_tool_names}."

    skills_description =
      if available_skill_names == "",
        do: "No skills available to grant.",
        else: "Available skills to grant: #{available_skill_names}."

    Tool.new(
      name: "spawn_agent",
      description: """
      Create a new worker agent in the team. Returns the new agent's ID — save
      it to use with call_agent, send_agent, interrupt_agent, or destroy_agent.
      Multiple agents of the same type are allowed (e.g. two developers working
      on different features in parallel). #{tools_description} #{skills_description}
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
          "provider" => %{
            "type" => "string",
            "description" => "LLM provider",
            "enum" => ["anthropic", "openai", "google"]
          },
          "model_id" => %{
            "type" => "string",
            "description" =>
              "The id of an LLM model to use, from list_models — only a model " <>
                "with type \"llm\" is valid. Call list_models first if you don't " <>
                "already have one."
          },
          "base_url" => %{
            "type" => "string",
            "description" =>
              "Server URL for a self-hosted or compatible endpoint (e.g. " <>
                "\"http://localhost:11434\"), passed alongside \"provider\" — the same " <>
                "provider atom is reused for its compatible endpoints, distinguished only " <>
                "by base_url (e.g. an OpenAI-compatible llama.cpp/Ollama server is still " <>
                "\"openai\"). Ignored for a real cloud account — pass any placeholder value."
          },
          "tools" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Built-in tool names to grant (e.g. [\"read\", \"bash\"]). Unknown names are silently ignored."
          },
          "skills" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Skill names to attach; their descriptions are appended to the system prompt. Unknown names are silently ignored."
          }
        },
        "required" => [
          "type",
          "name",
          "description",
          "system_prompt",
          "provider",
          "model_id",
          "base_url"
        ]
      },
      execute_fn: fn agent_id, _id, args ->
        provider = String.to_existing_atom(args["provider"])
        base_url = Map.get(args, "base_url")
        granted_tools = filter_granted(Map.get(args, "tools", []), grantable_tool_map)
        granted_skills = filter_granted(Map.get(args, "skills", []), grantable_skill_map)

        ctx = %{
          session_id: session_id,
          team_id: team_id,
          orchestrator_id: agent_id,
          cwd: cwd
        }

        with {:ok, model} <-
               resolve_spawn_model(provider, args["model_id"], base_url, available_models) do
          agent_id = generate_id()

          start_opts =
            build_spawn_start_opts(args, agent_id, model, granted_tools, granted_skills, ctx)

          case DynamicSupervisor.start_child(
                 Planck.Agent.AgentSupervisor,
                 {Planck.Agent, start_opts}
               ) do
            {:ok, _pid} -> {:ok, agent_id}
            {:error, reason} -> {:error, "Failed to start agent: #{inspect(reason)}"}
          end
        end
      end
    )
  end

  @doc "Prepend `AGENTS.md` content (if found by walking up from `cwd`) to `system_prompt`."
  @spec prepend_agents_md(String.t() | nil, String.t()) :: String.t()
  def prepend_agents_md(system_prompt, cwd) when cwd != "" do
    case find_agents_md(Path.expand(cwd)) do
      nil -> system_prompt || ""
      content when system_prompt in [nil, ""] -> content
      content -> content <> "\n\n" <> system_prompt
    end
  end

  def prepend_agents_md(system_prompt, _cwd), do: system_prompt || ""

  @spec find_agents_md(Path.t()) :: String.t() | nil
  defp find_agents_md(dir) do
    path = Path.join(dir, "AGENTS.md")
    parent = Path.dirname(dir)

    cond do
      File.exists?(path) -> File.read!(path)
      File.dir?(Path.join(dir, ".git")) -> nil
      dir == parent -> nil
      true -> find_agents_md(parent)
    end
  end

  @spec build_system_prompt(String.t(), [Skill.t()]) :: String.t()
  defp build_system_prompt(base, []), do: base

  defp build_system_prompt(base, skills) do
    # Dynamic agents: orchestrator explicitly granted these skills — show all of them.
    names = Enum.map(skills, & &1.name)

    case Skill.system_prompt_section(skills, names, length(skills)) do
      nil -> base
      section -> base <> "\n\n" <> section
    end
  end

  @doc "Build the `destroy_agent` tool for a given team."
  @spec destroy_agent(String.t()) :: Tool.t()
  def destroy_agent(team_id) do
    Tool.new(
      name: "destroy_agent",
      description: "Use when a worker is no longer needed. Permanently removes it from the team.",
      parameters: target_parameters(),
      execute_fn: fn _agent_id, _id, args ->
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
      description:
        "Use when a worker should stop what it is doing but remain alive. " <>
          "Aborts the current turn and returns the worker to idle.",
      parameters: target_parameters(),
      execute_fn: fn _agent_id, _id, args ->
        with {:ok, pid} <- resolve_target(team_id, args) do
          Agent.abort(pid)
          {:ok, "Agent interrupted."}
        end
      end
    )
  end

  @doc "Build the `list_models` tool from a pre-filtered list of available models."
  @spec list_models([Model.t()]) :: Tool.t()
  def list_models(available_models) do
    Tool.new(
      name: "list_models",
      description:
        "List the configured and connected LLM models available for spawning agents. " <>
          "Use the returned provider, id, and base_url when calling spawn_agent.",
      parameters: %{"type" => "object", "properties" => %{}},
      execute_fn: fn agent_id, _id, _args ->
        current_model_id =
          case Agent.whereis(agent_id) do
            {:ok, pid} -> Agent.get_state(pid).model.id
            _ -> nil
          end

        models =
          Enum.map(available_models, fn m ->
            %{
              provider: m.provider,
              id: m.id,
              model: m.model,
              name: m.name,
              type: m.type,
              context_window: m.context_window,
              base_url: m.base_url,
              current: m.id == current_model_id
            }
          end)

        {:ok, Jason.encode!(models)}
      end
    )
  end

  @doc """
  Build the `classify` tool from a pre-filtered list of available models.

  Automatic for the orchestrator when at least one available model has
  `type: :rlcd` — see `orchestrator_tools/6`. Not automatic for workers:
  a worker only gets it if granted like any other tool, via `TEAM.json`'s
  `tools` list or `spawn_agent`'s `tools:` param.
  """
  @spec classify([Model.t()]) :: Tool.t()
  def classify(available_models) do
    Tool.new(
      name: "classify",
      description:
        "Use to get a fast, calibrated decision (routing, extraction, " <>
          "yes/no confidence) from an RLCD model instead of asking a general " <>
          "model to reason it out in text. Call list_models first and pass " <>
          "the id of a model with type \"rlcd\".",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "provider" => %{
            "type" => "string",
            "description" => "RLCD provider",
            "enum" => ["typesafe"]
          },
          "model_id" => %{
            "type" => "string",
            "description" =>
              "The id of an RLCD model to use, from list_models — only a model " <>
                "with type \"rlcd\" is valid. Call list_models first if you don't " <>
                "already have one."
          },
          "base_url" => %{
            "type" => "string",
            "description" =>
              "Server URL for a self-hosted or Typesafe-compatible endpoint (e.g. " <>
                "\"http://localhost:8000\"), passed alongside \"provider\" — still " <>
                "\"typesafe\", distinguished only by base_url. Ignored for a real " <>
                "cloud account — pass any placeholder value."
          },
          "state" => %{
            "description" =>
              "The content to evaluate — plain text, or a JSON object/array for " <>
                "structured data such as a chat log or a record."
          },
          "questions" => %{
            "type" => "object",
            "description" =>
              "Named typed questions to ask about state. Choose your own key " <>
                "for each question — its answer comes back under the same key.",
            "additionalProperties" => %{
              "oneOf" => [
                %{
                  "properties" => %{
                    "type" => %{
                      "enum" => ["choice"],
                      "description" => "Pick exactly one option from criteria."
                    },
                    "instructions" => %{
                      "type" => "string",
                      "description" =>
                        "What the model should decide between the given criteria options."
                    },
                    "criteria" => %{
                      "type" => "object",
                      "description" => "Option key -> description. Up to 255 options."
                    }
                  },
                  "required" => ["type", "instructions", "criteria"]
                },
                %{
                  "properties" => %{
                    "type" => %{
                      "enum" => ["score"],
                      "description" => "Rate state against the ordered levels in criteria."
                    },
                    "instructions" => %{
                      "type" => "string",
                      "description" => "What the model should rate, in natural language."
                    },
                    "criteria" => %{
                      "type" => "array",
                      "items" => %{"type" => "string"},
                      "minItems" => 2,
                      "maxItems" => 10,
                      "description" => "Ordered level descriptions, low to high."
                    }
                  },
                  "required" => ["type", "instructions", "criteria"]
                },
                %{
                  "properties" => %{
                    "type" => %{
                      "enum" => ["boolean"],
                      "description" =>
                        "A yes/no question — returns the probability the answer is yes."
                    },
                    "instructions" => %{
                      "type" => "string",
                      "description" => "The yes/no question to evaluate, in natural language."
                    },
                    "criteria" => %{
                      "type" => "object",
                      "properties" => %{
                        "true" => %{"type" => "string"},
                        "false" => %{"type" => "string"}
                      },
                      "description" => "Optional — clarifies what counts as yes/no."
                    }
                  },
                  "required" => ["type", "instructions"]
                }
              ]
            }
          }
        },
        "required" => ["provider", "model_id", "base_url", "state", "questions"]
      },
      execute_fn: fn _agent_id, _id, args ->
        provider = String.to_existing_atom(args["provider"])
        model_id = Map.get(args, "model_id")
        base_url = Map.get(args, "base_url")

        state = Map.get(args, "state")
        questions = Map.get(args, "questions")

        with {:ok, model} <-
               resolve_classify_model(provider, model_id, base_url, available_models),
             {:ok, response} <-
               AIBehaviour.client().evaluate(model, state, questions, []) do
          {:ok, Jason.encode!(response.object)}
        end
      end
    )
  end

  @doc """
  Build the `list_team` tool for a given team.

  Without arguments (or `verbose: false`) returns name, type, description, and
  status for each member — cheap and safe to call frequently.

  With `verbose: true` also includes the agent's tool names and model, useful
  when reasoning about which worker to delegate a task to.
  """
  @spec list_team(String.t()) :: Tool.t()
  def list_team(team_id) do
    Tool.new(
      name: "list_team",
      description:
        "List all agents in the team. Returns each agent's id, type, name, and status. " <>
          "Use the id field when calling call_agent, send_agent, interrupt_agent, or destroy_agent. " <>
          "Pass verbose: true to also include each agent's tools and model.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "verbose" => %{
            "type" => "boolean",
            "description" =>
              "When true, include tool names and model for each agent (default: false)"
          }
        }
      },
      execute_fn: fn _agent_id, _id, args ->
        verbose = Map.get(args, "verbose", false)

        members =
          Registry.lookup(Planck.Agent.Registry, {team_id, :member})
          |> Enum.map(fn {pid, meta} ->
            info =
              try do
                Agent.get_info(pid)
              catch
                _, _ -> %{status: :unknown, turn_index: nil, usage: nil}
              end

            base = Map.merge(meta, Map.take(info, [:status, :turn_index, :usage]))

            if verbose do
              state =
                try do
                  Agent.get_state(pid)
                catch
                  _, _ -> nil
                end

              extra =
                if state do
                  %{
                    tools: state.tools |> Map.keys() |> Enum.sort(),
                    model: state.model && (state.model.name || state.model.id)
                  }
                else
                  %{}
                end

              Map.merge(base, extra)
            else
              base
            end
          end)

        {:ok, Jason.encode!(members)}
      end
    )
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec resolve_target(String.t(), map()) :: {:ok, pid()} | {:error, String.t()}
  defp resolve_target(_team_id, %{"agent_id" => id}) when is_binary(id) and id != "" do
    with {:error, :not_found} <- Agent.whereis(id) do
      {:error, "Agent not found. Call list_team to get the current agent IDs."}
    end
  end

  defp resolve_target(_team_id, _args) do
    {:error, "Missing required parameter: agent_id. Call list_team to get agent IDs."}
  end

  @spec filter_granted([String.t()], %{String.t() => term()}) :: [term()]
  defp filter_granted(names, pool_map) do
    Enum.flat_map(names, &List.wrap(Map.get(pool_map, &1)))
  end

  @spec resolve_classify_model(atom(), String.t(), String.t() | nil, [Model.t()]) ::
          {:ok, Model.t(:rlcd)}
          | {:error, String.t()}
  defp resolve_classify_model(provider, model_id, base_url, available_models)

  defp resolve_classify_model(provider, model_id, base_url, available_models)
       when is_atom(provider) and is_binary(model_id) do
    with {:error, _} <- find_model(provider, model_id, available_models, :rlcd) do
      find_model_live(provider, model_id, base_url, :rlcd)
    end
  end

  @spec resolve_spawn_model(atom(), String.t(), String.t() | nil, [Model.t()]) ::
          {:ok, Model.t(:llm)}
          | {:error, String.t()}
  defp resolve_spawn_model(provider, model_id, base_url, available_models)

  defp resolve_spawn_model(provider, model_id, base_url, available_models)
       when is_atom(provider) and is_binary(model_id) do
    with {:error, _} <- find_model(provider, model_id, available_models, :llm) do
      find_model_live(provider, model_id, base_url, :llm)
    end
  end

  @spec find_model(atom(), String.t(), [Planck.AI.Model.t()], Model.model_type()) ::
          {:ok, Model.t()}
          | {:error, String.t()}
  defp find_model(provider, model_id, available_models, type)

  defp find_model(provider, model_id, available_models, type)
       when is_atom(provider) and is_binary(model_id) and type in [:llm, :rlcd] do
    condition =
      &(&1.provider == provider and
          &1.id == model_id and
          &1.type == type)

    case Enum.find(available_models, condition) do
      %Model{type: ^type} = model ->
        {:ok, model}

      _ ->
        {:error, "No #{type} model configured with id #{model_id} from #{provider}."}
    end
  end

  @spec find_model_live(atom(), String.t(), nil | String.t(), Model.model_type()) ::
          {:ok, Model.t()}
          | {:error, String.t()}
  defp find_model_live(provider, model_id, base_url, type)

  defp find_model_live(provider, model_id, base_url, type)
       when is_binary(model_id) and
              is_binary(base_url) and
              base_url != "" and
              type in [:llm, :rlcd] do
    provider
    |> AIBehaviour.client().get_model(model_id, base_url: base_url)
    |> case do
      {:ok, %Model{type: ^type}} = found ->
        found

      {:ok, %Model{type: _}} ->
        reason = "Model \"#{model_id}\" from #{provider} is not of type #{inspect(type)}."
        {:error, reason}

      {:error, :not_found} ->
        reason =
          "Model #{model_id} not found at #{base_url}. " <>
            "Call list_models to see available #{provider} models and verify the base_url."

        {:error, reason}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}
    end
  end

  defp find_model_live(provider, model_id, _base_url, type)
       when is_binary(model_id) and type in [:llm, :rlcd] do
    provider
    |> AIBehaviour.client().get_model(model_id)
    |> case do
      {:ok, %Model{type: ^type}} = found ->
        found

      {:ok, %Model{type: _}} ->
        reason = "Model \"#{model_id}\" from #{provider} is not of type #{inspect(type)}."
        {:error, reason}

      {:error, :not_found} ->
        reason =
          "Model #{model_id} not found. " <>
            "Call list_models to see available #{provider} models and verify the base_url."

        {:error, reason}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}
    end
  end

  @spec build_spawn_start_opts(
          map(),
          String.t(),
          Planck.AI.Model.t(),
          [Tool.t()],
          [Skill.t()],
          map()
        ) ::
          keyword()
  defp build_spawn_start_opts(args, agent_id, model, granted_tools, granted_skills, ctx) do
    %{session_id: session_id, team_id: team_id, orchestrator_id: orchestrator_id, cwd: cwd} = ctx
    sender = %{id: agent_id, name: args["name"]}

    system_prompt =
      args["system_prompt"]
      |> prepend_agents_md(cwd)
      |> build_system_prompt(granted_skills)

    [
      id: agent_id,
      type: args["type"],
      name: args["name"],
      description: args["description"],
      model: model,
      cwd: cwd,
      system_prompt: system_prompt,
      session_id: session_id,
      team_id: team_id,
      delegator_id: orchestrator_id,
      tools: worker_tools(team_id, orchestrator_id, sender) ++ granted_tools
    ]
  end

  @spec target_parameters() :: map()
  defp target_parameters do
    %{
      "type" => "object",
      "properties" => %{
        "agent_id" => %{
          "type" => "string",
          "description" => "The agent's ID (from list_team)"
        }
      },
      "required" => ["agent_id"]
    }
  end

  @spec await_turn_end(reference()) :: {:ok, String.t()} | {:error, String.t()}
  defp await_turn_end(monitor_ref) do
    receive do
      {:agent_event, :turn_end, %{message: msg}} ->
        Process.demonitor(monitor_ref, [:flush])

        text =
          Enum.reduce(msg.content, "", fn
            {:text, t}, acc -> acc <> t
            _, acc -> acc
          end)

        {:ok, text}

      {:agent_event, :error, %{reason: reason}} when is_binary(reason) ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, reason}

      {:agent_event, :error, %{reason: reason}} ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, inspect(reason)}

      {:DOWN, ^monitor_ref, :process, _pid, reason} ->
        {:error, "Agent terminated: #{inspect(reason)}"}
    end
  end

  # Returns true if `target_id` is (transitively) waiting for `from_id`,
  # which would create a deadlock if `from_id` were to wait for `target_id`.
  @spec circular_wait?(String.t(), String.t()) :: boolean()
  defp circular_wait?(from_id, target_id) do
    do_circular_check(from_id, target_id, [])
  end

  @spec do_circular_check(String.t(), String.t(), [String.t()]) :: boolean()
  defp do_circular_check(from_id, current_id, visited) do
    cond do
      current_id == from_id ->
        true

      current_id in visited ->
        false

      true ->
        case Registry.lookup(Planck.Agent.Registry, {:waiting, current_id}) do
          [{_pid, next_id} | _] ->
            do_circular_check(from_id, next_id, [current_id | visited])

          [] ->
            false
        end
    end
  end

  @spec generate_id() :: String.t()
  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
