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
  Merges `.planck/config.json`, `~/.planck/config.json`, env vars, and
  application config via Skogsra; exposes a resolved `Planck.Headless.Config`
  struct.
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

- **Session naming** — generate and sanitize human-readable session names
  (`<adjective>-<noun>`) and embed them in SQLite filenames alongside the id
  for O(1) lookup by either id or name.

## What planck_headless does NOT own

- Rendering — no TUI or HTML; events flow via PubSub.
- Slash commands and prompt templates — UI-layer concerns.
- The agent loop — that is `planck_agent`'s responsibility.
- HTTP transport and LLM calls — that is `planck_ai`'s responsibility.

## Dependencies

```elixir
{:planck_agent, "~> 0.1"},
{:jason, "~> 1.4"},
{:skogsra, "~> 2.5"}
```

`planck_agent` transitively provides `Phoenix.PubSub`, `erlexec`, and
`exqlite`. `jason` is a direct dependency for reading `.planck/config.json`.
`skogsra` is the direct config dependency.

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
#   name:        String.t() | nil             — human-readable name; auto-generated
#                                               as "<adjective>-<noun>" if not provided
#   cwd:         Path.t()                     — working directory (default: File.cwd!())
@spec start_session(keyword()) :: {:ok, session_id :: String.t()} | {:error, term()}

# Resume a session by session_id or by name. Reconstructs the team, restores
# message history, injects a recovery context message if prior work was
# interrupted, and starts fresh agent processes.
# See *Session resumption* for the full flow.
@spec resume_session(id_or_name :: String.t(), keyword()) ::
        {:ok, session_id :: String.t()} | {:error, term()}

# Close a session. Stops the agent team and the session GenServer; the SQLite
# file is retained for later resumption.
@spec close_session(String.t()) :: :ok

# Send a user prompt to the orchestrator of a session.
@spec prompt(String.t(), String.t()) :: :ok | {:error, term()}

# List all sessions on disk (active and inactive) with their id, name, and
# whether they are currently running.
@spec list_sessions() ::
        [%{session_id: String.t(), name: String.t(), active: boolean()}]

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

1. **Config** — `Config.load/0` reads `.planck/config.json` and
   `~/.planck/config.json` into the `:planck` application env; then
   `Config.preload/0` caches all values; then `Config.validate!/0` fails fast
   on invalid required values. (see *Config* below).
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
2. Generate a `session_id` (random hex) and resolve the session name:
   - Use `opts[:name]` if provided, sanitized to `[a-z0-9-]+`.
   - Otherwise auto-generate via `Planck.Headless.SessionName.generate/1`,
     which picks an `<adjective>-<noun>` pair that is not already in use
     under `sessions_dir`. Retries on collision.
3. Start `Planck.Agent.Session` under `SessionSupervisor` with
   `id: session_id`, `name: session_name`, `dir: Config.sessions_dir!()`.
   The session file is created as `<sessions_dir>/<session_id>_<name>.db`.
4. Save session metadata via `Session.save_metadata/2`:
   - `team_alias` — the alias string, path, or `nil` for dynamic-only sessions.
   - `session_name` — the resolved name (mirrors the filename component).
   - `cwd` — from `opts[:cwd]` (default `File.cwd!()`).
5. For each member in the team, call `AgentSpec.to_start_opts/2` with:
   - `tool_pool:` from `ResourceStore.tools`
   - `skill_pool:` from `ResourceStore.skills`
   - `team_id:` and `session_id:` for this session
   - `available_models:` from `ResourceStore`
   - `on_compact:` from `ResourceStore.on_compact`
6. Start each agent under `Planck.Agent.AgentSupervisor`.
7. Record `session_id → team_id` in `SessionRegistry`.
8. Return `{:ok, session_id}`.

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

## Session resumption

`resume_session/1` reconstructs a session that was previously closed or
interrupted. The SQLite file survives; the agent processes must be recreated.

### Locating the session file

`resume_session/1` accepts either a session id or a session name:

- **By id** — `Session.find_by_id(sessions_dir, id)` globs
  `<sessions_dir>/<id>_*.db`. Returns `{:ok, path, name}`.
- **By name** — `Session.find_by_name(sessions_dir, name)` globs
  `<sessions_dir>/*_<name>.db`. Returns `{:ok, path, id}`.

Both return `{:error, :not_found}` if no matching file exists.

### Team reconstruction

1. **Read session metadata** — `Session.get_metadata/1` returns `team_alias`,
   `cwd`, and `session_name` that were stored when the session was first created.
2. **Reload the base team**:
   - `team_alias` is an alias string → look it up in the ResourceStore.
   - `team_alias` is an absolute path → `Team.load/1` on the fly.
   - `team_alias` is `nil` → the session was dynamic-only; start with a lone
     orchestrator built from config (same as `start_session(template: nil)`).
3. **Reconstruct dynamic workers** — scan the orchestrator's message history for
   `spawn_agent` tool calls. Each call contains the full `AgentSpec` as JSON
   arguments. Any worker that was spawned at runtime but is not in the base team
   is reconstructed from that call. New `agent_id`s are generated; the delegator
   is the new orchestrator's id.

This gives a complete picture of the team as it existed at the time of
interruption, without re-reading TEAM.json for workers that were spawned on the
fly.

### In-flight detection

An in-flight delegation is a `delegate_task` tool call in the orchestrator's
message history that has no corresponding `agent_response` before the next user
turn (or before the history ends). Concretely:

- After `delegate_task(type: "builder", task: "...")`, the orchestrator's
  history should contain an `agent_response` injected via `handle_info`.
- If no such response appears before the turn boundary, the delegation was
  in-flight at interruption time.

`resume_session/1` collects the list of such dangling delegations.

### Recovery context injection

After all agents are started, `resume_session/1` injects a recovery message into
the orchestrator's context before the orchestrator receives any new user input:

```
Session resumed after interruption.

The following delegations were in progress when the session ended and did not
receive a response:

- builder ("Bob"): "Refactor lib/app.ex to use a GenServer"
- tester ("Alice"): "Write tests for the new GenServer"

These agents have been restarted. Re-delegate their tasks as needed, or ask
the user how to proceed.
```

If no delegations were in-flight (clean resumption), no recovery message is
injected — the orchestrator simply continues with its existing history.

The recovery context is a `:user` message appended to the orchestrator's session
history; it is included in the next LLM call as part of the conversation.

### Testing strategy (resumption)

- Clean resume: session with complete history resumes without a recovery message;
  orchestrator's first call sees the same history.
- Interrupted resume: last orchestrator turn contained a `delegate_task` with no
  matching `agent_response`; recovery message lists the dangling delegation.
- Multiple in-flight delegations: all are listed in the recovery message.
- Dynamic worker reconstruction: `spawn_agent` calls in history recreate workers
  with fresh `agent_id`s; they appear in `list_team` output after resume.
- Static team on resume: `team_alias` from metadata reloads the same TEAM.json;
  if the file has changed since the session was created, the new definition is
  used (intentional — teams on disk are the source of truth).

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

Config is resolved from four sources, highest priority first:

1. **Environment variables** — `PLANCK_*` (see table below).
2. **Project-local JSON** — `.planck/config.json` in `File.cwd!()`.
3. **User-global JSON** — `~/.planck/config.json`.
4. **Application config** — `config :planck, <key>, ...` from `config/*.exs`
   or `config/runtime.exs`.
5. **Hardcoded defaults** — built into each `app_env` declaration.

At boot, `Application.start/2` runs in this order:

1. `Config.load/0` — reads the JSON files and puts their values into the
   `:planck` application env (project-local wins on collision).
2. `Config.preload/0` — Skogsra caches the resolved values into persistent terms.
3. `Config.validate!/0` — fails fast on any invalid required values.

Values are cached after `preload/0`; to change a value at runtime call
`Application.put_env/3` and then `reload_<key>/0` to invalidate that key's cache.

### JSON file format

```json
{
  "default_provider": "anthropic",
  "default_model":    "claude-sonnet-4-6",
  "sessions_dir":     ".planck/sessions",
  "skills_dirs":      ["~/.planck/skills"],
  "tools_dirs":       ["~/.planck/tools"],
  "teams_dirs":       ["~/.planck/teams"],
  "local_servers": [
    {"type": "ollama",    "base_url": "http://localhost:11434"},
    {"type": "llama_cpp", "base_url": "http://localhost:8080"}
  ],
  "compactor": "~/.planck/compactor.exs"
}
```

All keys are optional. Unknown keys are silently ignored. Arrays replace
rather than merge — a project-local `skills_dirs` wholly supersedes the
global one.

### Struct

```elixir
%Planck.Headless.Config{
  default_provider:  atom() | nil,
  default_model:     String.t() | nil,
  sessions_dir:      Path.t(),
  skills_dirs:       [Path.t()],
  tools_dirs:        [Path.t()],
  teams_dirs:        [Path.t()],
  compactor:         Path.t() | nil,
  local_servers:     [%{type: atom(), base_url: String.t()}]
}
```

### Env vars and defaults

#### Planner config

| Env var                   | Config key           | Default                           |
|---------------------------|----------------------|-----------------------------------|
| `PLANCK_DEFAULT_PROVIDER` | `:default_provider`  | `nil`                             |
| `PLANCK_DEFAULT_MODEL`    | `:default_model`     | `nil`                             |
| `PLANCK_SESSIONS_DIR`     | `:sessions_dir`      | `.planck/sessions`                |
| `PLANCK_SKILLS_DIRS`      | `:skills_dirs`       | `.planck/skills:~/.planck/skills` |
| `PLANCK_TOOLS_DIRS`       | `:tools_dirs`        | `.planck/tools:~/.planck/tools`   |
| `PLANCK_TEAMS_DIRS`       | `:teams_dirs`        | `.planck/teams:~/.planck/teams`   |
| `PLANCK_COMPACTOR`        | `:compactor`         | `nil`                             |
| `PLANCK_LOCAL_SERVERS`    | `:local_servers`     | `[]`                              |
| `PLANCK_CONFIG_FILES`     | `:config_files`      | `~/.planck/config.json:.planck/config.json` |

`*_DIRS` env vars take a colon-separated list. `PLANCK_LOCAL_SERVERS` takes a
comma-separated `type:base_url` list (e.g.
`ollama:http://localhost:11434,llama_cpp:http://localhost:8080`). Both forms
are parsed via inline Skogsra types (`PathList` and `LocalServers`).

#### Provider API keys

API keys are declared with `os_env:` so they map to the canonical provider
env var names. They are **not** in `Config.get()` or the `%Config{}` struct —
use the generated getters directly to avoid accidental exposure in logs.

| Env var             | Config key             | Provider           |
|---------------------|------------------------|--------------------|
| `ANTHROPIC_API_KEY` | `:anthropic_api_key`   | Anthropic (Claude) |
| `OPENAI_API_KEY`    | `:openai_api_key`      | OpenAI             |
| `GOOGLE_API_KEY`    | `:google_api_key`      | Google (Gemini)    |

### API

```elixir
# Resolved config struct.
@spec get() :: t()

# Read JSON files into application env. Must be called before preload/0.
@spec load() :: :ok

# Generated by `use Skogsra`. Called at boot by Application.start/2.
@spec preload() :: :ok
@spec validate!() :: :ok

# For each key <name>, Skogsra also generates:
#   <name>!()       — resolve, raise on missing-required
#   reload_<name>() — invalidate the persistent-term cache for this key
```

## Supervision tree

```
:planck_agent application          :planck_headless application
───────────────────────────        ──────────────────────────────────────────
Planck.Agent.Supervisor            Planck.Headless.Supervisor  (one_for_one)
  (started by :planck_agent)       └── Planck.Headless.AppSupervisor (one_for_one)
                                       ├── Planck.Headless.ResourceStore
                                       └── Planck.Headless.SessionRegistry
```

`Planck.Agent.Supervisor` is **not** a child of `Planck.Headless.Supervisor` —
it is started by the `:planck_agent` OTP application before `planck_headless`
boots. Adding it as a child would fail with "already started". Callers must
include both `:planck_agent` and `:planck_headless` in their application's
`extra_applications` (or depend on them as Mix deps, which is equivalent).

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
- `get/0`: returns struct with declared defaults when nothing is configured.
- Application-env override: `Application.put_env/3` followed by
  `reload_<key>/0` picks up the new value.
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
- `start_session/1` saves team_alias, cwd, session_name in session metadata.
- `resume_session/2`: see *Session resumption* testing strategy above.
- `close_session/1`: agents terminate; session GenServer stops; SQLite retained.

### Sessions
- `prompt/2`: message reaches orchestrator; `:turn_end` event arrives on
  session topic.
- `list_sessions/0`: returns all sessions on disk with id, name, and
  active status; auto-generated names are present for all entries.

### SessionName
- Auto-generation produces `<adjective>-<noun>` format, all lowercase,
  matching `[a-z]+-[a-z]+`.
- Collision retry: generates a new pair if the name already exists on disk.
- Sanitization: user-provided names are lowercased, spaces → hyphens,
  non-`[a-z0-9-]` characters stripped, result truncated to a reasonable
  length.
- `resume_session/1` by name: `find_by_name` resolves correctly when the
  name matches exactly; unknown name returns `{:error, :not_found}`.

### Teams
- `list_teams/0`: returns aliases with name/description.
- `get_team/1`: hit and `:not_found` cases.

### Other
- `available_models/0`: returns only models whose provider has an API key.
- `reload_resources/0`: new sessions see new resources; existing sessions
  unaffected.
