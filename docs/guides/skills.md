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

## Assigning skills to agents

In `TEAM.json`, add a `"skills"` array to any agent spec:

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

## Example use cases

- **Coding conventions** — inject style rules for a language or framework
- **Domain knowledge** — describe the business domain, data models, or API contracts
- **Review rubrics** — structured criteria for a reviewer agent
- **Output templates** — instruct an agent to follow a specific output format
