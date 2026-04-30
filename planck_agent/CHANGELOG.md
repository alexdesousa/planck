# Changelog

## v0.1.0

### Skills — explicit `load_skill` / `list_skills` tools

- `Skill.load_skill_tool/1` — builds a `load_skill` tool as a closure over the
  skill pool; automatically injected by `AgentSpec.to_start_opts/2` for every
  agent when `skill_pool:` is non-empty. No TEAM.json declaration needed.
- `Skill.list_skills_tool/1` — builds a `list_skills` tool returning all
  available skill names and descriptions. Opt-in: add `"list_skills"` to an
  agent's TEAM.json `"tools"` array to enable autonomous skill discovery.
- `Skill.system_prompt_section/1` updated: no longer includes file paths or
  resources dir; instructs agents to use `load_skill` instead of `read`.
- `AgentSpec.resolve_tools/2` updated: automatically appends `load_skill_tool`
  when `skill_pool:` is non-empty, regardless of `spec.skills`.

### Prior entries

First release.

- `Planck.Agent.Sidecar` — behaviour for distributed sidecar extensions; single
  `tools/0` callback; module-level RPC entry points: `discover/0` (auto-detects
  the entry module via `:persistent_term`-cached scan, only caches on success),
  `list_tools/0`, `list_tools/1`, `execute_tool/3`, `execute_tool/4`
- `Planck.Agent.Compactor` — redesigned: `compact/2` and `compact_timeout/0`
  callbacks; unified `build/2` accepting `sidecar_node:` and `compactor:` opts
  for remote sidecar compactors with local fallback; `compactor:` string is
  converted to `:"Elixir.<name>"` atom before RPC; `load/1` removed
- `AgentSpec.compactor` — per-agent compactor module name string; resolved via
  `Compactor.build/2` at session start
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
- `@type agent` and `@type t` now have full `@typedoc` documentation with all fields typed

### Session API additions

- `Session.append/3` changed from fire-and-forget cast to synchronous call —
  returns `pos_integer() | nil` (the SQLite autoincrement row id, or `nil` when
  the session is not found); enables the agent to set `Message.id = db_id`
  immediately after each persist
- `Session.truncate_after/2` — deletes all messages with `id >= db_id` across all
  agents in a session; used by the edit-message feature
- `Session.messages/1` rows now include `db_id: pos_integer()` — the SQLite row id
- `Message.id` is now the SQLite row id after persistence (previously a random UUID);
  this unifies the two identifiers so callers never need to track both
- `Message.id` is **not** stored in the serialised blob — the field is stripped
  before writing and set from the DB `id` column on every read; the row id is
  therefore authoritative for all rows, including legacy ones that stored a UUID
- `Agent.rewind_to_message/2` — truncates both the session and in-memory history to
  strictly before the given db_id, then reloads from the DB to restore canonical
  order and rebuild `turn_checkpoints`; replaces the old `rewind/2` (removed)
- `Agent.rewind/2` removed — replaced by `rewind_to_message/2`

### Message persistence ordering

- Queued messages (received while the agent is streaming) are no longer persisted
  immediately; they retain a UUID id in memory and are flushed to the session at
  the start of the next LLM turn via `flush_unpersisted_messages`. This guarantees
  that the queued message's db_id is always greater than the current turn's
  assistant response, preserving correct insertion order in the DB
- `flush_unpersisted_messages` and `reload_messages_from_session` are internal
  helpers that keep in-memory message order consistent with DB order after queuing
  or rewind; `turn_checkpoints` is rebuilt from the reloaded list

### Agent API

- `Agent.prompt/3` is now a synchronous `call` (was a `cast`) — returns `:ok` once the agent
  has set its status to `:streaming`; if the agent is already busy the message is queued
  (appended to history) and re-triggered automatically after the current turn ends via
  `maybe_turn_start/1`
- `send_response` tool now carries sender attribution: orchestrator receives
  `{:agent_response, response, %{id, name}}` and stores `sender_id`/`sender_name` in the
  message metadata
- `to_ai_messages/1` converts `{:custom, :agent_response}` messages to `:user` role, prefixed
  with `"Response from <name>: "` when `sender_name` metadata is present
- `ask_agent` no longer accepts a `timeout_ms` parameter — blocks indefinitely; monitors the
  target process and returns `{:error, "Agent terminated: ..."}` if it crashes; subscribes
  before prompting to close the race condition
- `delegate_task` tool result now includes guidance to end the turn

### Notes

- `planck_agent` is a pure library with no runtime config module; filesystem-path configuration (sessions, skills, tools, compactor) lives in `Planck.Headless.Config`. Callers using `planck_agent` directly pass paths as explicit arguments.
- `Planck.Agent.TeamTemplate` iterated out during development — superseded by `Planck.Agent.Team` and `AgentSpec.from_map/2`/`from_list/2`.
