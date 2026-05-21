# Skills

Skills are reusable agent capabilities stored as directories on the filesystem.
Each skill has a `SKILL.md` file with a name and description, and an optional
`resources/` directory for supporting files the agent reads at runtime.

Agents load skills on demand via the `load_skill` built-in tool.

## Directory structure

```
<skills_dir>/
  code_review/
    SKILL.md         # required
    resources/
      rubric.md      # optional — any files the agent may reference
  test_generation/
    SKILL.md
    resources/
      patterns.md
```

## SKILL.md format

```markdown
---
name: code_review
description: Reviews code for correctness, style, and performance.
always_present: false
planck_version: "0.1.7"
---

# Code Review

Full instructions for this skill go here. The agent loads this file via
`load_skill` when the skill is relevant to the current task.

## Resources

- `resources/rubric.md` — review rubric (load via `read` with the absolute path)
```

Frontmatter is YAML-style (one `key: value` per line). `name` and `description`
are required. Windows line endings (CRLF) are normalized before parsing.

### Frontmatter fields

| Field           | Type      | Required | Default | Description |
|-----------------|-----------|----------|---------|-------------|
| `name`          | string    | yes      | —       | Unique skill identifier used in TEAM.json and `load_skill` calls |
| `description`   | string    | yes      | —       | One-line summary shown in the system prompt index |
| `always_present`| boolean   | no       | `false` | When `true`, the skill is always included in the system prompt index regardless of ranking |
| `planck_version`| string    | no       | `nil`   | Optional minimum Planck version constraint (informational only) |

## How agents use skills

### Declared skills (predictable, pre-configured)

Skills can be declared per-agent in TEAM.json. Skill names are stored in
`AgentSpec` and resolved into a `SkillIndex` at session start.

The system prompt skill section is built from a **frozen** `SkillIndex.pool`
captured when the session starts. It is rebuilt only after context compaction
(via `index_refresh_fn`) — keeping token counts stable and predictable across
turns. The live `skill_refresh_fn` is used exclusively by the `load_skill` and
`list_skills` tools so agents can access the current pool on demand.

The section appended to the system prompt has three parts:

1. **Pinned** — skills with `always_present: true` in their frontmatter (always shown).
2. **Last-used** — up to `top_n` skills ordered by SQLite usage ranking for this agent.
3. **Discovery line** — guides the agent to call `list_skills` or `load_skill` by name.

Example output:

```
## Available skills

- **elixir-style** — Enforces Elixir style and formatting conventions.
- **code_review** — Reviews code for correctness, style, and performance.

Call `list_skills` to see all available skills, or `load_skill` with a name to load one.
```

When the orchestrator delegates a task that requires a skill the worker doesn't
have declared, it can instruct the worker to use it by name (e.g. "use the
`n8n-workflows` skill for this"). The worker then calls `load_skill("n8n-workflows")`
directly — no system prompt update is needed.

### `load_skill` tool (automatic)

Every agent automatically receives the `load_skill` tool when skills are
available — no TEAM.json declaration needed. It loads a skill's full `SKILL.md`
content by name:

```json
{ "name": "elixir-dev" }
```

Returns the full SKILL.md text, or an error listing available names if not found.

On each successful call, `load_skill` fires the `on_use:` callback (supplied by
`planck_headless`), which records the use in the per-project SQLite DB via
`SkillUsage.record_use/5`. This drives the last-used ranking shown in subsequent
system prompt sections.

`load_skill_tool/1` accepts an `opts` keyword list:
- `skill_refresh_fn:` — resolves the skill pool at call time (live pool access).
- `on_use:` — callback `(skill_name -> :ok)` fired on each successful load.

### `list_skills` tool (orchestrator: automatic; workers: opt-in)

The orchestrator always receives `list_skills` when skills are available — it
needs to know what's in the pool to direct workers effectively.

Workers do not get `list_skills` by default. Add `"list_skills"` to a worker's
TEAM.json `"tools"` array only when that worker needs autonomous skill discovery
(rare — workers usually receive skill names from the orchestrator).

## TEAM.json example

```json
{
  "name": "dev-team",
  "members": [
    {
      "type": "orchestrator",
      "provider": "anthropic",
      "model_id": "claude-opus-4-7",
      "system_prompt": "You coordinate the team.",
      "tools": ["read", "write", "edit", "bash", "list_skills"]
    },
    {
      "type": "builder",
      "name": "Builder",
      "provider": "anthropic",
      "model_id": "claude-sonnet-4-6",
      "system_prompt": "You implement features.",
      "tools": ["read", "write", "edit", "bash"],
      "skills": ["elixir-dev"]
    }
  ]
}
```

In this setup:
- The orchestrator can call `list_skills` to discover what's available
- The builder has `elixir-dev` pre-loaded in its system prompt
- Both agents automatically have `load_skill` available
- If a task needs `code_review`, the orchestrator tells the builder to use it

## Typical usage (via `AgentSpec.to_start_opts/2`)

`planck_headless` builds a `%SkillIndex{}` per agent and passes it as `skills:`:

```elixir
all_skills = Planck.Agent.Skill.load_all(["~/.planck/skills", ".planck/skills"])

skill_index = %Planck.Agent.SkillIndex{
  pool:      all_skills,   # frozen at session start
  ranked:    SkillUsage.ranked_names(project_dir, team_name, agent_name, all_skills, top_n),
  top_n:     top_n,
  names:     spec.skills,
  refresh_fn: fn -> ResourceStore.get().skills end
}

start_opts = AgentSpec.to_start_opts(spec,
  tool_pool: builtins ++ custom_tools,
  skills:    skill_index,
  team_id:   team_id
)
```

`load_skill` is **not** resolved from `tool_pool` — it is injected directly by
`AgentSpec.resolve_tools/2` whenever a `skills:` index is present.
Every agent gets it automatically regardless of what it declares.

`list_skills` is added to `tool_pool` by `planck_headless` when skills exist.
Like any other tool, it only reaches an agent if the agent declares
`"list_skills"` in its TEAM.json `"tools"` array.

## Skill usage ranking (SkillUsage)

`Planck.Agent.SkillUsage` tracks how often each agent calls `load_skill` and
uses that history to rank the skills shown in the system prompt index.

### Storage

A per-project SQLite DB is kept at `.planck/skills.db`. Schema:

```
(team_name, agent_name, agent_type, skill_name, use_count, last_used)
PRIMARY KEY (team_name, agent_name, skill_name)
```

`agent_name` is `spec.name || spec.type` — stable across restarts.
`team_name` is `team.alias` — stable across restarts.
Dynamic workers receive no ranking. Dynamic orchestrators share a combined
ranking via `top_n_for_orchestrators/3` (union over `agent_type`).

### Cold-start fallback

When no SQLite history exists yet (first run, or the DB was deleted), `ranked_names/5`
falls back to sorting skills by mtime of their `SKILL.md` file (most recently
modified first). This ensures the system prompt index is populated from the start
without requiring prior usage data.

### `top_skills` config key

`Planck.Headless.Config` exposes a `top_skills` key (default `5`) that controls
how many last-used skills appear in the system prompt index per agent. Settable
in `config.json`:

```json
{ "top_skills": 8 }
```

## Configuration

| Env var                      | Config key     | Default                           |
|------------------------------|----------------|-----------------------------------|
| `PLANCK_AGENT_SKILLS_DIRS`   | `:skills_dirs` | `.planck/skills:~/.planck/skills` |

Colon-separated list of directories, expanded at runtime. Configured via
`Planck.Agent.Config.skills_dirs!/0`.

```elixir
config :planck_agent, :skills_dirs, [".planck/skills", "~/.planck/skills"]
```

## API

### `Planck.Agent.Skill`

```elixir
# Load all skills from a list of directories; missing or malformed entries skipped.
@spec load_all([Path.t()]) :: [Skill.t()]

# Load a single skill from a SKILL.md file path.
@spec from_file(Path.t()) :: {:ok, Skill.t()} | {:error, String.t()}

# Build a three-part system-prompt skill index (pinned + last-used + discovery).
# Returns nil when nothing would be shown.
@spec system_prompt_section(
        all_skills   :: [Skill.t()],
        ranked_names :: [String.t()],
        top_n        :: pos_integer()
      ) :: String.t() | nil

# Build the load_skill tool (auto-injected when skill_pool is non-empty).
# opts: skill_refresh_fn: (-> [Skill.t()]) | nil, on_use: (String.t() -> :ok) | nil
@spec load_skill_tool(opts :: keyword()) :: Tool.t()

# Build the list_skills tool (opt-in via TEAM.json "tools" array).
@spec list_skills_tool([Skill.t()]) :: Tool.t()
```

### `Planck.Agent.SkillIndex`

```elixir
# Build an empty SkillIndex.
@spec new() :: SkillIndex.t()

# Build a SkillIndex from agent start opts.
@spec from_opts(keyword()) :: SkillIndex.t()

# Rebuild pool and ranked from index_refresh_fn (called after compaction).
@spec refresh(SkillIndex.t()) :: SkillIndex.t()
```

### `Planck.Agent.SkillUsage`

```elixir
# Record a skill use in the per-project SQLite DB (upsert).
@spec record_use(
        project_dir :: Path.t(),
        team_name   :: String.t(),
        agent_name  :: String.t(),
        agent_type  :: String.t(),
        skill_name  :: String.t()
      ) :: :ok

# Top-n skills for a specific agent by use_count.
@spec top_n(
        project_dir :: Path.t(),
        team_name   :: String.t(),
        agent_name  :: String.t(),
        n           :: pos_integer()
      ) :: [String.t()]

# Union ranking across all orchestrators by agent_type.
@spec top_n_for_orchestrators(
        project_dir :: Path.t(),
        team_name   :: String.t(),
        n           :: pos_integer()
      ) :: [String.t()]

# Top-n with mtime cold-start fallback when no DB history exists.
@spec ranked_names(
        project_dir :: Path.t(),
        team_name   :: String.t(),
        agent_name  :: String.t(),
        skills      :: [Skill.t()],
        n           :: pos_integer()
      ) :: [String.t()]
```
