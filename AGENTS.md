# Planck — Agent Instructions

Planck is an Elixir/OTP coding agent ecosystem. This file provides project
context and conventions for AI agents working in this repository.

## Project structure

Monorepo of four independent Mix projects (no umbrella):

| Package | Role |
|---|---|
| `planck_ai/` | LLM provider abstraction — streaming, tool calling, model catalog |
| `planck_agent/` | OTP agent runtime — GenServer per agent, teams, sessions, compactors, sidecar |
| `planck_headless/` | Headless core — config, resources, session lifecycle, SidecarManager |
| `planck_cli/` | CLI binary (Web UI + HTTP API, Burrito-packaged) |

Dependency order: `planck_ai` ← `planck_agent` ← `planck_headless` ← `planck_cli`.
UI code never calls `planck_agent` directly — always through `planck_headless`.

## Running checks and tests

```sh
# Full check across all packages (from monorepo root):
./check

# Check a specific package:
./check planck_agent

# Unit tests (from any package directory):
PLANCK_LOCAL=true mix test

# planck_headless integration tests (requires distributed Erlang node):
PLANCK_LOCAL=true mix test.integration
```

`PLANCK_LOCAL=true` resolves sibling packages from disk instead of Hex.
`test.integration` is only available in `planck_headless`.

## Module naming

All modules use the `Planck.X` namespace — never the flat `PlanckX` form.

| Package | Root module |
|---|---|
| `planck_ai` | `Planck.AI` |
| `planck_agent` | `Planck.Agent` |
| `planck_headless` | `Planck.Headless` |
| `planck_cli` | `Planck.CLI` |

## Commit format

Commit messages use an emoji prefix:

- `:sparkles:` — new features and improvements (including bug fixes in practice)
- `:memo:` — documentation, specs, and CHANGELOGs
- `:arrow_up:` — dependency upgrades

## Code style

- No comments unless the *why* is non-obvious (hidden constraint, subtle invariant, workaround)
- No `@doc` on private functions
- Prefer `with` over nested `case` for multi-step pipelines
- No trailing commas in function call arguments
- `@spec` on all public functions; private functions where the type is non-obvious
- Skogsra for config — each package has its own `Config` module (`Planck.Headless.Config`, `Planck.CLI.Config`); all config keys are declared with `app_env`
- Tests use `async: false` when touching global state (ResourceStore, SidecarManager, PubSub)

## Key architectural rules

- `planck_agent` has no runtime config — paths are passed as explicit arguments
- Each agent is a `GenServer`; role (orchestrator vs worker) is determined by tool list at start time (presence of `spawn_agent` tool = orchestrator)
- Team dies with the orchestrator — workers are process-linked and exit together
- Session persistence is SQLite via `Planck.Agent.Session`; checkpoints enable pagination
- Sidecar tools and compactors are loaded dynamically over distributed Erlang by `SidecarManager`
- `ResourceStore` is the single source of truth for skills, teams, models, and sidecar tools
- System prompt assembly lives in `Planck.Agent.SystemPrompt`; per-tool guidance sections are injected only when the tool is present in the agent's tool map

## Inter-agent tools

| Tool | Role | Behaviour |
|---|---|---|
| `call_agent` | all | Sync — blocks until the target responds |
| `send_agent` | all | Async — fire-and-forget; result arrives via `respond_agent` |
| `respond_agent` | all | Report results back to the caller |
| `list_team` | all | List agents; use `id` field for targeting |
| `spawn_agent` | orchestrator | Spawn a new worker; returns `agent_id` — save it |
| `destroy_agent` | orchestrator | Permanently remove a worker |
| `interrupt_agent` | orchestrator | Abort a worker's current turn; worker stays alive |
| `list_models` | orchestrator | List available models |

All targeting tools accept `agent_id` (from `list_team`). Type and name targeting were removed in v0.1.2.

## User-facing guides

`docs/guides/` contains guides written for agents configuring a Planck
environment. Read the relevant guide before implementing:

- `docs/guides/configuration.md` — `.planck/config.json` keys and env vars
- `docs/guides/teams.md` — TEAM.json structure, agent specs, inter-agent tools
- `docs/guides/skills.md` — SKILL.md format and skill assignment
- `docs/guides/sidecar.md` — sidecar scaffold, tools, compactors, PubSub events

## Specs

Design decisions live in `specs/`. Read the relevant spec before making
architectural changes to understand the rationale behind existing decisions.
