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
  resources/        (optional — any reference files)
    rubric.md
    style-guide.md
```

## SKILL.md format

```markdown
---
name: code_review
description: Reviews code for correctness, style, and performance.
always_present: false
planck_version: "0.1.7"
---

You are an expert code reviewer. When reviewing code:

- Check for correctness first — does it do what it claims?
- Flag style issues only if they impact readability
- Suggest performance improvements only when material

Reference the rubric at resources/rubric.md for scoring criteria.
```

The frontmatter `name` and `description` fields are required. The optional
`always_present` flag (default `false`) pins the skill to the system prompt index
regardless of usage ranking. The optional `planck_version` field is informational.
Everything after the closing `---` is the skill body loaded by `load_skill`.

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
→ returns the full skill body as a string
```

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
https://raw.githubusercontent.com/alexdesousa/planck/main/docs/guides/teams.md
