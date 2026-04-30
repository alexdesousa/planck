defmodule Planck.Agent.Session do
  @moduledoc """
  Persistent session store backed by SQLite.

  One GenServer per session, registered globally so any node in the cluster
  can append messages or query history via transparent GenServer calls.
  Each session writes to `<dir>/<id>_<name>.db`.

  Both `id` and `name` appear in the filename so either can be resolved with
  a single directory glob — see `find_by_id/2` and `find_by_name/2`.

  ## Usage

      {:ok, _pid} = Planck.Agent.Session.start("a1b2c3d4", name: "crazy-mango", dir: "/path/to/sessions")

      :ok = Planck.Agent.Session.append("my-session", "agent-1", message)

      {:ok, rows} = Planck.Agent.Session.messages("my-session")
      {:ok, rows} = Planck.Agent.Session.messages("my-session", agent_id: "agent-1")

  Each row is `%{db_id: pos_integer(), agent_id: String.t(), message: Message.t(), inserted_at: integer()}`.
  `db_id` is the SQLite autoincrement row id — use it with `truncate_after/2` to
  anchor a truncation to a specific message.

  Messages are serialized with `:erlang.term_to_binary/1` and read back with
  `:erlang.binary_to_term/2` (`:safe` — no new atoms created from DB content).

  `start/2` requires an explicit `:dir` option — the sessions directory is
  resolved by the caller (typically `Planck.Headless` from its config).

  ## Distribution

  Sessions are registered via `:global` as `{:session, session_id}`. Any node
  in the Erlang cluster can call `append/3` or `messages/2` — the call is routed
  transparently to the node that owns the session's SQLite file.

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

  @typedoc "A row returned by `messages/2` and related query functions."
  @type row :: %{
          db_id: pos_integer(),
          agent_id: String.t(),
          message: Message.t(),
          inserted_at: integer()
        }

  defstruct [:id, :name, :conn]

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
  Append a message and return its DB row id. Returns `nil` if the session is
  not found (agent has no persistent session).
  """
  @spec append(session_id(), String.t(), Message.t()) :: pos_integer() | nil
  def append(session_id, agent_id, message) do
    case whereis(session_id) do
      {:ok, pid} -> GenServer.call(pid, {:append, agent_id, message})
      _ -> nil
    end
  end

  @doc """
  Retrieve messages for a session in insertion order.

  Options:
  - `agent_id:` — filter to messages from a specific agent
  """
  @spec messages(session_id(), keyword()) :: {:ok, [row()]} | {:error, :not_found}
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
          {:ok, [row()], non_neg_integer() | nil} | {:error, :not_found}
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
          {:ok, [row()], non_neg_integer() | nil} | {:error, :not_found}
  def messages_before_checkpoint(session_id, checkpoint_id, opts \\ []) do
    case whereis(session_id) do
      {:ok, pid} -> GenServer.call(pid, {:messages_before_checkpoint, checkpoint_id, opts})
      error -> error
    end
  end

  @doc """
  Delete all messages with a DB row id >= `db_id`, across all agents in the session.

  Used when editing a previous message: truncates the session to strictly before
  the given row, then the caller re-prompts with new text.
  """
  @spec truncate_after(session_id(), pos_integer()) :: :ok | {:error, :not_found}
  def truncate_after(session_id, db_id) do
    case whereis(session_id) do
      {:ok, pid} -> GenServer.call(pid, {:truncate_after, db_id})
      error -> error
    end
  end

  @doc """
  Write key-value metadata for a session. Merges with any existing entries;
  existing keys are overwritten. Values are stored as strings.
  """
  @spec save_metadata(session_id(), map()) :: :ok | {:error, :not_found}
  def save_metadata(session_id, metadata) do
    case whereis(session_id) do
      {:ok, pid} -> GenServer.call(pid, {:save_metadata, metadata})
      error -> error
    end
  end

  @doc "Return all metadata for a session as a `%{String.t() => String.t() | nil}` map."
  @spec get_metadata(session_id()) ::
          {:ok, %{optional(String.t()) => String.t() | nil}} | {:error, :not_found}
  def get_metadata(session_id) do
    case whereis(session_id) do
      {:ok, pid} -> GenServer.call(pid, :get_metadata)
      error -> error
    end
  end

  @doc """
  Resolve a session file by id. Globs `<sessions_dir>/<id>_*.db`.

  Returns `{:ok, path, name}` or `{:error, :not_found}`.
  """
  @spec find_by_id(Path.t(), String.t()) ::
          {:ok, Path.t(), String.t()} | {:error, :not_found}
  def find_by_id(sessions_dir, session_id) do
    sessions_dir
    |> Path.expand()
    |> Path.join("#{session_id}_*.db")
    |> Path.wildcard()
    |> case do
      [path | _] -> {:ok, path, parse_name(path)}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Resolve a session file by name. Globs `<sessions_dir>/*_<name>.db`.

  Returns `{:ok, path, session_id}` or `{:error, :not_found}`.
  """
  @spec find_by_name(Path.t(), String.t()) ::
          {:ok, Path.t(), String.t()} | {:error, :not_found}
  def find_by_name(sessions_dir, name) do
    sessions_dir
    |> Path.expand()
    |> Path.join("*_#{name}.db")
    |> Path.wildcard()
    |> case do
      [path | _] -> {:ok, path, parse_id(path)}
      [] -> {:error, :not_found}
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
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: {:global, {:session, id}})
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
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
    name = Keyword.fetch!(opts, :name)
    dir = Keyword.fetch!(opts, :dir)

    File.mkdir_p!(dir)
    path = Path.join(dir, "#{id}_#{name}.db")

    {:ok, conn} = Exqlite.Sqlite3.open(path)
    :ok = create_tables(conn)

    {:ok, %__MODULE__{id: id, name: name, conn: conn}}
  end

  @impl true
  def handle_call(message, from, state)

  def handle_call({:append, agent_id, message}, _from, state) do
    db_id = insert_message(state.conn, agent_id, message)
    {:reply, db_id, state}
  end

  def handle_call({:save_metadata, metadata}, _from, state) do
    :ok = do_save_metadata(state.conn, metadata)
    {:reply, :ok, state}
  end

  def handle_call(:get_metadata, _from, state) do
    {:reply, {:ok, do_get_metadata(state.conn)}, state}
  end

  def handle_call({:messages, opts}, _from, state) do
    {:reply, query_messages(state.conn, opts), state}
  end

  def handle_call({:messages_from_latest_checkpoint, opts}, _from, state) do
    agent_id = Keyword.get(opts, :agent_id)
    checkpoint_id = find_latest_checkpoint(state.conn, agent_id)
    rows = query_rows_from(state.conn, checkpoint_id, agent_id)
    {:reply, {:ok, rows, checkpoint_id}, state}
  end

  def handle_call({:messages_before_checkpoint, checkpoint_id, opts}, _from, state) do
    agent_id = Keyword.get(opts, :agent_id)
    prev_id = find_prev_checkpoint(state.conn, checkpoint_id, agent_id)
    rows = query_rows_between(state.conn, prev_id, checkpoint_id, agent_id)
    {:reply, {:ok, rows, prev_id}, state}
  end

  def handle_call({:truncate_after, db_id}, _from, state) do
    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(state.conn, "DELETE FROM messages WHERE id >= ?1")

    :ok = Exqlite.Sqlite3.bind(stmt, [db_id])
    :done = Exqlite.Sqlite3.step(state.conn, stmt)
    :ok = Exqlite.Sqlite3.release(state.conn, stmt)
    {:reply, :ok, state}
  end

  @impl true
  def terminate(reason, state)

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

    :ok =
      Exqlite.Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS metadata (
        key   TEXT NOT NULL UNIQUE,
        value TEXT
      )
      """)

    :ok
  end

  @spec do_save_metadata(Exqlite.Sqlite3.db(), map()) :: :ok
  defp do_save_metadata(conn, metadata) do
    Enum.each(metadata, fn {key, value} ->
      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(conn, """
        INSERT INTO metadata (key, value) VALUES (?1, ?2)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """)

      str_value = if is_nil(value), do: nil, else: to_string(value)
      :ok = Exqlite.Sqlite3.bind(stmt, [to_string(key), str_value])
      :done = Exqlite.Sqlite3.step(conn, stmt)
      :ok = Exqlite.Sqlite3.release(conn, stmt)
    end)

    :ok
  end

  @spec do_get_metadata(Exqlite.Sqlite3.db()) :: %{optional(String.t()) => String.t() | nil}
  defp do_get_metadata(conn) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT key, value FROM metadata")
    :ok = Exqlite.Sqlite3.bind(stmt, [])
    rows = collect_metadata_rows(conn, stmt)
    :ok = Exqlite.Sqlite3.release(conn, stmt)
    Map.new(rows)
  end

  @spec collect_metadata_rows(Exqlite.Sqlite3.db(), Exqlite.Sqlite3.statement(), [
          {String.t(), String.t() | nil}
        ]) :: [{String.t(), String.t() | nil}]
  defp collect_metadata_rows(conn, stmt, acc \\ []) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, [key, value]} -> collect_metadata_rows(conn, stmt, [{key, value} | acc])
      :done -> acc
    end
  end

  @spec parse_name(Path.t()) :: String.t()
  defp parse_name(path) do
    [_id, name] = path |> Path.basename(".db") |> String.split("_", parts: 2)
    name
  end

  @spec parse_id(Path.t()) :: String.t()
  defp parse_id(path) do
    [id, _name] = path |> Path.basename(".db") |> String.split("_", parts: 2)
    id
  end

  @spec insert_message(Exqlite.Sqlite3.db(), String.t(), Message.t()) :: pos_integer()
  defp insert_message(conn, agent_id, message) do
    # Strip the id before serialising — it is redundant since the DB row id
    # is authoritative and set on every read in collect_rows.
    data =
      message
      |> Map.drop([:id])
      |> :erlang.term_to_binary()

    now = System.system_time(:second)
    checkpoint = if match?({:custom, :summary}, message.role), do: 1, else: 0

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(conn, """
      INSERT INTO messages (agent_id, data, inserted_at, checkpoint) VALUES (?1, ?2, ?3, ?4)
      """)

    :ok = Exqlite.Sqlite3.bind(stmt, [agent_id, data, now, checkpoint])
    :done = Exqlite.Sqlite3.step(conn, stmt)
    :ok = Exqlite.Sqlite3.release(conn, stmt)

    {:ok, row_id_stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT last_insert_rowid()")
    {:row, [db_id]} = Exqlite.Sqlite3.step(conn, row_id_stmt)
    :ok = Exqlite.Sqlite3.release(conn, row_id_stmt)
    db_id
  end

  @spec query_messages(Exqlite.Sqlite3.db(), keyword()) :: {:ok, [row()]}
  defp query_messages(conn, opts) do
    agent_id = Keyword.get(opts, :agent_id)
    {:ok, query_rows_from(conn, nil, agent_id)}
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
          [row()]
  defp query_rows_from(conn, from_id, agent_id) do
    {sql, params} =
      cond do
        from_id && agent_id ->
          {"SELECT id, agent_id, data, inserted_at FROM messages WHERE id >= ?1 AND agent_id = ?2 ORDER BY id",
           [from_id, agent_id]}

        from_id ->
          {"SELECT id, agent_id, data, inserted_at FROM messages WHERE id >= ?1 ORDER BY id",
           [from_id]}

        agent_id ->
          {"SELECT id, agent_id, data, inserted_at FROM messages WHERE agent_id = ?1 ORDER BY id",
           [agent_id]}

        true ->
          {"SELECT id, agent_id, data, inserted_at FROM messages ORDER BY id", []}
      end

    run_query(conn, sql, params)
  end

  @spec query_rows_between(
          Exqlite.Sqlite3.db(),
          non_neg_integer() | nil,
          non_neg_integer(),
          String.t() | nil
        ) :: [row()]
  defp query_rows_between(conn, from_id, before_id, agent_id) do
    {sql, params} =
      cond do
        from_id && agent_id ->
          {"SELECT id, agent_id, data, inserted_at FROM messages WHERE id >= ?1 AND id < ?2 AND agent_id = ?3 ORDER BY id",
           [from_id, before_id, agent_id]}

        from_id ->
          {"SELECT id, agent_id, data, inserted_at FROM messages WHERE id >= ?1 AND id < ?2 ORDER BY id",
           [from_id, before_id]}

        agent_id ->
          {"SELECT id, agent_id, data, inserted_at FROM messages WHERE id < ?1 AND agent_id = ?2 ORDER BY id",
           [before_id, agent_id]}

        true ->
          {"SELECT id, agent_id, data, inserted_at FROM messages WHERE id < ?1 ORDER BY id",
           [before_id]}
      end

    run_query(conn, sql, params)
  end

  @spec run_query(Exqlite.Sqlite3.db(), String.t(), list()) :: [row()]
  defp run_query(conn, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, params)
    rows = collect_rows(conn, stmt)
    :ok = Exqlite.Sqlite3.release(conn, stmt)
    rows
  end

  @spec collect_rows(Exqlite.Sqlite3.db(), Exqlite.Sqlite3.statement(), [row()]) :: [row()]
  defp collect_rows(conn, stmt, acc \\ []) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, [db_id, agent_id, data, inserted_at]} ->
        # binary_to_term restores the %Message{} struct (Map.drop preserved __struct__);
        # Map.put adds back the :id that was stripped before serialization.
        %Message{} = message = data |> :erlang.binary_to_term([:safe]) |> Map.put(:id, db_id)

        collect_rows(conn, stmt, [
          %{db_id: db_id, agent_id: agent_id, message: message, inserted_at: inserted_at} | acc
        ])

      :done ->
        Enum.reverse(acc)
    end
  end
end
