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
{:skogsra, "~> 2.5"}
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
- `rewind/2` — removes the last `n` user turns from message history; syncs session store
- Built-in inter-agent tools: `ask_agent`, `delegate_task`, `send_response`, `list_team`
- Built-in orchestrator-only tools: `spawn_agent`, `destroy_agent`, `interrupt_agent`,
  `list_models`
- `Planck.Agent.Session` — SQLite-backed persistent store with checkpoint-based pagination
- `Planck.Agent.Config` — Skogsra config for `sessions_dir`
- `Planck.Agent.Compactor` — default LLM-based compaction anchored on `model.context_window`
- `Planck.Agent.TeamTemplate` — loads static agent definitions from JSON; tools merged
  in programmatically by the caller

`planck_agent` does **not**:

- Know anything about HTTP or LLM providers — all LLM calls go through `planck_ai`
- Implement compaction strategy beyond the default `Compactor` — the hook is pluggable
- Inspect environment variables or detect API key availability — the caller
  pre-filters `available_models` before passing them in
- Define what tools workers have — the caller provides the tool list at start time

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
filtered out before the context is sent to the LLM, **except** `{:custom, :summary}`
which is converted to a `:user` message — summary checkpoints must be visible to the
model.

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

Intermediate struct returned by `TeamTemplate` — static data only, no `execute_fn`.
The caller merges tools in before spawning.

```elixir
%Planck.Agent.AgentSpec{
  type:          String.t(),
  name:          String.t() | nil,
  description:   String.t() | nil,
  provider:      atom(),
  model_id:      String.t(),
  system_prompt: String.t(),   # already resolved from file path if applicable
  opts:          keyword()
}
```

### Agent state

Internal GenServer state — not part of the public API.

```elixir
%Planck.Agent.Agent{
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
  on_compact:         (([Message.t()] -> {:summary, String.t()} | :skip)) | nil
}
```

`team_id` is `nil` for standalone agents.
`role` is derived at start time from whether `spawn_agent` is present in the tool list.
`delegator_id` is set automatically by `spawn_agent`; the LLM never addresses it.
`turn_checkpoints` is a stack of message-list lengths at the start of each user turn,
used by `rewind/2`.

## Public API

```elixir
# Start an agent (standalone or under DynamicSupervisor).
@spec start_link(keyword()) :: GenServer.on_start()

# Send a user message and kick off the agent loop (async).
@spec prompt(agent(), String.t() | [content_part()], keyword()) :: :ok

# Cancel in-flight streaming and tool execution. Agent returns to :idle.
@spec abort(agent()) :: :ok

# Graceful shutdown — cancels any in-flight work.
@spec stop(agent()) :: :ok

# Remove the last n user-initiated turns from message history.
@spec rewind(agent(), pos_integer()) :: :ok

# Synchronous state snapshot (for tests and UI initial render).
@spec get_state(agent()) :: %Planck.Agent.Agent{}

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
                   prompt/3
   idle ───────────────────────────► streaming
    ▲                                    │
    │                             stream events
    │                                    │ accumulate text / tool calls
    │                                    ▼
    │                             stream done
    │                            /            \
    │                   no tool calls        tool calls pending
    │                        │                      │
    │◄───────────────────────┘                      ▼
    │                                       executing_tools
    │                                              │
    │                                   Task.async_stream
    │                                   (parallel execution)
    │                                              │
    │                                   all tools complete
    │                                              │
    │                                   append tool_result message
    │                                              ▼
    │                                          streaming  ──► (loop)
    │
    │   abort/1 (any status)
    │◄──────────────────────────────────────────────
    │
    │   send_response received (inter-agent)
    └◄──────────────────────────────────────────────
        inject {:custom, :agent_response} message
        re-trigger via {:continue, :run_llm}
```

## Built-in tools

### Available to all agents

**`ask_agent`** — blocking. Sends a prompt to an existing agent in the same team and
waits for its `:turn_end` before returning. The tool runs in a `Task`, not the
GenServer itself, so blocking is safe. Accepts optional `timeout_ms` (default 300 000).

**`delegate_task`** — non-blocking. Sends a task and returns immediately. The delegatee
calls `send_response` when done.

**`send_response`** — non-blocking. Routes a result back to `delegator_id`. Re-triggers
the delegator if idle; injects a `{:custom, :agent_response}` message if active.

**`list_team`** — returns all agents in the team with type, name, description, status,
and turn index.

### Available to orchestrators only

**`spawn_agent`** — creates a new worker under the same `team_id` and `session_id`.
Returns the new agent's id.

**`destroy_agent`** — terminates a worker permanently.

**`interrupt_agent`** — aborts a worker's current turn; worker stays alive.

**`list_models`** — returns the `available_models` list passed at orchestrator start
time. No network call.

## Session

`Planck.Agent.Session` is a GenServer backed by SQLite, registered globally as
`{:session, session_id}`. Agents with a `session_id` append every message (including
summary checkpoints) to the session automatically.

Messages with role `{:custom, :summary}` are stored with `checkpoint = 1`, enabling
efficient pagination:

```elixir
# Initial load — latest checkpoint + messages after
{:ok, rows, checkpoint_id} = Session.messages_from_latest_checkpoint(session_id)

# Load more — previous chapter
{:ok, rows, prev_id} = Session.messages_before_checkpoint(session_id, checkpoint_id)
# prev_id == nil means no more history
```

## Compaction

`Planck.Agent.Compactor.build/2` returns an `on_compact` function. It estimates token
usage from message content (chars ÷ 4) and triggers when usage exceeds
`ratio * model.context_window` (default ratio: 0.8).

When triggered, it summarises older messages via an LLM call using a prompt that
prioritises the active goal and recent requests. Returns `{:summary, text}` on success
or `:skip` on failure (original messages unchanged).

The agent inserts the summary as a `{:custom, :summary}` checkpoint in `state.messages`
and persists it to the session. Future LLM calls are built from the latest checkpoint
onward — full history is retained in the session for audit and UI pagination.

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

## Supervision tree

```
Planck.Agent.Supervisor  (strategy: :one_for_all)
├── Phoenix.PubSub        (name: Planck.Agent.PubSub)
├── Registry              (keys: :duplicate, name: Planck.Agent.Registry)
├── Task.Supervisor       (name: Planck.Agent.TaskSupervisor)
├── DynamicSupervisor     (name: Planck.Agent.SessionSupervisor, strategy: :one_for_one)
│   └── Planck.Agent.Session  (restart: :temporary, registered via :global)
└── DynamicSupervisor     (name: Planck.Agent.AgentSupervisor, strategy: :one_for_one)
    ├── Planck.Agent.Agent (id: "orch-1", role: :orchestrator, team_id: "team-abc")
    ├── Planck.Agent.Agent (id: "work-1", role: :worker,       team_id: "team-abc")
    └── Planck.Agent.Agent (id: "work-2", role: :worker,       team_id: "team-abc")
```

`:one_for_all` on the top-level supervisor ensures the Registry and PubSub always
restart together — a stale Registry after a crash would leave agents unable to find
each other.

## Team templates

```json
[
  {
    "type":          "builder",
    "name":          "Builder Joe",
    "description":   "Writes and edits code",
    "provider":      "anthropic",
    "model_id":      "claude-sonnet-4-6",
    "system_prompt": "You are an expert builder.",
    "opts": { "temperature": 0.7 }
  },
  {
    "type":          "tester",
    "name":          "Tester Alice",
    "description":   "Writes and runs tests",
    "provider":      "ollama",
    "model_id":      "llama3.2",
    "system_prompt": "prompts/tester.md"
  }
]
```

`system_prompt` accepts an inline string or a `.md`/`.txt` file path resolved relative
to the template file. Valid providers are derived from `Planck.AI.Model.providers/0`.

```elixir
{:ok, specs} = TeamTemplate.load("config/team.json")

team_id    = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
session_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
on_compact = Planck.Agent.Compactor.build(model)

Enum.each(specs, fn spec ->
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

## Testing strategy

### Unit tests

- `Tool.new/1` — struct construction, missing required fields
- `Message` filtering — `{:custom, _}` dropped; `{:custom, :summary}` converted to `:user`
- `TeamTemplate.load/1` / `from_list/1` — valid entries, missing fields, file path
  resolution, invalid JSON, provider validation
- `AgentSpec.new/1` / `to_start_opts/2` — field merging, model resolution
- `Session` — append, messages, truncate, checkpoint pagination, persistence across restart
- `Compactor` — threshold check, summary generation, fallback on LLM error, keep_recent

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
