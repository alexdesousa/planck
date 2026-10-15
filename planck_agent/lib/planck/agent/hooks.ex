defmodule Planck.Agent.Hooks do
  @moduledoc """
  Hook configuration for a running agent.

  Holds the resolved hook module atoms and the sidecar node used for
  RPC dispatch.  All fields are set once in `init/1` and only read afterwards.

  The dispatch wrappers (`Planck.Agent.Hooks.Compactor`, `.Persistence`,
  `.Prompt`, `.TurnEnd`) take this struct (or its individual fields) instead
  of the full agent state.
  """

  @typedoc """
  Hooks information.
  """
  @type t :: %__MODULE__{
          compactor: module(),
          persistence: module() | nil,
          prompt: module() | nil,
          turn_end: module() | nil,
          turn_start: module() | nil,
          tool_start: module() | nil,
          tool_end: module() | nil,
          sidecar_node: atom() | nil
        }

  @doc false
  defstruct compactor: Planck.Agent.Hooks.Compactor.Default,
            persistence: nil,
            prompt: nil,
            turn_end: nil,
            turn_start: nil,
            tool_start: nil,
            tool_end: nil,
            sidecar_node: nil

  @doc "Build a `Hooks` struct from agent start opts."
  @spec build(keyword()) :: t()
  def build(opts)

  def build(opts) when is_list(opts) do
    %__MODULE__{
      compactor: opts[:compactor] || Planck.Agent.Hooks.Compactor.Default,
      persistence: opts[:persistence],
      prompt: opts[:prompt_hook],
      turn_end: opts[:turn_end_hook],
      turn_start: opts[:turn_start_hook],
      tool_start: opts[:tool_start_hook],
      tool_end: opts[:tool_end_hook],
      sidecar_node: opts[:sidecar_node]
    }
  end

  @doc """
  Convert a `Hooks` struct back to the start-opts keyword list form, so a
  spawned agent can inherit the parent's hook configuration verbatim.
  """
  @spec to_opts(t()) :: keyword()
  def to_opts(%__MODULE__{} = hooks) do
    [
      compactor: hooks.compactor,
      persistence: hooks.persistence,
      prompt_hook: hooks.prompt,
      turn_end_hook: hooks.turn_end,
      turn_start_hook: hooks.turn_start,
      tool_start_hook: hooks.tool_start,
      tool_end_hook: hooks.tool_end,
      sidecar_node: hooks.sidecar_node
    ]
  end

  @doc """
  Convert a `Hooks` struct into the string-keyed spec-map form that
  `Planck.Agent.AgentSpec.from_map/2` parses. Module atoms are reduced to
  their dotted names (the inverse of the spec's `resolve_hook_module/1`) and
  unset hooks are omitted, so a reconstructed dynamic worker inherits the
  orchestrator's hooks through the normal spec-parsing path. `sidecar_node`
  is intentionally excluded — it is resolved live, not from the spec.
  """
  @spec to_spec_args(t()) :: %{String.t() => String.t()}
  def to_spec_args(%__MODULE__{} = hooks) do
    [
      compactor: hooks.compactor,
      persistence: hooks.persistence,
      prompt_hook: hooks.prompt,
      turn_end_hook: hooks.turn_end,
      turn_start_hook: hooks.turn_start,
      tool_start_hook: hooks.tool_start,
      tool_end_hook: hooks.tool_end
    ]
    |> Enum.reject(fn {_key, module} -> is_nil(module) end)
    |> Map.new(fn {key, module} -> {to_string(key), module_name(module)} end)
  end

  @spec module_name(module()) :: String.t()
  defp module_name(module) do
    module |> inspect() |> String.replace_prefix("Elixir.", "")
  end
end
