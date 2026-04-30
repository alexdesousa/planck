defmodule Planck.Agent.AgentSpec do
  @moduledoc """
  Static agent definition loaded from a `Planck.Agent.TeamTemplate`.

  Contains only serializable fields — no `execute_fn`. The caller merges tools
  in programmatically before starting the agent.
  """

  @typedoc """
  A static, serializable agent definition.

  - `:type` — role identifier used for registry lookups and tool targeting (e.g. `"builder"`)
  - `:name` — human-readable label shown to other agents via `list_team`
  - `:description` — one-line purpose shown to other agents via `list_team`
  - `:provider` — LLM provider atom (e.g. `:anthropic`, `:ollama`)
  - `:model_id` — model identifier within the provider (e.g. `"claude-sonnet-4-6"`)
  - `:system_prompt` — system prompt text sent to the model at the start of every turn
  - `:opts` — provider-specific options forwarded to the LLM call (e.g. `temperature:`)
  - `:tools` — tool names to resolve from a `tool_pool:` at start time (e.g. `["read", "bash"]`)
  """
  @type t :: %__MODULE__{
          type: String.t(),
          name: String.t() | nil,
          description: String.t() | nil,
          provider: atom(),
          model_id: String.t(),
          system_prompt: String.t(),
          opts: keyword(),
          tools: [String.t()]
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
    tools: []
  ]

  @doc """
  Build an `AgentSpec` from a keyword list of validated fields.
  """
  @spec new(keyword()) :: t()
  def new(fields) do
    %__MODULE__{
      type: Keyword.fetch!(fields, :type),
      name: Keyword.get(fields, :name),
      description: Keyword.get(fields, :description),
      provider: Keyword.fetch!(fields, :provider),
      model_id: Keyword.fetch!(fields, :model_id),
      system_prompt: Keyword.fetch!(fields, :system_prompt),
      opts: Keyword.get(fields, :opts, []),
      tools: Keyword.get(fields, :tools, [])
    }
  end

  @doc """
  Convert an `AgentSpec` to keyword options suitable for `Planck.Agent.start_link/1`.

  Accepts optional overrides: `tools:`, `tool_pool:`, `team_id:`, `available_models:`,
  `on_compact:`.

  When `spec.tools` is non-empty, tool names are resolved against `tool_pool:` (a list
  of `Tool.t()` structs). Unknown names are silently ignored. Any tools passed via
  `tools:` are appended after the resolved ones.

  When `spec.tools` is empty, `tools:` is used directly (the previous behaviour).

  ## Examples

      iex> AgentSpec.to_start_opts(spec, tool_pool: [read_tool, bash_tool], team_id: "team-1")
      [id: "...", type: "builder", tools: [read_tool], ...]
  """
  @spec to_start_opts(t(), keyword()) :: keyword()
  def to_start_opts(%__MODULE__{} = spec, overrides \\ []) do
    model = resolve_model!(spec.provider, spec.model_id)

    tools =
      case spec.tools do
        [] ->
          Keyword.get(overrides, :tools, [])

        names ->
          pool = Keyword.get(overrides, :tool_pool, [])
          pool_map = Map.new(pool, &{&1.name, &1})
          resolved = Enum.flat_map(names, &List.wrap(Map.get(pool_map, &1)))
          resolved ++ Keyword.get(overrides, :tools, [])
      end

    [
      id: generate_id(),
      type: spec.type,
      name: spec.name,
      description: spec.description,
      model: model,
      system_prompt: spec.system_prompt,
      opts: spec.opts,
      tools: tools,
      team_id: Keyword.get(overrides, :team_id),
      session_id: Keyword.get(overrides, :session_id),
      available_models: Keyword.get(overrides, :available_models, []),
      on_compact: Keyword.get(overrides, :on_compact)
    ]
  end

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
