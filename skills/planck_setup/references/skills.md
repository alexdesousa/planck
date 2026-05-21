# Planck Skills

A skill is a reusable capability stored on the filesystem. Agents discover and
load skills on demand via the `load_skill` tool. A concise index of the agent's
most-used skills is shown in its system prompt so it knows what to reach for.

Skills are useful for injecting domain knowledge, coding conventions, or
project-specific context that applies to multiple agents or sessions.

## File layout

```
.planck/skills/<name>/
  SKILL.md
  references/       (optional — docs loaded into context via `read`)
    guide.md
    rubric.md
  scripts/          (optional — executable helpers run via `bash`)
    validate.sh
  assets/           (optional — templates, icons, or other output files)
    template.md
```

All subdirectory content is loaded on demand. When `load_skill` returns a
skill's content, it prepends `Skill directory: <path>` so the agent can
construct absolute paths for any files it needs to `read` or `bash`.

## SKILL.md format

```markdown
---
name: code_review
description: Reviews code for correctness, style, and performance.
---

You are an expert code reviewer. When reviewing code:

- Check for correctness first — does it do what it claims?
- Flag style issues only if they impact readability
- Suggest performance improvements only when material

See `references/rubric.md` for scoring criteria.
```

Frontmatter fields:

| Field | Required | Default | Notes |
|---|---|---|---|
| `name` | ✅ | — | Identifier used in the index and `load_skill` calls |
| `description` | ✅ | — | One-line summary shown in the skill index |
| `always_present` | | `false` | Pin to system prompt index regardless of usage ranking |
| `planck_version` | | `null` | Set by Planck on bundled skills; used for upgrade detection |
| `creator` | | `null` | `"agent"` for SkillReflector-created skills; `null` for user-created |

Everything after the closing `---` is the skill body returned by `load_skill`.
The `creator` field is set automatically by the SkillReflector — do not set it
manually unless you want the skill to be treated as agent-managed.

## Assigning skills in TEAM.json

Add a `"skills"` array to any agent spec. The skill names are stored in the
agent's `SkillIndex` and used to build the system prompt index at session start:

```json
{
  "type":    "reviewer",
  "skills":  ["code_review", "elixir_style"]
}
```

The system prompt index shows pinned skills (`always_present: true`) plus the
agent's most-recently-used skills (up to `top_skills`, default 5) ranked from the
per-project SQLite usage DB (`.planck/skills.db`). On first run (no history), the
index falls back to skills sorted by mtime of their `SKILL.md` file.

Skill names are resolved from the configured `skills_dirs`
(default: `.planck/skills` and `~/.planck/skills`).

## Global vs project skills

- `~/.planck/skills/` — available across all projects
- `.planck/skills/` — project-local; overrides global on name collision

## Runtime skill tools

Two tools are available for working with skills during a session.

### `load_skill` — on-demand loading

`load_skill` is **automatically injected** into every agent when skills are
available. No TEAM.json declaration needed. Agents call it to pull a skill's
content into their context during a session — useful for large skills that
are only needed for specific tasks, or to inspect a skill's contents.

```
load_skill("code_review")
→ Skill directory: /path/to/.planck/skills/code_review

  ---
  name: code_review
  ...
```

The response is prefixed with `Skill directory: <path>` so the agent can resolve
relative paths (e.g. `references/rubric.md`) using the `read` tool.

Each successful `load_skill` call records the use in `.planck/skills.db` (the
per-project SQLite usage DB). This drives the last-used ranking that determines
which skills appear in the system prompt index on subsequent sessions.

### `list_skills` — discovery

`list_skills` is **opt-in**. Add `"list_skills"` to an agent's `tools` array
to enable it:

```json
{ "type": "builder", "tools": ["read", "write", "edit", "bash", "list_skills"] }
```

Returns all available skill names and their one-line descriptions. Useful for
agents that need to autonomously discover and load relevant skills.

## Granting skills to dynamically spawned workers

When the orchestrator calls `spawn_agent`, it can attach skills to the new
worker via the `"skills"` parameter. The skill content is appended to the
worker's system prompt at spawn time — no TEAM.json entry needed:

```json
{
  "type":          "reviewer",
  "name":          "Reviewer",
  "skills":        ["code_review"],
  "system_prompt": "Review the changes made by the builder.",
  ...
}
```

Only skills the orchestrator itself has access to can be granted.

## Dynamic loading — live updates without restart

When you edit a `SKILL.md` file on disk, the running `Watcher` GenServer
detects the change (300 ms debounce) and calls `ResourceStore.reload/0`.

- **`load_skill` tool** — always reads from the live pool, so edited skill
  content is available immediately on the agent's next `load_skill` call.
- **System prompt index** — built from a frozen pool captured at session start
  and refreshed only after context compaction. Edits to descriptions of already-indexed
  skills become visible after the next compaction.

New skills added to the pool after a session starts are loadable by name via
`load_skill` even if they do not appear in the current system prompt index.

## Example use cases

- **Coding conventions** — inject style rules for a language or framework
- **Domain knowledge** — describe the business domain, data models, or API contracts
- **Review rubrics** — structured criteria for a reviewer agent
- **Output templates** — instruct an agent to follow a specific output format

For team configuration, see:
https://raw.githubusercontent.com/alexdesousa/planck/main/skills/planck_setup/references/teams.md
