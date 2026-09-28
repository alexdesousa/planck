defmodule Planck.Agent.Hooks.Persistence.Default do
  @moduledoc """
  The built-in persistence strategy: SQLite, via `Planck.Agent.Session` and
  `Planck.Agent.SessionStore`.

  This is what every agent used before pluggable persistence existed, and
  it's still what `persistence: nil` resolves to — a custom module changes
  nothing about this module's own behavior, and this module changes nothing
  about the SQLite format on disk.
  """

  use Planck.Agent.Hooks.Persistence

  alias Planck.Agent.{Session, SessionStore}

  @impl true
  def persist_message(session_id, agent_id, message),
    do: SessionStore.persist_message(session_id, agent_id, message)

  @impl true
  def persist_usage(session_id, agent_id, usage),
    do: SessionStore.persist_usage(session_id, agent_id, usage)

  @impl true
  def load_messages(session_id, agent_id, opts),
    do: SessionStore.load_messages(session_id, agent_id, opts)

  @impl true
  def flush_unpersisted(session_id, agent_id, messages),
    do: SessionStore.flush_unpersisted(session_id, agent_id, messages)

  @impl true
  def truncate_after(session_id, message_id),
    do: Session.truncate_after(session_id, message_id)

  @impl true
  def load_session_messages(session_id, _opts),
    do: Session.messages(session_id)
end
