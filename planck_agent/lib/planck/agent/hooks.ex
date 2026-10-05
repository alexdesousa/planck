defmodule Planck.Agent.Hooks do
  @moduledoc """
  Hook configuration for a running agent.

  Holds the four resolved hook module atoms and the sidecar node used for
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
          sidecar_node: atom() | nil
        }

  @doc false
  defstruct compactor: Planck.Agent.Hooks.Compactor.Default,
            persistence: nil,
            prompt: nil,
            turn_end: nil,
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
      sidecar_node: opts[:sidecar_node]
    }
  end

  @doc "Return `before_prompt/1` injection text, or `nil`."
  @spec before_prompt(t(), String.t() | nil) :: String.t() | nil
  def before_prompt(hooks, session_id)

  def before_prompt(%__MODULE__{prompt: module, sidecar_node: sidecar_node}, session_id) do
    __MODULE__.Prompt.before_prompt(module, session_id, sidecar_node)
  end

  @doc "Return `after_prompt/1` injection text, or `nil`."
  @spec after_prompt(t(), String.t() | nil) :: String.t() | nil
  def after_prompt(hooks, session_id)

  def after_prompt(%__MODULE__{prompt: module, sidecar_node: sidecar_node}, session_id) do
    __MODULE__.Prompt.after_prompt(module, session_id, sidecar_node)
  end
end
