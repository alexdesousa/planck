---
name: planck-setup
description: Guides for configuring Planck — providers, models, teams, skills, sidecars, hooks, and the HTTP API. Use this skill whenever the user asks about setting up or configuring Planck, creating teams, installing providers, adding skills, writing sidecars, or using the HTTP API.
always_present: true
planck_version: 0.1.10
---

# Planck Setup

Reference guides for configuring and extending Planck. Load the relevant guide
when you need details on a specific topic — read it fully before implementing.

## Reference files

- `references/configuration.md` — `.planck/config.json` keys, env vars, provider
  API keys, local model declarations
- `references/teams.md` — TEAM.json structure, agent specs, provider/model
  selection, system prompts, tool assignment, multi-agent orchestration patterns
- `references/new_team.md` — scaffold a new TEAM.json and system prompt files,
  discover available models, register and start the team
- `references/skills.md` — SKILL.md format, file layout, injecting reusable
  context into agent prompts, global vs project-local skill directories
- `references/sidecar.md` — custom tools and compactors via a separate OTP
  application, external service integrations, PubSub event subscriptions,
  hooks (Compactor, Prompt, TurnEnd), scaffold
- `references/hooks.md` — Compactor, Prompt, and TurnEnd hook behaviours in
  detail; implementing them in a sidecar; TEAM.json wiring
- `references/api.md` — manage sessions and stream events from external agents,
  scripts, or CI pipelines via REST + SSE
- `references/tool-shadowing.md` — override built-in tools with sidecar
  implementations
- `references/docker.md` — Docker stack services (agent-vault, Typesense,
  Searxng, Tika), credential proxy, long-term memory, skill reflector, web fetch
- `references/images.md` — inline image display via the built-in proxy

## Usage pattern

1. Load the relevant reference file using the `read` tool with its absolute path
   (the `Skill directory:` prefix tells you the base path).
2. Follow any cross-references inside the guide.
3. Implement the configuration step by step, verifying each change.
