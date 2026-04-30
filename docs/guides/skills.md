# Planck Skills

A skill is a reusable system prompt section stored on the filesystem. When an
agent has a skill assigned, its content is appended to the agent's system prompt
at session start.

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
---

You are an expert code reviewer. When reviewing code:

- Check for correctness first — does it do what it claims?
- Flag style issues only if they impact readability
- Suggest performance improvements only when material

Reference the rubric at resources/rubric.md for scoring criteria.
```

The frontmatter `name` and `description` fields are required. Everything after
the `---` separator is the skill body injected into the system prompt.

## Assigning skills in TEAM.json

Add a `"skills"` array to any agent spec to inject skill content at session start:

```json
{
  "type":    "reviewer",
  "skills":  ["code_review", "elixir_style"]
}
```

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

## Example use cases

- **Coding conventions** — inject style rules for a language or framework
- **Domain knowledge** — describe the business domain, data models, or API contracts
- **Review rubrics** — structured criteria for a reviewer agent
- **Output templates** — instruct an agent to follow a specific output format

For team configuration, see:
https://raw.githubusercontent.com/alexdesousa/planck/main/docs/guides/teams.md
