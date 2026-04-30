defmodule Planck.Agent.AgentSpec do
  @moduledoc """
  Static, serializable agent definition.

  An `AgentSpec` is the shape used both by team members loaded from disk (via
  `Planck.Agent.Team`) and by the orchestrator's `spawn_agent` tool when it
  creates workers at runtime. It contains only serializable fields — no
  `execute_fn`. Tool wiring is merged in programmatically before starting the
  agent.

  ## Member-entry JSON schema

  This is the format for a single entry in a team's `members` list:

      {
        "type":          "builder",
        "name":          "Builder Joe",
        "description":   "Writes and edits code.",
        "provider":      "anthropic",
        "model_id":      "claude-sonnet-4-6",
        "system_prompt": "You are an expert builder.",
        "opts":          { "temperature": 0.7 },
        "tools":         ["read", "write", "edit", "bash"],
        "skills":        ["code_review", "refactor"]
      }

  Required fields are `type`, `provider`, `model_id`. Valid providers are
  derived from `Planck.AI.Model.providers/0`.

  `system_prompt` is either inline text or a path to a `.md`/`.txt` file
  resolved relative to a caller-provided `base_dir`. `tools` and `skills`
  are lists of names resolved against caller-provided pools at start time
  (see `to_start_opts/2`). When `skills` is non-empty, their descriptions
  are appended to the system prompt via `Planck.Agent.Skill.system_prompt_section/1`.

  ## Construction

      iex> AgentSpec.from_map(%{
      ...>   "type" => "builder",
      ...>   "provider" => "ollama",
      ...>   "model_id" => "llama3.2",
      ...>   "system_prompt" => "Build things."
      ...> })
      {:ok, %AgentSpec{...}}

      iex> AgentSpec.from_list(list_of_maps, base_dir: "/path/to/team")
      [%AgentSpec{...}, ...]
  """

  require Logger

  @typedoc """
  - `:type` — role identifier used for registry lookups and tool targeting (e.g. `"builder"`)
  - `:name` — human-readable label shown to other agents via `list_team`; defaults
    to `type` when not provided or empty
  - `:description` — one-line purpose shown to other agents via `list_team`
  - `:provider` — LLM provider atom (e.g. `:anthropic`, `:ollama`)
  - `:model_id` — model identifier within the provider (e.g. `"claude-sonnet-4-6"`)
  - `:system_prompt` — system prompt text sent to the model at the start of every turn
  - `:opts` — provider-specific options forwarded to the LLM call (e.g. `temperature:`)
  - `:tools` — tool names to resolve from a `tool_pool:` at start time (e.g. `["read", "bash"]`)
  - `:skills` — skill names to resolve from a `skill_pool:` at start time; when
    non-empty, their descriptions are appended to `system_prompt` in `to_start_opts/2`
  """
  @type t :: %__MODULE__{
          type: String.t(),
          name: String.t(),
          description: String.t() | nil,
          provider: atom(),
          model_id: String.t(),
          system_prompt: String.t(),
          opts: keyword(),
          tools: [String.t()],
          skills: [String.t()]
        }

  @enforce_keys [:type, :provider, :model_id, :system_prompt]
  defstruct [
    :type,
    :name,
    :description,
    :provider,
    :model_id,
    :system_prompt,
    opts: [],
    tools: [],
    skills: []
  ]

  @provider_atoms Map.new(Planck.AI.Model.providers(), fn p -> {Atom.to_string(p), p} end)

  @doc """
  Build an `AgentSpec` from a keyword list of validated fields.

  `name` defaults to `type` when not provided or empty — every agent has a
  human-readable label, and teams with multiple members of the same type are
  forced to assign explicit names (via `Team.load/1`'s name-uniqueness check).
  """
  @spec new(keyword()) :: t()
  def new(fields) do
    type = Keyword.fetch!(fields, :type)

    %__MODULE__{
      type: type,
      name: default_name(Keyword.get(fields, :name), type),
      description: Keyword.get(fields, :description),
      provider: Keyword.fetch!(fields, :provider),
      model_id: Keyword.fetch!(fields, :model_id),
      system_prompt: Keyword.fetch!(fields, :system_prompt),
      opts: Keyword.get(fields, :opts, []),
      tools: Keyword.get(fields, :tools, []),
      skills: Keyword.get(fields, :skills, [])
    }
  end

  @spec default_name(term(), String.t()) :: String.t()
  defp default_name(name, _type) when is_binary(name) and name != "", do: name
  defp default_name(_, type), do: type

  @doc """
  Convert a list of maps (as decoded from JSON) into a list of `AgentSpec` structs.

  Invalid entries are skipped with a warning; the rest are returned. Accepts
  `base_dir:` for resolving relative `system_prompt` file paths. Defaults to
  `File.cwd!()`.
  """
  @spec from_list([map()]) :: [t()]
  @spec from_list([map()], keyword()) :: [t()]
  def from_list(entries, opts \\ []) when is_list(entries) do
    base_dir = Keyword.get(opts, :base_dir, File.cwd!())

    Enum.flat_map(entries, fn entry ->
      case from_map(entry, base_dir) do
        {:ok, spec} ->
          [spec]

        {:error, reason} ->
          Logger.warning("[Planck.Agent.AgentSpec] skipping entry: #{reason} — #{inspect(entry)}")

          []
      end
    end)
  end

  @doc """
  Convert a single map into an `AgentSpec` struct.

  Returns `{:ok, spec}` or `{:error, reason}`. `system_prompt` values ending in
  `.md` or `.txt` are treated as file paths and read from disk relative to
  `base_dir`.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
  @spec from_map(map(), Path.t()) :: {:ok, t()} | {:error, String.t()}
  def from_map(entry, base_dir \\ ".")

  def from_map(
        %{"type" => type, "provider" => raw_provider, "model_id" => model_id} = entry,
        base_dir
      )
      when is_binary(type) and type != "" and is_binary(model_id) and model_id != "" do
    with {:ok, provider} <- parse_provider(raw_provider),
         {:ok, system_prompt} <- resolve_system_prompt(entry["system_prompt"], base_dir) do
      {:ok,
       new(
         type: type,
         name: entry["name"],
         description: entry["description"],
         provider: provider,
         model_id: model_id,
         system_prompt: system_prompt,
         opts: parse_opts(entry["opts"]),
         tools: parse_string_list(entry["tools"]),
         skills: parse_string_list(entry["skills"])
       )}
    end
  end

  def from_map(%{"type" => ""}, _base_dir), do: {:error, "type must not be empty"}

  def from_map(%{"type" => _}, _base_dir),
    do: {:error, "missing required field: provider or model_id"}

  def from_map(_, _base_dir), do: {:error, "missing required field: type"}

  @doc """
  Convert an `AgentSpec` to keyword options suitable for `Planck.Agent.start_link/1`.

  Accepts optional overrides: `tools:`, `tool_pool:`, `skill_pool:`, `team_id:`,
  `session_id:`, `available_models:`, `on_compact:`.

  ## Tool resolution

  When `spec.tools` is non-empty, tool names are resolved against `tool_pool:` (a list
  of `Tool.t()` structs). Unknown names are silently ignored. Any tools passed via
  `tools:` are appended after the resolved ones. When `spec.tools` is empty, `tools:`
  is used directly.

  ## Skill resolution

  When `spec.skills` is non-empty, skill names are resolved against `skill_pool:` (a
  list of `Skill.t()` structs). The resolved skills' descriptions are appended to
  `spec.system_prompt` via `Planck.Agent.Skill.system_prompt_section/1`. Unknown
  names are silently ignored. When `spec.skills` is empty, `system_prompt` passes
  through unchanged.

  ## Examples

      iex> AgentSpec.to_start_opts(spec, tool_pool: [read_tool, bash_tool], team_id: "team-1")
      [id: "...", type: "builder", tools: [read_tool], ...]
  """
  @spec to_start_opts(t(), keyword()) :: keyword()
  def to_start_opts(%__MODULE__{} = spec, overrides \\ []) do
    model = resolve_model!(spec.provider, spec.model_id)
    tools = resolve_tools(spec, overrides)
    system_prompt = assemble_system_prompt(spec, overrides)

    [
      id: generate_id(),
      type: spec.type,
      name: spec.name,
      description: spec.description,
      model: model,
      system_prompt: system_prompt,
      opts: spec.opts,
      tools: tools,
      team_id: Keyword.get(overrides, :team_id),
      session_id: Keyword.get(overrides, :session_id),
      available_models: Keyword.get(overrides, :available_models, []),
      on_compact: Keyword.get(overrides, :on_compact)
    ]
  end

  @spec resolve_tools(t(), keyword()) :: [Planck.Agent.Tool.t()]
  defp resolve_tools(spec, overrides) do
    case spec.tools do
      [] ->
        Keyword.get(overrides, :tools, [])

      names ->
        pool = Keyword.get(overrides, :tool_pool, [])
        pool_map = Map.new(pool, &{&1.name, &1})
        resolved = Enum.flat_map(names, &List.wrap(Map.get(pool_map, &1)))
        resolved ++ Keyword.get(overrides, :tools, [])
    end
  end

  @spec assemble_system_prompt(t(), keyword()) :: String.t()
  defp assemble_system_prompt(spec, overrides) do
    case spec.skills do
      [] ->
        spec.system_prompt

      names ->
        pool = Keyword.get(overrides, :skill_pool, [])
        pool_map = Map.new(pool, &{&1.name, &1})
        resolved = Enum.flat_map(names, &List.wrap(Map.get(pool_map, &1)))

        case Planck.Agent.Skill.system_prompt_section(resolved) do
          nil -> spec.system_prompt
          section -> spec.system_prompt <> "\n\n" <> section
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec parse_provider(String.t()) :: {:ok, atom()} | {:error, String.t()}
  defp parse_provider(p) do
    case Map.fetch(@provider_atoms, p) do
      {:ok, atom} ->
        {:ok, atom}

      :error ->
        {:error,
         "unknown provider #{inspect(p)}; valid: #{Enum.join(Map.keys(@provider_atoms), ", ")}"}
    end
  end

  @spec resolve_system_prompt(String.t() | nil, Path.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp resolve_system_prompt(nil, _base_dir), do: {:ok, ""}
  defp resolve_system_prompt("", _base_dir), do: {:ok, ""}

  defp resolve_system_prompt(value, base_dir) when is_binary(value) do
    if file_path?(value) do
      full_path = Path.join(base_dir, value)

      case File.read(full_path) do
        {:ok, content} -> {:ok, String.trim(content)}
        {:error, reason} -> {:error, "could not read system_prompt file #{full_path}: #{reason}"}
      end
    else
      {:ok, value}
    end
  end

  @spec file_path?(String.t()) :: boolean()
  defp file_path?(value) do
    String.ends_with?(value, ".md") or String.ends_with?(value, ".txt")
  end

  @spec parse_opts(map() | nil) :: keyword()
  defp parse_opts(nil), do: []

  defp parse_opts(map) when is_map(map) do
    Enum.flat_map(map, fn {k, v} ->
      try do
        [{String.to_existing_atom(k), v}]
      rescue
        ArgumentError ->
          Logger.warning("[Planck.Agent.AgentSpec] unknown opt key #{inspect(k)}, skipping")
          []
      end
    end)
  end

  defp parse_opts(_), do: []

  @spec parse_string_list(term()) :: [String.t()]
  defp parse_string_list(nil), do: []
  defp parse_string_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp parse_string_list(_), do: []

  @spec resolve_model!(atom(), String.t()) :: Planck.AI.Model.t()
  defp resolve_model!(provider, model_id) do
    case Planck.Agent.AIBehaviour.client().get_model(provider, model_id) do
      {:ok, model} -> model
      {:error, :not_found} -> raise ArgumentError, "model not found: #{provider}:#{model_id}"
    end
  end

  @spec generate_id() :: String.t()
  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
