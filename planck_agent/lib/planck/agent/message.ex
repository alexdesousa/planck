defmodule Planck.Agent.Message do
  @moduledoc """
  An agent-side message with metadata.

  Wraps `Planck.AI.Message` content parts with an id, timestamp, and metadata map.
  Messages with a `{:custom, atom()}` role are UI-only and filtered out before the
  context is sent to the LLM.
  """

  @type role :: :user | :assistant | :tool_result | {:custom, atom()}

  @type t :: %__MODULE__{
          id: String.t(),
          role: role(),
          content: [Planck.AI.Message.content_part()],
          timestamp: DateTime.t(),
          metadata: map()
        }

  @enforce_keys [:id, :role, :content, :timestamp]
  defstruct [:id, :role, :content, :timestamp, metadata: %{}]

  @doc """
  Build a new message with a generated id and current UTC timestamp.
  """
  @spec new(role(), [Planck.AI.Message.content_part()], map()) :: t()
  def new(role, content, metadata \\ %{}) do
    %__MODULE__{
      id: generate_id(),
      role: role,
      content: content,
      timestamp: DateTime.utc_now(),
      metadata: metadata
    }
  end

  @doc """
  Convert a list of agent messages to `Planck.AI.Message` structs.

  `{:custom, :summary}` messages are converted to `:user` so the LLM sees
  compacted context. All other `{:custom, _}` messages are dropped.
  """
  @spec to_ai_messages([t()]) :: [Planck.AI.Message.t()]
  def to_ai_messages(messages) do
    Enum.flat_map(messages, fn %__MODULE__{role: role, content: content} ->
      cond do
        match?({:custom, :summary}, role) ->
          [%Planck.AI.Message{role: :user, content: content}]

        match?({:custom, _}, role) ->
          []

        true ->
          [%Planck.AI.Message{role: role, content: content}]
      end
    end)
  end

  @spec generate_id() :: String.t()
  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
