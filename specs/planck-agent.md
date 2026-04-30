# planck_agent

## Purpose

OTP-based agent runtime that drives the LLM loop: stream a response, collect tool
calls, execute them concurrently, append results, and re-stream until the model stops.
Each agent is a `GenServer` supervised under a single `DynamicSupervisor`.

Two roles emerge naturally from the tool set:

- **Orchestrators** have `spawn_agent` and `destroy_agent` available — they create
  teams, assign work, and own the team's lifecycle. The team dies when the
  orchestrator terminates.
- **Workers** receive tasks, execute them, and report back. They cannot spawn agents.

There is no structural difference — role is determined solely by which tools an agent
has in its list.

## Dependencies

```elixir
{:planck_ai, "~> 0.1"},
{:jason, "~> 1.4"},
{:nimble_options, "~> 1.0"}
```

No Phoenix dependency — pub/sub is Registry-based.

## What planck_agent does (and doesn't do)

`planck_ai` handles: HTTP transport, streaming, model catalog, content translation.

`planck_agent` adds:

- `GenServer` per agent with a typed state machine (`idle → streaming → executing_tools`)
- Parallel tool execution via `Task.async_stream` under a named `Task.Supervisor`
- Registry-based pub/sub: typed `{:agent_event, type, payload}` broadcast to subscribers
- Team lifecycle: orchestrator owns a `team_id`; all agents with that `team_id` are
  terminated when the orchestrator exits
- Three built-in inter-agent tools available to all agents: `ask_agent`,
  `delegate_task`, `send_response`
- Three built-in orchestrator-only tools: `spawn_agent`, `destroy_agent`, `interrupt_agent`
- One built-in orchestrator-only tool: `list_models` (returns pre-filtered
  `available_models` passed at start time)
- Pluggable context compaction hook — called before every LLM turn; default passes
  all messages as-is; compaction logic lives in the caller (e.g. `planck_cli`)
- Abort: cancels the in-flight stream task and clears pending tool calls; agent
  returns to `:idle`
- `Planck.Agent.TeamTemplate` — loads static agent definitions from JSON; tools
  merged in programmatically by the caller

`planck_agent` does **not**:

- Know anything about HTTP or LLM providers — all LLM calls go through `planck_ai`
- Implement compaction strategy — it only calls the hook
- Persist messages — session storage is the caller's responsibility
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
  execute_fn:  (id :: String.t(), args :: map() -> {:ok, term()} | {:error, term()})
}
```

Built with `Tool.new/1`:

```elixir
Tool.new(
  name: "read_file",
  description: "Read a file",
  parameters: %{
    "type" => "object",
    "properties" => %{"path" => %{"type" => "string"}},
    "required" => ["path"]
  },
  execute_fn: fn _id, %{"path" => path} ->
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
)
```

### `Planck.Agent.Message`

Agent-side message with metadata. Messages with a `{:custom, atom()}` role are
UI-only and filtered out before the context is sent to the LLM.

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
  provider:      atom(),
  model_id:      String.t(),
  system_prompt: String.t(),   # already resolved from file path if applicable
  opts:          keyword()
}
```

### `Planck.Agent.State`

Internal GenServer state — not part of the public API.

```elixir
%Planck.Agent.State{
  id:                 String.t(),
  name:               String.t() | nil,      # human-readable label for UI
  team_id:            String.t() | nil,      # nil for standalone agents
  delegator_id:       String.t() | nil,      # set by spawn_agent; nil for orchestrators
  role:               :orchestrator | :worker,
  model:              Planck.AI.Model.t(),
  available_models:   [Planck.AI.Model.t()], # pre-filtered list for list_models tool
  system_prompt:      String.t(),
  messages:           [Planck.Agent.Message.t()],
  tools:              %{String.t() => Planck.Agent.Tool.t()},
  opts:               keyword(),
  status:             :idle | :streaming | :executing_tools,
  stream_task:        Task.t() | nil,
  stream_ref:         reference() | nil,
  pending_tool_calls: [map()],
  on_compact:         (([Planck.Agent.Message.t()]) -> [Planck.Agent.Message.t()]) | nil
}
```

`team_id` is `nil` for standalone agents (no multi-agent coordination needed).
`role` is derived at start time from whether `spawn_agent`/`destroy_agent` are
present in the tool list — it is never set directly by the caller.
`delegator_id` is set automatically by `spawn_agent`; the LLM never addresses it.

## Public API

```elixir
# Start an agent (standalone or as part of a team via DynamicSupervisor).
@spec start_link(keyword()) :: GenServer.on_start()

# Send a user message and kick off the agent loop (async — returns immediately).
@spec prompt(agent(), String.t() | [Planck.AI.Message.content_part()], keyword()) :: :ok

# Cancel in-flight streaming and tool execution. Agent returns to :idle.
@spec abort(agent()) :: :ok

# Synchronous state snapshot (for tests and UI initial render).
@spec get_state(agent()) :: Planck.Agent.State.t()

# Register a subscriber. Agent sends {:agent_event, type, payload} messages to it.
@spec subscribe(agent(), subscriber :: pid()) :: :ok

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
| `name` | `String.t()` | no | Human-readable label; nil = unnamed |
| `model` | `Planck.AI.Model.t()` | yes | |
| `system_prompt` | `String.t()` | no | Defaults to `""` |
| `tools` | `[Planck.Agent.Tool.t()]` | no | Defaults to `[]` |
| `opts` | `keyword()` | no | Default inference opts |
| `available_models` | `[Planck.AI.Model.t()]` | no | For `list_models` tool; defaults to `[]` |
| `on_compact` | function | no | Context compaction hook |
| `name` | GenServer name | no | Optional process registration |

`team_id` and `delegator_id` are intentionally absent — they are assigned
internally by `spawn_agent`, never passed directly by callers.

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

**Key transitions:**

- `prompt/3` is the only external entry point into the loop — adds a user message
  and transitions to `:streaming` via `{:continue, :run_llm}`
- `abort/1` terminates the stream task and clears pending tool calls from any state
- An incoming `send_response` while `:idle` re-triggers the loop directly
- An incoming `send_response` while `:streaming` or `:executing_tools` injects a
  `{:custom, :agent_response}` message — picked up on the next LLM turn
- The loop only exits to `:idle` when streaming completes with no pending tool calls

## Built-in tools

### Available to all agents

**`ask_agent`** — blocking. Sends a prompt to an existing agent in the same team and
waits for its `:turn_end` before returning. Since tool execution runs in a `Task`
(not the GenServer itself), blocking the task is safe — the calling agent's GenServer
stays responsive throughout.

```
args:    %{"type" | "name" | "id" => string, "question" => string}
returns: {:ok, response_text} | {:error, :not_found | :timeout}
```

**`delegate_task`** — non-blocking. Sends a task to an existing agent in the same
team and returns immediately. The delegatee calls `send_response` when done, which
re-triggers the delegator. Fails immediately if no matching agent exists in the team.

```
args:    %{"type" | "name" | "id" => string, "task" => string}
returns: {:ok, agent_id} | {:error, :not_found}
```

**`send_response`** — non-blocking. Sends a result back to the agent that delegated
the current task. Routes via `delegator_id` stored in state — the LLM only provides
the response content, not the destination. If the delegator is `:idle`, re-triggers
its loop. If active, injects a `{:custom, :agent_response}` message into its context.

```
args:    %{"response" => string}
returns: {:ok} | {:error, :no_delegator}
```

### Available to orchestrators only

**`spawn_agent`** — creates a new worker under the same `team_id`, registers it in
the Registry, and stores the orchestrator's `id` as `delegator_id` in the worker's
state. Returns immediately once the worker is started.

```
args: %{
  "type"          => string,
  "name"          => string,
  "system_prompt" => string,
  "provider"      => string,   # e.g. "anthropic"
  "model_id"      => string    # e.g. "claude-sonnet-4-6"
}
returns: {:ok, agent_id} | {:error, :already_exists | :model_not_found}
```

**`destroy_agent`** — terminates a worker in the team. If the worker is mid-turn,
it is aborted first. Useful for resetting a misbehaving worker or freeing resources.

```
args:    %{"type" | "name" | "id" => string}
returns: {:ok} | {:error, :not_found}
```

**`interrupt_agent`** — aborts a worker's current turn and returns it to `:idle`.
The worker stays alive and its mailbox is intact — queued messages are processed
normally after the interrupt. Use `destroy_agent` to terminate permanently.

```
args:    %{"type" | "name" | "id" => string}
returns: {:ok} | {:error, :not_found}
```

**`list_models`** — returns the `available_models` list passed at orchestrator start
time. No network call — the caller pre-filters this list before starting the agent.

```
args:    %{}
returns: {:ok, [%{provider: string, id: string, name: string, context_window: integer}]}
```

## Inter-agent communication

### Registry-based discovery

All inter-agent tool calls resolve the target agent through the Registry before
acting. Resolution priority:

1. `id` — direct lookup, no Registry needed (pid stored in state by orchestrator)
2. `name` — `Registry.lookup(Planck.Agent.Registry, {team_id, name})`
3. `type` — `Registry.lookup(Planck.Agent.Registry, {team_id, type})`, first match wins

If resolution fails, the tool returns `{:error, :not_found}` immediately.

### `ask_agent` flow

```
caller agent (task)              target agent (GenServer)
      │                                  │
      │── prompt ──────────────────────► │ (transitions to :streaming)
      │                                  │
      │   [blocks task, not GenServer]   │ ... runs loop ...
      │                                  │
      │◄── {:agent_event, :turn_end} ────│
      │                                  │
   returns response text
```

The task subscribes to the target agent's events, sends a prompt, and blocks until
`{:agent_event, :turn_end, %{message: msg}}` is received or a timeout is hit.

### `delegate_task` / `send_response` flow

```
orchestrator                  worker
     │                          │
     │── delegate_task ────────►│ prompt/3 called
     │◄── {:ok, agent_id} ──────│ returns immediately
     │                          │
     │   [continues or idles]   │ ... runs full loop ...
     │                          │
     │                          │── send_response ──► injects {:custom, :agent_response}
     │                          │                     into orchestrator messages
     │                          │
     │◄── {:continue, :run_llm} │ re-triggered if :idle
     │    or context injection   │ context injected if active
```

The delegator's `id` is stored in the worker's `delegator_id` field at spawn time
so `send_response` always knows where to route the result.

## Supervision tree

```
Planck.Agent.Supervisor  (strategy: :one_for_all)
├── Registry              (keys: :duplicate, name: Planck.Agent.Registry)
├── Task.Supervisor       (name: Planck.Agent.TaskSupervisor)
└── DynamicSupervisor     (name: Planck.Agent.AgentSupervisor, strategy: :one_for_one)
    ├── Planck.Agent.Agent (id: "orch-1", role: :orchestrator, team_id: "team-abc")
    ├── Planck.Agent.Agent (id: "work-1", role: :worker,       team_id: "team-abc")
    └── Planck.Agent.Agent (id: "work-2", role: :worker,       team_id: "team-abc")
```

`:one_for_all` on the top-level supervisor ensures the Registry and TaskSupervisor
always restart together — a stale Registry after a crash would leave agents unable
to find each other.

**Team lifecycle on orchestrator exit:**

When an orchestrator terminates (normally or abnormally), `planck_agent` terminates
all agents sharing the same `team_id` via `DynamicSupervisor.terminate_child/2`.
Workers are aborted if mid-turn before termination.

The orchestrator monitors its team via `Process.monitor/1` on each spawned worker,
so it is notified if a worker crashes unexpectedly before `destroy_agent` is called.

**Agent registration:**

Agents register in the Registry under two keys on start:

- `{team_id, type}` — for type-based discovery
- `{team_id, name}` — for name-based discovery (skipped if `name` is nil)

Standalone agents (no `team_id`) skip Registry registration entirely.

**Stream task lifecycle:**

The stream runs in a `Task.Supervisor.start_child` task (not linked to the GenServer
directly). The task pid and a unique ref are stored in state.

- **Normal completion**: task sends `{:stream_done, ref}` to the agent
- **Abort**: agent calls `Task.Supervisor.terminate_child/2` on the task pid; stale
  stream events with an old `ref` are dropped via pattern match guard
- **Task crash**: the stream emits `{:error, _}` before the crash reaches the task
  boundary, so the agent handles the error event rather than a process exit

## Team templates and model availability

### `Planck.Agent.TeamTemplate`

Loads the static parts of agent definitions from a JSON file. Tools are always
provided programmatically — `execute_fn` cannot be serialized.

```json
[
  {
    "type":          "builder",
    "name":          "Builder Joe",
    "provider":      "anthropic",
    "model_id":      "claude-sonnet-4-6",
    "system_prompt": "You are an expert builder.",
    "opts": {
      "temperature": 0.7
    }
  },
  {
    "type":          "tester",
    "name":          "Tester Alice",
    "provider":      "ollama",
    "model_id":      "llama3.2",
    "system_prompt": "prompts/tester.md"
  }
]
```

`system_prompt` accepts either an inline string or a file path — the loader
resolves file paths relative to the template file's directory.

Two entry points (mirrors `Planck.AI.Config`):

- `load/1` — reads and parses a JSON file by path
- `from_list/1` — accepts a pre-decoded list of maps

Both return `{:ok, [%AgentSpec{}]}` or `{:error, reason}`. Invalid entries are
skipped with a warning.

### Usage

```elixir
{:ok, specs} = TeamTemplate.load("config/team.json")

tools_by_type = %{
  "builder" => [read_tool, write_tool, bash_tool],
  "tester"  => [read_tool, bash_tool]
}

team_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

Enum.each(specs, fn spec ->
  tools = Map.get(tools_by_type, spec.type, [])
  DynamicSupervisor.start_child(
    Planck.Agent.AgentSupervisor,
    {Planck.Agent.Agent, AgentSpec.to_start_opts(spec, tools: tools, team_id: team_id)}
  )
end)
```

### Model availability

The orchestrator receives `available_models` at start time — a pre-filtered list
of `%Planck.AI.Model{}` structs the caller has verified are usable (API key
present, local server reachable, etc.).

```elixir
available =
  (AI.list_models(:anthropic) ++ AI.list_models(:ollama))
  |> Enum.filter(&api_key_present?/1)

DynamicSupervisor.start_child(
  Planck.Agent.AgentSupervisor,
  {Planck.Agent.Agent,
    id:               "orch-1",
    model:            orchestrator_model,
    available_models: available,
    tools:            orchestrator_tools}
)
```

## Pub/Sub events

All events are broadcast as `{:agent_event, type, payload}` to subscribers
registered via `subscribe/2`. The Registry uses `:duplicate` keys so multiple
subscribers (TUI, session store, tests) can all receive the same events.

| Event type | Payload | When |
|---|---|---|
| `:turn_start` | `%{index: non_neg_integer()}` | New LLM turn begins |
| `:text_delta` | `%{text: String.t()}` | Streaming text chunk arrives |
| `:thinking_delta` | `%{text: String.t()}` | Streaming thinking chunk arrives |
| `:tool_start` | `%{id: String.t(), name: String.t(), args: map()}` | Tool execution begins |
| `:tool_end` | `%{id: String.t(), name: String.t(), result: term(), error: boolean()}` | Tool finished |
| `:agent_spawned` | `%{id: String.t(), name: String.t(), type: String.t()}` | Worker spawned by orchestrator |
| `:agent_destroyed` | `%{id: String.t(), name: String.t(), type: String.t()}` | Worker destroyed |
| `:turn_end` | `%{message: Planck.Agent.Message.t()}` | LLM turn complete, no pending tools |
| `:error` | `%{reason: term()}` | Stream or tool error; agent returns to `:idle` |

### Subscribing to an entire team

```elixir
Agent.subscribe(orchestrator_pid)

receive do
  {:agent_event, :agent_spawned, %{id: worker_id}} ->
    {:ok, worker_pid} = Agent.whereis(worker_id)
    Agent.subscribe(worker_pid)
end
```

## Testing strategy

### Unit tests (no HTTP, no inter-agent)

- `Tool.new/1`: struct construction, missing required fields
- `Message` filtering: `{:custom, _}` roles are dropped before context is built
- `TeamTemplate.load/1` and `from_list/1`: valid entries, missing required fields,
  file path resolution for `system_prompt`, invalid JSON
- `AgentSpec.to_start_opts/2`: correct merging of tools and `team_id`
- State machine transitions: assert status changes on each
  `handle_cast`/`handle_info`/`handle_continue` in isolation
- `on_compact` hook: verify it is called before building context, verify its output
  is what gets sent to the LLM

### Integration tests (Mox)

`Planck.Agent.AiBehaviour` wraps `Planck.AI.stream/3`. `MockAI` is injected via
application config. Mocks emit canned event sequences; tests assert the resulting
broadcast sequence and final `get_state/1` output.

Mocks defined in `test/test_helper.exs`:

```elixir
Mox.defmock(Planck.Agent.MockAI, for: Planck.Agent.AiBehaviour)
```

Test cases:

- **Text-only response**: mock emits `{:text_delta, _}` + `{:done, _}` → assert
  `:turn_end` broadcast with assembled message, status back to `:idle`
- **Tool call round-trip**: `{:tool_call_complete, _}` → tool executed → result
  appended → second LLM turn → `:turn_end`
- **Parallel tool calls**: two tool calls in one turn → both executed concurrently
  via `Task.async_stream`
- **Abort mid-stream**: `abort/1` during `:streaming` → stream task terminated,
  status returns to `:idle`, no `:turn_end` broadcast
- **Error path**: mock emits `{:error, _}` → `:error` event broadcast, agent
  returns to `:idle`
- **`on_compact` hook**: verify messages passed to hook, verify hook output is sent
  to the LLM, not the full message list

### Multi-agent tests

Use multiple real `GenServer` instances (no mocks needed for the inter-agent layer
— only `MockAI` for the LLM calls).

Test cases:

- **`ask_agent`**: agent A asks agent B → B's mock emits a response → A's tool
  returns the response text → A continues its turn
- **`delegate_task` + `send_response`**: orchestrator delegates to worker → worker
  mock finishes → `send_response` re-triggers orchestrator from `:idle`
- **Team teardown**: orchestrator exits → all workers with same `team_id` are
  terminated → Registry entries cleaned up
- **`destroy_agent`**: orchestrator destroys a worker mid-turn → worker aborted →
  Registry entry removed
- **`not_found` errors**: `delegate_task` targeting a type not in the team →
  `{:error, :not_found}` returned immediately
