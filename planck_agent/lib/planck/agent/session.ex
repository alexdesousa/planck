defmodule Planck.Agent.Session do
  @moduledoc """
  Persistent session store backed by SQLite.

  One GenServer per session, registered globally so any node in the cluster
  can append messages or query history via transparent GenServer calls.
  Each session writes to `sessions_dir/session_id.db`.

  ## Usage

      {:ok, _pid} = Planck.Agent.Session.start("my-session")

      :ok = Planck.Agent.Session.append("my-session", "agent-1", message)

      {:ok, rows} = Planck.Agent.Session.messages("my-session")
      {:ok, rows} = Planck.Agent.Session.messages("my-session", agent_id: "agent-1")

  Each row is `%{agent_id: String.t(), message: Message.t(), inserted_at: integer()}`.

  Messages are serialized with `:erlang.term_to_binary/1` and read back with
  `:erlang.binary_to_term/2` (`:safe` — no new atoms created from DB content).

  ## Distribution

  Sessions are registered via `:global` as `{:session, session_id}`. Any node
  in the Erlang cluster can call `append/3` or `messages/2` — the call is routed
  transparently to the node that owns the session's SQLite file.

  Configure the default storage directory via:

      config :planck_agent, :sessions_dir, "/path/to/sessions"

  ## Pagination

  Messages with role `{:custom, :summary}` are stored as checkpoints
  (`checkpoint = 1` in the DB). Two functions support cursor-based pagination
  anchored on these checkpoints:

  - `messages_from_latest_checkpoint/2` — initial load: latest checkpoint +
    everything after. Returns `{:ok, rows, checkpoint_id | nil}`.
  - `messages_before_checkpoint/3` — load more: the previous chapter.
    Returns `{:ok, rows, prev_checkpoint_id | nil}`. `nil` means no more history.

  Pass the returned `checkpoint_id` integer back as the cursor for the next page.
  """

  use GenServer

  require Logger

  alias Planck.Agent.Message

  @type session_id :: String.t()

  defstruct [:id, :conn]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Start a session under the SessionSupervisor."
  @spec start(session_id(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(session_id, opts \\ []) do
    DynamicSupervisor.start_child(
      Planck.Agent.SessionSupervisor,
      {__MODULE__, Keyword.put(opts, :id, session_id)}
    )
  end

  @doc "Stop a running session."
  @spec stop(session_id()) :: :ok | {:error, :not_found | term()}
  def stop(session_id) do
    case whereis(session_id) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(Planck.Agent.SessionSupervisor, pid)
      error -> error
    end
  end

  @doc """
  Append a message to the session. Fire-and-forget — silently no-ops if the
  session is not found.
  """
  @spec append(session_id(), String.t(), Message.t()) :: :ok
  def append(session_id, agent_id, message) do
    case whereis(session_id) do
      {:ok, pid} -> GenServer.cast(pid, {:append, agent_id, message})
      _ -> :ok
    end
  end

  @doc """
  Retrieve messages for a session in insertion order.

  Options:
  - `agent_id:` — filter to messages from a specific agent
  """
  @spec messages(session_id(), keyword()) :: {:ok, [map()]} | {:error, :not_found}
  def messages(session_id, opts \\ []) do
    case whereis(session_id) do
      {:ok, pid} -> GenServer.call(pid, {:messages, opts})
      error -> error
    end
  end

  @doc """
  Return the latest summary checkpoint and all messages after it.

  If no checkpoint exists, returns all messages from the beginning.
  The `checkpoint_id` in the return tuple is the DB row id of the checkpoint —
  pass it to `messages_before_checkpoint/3` to load the previous page.

  Options:
  - `agent_id:` — filter to a specific agent
  """
  @spec messages_from_latest_checkpoint(session_id(), keyword()) ::
          {:ok, [map()], non_neg_integer() | nil} | {:error, :not_found}
  def messages_from_latest_checkpoint(session_id, opts \\ []) do
    case whereis(session_id) do
      {:ok, pid} -> GenServer.call(pid, {:messages_from_latest_checkpoint, opts})
      error -> error
    end
  end

  @doc """
  Return the chapter before a given checkpoint: the previous summary checkpoint
  and all messages between it and `checkpoint_id`.

  Returns `{:ok, rows, prev_checkpoint_id | nil}`. When `prev_checkpoint_id` is
  `nil` there is no further history to load.

  Options:
  - `agent_id:` — filter to a specific agent
  """
  @spec messages_before_checkpoint(session_id(), non_neg_integer(), keyword()) ::
          {:ok, [map()], non_neg_integer() | nil} | {:error, :not_found}
  def messages_before_checkpoint(session_id, checkpoint_id, opts \\ []) do
    case whereis(session_id) do
      {:ok, pid} -> GenServer.call(pid, {:messages_before_checkpoint, checkpoint_id, opts})
      error -> error
    end
  end

  @doc """
  Delete messages for `agent_id` beyond the first `keep_count`, in insertion order.

  Used by `Planck.Agent.Agent.rewind/2` to sync the store when the agent's
  in-memory history is trimmed. Fire-and-forget cast.
  """
  @spec truncate_agent(session_id(), String.t(), non_neg_integer()) :: :ok
  def truncate_agent(session_id, agent_id, keep_count) do
    case whereis(session_id) do
      {:ok, pid} -> GenServer.cast(pid, {:truncate_agent, agent_id, keep_count})
      _ -> :ok
    end
  end

  @doc "Resolve a session id to its pid via `:global`."
  @spec whereis(session_id()) :: {:ok, pid()} | {:error, :not_found}
  def whereis(session_id) do
    case :global.whereis_name({:session, session_id}) do
      :undefined -> {:error, :not_found}
      pid -> {:ok, pid}
    end
  end

  @doc false
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: {:global, {:session, id}})
  end

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.fetch!(opts, :id),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    dir = Keyword.get(opts, :dir, sessions_dir())

    File.mkdir_p!(dir)
    path = Path.join(dir, "#{id}.db")

    {:ok, conn} = Exqlite.Sqlite3.open(path)
    :ok = create_tables(conn)

    {:ok, %__MODULE__{id: id, conn: conn}}
  end

  @impl true
  def handle_cast({:append, agent_id, message}, state) do
    :ok = insert_message(state.conn, agent_id, message)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:truncate_agent, agent_id, keep_count}, state) do
    :ok = do_truncate_agent(state.conn, agent_id, keep_count)
    {:noreply, state}
  end

  @impl true
  def handle_call({:messages, opts}, _from, state) do
    {:reply, query_messages(state.conn, opts), state}
  end

  @impl true
  def handle_call({:messages_from_latest_checkpoint, opts}, _from, state) do
    agent_id = Keyword.get(opts, :agent_id)
    checkpoint_id = find_latest_checkpoint(state.conn, agent_id)
    rows = query_rows_from(state.conn, checkpoint_id, agent_id)
    {:reply, {:ok, rows, checkpoint_id}, state}
  end

  @impl true
  def handle_call({:messages_before_checkpoint, checkpoint_id, opts}, _from, state) do
    agent_id = Keyword.get(opts, :agent_id)
    prev_id = find_prev_checkpoint(state.conn, checkpoint_id, agent_id)
    rows = query_rows_between(state.conn, prev_id, checkpoint_id, agent_id)
    {:reply, {:ok, rows, prev_id}, state}
  end

  @impl true
  def terminate(_reason, %{conn: conn}) when not is_nil(conn) do
    Exqlite.Sqlite3.close(conn)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec create_tables(Exqlite.Sqlite3.db()) :: :ok
  defp create_tables(conn) do
    :ok =
      Exqlite.Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS messages (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        agent_id    TEXT    NOT NULL,
        data        BLOB    NOT NULL,
        inserted_at INTEGER NOT NULL,
        checkpoint  INTEGER NOT NULL DEFAULT 0
      )
      """)

    :ok
  end

  @spec insert_message(Exqlite.Sqlite3.db(), String.t(), Message.t()) :: :ok
  defp insert_message(conn, agent_id, message) do
    data = :erlang.term_to_binary(message)
    now = System.system_time(:second)
    checkpoint = if match?({:custom, :summary}, message.role), do: 1, else: 0

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(conn, """
      INSERT INTO messages (agent_id, data, inserted_at, checkpoint) VALUES (?1, ?2, ?3, ?4)
      """)

    :ok = Exqlite.Sqlite3.bind(stmt, [agent_id, data, now, checkpoint])
    :done = Exqlite.Sqlite3.step(conn, stmt)
    :ok = Exqlite.Sqlite3.release(conn, stmt)
    :ok
  end

  @spec query_messages(Exqlite.Sqlite3.db(), keyword()) :: {:ok, [map()]}
  defp query_messages(conn, opts) do
    agent_id = Keyword.get(opts, :agent_id)
    {:ok, query_rows_from(conn, nil, agent_id)}
  end

  @spec do_truncate_agent(Exqlite.Sqlite3.db(), String.t(), non_neg_integer()) :: :ok
  defp do_truncate_agent(conn, agent_id, keep_count) do
    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(conn, """
      DELETE FROM messages
      WHERE agent_id = ?1
      AND id NOT IN (
        SELECT id FROM messages WHERE agent_id = ?1 ORDER BY id LIMIT ?2
      )
      """)

    :ok = Exqlite.Sqlite3.bind(stmt, [agent_id, keep_count])
    :done = Exqlite.Sqlite3.step(conn, stmt)
    :ok = Exqlite.Sqlite3.release(conn, stmt)
    :ok
  end

  @spec find_latest_checkpoint(Exqlite.Sqlite3.db(), String.t() | nil) ::
          non_neg_integer() | nil
  defp find_latest_checkpoint(conn, agent_id) do
    {sql, params} =
      if agent_id do
        {"SELECT id FROM messages WHERE checkpoint = 1 AND agent_id = ?1 ORDER BY id DESC LIMIT 1",
         [agent_id]}
      else
        {"SELECT id FROM messages WHERE checkpoint = 1 ORDER BY id DESC LIMIT 1", []}
      end

    fetch_one_id(conn, sql, params)
  end

  @spec find_prev_checkpoint(Exqlite.Sqlite3.db(), non_neg_integer(), String.t() | nil) ::
          non_neg_integer() | nil
  defp find_prev_checkpoint(conn, checkpoint_id, agent_id) do
    {sql, params} =
      if agent_id do
        {"SELECT id FROM messages WHERE checkpoint = 1 AND id < ?1 AND agent_id = ?2 ORDER BY id DESC LIMIT 1",
         [checkpoint_id, agent_id]}
      else
        {"SELECT id FROM messages WHERE checkpoint = 1 AND id < ?1 ORDER BY id DESC LIMIT 1",
         [checkpoint_id]}
      end

    fetch_one_id(conn, sql, params)
  end

  @spec fetch_one_id(Exqlite.Sqlite3.db(), String.t(), list()) :: non_neg_integer() | nil
  defp fetch_one_id(conn, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, params)

    result =
      case Exqlite.Sqlite3.step(conn, stmt) do
        {:row, [id]} -> id
        :done -> nil
      end

    :ok = Exqlite.Sqlite3.release(conn, stmt)
    result
  end

  @spec query_rows_from(Exqlite.Sqlite3.db(), non_neg_integer() | nil, String.t() | nil) ::
          [map()]
  defp query_rows_from(conn, from_id, agent_id) do
    {sql, params} =
      cond do
        from_id && agent_id ->
          {"SELECT agent_id, data, inserted_at FROM messages WHERE id >= ?1 AND agent_id = ?2 ORDER BY id",
           [from_id, agent_id]}

        from_id ->
          {"SELECT agent_id, data, inserted_at FROM messages WHERE id >= ?1 ORDER BY id",
           [from_id]}

        agent_id ->
          {"SELECT agent_id, data, inserted_at FROM messages WHERE agent_id = ?1 ORDER BY id",
           [agent_id]}

        true ->
          {"SELECT agent_id, data, inserted_at FROM messages ORDER BY id", []}
      end

    run_query(conn, sql, params)
  end

  @spec query_rows_between(
          Exqlite.Sqlite3.db(),
          non_neg_integer() | nil,
          non_neg_integer(),
          String.t() | nil
        ) :: [map()]
  defp query_rows_between(conn, from_id, before_id, agent_id) do
    {sql, params} =
      cond do
        from_id && agent_id ->
          {"SELECT agent_id, data, inserted_at FROM messages WHERE id >= ?1 AND id < ?2 AND agent_id = ?3 ORDER BY id",
           [from_id, before_id, agent_id]}

        from_id ->
          {"SELECT agent_id, data, inserted_at FROM messages WHERE id >= ?1 AND id < ?2 ORDER BY id",
           [from_id, before_id]}

        agent_id ->
          {"SELECT agent_id, data, inserted_at FROM messages WHERE id < ?1 AND agent_id = ?2 ORDER BY id",
           [before_id, agent_id]}

        true ->
          {"SELECT agent_id, data, inserted_at FROM messages WHERE id < ?1 ORDER BY id",
           [before_id]}
      end

    run_query(conn, sql, params)
  end

  @spec run_query(Exqlite.Sqlite3.db(), String.t(), list()) :: [map()]
  defp run_query(conn, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, params)
    rows = collect_rows(conn, stmt)
    :ok = Exqlite.Sqlite3.release(conn, stmt)
    rows
  end

  @spec collect_rows(Exqlite.Sqlite3.db(), Exqlite.Sqlite3.statement(), [map()]) :: [map()]
  defp collect_rows(conn, stmt, acc \\ []) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, [agent_id, data, inserted_at]} ->
        message = :erlang.binary_to_term(data, [:safe])

        collect_rows(conn, stmt, [
          %{agent_id: agent_id, message: message, inserted_at: inserted_at} | acc
        ])

      :done ->
        Enum.reverse(acc)
    end
  end

  @spec sessions_dir() :: String.t()
  defp sessions_dir do
    dir = Planck.Agent.Config.sessions_dir!()

    if Path.type(dir) == :absolute do
      dir
    else
      Path.join(File.cwd!(), dir)
    end
  end
end
