defmodule Planck.Agent.TurnState do
  @moduledoc """
  Tracks the agent's turn counter and checkpoint stack.

  `:index` increments on every new LLM turn. `:checkpoints` is a
  reversed list of message-list lengths recorded at the start of each
  user prompt — used to detect messages appended mid-turn and to rebuild
  state after a session reload.
  """

  @typedoc """
  - `:index` — monotonically increasing turn counter
  - `:checkpoints` — reversed stack of message-count checkpoints, one per user prompt
  """
  @type t :: %__MODULE__{
          index: non_neg_integer(),
          checkpoints: [non_neg_integer()]
        }

  defstruct index: 0, checkpoints: []

  @doc "Return a fresh turn state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Increment the turn counter."
  @spec advance(t()) :: t()
  def advance(turn_state)

  def advance(%__MODULE__{} = ts), do: %{ts | index: ts.index + 1}

  @doc "Push a checkpoint (current message-list length) onto the stack."
  @spec push_checkpoint(t(), non_neg_integer()) :: t()
  def push_checkpoint(turn_state, length)

  def push_checkpoint(%__MODULE__{} = ts, length),
    do: %{ts | checkpoints: [length | ts.checkpoints]}

  @doc "Rebuild checkpoints from a message list, preserving the current index."
  @spec rebuild_checkpoints(t(), [term()]) :: t()
  def rebuild_checkpoints(turn_state, messages)

  def rebuild_checkpoints(%__MODULE__{} = ts, messages) do
    checkpoints =
      messages
      |> Enum.with_index()
      |> Enum.filter(fn {msg, _} -> msg.role == :user end)
      |> Enum.map(fn {_, idx} -> idx end)
      |> Enum.reverse()

    %{ts | checkpoints: checkpoints}
  end
end
