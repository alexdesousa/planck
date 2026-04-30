# planck_headless

## Purpose

The headless core of the Planck coding agent. `planck_headless` is a long-running
OTP application that owns configuration, loads resources (tools, skills, teams,
compactor) at startup, and manages session lifecycles. Any process — a TUI, a
Phoenix controller, a test — can start a session and interact with it via a clean
API; events flow over the `planck_agent` PubSub already in place.

`planck_cli` depends on `planck_headless` and contains both the TUI and Web UI
as internal modules. They are rendering surfaces only — they never call
`planck_agent` directly.

## What planck_headless owns

- **Configuration** — the single source of truth for all runtime settings.
  Merges `.planck/config.json`, `~/.planck/config.json`, env vars, and
  application config via Skogsra; exposes a resolved `Planck.Headless.Config`
  struct.
- **Startup orchestration** — load skills, teams, and models at application
  start; optionally start the sidecar process (external tools and per-agent
  compactors come from there); make everything available via a `ResourceStore`.
- **Sidecar management** — if `config.sidecar` is set, spawn the sidecar OTP
  application as a separate named node, inject connection env vars, wait for it
  to connect, then discover tools and compactors from it via
  `Planck.Agent.Sidecar` behaviour callbacks.
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

1. **Config** — `Planck.AI.Model.providers()` is called first to ensure
   provider atoms exist; then `Config.preload/0` caches all values (JSON
   files are read via `JsonBinding` as part of the Skogsra binding chain);
   then `Config.validate!/0` fails fast on invalid required values.
   (see *Config* below).
2. **Skills** — `Planck.Agent.Skill.load_all(config.skills_dirs)`.
3. **Teams** — scan `config.teams_dirs` and call `Planck.Agent.Team.load/1` on
   each subdirectory; store in `ResourceStore.teams` keyed by alias. Project-
   local aliases overwrite global ones on collision.
4. **Models** — cloud providers filtered by API key; local models from
   `Config.models!()`.
5. **Sidecar** — if `Config.sidecar!()` is set, spawn the sidecar process,
   wait for it to connect, then call `list_tools/0` to populate
   `ResourceStore.sidecar_tools`. External tools and per-agent compactors
   come exclusively from the sidecar; there is no `tools_dirs` filesystem scan.
6. **ResourceStore** — populate the named GenServer with all of the above.

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
   - `agent_ids` — JSON map of `display_name → agent_id` for all team members,
     used to preserve agent IDs across subsequent resumes.
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
3. **Restore agent IDs** — session metadata stores a `agent_ids` map
   (`%{display_name => agent_id}`) written when the session was first created or
   last resumed. `materialize_team` and `start_workers` use this map to restart
   each agent with its original ID. This keeps the session rows, UI, and
   recovery logic consistent across resumes without any ID-reconciliation code.
4. **Reconstruct dynamic workers** — scan the orchestrator's message history
   (now stable-ID, so no disambiguation needed) for `spawn_agent` calls that
   *completed* (have a matching `tool_result`). Each such call contains the full
   `AgentSpec` as JSON arguments. Workers are deduplicated against the base team
   by `{type, name}` pair. The original IDs are reused via the `agent_ids` map.

This gives a complete picture of the team as it existed at the time of
interruption, without re-reading TEAM.json for workers that were spawned on the
fly.

### In-flight detection

A worker is considered unfinished when their most recent `:user` message (the
task that was last assigned to them) has no `send_response` tool call in any
`:assistant` message that follows it in the worker's history. The full session
history is scanned — not just in-memory context — so compacted history is still
checked correctly.

`resume_session/1` builds the in-flight list by:
1. Identifying all non-orchestrator agents in the session rows.
2. For each, calling `worker_unfinished?/1`: find the last `:user` message;
   if any subsequent `:assistant` message calls `send_response`, the worker is
   done; otherwise it is unfinished.
3. Cross-referencing the orchestrator's `delegate_task` calls (matched by task
   text) to surface the target name and task in the recovery message.

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
- Dynamic worker reconstruction: completed `spawn_agent` calls (those with a
  matching `tool_result`) recreate workers with fresh `agent_id`s deduped by
  `{type, name}` against the base team; they appear in `list_team` after resume.
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

Config keys that can be set in `.planck/config.json` use
`binding_order: [:system, JsonBinding, :config]`. Skogsra resolves each key
by trying sources in order:

1. **Environment variables** — `PLANCK_*` (see table below).
2. **JSON config files** — `~/.planck/config.json` (global) then
   `.planck/config.json` (project-local, wins on collision), read by
   `Planck.Headless.Config.JsonBinding` at resolution time and cached.
3. **Application config** — `config :planck, <key>, ...` from `config/*.exs`
   or `config/runtime.exs`.
4. **Hardcoded defaults** — built into each `app_env` declaration.

API keys use the default Skogsra binding order (env vars → app config → default)
and are never read from JSON files.

At boot, `Application.start/2`:

1. Calls `Planck.AI.Model.providers()` to ensure provider atoms (`:llama_cpp`
   etc.) exist before Skogsra preloads the `:models` key.
2. `Config.preload/0` — Skogsra resolves and caches all values; JSON files are
   read here via `JsonBinding`.
3. `Config.validate!/0` — fails fast on invalid required values.

Values are cached after `preload/0`; to change a value at runtime call
`Application.put_env/3` and then `reload_<key>/0` to invalidate that key's cache.
Call `JsonBinding.invalidate/0` to bust the JSON file cache before reloading.

### JSON file format

```json
{
  "default_provider": "anthropic",
  "default_model":    "claude-sonnet-4-6",
  "sessions_dir":     ".planck/sessions",
  "skills_dirs":      ["~/.planck/skills"],
  "teams_dirs":       ["~/.planck/teams"],
  "sidecar":          ".planck/sidecar",
  "models": [
    {
      "id":             "llama3.2",
      "provider":       "ollama",
      "base_url":       "http://localhost:11434",
      "context_window": 128000
    },
    {
      "id":             "mistral",
      "provider":       "llama_cpp",
      "base_url":       "http://localhost:8080",
      "context_window": 32768
    }
  ]
}
```

`tools_dirs` and `compactor` keys are removed — external tools and per-agent
compactors come from the sidecar. See `specs/sidecar.md`.

The `models` list uses the same format as `Planck.AI.Config` — only `"id"`
and `"provider"` are required. This replaces the old `local_servers` approach:
models are **declared** (no network discovery at boot) and include full
`Planck.AI.Model` fields (`context_window`, `max_tokens`, `base_url`, etc.).
Cloud providers that have an API key still contribute their static LLMDB
catalog on top.

All keys are optional. Unknown keys are silently ignored. Arrays replace
rather than merge — a project-local `skills_dirs` wholly supersedes the
global one. `:models` has no `PLANCK_*` env var equivalent — the format is
too structured for a flat string.

### Struct

```elixir
%Planck.Headless.Config{
  default_provider:  atom() | nil,
  default_model:     String.t() | nil,
  sessions_dir:      Path.t(),
  skills_dirs:       [Path.t()],
  teams_dirs:        [Path.t()],
  sidecar:           Path.t(),        # defaults to ".planck/sidecar"; skipped if absent on disk
  models:            [Planck.AI.Model.t()]
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
| `PLANCK_TEAMS_DIRS`       | `:teams_dirs`        | `.planck/teams:~/.planck/teams`   |
| `PLANCK_SIDECAR`          | `:sidecar`           | `.planck/sidecar`                 |
| `PLANCK_CONFIG_FILES`     | `:config_files`      | `~/.planck/config.json:.planck/config.json` |

`*_DIRS` env vars take a colon-separated list, parsed via an inline
`PathList` Skogsra type.

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

# Generated by `use Skogsra`. Called at boot by Application.start/2.
@spec preload() :: :ok
@spec validate!() :: :ok

# For each key <name>, Skogsra also generates:
#   <name>!()       — resolve, raise on missing-required
#   reload_<name>() — invalidate the persistent-term cache for this key

# Bust the JsonBinding persistent-term cache (call before reload_resources/0
# when you want JSON file changes to take effect immediately).
@spec Planck.Headless.Config.JsonBinding.invalidate() :: :ok
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
