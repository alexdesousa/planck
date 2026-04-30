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
---

# Code Review

Full instructions for this skill go here. The agent loads this file via
`load_skill` when the skill is relevant to the current task.

## Resources

- `resources/rubric.md` — review rubric (load via `read` with the absolute path)
```

Frontmatter is YAML-style (one `key: value` per line). Both `name` and
`description` are required. Windows line endings (CRLF) are normalized before
parsing.

## How agents use skills

### Declared skills (predictable, pre-configured)

Skills can be declared per-agent in TEAM.json. At start time,
`Planck.Agent.AgentSpec.to_start_opts/2` resolves the names against the global
`skill_pool:` and injects a system prompt section listing the agent's skills:

```
## Available skills

- **code_review** — Reviews code for correctness, style, and performance.
- **elixir-dev** — Expert Elixir development patterns and best practices.

Use `load_skill` with the skill name to load its full instructions when relevant.
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

```elixir
skills = Planck.Agent.Skill.load_all(["~/.planck/skills", ".planck/skills"])

start_opts = AgentSpec.to_start_opts(spec,
  tool_pool:  builtins ++ custom_tools,
  skill_pool: skills,
  team_id:    team_id
)
```

`load_skill` is **not** resolved from `tool_pool` — it is injected directly by
`AgentSpec.resolve_tools/2` after pool resolution, whenever `skill_pool:` is
non-empty. Every agent gets it automatically regardless of what it declares.

`list_skills` is added to `tool_pool` by `planck_headless` when skills exist.
Like any other tool, it only reaches an agent if the agent declares
`"list_skills"` in its TEAM.json `"tools"` array.

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

```elixir
# Load all skills from a list of directories; missing or malformed entries skipped.
@spec load_all([Path.t()]) :: [Skill.t()]

# Load a single skill from a SKILL.md file path.
@spec from_file(Path.t()) :: {:ok, Skill.t()} | {:error, String.t()}

# Build a system-prompt snippet listing declared skill names and descriptions.
# Returns nil when the list is empty.
@spec system_prompt_section([Skill.t()]) :: String.t() | nil

# Build the load_skill tool (auto-injected when skill_pool is non-empty).
@spec load_skill_tool([Skill.t()]) :: Tool.t()

# Build the list_skills tool (opt-in via TEAM.json "tools" array).
@spec list_skills_tool([Skill.t()]) :: Tool.t()
```
