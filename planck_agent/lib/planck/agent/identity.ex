defmodule Planck.Agent.Identity do
  @moduledoc """
  Identity fields for a running agent.

  Holds the agent's display metadata, team/session association, role, and
  configured model.  Most fields are immutable after `init/1`; only `model`
  changes at runtime via `change_model/2`.
  """

  alias Planck.AI.Model

  @typedoc """
  Agent role.
  """
  @type role :: :orchestrator | :worker

  @typedoc """
  An agent identity information.
  """
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          description: String.t() | nil,
          type: String.t() | nil,
          team_id: String.t() | nil,
          team_name: String.t() | nil,
          session_id: String.t() | nil,
          delegator_id: String.t() | nil,
          role: role(),
          model: Model.t() | nil
        }

  @doc false
  defstruct [
    :id,
    :name,
    :description,
    :type,
    :team_id,
    :team_name,
    :session_id,
    :delegator_id,
    :role,
    :model
  ]

  @doc "Build an `Identity` from agent start opts and a computed role."
  @spec build(keyword()) :: t()
  def build(opts)

  def build(opts) when is_list(opts) do
    role =
      if Enum.any?(opts[:tools] || [], &(&1.name == "spawn_agent")),
        do: :orchestrator,
        else: :worker

    %__MODULE__{
      id: Keyword.fetch!(opts, :id),
      name: Keyword.get(opts, :name),
      description: Keyword.get(opts, :description),
      type: Keyword.get(opts, :type),
      team_id: Keyword.get(opts, :team_id),
      team_name: Keyword.get(opts, :team_name),
      session_id: Keyword.get(opts, :session_id),
      delegator_id: Keyword.get(opts, :delegator_id),
      role: role,
      model: Keyword.fetch!(opts, :model)
    }
  end

  @doc "Sets the model."
  @spec set_model(t(), Model.t()) :: t()
  def set_model(identity, model), do: %{identity | model: model}
end
