defmodule Planck.Agent.Message do
  @moduledoc """
  An agent-side message with metadata.

  Wraps `Planck.AI.Message` content parts with an id, timestamp, and metadata map.
  Messages with a `{:custom, atom()}` role are UI-only and filtered out before the
  context is sent to the LLM.
  """

  @type role :: :user | :assistant | :tool_result | {:custom, atom()}

  @type t :: %__MODULE__{
          id: non_neg_integer() | String.t(),
          role: role(),
          content: [Planck.AI.Message.content_part()],
          timestamp: DateTime.t(),
          metadata: map()
        }

  @enforce_keys [:id, :role, :content, :timestamp]
  defstruct [:id, :role, :content, :timestamp, metadata: %{}]

  @doc """
  Estimate the token count for a list of messages using a character-based
  approximation (4 characters ≈ 1 token). Fast enough for real-time display
  and compaction threshold checks; not a substitute for model tokenization.
  """
  @spec estimate_tokens([t()]) :: non_neg_integer()
  def estimate_tokens(messages) do
    Enum.reduce(messages, 0, fn msg, acc ->
      Enum.reduce(msg.content, acc, fn
        {:text, text}, a -> a + div(String.length(text), 4)
        {:thinking, text}, a -> a + div(String.length(text), 4)
        {:tool_result, _id, value}, a -> a + div(String.length(value), 4)
        _other, a -> a
      end)
    end)
  end

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
    Enum.flat_map(messages, fn
      %__MODULE__{role: {:custom, :summary}, content: content} ->
        [%Planck.AI.Message{role: :user, content: content}]

      %__MODULE__{role: {:custom, :agent_response}, content: content, metadata: metadata} ->
        [%Planck.AI.Message{role: :user, content: agent_response(content, metadata)}]

      %__MODULE__{role: {:custom, _}} ->
        []

      %__MODULE__{role: role, content: content} ->
        [%Planck.AI.Message{role: role, content: content}]
    end)
  end

  @spec generate_id() :: String.t()
  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  @spec agent_response([Planck.AI.Message.content_part()], map()) :: [Planck.AI.Message.t()]
  defp agent_response(content, metadata)

  defp agent_response(content, %{sender_name: name}) when not is_nil(name) do
    Enum.map(content, fn
      {:text, text} -> {:text, "Response from #{name}: #{text}"}
      part -> part
    end)
  end

  defp agent_response(content, _metadata) do
    content
  end
end
