# Teams

A **team** is a named, runtime collection of agents that share a `team_id` and
can address each other via the inter-agent tools (`ask_agent`, `delegate_task`,
`send_response`, `list_team`). Every team has exactly one orchestrator; other
members are workers.

Teams can be created two ways:

- **Static** — hydrated from a directory on disk (`.planck/teams/<alias>/`) at
  session start, selected by alias.
- **Dynamic** — started as a lone orchestrator, which then calls `spawn_agent`
  to add workers at runtime. No filesystem footprint.

Both paths produce the same runtime representation. Callers (TUI, Web UI) treat
them uniformly once a session is running.

When no template is supplied, `start_session/1` builds a one-member dynamic
team — a lone orchestrator whose config comes from `planck_headless`. The
orchestrator can grow the team at runtime via `spawn_agent`.

## Directory layout

```
.planck/teams/
  elixir-dev-workflow/
    TEAM.json                          # required — member list and metadata
    members/
      orchestrator.md                  # system prompt for the orchestrator
      planner.md
      builder.md
```

The alias is the folder name (`elixir-dev-workflow`). TEAM.json is the source
of truth for membership and ordering. Each member's system prompt lives in a
flat file at `members/<name>.md` by convention, where `<name>` is the member's
`name` field (which defaults to `type` when not set). So a single-builder team
keeps `members/builder.md`; a Bob+Charlie team keeps `members/Bob.md` and
`members/Charlie.md`.

Tools and skills are **always global** (loaded by `planck_headless` from
`~/.planck/tools` and `~/.planck/skills`). Each member declares which ones it
sees via the `"tools"` and `"skills"` arrays in its TEAM.json entry — names
are resolved against the global pool at agent-start time. There is no member
folder for per-member resources; the scoping is in the declaration, not the
filesystem layout.

### Locations and precedence

Teams are loaded from two roots, in priority order (highest first):

1. `.planck/teams/` in the current working directory (project-local)
2. `~/.planck/teams/` (user-global)

On alias collision, project-local wins entirely — there is no per-member
merging between global and project-local versions of the same team. This
mirrors the config precedence rule in `planck-headless.md`.

## TEAM.json

```json
{
  "name":        "elixir-dev-workflow",
  "description": "Plan, build, and test Elixir changes with a small team.",
  "members": [
    {
      "type":          "orchestrator",
      "name":          "Coordinator",
      "description":   "Delegates and synthesizes.",
      "provider":      "anthropic",
      "model_id":      "claude-sonnet-4-6",
      "system_prompt": "members/orchestrator.md",
      "tools":         ["read"],
      "skills":        ["planning"]
    },
    {
      "type":          "planner",
      "name":          "Planner",
      "description":   "Breaks tasks into steps.",
      "provider":      "anthropic",
      "model_id":      "claude-sonnet-4-6",
      "system_prompt": "members/planner.md"
    },
    {
      "type":          "builder",
      "name":          "Builder",
      "description":   "Writes and edits code.",
      "provider":      "anthropic",
      "model_id":      "claude-sonnet-4-6",
      "system_prompt": "members/builder.md",
      "tools":         ["read", "write", "edit", "bash"],
      "skills":        ["refactor"]
    }
  ]
}
```

### Required fields

| Field     | Type   | Description                                     |
|-----------|--------|-------------------------------------------------|
| `name`    | string | Human-readable team name (informational)        |
| `members` | array  | Non-empty list of member entries                |

### Optional fields

| Field         | Type   | Description                         |
|---------------|--------|-------------------------------------|
| `description` | string | One-line purpose shown via `/team`  |

### Member entries

Each entry in `members` describes a single agent. The full field reference
lives in the `Planck.Agent.AgentSpec` module docs; the summary is:

| Field           | Req | Description                                                    |
|-----------------|-----|----------------------------------------------------------------|
| `type`          | ✓   | Role identifier (e.g. `"orchestrator"`, `"builder"`)           |
| `provider`      | ✓   | LLM provider (`anthropic`, `openai`, `google`, `ollama`, `llama_cpp`) |
| `model_id`      | ✓   | Provider-specific model id (e.g. `"claude-sonnet-4-6"`)        |
| `name`          |     | Human-readable label; defaults to `type` when absent. Disambiguates when `type` repeats — required in that case. |
| `description`   |     | One-line purpose shown to other agents via `list_team`         |
| `system_prompt` |     | Inline text, or a `.md`/`.txt` path relative to the team dir   |
| `opts`          |     | Provider-specific options (e.g. `{"temperature": 0.7}`)        |
| `tools`         |     | Tool names resolved from the global tool pool at start (e.g. `["read", "bash"]`) |
| `skills`        |     | Skill names resolved from the global skill pool at start; appended to `system_prompt` |

Exactly one member must have `"type": "orchestrator"`; the rest are workers.

**Types may repeat** (e.g. two `"builder"` members named "Bob" and "Charlie").
`name` defaults to `type` when not provided, which means multiple same-type
members must declare explicit names — otherwise `Team.load/1` rejects the team
with a duplicate-name error. Repeated types with unique names are accepted.

> Note: the existing `spawn_agent` tool forbids duplicate types at runtime
> (`planck_agent/lib/planck/agent/tools.ex`). That constraint is inconsistent
> with the `Planck.Agent.Registry`, which is configured with `keys: :duplicate`
> and already allows repeated types. Loosening `spawn_agent` and making type
> lookups explicit about ambiguity is a planned follow-up and out of scope for
> this spec.

`system_prompt` paths are resolved **relative to the team directory**. The
convention is `"members/<name>.md"` where `<name>` is the member's `name`
field.

## Scoping tools and skills

Tools and skills are global resources loaded once by `planck_headless` into a
shared pool. Each member declares which entries it sees via the `"tools"` and
`"skills"` arrays in its TEAM.json entry; names are resolved against the pool
at agent-start time (in `AgentSpec.to_start_opts/2`).

- An **empty** `"tools"`/`"skills"` array (or absent key) means the member
  gets nothing from that pool by default. The caller can still pass extra
  tools via the `tools:` override at start time.
- Resolved skills have their descriptions appended to `system_prompt` via
  `Planck.Agent.Skill.system_prompt_section/1`. If `"skills"` is empty, the
  prompt passes through unchanged.
- There is no filesystem scoping — per-member skill/tool folders do not exist.
  The scoping lives in the TEAM.json declaration alone.

For the dynamic-team case, the orchestrator's `spawn_agent` tool accepts the
same `"skills"` parameter (plus a `grantable_skills:` closure arg on the
orchestrator side, symmetric to `grantable_tools:`). The orchestrator can
thus attach specific skills to the workers it spawns.

## Runtime model

Both static and dynamic teams hydrate into the same struct:

```elixir
%Planck.Agent.Team{
  id:          String.t() | nil,   # team_id, generated at materialization (nil pre-start)
  alias:       String.t() | nil,   # "elixir-dev-workflow", or nil if dynamic
  source:      :filesystem | :dynamic,
  name:        String.t() | nil,
  description: String.t() | nil,
  dir:         Path.t() | nil,     # team directory (nil for dynamic)
  members:     [Planck.Agent.AgentSpec.t()]
}
```

- `source: :filesystem` — loaded from `.planck/teams/<alias>/TEAM.json`.
- `source: :dynamic` — started as a lone orchestrator built from config.
  Workers may be added later via `spawn_agent`, which uses the same `team_id`
  so spawned members join additively (no sub-team concept). Covers both the
  no-template fallback and orchestrator-driven team growth.

`spawn_agent` accepts the same member-entry schema used by TEAM.json. This
keeps one representation across the static and dynamic paths and lets a
team-generation skill round-trip its output through `Team.load/1`.

## Loading

### Registry

`planck_headless`'s `ResourceStore` is extended to hold a team registry:

```elixir
%Planck.Headless.ResourceStore{
  tools:            [Planck.Agent.Tool.t()],
  skills:           [Planck.Agent.Skill.t()],
  on_compact:       function(),
  available_models: [Planck.AI.Model.t()],
  teams:            %{String.t() => Planck.Agent.Team.t()}  # alias => team
}
```

At boot, `planck_headless`:

1. Scans `~/.planck/teams/*/TEAM.json` and `.planck/teams/*/TEAM.json`.
2. For each directory, parses TEAM.json and resolves member `system_prompt`
   paths relative to the team directory.
3. Stores the resulting `%Team{}` under its alias in `ResourceStore`.
4. Project-local aliases overwrite global ones on collision.

Invalid TEAM.json files are skipped with a warning; the rest load. Same rule
as `ExternalTool.load_all/1` and `Skill.load_all/1`.

### Resolution at session start

`Planck.Headless.start_session/1` accepts:

- `template: alias_or_path` — an alias string (looked up in the team registry)
  or a filesystem path to a TEAM.json (parsed on the fly, bypassing the
  registry). Defaults to `nil`, which builds a one-member dynamic team (lone
  orchestrator from config).

```elixir
# Static team by alias
{:ok, sid} = Planck.Headless.start_session(template: "elixir-dev-workflow")

# Explicit path override (not in the registry)
{:ok, sid} = Planck.Headless.start_session(template: "/tmp/my-team/TEAM.json")

# Dynamic team of one — lone orchestrator built from config
{:ok, sid} = Planck.Headless.start_session()
```

### Reload

`Planck.Headless.reload_resources/0` rescans team directories alongside tools
and skills. In-flight sessions keep the team they were started with — same
contract as other resources.

## Slash commands (TUI / Web UI)

The UI exposes two commands for team selection. Rendering surfaces implement
these; `planck_headless` just provides the data and the session-start hook.

### `/team [alias]`

- No argument: list all registered teams (alias, name, description).
- With alias: start a new session with that team. Only valid when no session
  is currently active — otherwise the UI rejects the command and suggests
  `/new` first.

### `/new`

Close the current session and return to the input prompt. Combine with `/team`
to switch teams:

```
/new
/team elixir-dev-workflow
```

### Default input behavior

- Plain prompt → start a session with a dynamic team of one (orchestrator
  built from config) and send the prompt. The orchestrator handles it,
  optionally calling `spawn_agent` to grow the team.
- `/team <alias>` → start a session with that static team; subsequent input is
  a prompt to the orchestrator.

## Dynamic team generation

Dynamic teams require no new machinery. The orchestrator's `spawn_agent` tool
already supports arbitrary member creation with the same schema used by
TEAM.json entries. A dynamic team is simply a static team that was never
serialized.

A future skill (`new_team`) can guide the orchestrator to scaffold a
`.planck/teams/<alias>/` directory from an existing dynamic team — e.g. "save
this team as elixir-dev-workflow." The output format is exactly the directory
layout defined above, so the saved team loads on next boot without special
handling. This is scope for a later iteration; the spec only reserves the
skill name.

## Public API

```elixir
# Planck.Agent.Team
#
# Load a team from a directory. Returns {:ok, %Team{}} or {:error, reason}.
# Resolves member system_prompt paths relative to the team dir.
@spec load(Path.t()) :: {:ok, Planck.Agent.Team.t()} | {:error, term()}

# Planck.Headless
#
# List all registered team aliases with metadata for /team display.
@spec list_teams() :: [%{alias: String.t(), name: String.t(), description: String.t() | nil}]

# Look up a team by alias.
@spec get_team(String.t()) :: {:ok, Planck.Agent.Team.t()} | {:error, :not_found}
```

`start_session/1` is extended (not replaced): the existing `template:` option
now accepts an alias in addition to a path.

## Package ownership

- `planck_agent` owns `%Planck.Agent.Team{}`, `Planck.Agent.Team.load/1`, and
  the TEAM.json parser. A single team is a `planck_agent` concern.
- `planck_headless` owns the registry (boot-time scan, alias lookup, reload).
  Collections of teams are a `planck_headless` concern, same pattern as tools
  and skills.
- `planck_tui` and `planck_web` own the slash commands and the team-selection
  UI. They call `Planck.Headless.list_teams/0` and
  `Planck.Headless.start_session(template: alias)`.

## Testing strategy

- `Team.load/1` — happy path for a valid directory; rejects missing TEAM.json;
  skips malformed member entries with warnings; resolves `system_prompt`
  paths; parses member `skills` and `tools` arrays.
- `AgentSpec.to_start_opts/2` — resolves `spec.skills` against `skill_pool:`;
  appends the skill section to the system prompt when non-empty; passes
  through unchanged when empty.
- `ResourceStore` — scans both roots at boot; project-local overrides global
  on collision; reload picks up new/removed teams; in-flight sessions keep
  their original team.
- `start_session(template: alias)` — resolves alias; errors cleanly on unknown
  alias; path override bypasses registry.
- `start_session(template: path)` — still works for explicit paths not in the
  registry.
- No-template fallback — `start_session()` with no template spins up a
  one-member dynamic team (lone orchestrator from config) with the full global
  tool pool.
- Dynamic team growth — orchestrator spawns a worker via `spawn_agent`;
  `list_team` includes the new member under the same `team_id`.
- `spawn_agent` skills — granted skills are appended to the spawned agent's
  system prompt; unknown names are silently ignored.
