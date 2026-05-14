# Changelog

## v0.1.1

### `checkpoint_agent` tool + `Planck.Agent.checkpoint/2`

- `checkpoint_agent` — orchestrator-only tool that inserts a `{:custom, :summary}`
  message into a target worker's conversation. The worker's next LLM call only sees
  the checkpoint and later messages; prior history is preserved in the session DB.
  Added to `orchestrator_tools/6` alongside `spawn_agent`, `destroy_agent`, and
  `interrupt_agent`.
- `Planck.Agent.checkpoint/2` — new public API: `checkpoint(agent, summary_text)` issues a
  synchronous `GenServer.call/2` that builds, persists, and appends the summary
  message. Works regardless of the agent's current status.

### Dynamic skill injection

- `Agent` state gains `skill_names: [String.t()]` and
  `skill_refresh_fn: (-> [Skill.t()]) | nil` fields.
- `do_run_llm` now calls `build_system_prompt/1` (private) before each LLM turn:
  invokes `skill_refresh_fn.()` to get the current skill pool from `ResourceStore`
  and appends a fresh skill section. Skills are no longer baked into
  `state.system_prompt` at agent start time.
- `AgentSpec.assemble_system_prompt/1` returns the base prompt only (identity line +
  user prompt). `to_start_opts/2` stores skill names in the `skill_names:` start opt
  and accepts a `skill_refresh_fn:` override.

### Dependency update

- `ex_doc` bumped to `~> 0.40.2`.

## v0.1.0

### execute_fn receives agent_id

- `Tool.execute_fn` type updated to `(agent_id, tool_call_id, args)` — every
  tool now receives the calling agent's id as the first argument.
- `ask_agent` drops the `own_id` closure capture — reads from `agent_id`.
- `spawn_agent` drops the `orchestrator_id` closure capture — reads from `agent_id`.
- `worker_tools/3` (was `/4`) and `orchestrator_tools/6` (was `/7`) — each lost
  one parameter as a result.
- `list_models` marks the caller's current model with `current: true` via a
  dynamic `Agent.get_state` lookup — works correctly when granted to workers.
- `AIBehaviour` — added `get_model/3` callback for base-url-aware lookups.

### Explicit agent targeting

- `ask_agent`, `delegate_task`, `destroy_agent`, `interrupt_agent` — replaced
  the three optional `type`/`name`/`id` fields with a required `identifier`
  string and a required `identifier_type` enum (`"type"`, `"name"`, `"id"`).
  The LLM can no longer omit all three and silently fail to target an agent.

### spawn_agent hardening

- `base_url` is now always required in `spawn_agent` (cloud providers may pass
  a placeholder; only ollama/llama_cpp use it).
- `spawn_agent` execute_fn refactored into focused helpers: `validate_base_url`,
  `resolve_spawn_model`, `build_spawn_start_opts`, `filter_granted`.

### Tool output truncation

- Tool results are now capped at 2 000 lines **or** 50 KB (whichever is
  reached first) before being stored in the session. Outputs that exceed either
  limit are truncated and suffixed with `\n[output truncated]`. Both limits are
  always enforced — line truncation is applied first, then byte truncation on
  the result.

### Compactor fixes

- `estimate_tokens` now counts `{:tool_call, id, name, args}` content parts
  (previously ignored, causing systematic underestimates).
- `compact_local` filters all `{:custom, :summary}` messages from `old` before
  calling `summarize/2` — only messages since the last checkpoint are
  summarised, preventing the previous checkpoint from bloating the request.
- `format_history` strips thinking blocks and truncates tool results to 2 000
  chars — keeps the summarisation input small without losing signal.

### Queued message follow-up fix

- A user message sent while the orchestrator is executing tools now correctly
  triggers a dedicated follow-up turn after all tools complete. Previously,
  `do_run_llm` called during tool continuation advanced `stream_start` past the
  queued message, so `maybe_turn_start` found no pending input.

### Runtime model switching

- `Planck.Agent.change_model/2` — replaces the model in the agent's GenServer state
  for subsequent LLM turns without affecting the current conversation history
  or status.

### AGENTS.md prepending for all agents

- `Tools.prepend_agents_md/2` is now public — walks up from `cwd` to the
  nearest `.git` root, reads `AGENTS.md` if found, and prepends its content to
  the given system prompt. Returns the prompt unchanged when no file is found or
  `cwd` is empty.
- `orchestrator_tools/7` — added `cwd` parameter (default `""`); passed into
  the `spawn_agent` closure so dynamically spawned workers inherit the same
  project context.
- `spawn_agent` tool — prepends `AGENTS.md` to the worker's system prompt before
  starting the agent process; `cwd` is stored in the new agent's state.
- `Agent.t` — added `cwd: String.t()` field (default `""`); set from start opts.

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

### Inter-agent tools — deadlock detection + improvements

- `ask_agent/2` — now accepts `own_id` for deadlock detection; before blocking,
  registers `{:waiting, own_id} → target_id` in `Planck.Agent.Registry` (auto-
  cleared on task exit) and checks for a circular wait chain; returns a clear
  error instead of deadlocking if a cycle is detected.
- `worker_tools/4` — added `own_id` parameter (passed to `ask_agent` for cycle
  detection); callers must now supply the agent's own id.
- `orchestrator_tools/6` — added `grantable_skills` parameter so skills can be
  granted to dynamically spawned workers via `spawn_agent`.
- `spawn_agent` — spawned workers now receive a `sender` identity so the
  orchestrator knows which worker replied via `send_response`.
- `list_team/1` — added `verbose: boolean` parameter; verbose mode includes tool
  names and model for each team member.
- `list_models/1` — output now includes `base_url` for each model so the LLM
  can pass the correct base_url when calling `spawn_agent`.
- Agent `init` broadcasts `:worker_spawned` on the session PubSub topic when
  a worker with a `delegator_id` starts, enabling UIs to refresh the agent list.
- Non-blocking tool execution: `handle_continue({:execute_tools})` now spawns
  each tool as a supervised fire-and-forget task; results collected via
  `handle_info({:tool_done})`; the GenServer loop stays free for abort/prompt
  during tool execution.
- `abort/1` changed from cast to call; blocks until the agent is idle, closing
  the race condition between abort and subsequent prompt/rewind calls.
- `cost: float()` added to agent state; accumulated from model rates on each
  `:done` event; persisted to session metadata; broadcast in `:usage_delta`.
- `Message.estimate_tokens/1` — public character-based token estimator.
- `Planck.Agent.estimate_tokens/1` — public API that computes current context size.
- `running_tools` / `tool_results_acc` added to agent state for non-blocking
  tool tracking.

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
- `Planck.Agent.rewind_to_message/2` — truncates both the session and in-memory history to
  strictly before the given db_id, then reloads from the DB to restore canonical
  order and rebuild `turn_checkpoints`; replaces the old `rewind/2` (removed)
- `rewind/2` removed — replaced by `Planck.Agent.rewind_to_message/2`

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

- `Planck.Agent.prompt/3` is now a synchronous `call` (was a `cast`) — returns `:ok` once the agent
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
