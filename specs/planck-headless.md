# planck_headless

## Purpose

The headless core of the Planck coding agent. `planck_headless` is a long-running OTP
application that manages sessions, loads resources (tools, skills, compactor), and
bootstraps agent teams. Any process — a TUI, a Phoenix controller, a test — can start
a session and interact with it via a clean API; events are received through the
`planck_agent` PubSub already in place.

`planck_tui` and `planck_web` depend on `planck_headless`. They are rendering surfaces
only — they never call `planck_agent` directly.

## What planck_headless owns

- **Startup orchestration** — load external tools, skills, and the custom compactor from
  the filesystem at application start; make them available to all sessions
- **Session lifecycle** — create and resume named sessions; start the SQLite-backed
  `Planck.Agent.Session` and the agent team together; tear both down on close
- **Team bootstrap** — instantiate a team from a `TeamTemplate` (or a default config)
  with tools, skills, compactor, and models already wired; caller gets a `session_id`
- **Model availability** — detect which providers have API keys set; expose a filtered
  `available_models` list to callers and to the orchestrator's `list_models` tool
- **Config loading** — merge `.planck/config.yaml`, `~/.planck/config.yaml`, and env
  vars into a single resolved config; extend the Skogsra config from `planck_agent`

## What planck_headless does NOT own

- Rendering — no TUI or HTML; events flow via PubSub
- Slash commands and prompt templates — UI-layer concerns
- The agent loop — that is `planck_agent`'s responsibility
- HTTP transport and LLM calls — that is `planck_ai`'s responsibility

## Dependencies

```elixir
{:planck_agent, "~> 0.1"},
{:yaml_elixir, "~> 2.9"},
{:jason, "~> 1.4"}
```

## How a UI uses it

```elixir
# 1. Start a session (creates SQLite session + agent team)
{:ok, session_id} = Planck.Headless.start_session()

# 2. Subscribe to all events for that session (planck_agent PubSub)
Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "session:#{session_id}")

# 3. Send a prompt to the orchestrator
:ok = Planck.Headless.prompt(session_id, "Refactor lib/app.ex to use a GenServer")

# 4. Receive events
receive do
  {:agent_event, :text_delta, %{text: chunk}} -> IO.write(chunk)
  {:agent_event, :turn_end, %{usage: u}}      -> IO.inspect(u)
end

# 5. Close the session when done
:ok = Planck.Headless.close_session(session_id)
```

Multiple sessions can run concurrently. Each has its own team and SQLite file. One
session crashing does not affect others.

## Public API

```elixir
# Start a new session with an agent team. Returns a session_id.
# opts:
#   template:   Path.t() | nil  — path to a team template JSON; uses default if nil
#   name:       String.t() | nil  — human-readable session name
#   cwd:        Path.t()  — working directory for the session (default: File.cwd!())
@spec start_session(keyword()) :: {:ok, session_id :: String.t()} | {:error, term()}

# Resume a session by id. Restores message history; starts a fresh agent team.
@spec resume_session(session_id :: String.t(), keyword()) ::
        {:ok, session_id :: String.t()} | {:error, term()}

# Close a session. Stops the agent team and the SQLite session process.
# The SQLite file is retained on disk and can be resumed later.
@spec close_session(session_id :: String.t()) :: :ok

# Send a user prompt to the orchestrator of a session.
@spec prompt(session_id :: String.t(), text :: String.t()) :: :ok | {:error, term()}

# List all active sessions.
@spec list_sessions() :: [%{session_id: String.t(), name: String.t() | nil, status: atom()}]

# Return models available for use (providers with API keys configured).
@spec available_models() :: [Planck.AI.Model.t()]

# Return the resolved config.
@spec config() :: Planck.Headless.Config.t()
```

## Startup sequence

When the `planck_headless` application starts:

1. Load and resolve config (YAML files + env vars)
2. Load external tools via `Planck.Agent.ExternalTool.load_all(tools_dirs)`
3. Load skills via `Planck.Agent.Skill.load_all(skills_dirs)`
4. Load the custom compactor via `Planck.Agent.Compactor.load(compactor_path)` if
   configured; otherwise fall back to `Planck.Agent.Compactor.build/2`
5. Detect available models by checking provider API keys
6. Store all loaded resources in the `Planck.Headless.ResourceStore` (a named GenServer)

From that point on, any call to `start_session/1` uses the already-loaded resources —
no per-session filesystem scanning.

## Session bootstrap

`start_session/1` performs these steps atomically (rolls back on failure):

1. Generate a `session_id` (or accept one for resume)
2. Start `Planck.Agent.Session` under `SessionSupervisor`
3. Load message history from SQLite if resuming
4. Resolve team template (from `opts[:template]` or the default)
5. Build the system prompt by injecting the skills section
6. Start all agents via `AgentSpec.to_start_opts/2` with:
   - `tool_pool:` from `ResourceStore`
   - `on_compact:` from `ResourceStore`
   - `available_models:` from `ResourceStore`
   - `team_id:` and `session_id:` generated for this session
7. Return `{:ok, session_id}`

## ResourceStore

`Planck.Headless.ResourceStore` is a GenServer started at application boot that holds
the loaded resources. It is the single source of truth for tools, skills, compactor,
and available models.

```elixir
%Planck.Headless.ResourceStore{
  tools:             [Planck.Agent.Tool.t()],   # builtin + external
  skills:            [Planck.Agent.Skill.t()],
  on_compact:        function(),
  available_models:  [Planck.AI.Model.t()]
}
```

Resources can be reloaded at runtime without restarting the application:

```elixir
# Reload tools and skills from disk (new sessions pick up the changes)
Planck.Headless.reload_resources()
```

In-flight sessions are not affected by a reload — they keep the resources they were
started with.

## Config

`planck_headless` merges config from three sources in priority order (highest first):

1. Environment variables
2. `.planck/config.yaml` in the current working directory (project-local)
3. `~/.planck/config.yaml` (user-global)

```yaml
# ~/.planck/config.yaml
default_provider: anthropic
default_model:    claude-sonnet-4-6

tools_dirs:
  - ~/.planck/tools

skills_dirs:
  - ~/.planck/skills

compactor: ~/.planck/compactor.exs

team_template: ~/.planck/team.json
```

```elixir
%Planck.Headless.Config{
  default_provider:  atom() | nil,
  default_model:     String.t() | nil,
  tools_dirs:        [Path.t()],
  skills_dirs:       [Path.t()],
  compactor:         Path.t() | nil,
  team_template:     Path.t() | nil
}
```

Config keys map to the env vars already defined in `planck_agent` (`PLANCK_AGENT_TOOLS_DIRS`,
`PLANCK_AGENT_SKILLS_DIRS`, `PLANCK_AGENT_COMPACTOR`) plus new ones for
`default_provider`, `default_model`, and `team_template`.

## Default team template

When no `team_template` is configured, `planck_headless` boots a single-agent session:
one orchestrator with the full built-in tool set (`read`, `write`, `edit`, `bash`) plus
all loaded external tools. This mirrors the classic single-agent coding assistant experience.

## Supervision tree

```
Planck.Headless.Supervisor  (strategy: :one_for_one)
├── Planck.Agent.Supervisor          (planck_agent's own tree)
└── Planck.Headless.AppSupervisor    (strategy: :one_for_one)
    ├── Planck.Headless.ResourceStore
    └── Planck.Headless.SessionRegistry  (tracks active session_id → team_id mapping)
```

`Planck.Agent.Supervisor` is started as a child so headless owns the full OTP tree.
Callers only need to start `planck_headless` — not `planck_agent` separately.

## Testing strategy

- `ResourceStore` — verify tools/skills/compactor are loaded from fixture dirs on start;
  verify reload picks up changes; verify in-flight sessions are unaffected
- `start_session/1` — happy path returns `session_id`; team is reachable via PubSub;
  failure (bad template) rolls back session and SQLite process
- `resume_session/1` — message history is restored; agents pick up from last checkpoint
- `close_session/1` — team processes terminate; session SQLite process stops; file retained
- `prompt/2` — message reaches orchestrator; turn_end event arrives on session topic
- `available_models/0` — returns only models whose provider has an API key set
- `reload_resources/0` — new sessions see new tools; existing sessions unaffected
- Config merging — project-local YAML overrides global; env vars override both
