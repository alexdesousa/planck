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
          skills: [Skill.t()],
          teams: %{String.t() => Team.t()},
          available_models: [Planck.AI.Model.t()]
        }

  defstruct tools: [], skills: [], teams: %{}, available_models: []

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
  @spec put_tools([Planck.AI.Tool.t()]) :: :ok
  def put_tools(tools) do
    GenServer.call(__MODULE__, {:put_tools, tools})
  end

  @doc "Clear all sidecar tools. Called by SidecarManager on nodedown."
  @spec clear_tools() :: :ok
  def clear_tools do
    GenServer.call(__MODULE__, :clear_tools)
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
  def handle_call(:reload, _from, _state) do
    {:reply, :ok, load_resources()}
  end

  @impl true
  def handle_call({:put_tools, tools}, _from, state) do
    {:reply, :ok, %{state | tools: tools}}
  end

  @impl true
  def handle_call(:clear_tools, _from, state) do
    {:reply, :ok, %{state | tools: []}}
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

  # Cloud models: static LLMDB catalog filtered by API key presence (no network).
  # Local/custom models: explicitly declared in Config.models!() and already
  # parsed to Planck.AI.Model structs by the Models Skogsra type — no network,
  # no timeouts.
  @spec detect_available_models() :: [Planck.AI.Model.t()]
  defp detect_available_models do
    cloud =
      [:anthropic, :openai, :google]
      |> Enum.filter(&api_key_set?/1)
      |> Enum.flat_map(&Planck.AI.list_models/1)

    cloud ++ Config.models!()
  end

  @spec api_key_set?(atom()) :: boolean()
  defp api_key_set?(:anthropic), do: Config.anthropic_api_key!() != nil
  defp api_key_set?(:openai), do: Config.openai_api_key!() != nil
  defp api_key_set?(:google), do: Config.google_api_key!() != nil
  defp api_key_set?(_), do: false
end
