# Changelog

## v0.1.0 (2026-04-18)

First release.

- OTP-based agent runtime with GenServer per agent
- Team lifecycle: orchestrator owns team, team dies with orchestrator
- Inter-agent tools: `ask_agent`, `delegate_task`, `send_response`, `list_team`
- Orchestrator-only tools: `spawn_agent`, `destroy_agent`, `interrupt_agent`, `list_models`
- `spawn_agent` accepts a `"tools"` JSON array; the orchestrator may grant any subset of its own `grantable_tools` to the spawned worker (no privilege escalation)
- `Planck.Agent.ExternalTool` — declarative external tool spec loaded from `<name>/TOOL.json`; `{{key}}` interpolation in commands; `erlexec`-backed execution; `load_all/1`, `from_file/1`
- `Planck.Agent.Compactor` — defines `@callback compact/1`; custom compactors implement this behaviour in a module inside a `.exs` file, allowing helper functions alongside the main callback; `load/1` compiles the file and wraps the module's `compact/1` as an `on_compact` function
- Registry-based agent discovery by type, name, or id
- Parallel tool execution via `Task.async_stream`
- Phoenix.PubSub broadcasting on `"agent:#{id}"` and `"session:#{session_id}"` topics
- Token usage tracking: `:usage_delta` events in real-time and `usage` in `:turn_end`
- `rewind/2` — removes last `n` turns from message history; syncs session store
- `stop/1` — graceful shutdown; cancels in-flight stream via `terminate/2`
- `get_info/1` — lightweight metadata snapshot
- `Planck.Agent.BuiltinTools` — `read/0`, `write/0`, `edit/0`, `bash/0` tool factories
  - `read` streams line-by-line with optional `offset` and `limit`
  - `bash` is backed by `erlexec`; accepts `cwd` and `timeout` as runtime JSON args; stdout and stderr both captured
- `Planck.Agent.Skill` — filesystem-based skill loader; `load_all/1`, `from_file/1`, `system_prompt_section/1`; skills are `<name>/SKILL.md` directories with YAML-style frontmatter
- `Planck.Agent.Session` — SQLite-backed session store with checkpoint-based pagination; caller-supplied `:dir` (no default)
- `Planck.Agent.Compactor` — default LLM-based context compaction anchored on `model.context_window`
- `Planck.Agent.Team` — directory-based team loader (`TEAM.json` + `members/<name>.md`); `%Team{source: :filesystem | :dynamic}`; `Team.load/1` and `Team.dynamic/1`
- `Planck.Agent.AgentSpec` — explicit constructor `new/1`; JSON parsers `from_map/2` and `from_list/2` for member entries; `description`, `tools: [String.t()]`, and `skills: [String.t()]` fields; `to_start_opts/2` accepts `tool_pool:` and `skill_pool:` overrides — tool names resolve from `tool_pool:` (falling back to the `tools:` override when `spec.tools` is empty); skill names resolve from `skill_pool:` and their descriptions are appended to `system_prompt` via `Skill.system_prompt_section/1` when `spec.skills` is non-empty
- Member `name` defaults to `type` when not provided; `Team.load/1` rejects duplicate names so multiple same-type members must be explicitly named
- `spawn_agent` tool accepts a `"skills"` parameter and a `grantable_skills` closure arg, symmetric with `grantable_tools`
- `Planck.AI.Model.providers/0` — valid provider atoms
- Pluggable `on_compact` hook — `Compactor.build/2` returns a ready-to-use function

### Notes

- `planck_agent` is a pure library with no runtime config module; filesystem-path configuration (sessions, skills, tools, compactor) lives in `Planck.Headless.Config`. Callers using `planck_agent` directly pass paths as explicit arguments.
- `Planck.Agent.TeamTemplate` iterated out during development — superseded by `Planck.Agent.Team` and `AgentSpec.from_map/2`/`from_list/2`.
