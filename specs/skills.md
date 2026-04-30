# Skills

Skills are reusable agent capabilities stored as directories on the filesystem.
Each skill has a `SKILL.md` file with a name and description, and an optional
`resources/` directory for supporting files the agent reads at runtime.

No special runtime support is required — skills are just files on disk. Agents
discover them via the system prompt and access them using the `read` built-in tool.

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

Full instructions for this skill go here. The agent reads this file via the
`read` tool when the skill is relevant to the current task.
```

Frontmatter is YAML-style (one `key: value` per line). Both `name` and
`description` are required. Windows line endings (CRLF) are normalized before
parsing.

## How agents use skills

`Planck.Agent.Skill.system_prompt_section/1` builds a prompt snippet that lists
all loaded skills with the path to their `SKILL.md` and `resources/` directory:

```
Available skills:
- code_review: Reviews code for correctness, style, and performance.
  skill file: /home/user/.planck/skills/code_review/SKILL.md
  resources dir: /home/user/.planck/skills/code_review/resources
```

The agent reads the full `SKILL.md` via the `read` tool when a skill is
relevant, and navigates resource files from the `resources dir` path.

Typical usage:

```elixir
skills = Planck.Agent.Skill.load_all(Planck.Agent.Config.skills_dirs!())

system_prompt =
  [base_prompt, Planck.Agent.Skill.system_prompt_section(skills)]
  |> Enum.reject(&is_nil/1)
  |> Enum.join("\n\n")
```

`system_prompt_section/1` returns `nil` when the list is empty, so it composes
cleanly with other prompt fragments.

## Why skills are not loaded automatically

`planck_agent` is a library — it does not run startup hooks or read config on
its own. Loading skills and injecting them into a system prompt is an
application-level decision: which dirs to scan, which agents get the skill
index, and when to do it. That responsibility belongs to `planck_headless`,
which calls `Skill.load_all/1` at startup and passes the result to agent
constructors.

## Configuration

| Env var                      | Config key     | Default                                        |
|------------------------------|----------------|------------------------------------------------|
| `PLANCK_AGENT_SKILLS_DIRS`   | `:skills_dirs` | `.planck/skills:~/.planck/skills`              |

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

# Build a system-prompt snippet listing skills with file and resources paths.
# Returns nil when the list is empty.
@spec system_prompt_section([Skill.t()]) :: String.t() | nil
```

## Struct

```elixir
%Planck.Agent.Skill{
  name:          String.t(),
  description:   String.t(),
  file_path:     Path.t(),   # absolute path to SKILL.md
  resources_dir: Path.t()    # absolute path to resources/ (may not exist on disk)
}
```
