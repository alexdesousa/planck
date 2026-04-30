# planck_agent

## Purpose

OTP-based agent runtime that drives the LLM loop: stream a response, collect tool
calls, execute them concurrently, append results, and re-stream until the model stops.
Each agent is a `GenServer` supervised under a `DynamicSupervisor`.

Two roles emerge naturally from the tool set:

- **Orchestrators** have `spawn_agent` in their tool list — they create teams, assign
  work, and own the team's lifecycle. The team dies when the orchestrator terminates.
- **Workers** receive tasks, execute them, and report back. They cannot spawn agents.

There is no structural difference — role is determined solely by which tools an agent
has in its list.

## Dependencies

```elixir
{:planck_ai, "~> 0.1"},
{:jason, "~> 1.4"},
{:nimble_options, "~> 1.0"},
{:phoenix_pubsub, "~> 2.1"},
{:exqlite, "~> 0.23"},
{:erlexec, "~> 2.0"}
```

## What planck_agent does (and doesn't do)

`planck_ai` handles: HTTP transport, streaming, model catalog, content translation.

`planck_agent` adds:

- `GenServer` per agent with a typed state machine (`idle → streaming → executing_tools`)
- Parallel tool execution via `Task.async_stream` under a named `Task.Supervisor`
- Phoenix.PubSub broadcasting: `{:agent_event, type, payload}` on `"agent:#{id}"` and
  `"session:#{session_id}"` topics
- Team lifecycle: orchestrator owns a `team_id`; all agents with that `team_id` are
  terminated when the orchestrator exits (via process linking)
- Token usage tracking across all LLM calls in a turn; broadcast in real-time and
  included in `:turn_end`
- `rewind_to_message/2` — truncates both session and in-memory history to before a given message id; used by the edit-message feature
- Built-in inter-agent tools: `ask_agent`, `delegate_task`, `send_response`, `list_team`
- Built-in orchestrator-only tools: `spawn_agent`, `destroy_agent`, `interrupt_agent`,
  `list_models`
- `Planck.Agent.BuiltinTools` — `read`, `write`, `edit`, `bash` tool factories; `bash`
  is backed by `erlexec` with `Task.yield/shutdown` timeout handling
- `Planck.Agent.Skill` — filesystem-based skill loader; `load_all/1`, `from_file/1`,
  `system_prompt_section/1`
- `Planck.Agent.Session` — SQLite-backed persistent store with checkpoint-based pagination;
  caller supplies `dir:` explicitly (no built-in config; lives in `planck_headless`)
- `Planck.Agent.Compactor` — default LLM-based compaction anchored on `model.context_window`;
  used as fallback when no per-agent compactor is configured
- `Planck.Agent.Sidecar` — behaviour for sidecar applications; defines `list_tools/0`
  and `compactor_for/1`. See `specs/sidecar.md`.
- `Planck.Agent.Team` — loads a team directory (TEAM.json + members/) and exposes
  `%Team{}` as the runtime representation; tools merged in programmatically by the
  caller. See `specs/teams.md`.
- `Planck.Agent.AgentSpec` — member-entry struct and JSON parsers (`from_map/2`,
  `from_list/2`) shared by `Team.load/1` and any other code building specs from
  user-supplied maps

`planck_agent` does **not**:

- Know anything about HTTP or LLM providers — all LLM calls go through `planck_ai`
- Implement compaction strategy beyond the default `Compactor` — the hook is pluggable
- Inspect environment variables or detect API key availability — the caller
  pre-filters `available_models` before passing them in
- Define what tools workers have — the caller provides the tool list at start time
- Auto-load skills, external tools, or compactors — loading from the filesystem
  and wiring into agents is an application-level decision owned by `planck_headless`

## Core structs

### `Planck.Agent.Tool`

Extends `Planck.AI.Tool` with an execution function. Converted to `Planck.AI.Tool`
(dropping `execute_fn`) when building the `Planck.AI.Context`.

```elixir
%Planck.Agent.Tool{
  name:        String.t(),
  description: String.t(),
  parameters:  map(),
  execute_fn:  (id :: String.t(), args :: map() -> {:ok, String.t()} | {:error, String.t()})
}
```

### `Planck.Agent.Message`

Agent-side message with metadata. Messages with a `{:custom, atom()}` role are
filtered out before the context is sent to the LLM, with two exceptions:

- `{:custom, :summary}` is converted to a `:user` message — summary checkpoints
  must be visible to the model.
- `{:custom, :agent_response}` is converted to a `:user` message — worker responses
  must be visible so the orchestrator can react to them. When `metadata` contains
  `:sender_name`, the text is prefixed with `"Response from <name>: "` so the LLM
  knows which worker replied.

```elixir
%Planck.Agent.Message{
  id:        String.t(),
  role:      :user | :assistant | :tool_result | {:custom, atom()},
  content:   [Planck.AI.Message.content_part()],
  timestamp: DateTime.t(),
  metadata:  map()
}
```

### `Planck.Agent.AgentSpec`

Static, serializable member-entry struct — no `execute_fn`. Produced by
`AgentSpec.from_map/2` (single entry) and `AgentSpec.from_list/2` (JSON array
of entries), and consumed by `Planck.Agent.Team.load/1` when it parses
TEAM.json. The caller merges tools in before spawning.

```elixir
%Planck.Agent.AgentSpec{
  type:          String.t(),
  name:          String.t(),            # defaults to type when not provided
  description:   String.t() | nil,
  provider:      atom(),
  model_id:      String.t(),
  base_url:      String.t() | nil,      # server URL for local providers with multiple instances
  system_prompt: String.t(),            # already resolved from file path if applicable
  opts:          keyword(),
  tools:         [String.t()],          # tool names resolved from tool_pool: at start time
  skills:        [String.t()],          # skill names resolved from skill_pool: at start time;
                                        # appended to system_prompt via system_prompt_section/1
  compactor:     String.t() | nil       # sidecar module name for per-agent compaction,
                                        # e.g. "MySidecar.Compactors.Builder"; nil = default
}
```

### Agent state

Internal GenServer state — not part of the public API.

```elixir
%Planck.Agent{
  id:                 String.t(),
  name:               String.t() | nil,
  description:        String.t() | nil,
  type:               String.t() | nil,
  team_id:            String.t() | nil,
  session_id:         String.t() | nil,
  delegator_id:       String.t() | nil,
  role:               :orchestrator | :worker,
  model:              Planck.AI.Model.t(),
  available_models:   [Planck.AI.Model.t()],
  system_prompt:      String.t(),
  messages:           [Planck.Agent.Message.t()],
  tools:              %{String.t() => Planck.Agent.Tool.t()},
  opts:               keyword(),
  status:             :idle | :streaming | :executing_tools,
  stream_task:        Task.t() | nil,
  stream_ref:         reference() | nil,
  turn_index:         non_neg_integer(),
  turn_checkpoints:   [non_neg_integer()],
  pending_tool_calls: [map()],
  text_buffer:        String.t(),
  thinking_buffer:    String.t(),
  usage:              %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()},
  on_compact:         (([Message.t()] -> {:compact, Message.t(), [Message.t()]} | :skip)) | nil
}
```

`team_id` is `nil` for standalone agents.
`role` is derived at start time from whether `spawn_agent` is present in the tool list.
`delegator_id` is set automatically by `spawn_agent`; the LLM never addresses it.
`turn_checkpoints` is a stack of message-list lengths at the start of each user turn,
used internally for context management.

## Public API

```elixir
# Start an agent (standalone or under DynamicSupervisor).
@spec start_link(keyword()) :: GenServer.on_start()

# Truncate both the SQLite session and in-memory history to strictly before the
# message with the given db_id (Message.id == db_id for persisted messages).
# Also reloads the message list from the session DB to ensure canonical order.
# No-op for ephemeral agents (no session_id).
@spec rewind_to_message(agent(), message_id :: pos_integer()) :: :ok

# Send a user message and kick off the agent loop.
# Synchronous — returns :ok once the agent has set status to :streaming.
# If the agent is already busy (streaming or executing tools), the message is
# appended to history and processed automatically after the current turn ends.
@spec prompt(agent(), String.t() | [content_part()], keyword()) :: :ok

# Cancel in-flight streaming and tool execution. Agent returns to :idle.
@spec abort(agent()) :: :ok

# Graceful shutdown — cancels any in-flight work.
@spec stop(agent()) :: :ok

# Synchronous state snapshot (for tests and UI initial render).
@spec get_state(agent()) :: %Planck.Agent{}

# Lightweight metadata: id, name, description, type, role, status, turn_index, usage.
@spec get_info(agent()) :: map()

# Subscribe the calling process to {:agent_event, type, payload} messages.
@spec subscribe(String.t() | agent()) :: :ok | {:error, term()}

# Resolve an agent id to a pid.
@spec whereis(String.t()) :: {:ok, pid()} | {:error, :not_found}

# Dynamically add/remove tools at runtime.
@spec add_tool(agent(), Planck.Agent.Tool.t()) :: :ok
@spec remove_tool(agent(), name :: String.t()) :: :ok

@type agent() :: pid() | atom() | {:via, module(), term()}
```

`start_link` options:

| Key | Type | Required | Notes |
|---|---|---|---|
| `id` | `String.t()` | yes | Unique agent ID |
| `type` | `String.t()` | no | Role type; used for team discovery |
| `name` | `String.t()` | no | Human-readable label |
| `description` | `String.t()` | no | One-line purpose shown via `list_team` |
| `model` | `Planck.AI.Model.t()` | yes | |
| `system_prompt` | `String.t()` | no | Defaults to `""` |
| `tools` | `[Planck.Agent.Tool.t()]` | no | Defaults to `[]` |
| `opts` | `keyword()` | no | Forwarded to the LLM call |
| `available_models` | `[Planck.AI.Model.t()]` | no | For `list_models` tool |
| `team_id` | `String.t()` | no | Joins a team; nil for standalone |
| `session_id` | `String.t()` | no | Enables session persistence and session-topic broadcasting |
| `delegator_id` | `String.t()` | no | Set by `spawn_agent`; rarely passed directly |
| `on_compact` | function | no | Context compaction hook |

## Agent loop — state machine

```
                   prompt/3 (when idle)
   idle ───────────────────────────────────► streaming
    ▲                                            │
    │                                     stream events
    │                                            │ accumulate text / tool calls
    │                                            ▼
    │                                     stream done
    │                                    /            \
    │                           no tool calls        tool calls pending
    │                                │                      │
    │◄───────────────────────────────┘                      ▼
    │       (unless pending input*)             executing_tools
    │                                                  │
    │                                       Task.async_stream
    │                                       (parallel execution)
    │                                                  │
    │                                       all tools complete
    │                                                  │
    │                                       append tool_result message
    │                                                  ▼
    │                                              streaming  ──► (loop)
    │
    │   abort/1 (any status)
    │◄──────────────────────────────────────────────────
    │       (unless pending input*)
    │
    │   send_response / ask_agent / delegate_task arrives while busy
    │       message appended to history; re-triggers after current turn *
    │
    └◄── (*) maybe_turn_start/1 fires when pending input detected:
             any :user or {:custom, :agent_response} message that arrived
             after the turn-starting message (identified via turn_checkpoints)
```

## Built-in tools

### Available to all agents

**`ask_agent`** — blocking. Sends a prompt to an existing agent in the same team and
waits for its `:turn_end` before returning. The tool runs in a `Task`, not the
GenServer itself, so blocking is safe and the caller's GenServer loop stays free.
Blocks indefinitely — there is no `timeout_ms`; callers should abort the agent
to break a stuck wait. The target process is monitored; if it crashes, the tool
returns `{:error, "Agent terminated: ..."}`.

**Deadlock detection** — before blocking, `ask_agent` checks whether the target
is (transitively) waiting for the caller by walking the `{:waiting, agent_id}`
entries in `Planck.Agent.Registry`. If a cycle is found it returns
`{:error, "Deadlock detected: ..."}` immediately instead of blocking. The waiting
entry is automatically removed from the registry when the task exits.

**`delegate_task`** — non-blocking. Sends a task and returns immediately. The delegatee
calls `send_response` when done.

**`send_response`** — non-blocking. Routes a result back to `delegator_id`. Re-triggers
the delegator if idle; injects a `{:custom, :agent_response}` message if active.
Carries sender attribution (`%{id, name}` captured at worker start time) so the
delegator's `agent_response` message is tagged with `:sender_id` and `:sender_name`
in its metadata.

**`list_team`** — returns all agents in the team with type, name, description, status,
and turn index. Pass `verbose: true` to also include tool names and model for each
member — useful when reasoning about which worker to delegate a task to.

### Available to orchestrators only

**`spawn_agent`** — creates a new worker under the same `team_id` and `session_id`.
Returns the new agent's id. Accepts optional `"tools"` and `"skills"` JSON arrays;
the orchestrator grants a subset of its `grantable_tools` / `grantable_skills` to
the spawned worker by name (no privilege escalation). Workers always receive the
standard `worker_tools` in addition to granted tools. The spawned worker emits a
`:worker_spawned` PubSub event on the session topic on startup.

**`destroy_agent`** — terminates a worker permanently.

**`interrupt_agent`** — aborts a worker's current turn; worker stays alive.

**`list_models`** — returns the configured and connected models available for
spawning agents. Each entry includes `provider`, `id`, `name`, `context_window`,
and `base_url`. Pass the returned `base_url` to `spawn_agent` to ensure the model
is resolved correctly regardless of provider configuration.

## Built-in file and shell tools

`Planck.Agent.BuiltinTools` provides four factory functions. Each returns a
`Planck.Agent.Tool` struct ready to be passed in a tool list.

| Function | Tool name | Key args |
|---|---|---|
| `read/0`  | `read`  | `path` (required), `offset`, `limit` |
| `write/0` | `write` | `path`, `content` |
| `edit/0`  | `edit`  | `path`, `old_string`, `new_string` |
| `bash/0`  | `bash`  | `command` (required), `cwd`, `timeout` |

**`read`** streams the file line-by-line with `File.stream!(:line)`. `offset` and
`limit` select a window without loading the whole file into memory. Expands `~` in
paths.

**`edit`** splits on `old_string` using `String.split(content, old, parts: 3)`:
one part → not found; two parts → unique match; three+ → ambiguous.

**`bash`** passes the command as a binary string to `erlexec`, which routes it
through `/bin/sh -c`. Both stdout and stderr are captured; stderr is appended under a
`STDERR:` header. Timeout is implemented via `Task.yield/2 || Task.shutdown/1` so no
orphaned process is left linked to the GenServer. Exit status is decoded from the raw
`waitpid()` value (`status * 256` → `status`).

## Skills

`Planck.Agent.Skill` loads skills from directories on the filesystem. A skill is a
subdirectory with a `SKILL.md` file:

```
<skills_dir>/
  code_review/
    SKILL.md       # required — name + description frontmatter
    resources/     # optional — any extra files the LLM may reference
```

`SKILL.md` frontmatter (YAML-style, CRLF-safe):

```markdown
---
name: code_review
description: Reviews code for correctness, style, and performance.
---
```

API:

```elixir
# Load all skills from a list of directories; missing dirs are skipped silently.
@spec load_all([Path.t()]) :: [Skill.t()]

# Load a single skill from its SKILL.md path.
@spec from_file(Path.t()) :: {:ok, Skill.t()} | {:error, String.t()}

# Build a system-prompt snippet listing skills with file and resources paths.
# Returns nil when the list is empty.
@spec system_prompt_section([Skill.t()]) :: String.t() | nil
```

Configured via `PLANCK_SKILLS_DIRS` env var or `config :planck, :skills_dirs, [...]`
in `planck_headless`. Callers pass the resolved dirs explicitly to `load_all/1`.

## Session

`Planck.Agent.Session` is a GenServer backed by SQLite, registered globally as
`{:session, session_id}`. Agents with a `session_id` append every message (including
summary checkpoints) to the session automatically.

Each row returned by `Session.messages/1` (and the pagination variants) is a map with:

```elixir
%{
  db_id:       pos_integer(),   # SQLite autoincrement row id
  agent_id:    String.t(),
  message:     Planck.Agent.Message.t(),
  inserted_at: integer()        # Unix seconds
}
```

`db_id` is the stable SQLite row id and is used to anchor `truncate_after/2`.

Messages with role `{:custom, :summary}` are stored with `checkpoint = 1`, enabling
efficient pagination:

```elixir
# Initial load — latest checkpoint + messages after
{:ok, rows, checkpoint_id} = Session.messages_from_latest_checkpoint(session_id)

# Load more — previous chapter
{:ok, rows, prev_id} = Session.messages_before_checkpoint(session_id, checkpoint_id)
# prev_id == nil means no more history
```

Additional Session API:

```elixir
# Delete all messages with db_id >= db_id across ALL agents in the session.
# Used when editing a previous message: truncate the store, then call
# Agent.rewind_to_message/2 and re-prompt.
@spec Session.truncate_after(session_id(), db_id :: pos_integer()) ::
        :ok | {:error, :not_found}
```

## Compaction

`Planck.Agent.Compactor.build/2` returns an `on_compact` function. It estimates token
usage from message content (chars ÷ 4) and triggers when usage exceeds
`ratio * model.context_window` (default ratio: 0.8).

When triggered, it summarises older messages via an LLM call using a prompt that
prioritises the active goal and recent requests. Returns `{:compact, summary_msg, kept}`
on success or `:skip` on failure (original messages unchanged).

The agent inserts the summary as a `{:custom, :summary}` checkpoint in `state.messages`
and persists it to the session. Future LLM calls are built from the latest checkpoint
onward — full history is retained in the session for audit and UI pagination.

Custom compactors implement the `Planck.Agent.Compactor` behaviour and are
referenced by module name in `AgentSpec.compactor`; the module lives in the
sidecar application (see `specs/sidecar.md`).

```elixir
on_compact = Planck.Agent.Compactor.build(model, ratio: 0.8, keep_recent: 10)
```

## Pub/Sub events

All events are `{:agent_event, type, payload}` broadcast via Phoenix.PubSub.

| Event | Payload keys | When |
|---|---|---|
| `:turn_start` | `index` | New LLM turn begins |
| `:turn_end` | `message`, `usage` | Turn complete, no pending tools |
| `:text_delta` | `text` | Streaming text chunk |
| `:thinking_delta` | `text` | Streaming thinking chunk |
| `:usage_delta` | `delta`, `total` | Each `{:done}` event from the LLM |
| `:tool_start` | `id`, `name`, `args` | Tool execution begins |
| `:tool_end` | `id`, `name`, `result`, `error` | Tool finished |
| `:rewind` | `message_count` | History rewound |
| `:worker_exit` | `pid`, `reason` | Worker process exited (orchestrator only) |
| `:error` | `reason` | Stream or tool error; agent returns to `:idle` |
| `:compacting` | — | Context compaction started (before LLM summary call) |
| `:compacted` | — | Context compaction finished; summary checkpoint written |

## Supervision tree

```
Planck.Agent.Supervisor  (strategy: :one_for_all)
├── Phoenix.PubSub        (name: Planck.Agent.PubSub)
├── Registry              (keys: :duplicate, name: Planck.Agent.Registry)
├── Task.Supervisor       (name: Planck.Agent.TaskSupervisor)
├── DynamicSupervisor     (name: Planck.Agent.SessionSupervisor, strategy: :one_for_one)
│   └── Planck.Agent.Session  (restart: :temporary, registered via :global)
└── DynamicSupervisor     (name: Planck.Agent.AgentSupervisor, strategy: :one_for_one)
    ├── Planck.Agent (id: "orch-1", role: :orchestrator, team_id: "team-abc")
    ├── Planck.Agent (id: "work-1", role: :worker,       team_id: "team-abc")
    └── Planck.Agent (id: "work-2", role: :worker,       team_id: "team-abc")
```

`:one_for_all` on the top-level supervisor ensures the Registry and PubSub always
restart together — a stale Registry after a crash would leave agents unable to find
each other.

## Teams

Teams are defined by a directory containing a `TEAM.json` file and optional
per-member folders. See `specs/teams.md` for the full directory convention,
scoping rules, and dynamic-vs-static model. The short form:

```elixir
alias Planck.Agent
alias Planck.Agent.{AgentSpec, Compactor, Team}

{:ok, team} = Team.load(".planck/teams/elixir-dev-workflow")

team_id    = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
session_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
on_compact = Compactor.build(model)

Enum.each(team.members, fn spec ->
  tools = Map.get(tools_by_type, spec.type, [])
  start_opts = AgentSpec.to_start_opts(spec,
    tools: tools,
    team_id: team_id,
    session_id: session_id,
    on_compact: on_compact
  )
  DynamicSupervisor.start_child(Planck.Agent.AgentSupervisor, {Agent, start_opts})
end)
```

Individual member entries follow the JSON schema documented on
`Planck.Agent.AgentSpec`. `Team.load/1` invokes `AgentSpec.from_list/2`
internally, so any code that needs to build an `AgentSpec` from a decoded map
(e.g. `spawn_agent`) shares the same parser.

## Testing strategy

### Unit tests

- `Tool.new/1` — struct construction, missing required fields
- `Message` filtering — `{:custom, _}` dropped; `{:custom, :summary}` converted to `:user`
- `AgentSpec.from_map/2` / `from_list/2` — valid entries, missing fields, file
  path resolution, provider validation
- `AgentSpec.new/1` / `to_start_opts/2` — field merging, model resolution
- `Team.load/1` — valid directories, missing TEAM.json, member validation,
  name-uniqueness, skills/tools field parsing (see `specs/teams.md`)
- `Session` — append, messages, truncate, checkpoint pagination, persistence across restart
- `Compactor` — threshold check, summary generation, fallback on LLM error, keep_recent
- `BuiltinTools` — each of the four tools exercised directly via `tool.execute_fn`:
  - `read`: exists, missing, `~` expansion, offset, limit, offset+limit, offset beyond EOF
  - `write`: creates, overwrites, missing parents, error when parent is a file
  - `edit`: replaces, not found, more than once, missing file
  - `bash`: stdout, stderr, non-zero exit, `cwd` arg, timeout
- `Skill` — `from_file/1`, `load_all/1`, `system_prompt_section/1`; checks `resources dir:`
  label in prompt output

### Integration tests (Mox)

`Planck.Agent.AIBehaviour` wraps `Planck.AI.stream/3`. `MockAI` is injected via
application config. Tests assert broadcast sequences and final `get_state/1` output.

- Text-only response → `:turn_end` with assembled message and usage
- Tool call round-trip → tool executed → result appended → second LLM turn
- Abort mid-stream → task terminated, status `:idle`, no `:turn_end`
- Error path → `:error` event, agent returns to `:idle`
- `on_compact` hook → called before LLM turn; hook output sent to LLM
- Usage tracking → `:usage_delta` and `:turn_end` include correct token counts
- `rewind/2` → messages trimmed, `:rewind` event broadcast

### Multi-agent tests

- `ask_agent` — blocks until target responds; returns response text as tool result
- `delegate_task` + `send_response` — worker re-triggers orchestrator on completion
- Team teardown — orchestrator exit terminates all workers in same team
- `destroy_agent` — worker process goes down; registry entry removed
- `interrupt_agent` — worker returns to `:idle`; stays alive
- `spawn_agent` grantable tools — orchestrator grants `read`; worker receives it and
  unknown names are ignored; worker without grant cannot use the tool
- Built-in tools via spawned worker — each of `read`, `write`, `edit`, `bash` exercised
  end-to-end through a real spawned agent to confirm tool wiring
