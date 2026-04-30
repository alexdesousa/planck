# Changelog

## v0.1.0 (2026-04-18)

First release.

- OTP-based agent runtime with GenServer per agent
- Team lifecycle: orchestrator owns team, team dies with orchestrator
- Inter-agent tools: `ask_agent`, `delegate_task`, `send_response`, `list_team`
- Orchestrator-only tools: `spawn_agent`, `destroy_agent`, `interrupt_agent`, `list_models`
- `spawn_agent` accepts a `"tools"` JSON array; the orchestrator may grant any subset of its own `grantable_tools` to the spawned worker (no privilege escalation)
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
- `Planck.Agent.Session` — SQLite-backed session store with checkpoint-based pagination
- `Planck.Agent.Config` — Skogsra-based config; `PLANCK_AGENT_SESSIONS_DIR` and `PLANCK_AGENT_SKILLS_DIRS` env vars; `PathList` type for colon-separated dir lists
- `Planck.Agent.Compactor` — default LLM-based context compaction anchored on `model.context_window`
- `Planck.Agent.TeamTemplate` JSON loader for static agent definitions
- `AgentSpec.new/1` explicit constructor; `AgentSpec` gains `description` field
- `Planck.AI.Model.providers/0` — valid provider atoms; `TeamTemplate` derives its map from it
- Pluggable `on_compact` hook — `Compactor.build/2` returns a ready-to-use function
