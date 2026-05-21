defmodule Planck.Agent.SessionStore do
  @moduledoc """
  Database operations for an agent's conversation history.

  All functions that persist or load messages from the session SQLite database
  live here. `Planck.Agent` calls these helpers and applies the returned data
  to its own state — there is no state mutation in this module.
  """

  require Logger

  alias Planck.Agent.{Message, Session, Usage}

  @doc """
  Persist `msg` to the session and return it with its database ID set.

  Returns `msg` unchanged for ephemeral agents (`session_id: nil`) or when
  the session append fails.
  """
  @spec persist_message(String.t() | nil, String.t(), Message.t()) :: Message.t()
  def persist_message(nil, _agent_id, msg), do: msg

  def persist_message(session_id, agent_id, msg) do
    case Session.append(session_id, agent_id, msg) do
      nil -> msg
      db_id -> %{msg | id: db_id}
    end
  end

  @doc """
  Save accumulated usage and cost for the agent to the session metadata store.

  No-op for ephemeral agents (`session_id: nil`).
  """
  @spec persist_usage(String.t() | nil, String.t(), Usage.t()) :: :ok
  def persist_usage(nil, _agent_id, _usage), do: :ok

  def persist_usage(session_id, agent_id, %Usage{} = usage) do
    data =
      Jason.encode!(%{
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens,
        cost: usage.cost
      })

    Session.save_metadata(session_id, %{"agent_usage:#{agent_id}" => data})
  end

  @doc """
  Load the message history for `agent_id` from `session_id`.

  Returns `{:ok, messages}` on success, or `:error` when the session is
  unavailable.

  Pass `strip_orphans: true` to remove the last message if it is an assistant
  turn with unanswered tool calls — this repairs state after a crash.
  """
  @spec load_messages(String.t(), String.t(), keyword()) ::
          {:ok, [Message.t()]} | :error
  def load_messages(session_id, agent_id, opts \\ []) do
    case Session.messages(session_id, agent_id: agent_id) do
      {:ok, rows} ->
        rows =
          if opts[:strip_orphans],
            do: strip_orphaned_tool_call(session_id, rows),
            else: rows

        {:ok, Enum.map(rows, & &1.message)}

      _ ->
        :error
    end
  end

  @doc """
  Persist any in-memory messages that have not yet been written to the session.

  Unpersisted messages are identified by a binary (UUID) id — messages written
  to the DB receive an integer id. Returns `:flushed` when at least one message
  was written, `:noop` when all messages were already persisted.

  Always returns `:noop` for ephemeral agents (`session_id: nil`).
  """
  @spec flush_unpersisted(String.t() | nil, String.t(), [Message.t()]) :: :flushed | :noop
  def flush_unpersisted(nil, _agent_id, _messages), do: :noop

  def flush_unpersisted(session_id, agent_id, messages) do
    unpersisted = Enum.filter(messages, &is_binary(&1.id))

    if unpersisted == [] do
      :noop
    else
      Enum.each(unpersisted, &Session.append(session_id, agent_id, &1))
      :flushed
    end
  end

  @doc """
  Remove the last row from `rows` if it is an orphaned tool-call turn.

  A turn is orphaned when the last assistant message contains tool calls but
  has no following tool-result message — the agent crashed mid-execution.
  The orphan is also truncated from the database when `session_id` is non-nil.
  """
  @spec strip_orphaned_tool_call(String.t() | nil, [map()]) :: [map()]
  def strip_orphaned_tool_call(_session_id, []), do: []

  def strip_orphaned_tool_call(session_id, rows) do
    last = List.last(rows)

    orphaned? =
      last.message.role == :assistant and
        Enum.any?(last.message.content, &match?({:tool_call, _, _, _}, &1))

    if orphaned? do
      Logger.warning("[Planck.Agent] stripping orphaned tool-call turn (db_id=#{last.db_id})")
      if session_id, do: Session.truncate_after(session_id, last.db_id)
      Enum.drop(rows, -1)
    else
      rows
    end
  end
end
