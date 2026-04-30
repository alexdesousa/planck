# Changelog

## v0.1.0 (2026-04-18)

First release.

- OTP-based agent runtime with GenServer per agent
- Team lifecycle: orchestrator owns team, team dies with orchestrator
- Inter-agent tools: `ask_agent`, `delegate_task`, `send_response`, `list_team`
- Orchestrator-only tools: `spawn_agent`, `destroy_agent`, `interrupt_agent`, `list_models`
- Registry-based agent discovery by type, name, or id
- Parallel tool execution via `Task.async_stream`
- Phoenix.PubSub broadcasting on `"agent:#{id}"` and `"session:#{session_id}"` topics
- Token usage tracking: `:usage_delta` events in real-time and `usage` in `:turn_end`
- `rewind/2` — removes last `n` turns from message history; syncs session store
- `stop/1` — graceful shutdown; cancels in-flight stream via `terminate/2`
- `get_info/1` — lightweight metadata snapshot
- `Planck.Agent.Session` — SQLite-backed session store with checkpoint-based pagination
- `Planck.Agent.Config` — Skogsra-based config; `PLANCK_AGENT_SESSIONS_DIR` env var
- `Planck.Agent.Compactor` — default LLM-based context compaction anchored on `model.context_window`
- `Planck.Agent.TeamTemplate` JSON loader for static agent definitions
- `AgentSpec.new/1` explicit constructor; `AgentSpec` gains `description` field
- `Planck.AI.Model.providers/0` — valid provider atoms; `TeamTemplate` derives its map from it
- Pluggable `on_compact` hook — `Compactor.build/2` returns a ready-to-use function
