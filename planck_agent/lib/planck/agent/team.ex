defmodule Planck.Agent.Team do
  @moduledoc """
  A named collection of agents that share a `team_id` and can address each
  other via the inter-agent tools.

  Teams can be hydrated from a directory on disk (static) or constructed
  in-memory by an orchestrator using `spawn_agent` (dynamic). Both paths
  produce the same struct.

  ## Directory layout

      .planck/teams/
        elixir-dev-workflow/
          TEAM.json                  # required — member list and metadata
          members/
            orchestrator.md          # system prompt for the orchestrator
            planner.md
            builder.md

  Each member's system prompt lives in `members/<name>.md` by convention, where
  `<name>` is the member's `name` (which defaults to `type` when not set).

  ## TEAM.json format

      {
        "name":        "elixir-dev-workflow",
        "description": "Plan, build, and test Elixir changes.",
        "members": [
          {
            "type":          "orchestrator",
            "provider":      "anthropic",
            "model_id":      "claude-sonnet-4-6",
            "system_prompt": "members/orchestrator.md"
          },
          {
            "type":          "builder",
            "provider":      "anthropic",
            "model_id":      "claude-sonnet-4-6",
            "system_prompt": "members/builder.md",
            "tools":         ["read", "write", "edit", "bash"],
            "skills":        ["refactor"]
          }
        ]
      }

  Member entries follow the schema documented on `Planck.Agent.AgentSpec`.
  Exactly one member must have `"type": "orchestrator"`; the rest are workers.
  All `system_prompt` file paths are resolved relative to the team directory.

  Tools and skills are global (loaded by `planck_headless` from
  `~/.planck/tools` and `~/.planck/skills`). Each member declares which of
  them it should see via the `"tools"` and `"skills"` arrays; names are
  resolved against the global pool at agent-start time.
  """

  require Logger

  alias Planck.Agent.AgentSpec

  @team_file "TEAM.json"
  @orchestrator_type "orchestrator"

  @typedoc """
  A team definition.

  - `:id` — team_id generated at materialization; `nil` before `start_session`.
  - `:alias` — folder name for static teams; `nil` for dynamic teams.
  - `:source` — `:filesystem` or `:dynamic`.
  - `:name` — informational label from TEAM.json.
  - `:description` — one-line purpose shown in team listings.
  - `:dir` — absolute path to the team directory, `nil` for dynamic teams.
  - `:members` — agent specs; exactly one has `type: "orchestrator"`.
  """
  @type t :: %__MODULE__{
          id: String.t() | nil,
          alias: String.t() | nil,
          source: :filesystem | :dynamic,
          name: String.t() | nil,
          description: String.t() | nil,
          dir: Path.t() | nil,
          members: [AgentSpec.t()]
        }

  @enforce_keys [:source, :members]
  defstruct id: nil,
            alias: nil,
            source: :filesystem,
            name: nil,
            description: nil,
            dir: nil,
            members: []

  @doc """
  Load a team from a directory containing a `TEAM.json` file.

  Resolves member `system_prompt` paths relative to the team directory.

  Returns `{:ok, team}` or `{:error, reason}`.
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def load(dir) do
    expanded = Path.expand(dir)
    team_file = Path.join(expanded, @team_file)

    with :ok <- ensure_dir(expanded),
         {:ok, content} <- read_team_file(team_file),
         {:ok, data} <- decode_json(content, team_file),
         {:ok, members_data, name, description} <- parse_team(data, team_file),
         {:ok, members} <- parse_members(members_data, expanded),
         :ok <- validate_members(members, team_file) do
      {:ok,
       %__MODULE__{
         alias: Path.basename(expanded),
         source: :filesystem,
         name: name,
         description: description,
         dir: expanded,
         members: members
       }}
    end
  end

  @doc """
  Build a dynamic team from a single orchestrator spec.

  Dynamic teams have no filesystem footprint. Workers may be added later via
  the orchestrator's `spawn_agent` tool. Used both when `start_session/1`
  runs with no `template:` (team of one) and when the orchestrator grows
  the team at runtime.
  """
  @spec dynamic(AgentSpec.t()) :: t()
  def dynamic(%AgentSpec{type: @orchestrator_type} = orchestrator) do
    %__MODULE__{source: :dynamic, members: [orchestrator]}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec ensure_dir(Path.t()) :: :ok | {:error, String.t()}
  defp ensure_dir(dir) do
    if File.dir?(dir), do: :ok, else: {:error, "team directory not found: #{dir}"}
  end

  @spec read_team_file(Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp read_team_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  @spec decode_json(String.t(), Path.t()) :: {:ok, term()} | {:error, String.t()}
  defp decode_json(content, path) do
    case Jason.decode(content) do
      {:ok, data} ->
        {:ok, data}

      {:error, %Jason.DecodeError{} = e} ->
        {:error, "invalid JSON in #{path}: #{Exception.message(e)}"}
    end
  end

  @spec parse_team(term(), Path.t()) ::
          {:ok, [map()], String.t() | nil, String.t() | nil} | {:error, String.t()}
  defp parse_team(%{"members" => members} = data, _path)
       when is_list(members) and members != [] do
    {:ok, members, string_or_nil(data["name"]), string_or_nil(data["description"])}
  end

  defp parse_team(%{"members" => []}, path),
    do: {:error, "#{path}: members must not be empty"}

  defp parse_team(%{"members" => _}, path),
    do: {:error, "#{path}: members must be an array"}

  defp parse_team(_, path),
    do: {:error, "#{path}: missing required field 'members'"}

  @spec string_or_nil(term()) :: String.t() | nil
  defp string_or_nil(v) when is_binary(v) and v != "", do: v
  defp string_or_nil(_), do: nil

  @spec parse_members([map()], Path.t()) :: {:ok, [AgentSpec.t()]} | {:error, String.t()}
  defp parse_members(entries, base_dir) do
    case AgentSpec.from_list(entries, base_dir: base_dir) do
      [] -> {:error, "no valid members in TEAM.json at #{base_dir}"}
      specs -> {:ok, specs}
    end
  end

  @spec validate_members([AgentSpec.t()], Path.t()) :: :ok | {:error, String.t()}
  defp validate_members(members, path) do
    with :ok <- validate_single_orchestrator(members, path) do
      validate_unique_names(members, path)
    end
  end

  @spec validate_single_orchestrator([AgentSpec.t()], Path.t()) :: :ok | {:error, String.t()}
  defp validate_single_orchestrator(members, path) do
    case Enum.count(members, &(&1.type == @orchestrator_type)) do
      1 ->
        :ok

      0 ->
        {:error, "#{path}: team must have exactly one member with type \"orchestrator\""}

      n ->
        {:error, "#{path}: team must have exactly one orchestrator, found #{n}"}
    end
  end

  @spec validate_unique_names([AgentSpec.t()], Path.t()) :: :ok | {:error, String.t()}
  defp validate_unique_names(members, path) do
    names = Enum.map(members, & &1.name)
    duplicates = names -- Enum.uniq(names)

    case duplicates do
      [] ->
        :ok

      [dup | _] ->
        {:error,
         "#{path}: duplicate member name #{inspect(dup)} " <>
           "(names default to type; give explicit names to disambiguate same-type members)"}
    end
  end
end
