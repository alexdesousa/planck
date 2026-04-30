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
| `planck_cli/` | CLI binary (TUI + Web UI, Burrito-packaged) |

Dependency order: `planck_ai` ← `planck_agent` ← `planck_headless` ← `planck_cli`.
UI code never calls `planck_agent` directly — always through `planck_headless`.

## Running tests

```sh
# Unit tests (from any package directory):
PLANCK_LOCAL=true mix test

# planck_headless integration tests (requires distributed Erlang node):
PLANCK_LOCAL=true mix test.integration

# Full check (format + compile + credo + tests):
PLANCK_LOCAL=true mix check
```

`PLANCK_LOCAL=true` resolves sibling packages from disk instead of Hex.

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

- `:sparkles:` — new features
- `:recycle:` — refactors
- `:bug:` — bug fixes
- `:memo:` — documentation and specs
- `:arrow_up:` — dependency upgrades

## Code style

- No comments unless the *why* is non-obvious (hidden constraint, subtle invariant, workaround)
- No `@doc` on private functions
- Prefer `with` over nested `case` for multi-step pipelines
- No trailing commas in function call arguments
- `@spec` on all public functions; private functions where the type is non-obvious
- Skogsra for config — all config keys have an `app_env` declaration in `Planck.Headless.Config`
- Tests use `async: false` when touching global state (ResourceStore, SidecarManager, PubSub)

## Key architectural rules

- `planck_agent` has no runtime config — paths are passed as explicit arguments
- Each agent is a `GenServer`; role (orchestrator vs worker) is determined by tool list at start time
- Team dies with the orchestrator — workers are process-linked and exit together
- Session persistence is SQLite via `Planck.Agent.Session`; checkpoints enable pagination
- Sidecar tools and compactors are loaded dynamically over distributed Erlang by `SidecarManager`
- `ResourceStore` is the single source of truth for skills, teams, models, and sidecar tools

## Specs

Design decisions live in `specs/`. Read the relevant spec before making
architectural changes to understand the rationale behind existing decisions.
