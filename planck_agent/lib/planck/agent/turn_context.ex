defmodule Planck.Agent.TurnContext do
  @moduledoc """
  Pure queries over an agent's in-memory message history.

  These functions inspect lists of `Planck.Agent.Message` values without
  touching the database or modifying any state.
  """

  alias Planck.Agent.Message

  @doc """
  Return the messages since the last `{:custom, :summary}` checkpoint.

  When no summary exists the full list is returned. When one exists the
  summary message itself is included as the head.
  """
  @spec messages_since_last_summary([Message.t()]) :: [Message.t()]
  def messages_since_last_summary(messages) do
    messages
    |> Enum.reverse()
    |> Enum.split_while(&(not match?(%Message{role: {:custom, :summary}}, &1)))
    |> case do
      {_tail_rev, []} -> messages
      {tail_rev, [%Message{} = summary | _]} -> [summary | Enum.reverse(tail_rev)]
    end
  end

  @doc """
  Return `true` if any user or agent-response message arrived at or after
  `stream_start` (i.e. was appended during streaming and not yet seen by the LLM).
  """
  @spec has_pending_input?([Message.t()], non_neg_integer()) :: boolean()
  def has_pending_input?(messages, stream_start) do
    messages
    |> Enum.drop(stream_start)
    |> Enum.any?(fn
      %{role: :user} -> true
      %{role: {:custom, :agent_response}} -> true
      _ -> false
    end)
  end
end
