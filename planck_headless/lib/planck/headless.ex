defmodule Planck.Headless do
  @moduledoc """
  The headless core of the Planck coding agent.

  `planck_headless` owns configuration, loads resources at startup (tools,
  skills, teams, compactor), and manages session lifecycles. UIs depend on
  this module; they are rendering surfaces only and never call `planck_agent`
  directly.

  See the design specs in the `specs/` directory of the repository.
  """

  require Logger

  alias Planck.Agent

  alias Planck.Agent.{
    AgentSpec,
    BuiltinTools,
    Message,
    Session,
    Skill,
    SkillUsage,
    Team,
    Tools
  }

  alias Planck.AI.Model

  alias Planck.Headless.{
    Config,
    DefaultPrompt,
    ResourceStore,
    SessionName,
    SidecarManager
  }

  @typedoc "A session ID"
  @type session_id :: String.t()

  @typedoc "A session name"
  @type session_name :: String.t()

  @typedoc "A team ID"
  @type team_id :: String.t()

  @typedoc "An agent ID"
  @type agent_id :: String.t()

  @typedoc "An agent name"
  @type agent_name :: String.t()

  @typedoc "A tool call ID"
  @type tool_call_id :: String.t()

  @typedoc "A tool call ID"
  @type tool_call_name :: String.t()

  @typedoc false
  @type start_ctx :: %{
          metadata: map(),
          session_tools: [Planck.Agent.Tool.t()],
          prev_ids: %{agent_name() => agent_id()},
          team_name: String.t() | nil
        }

  @typedoc false
  @type session_metadata :: %{
          template: term(),
          session_name: session_name(),
          cwd: Path.t(),
          team_id: String.t(),
          agent_id_map: map(),
          description: String.t() | nil,
          persistence: String.t() | nil
        }

  @typedoc """
  A parked tool call awaiting human approval.
  """
  @type approval :: %{
          agent_id: agent_id(),
          call_id: tool_call_id(),
          tool_name: tool_call_name(),
          args: map(),
          reason: String.t()
        }

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
  Starts a new session.

  ## Options

  - `template:` — team alias, path to a TEAM.json directory, `"dynamic"` for
    the built-in lone-orchestrator team, or `nil` for the default team: the
    `default_team` config if set (falling back to dynamic when unresolvable),
    otherwise the dynamic team.
  - `name:` — session name; auto-generated as `<adjective>-<noun>` if absent.
  - `cwd:` — working directory for the session (default: `File.cwd!()`).
  - `tools:` — extra `Planck.Agent.Tool.t()` list available only for this
    session. These shadow registered and built-in tools of the same name.
  """
  @spec start_session(keyword()) ::
          {:ok, session_id()}
          | {:error, {:team_not_found, String.t()}}
          | {:error, {:no_default_model_configured, String.t()}}
          | {:error, {:default_model_not_available, String.t()}}
          | {:error, :session_name_exhausted}
          | {:error, {:invalid_session_name, String.t()}}
          | {:error, :session_start_failed}
          | {:error, {:cannot_start_agent, nil | agent_id()}}
          | {:error, String.t()}
  def start_session(opts \\ [])

  def start_session(opts) when is_list(opts) do
    template = Keyword.get(opts, :template)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    session_name = Keyword.get(opts, :name)
    session_tools = Keyword.get(opts, :tools, [])

    with {:ok, team} <- resolve_team(template),
         {:ok, session_name} <- resolve_name(session_name),
         {:ok, session_id} <- create_session(session_name),
         {:ok, team_id} <- materialize_team(session_id, team, cwd, session_tools: session_tools) do
      save_metadata(session_id, %{
        template: template || Config.default_team!(),
        session_name: session_name,
        cwd: cwd,
        team_id: team_id,
        agent_id_map: agent_ids(team_id),
        description: team.description,
        persistence: primary_persistence(team)
      })

      {:ok, session_id}
    end
  end

  @doc """
  Resumes a session by session_id or by name. Reconstructs the team, restores
  message history, and injects a recovery context if prior work was in-flight.
  """
  @spec resume_session(String.t()) ::
          {:ok, session_id()}
          | {:error, {:session_not_found, String.t()}}
          | {:error, :session_start_failed}
          | {:error, :not_found}
          | {:error, {:team_not_found, String.t()}}
          | {:error, {:no_default_model_configured, String.t()}}
          | {:error, {:default_model_not_available, String.t()}}
          | {:error, {:cannot_start_agent, nil | agent_id()}}
          | {:error, String.t()}
  def resume_session(id_or_name)

  def resume_session(id_or_name) when is_binary(id_or_name) do
    sessions_dir = Config.sessions_dir!() |> Path.expand()

    with {:ok, session_id, session_name} <- locate_session(sessions_dir, id_or_name),
         {:ok, ^session_id} <- create_session(session_id, session_name),
         {:ok, metadata} <- Session.get_metadata(session_id),
         {:ok, team} <- resolve_team(metadata["team_alias"]),
         prev_ids = agent_ids(metadata),
         {:ok, team_id} <-
           materialize_team(session_id, team, metadata["cwd"] || File.cwd!(),
             prev_ids: prev_ids,
             metadata: metadata
           ),
         :ok <- reconstruct_dynamic_workers(session_id, team_id, team),
         :ok <-
           save_metadata(session_id, %{
             template: metadata["team_alias"],
             session_name: session_name,
             cwd: metadata["cwd"] || File.cwd!(),
             team_id: team_id,
             agent_id_map: agent_ids(team_id),
             description: metadata["team_description"],
             persistence: primary_persistence(team)
           }),
         :ok <- maybe_inject_recovery(session_id, team_id) do
      {:ok, session_id}
    end
  end

  @doc """
  Close a session. Stops the agent team and the session GenServer.
  The SQLite file is retained for later resumption.
  """
  @spec close_session(session_id()) ::
          :ok
          | {:error, :team_id_not_found}
  def close_session(session_id)

  def close_session(session_id) when is_binary(session_id) do
    with {:ok, team_id} <- read_team_id(session_id) do
      stop_team(team_id)
      Session.stop(session_id)
      :ok
    end
  end

  @doc """
  Close a session and permanently delete its stored data.

  Stops all running agents and the Session GenServer if active, then
  dispatches `delete_session` to the session's persistence backend — the
  built-in SQLite `.db` file by default, or the custom `persistence:`
  module declared by the team (on the sidecar node when one is running),
  resolved from the session's saved metadata the same way
  `session_messages/1` resolves its read backend. This operation is
  irreversible.
  """
  @spec delete_session(session_id()) :: :ok
  def delete_session(session_id)

  def delete_session(session_id) when is_binary(session_id) do
    # Read the persistence module before closing — the Session GenServer
    # must still be alive to answer, and it's what tells us which backend
    # (if any) owns this session's data.
    persistence =
      case Session.get_metadata(session_id) do
        {:ok, metadata} -> metadata["persistence"]
        _ -> nil
      end

    # Stop running processes if active — best-effort, ignore any errors
    try do
      close_session(session_id)
    rescue
      _ -> :ok
    end

    sessions_dir = Config.sessions_dir!() |> Path.expand()
    module = resolve_hook_module(persistence)

    Agent.Hooks.Persistence.delete_session(
      module,
      session_id,
      [dir: sessions_dir],
      SidecarManager.node()
    )

    :ok
  end

  @doc """
  Edit a previous user message: rewind the orchestrator to strictly before the
  given DB row id (truncates both the SQLite session and in-memory history via
  `Planck.Agent.rewind_to_message/2`), then re-prompt with `new_text`.
  """
  @spec rewind_to_message(session_id(), pos_integer(), String.t()) ::
          :ok
          | {:error, :team_id_not_found}
          | {:error, :orchestrator_not_found}
          | {:error, :already_sent}
  def rewind_to_message(session_id, db_id, new_text)

  def rewind_to_message(session_id, db_id, new_text)
      when is_binary(session_id) and
             is_integer(db_id) and db_id > 0 and
             is_binary(new_text) do
    with {:ok, team_id} <- read_team_id(session_id),
         {:ok, orch_pid} <- find_orchestrator(team_id) do
      Agent.rewind_to_message(orch_pid, db_id)
      Agent.prompt(orch_pid, new_text)
    end
  end

  @doc """
  Send a user prompt to the orchestrator of a session.

  If the text starts with `/<command-name>`, it is dispatched as a slash
  command against three precedence tiers: built-in primitives (`/clear`,
  `/compact`), custom commands (from `ResourceStore.commands`), and skills
  (from `ResourceStore.skills`). A `/<name>` that matches no tier is passed
  through verbatim as a normal user message.

  Pass `edit: id` to instead replace the text of a message with that id —
  only succeeds if it's still the last, unpersisted message queued while
  the orchestrator was busy; fails with `{:error, :already_sent}` once it's
  been flushed to the session.
  """
  @spec prompt(session_id(), String.t(), keyword()) ::
          :ok
          | {:error, :team_id_not_found}
          | {:error, :orchestrator_not_found}
          | {:error, :already_sent}
  def prompt(session_id, text, opts \\ [])

  def prompt(session_id, text, opts)
      when is_binary(session_id) and is_binary(text) and is_list(opts) do
    with {:ok, team_id} <- read_team_id(session_id),
         {:ok, pid} <- find_orchestrator(team_id) do
      dispatch_prompt(pid, text, opts)
    end
  end

  @doc """
  Cancel a message still queued (unpersisted) in the orchestrator's
  in-memory message list. Used by the UI to remove a queued command,
  `/clear`, `/compact`, or user message before the agent processes it.

  Returns `{:error, :already_sent}` once the message has been flushed to
  the session, or `{:error, :not_found}` if no message with that id is
  queued.
  """
  @spec cancel_queued_message(session_id(), String.t()) ::
          :ok
          | {:error, :team_id_not_found}
          | {:error, :orchestrator_not_found}
          | {:error, :not_found}
          | {:error, :already_sent}
  def cancel_queued_message(session_id, agent_id)

  def cancel_queued_message(session_id, agent_id)
      when is_binary(session_id) and is_binary(agent_id) do
    with {:ok, team_id} <- read_team_id(session_id),
         {:ok, pid} <- find_orchestrator(team_id) do
      Agent.cancel_queued(pid, agent_id)
    end
  end

  @doc """
  Approve a parked tool call for the given agent in the session.

  The agent must belong to the session; unknown or already-resolved calls
  return `{:error, :not_found}`.
  """
  @spec approve_tool_call(session_id(), String.t(), String.t()) ::
          :ok
          | {:error, :not_found}
          | {:error, :agent_not_in_session}
          | {:error, :agent_not_found}
  def approve_tool_call(session_id, agent_id, call_id)

  def approve_tool_call(session_id, agent_id, call_id)
      when is_binary(session_id) and is_binary(agent_id) and is_binary(call_id) do
    with_session_agent(session_id, agent_id, &Agent.approve_tool_call(&1, call_id))
  end

  @doc """
  Deny a parked tool call for the given agent in the session, with an
  optional reason shown to the model.

  The agent must belong to the session; unknown or already-resolved calls
  return `{:error, :not_found}`.
  """
  @spec deny_tool_call(session_id(), String.t(), String.t(), String.t() | nil) ::
          :ok
          | {:error, :not_found}
          | {:error, :agent_not_in_session}
          | {:error, :agent_not_found}
  def deny_tool_call(session_id, agent_id, call_id, reason \\ nil)

  def deny_tool_call(session_id, agent_id, call_id, reason)
      when is_binary(session_id) and is_binary(agent_id) and is_binary(call_id) do
    with_session_agent(session_id, agent_id, &Agent.deny_tool_call(&1, call_id, reason))
  end

  @doc """
  List parked tool calls awaiting human approval for the given agent in
  the session. Used by UIs rendering approval prompts after a refresh,
  when the `:tool_blocked` event was missed.
  """
  @spec list_pending_approvals(session_id(), String.t()) ::
          {:ok, [approval()]}
          | {:error, :not_found}
          | {:error, :agent_not_in_session}
          | {:error, :agent_not_found}
  def list_pending_approvals(session_id, agent_id)
      when is_binary(session_id) and is_binary(agent_id) do
    with_session_agent(session_id, agent_id, fn pid ->
      approvals =
        pid
        |> Agent.list_pending_approvals()
        |> Enum.map(&flatten_approval(&1, agent_id))

      {:ok, approvals}
    end)
  end

  @doc """
  List parked tool calls awaiting human approval across all agents in
  the session. Each entry carries its owning `agent_id`. Dead agents
  are skipped.
  """
  @spec list_all_pending_approvals(session_id()) ::
          {:ok, [approval()]}
          | {:error, :not_found}
  def list_all_pending_approvals(session_id) do
    with {:ok, metadata} <- Session.get_metadata(session_id) do
      approvals =
        metadata
        |> agent_ids()
        |> Map.values()
        |> Stream.map(&list_pending_approvals(session_id, &1))
        |> Stream.filter(&(elem(&1, 0) == :ok))
        |> Enum.flat_map(&elem(&1, 1))

      {:ok, approvals}
    end
  end

  @spec flatten_approval(Agent.Turn.running_entry(), agent_id()) :: approval()
  defp flatten_approval(entry, agent_id)

  defp flatten_approval(entry, agent_id)
       when is_map(entry) and is_binary(agent_id) do
    tool_call = Map.get(entry, :tool_call, %{})
    metadata = Map.get(entry, :metadata, %{})

    %{
      agent_id: agent_id,
      call_id: Map.get(tool_call, :id),
      tool_name: Map.get(tool_call, :name),
      args: Map.get(tool_call, :args, %{}),
      reason: Map.get(metadata, :reason, "")
    }
  end

  @spec with_session_agent(session_id(), agent_id(), (pid() -> term())) :: term()
  defp with_session_agent(session_id, agent_id, fun)

  defp with_session_agent(session_id, agent_id, fun)
       when is_binary(session_id) and is_binary(agent_id) and is_function(fun, 1) do
    with {:ok, metadata} <- Session.get_metadata(session_id),
         ids = agent_ids(metadata),
         true <- agent_id in Map.values(ids),
         {:ok, pid} <- Agent.whereis(agent_id) do
      fun.(pid)
    else
      false -> {:error, :agent_not_in_session}
      {:error, :not_found} -> {:error, :agent_not_found}
    end
  end

  @slash_re ~r/\A\/([a-z0-9_-]+)(\s+(.*))?\z/i

  @spec dispatch_prompt(pid(), String.t(), keyword()) :: :ok | {:error, :already_sent}
  defp dispatch_prompt(pid, text, opts)

  defp dispatch_prompt(pid, "/clear" <> rest, opts) do
    if String.trim(rest) == "" do
      Agent.clear(pid)
    else
      dispatch_slash(pid, "/clear" <> rest, opts)
    end
  end

  defp dispatch_prompt(pid, "/compact" <> prompt, _opts) do
    case String.trim(prompt) do
      "" ->
        Agent.compact(pid, %{prompt: nil})

      prompt ->
        Agent.compact(pid, %{prompt: prompt})
    end
  end

  defp dispatch_prompt(pid, "/" <> _ = original, opts) do
    dispatch_slash(pid, original, opts)
  end

  defp dispatch_prompt(pid, text, opts) do
    Agent.prompt(pid, text, opts)
  end

  defp dispatch_slash(pid, original, opts) do
    case Regex.run(@slash_re, original, capture: :all_but_first) do
      [name, _full_extra, args] ->
        dispatch_command(pid, original, name, args, opts)

      [name] ->
        dispatch_command(pid, original, name, nil, opts)

      _ ->
        Agent.prompt(pid, original, opts)
    end
  end

  @spec dispatch_command(pid(), String.t(), String.t(), String.t() | nil, keyword()) ::
          :ok | {:error, :already_sent}
  defp dispatch_command(pid, original, name, args, opts)

  defp dispatch_command(pid, original, name, args, opts) do
    store = ResourceStore.get()

    cond do
      command = find_by_name(store.commands, name) ->
        Agent.command(pid, command, args)

      skill = find_by_name(store.skills, name) ->
        dispatch_skill(pid, skill, args, opts)

      true ->
        Agent.prompt(pid, original, opts)
    end
  end

  @spec dispatch_skill(pid(), Skill.t(), String.t() | nil, keyword()) :: :ok
  defp dispatch_skill(pid, skill, args, _opts) do
    Agent.load_skill(pid, skill, args)
  end

  @spec find_by_name([struct()], String.t()) :: struct() | nil
  defp find_by_name(items, name) do
    Enum.find(items, &(&1.name == name))
  end

  @doc """
  Nudge the orchestrator to act on its existing message history without adding
  a new user message. Used after session resume when a recovery context is
  already present and just needs to be acted upon.

  Returns `:ok` if the orchestrator was nudged, `{:error, reason}` otherwise.
  """
  @spec nudge(session_id()) :: :ok | {:error, term()}
  def nudge(session_id) do
    with {:ok, team_id} <- read_team_id(session_id),
         {:ok, pid} <- find_orchestrator(team_id) do
      Agent.nudge(pid)
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
    |> Enum.sort_by(&File.stat!(&1).ctime, :desc)
    |> Enum.map(fn path ->
      [id, name] = path |> Path.basename(".db") |> String.split("_", parts: 2)
      %{session_id: id, name: name, active: session_active?(id)}
    end)
  end

  @doc """
  Return every agent's messages for `session_id`, interleaved by insertion
  order — the cross-agent history a chat UI displays, not any single agent's
  own view of it.

  Resolves the session's persistence module from its saved metadata (set at
  `start_session/1`/`resume_session/2` time from the primary team member's
  `persistence` field) rather than from a running agent process, so it
  reaches the same backend a custom `persistence:` configuration used to
  write it — the built-in SQLite store, `nil` in metadata, is the default.

  Has the same reachability as `Session.get_metadata/1`: the session's own
  `Session` GenServer must be running (active, or reopened via
  `resume_session/2`).
  """
  @spec session_messages(session_id()) ::
          {:ok, [Agent.Hooks.Persistence.session_row()]} | {:error, term()}
  def session_messages(session_id) do
    with {:ok, metadata} <- Session.get_metadata(session_id) do
      module = resolve_hook_module(metadata["persistence"])
      Agent.Hooks.Persistence.load_session_messages(module, session_id, SidecarManager.node())
    end
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
  @spec available_models() :: [Model.t()]
  def available_models do
    ResourceStore.get().available_models
  end

  @doc """
  Ask an RLCD model a set of typed questions, using the first available
  `:rlcd` model.
  """
  @spec ask(String.t() | map(), map()) ::
          {:ok, map()}
          | {:error, :no_rlcd_model}
          | {:error, term()}
  @spec ask(String.t() | map(), map(), [Model.t()]) ::
          {:ok, map()}
          | {:error, :no_rlcd_model}
          | {:error, term()}
  def ask(state, questions, available \\ available_models())

  def ask(state, questions, available)
      when is_map(questions) and is_list(available) do
    with %Model{type: :rlcd} = model <- Enum.find(available, &(&1.type == :rlcd)),
         {:ok, response} <-
           Planck.Agent.AIBehaviour.client().evaluate(model, state, questions, []) do
      {:ok, response.object}
    else
      nil -> {:error, :no_rlcd_model}
      {:error, _} = error -> error
    end
  end

  @doc """
  Register a local-node tool globally. Available to all new sessions.

  If a tool with the same name is already registered it is replaced.
  Registered tools shadow sidecar tools and built-ins of the same name.
  See the tool-shadowing guide for details.
  """
  @spec register_tool(Planck.Agent.Tool.t()) :: :ok
  def register_tool(tool), do: ResourceStore.register_tool(tool)

  @doc "Remove a globally registered tool by name. No-op if not found."
  @spec unregister_tool(String.t()) :: :ok
  def unregister_tool(name), do: ResourceStore.unregister_tool(name)

  @doc """
  Persist a provider entry to the JSON config and API key to `.env`, then
  reload resources.

  Options:
  - `:id` (required) — provider key written to `providers` map (e.g. `"anthropic"`, `"nvidia"`)
  - `:type` (required) — `"anthropic"`, `"openai"`, or `"google"`
  - `:base_url` — for OpenAI-compatible endpoints
  - `:identifier` — uppercase tag for env var derivation (`"NVIDIA"` → `NVIDIA_API_KEY`)
  - `:has_api_key` — set `false` for keyless local servers; default `true`
  - `:api_key` — written to `<scope>/.env`
  - `:scope` — `:local` (default, `.planck/`) or `:global` (`~/.planck/`)
  """
  @spec configure_provider(keyword()) :: :ok | {:error, term()}
  def configure_provider(opts) do
    id = Keyword.fetch!(opts, :id)
    type = Keyword.fetch!(opts, :type)
    scope = Keyword.get(opts, :scope, :local)
    api_key = Keyword.get(opts, :api_key)
    raw_identifier = Keyword.get(opts, :identifier)
    has_api_key = Keyword.get(opts, :has_api_key, true)

    config_path = Keyword.get(opts, :config_file) || config_path_for(scope)
    env_path = Keyword.get(opts, :env_file) || env_path_for(scope)

    with :ok <- if(id == "", do: {:error, :empty_id}, else: :ok),
         {:ok, identifier} <- sanitize_provider_identifier(type, raw_identifier),
         entry = provider_entry(identifier, opts),
         config_update = %{"providers" => %{id => entry}},
         effective_api_key = if(has_api_key, do: api_key, else: nil),
         :ok <- ensure_config_dir(config_path),
         :ok <- update_json_config(config_path, config_update),
         :ok <- maybe_store_api_key(type, effective_api_key, identifier, env_path) do
      reload_resources()
    end
  end

  # Normalizes the identifier before it's ever written to config.json, using
  # the same rule Planck.AI.Config applies at load time — so the persisted
  # identifier and the .env key it derives (provider_api_key_env_var/2) always
  # agree, instead of drifting apart (e.g. a lowercase identifier writing a
  # mismatched-case .env key that the uppercased, loaded Model can't find).
  @spec sanitize_provider_identifier(String.t(), String.t() | nil) ::
          {:ok, String.t() | nil} | {:error, :invalid_identifier}
  defp sanitize_provider_identifier("openai", raw) when is_binary(raw) do
    case Planck.AI.Config.sanitize_identifier(raw) do
      {:ok, cleaned} -> {:ok, cleaned}
      :error -> {:error, :invalid_identifier}
    end
  end

  defp sanitize_provider_identifier(_type, raw) do
    {:ok, raw}
  end

  @spec provider_entry(nil | binary(), keyword()) :: map()
  defp provider_entry(identifier, opts)

  defp provider_entry(identifier, opts) when is_list(opts) do
    type = Keyword.fetch!(opts, :type)
    base_url = Keyword.get(opts, :base_url)
    has_api_key = Keyword.get(opts, :has_api_key, true)

    %{"type" => type}
    |> maybe_put("base_url", base_url)
    |> maybe_put("identifier", identifier)
    |> then(fn entry ->
      if has_api_key,
        do: entry,
        else: Map.put(entry, "has_api_key", false)
    end)
  end

  @doc """
  Persist a model entry to the JSON config, then reload resources so the new
  model is immediately available.

  Options:
  - `:id` (required) — user alias (e.g. `"sonnet"`)
  - `:model` (required) — provider model identifier (e.g. `"claude-sonnet-4-6"`)
  - `:provider` (required) — key referencing an entry in the `providers` map
  - `:scope` — `:local` (default, `.planck/`) or `:global` (`~/.planck/`)
  - `:default` — set as `default_model` (default: `true`). Silently ignored
    for an `:rlcd`-typed (`:typesafe`) provider — an RLCD model cannot serve
    chat, so it can never be the default an agent is started with. Callers
    don't need to know this; it's enforced here, not left to the UI to check.
  - `:params` — inference parameters map (e.g. `%{"temperature" => 0.7}`)
  """
  @spec configure_model(keyword()) :: :ok | {:error, term()}
  def configure_model(opts) do
    id = Keyword.fetch!(opts, :id)
    model_id = Keyword.fetch!(opts, :model)
    provider = Keyword.fetch!(opts, :provider)
    scope = Keyword.get(opts, :scope, :local)
    set_default = Keyword.get(opts, :default, true) and not rlcd_provider_key?(provider)
    params = Keyword.get(opts, :params)
    context_window = Keyword.get(opts, :context_window)
    max_tokens = Keyword.get(opts, :max_tokens)

    config_path = Keyword.get(opts, :config_file) || config_path_for(scope)

    entry =
      %{"id" => id, "model" => model_id, "provider" => provider}
      |> maybe_put("params", params)
      |> maybe_put("context_window", context_window)
      |> maybe_put("max_tokens", max_tokens)

    config_update =
      if set_default,
        do: %{"default_model" => id, "models" => [entry]},
        else: %{"models" => [entry]}

    with :ok <- if(id == "", do: {:error, :empty_id}, else: :ok),
         :ok <- if(provider == "", do: {:error, :empty_provider}, else: :ok),
         :ok <- ensure_config_dir(config_path),
         :ok <- update_json_config(config_path, config_update) do
      reload_resources()
    end
  end

  @doc """
  Reload tools, skills, teams, and the compactor from disk.
  In-flight sessions keep their original resources.
  """
  @spec reload_resources() :: :ok
  def reload_resources do
    ResourceStore.reload()
  end

  # ---------------------------------------------------------------------------
  # Private — session lifecycle
  # ---------------------------------------------------------------------------

  @spec locate_session(Path.t(), String.t()) ::
          {:ok, session_id(), session_name()}
          | {:error, {:session_not_found, String.t()}}
  defp locate_session(sessions_dir, id_or_name)

  defp locate_session(sessions_dir, id_or_name)
       when is_binary(sessions_dir) and is_binary(id_or_name) do
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

  @spec create_session(session_name()) ::
          {:ok, session_id()}
          | {:error, :session_start_failed}
  @spec create_session(nil | session_id(), session_name()) ::
          {:ok, session_id()}
          | {:error, :session_start_failed}
  defp create_session(session_id \\ nil, session_name)

  defp create_session(nil, session_name) when is_binary(session_name) do
    generate_id()
    |> create_session(session_name)
  end

  defp create_session(session_id, session_name)
       when is_binary(session_id) and is_binary(session_name) do
    sessions_dir = Config.sessions_dir!() |> Path.expand()

    case Session.start(session_id, name: session_name, dir: sessions_dir) do
      {:ok, _pid} -> {:ok, session_id}
      {:ok, _pid, _info} -> {:ok, session_id}
      {:error, {:already_started, _pid}} -> {:ok, session_id}
      _ -> {:error, :session_start_failed}
    end
  end

  @spec save_metadata(session_id(), session_metadata()) :: :ok
  defp save_metadata(session_id, attrs)

  defp save_metadata(session_id, attrs)
       when is_binary(session_id) and is_map(attrs) do
    team_alias =
      case attrs.template do
        nil -> nil
        alias when is_binary(alias) -> alias
      end

    Session.save_metadata(session_id, %{
      "team_alias" => team_alias,
      "team_description" => attrs.description,
      "team_id" => attrs.team_id,
      "session_name" => attrs.session_name,
      "cwd" => attrs.cwd,
      "agent_ids" => Jason.encode!(attrs.agent_id_map),
      "persistence" => attrs.persistence
    })
  end

  # The primary member's persistence module string (or nil), stored in
  # session metadata so a later, external reader (e.g. a chat UI, possibly
  # for a closed session with no agent process running) can resolve the
  # same persistence module a session's agents used, for a cross-agent
  # read — see session_messages/1 and Hooks.Persistence.load_session_messages/3.
  @spec primary_persistence(Team.t()) :: String.t() | nil
  defp primary_persistence(team) do
    case Enum.find(team.members, &(&1.type in ["orchestrator", "solo"])) do
      nil -> nil
      spec -> spec.persistence
    end
  end

  # Build a name → id map for all agents in a team, keyed by their display name.
  # Used to preserve agent IDs across session resumes.
  @spec agent_ids(team_id() | map()) :: %{agent_name() => agent_id()}
  defp agent_ids(team_id)

  defp agent_ids(team_id) when is_binary(team_id) do
    Registry.lookup(Planck.Agent.Registry, {team_id, :member})
    |> Map.new(fn {_pid, meta} -> {meta.name || meta.type, meta.id} end)
  end

  defp agent_ids(metadata) when is_map(metadata) do
    with json when is_binary(json) <- metadata["agent_ids"],
         {:ok, ids} <- Jason.decode(json) do
      ids
    else
      _ -> %{}
    end
  end

  @spec read_team_id(session_id()) ::
          {:ok, team_id()}
          | {:error, :team_id_not_found}
  defp read_team_id(session_id)

  defp read_team_id(session_id) when is_binary(session_id) do
    with {:ok, meta} <- Session.get_metadata(session_id),
         %{"team_id" => "" <> team_id} <- meta do
      {:ok, team_id}
    else
      _ -> {:error, :team_id_not_found}
    end
  end

  @spec resolve_name(nil | session_name()) ::
          {:ok, session_name()}
          | {:error, :session_name_exhausted}
          | {:error, {:invalid_session_name, String.t()}}
  defp resolve_name(session_name)

  defp resolve_name(nil) do
    sessions_dir =
      Config.sessions_dir!()
      |> Path.expand()

    case SessionName.generate(sessions_dir) do
      {:ok, name} -> {:ok, name}
      {:error, :exhausted} -> {:error, :session_name_exhausted}
    end
  end

  defp resolve_name(name) when is_binary(name) do
    case SessionName.sanitize(name) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, :invalid} -> {:error, {:invalid_session_name, name}}
    end
  end

  @spec resolve_team(nil | String.t()) ::
          {:ok, Team.t()}
          | {:error, String.t()}
          | {:error, {:team_not_found, String.t()}}
          | {:error, {:no_default_model_configured, String.t()}}
          | {:error, {:default_model_not_available, String.t()}}
  defp resolve_team(team_alias)

  defp resolve_team(nil) do
    case Config.default_team!() do
      team when team in [nil, "dynamic"] ->
        build_dynamic_team()

      default when is_binary(default) ->
        resolve_team(default)
    end
  end

  defp resolve_team(alias) when is_binary(alias) do
    case load_team_any(alias) do
      {:ok, team} ->
        {:ok, team}

      {:error, reason} ->
        Logger.warning(
          "default_team #{inspect(alias)} could not be resolved (#{inspect(reason)}) — " <>
            "falling back to the dynamic team"
        )

        build_dynamic_team()
    end
  end

  @spec load_team_any(String.t()) ::
          {:ok, Team.t()}
          | {:error, String.t()}
          | {:error, {:team_not_found, String.t()}}
  defp load_team_any(alias) do
    with {:error, :not_found} <- get_team(alias),
         expanded = Path.expand(alias),
         true <- File.dir?(expanded) || {:error, {:team_not_found, alias}} do
      Team.load(expanded)
    end
  end

  @spec build_dynamic_team() ::
          {:ok, Team.t()}
          | {:error, {:no_default_model_configured, String.t()}}
          | {:error, {:default_model_not_available, String.t()}}
  @spec build_dynamic_team(nil | String.t()) ::
          {:ok, Team.t()}
          | {:error, {:no_default_model_configured, String.t()}}
          | {:error, {:default_model_not_available, String.t()}}
  defp build_dynamic_team(model_alias \\ nil)

  defp build_dynamic_team(nil) do
    model_alias = Config.default_model!()

    if is_nil(model_alias) do
      reason = "Set default_model in ~/.planck/config.json or via PLANCK_DEFAULT_MODEL"
      {:error, {:no_default_model_configured, reason}}
    else
      build_dynamic_team(model_alias)
    end
  end

  defp build_dynamic_team(model_alias) when is_binary(model_alias) do
    store = ResourceStore.get()

    case Enum.find(store.available_models, &(&1.id == model_alias)) do
      nil ->
        reason = "Model #{inspect(model_alias)} not found — check providers and models in config"
        {:error, {:default_model_not_available, reason}}

      %Model{} = model ->
        orchestrator =
          AgentSpec.new(
            type: "orchestrator",
            provider: model.provider,
            model_id: model.id,
            base_url: model.base_url,
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

  @spec materialize_team(session_id(), Team.t(), Path.t(), keyword()) ::
          {:ok, team_id()}
          | {:error, {:cannot_start_agent, nil | agent_id()}}
  defp materialize_team(session_id, team, cwd, opts)

  defp materialize_team(session_id, %Team{} = team, cwd, opts)
       when is_binary(session_id) and is_binary(cwd) and is_list(opts) do
    prev_ids = Keyword.get(opts, :prev_ids, %{})
    metadata = Keyword.get(opts, :metadata, %{})
    session_tools = Keyword.get(opts, :session_tools, [])

    ctx = %{
      prev_ids: prev_ids,
      metadata: metadata,
      session_tools: session_tools,
      team_name: team.alias || "default"
    }

    store = ResourceStore.get()
    team_id = generate_id()

    orch_spec = Enum.find(team.members, &(&1.type in ["orchestrator", "solo"]))
    workers = Enum.reject(team.members, &(&1.type in ["orchestrator", "solo"]))
    orchestrator_id = Map.get(prev_ids, orch_spec.name || orch_spec.type, generate_id())

    case orch_spec do
      %AgentSpec{type: "orchestrator"} ->
        do_materialize_team(
          session_id,
          team_id,
          orchestrator_id,
          orch_spec,
          workers,
          store,
          cwd,
          ctx
        )

      %AgentSpec{type: "solo"} ->
        do_materialize_solo(
          session_id,
          team_id,
          orchestrator_id,
          orch_spec,
          store,
          cwd,
          ctx
        )
    end
  end

  @spec do_materialize_team(
          session_id(),
          team_id(),
          agent_id(),
          AgentSpec.t(),
          [AgentSpec.t()],
          ResourceStore.t(),
          Path.t(),
          start_ctx()
        ) ::
          {:ok, team_id()}
          | {:error, {:cannot_start_agent, nil | agent_id()}}
  defp do_materialize_team(session_id, team_id, orchestrator_id, spec, workers, store, cwd, ctx)

  defp do_materialize_team(
         session_id,
         team_id,
         orchestrator_id,
         %AgentSpec{} = spec,
         workers,
         %ResourceStore{} = store,
         cwd,
         ctx
       )
       when is_binary(session_id) and
              is_binary(team_id) and
              is_binary(orchestrator_id) and
              is_list(workers) and
              is_binary(cwd) and
              is_map(ctx) do
    with {:ok, _} <-
           start_orchestrator(session_id, team_id, orchestrator_id, spec, store, cwd, ctx),
         :ok <- start_workers(session_id, team_id, orchestrator_id, workers, store, cwd, ctx) do
      {:ok, team_id}
    end
  end

  @spec do_materialize_solo(
          session_id(),
          team_id(),
          agent_id(),
          AgentSpec.t(),
          ResourceStore.t(),
          Path.t(),
          start_ctx()
        ) ::
          {:ok, team_id()}
          | {:error, {:cannot_start_agent, nil | agent_id()}}
  defp do_materialize_solo(session_id, team_id, agent_id, spec, store, cwd, ctx)

  defp do_materialize_solo(
         session_id,
         team_id,
         agent_id,
         %AgentSpec{} = spec,
         %ResourceStore{} = store,
         cwd,
         ctx
       )
       when is_binary(session_id) and
              is_binary(team_id) and
              is_binary(agent_id) and
              is_binary(cwd) and
              is_map(ctx) do
    with {:ok, _} <- start_solo(session_id, team_id, agent_id, spec, store, cwd, ctx) do
      {:ok, team_id}
    end
  end

  @spec start_orchestrator(
          session_id(),
          team_id(),
          agent_id(),
          AgentSpec.t(),
          ResourceStore.t(),
          Path.t(),
          start_ctx()
        ) ::
          {:ok, pid()}
          | {:error, {:cannot_start_agent, nil | agent_id()}}
  defp start_orchestrator(session_id, team_id, orchestrator_id, spec, store, cwd, ctx)

  defp start_orchestrator(
         session_id,
         team_id,
         orchestrator_id,
         %AgentSpec{} = spec,
         %ResourceStore{} = store,
         cwd,
         ctx
       )
       when is_binary(session_id) and
              is_binary(team_id) and
              is_binary(orchestrator_id) and
              is_binary(cwd) and
              is_map(ctx) do
    tool_resolver = fn resolved ->
      orchestrator_tools =
        Tools.orchestrator_tools(
          session_id,
          team_id,
          store.available_models,
          resolved,
          store.skills,
          cwd
        )

      worker_tools = Tools.worker_tools(team_id, nil)

      orchestrator_tools ++ worker_tools
    end

    start_primary_agent(
      session_id,
      team_id,
      orchestrator_id,
      spec,
      store,
      cwd,
      ctx,
      tool_resolver
    )
  end

  @spec start_solo(
          session_id(),
          team_id(),
          agent_id(),
          AgentSpec.t(),
          ResourceStore.t(),
          Path.t(),
          start_ctx()
        ) ::
          {:ok, pid()}
          | {:error, {:cannot_start_agent, nil | agent_id()}}
  defp start_solo(session_id, team_id, agent_id, spec, store, cwd, ctx)

  defp start_solo(
         session_id,
         team_id,
         agent_id,
         %AgentSpec{} = spec,
         %ResourceStore{} = store,
         cwd,
         ctx
       )
       when is_binary(session_id) and
              is_binary(team_id) and
              is_binary(agent_id) and
              is_binary(cwd) and
              is_map(ctx) do
    tool_resolver = fn _resolved -> Tools.solo_tools() end

    start_primary_agent(session_id, team_id, agent_id, spec, store, cwd, ctx, tool_resolver)
  end

  # Shared setup for a team's primary agent — an "orchestrator" or a "solo"
  # agent, the two roles `materialize_team/4` can dispatch to. They differ
  # only in which extra delegation tools they get, supplied by
  # `extra_tools_fn` once the tool pool has resolved `spec.tools`.
  @spec start_primary_agent(
          session_id(),
          team_id(),
          agent_id(),
          AgentSpec.t(),
          ResourceStore.t(),
          Path.t(),
          start_ctx(),
          tool_resolver
        ) ::
          {:ok, pid()}
          | {:error, {:cannot_start_agent, nil | agent_id()}}
        when tool_resolver: ([Planck.Agent.Tool.t()] -> [Planck.Agent.Tool.t()])
  defp start_primary_agent(session_id, team_id, agent_id, spec, store, cwd, ctx, tool_resolver)

  defp start_primary_agent(
         session_id,
         team_id,
         agent_id,
         %AgentSpec{} = spec,
         %ResourceStore{} = store,
         cwd,
         ctx,
         tool_resolver
       )
       when is_binary(session_id) and
              is_binary(team_id) and
              is_binary(agent_id) and
              is_binary(cwd) and
              is_map(ctx) and
              is_function(tool_resolver, 1) do
    skill_opts =
      build_skill_opts(
        ctx.team_name,
        spec.name,
        spec.type,
        store.invocable_skills,
        cwd
      )

    default_tools =
      if spec.tools == [],
        do: builtins(),
        else: []

    base_opts =
      AgentSpec.to_start_opts(spec,
        tool_pool: tool_pool(store),
        tools: default_tools,
        skill_pool: store.invocable_skills,
        skill_refresh_fn: fn -> ResourceStore.get().invocable_skills end,
        on_skill_use: skill_opts[:on_skill_use],
        team_id: team_id,
        session_id: session_id,
        available_models: store.available_models,
        sidecar_node: SidecarManager.node()
      )

    resolved = base_opts[:tools]

    full_tools =
      tool_resolver.(resolved) ++
        skill_discovery_tools(store.invocable_skills) ++
        resolved ++
        store.registered_tools ++
        ctx.session_tools

    system_prompt = Tools.prepend_agents_md(base_opts[:system_prompt], cwd)
    {usage, cost} = load_agent_usage(ctx.metadata, agent_id)

    opts =
      base_opts
      |> Keyword.put(:id, agent_id)
      |> Keyword.put(:cwd, cwd)
      |> Keyword.put(:tools, full_tools)
      |> Keyword.put(:system_prompt, system_prompt)
      |> Keyword.put(:team_name, ctx.team_name)
      |> Keyword.put(:ranked_skill_names, skill_opts[:ranked_skill_names])
      |> Keyword.put(:top_skills, skill_opts[:top_skills])
      |> Keyword.put(:skill_pool, skill_opts[:skill_pool])
      |> Keyword.put(:usage, usage)
      |> Keyword.put(:cost, cost)

    start_agent(opts)
  end

  @spec start_workers(
          session_id(),
          team_id(),
          agent_id(),
          [AgentSpec.t()],
          ResourceStore.t(),
          Path.t(),
          start_ctx()
        ) ::
          :ok
          | {:error, {:cannot_start_agent, nil | agent_id()}}
  defp start_workers(session_id, team_id, orchestrator_id, workers, store, cwd, ctx)

  defp start_workers(
         session_id,
         team_id,
         orchestrator_id,
         workers,
         %ResourceStore{} = store,
         cwd,
         ctx
       )
       when is_binary(session_id) and
              is_binary(team_id) and
              is_binary(orchestrator_id) and
              is_list(workers) and
              is_binary(cwd) and
              is_map(ctx) do
    Enum.reduce_while(workers, :ok, fn spec, :ok ->
      case start_worker(session_id, team_id, orchestrator_id, spec, store, cwd, ctx) do
        {:ok, _pid} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec start_worker(
          session_id(),
          team_id(),
          agent_id(),
          AgentSpec.t(),
          ResourceStore.t(),
          Path.t(),
          start_ctx()
        ) ::
          {:ok, pid()}
          | {:error, {:cannot_start_agent, nil | agent_id()}}
  defp start_worker(session_id, team_id, orchestrator_id, spec, store, cwd, ctx)

  defp start_worker(
         session_id,
         team_id,
         orchestrator_id,
         %AgentSpec{} = spec,
         %ResourceStore{} = store,
         cwd,
         ctx
       )
       when is_binary(session_id) and
              is_binary(team_id) and
              is_binary(orchestrator_id) and
              is_binary(cwd) and
              is_map(ctx) do
    base_opts =
      AgentSpec.to_start_opts(spec,
        tool_pool: tool_pool(store),
        skill_pool: store.invocable_skills,
        skill_refresh_fn: fn -> ResourceStore.get().invocable_skills end,
        team_id: team_id,
        session_id: session_id,
        available_models: store.available_models,
        sidecar_node: SidecarManager.node()
      )

    resolved = base_opts[:tools]
    worker_id = Map.get(ctx.prev_ids, spec.name, base_opts[:id])
    sender = %{id: worker_id, name: spec.name}
    {usage, cost} = load_agent_usage(ctx.metadata, worker_id)
    system_prompt = Tools.prepend_agents_md(base_opts[:system_prompt], cwd)

    skill_opts =
      build_skill_opts(
        ctx.team_name,
        spec.name,
        spec.type,
        store.invocable_skills,
        cwd
      )

    opts =
      base_opts
      |> Keyword.put(:id, worker_id)
      |> Keyword.put(:cwd, cwd)
      |> Keyword.put(
        :tools,
        Tools.worker_tools(team_id, orchestrator_id, sender) ++
          resolved ++ store.registered_tools ++ ctx.session_tools
      )
      |> Keyword.put(:system_prompt, system_prompt)
      |> Keyword.put(:delegator_id, orchestrator_id)
      |> Keyword.put(:team_name, ctx.team_name)
      |> Keyword.put(:ranked_skill_names, skill_opts[:ranked_skill_names])
      |> Keyword.put(:top_skills, skill_opts[:top_skills])
      |> Keyword.put(:skill_pool, skill_opts[:skill_pool])
      |> Keyword.put(:usage, usage)
      |> Keyword.put(:cost, cost)

    start_agent(opts)
  end

  @spec resolve_hook_module(String.t() | nil) :: module() | nil
  defp resolve_hook_module(nil), do: nil
  defp resolve_hook_module(name), do: :"Elixir.#{name}"

  @spec build_skill_opts(String.t(), String.t(), String.t(), [Skill.t()], Path.t()) :: keyword()
  defp build_skill_opts(team_name, agent_name, agent_type, skills, cwd) do
    top_n = Config.top_skills!()

    ranked = SkillUsage.ranked_names(cwd, team_name, agent_name, skills, top_n)

    [
      ranked_skill_names: ranked,
      top_skills: top_n,
      skill_pool: skills,
      on_skill_use: fn _agent_id, skill_name ->
        SkillUsage.record_use(cwd, team_name, agent_name, agent_type, skill_name)
      end,
      skill_index_refresh_fn: fn ->
        current = ResourceStore.get().invocable_skills

        new_ranked = SkillUsage.ranked_names(cwd, team_name, agent_name, current, top_n)

        {current, new_ranked}
      end
    ]
  end

  # list_skills is opt-in: agents declare "list_skills" in their TEAM.json tools
  # array to get autonomous skill discovery. load_skill is injected automatically
  # by AgentSpec.to_start_opts when skill_pool is non-empty.
  @spec skill_discovery_tools([Skill.t()]) :: [Planck.Agent.Tool.t()]
  defp skill_discovery_tools([]), do: []

  defp skill_discovery_tools(skills) do
    base = Skill.list_skills_tool(skills)

    execute_fn =
      fn _agent_id, _id, _args ->
        current = ResourceStore.get().invocable_skills

        entries =
          Enum.map_join(current, "\n", fn %Skill{name: name, description: desc} ->
            "- **#{name}**: #{desc}"
          end)

        if entries == "", do: {:ok, "No skills available."}, else: {:ok, entries}
      end

    [%{base | execute_fn: execute_fn}]
  end

  @spec load_agent_usage(map(), String.t()) ::
          {%{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()}, float()}
  defp load_agent_usage(metadata, agent_id) do
    with json when not is_nil(json) <- Map.get(metadata, "agent_usage:#{agent_id}"),
         {:ok, %{"input_tokens" => i, "output_tokens" => o, "cost" => c}} <- Jason.decode(json) do
      {%{input_tokens: i, output_tokens: o}, c}
    else
      _ -> {%{input_tokens: 0, output_tokens: 0}, 0.0}
    end
  end

  @spec start_agent(keyword()) ::
          {:ok, pid()}
          | {:error, {:cannot_start_agent, nil | agent_id()}}
  defp start_agent(opts)

  defp start_agent(opts) when is_list(opts) do
    case DynamicSupervisor.start_child(Planck.Agent.AgentSupervisor, {Planck.Agent, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      _ -> {:error, {:cannot_start_agent, opts[:id]}}
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

  # A team has exactly one promptable primary agent — either an
  # "orchestrator" or a "solo" agent (Team.validate_single_primary/2 enforces
  # this) — so at most one of these two lookups ever returns a match.
  @spec find_orchestrator(String.t()) ::
          {:ok, pid()}
          | {:error, :orchestrator_not_found}
  defp find_orchestrator(team_id) do
    case Registry.lookup(Planck.Agent.Registry, {team_id, "orchestrator"}) ++
           Registry.lookup(Planck.Agent.Registry, {team_id, "solo"}) do
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
         {:ok, orch_pid} <- find_orchestrator(team_id) do
      orch_id = Agent.get_info(orch_pid).id
      messages_by_agent = Enum.group_by(all_rows, & &1.agent_id, & &1.message)
      orch_messages = Map.get(messages_by_agent, orch_id, [])

      # Workers are identified by {type, name}. Name defaults to type when absent,
      # matching AgentSpec.default_name/2 behaviour.
      base_members =
        MapSet.new(base_team.members, fn m -> {m.type, m.name} end)

      store = ResourceStore.get()

      orch_messages
      |> completed_spawn_calls()
      |> Enum.reject(fn {args, _id} ->
        type = args["type"]
        name = args["name"] || type
        MapSet.member?(base_members, {type, name})
      end)
      |> Enum.reverse()
      |> Enum.uniq_by(fn {args, _id} ->
        type = args["type"]
        name = args["name"] || type
        {type, name}
      end)
      |> Enum.each(fn {args, original_id} ->
        ctx = %{agent_id: original_id, args: args}
        start_dynamic_worker(session_id, team_id, orch_id, store, ctx)
      end)
    end

    :ok
  end

  # Returns {args, original_worker_id} pairs. The worker ID is extracted from
  # the spawn_agent tool result so it matches the ID under which the worker's
  # messages were stored, restoring history on resume.
  @spec completed_spawn_calls([Planck.Agent.Message.t()]) :: [{map(), String.t() | nil}]
  defp completed_spawn_calls(messages) do
    results_by_id =
      messages
      |> Enum.flat_map(fn msg ->
        Enum.flat_map(msg.content, fn
          {:tool_result, id, result} -> [{id, result}]
          _ -> []
        end)
      end)
      |> Map.new()

    messages
    |> Enum.filter(&(&1.role == :assistant))
    |> Enum.flat_map(&completed_spawn_parts(&1.content, results_by_id))
  end

  @spec completed_spawn_parts([term()], %{String.t() => term()}) :: [{map(), String.t() | nil}]
  defp completed_spawn_parts(content, results_by_id) do
    Enum.flat_map(content, fn
      {:tool_call, id, "spawn_agent", args} -> successful_spawn(Map.get(results_by_id, id), args)
      _ -> []
    end)
  end

  @spec successful_spawn(term(), map()) :: [{map(), String.t()}]
  defp successful_spawn(worker_id, args)
       when is_binary(worker_id) and not is_nil(worker_id) do
    if String.starts_with?(worker_id, "Error"), do: [], else: [{args, worker_id}]
  end

  defp successful_spawn(_result, _args), do: []

  @spec start_dynamic_worker(
          session_id(),
          team_id(),
          agent_id(),
          ResourceStore.t(),
          ctx
        ) :: :ok
        when ctx: %{agent_id: agent_id() | nil, args: map()}
  defp start_dynamic_worker(
         session_id,
         team_id,
         orchestrator_id,
         %ResourceStore{} = store,
         ctx
       )
       when is_binary(session_id) and
              is_binary(team_id) and
              is_binary(orchestrator_id) and
              is_map(ctx) do
    with {args, ctx} <- Map.pop(ctx, :args, %{}),
         {:ok, %AgentSpec{} = spec} <- AgentSpec.from_map(args),
         {:ok, _} <-
           do_start_dynamic_worker(session_id, team_id, orchestrator_id, spec, store, ctx) do
      :ok
    else
      {:error, _} ->
        Logger.warning("[Planck.Headless] skipping worker reconstruction.")
    end

    :ok
  end

  @spec do_start_dynamic_worker(
          session_id(),
          team_id(),
          agent_id(),
          AgentSpec.t(),
          ResourceStore.t(),
          ctx
        ) ::
          {:ok, pid()}
          | {:error, {:cannot_start_agent, nil | agent_id()}}
        when ctx: %{agent_id: agent_id() | nil}
  defp do_start_dynamic_worker(session_id, team_id, orchestrator_id, spec, store, ctx)

  defp do_start_dynamic_worker(
         session_id,
         team_id,
         orchestrator_id,
         spec,
         store,
         ctx
       )
       when is_binary(session_id) and
              is_binary(team_id) and
              is_binary(orchestrator_id) and
              is_map(ctx) do
    base_opts =
      AgentSpec.to_start_opts(spec,
        tool_pool: tool_pool(store),
        skill_pool: store.invocable_skills,
        skill_refresh_fn: fn -> ResourceStore.get().invocable_skills end,
        team_id: team_id,
        session_id: session_id,
        available_models: store.available_models,
        sidecar_node: SidecarManager.node()
      )

    base_opts =
      if ctx.agent_id,
        do: Keyword.put(base_opts, :id, ctx.agent_id),
        else: base_opts

    sender = %{id: base_opts[:id], name: spec.name}

    tools = Tools.worker_tools(team_id, orchestrator_id, sender) ++ base_opts[:tools]

    opts =
      base_opts
      |> Keyword.put(:tools, tools)
      |> Keyword.put(:delegator_id, orchestrator_id)
      |> Keyword.put(:team_name, nil)

    start_agent(opts)
  end

  @spec maybe_inject_recovery(String.t(), String.t()) :: :ok
  defp maybe_inject_recovery(session_id, team_id) do
    with {:ok, orch_pid} <- find_orchestrator(team_id),
         {:ok, all_rows} <- Session.messages(session_id) do
      orch_id = Agent.get_info(orch_pid).id
      messages_by_agent = Enum.group_by(all_rows, & &1.agent_id, & &1.message)
      orch_messages = Map.get(messages_by_agent, orch_id, [])

      in_flight =
        if last_message_is_recovery?(orch_messages),
          do: [],
          else: unfinished_workers(messages_by_agent, orch_id, orch_messages)

      if in_flight != [] do
        Session.append(session_id, orch_id, build_recovery_message(in_flight))
      end
    end

    :ok
  end

  @recovery_marker "Session resumed after interruption."

  @spec last_message_is_recovery?([Planck.Agent.Message.t()]) :: boolean()
  defp last_message_is_recovery?(messages) do
    case List.last(messages) do
      %{role: :user, content: [{:text, text}]} -> String.starts_with?(text, @recovery_marker)
      _ -> false
    end
  end

  @orchestrator_tools ~w(call_agent send_agent spawn_agent)

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
    #{@recovery_marker} The following tasks were still in progress when the session ended:

    #{lines}

    The workers listed above are idle and waiting for instructions. Before re-delegating, \
    you can ask each of them where they left off — they retain their context and can \
    continue from that point if you see it fit.
    """

    Message.new(:user, [{:text, String.trim(body)}])
  end

  # Find workers (non-orchestrator agent_ids) whose last received task has no
  # respond_agent after it. For each, find the LAST orchestrator tool call
  # (call_agent or send_agent) that matches the worker's pending task text —
  # that determines both the tool type and the target label in the report.
  @spec unfinished_workers(
          %{String.t() => [Planck.Agent.Message.t()]},
          String.t(),
          [Planck.Agent.Message.t()]
        ) :: [{String.t(), String.t()}]
  defp unfinished_workers(messages_by_agent, orch_id, orch_messages) do
    orchestrator_ids =
      MapSet.new(messages_by_agent, fn {id, msgs} ->
        if has_orchestrator_tool_calls?(msgs), do: id, else: nil
      end)
      |> MapSet.delete(nil)
      |> MapSet.put(orch_id)

    messages_by_agent
    |> Enum.reject(fn {id, _} -> MapSet.member?(orchestrator_ids, id) end)
    |> Enum.flat_map(fn {_worker_id, msgs} ->
      task_text = worker_task_text(msgs)
      interaction = last_orchestrator_interaction(task_text, orch_messages)
      pending_interaction_entry(interaction, msgs)
    end)
  end

  @spec pending_interaction_entry(
          {String.t(), String.t(), String.t()} | nil,
          [Planck.Agent.Message.t()]
        ) :: [{String.t(), String.t()}]
  defp pending_interaction_entry(nil, _msgs), do: []

  defp pending_interaction_entry({"call_agent", target, task}, msgs) do
    if worker_answered_ask?(msgs) do
      []
    else
      [{"call_agent", "#{target}: #{truncate(task, 80)}"}]
    end
  end

  defp pending_interaction_entry({"send_agent", target, task}, msgs) do
    if worker_sent_response?(msgs),
      do: [],
      else: [{"send_agent", "#{target} did not complete: #{truncate(task, 80)}"}]
  end

  # Find the LAST call_agent or send_agent call from the orchestrator whose
  # question/task text matches the worker's current pending task text.
  @spec last_orchestrator_interaction(String.t(), [Planck.Agent.Message.t()]) ::
          {String.t(), String.t(), String.t()} | nil
  defp last_orchestrator_interaction(task_text, orch_messages) do
    orch_messages
    |> Enum.filter(&(&1.role == :assistant))
    |> Enum.flat_map(&match_interactions(&1.content, task_text))
    |> List.last()
  end

  @spec match_interactions([term()], String.t()) :: [{String.t(), String.t(), String.t()}]
  defp match_interactions(content, task_text) do
    Enum.flat_map(content, fn
      {:tool_call, _, tool, args} when tool in ["call_agent", "send_agent"] ->
        content_text = args["question"] || args["task"] || ""

        if content_text == task_text do
          [{tool, args["identifier"] || "worker", task_text}]
        else
          []
        end

      _ ->
        []
    end)
  end

  # The worker's last :user message is their current pending task text.
  @spec worker_task_text([Planck.Agent.Message.t()]) :: String.t()
  defp worker_task_text(messages) do
    case Enum.filter(messages, &(&1.role == :user)) |> List.last() do
      nil ->
        ""

      msg ->
        msg.content
        |> Enum.flat_map(fn
          {:text, t} -> [t]
          _ -> []
        end)
        |> Enum.join("")
    end
  end

  @spec truncate(String.t(), non_neg_integer()) :: String.t()
  defp truncate(text, max) do
    if String.length(text) > max,
      do: String.slice(text, 0, max) <> "…",
      else: text
  end

  # send_agent: done when the worker has called respond_agent after the last task.
  @spec worker_sent_response?([Planck.Agent.Message.t()]) :: boolean()
  defp worker_sent_response?(msgs) do
    msgs_after_last_user(msgs)
    |> Enum.any?(fn msg ->
      msg.role == :assistant &&
        Enum.any?(msg.content, fn
          {:tool_call, _, "respond_agent", _} -> true
          _ -> false
        end)
    end)
  end

  # call_agent: done when the worker has produced any assistant turn after the question.
  @spec worker_answered_ask?([Planck.Agent.Message.t()]) :: boolean()
  defp worker_answered_ask?(msgs) do
    msgs_after_last_user(msgs)
    |> Enum.any?(&(&1.role == :assistant))
  end

  @spec msgs_after_last_user([Planck.Agent.Message.t()]) :: [Planck.Agent.Message.t()]
  defp msgs_after_last_user(msgs) do
    case msgs
         |> Enum.with_index()
         |> Enum.filter(fn {m, _} -> m.role == :user end)
         |> List.last() do
      nil -> []
      {_, idx} -> Enum.drop(msgs, idx + 1)
    end
  end

  @spec tool_pool(ResourceStore.t()) :: [Planck.Agent.Tool.t()]
  defp tool_pool(store)

  defp tool_pool(%ResourceStore{} = store) do
    builtins() ++
      store.tools ++
      store.registered_tools ++
      rlcd_grantable_tools(store.available_models) ++
      skill_discovery_tools(store.invocable_skills)
  end

  @spec builtins() :: [Planck.Agent.Tool.t()]
  defp builtins do
    [BuiltinTools.read(), BuiltinTools.write(), BuiltinTools.edit(), BuiltinTools.bash()]
  end

  # ask/ask_files are grantable to workers (via TEAM.json tools or
  # spawn_agent tools:) under the same RLCD predicate that auto-includes
  # them for the orchestrator — see Planck.Agent.Tools.rlcd_tools/1.
  @spec rlcd_grantable_tools([Planck.AI.Model.t()]) :: [Planck.Agent.Tool.t()]
  defp rlcd_grantable_tools(available_models) do
    Planck.Agent.Tools.rlcd_tools(available_models)
  end

  @spec builtin_tool_names() :: [String.t()]
  defp builtin_tool_names, do: Enum.map(builtins(), & &1.name)

  @spec generate_id() :: session_id() | team_id() | agent_id()
  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  # ---------------------------------------------------------------------------
  # Private — configure_model helpers
  # ---------------------------------------------------------------------------

  @spec config_path_for(:local | :global) :: Path.t()
  defp config_path_for(:local), do: ".planck/config.json"
  defp config_path_for(:global), do: "~/.planck/config.json"

  @spec env_path_for(:local | :global) :: Path.t()
  defp env_path_for(:local), do: ".planck/.env"
  defp env_path_for(:global), do: "~/.planck/.env"

  @spec maybe_put(map(), String.t(), term()) :: map()
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Checks the currently loaded config (not the file being written — that
  # provider entry must already be persisted by the time a model referencing
  # it is configured) so this holds regardless of caller: the setup modal,
  # a future API, or a hand-written script calling configure_model/1 directly.
  @spec rlcd_provider_key?(String.t()) :: boolean()
  defp rlcd_provider_key?(provider_key) do
    match?(%{"type" => "typesafe"}, Map.get(Config.get().providers, provider_key))
  end

  @spec ensure_config_dir(Path.t()) :: :ok | {:error, File.posix()}
  defp ensure_config_dir(path) do
    case path |> Path.expand() |> Path.dirname() |> File.mkdir_p() do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_json_config(Path.t(), map()) :: :ok | {:error, term()}
  defp update_json_config(path, update) do
    expanded = Path.expand(path)

    existing =
      case File.read(expanded) do
        {:ok, content} -> Jason.decode!(content)
        {:error, :enoent} -> %{}
      end

    merged =
      Map.merge(existing, update, fn
        "models", old, new -> Enum.uniq_by(new ++ old, & &1["id"])
        "providers", old, new -> Map.merge(old, new)
        _key, _old, new -> new
      end)

    case Jason.encode(merged, pretty: true) do
      {:ok, json} -> File.write(expanded, json)
      error -> error
    end
  end

  @spec maybe_store_api_key(String.t(), String.t() | nil, String.t() | nil, Path.t()) ::
          :ok | {:error, term()}
  defp maybe_store_api_key(_type, key, _id, _env_path) when key in [nil, ""] do
    :ok
  end

  defp maybe_store_api_key(type, api_key, identifier, env_path) do
    case provider_api_key_env_var(type, identifier) do
      nil -> :ok
      env_var -> store_api_key(Planck.Headless.Secrets.resolve(), env_var, api_key, env_path)
    end
  end

  # EnvFile uses write_to/3 for scoped writes (local vs global path).
  defp store_api_key(Planck.Headless.Secrets.EnvFile, env_var, api_key, env_path) do
    Planck.Headless.Secrets.EnvFile.write_to(env_path, env_var, api_key)
  end

  # All other backends go through the dispatch layer (RPC to sidecar).
  # Falls back to EnvFile if the sidecar isn't connected yet —
  # AgentVault.maybe_migrate/0 will move it to the vault on connect.
  defp store_api_key(_mod, env_var, api_key, env_path) do
    case Planck.Headless.Secrets.store(env_var, api_key) do
      :ok ->
        :ok

      {:error, :sidecar_not_connected} ->
        Planck.Headless.Secrets.EnvFile.write_to(env_path, env_var, api_key)

      {:error, _} = error ->
        error
    end
  end

  @spec provider_api_key_env_var(String.t(), String.t() | nil) :: String.t() | nil
  defp provider_api_key_env_var("anthropic", _), do: "ANTHROPIC_API_KEY"
  defp provider_api_key_env_var("google", _), do: "GOOGLE_API_KEY"
  defp provider_api_key_env_var("openai", id) when is_binary(id) and id != "", do: "#{id}_API_KEY"
  defp provider_api_key_env_var("openai", _), do: "OPENAI_API_KEY"

  defp provider_api_key_env_var("typesafe", id) when is_binary(id) and id != "",
    do: "#{id}_API_KEY"

  defp provider_api_key_env_var("typesafe", _), do: "TYPESAFE_API_KEY"
  defp provider_api_key_env_var(_, _), do: nil
end
