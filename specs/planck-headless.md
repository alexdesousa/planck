# planck_headless

## Purpose

The headless core of the Planck coding agent. `planck_headless` is a long-running
OTP application that owns configuration, loads resources (tools, skills, teams,
compactor) at startup, and manages session lifecycles. Any process — a TUI, a
Phoenix controller, a test — can start a session and interact with it via a clean
API; events flow over the `planck_agent` PubSub already in place.

`planck_tui` and `planck_web` depend on `planck_headless`. They are rendering
surfaces only — they never call `planck_agent` directly.

## What planck_headless owns

- **Configuration** — the single source of truth for all runtime settings.
  Merges a JSON config file with environment variables and application config
  and exposes a resolved `Planck.Headless.Config` struct.
- **Startup orchestration** — load external tools, skills, teams, and the
  custom compactor from the filesystem at application start; make them
  available to all sessions via a `ResourceStore`.
- **Team registry** — scan `teams_dirs` at boot, parse each team directory via
  `Planck.Agent.Team.load/1`, store the results keyed by alias.
- **Session lifecycle** — create, resume, and close named sessions; start the
  SQLite-backed `Planck.Agent.Session` and the agent team together; tear both
  down on close.
- **Team bootstrap** — instantiate a team from a `%Planck.Agent.Team{}` (loaded
  from the registry by alias, loaded on the fly from a path, or built
  dynamically from config for the no-template case) with tools, skills,
  compactor, and models already wired; the caller gets a `session_id`.
- **Model availability** — detect which providers have API keys set; expose a
  filtered `available_models` list to callers and to the orchestrator's
  `list_models` tool.

## What planck_headless does NOT own

- Rendering — no TUI or HTML; events flow via PubSub.
- Slash commands and prompt templates — UI-layer concerns.
- The agent loop — that is `planck_agent`'s responsibility.
- HTTP transport and LLM calls — that is `planck_ai`'s responsibility.

## Dependencies

```elixir
{:planck_agent, "~> 0.1"},
{:jason, "~> 1.4"}
```

`planck_agent` transitively provides `Skogsra`, `Phoenix.PubSub`, `erlexec`, and
`exqlite`. No new config-format deps: JSON is the config file format, parsed
via `Jason`.

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

Multiple sessions run concurrently. Each has its own team and SQLite file. One
session crashing does not affect others.

## Public API

```elixir
# --- Sessions ---

# Start a new session. Returns a session_id.
# opts:
#   template:    String.t() | Path.t() | nil  — alias in the registry,
#                path to a TEAM.json, or nil for the default dynamic team
#   name:        String.t() | nil             — human-readable session name
#   cwd:         Path.t()                     — working directory (default: File.cwd!())
@spec start_session(keyword()) :: {:ok, String.t()} | {:error, term()}

# Resume a session by id. Restores message history; starts a fresh agent team
# using the same team spec the session was originally created with.
@spec resume_session(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}

# Close a session. Stops the agent team and the session GenServer; the SQLite
# file is retained for later resumption.
@spec close_session(String.t()) :: :ok

# Send a user prompt to the orchestrator of a session.
@spec prompt(String.t(), String.t()) :: :ok | {:error, term()}

# List all active sessions.
@spec list_sessions() ::
        [%{session_id: String.t(), name: String.t() | nil, status: atom()}]

# --- Teams ---

# List all registered teams with metadata for UI display.
@spec list_teams() ::
        [%{alias: String.t(), name: String.t() | nil, description: String.t() | nil}]

# Look up a team by alias.
@spec get_team(String.t()) :: {:ok, Planck.Agent.Team.t()} | {:error, :not_found}

# --- Resources ---

# Reload tools, skills, teams, and the compactor from disk. In-flight sessions
# keep their original resources; only new sessions pick up changes.
@spec reload_resources() :: :ok

# Return models available for use (providers with API keys configured).
@spec available_models() :: [Planck.AI.Model.t()]

# Return the resolved config.
@spec config() :: Planck.Headless.Config.t()
```

## Startup sequence

When the `planck_headless` application starts:

1. **Config** — load and resolve config from JSON files + env vars + application
   config (see *Config* below).
2. **Tools** — `Planck.Agent.ExternalTool.load_all(config.tools_dirs)`.
3. **Skills** — `Planck.Agent.Skill.load_all(config.skills_dirs)`.
4. **Teams** — scan `config.teams_dirs` and call `Planck.Agent.Team.load/1` on
   each subdirectory; store in `ResourceStore.teams` keyed by alias. Project-
   local aliases overwrite global ones on collision.
5. **Compactor** — `Planck.Agent.Compactor.load(config.compactor)` if set,
   otherwise fall back to `Planck.Agent.Compactor.build/2` at session start
   using the orchestrator's model.
6. **Models** — detect providers with API keys set; build the filtered
   `available_models` list.
7. **ResourceStore** — populate the named GenServer with all of the above.

From that point on, `start_session/1` uses the already-loaded resources — no
per-session filesystem scanning.

## Session bootstrap

`start_session/1` performs these steps atomically (rolls back on failure):

1. Resolve the team:
   - `template: alias_string` → `ResourceStore.teams[alias]`
   - `template: path` → `Team.load(path)` on the fly
   - `template: nil` → build a dynamic team of one from config
     (`default_provider`, `default_model`, default system prompt; full
     `tool_pool` and `skill_pool` attached to the lone orchestrator)
2. Generate a `session_id`.
3. Start `Planck.Agent.Session` under `SessionSupervisor`.
4. For each member in the team, call `AgentSpec.to_start_opts/2` with:
   - `tool_pool:` from `ResourceStore.tools`
   - `skill_pool:` from `ResourceStore.skills`
   - `team_id:` and `session_id:` for this session
   - `available_models:` from `ResourceStore`
   - `on_compact:` from `ResourceStore.on_compact`
5. Start each agent under `Planck.Agent.AgentSupervisor`.
6. Record `session_id → team_id` in `SessionRegistry`.
7. Return `{:ok, session_id}`.

The system-prompt assembly (appending the skills section) already happens inside
`AgentSpec.to_start_opts/2` via the `skill_pool:` resolver — `planck_headless`
does not touch prompts directly.

## Default team

When `start_session/1` is called with `template: nil`, `planck_headless` builds
a dynamic team of one via `Planck.Agent.Team.dynamic/1`:

```elixir
orchestrator =
  AgentSpec.new(
    type:          "orchestrator",
    provider:      config.default_provider,
    model_id:      config.default_model,
    system_prompt: Planck.Headless.DefaultPrompt.orchestrator(),
    tools:         Enum.map(resource_store.tools, & &1.name),
    skills:        Enum.map(resource_store.skills, & &1.name)
  )

Team.dynamic(orchestrator)
```

The orchestrator sees every loaded tool and skill. A `new_team` skill can later
grow this into a multi-member dynamic team via `spawn_agent`.

## ResourceStore

`Planck.Headless.ResourceStore` is a GenServer started at application boot that
holds the loaded resources — the single source of truth.

```elixir
%Planck.Headless.ResourceStore{
  tools:             [Planck.Agent.Tool.t()],           # builtin + external
  skills:            [Planck.Agent.Skill.t()],
  teams:             %{String.t() => Planck.Agent.Team.t()},  # alias => team
  on_compact:        function() | nil,
  available_models:  [Planck.AI.Model.t()]
}
```

Resources can be reloaded at runtime without restarting the application:

```elixir
Planck.Headless.reload_resources()
```

In-flight sessions are not affected by a reload — they keep the resources they
were started with.

## Config

`Planck.Headless.Config` is the **single** config module in the stack.
`Planck.Agent.Config` is removed as part of the migration (see *Migration from
Planck.Agent.Config* below).

### Sources and precedence

Config is resolved by merging three sources, highest priority first:

1. **Environment variables** — `PLANCK_*` (see table below).
2. **Project-local JSON** — `.planck/config.json` in `File.cwd!()`.
3. **User-global JSON** — `~/.planck/config.json`.
4. **Application config** — `config :planck_headless, ...` from `config/*.exs`.

Env vars override JSON files; project-local JSON overrides user-global JSON;
both override application config. At boot, `Planck.Headless.Config.load/0`
merges the two JSON files into Application config, then Skogsra resolves each
key with env-var precedence.

### Struct

```elixir
%Planck.Headless.Config{
  default_provider:  atom() | nil,    # e.g. :anthropic
  default_model:     String.t() | nil, # e.g. "claude-sonnet-4-6"
  sessions_dir:      Path.t(),
  skills_dirs:       [Path.t()],
  tools_dirs:        [Path.t()],
  teams_dirs:        [Path.t()],
  compactor:         Path.t() | nil
}
```

### JSON file format

```json
{
  "default_provider": "anthropic",
  "default_model":    "claude-sonnet-4-6",
  "sessions_dir":     ".planck/sessions",
  "skills_dirs":      ["~/.planck/skills"],
  "tools_dirs":       ["~/.planck/tools"],
  "teams_dirs":       ["~/.planck/teams"],
  "compactor":        "~/.planck/compactor.exs"
}
```

All keys are optional. Arrays are replaced, not merged (project-local
`skills_dirs` wholly replaces the global one; users who want to layer should
include both paths in the project-local file).

### Env vars and defaults

| Env var                   | Config key           | Default                                              |
|---------------------------|----------------------|------------------------------------------------------|
| `PLANCK_DEFAULT_PROVIDER` | `:default_provider`  | `nil`                                                |
| `PLANCK_DEFAULT_MODEL`    | `:default_model`     | `nil`                                                |
| `PLANCK_SESSIONS_DIR`     | `:sessions_dir`      | `.planck/sessions`                                   |
| `PLANCK_SKILLS_DIRS`      | `:skills_dirs`       | `.planck/skills:~/.planck/skills`                    |
| `PLANCK_TOOLS_DIRS`       | `:tools_dirs`        | `.planck/tools:~/.planck/tools`                      |
| `PLANCK_TEAMS_DIRS`       | `:teams_dirs`        | `.planck/teams:~/.planck/teams`                      |
| `PLANCK_COMPACTOR`        | `:compactor`         | `nil`                                                |

`*_DIRS` env vars take a colon-separated list; paths are expanded at runtime
(`~` and relative paths resolved). Parsed via a `Planck.Headless.Config.PathList`
Skogsra type (moved from `Planck.Agent.Config.PathList`).

### API

```elixir
# Resolved config. Cached after first call; cleared by reload_resources/0.
@spec get() :: t()

# Load JSON config files into Application env. Called by Application.start/2
# before the supervisor starts. Idempotent.
@spec load() :: :ok
```

## Supervision tree

```
Planck.Headless.Supervisor  (strategy: :one_for_one)
├── Planck.Agent.Supervisor               (planck_agent's own tree)
└── Planck.Headless.AppSupervisor         (strategy: :one_for_one)
    ├── Planck.Headless.ResourceStore     (named GenServer)
    └── Planck.Headless.SessionRegistry   (tracks session_id → team_id)
```

`Planck.Agent.Supervisor` is started as a child so headless owns the full OTP
tree. Callers only need to start `:planck_headless` — not `:planck_agent`
separately.

## Migration from Planck.Agent.Config

`Planck.Agent.Config` is removed. `planck_agent` becomes a pure library with no
filesystem-reading config module; any function that previously read
`Planck.Agent.Config` takes the path as an explicit argument.

### Changes in `planck_agent`

- Delete `lib/planck/agent/config.ex` (including `PathList`).
- Delete `Planck.Agent.Config.preload/0` / `validate!/0` calls from
  `Planck.Agent.Application`.
- `Planck.Agent.Session.open/1` requires `dir:` — no more `sessions_dir()`
  default. Drop `@spec sessions_dir/0` and the corresponding private function.
- Update moduledoc examples in `Skill`, `ExternalTool`, `Session`, and
  `Compactor` that reference `Planck.Agent.Config.*!()`; replace with
  `Planck.Headless.Config.get/0` examples (or drop the config example in favor
  of explicit-path usage, since `planck_agent` is library-level).
- Remove `use Skogsra` from `planck_agent`. `planck_headless` is the Skogsra
  consumer now. (Skogsra stays as a dependency because `planck_headless` pulls
  it in transitively.)

### Changes in `planck_headless`

- `Planck.Headless.Config` carries every key previously in
  `Planck.Agent.Config`, plus `teams_dirs`, `default_provider`, `default_model`.
- `PathList` Skogsra type moves here as `Planck.Headless.Config.PathList`.
- Env var prefix changes from `PLANCK_AGENT_*` to `PLANCK_*`.

### Rationale

The original spec said "extend" the agent config. In practice that meant two
modules answering "where do skills live?" — confusing and redundant. Moving
everything one layer up eliminates the redundancy and makes the library/app
split honest: `planck_agent` provides primitives that take paths; `planck_headless`
is the configured application that resolves paths once and threads them through.

## Testing strategy

### Config
- JSON loading: happy path, malformed JSON, missing file handled gracefully,
  `~` expansion.
- Precedence: env > project-local JSON > global JSON > application config.
- `PathList`: colon-separated strings, nested list, invalid types.

### ResourceStore
- Boot-time loading: tools, skills, teams from fixture dirs.
- Reload: picks up added and removed teams/tools/skills; in-flight sessions
  unaffected.
- Project-local teams override global on alias collision.

### Session lifecycle
- `start_session/1` happy path: session_id returned, team reachable via PubSub.
- `start_session(template: alias)`: resolves from registry; unknown alias
  returns `{:error, :not_found}`.
- `start_session(template: path)`: loads on the fly, bypasses registry.
- `start_session(template: nil)`: builds dynamic team of one from config; the
  orchestrator's system prompt includes the global skill section; its tool list
  includes every loaded tool.
- `start_session/1` with a malformed template rolls back session + agents + SQLite.
- `resume_session/2`: history restored; fresh team starts with the same spec.
- `close_session/1`: agents terminate; session GenServer stops; SQLite retained.

### Sessions
- `prompt/2`: message reaches orchestrator; `:turn_end` event arrives on
  session topic.
- `list_sessions/0`: returns currently active sessions.

### Teams
- `list_teams/0`: returns aliases with name/description.
- `get_team/1`: hit and `:not_found` cases.

### Other
- `available_models/0`: returns only models whose provider has an API key.
- `reload_resources/0`: new sessions see new resources; existing sessions
  unaffected.
