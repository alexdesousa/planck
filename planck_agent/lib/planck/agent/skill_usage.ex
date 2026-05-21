defmodule Planck.Agent.SkillUsage do
  @moduledoc """
  Per-project SQLite database tracking skill usage per agent type.

  The DB lives at `.planck/skills.db` inside the project directory. It is
  created on first use; callers pass the path explicitly so the module stays
  stateless and testable.

  The PK is `(team_name, agent_name, skill_name)`. `agent_type` is stored as a
  plain column and is used only for the dynamic-orchestrator union query.

  - `team_name` — team directory alias, e.g. `"my-team"`
  - `agent_name` — `spec.name || spec.type`, e.g. `"Builder"`, `"orchestrator"`
  - `agent_type` — `spec.type`, e.g. `"orchestrator"`, `"builder"`

  Fixed agents are queried by `(team_name, agent_name)`. Dynamic orchestrators
  (spawned via `spawn_agent`, no history of their own) are seeded by querying
  `agent_type = 'orchestrator'` across the team.

  ## Schema

      CREATE TABLE skill_usage (
        team_name  TEXT NOT NULL,
        agent_name TEXT NOT NULL,
        agent_type TEXT NOT NULL,
        skill_name TEXT NOT NULL,
        use_count  INTEGER NOT NULL DEFAULT 0,
        last_used  TEXT,
        PRIMARY KEY (team_name, agent_name, skill_name)
      );
  """

  require Logger

  @db_filename "skills.db"

  @doc """
  Record one use of `skill_name` by `(team_name, agent_name, agent_type)`.

  Creates the DB and table if they do not exist. Increments `use_count` and
  updates `last_used` to the current UTC timestamp. No-ops silently on error.
  """
  @spec record_use(Path.t(), String.t(), String.t(), String.t(), String.t()) :: :ok
  def record_use(project_dir, team_name, agent_name, agent_type, skill_name) do
    path = db_path(project_dir)

    with {:ok, conn} <- open(path),
         :ok <- ensure_table(conn) do
      upsert(conn, team_name, agent_name, agent_type, skill_name)
      Exqlite.Sqlite3.close(conn)
    else
      {:error, reason} ->
        Logger.warning("[Planck.Agent.SkillUsage] record_use failed: #{inspect(reason)}")
    end

    :ok
  end

  @doc """
  Return the ranked skill names for an agent, with a cold-start fallback.

  Queries the SQLite DB for the top `n` most recently used skills for
  `(team_name, agent_name)`. When no history exists (first session), falls back
  to the `n` most recently modified skill files — ensuring the index is always
  populated even before any skills have been loaded.
  """
  @spec ranked_names(Path.t(), String.t(), String.t(), [Planck.Agent.Skill.t()], pos_integer()) ::
          [String.t()]
  def ranked_names(project_dir, team_name, agent_name, skills, n) do
    ranked = top_n(project_dir, team_name, agent_name, n)
    if ranked == [], do: fallback_by_mtime(skills, n), else: ranked
  end

  @spec fallback_by_mtime([Planck.Agent.Skill.t()], pos_integer()) :: [String.t()]
  defp fallback_by_mtime(skills, n) do
    skills
    |> Enum.sort_by(&skill_mtime/1, :desc)
    |> Enum.take(n)
    |> Enum.map(& &1.name)
  end

  @spec skill_mtime(Planck.Agent.Skill.t()) :: :calendar.datetime()
  defp skill_mtime(skill) do
    case File.stat(skill.skill_file) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> {{0, 0, 0}, {0, 0, 0, 0}}
    end
  end

  @doc """
  Return the top `n` skill names for `(team_name, agent_name)`, ordered by
  recency then count.

  Returns an empty list when the DB does not exist or the agent has no history.
  """
  @spec top_n(Path.t(), String.t(), String.t(), pos_integer()) :: [String.t()]
  def top_n(project_dir, team_name, agent_name, n) do
    query_names(db_path(project_dir), fn conn ->
      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(conn, """
        SELECT skill_name FROM skill_usage
        WHERE team_name = ?1 AND agent_name = ?2
        ORDER BY last_used DESC, use_count DESC
        LIMIT ?3
        """)

      :ok = Exqlite.Sqlite3.bind(stmt, [team_name, agent_name, n])
      collect_names(conn, stmt)
    end)
  end

  @doc """
  Return the top `n` skill names across all orchestrators in a given team.

  Used to seed the skill ranking for dynamic orchestrators (spawned via
  `spawn_agent`), which have no usage history of their own. Queries by
  `agent_type = 'orchestrator'` so all fixed orchestrators in the team
  contribute. Deduplicates and orders by recency then count.
  """
  @spec top_n_for_orchestrators(Path.t(), String.t(), pos_integer()) :: [String.t()]
  def top_n_for_orchestrators(project_dir, team_name, n) do
    query_names(db_path(project_dir), fn conn ->
      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(conn, """
        SELECT skill_name FROM skill_usage
        WHERE team_name = ?1 AND agent_type = 'orchestrator'
        GROUP BY skill_name
        ORDER BY MAX(last_used) DESC, SUM(use_count) DESC
        LIMIT ?2
        """)

      :ok = Exqlite.Sqlite3.bind(stmt, [team_name, n])
      collect_names(conn, stmt)
    end)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec db_path(Path.t()) :: Path.t()
  defp db_path(project_dir), do: Path.join([project_dir, ".planck", @db_filename])

  @spec open(Path.t()) :: {:ok, Exqlite.Sqlite3.db()} | {:error, term()}
  defp open(path) do
    :ok = path |> Path.dirname() |> File.mkdir_p()
    Exqlite.Sqlite3.open(path)
  end

  @spec ensure_table(Exqlite.Sqlite3.db()) :: :ok
  defp ensure_table(conn) do
    Exqlite.Sqlite3.execute(conn, """
    CREATE TABLE IF NOT EXISTS skill_usage (
      team_name  TEXT NOT NULL,
      agent_name TEXT NOT NULL,
      agent_type TEXT NOT NULL,
      skill_name TEXT NOT NULL,
      use_count  INTEGER NOT NULL DEFAULT 0,
      last_used  TEXT,
      PRIMARY KEY (team_name, agent_name, skill_name)
    )
    """)
  end

  @spec upsert(Exqlite.Sqlite3.db(), String.t(), String.t(), String.t(), String.t()) :: :ok
  defp upsert(conn, team_name, agent_name, agent_type, skill_name) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(conn, """
      INSERT INTO skill_usage (team_name, agent_name, agent_type, skill_name, use_count, last_used)
      VALUES (?1, ?2, ?3, ?4, 1, ?5)
      ON CONFLICT (team_name, agent_name, skill_name)
      DO UPDATE SET use_count = use_count + 1, last_used = ?5
      """)

    :ok = Exqlite.Sqlite3.bind(stmt, [team_name, agent_name, agent_type, skill_name, now])
    :done = Exqlite.Sqlite3.step(conn, stmt)
    :ok = Exqlite.Sqlite3.release(conn, stmt)
  end

  @spec query_names(Path.t(), (Exqlite.Sqlite3.db() -> [String.t()])) :: [String.t()]
  defp query_names(path, fun) do
    if File.exists?(path) do
      case Exqlite.Sqlite3.open(path) do
        {:ok, conn} ->
          names = fun.(conn)
          Exqlite.Sqlite3.close(conn)
          names

        {:error, _} ->
          []
      end
    else
      []
    end
  end

  @spec collect_names(Exqlite.Sqlite3.db(), Exqlite.Sqlite3.statement()) :: [String.t()]
  defp collect_names(conn, stmt) do
    collect_names(conn, stmt, [])
  end

  defp collect_names(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, [name]} -> collect_names(conn, stmt, [name | acc])
      :done -> Enum.reverse(acc)
    end
  end
end
