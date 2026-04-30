# Sessions

`Planck.Agent.Session` provides SQLite-backed persistent storage for agent message
histories. Agents with a `session_id` automatically append every message (including
summary checkpoints) to the shared session file.

## Architecture

Each session is a `GenServer` backed by a single SQLite file at
`<sessions_dir>/<session_id>_<name>.db`. Sessions are registered globally as
`{:session, session_id}` and started under `Planck.Agent.SessionSupervisor`
(`DynamicSupervisor`, `restart: :temporary`).

The filename encodes both the id and the name so that either can be resolved
with a single directory glob — no need to open files to find a session:

```
<sessions_dir>/
  a1b2c3d4_crazy-mango.db
  e5f6a7b8_silent-papaya.db
  c9d0e1f2_bright-kumquat.db
```

- **Lookup by id** — glob `<sessions_dir>/<id>_*.db`
- **Lookup by name** — glob `<sessions_dir>/*_<name>.db`
- **List all** — glob `<sessions_dir>/*.db`, split on `_` to extract id + name

Names are constrained to `[a-z0-9-]+` (no underscores) so `_` unambiguously
separates the id from the name. `planck_headless.SessionName` generates and
sanitizes names; `planck_agent.Session` only receives them as the `name:` opt.

Multiple agents can share one session by using the same `session_id`. Messages
are stored in insertion order with the originating `agent_id` and a wall-clock
timestamp (milliseconds since epoch).

The SQLite file has two tables:

- **`messages`** — one row per message: `agent_id`, `role`, `content`,
  `checkpoint` (0 or 1), `inserted_at`.
- **`metadata`** — key-value pairs written at session creation time and read on
  resume. Used by `planck_headless` to reconstruct the team and detect in-flight
  work without scanning message history.

## Metadata

The metadata table stores session-level facts that cannot be reliably derived
from the message history alone:

| Key            | Type           | Description                                                  |
|----------------|----------------|--------------------------------------------------------------|
| `team_alias`   | string \| null | Team alias or absolute path to TEAM.json; nil for dynamic-only sessions |
| `session_name` | string         | Sanitized session name (mirrors the filename component)      |
| `cwd`          | string         | Working directory at session creation time                   |

`planck_headless` writes these keys when `start_session/1` is called and reads
them during `resume_session/1`. `planck_agent` does not interpret metadata — it
is stored and returned verbatim.

## Checkpoints

Messages with role `{:custom, :summary}` are stored with `checkpoint = 1`. This
enables efficient pagination — rather than loading the full history on every
render, a client loads the latest checkpoint and all messages after it, then
lazily pages backward through earlier chapters.

```
Full history stored in SQLite
──────────────────────────────────────────
  [messages]  │  summary ←── checkpoint A
  [messages]  │  summary ←── checkpoint B
  [messages]             ←── active window (no checkpoint yet)
──────────────────────────────────────────
                               ↑ loaded on initial render
```

## API

```elixir
# Start a session GenServer. Call before starting any agents that need persistence.
# Requires:
#   id:   String.t()  — the session id
#   name: String.t()  — the sanitized session name (used to build the filename)
#   dir:  Path.t()    — the sessions directory
@spec start(id :: String.t(), opts :: keyword()) ::
        {:ok, pid()} | {:error, term()}

# Stop a session GenServer.
@spec stop(session_id :: String.t()) :: :ok

# Append a message. Called automatically by agents — rarely needed directly.
@spec append(session_id :: String.t(), agent_id :: String.t(), Message.t()) :: :ok

# All messages in insertion order.
@spec messages(session_id :: String.t()) ::
        {:ok, [%{agent_id: String.t(), message: Message.t(), inserted_at: integer()}]}

# Filter by agent.
@spec messages(session_id :: String.t(), agent_id: String.t()) :: {:ok, [...]}

# Remove messages after position `keep` for a specific agent. Used by rewind/2.
@spec truncate_agent(session_id :: String.t(), agent_id :: String.t(),
                     keep :: non_neg_integer()) :: :ok

# Pagination: latest checkpoint + all messages after it.
@spec messages_from_latest_checkpoint(session_id :: String.t()) ::
        {:ok, [...], checkpoint_id :: integer() | nil}

# Pagination: one chapter back from a checkpoint.
@spec messages_before_checkpoint(session_id :: String.t(), checkpoint_id :: integer()) ::
        {:ok, [...], prev_checkpoint_id :: integer() | nil}
# prev_checkpoint_id == nil means no earlier history.

# Write metadata key-value pairs. Merges with any existing metadata.
@spec save_metadata(session_id :: String.t(), map()) :: :ok

# Read all metadata as a map.
@spec get_metadata(session_id :: String.t()) ::
        {:ok, %{optional(String.t()) => String.t() | nil}} | {:error, :not_found}

# Resolve a session file path from the sessions dir and a session id.
# Returns {:ok, path, name} or {:error, :not_found}.
@spec find_by_id(sessions_dir :: Path.t(), session_id :: String.t()) ::
        {:ok, Path.t(), String.t()} | {:error, :not_found}

# Resolve a session file path from the sessions dir and a session name.
# Returns {:ok, path, id} or {:error, :not_found}.
@spec find_by_name(sessions_dir :: Path.t(), name :: String.t()) ::
        {:ok, Path.t(), String.t()} | {:error, :not_found}
```

Both pagination functions accept an optional `agent_id:` keyword to filter
results to a specific agent.

## Usage

```elixir
alias Planck.Agent.Session

# Start a session before starting agents
{:ok, _pid} = Session.start(session_id, name: "crazy-mango", dir: sessions_dir)

# Reopen an existing session on resume (file already exists)
{:ok, path, _name} = Session.find_by_id(sessions_dir, session_id)
{:ok, _pid} = Session.start(session_id, name: name, dir: sessions_dir)

# Initial page load
{:ok, rows, checkpoint_id} = Session.messages_from_latest_checkpoint(session_id)

# Load more (previous chapter)
{:ok, rows, prev_id} = Session.messages_before_checkpoint(session_id, checkpoint_id)
# prev_id == nil → no more history
```

## Notes

- Sessions are `restart: :temporary` — they do not restart after a crash.
  Agents write to the session if it is alive; if it is not, messages are
  silently dropped in memory only (the agents continue running).
- The SQLite file persists on disk and can be re-opened by calling `Session.start/2`
  with the same `session_id`, `name:`, and `dir:`.
- `truncate_agent/3` is called by `Planck.Agent.rewind/2` to keep the session
  in sync with the in-memory message history.
- The `sessions_dir` is configured via `PLANCK_SESSIONS_DIR` in
  `Planck.Headless.Config`. `Session.start/2` takes an explicit `dir:` argument —
  it does not read config directly.
