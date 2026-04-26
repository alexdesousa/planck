defmodule Planck.Headless do
  @moduledoc """
  The headless core of the Planck coding agent.

  `planck_headless` owns configuration, loads resources at startup (tools,
  skills, teams, compactor), and manages session lifecycles. UIs depend on
  this module; they are rendering surfaces only and never call `planck_agent`
  directly.

  See `specs/planck-headless.md` for the full design.
  """

  require Logger

  alias Planck.Agent
  alias Planck.Agent.{AgentSpec, BuiltinTools, Compactor, Session, Team, Tools}
  alias Planck.Headless.{Config, DefaultPrompt, ResourceStore, SessionName, SidecarManager}

  @type session_id :: String.t()

  # ---------------------------------------------------------------------------
  # Config
  # ---------------------------------------------------------------------------

  @doc "Return the resolved configuration."
  @spec config() :: Config.t()
  def config, do: Config.get()

  # ---------------------------------------------------------------------------
  # Sessions
  # ---------------------------------------------------------------------------

  @doc """
  Start a new session. Returns `{:ok, session_id}`.

  ## Options

  - `template:` — team alias, path to a TEAM.json directory, or `nil` for the
    default dynamic team (lone orchestrator built from config defaults).
  - `name:` — session name; auto-generated as `<adjective>-<noun>` if absent.
  - `cwd:` — working directory for the session (default: `File.cwd!()`).
  """
  @spec start_session(keyword()) :: {:ok, session_id()} | {:error, term()}
  def start_session(opts \\ []) do
    template = Keyword.get(opts, :template)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    user_name = Keyword.get(opts, :name)

    with {:ok, team} <- resolve_team(template),
         {:ok, session_name} <- resolve_name(user_name),
         {:ok, session_id} <- create_session(session_name, cwd),
         {:ok, team_id} <- materialize_team(session_id, team, cwd),
         :ok <- save_metadata(session_id, template, session_name, cwd, team_id) do
      {:ok, session_id}
    end
  end

  @doc """
  Resume a session by session_id or by name. Reconstructs the team, restores
  message history, and injects a recovery context if prior work was in-flight.
  """
  @spec resume_session(String.t(), keyword()) :: {:ok, session_id()} | {:error, term()}
  def resume_session(id_or_name, _opts \\ []) do
    sessions_dir = Config.sessions_dir!() |> Path.expand()

    with {:ok, session_id, session_name} <- locate_session(sessions_dir, id_or_name),
         {:ok, _pid} <- reopen_session(session_id, session_name, sessions_dir),
         {:ok, metadata} <- Session.get_metadata(session_id),
         {:ok, team} <- resolve_team(metadata["team_alias"]),
         {:ok, team_id} <- materialize_team(session_id, team, metadata["cwd"] || File.cwd!()),
         :ok <-
           save_metadata(
             session_id,
             metadata["team_alias"],
             session_name,
             metadata["cwd"] || File.cwd!(),
             team_id
           ),
         :ok <- reconstruct_dynamic_workers(session_id, team_id, team),
         :ok <- maybe_inject_recovery(session_id, team_id) do
      {:ok, session_id}
    end
  end

  @doc """
  Close a session. Stops the agent team and the session GenServer.
  The SQLite file is retained for later resumption.
  """
  @spec close_session(session_id()) :: :ok | {:error, term()}
  def close_session(session_id) do
    with {:ok, team_id} <- read_team_id(session_id) do
      stop_team(team_id)
      Session.stop(session_id)
      :ok
    end
  end

  @doc "Send a user prompt to the orchestrator of a session."
  @spec prompt(session_id(), String.t()) :: :ok | {:error, term()}
  def prompt(session_id, text) do
    with {:ok, team_id} <- read_team_id(session_id),
         {:ok, pid} <- find_orchestrator(team_id) do
      Agent.prompt(pid, text)
    end
  end

  @doc """
  List all sessions on disk — active and inactive — with their id, name, and
  whether they are currently running.
  """
  @spec list_sessions() ::
          [%{session_id: String.t(), name: String.t(), active: boolean()}]
  def list_sessions do
    sessions_dir = Config.sessions_dir!() |> Path.expand()

    sessions_dir
    |> Path.join("*.db")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      [id, name] = path |> Path.basename(".db") |> String.split("_", parts: 2)
      %{session_id: id, name: name, active: session_active?(id)}
    end)
  end

  @spec session_active?(String.t()) :: boolean()
  defp session_active?(session_id) do
    case Session.whereis(session_id) do
      {:ok, _pid} -> true
      {:error, :not_found} -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Teams
  # ---------------------------------------------------------------------------

  @doc "List all registered teams with alias, name, and description."
  @spec list_teams() ::
          [%{alias: String.t(), name: String.t() | nil, description: String.t() | nil}]
  def list_teams do
    ResourceStore.get().teams
    |> Enum.map(fn {team_alias, team} ->
      %{alias: team_alias, name: team.name, description: team.description}
    end)
  end

  @doc "Look up a team by alias."
  @spec get_team(String.t()) :: {:ok, Planck.Agent.Team.t()} | {:error, :not_found}
  def get_team(team_alias) do
    case Map.fetch(ResourceStore.get().teams, team_alias) do
      {:ok, team} -> {:ok, team}
      :error -> {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Resources
  # ---------------------------------------------------------------------------

  @doc "Return models available for use (providers with API keys configured)."
  @spec available_models() :: [Planck.AI.Model.t()]
  def available_models, do: ResourceStore.get().available_models

  @doc """
  Reload tools, skills, teams, and the compactor from disk.
  In-flight sessions keep their original resources.
  """
  @spec reload_resources() :: :ok
  def reload_resources do
    Planck.Headless.Config.JsonBinding.invalidate()
    ResourceStore.reload()
  end

  # ---------------------------------------------------------------------------
  # Private — session lifecycle
  # ---------------------------------------------------------------------------

  @spec locate_session(Path.t(), String.t()) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  defp locate_session(sessions_dir, id_or_name) do
    with {:error, :not_found} <- Session.find_by_id(sessions_dir, id_or_name),
         {:ok, _path, id} <- Session.find_by_name(sessions_dir, id_or_name) do
      {:ok, id, id_or_name}
    else
      {:ok, _path, name} ->
        {:ok, id_or_name, name}

      {:error, :not_found} ->
        {:error, {:session_not_found, id_or_name}}
    end
  end

  @spec reopen_session(String.t(), String.t(), Path.t()) ::
          {:ok, pid()} | {:error, term()}
  defp reopen_session(session_id, session_name, sessions_dir) do
    case Session.whereis(session_id) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_found} ->
        Session.start(session_id, name: session_name, dir: sessions_dir)
    end
  end

  @spec create_session(String.t(), Path.t()) :: {:ok, String.t()} | {:error, term()}
  defp create_session(session_name, _cwd) do
    session_id = generate_id()
    sessions_dir = Config.sessions_dir!() |> Path.expand()

    case Session.start(session_id, name: session_name, dir: sessions_dir) do
      {:ok, _pid} -> {:ok, session_id}
      {:error, reason} -> {:error, {:session_start_failed, reason}}
    end
  end

  @spec save_metadata(String.t(), term(), String.t(), Path.t(), String.t()) :: :ok
  defp save_metadata(session_id, template, session_name, cwd, team_id) do
    team_alias =
      case template do
        nil -> nil
        alias when is_binary(alias) -> alias
      end

    Session.save_metadata(session_id, %{
      "team_alias" => team_alias,
      "team_id" => team_id,
      "session_name" => session_name,
      "cwd" => cwd
    })
  end

  @spec read_team_id(String.t()) :: {:ok, String.t()} | {:error, term()}
  defp read_team_id(session_id) do
    with {:ok, meta} <- Session.get_metadata(session_id) do
      case meta["team_id"] do
        nil -> {:error, :team_id_not_found}
        team_id -> {:ok, team_id}
      end
    end
  end

  @spec resolve_name(String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  defp resolve_name(nil) do
    sessions_dir = Config.sessions_dir!() |> Path.expand()

    case SessionName.generate(sessions_dir) do
      {:ok, name} -> {:ok, name}
      {:error, :exhausted} -> {:error, :session_name_exhausted}
    end
  end

  defp resolve_name(name) do
    case SessionName.sanitize(name) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, :invalid} -> {:error, {:invalid_session_name, name}}
    end
  end

  @spec resolve_team(term()) :: {:ok, Team.t()} | {:error, term()}
  defp resolve_team(nil), do: build_dynamic_team()

  defp resolve_team(alias) when is_binary(alias) do
    case get_team(alias) do
      {:ok, team} ->
        {:ok, team}

      {:error, :not_found} ->
        # Try as a filesystem path
        if File.dir?(alias) do
          Team.load(alias)
        else
          {:error, {:team_not_found, alias}}
        end
    end
  end

  @spec build_dynamic_team() :: {:ok, Team.t()} | {:error, term()}
  defp build_dynamic_team do
    provider = Config.default_provider!()
    model_id = Config.default_model!()

    if is_nil(provider) or is_nil(model_id) do
      {:error,
       {:no_default_model_configured,
        "Set default_provider and default_model in ~/.planck/config.json or via PLANCK_DEFAULT_PROVIDER / PLANCK_DEFAULT_MODEL"}}
    else
      store = ResourceStore.get()

      base_url =
        store.available_models
        |> Enum.find(&(&1.provider == provider && &1.id == model_id))
        |> case do
          %{base_url: url} -> url
          nil -> nil
        end

      orchestrator =
        AgentSpec.new(
          type: "orchestrator",
          provider: provider,
          model_id: model_id,
          base_url: base_url,
          system_prompt: DefaultPrompt.orchestrator(),
          tools: builtin_tool_names() ++ Enum.map(store.tools, & &1.name),
          skills: Enum.map(store.skills, & &1.name)
        )

      {:ok, Team.dynamic(orchestrator)}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — team materialization
  # ---------------------------------------------------------------------------

  @spec materialize_team(String.t(), Team.t(), Path.t()) :: {:ok, String.t()} | {:error, term()}
  defp materialize_team(session_id, team, cwd) do
    store = ResourceStore.get()
    team_id = generate_id()

    orch_spec = Enum.find(team.members, &(&1.type == "orchestrator"))
    workers = Enum.reject(team.members, &(&1.type == "orchestrator"))
    orchestrator_id = generate_id()

    with {:ok, _} <-
           start_orchestrator(session_id, team_id, orchestrator_id, orch_spec, store, cwd),
         :ok <- start_workers(session_id, team_id, orchestrator_id, workers, store) do
      {:ok, team_id}
    end
  end

  @spec start_orchestrator(
          String.t(),
          String.t(),
          String.t(),
          AgentSpec.t(),
          ResourceStore.t(),
          Path.t()
        ) :: {:ok, pid()} | {:error, term()}
  defp start_orchestrator(session_id, team_id, orchestrator_id, spec, store, cwd) do
    base_opts =
      AgentSpec.to_start_opts(spec,
        tool_pool: builtins() ++ store.tools,
        skill_pool: store.skills,
        team_id: team_id,
        session_id: session_id,
        available_models: store.available_models
      )

    resolved = base_opts[:tools]

    full_tools =
      Tools.orchestrator_tools(
        session_id,
        team_id,
        orchestrator_id,
        store.available_models,
        resolved
      ) ++
        Tools.worker_tools(team_id, nil) ++
        resolved

    system_prompt = prepend_agents_md(base_opts[:system_prompt], cwd)

    opts =
      base_opts
      |> Keyword.put(:id, orchestrator_id)
      |> Keyword.put(:tools, full_tools)
      |> Keyword.put(:system_prompt, system_prompt)
      |> Keyword.put(:on_compact, build_on_compact(spec, base_opts[:model]))

    start_agent(opts)
  end

  @spec start_workers(
          String.t(),
          String.t(),
          String.t(),
          [AgentSpec.t()],
          ResourceStore.t()
        ) :: :ok | {:error, term()}
  defp start_workers(session_id, team_id, orchestrator_id, workers, store) do
    Enum.reduce_while(workers, :ok, fn spec, :ok ->
      base_opts =
        AgentSpec.to_start_opts(spec,
          tool_pool: builtins() ++ store.tools,
          skill_pool: store.skills,
          team_id: team_id,
          session_id: session_id,
          available_models: store.available_models
        )

      resolved = base_opts[:tools]

      opts =
        base_opts
        |> Keyword.put(:tools, Tools.worker_tools(team_id, orchestrator_id) ++ resolved)
        |> Keyword.put(:delegator_id, orchestrator_id)
        |> Keyword.put(:on_compact, build_on_compact(spec, base_opts[:model]))

      case start_agent(opts) do
        {:ok, _pid} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec build_on_compact(AgentSpec.t(), Planck.AI.Model.t() | nil) :: function() | nil
  defp build_on_compact(spec, model) when not is_nil(model) do
    Compactor.build(model,
      compactor: spec.compactor,
      sidecar_node: SidecarManager.node()
    )
  end

  defp build_on_compact(_spec, nil), do: nil

  @spec start_agent(keyword()) :: {:ok, pid()} | {:error, term()}
  defp start_agent(opts) do
    case DynamicSupervisor.start_child(Planck.Agent.AgentSupervisor, {Planck.Agent, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, {:agent_start_failed, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — session helpers
  # ---------------------------------------------------------------------------

  @spec stop_team(String.t()) :: :ok
  defp stop_team(team_id) do
    Planck.Agent.Registry
    |> Registry.lookup({team_id, :member})
    |> Enum.each(fn {pid, _} ->
      DynamicSupervisor.terminate_child(Planck.Agent.AgentSupervisor, pid)
    end)
  end

  @spec find_orchestrator(String.t()) :: {:ok, pid()} | {:error, :orchestrator_not_found}
  defp find_orchestrator(team_id) do
    case Registry.lookup(Planck.Agent.Registry, {team_id, "orchestrator"}) do
      [{pid, _} | _] -> {:ok, pid}
      [] -> {:error, :orchestrator_not_found}
    end
  end

  # After the base team is materialised, replay any spawn_agent calls that
  # completed during the original session but are not part of the base team.
  # This reconstructs dynamic workers added at runtime by the orchestrator.
  @spec reconstruct_dynamic_workers(String.t(), String.t(), Team.t()) :: :ok
  defp reconstruct_dynamic_workers(session_id, team_id, base_team) do
    with {:ok, all_rows} <- Session.messages(session_id),
         {:ok, new_orch_pid} <- find_orchestrator(team_id) do
      new_orch_id = Agent.get_info(new_orch_pid).id
      messages_by_agent = Enum.group_by(all_rows, & &1.agent_id, & &1.message)
      prev_orch_id = find_previous_orchestrator(messages_by_agent, new_orch_id)
      orch_messages = Map.get(messages_by_agent, prev_orch_id || new_orch_id, [])

      # Workers are identified by {type, name}. Name defaults to type when absent,
      # matching AgentSpec.default_name/2 behaviour.
      base_members =
        MapSet.new(base_team.members, fn m -> {m.type, m.name} end)

      store = ResourceStore.get()

      orch_messages
      |> completed_spawn_calls()
      |> Enum.reject(fn args ->
        type = args["type"]
        name = args["name"] || type
        MapSet.member?(base_members, {type, name})
      end)
      |> Enum.each(&start_dynamic_worker(&1, session_id, team_id, new_orch_id, store))
    end

    :ok
  end

  @spec completed_spawn_calls([Planck.Agent.Message.t()]) :: [map()]
  defp completed_spawn_calls(messages) do
    resolved_ids =
      messages
      |> Enum.flat_map(fn msg ->
        Enum.flat_map(msg.content, fn
          {:tool_result, id, _} -> [id]
          _ -> []
        end)
      end)
      |> MapSet.new()

    messages
    |> Enum.filter(&(&1.role == :assistant))
    |> Enum.flat_map(&completed_spawn_parts(&1.content, resolved_ids))
  end

  @spec completed_spawn_parts([term()], MapSet.t()) :: [map()]
  defp completed_spawn_parts(content, resolved_ids) do
    Enum.flat_map(content, fn
      {:tool_call, id, "spawn_agent", args} ->
        if MapSet.member?(resolved_ids, id), do: [args], else: []

      _ ->
        []
    end)
  end

  @spec start_dynamic_worker(map(), String.t(), String.t(), String.t(), ResourceStore.t()) :: :ok
  defp start_dynamic_worker(args, session_id, team_id, orchestrator_id, store) do
    case AgentSpec.from_map(args) do
      {:ok, spec} ->
        base_opts =
          AgentSpec.to_start_opts(spec,
            tool_pool: builtins() ++ store.tools,
            skill_pool: store.skills,
            team_id: team_id,
            session_id: session_id,
            available_models: store.available_models
          )

        opts =
          base_opts
          |> Keyword.put(
            :tools,
            Tools.worker_tools(team_id, orchestrator_id) ++ base_opts[:tools]
          )
          |> Keyword.put(:delegator_id, orchestrator_id)
          |> Keyword.put(:on_compact, build_on_compact(spec, base_opts[:model]))

        case start_agent(opts) do
          {:ok, _} ->
            :ok

          {:error, r} ->
            Logger.warning("[Planck.Headless] could not reconstruct worker: #{inspect(r)}")
        end

      {:error, reason} ->
        Logger.warning("[Planck.Headless] skipping worker reconstruction: #{reason}")
    end

    :ok
  end

  @spec maybe_inject_recovery(String.t(), String.t()) :: :ok
  defp maybe_inject_recovery(session_id, team_id) do
    with {:ok, orch_pid} <- find_orchestrator(team_id),
         {:ok, all_rows} <- Session.messages(session_id) do
      new_orch_id = Agent.get_info(orch_pid).id

      messages_by_agent =
        Enum.group_by(all_rows, & &1.agent_id, & &1.message)

      # The new orchestrator (just started) has no messages yet. The previous
      # orchestrator is the agent whose messages contain orchestrator-specific
      # tool calls (ask_agent, delegate_task, spawn_agent). We inject the
      # recovery message under the new orchestrator's id so it sees it first.
      prev_orch_id = find_previous_orchestrator(messages_by_agent, new_orch_id)
      orch_messages = Map.get(messages_by_agent, prev_orch_id || new_orch_id, [])

      in_flight =
        unresolved_asks(orch_messages) ++
          unfinished_workers(messages_by_agent, prev_orch_id || new_orch_id)

      if in_flight != [] do
        Session.append(session_id, new_orch_id, build_recovery_message(in_flight))
      end
    end

    :ok
  end

  @orchestrator_tools ~w(ask_agent delegate_task spawn_agent)

  @spec find_previous_orchestrator(%{String.t() => [Planck.Agent.Message.t()]}, String.t()) ::
          String.t() | nil
  defp find_previous_orchestrator(messages_by_agent, new_orch_id) do
    Enum.find_value(messages_by_agent, fn {agent_id, messages} ->
      if agent_id != new_orch_id && has_orchestrator_tool_calls?(messages),
        do: agent_id
    end)
  end

  @spec has_orchestrator_tool_calls?([Planck.Agent.Message.t()]) :: boolean()
  defp has_orchestrator_tool_calls?(messages) do
    Enum.any?(messages, fn msg ->
      msg.role == :assistant &&
        Enum.any?(msg.content, fn
          {:tool_call, _, name, _} -> name in @orchestrator_tools
          _ -> false
        end)
    end)
  end

  @spec build_recovery_message([{String.t(), String.t()}]) :: Planck.Agent.Message.t()
  defp build_recovery_message(in_flight) do
    lines = Enum.map_join(in_flight, "\n", fn {tool, desc} -> "- #{tool}: #{desc}" end)

    body = """
    Session resumed after interruption. The following tasks were in progress when the session ended:

    #{lines}

    Review your message history and re-delegate or continue as appropriate.
    """

    Planck.Agent.Message.new(:user, [{:text, String.trim(body)}])
  end

  # Find ask_agent tool calls in the orchestrator's messages that have no
  # matching tool_result — the orchestrator was blocked waiting for an answer.
  @spec unresolved_asks([Planck.Agent.Message.t()]) :: [{String.t(), String.t()}]
  defp unresolved_asks(messages) do
    # Collect all resolved tool call ids from tool_result messages.
    resolved_ids =
      messages
      |> Enum.flat_map(fn msg ->
        Enum.flat_map(msg.content, fn
          {:tool_result, id, _} -> [id]
          _ -> []
        end)
      end)
      |> MapSet.new()

    # Find ask_agent tool calls with no matching result.
    messages
    |> Enum.filter(&(&1.role == :assistant))
    |> Enum.flat_map(&unresolved_ask_parts(&1.content, resolved_ids))
  end

  @spec unresolved_ask_parts([term()], MapSet.t()) :: [{String.t(), String.t()}]
  defp unresolved_ask_parts(content, resolved_ids) do
    Enum.flat_map(content, fn
      {:tool_call, id, "ask_agent", input} ->
        if MapSet.member?(resolved_ids, id) do
          []
        else
          target = input["name"] || input["type"] || "agent"
          [{"ask_agent", "waiting for answer from #{target}: #{input["question"]}"}]
        end

      _ ->
        []
    end)
  end

  # Find workers (non-orchestrator agent_ids) whose last assistant message
  # does not end with a send_response tool call — they never finished their task.
  @spec unfinished_workers(%{String.t() => [Planck.Agent.Message.t()]}, String.t()) ::
          [{String.t(), String.t()}]
  defp unfinished_workers(messages_by_agent, orch_id) do
    messages_by_agent
    |> Enum.reject(fn {id, _} -> id == orch_id end)
    |> Enum.flat_map(fn {_worker_id, msgs} ->
      last_assistant =
        msgs
        |> Enum.filter(&(&1.role == :assistant))
        |> List.last()

      if last_assistant && not ends_with_send_response?(last_assistant) do
        # Try to find what task was delegated to this worker from the orchestrator.
        [{"delegate_task", "worker did not send a response"}]
      else
        []
      end
    end)
  end

  @spec ends_with_send_response?(Planck.Agent.Message.t()) :: boolean()
  defp ends_with_send_response?(message) do
    message.content
    |> Enum.reverse()
    |> Enum.find(fn
      {:tool_call, _, _, _} -> true
      _ -> false
    end)
    |> case do
      {:tool_call, _, "send_response", _} -> true
      _ -> false
    end
  end

  @spec builtins() :: [Planck.Agent.Tool.t()]
  defp builtins do
    [BuiltinTools.read(), BuiltinTools.write(), BuiltinTools.edit(), BuiltinTools.bash()]
  end

  @spec builtin_tool_names() :: [String.t()]
  defp builtin_tool_names, do: Enum.map(builtins(), & &1.name)

  @spec prepend_agents_md(String.t() | nil, Path.t()) :: String.t() | nil
  defp prepend_agents_md(system_prompt, cwd) do
    case find_agents_md(Path.expand(cwd)) do
      nil -> system_prompt
      content when system_prompt in [nil, ""] -> content
      content -> content <> "\n\n" <> system_prompt
    end
  end

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

  @spec generate_id() :: String.t()
  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
