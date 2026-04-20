# Sessions

`Planck.Agent.Session` provides SQLite-backed persistent storage for agent message
histories. Agents with a `session_id` automatically append every message (including
summary checkpoints) to the shared session file.

## Architecture

Each session is a `GenServer` backed by a single SQLite file at
`<sessions_dir>/<session_id>.db`. Sessions are registered globally as
`{:session, session_id}` and started under `Planck.Agent.SessionSupervisor`
(`DynamicSupervisor`, `restart: :temporary`).

Multiple agents can share one session by using the same `session_id`. Messages
are stored in insertion order with the originating `agent_id` and a wall-clock
timestamp (milliseconds since epoch).

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
# opts: dir: Path.t() — override the default sessions_dir for this session.
@spec start(session_id :: String.t(), opts :: keyword()) ::
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
```

Both pagination functions accept an optional `agent_id:` keyword to filter
results to a specific agent.

## Usage

```elixir
alias Planck.Agent.Session

# Start a session before starting agents
{:ok, _pid} = Session.start(session_id)

# Initial page load
{:ok, rows, checkpoint_id} = Session.messages_from_latest_checkpoint(session_id)

# Load more (previous chapter)
{:ok, rows, prev_id} = Session.messages_before_checkpoint(session_id, checkpoint_id)
# prev_id == nil → no more history
```

## Configuration

| Env var                       | Config key      | Default             |
|-------------------------------|-----------------|---------------------|
| `PLANCK_AGENT_SESSIONS_DIR`   | `:sessions_dir` | `.planck/sessions`  |

```elixir
config :planck_agent, :sessions_dir, "/var/data/planck/sessions"
```

## Notes

- Sessions are `restart: :temporary` — they do not restart after a crash.
  Agents write to the session if it is alive; if it is not, messages are
  silently dropped in memory only (the agents continue running).
- The SQLite file persists on disk and can be re-opened after a restart by
  calling `Session.start/2` with the same `session_id`.
- `truncate_agent/3` is called by `Planck.Agent.rewind/2` to keep the session
  in sync with the in-memory message history.
