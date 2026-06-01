# Changelog

## v0.1.10

- TODO

## v0.1.9

### Compactor — token-aware keep-recent

The built-in LLM compactor no longer keeps a fixed 10 messages verbatim.
Instead it keeps messages from the most recent end of history as long as their
cumulative estimated token count stays within `@keep_ratio` (10%) of the
model's `context_window`. At least one message is always kept regardless of
size, preventing infinite compaction loops on very large individual turns.

## v0.1.8

- Version bump; pin Burrito OTP build version to 28.5.0 to fix macOS binary builds.

## v0.1.7

### Unified `Planck.Agent.Hooks` namespace

Three hook behaviours under `Planck.Agent.Hooks`:

**`Planck.Agent.Hooks.Compactor`** — context compaction.
- `compact/2` callback: `compact(model, messages)` → `{:compact, summary, kept} | :skip`
- `compact_timeout/0` callback for custom RPC timeouts (default 30 000 ms)
- Dispatch: `Hooks.Compactor.compact(module, model, messages, sidecar_node)`. When
  `module` is `nil`, the built-in LLM-based compactor runs locally.

**`Planck.Agent.Hooks.Prompt`** — per-turn system prompt injection.
- `before_prompt/1` and `after_prompt/1` callbacks receive `session_id` — enabling
  per-session state lookups (e.g. an ETS table keyed by session)
- `hook_timeout/0` callback for custom RPC timeouts (default 5 000 ms)
- `use Planck.Agent.Hooks.Prompt` injects no-op defaults for all three
- Dispatch: `Hooks.Prompt.before_prompt(module, session_id, sidecar_node)` /
  `Hooks.Prompt.after_prompt(module, session_id, sidecar_node)`; RPC failures
  return `nil` (no injection) instead of raising

**`Planck.Agent.Hooks.TurnEnd`** — post-turn reflection, fires in a background Task.
- `reflect/2` callback: `reflect(agent_id, turn_messages)` — called after every turn;
  dispatch is unconditional — the implementation owns any threshold check
- `reflect_timeout/0` for custom RPC timeouts (default 30 000 ms); `default_timeout/0`
  exposes the default for use in `__using__` macros
- `use Planck.Agent.Hooks.TurnEnd` injects no-op defaults
- Dispatch: `TurnEnd.reflect(module, agent_id, turn_messages, sidecar_node)`

### Module-based dispatch (no closures)

Agent state now holds module atoms directly — no closure wrapping:

- `compactor: module() | nil` — replaces closure-based `on_compact`
- `prompt_hook: module() | nil` — replaces `system_prompt_prepend_fn` / `system_prompt_append_fn`
- `turn_end_hook: module() | nil` — new post-turn hook
- `sidecar_node: atom() | nil` — shared across all three hooks

`AgentSpec` gains a `turn_end_hook: String.t() | nil` field (alongside the
existing `compactor` and `prompt_hook` fields), declarable in TEAM.json.
planck_headless passes hook module names as atoms directly at agent start time —
no intermediate builder functions.

### `Usage.from_opts/1`

New public function that builds a `%Usage{}` struct from agent start opts.
Reads the `:usage` keyword (a map with `:input_tokens`/`:output_tokens` keys) and
the `:cost` float. Previously this logic lived as a private `build_initial_usage/1`
in `agent.ex`.

### Agent state — `usage` consolidation

`cost: float()` (added in v0.1.0) has been moved inside the `%Usage{}` struct.
`state.cost` no longer exists; use `state.usage.cost` instead.
`SessionStore.persist_usage/3` now serialises `usage.cost` from the struct directly.

### `SkillUsage` — per-project SQLite skill usage tracking

New module `Planck.Agent.SkillUsage` records how often each agent uses each
skill, persisting counts to a per-project SQLite DB at `.planck/skills.db`.

- Schema: `(team_name, agent_name, agent_type, skill_name, use_count, last_used)`
  — primary key is `(team_name, agent_name, skill_name)`.
- `record_use/5` — upserts a row on each successful `load_skill` call.
- `top_n/4` — per-agent ranking by `use_count`.
- `top_n_for_orchestrators/3` — union of all orchestrators by `agent_type`.
- `ranked_names/5` — returns `top_n` results with mtime-sorted cold-start
  fallback when no SQLite history exists yet.

### `SkillIndex` — consolidated skill state

New struct `Planck.Agent.SkillIndex` replaces the five separate skill-related
fields that previously lived in `%Planck.Agent{}` state:

```elixir
%Planck.Agent.SkillIndex{
  pool:              [Skill.t()],              # frozen at session start
  ranked:            [String.t()],             # ordered names from SQLite
  top_n:             pos_integer(),            # max ranked skills (default 5)
  names:             [String.t()],             # from TEAM.json skills array
  refresh_fn:        (-> [Skill.t()]) | nil,   # for tools only
  index_refresh_fn:  (-> {[Skill.t()], [String.t()]}) | nil  # called after compaction
}
```

Agent state field `skills: %SkillIndex{}` replaces the five separate skill
fields. `SkillIndex.new/0`, `SkillIndex.from_opts/1`, and `SkillIndex.refresh/1`
are the public constructors and mutators.

### `Skill.t` — new frontmatter fields

`Planck.Agent.Skill.t` gains three new optional frontmatter fields:

- `always_present: boolean()` (default `false`) — when `true`, the skill is
  always included in the system prompt index regardless of ranking.
- `planck_version: String.t() | nil` (default `nil`) — set by Planck on
  bundled skills; used for upgrade detection.
- `creator: String.t() | nil` (default `nil`) — `"agent"` for skills written
  by the SkillReflector; `nil` for user-created skills. Used by the reflector's
  filtered `list_skills` to show agents only their own skills.

### `inject_tool_result/3`

New public API:

```elixir
@spec inject_tool_result(agent(), tool_name :: String.t(), result :: String.t()) :: :ok
```

Appends a synthetic assistant tool-call message paired with a `:tool_result`
message to the agent's history. Both are persisted. No new turn is triggered.

The `tool_name` does not need to be in the agent's callable tool list — it
appears only as a history entry. Used by the sidecar `SkillReflector` to signal
`create_skill` / `update_skill` back to the parent agent so the LLM and UI see
it passively on the next turn.

### `load_skill` — skill directory prefix

The content returned by `load_skill` is now prefixed with a `Skill directory:`
line so the LLM knows the absolute path of the skill on disk:

```
Skill directory: /Users/alex/.planck/skills/planck_setup

---
name: planck-setup
...
```

This allows the agent to resolve relative reference file paths (e.g.
`references/guide.md`) using the `read` tool without any special convention.

### `Skill.system_prompt_section/3` — three-part index

`system_prompt_section/1` is replaced by `system_prompt_section/3`:

```elixir
@spec system_prompt_section(
        all_skills    :: [Skill.t()],
        ranked_names  :: [String.t()],
        top_n         :: pos_integer()
      ) :: String.t() | nil
```

The returned section has three parts:

1. **Pinned** — skills with `always_present: true` (always shown).
2. **Last-used** — up to `top_n` skills from `ranked_names` (SQLite-ranked).
3. **Discovery line** — guides the agent to call `load_skill` or `list_skills`
   when it needs a skill not listed.

Returns `nil` when nothing would be shown.

### `load_skill` tool — records usage to SQLite

`Skill.load_skill_tool/1` now accepts an `opts` keyword list:

- `skill_refresh_fn:` — resolves the skill pool at call time (for tools; NOT
  used by the system prompt).
- `on_use:` — callback fired on each successful `load_skill` call; used by
  `planck_headless` to call `SkillUsage.record_use/5`.

### Skill index frozen at session start

The system prompt skill section is built from a **frozen** `skill_pool` captured
at session start (`SkillIndex.pool`). It is refreshed only after compaction
(via `index_refresh_fn`), keeping system prompt tokens stable across turns.
`skill_refresh_fn` is used exclusively by the `load_skill` and `list_skills`
tools to access a live pool.

### `top_skills` config key

`Planck.Headless.Config` gains a new `top_skills` key (default `5`) settable in
`config.json`. Controls how many last-used skills appear in the system prompt
index per agent.

### `Hooks.Compactor` — iodata accumulation

`summarize/2` and `extract_text/1` now build iolists instead of using `<>`
string concatenation in a reduce. `IO.iodata_to_binary/1` does a single
allocation at the end — O(n) instead of O(n²) for long histories.

### `"planck:sessions"` global PubSub topic

`Planck.Agent` now broadcasts `:turn_end` and `:compacted` events to a global
`"planck:sessions"` topic in addition to the existing per-agent and per-session
topics. Only persistent agents (those with a `session_id`) emit these events.

The payload is the same as the per-session event plus four extra fields:

- `agent_name` — stable agent name from TEAM.json (`spec.name || spec.type`)
- `agent_id` — the agent's process identifier
- `session_id` — the agent's SQLite session identifier
- `team_name` — the stable team alias (`team.alias || "default"`)
- `turn_messages` — messages from the user trigger onwards (sliced from
  `stream_start - 1`), built by the private `readable_turn_messages/2` helper

```elixir
Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "planck:sessions")
# receives: {:agent_event, :turn_end | :compacted, %{agent_id:, agent_name:, session_id:, team_name:, turn_messages:, ...}}
```

Sidecars subscribe to this single topic to receive events from all agents
without needing to know individual agent IDs in advance.

### `team_name` in agent state

`%Planck.Agent{}` gains a `team_name: String.t() | nil` field — the stable
team alias passed from planck_headless at start time (`team.alias || "default"`
for the default dynamic team, `nil` for standalone agents). This is distinct
from `team_id` (the runtime UUID) and is used as the stable key for per-team
memory lookups in sidecars.

### `SkillUsage` — `team_name` nil bug fix

`SkillUsage.record_use/5` and `top_n/4` now always receive a non-nil
`team_name`. The default dynamic team (no `template:` in `start_session/1`)
previously passed `nil` for `team_name`, causing the SQLite `ON CONFLICT`
clause to silently malfunction. `planck_headless` now falls back to
`"default"` when `team.alias` is nil.

### `SessionStore` — `load_messages/3` return type

`SessionStore.load_messages/3` now returns `{:ok, [Message.t()]}` (was
`{:ok, [Message.t()], [non_neg_integer()]}`). Checkpoint rebuilding is now handled
by `TurnState.rebuild_checkpoints/2` in `do_load_session`, eliminating the duplicate
`build_checkpoints/1` private function that previously existed in both modules.

## v0.1.6

- Drop `:ollama`, `:llama_cpp`, and `:custom_openai` provider atoms — valid
  providers are now `:anthropic | :openai | :google` only, matching `planck_ai`
- `spawn_agent` tool provider enum updated: `ollama`, `llama_cpp`, and
  `custom_openai` removed; OpenAI-compatible endpoints use `openai` with a
  `base_url`
- `@local_providers` and related validation (`validate_local_base_url`,
  `resolve_spawn_model`) updated — local inference servers are now configured
  via `openai` + `base_url`

## v0.1.5

- `"custom_openai"` added to the `spawn_agent` provider enum; the LLM can now
  spawn workers backed by any OpenAI-compatible endpoint (NVIDIA, Together, vLLM, etc.)
- `base_url` description in `spawn_agent` updated to mention `custom_openai` as a local provider that requires it
- `@local_providers` extended to include `:custom_openai` — `validate_local_base_url` and `resolve_spawn_model` now enforce and use `base_url` for `custom_openai` the same way they do for `ollama` and `llama_cpp`

## v0.1.4

- Version bump to stay in sync with the monorepo release; no functional changes.

## v0.1.3

### Generic JSON schema validation

- `Tool.validate_args/2` now validates every tool invocation against the tool's
  JSON Schema parameters using `ex_json_schema` before `execute_fn` is called.
  Covers required fields, types, enums, and any other constraint declared in the
  schema — no per-tool validation boilerplate needed.
- Validation is wired in `resolve_tool_fn` in `agent.ex`, so all tools — built-in,
  inter-agent, and sidecar — get it automatically.
- Enum errors include the list of valid values; required-field and type errors
  name the offending field.
- `ex_json_schema ~> 0.11` added as a dependency.

### `spawn_agent` provider enum

- The `provider` parameter now declares `"enum": ["anthropic", "openai", "google",
  "ollama", "llama_cpp"]`. Invalid provider names are caught by schema validation
  with a clear error before `execute_fn` runs — the `ArgumentError` rescue that
  previously handled this case has been removed.

## v0.1.2

### Duplicate agent types allowed

- `spawn_agent` no longer enforces type uniqueness. Multiple agents of the same
  type are now permitted (e.g. two `"developer"` agents working on different
  features in parallel). All agents are uniquely identified by their `id`; `type`
  is display metadata only. `list_team` + ID-based targeting makes type uniqueness
  unnecessary.

### Agent resilience

- **Tool task crash recovery** — `execute_fn` is now wrapped in try/rescue
  inside the task. Any exception sends `{:tool_done, id, name, {:error, message}}`
  instead of leaving the agent stuck in `:executing_tools`. Queued user messages
  sent during tool execution are therefore always flushed and persisted, preventing
  them from disappearing on page refresh.
- **Stream task crash recovery** — the LLM stream task is also wrapped in
  try/rescue. Exceptions send `{:stream_event, ref, {:error, message}}`, hitting
  the existing `reset_streaming` path and returning the agent to `:idle`.
- **Orphaned tool-call stripping** — when an agent starts with an existing session,
  `handle_continue(:load_session_history)` loads the DB history and strips any
  trailing assistant turn whose tool calls were never answered (left by a previous
  crash). The turn is removed from both in-memory state and the session DB.
- **`bash` nil-command guard** — the `bash` builtin returns
  `{:error, "missing required argument: command"}` instead of crashing when
  the LLM omits the `command` argument.

### Identity line moved to runtime

- `AgentSpec.to_start_opts/2` no longer prepends the identity line to
  `system_prompt`. The agent's `build_system_prompt/1` now injects it at
  runtime before each LLM call, generating `"You are a <type>."` or
  `"You are <name>, a <type>."` depending on whether name and type differ.

### Inter-agent tool overhaul

- **Renames** — tools renamed to make the sync/async distinction explicit:
  - `ask_agent` → `call_agent` (sync, blocks until the target responds)
  - `delegate_task` → `send_agent` (async, fire-and-forget)
  - `send_response` → `respond_agent`
- **`checkpoint_agent` removed** — replaced by `reset_previous_context: true`
  parameter on `call_agent` and `send_agent`. When true, archives the target's
  prior history before sending the message, giving it a clean slate. Workers
  have automatic compaction for in-task context growth; `reset_previous_context`
  is for deliberate redirection across tasks.
- **ID-only targeting** — `identifier` + `identifier_type` parameters removed
  from all targeting tools. All tools now accept a single `agent_id` (from
  `list_team`). Name/type-based resolution is gone; agents must call `list_team`
  to discover IDs before targeting. `list_team` description updated to highlight
  the `id` field. Error messages guide recovery: "Agent not found. Call list_team
  to get current agent IDs."
- **`spawn_agent` guidance** — returns the new agent's ID; the caller must save
  it for subsequent `call_agent`/`send_agent`/`interrupt_agent`/`destroy_agent` calls.

### `Planck.Agent.SystemPrompt` module

- All system prompt assembly extracted from `agent.ex` into a dedicated
  `Planck.Agent.SystemPrompt` module with `build/1` as the public entry point.
- Per-tool guidance sections injected only when the relevant tool is present.
  Grouped as: discovery → spawn → interaction → management.
- Role-aware intro: shows the ask/delegate decision rule when the agent has both
  `call_agent` and `send_agent`; simplified variant for agents with only one.
- Each section uses "Use when…" framing consistent with the skill description convention.
- `Planck.Agent.Tools` error messages updated with recovery hints ("Call list_team",
  "Call list_models") that fire at exactly the moment the agent needs them.

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

### YAML frontmatter via yamerl

- `Planck.Agent.Skill` now parses SKILL.md frontmatter using `yamerl` instead of a
  hand-rolled regex. Handles multi-line values, special characters, and the YAML
  `>` folded-scalar syntax without fragile string splitting.
- `yamerl ~> 0.10` added as a dependency.
- Note: YAML description values containing `:` must be quoted:
  `description: "Generate images: text-to-image and img2img."`

### Binary tool output guard

- `truncate_tool_output/1` now checks `String.valid?/1` before truncating.
  Non-UTF-8 binary output (e.g. raw image bytes returned by a tool) is replaced
  with `[binary file, N bytes — cannot display]` instead of crashing.

### Dynamic skill injection — `load_skill_tool/2`

- `Skill.load_skill_tool/2` accepts an optional `skill_refresh_fn` second argument.
  When provided, `load_skill` resolves the skill at call time rather than at agent
  start, enabling hot reload of edited SKILL.md files without restarting the agent.

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
