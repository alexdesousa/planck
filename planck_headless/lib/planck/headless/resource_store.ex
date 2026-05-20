defmodule Planck.Headless.ResourceStore do
  @moduledoc """
  GenServer started at application boot that holds the loaded resources —
  the single source of truth for skills, teams, and available models.

  Resources are loaded once at startup from the directories configured in
  `Planck.Headless.Config`. New sessions pick up whatever is in the store
  at the time they start; in-flight sessions are not affected by reloads.

  ## Reload

      Planck.Headless.ResourceStore.reload()

  Triggers a synchronous reload of tools, skills, and teams from disk.
  Available models are also re-resolved.
  """

  use GenServer

  require Logger

  alias Planck.Agent.{Skill, Team}
  alias Planck.Headless.Config

  @type t :: %__MODULE__{
          tools: [Planck.Agent.Tool.t()],
          registered_tools: [Planck.Agent.Tool.t()],
          skills: [Skill.t()],
          teams: %{String.t() => Team.t()},
          available_models: [Planck.AI.Model.t()]
        }

  defstruct tools: [],
            registered_tools: [],
            skills: [],
            teams: %{},
            available_models: [],
            on_reload: []

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Start the ResourceStore under its supervisor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return the full resource store state."
  @spec get() :: t()
  def get do
    GenServer.call(__MODULE__, :get)
  end

  @doc """
  Reload tools, skills, and teams from disk.

  In-flight sessions keep their original resources. Only new sessions
  created after this call will see the updated resources.
  """
  @spec reload() :: :ok
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc "Replace the sidecar tool list. Called by SidecarManager on nodeup."
  @spec put_tools([Planck.Agent.Tool.t()]) :: :ok
  def put_tools(tools) do
    GenServer.call(__MODULE__, {:put_tools, tools})
  end

  @doc "Clear all sidecar tools. Called by SidecarManager on nodedown."
  @spec clear_tools() :: :ok
  def clear_tools do
    GenServer.call(__MODULE__, :clear_tools)
  end

  @doc "Register a local-node tool globally. Replaces any existing tool with the same name."
  @spec register_tool(Planck.Agent.Tool.t()) :: :ok
  def register_tool(tool) do
    GenServer.call(__MODULE__, {:register_tool, tool})
  end

  @doc "Remove a globally registered tool by name. No-op if not found."
  @spec unregister_tool(String.t()) :: :ok
  def unregister_tool(name) do
    GenServer.call(__MODULE__, {:unregister_tool, name})
  end

  @doc """
  Register a zero-arity function to be called after every `reload/0`.

  Useful for packages that sit above `planck_headless` in the dependency tree
  and need to invalidate their own caches (e.g. Skogsra config values) when
  files change on disk. Callbacks are preserved across reloads.
  """
  @spec register_on_reload((-> any())) :: :ok
  def register_on_reload(fun) when is_function(fun, 0) do
    GenServer.call(__MODULE__, {:register_on_reload, fun})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, load_resources()}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    Config.JsonBinding.invalidate()
    Config.EnvBinding.invalidate()
    Enum.each(state.on_reload, & &1.())
    new_state = load_resources()

    {:reply, :ok,
     %{
       new_state
       | on_reload: state.on_reload,
         registered_tools: state.registered_tools,
         tools: state.tools
     }}
  end

  @impl true
  def handle_call({:put_tools, tools}, _from, state) do
    {:reply, :ok, %{state | tools: tools}}
  end

  @impl true
  def handle_call(:clear_tools, _from, state) do
    {:reply, :ok, %{state | tools: []}}
  end

  @impl true
  def handle_call({:register_tool, tool}, _from, state) do
    updated = Enum.reject(state.registered_tools, &(&1.name == tool.name)) ++ [tool]
    {:reply, :ok, %{state | registered_tools: updated}}
  end

  @impl true
  def handle_call({:unregister_tool, name}, _from, state) do
    updated = Enum.reject(state.registered_tools, &(&1.name == name))
    {:reply, :ok, %{state | registered_tools: updated}}
  end

  @impl true
  def handle_call({:register_on_reload, fun}, _from, state) do
    {:reply, :ok, %{state | on_reload: state.on_reload ++ [fun]}}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec load_resources() :: t()
  defp load_resources do
    skills = Skill.load_all(Config.skills_dirs!())
    teams = load_teams(Config.teams_dirs!())
    available_models = detect_available_models()

    %__MODULE__{
      skills: skills,
      teams: teams,
      available_models: available_models
    }
  end

  @spec load_teams([Path.t()]) :: %{String.t() => Team.t()}
  defp load_teams(dirs) do
    dirs
    |> Enum.flat_map(&scan_teams_dir/1)
    |> Enum.reduce(%{}, fn {alias, team}, acc ->
      # Project-local (later in the list) wins on collision.
      Map.put(acc, alias, team)
    end)
  end

  @spec scan_teams_dir(Path.t()) :: [{String.t(), Team.t()}]
  defp scan_teams_dir(dir) do
    expanded = Path.expand(dir)

    case File.ls(expanded) do
      {:error, _} -> []
      {:ok, entries} -> Enum.flat_map(entries, &load_team_entry(expanded, &1))
    end
  end

  @spec load_team_entry(Path.t(), String.t()) :: [{String.t(), Team.t()}]
  defp load_team_entry(dir, entry) do
    team_dir = Path.join(dir, entry)

    if File.dir?(team_dir) do
      case Team.load(team_dir) do
        {:ok, team} ->
          [{team.alias, team}]

        {:error, reason} ->
          Logger.warning("[Planck.Headless.ResourceStore] skipping #{team_dir}: #{reason}")
          []
      end
    else
      []
    end
  end

  # Available models are derived entirely from the providers map + models list
  # declared in config.json. The LLMDB catalog is no longer included — only
  # explicitly configured models are available.
  @spec detect_available_models() :: [Planck.AI.Model.t()]
  defp detect_available_models do
    Planck.AI.Config.from_config(Config.providers!(), Config.models!())
  end
end
