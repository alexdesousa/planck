# Planck.Agent

`planck_agent` is an OTP-based agent runtime for Elixir built on top of
[`planck_ai`](https://hex.pm/packages/planck_ai). It drives the full LLM loop —
stream a response, collect tool calls, execute them concurrently, append results,
re-stream — inside a supervised `GenServer` per agent, with Phoenix.PubSub
broadcasting at every step.

## Installation

```elixir
# mix.exs
{:planck_agent, "~> 0.1"}
```

Set the sessions directory (optional, defaults to `.planck/sessions`):

```bash
export PLANCK_AGENT_SESSIONS_DIR=/var/data/planck/sessions
```

## Quick start

```elixir
alias Planck.AI
alias Planck.Agent
alias Planck.Agent.Tool

# 1. Get a model from planck_ai
{:ok, model} = AI.get_model(:anthropic, "claude-sonnet-4-6")

# 2. Define a tool
read_file =
  Tool.new(
    name: "read_file",
    description: "Read a file from disk",
    parameters: %{
      "type" => "object",
      "properties" => %{"path" => %{"type" => "string"}},
      "required" => ["path"]
    },
    execute_fn: fn _id, %{"path" => path} ->
      case File.read(path) do
        {:ok, content} -> {:ok, content}
        {:error, reason} -> {:error, "could not read #{path}: #{reason}"}
      end
    end
  )

# 3. Start an agent
{:ok, agent} =
  DynamicSupervisor.start_child(
    Planck.Agent.AgentSupervisor,
    {Agent,
     id: "agent-1",
     model: model,
     system_prompt: "You are a helpful coding assistant.",
     tools: [read_file]}
  )

# 4. Subscribe and prompt
Agent.subscribe(agent)
Agent.prompt(agent, "What does lib/app.ex do?")

# 5. Receive events
receive do
  {:agent_event, :turn_end, %{message: msg, usage: usage}} ->
    IO.inspect(msg.content)
    IO.inspect(usage)
end
```

## Pub/Sub events

Subscribe to `{:agent_event, type, payload}` messages via `Agent.subscribe/1`.
Events are broadcast on two topics: `"agent:#{id}"` and, when a `session_id` is
set, `"session:#{session_id}"`.

| Event | Payload keys | When |
|---|---|---|
| `:turn_start` | `index` | New LLM turn begins |
| `:turn_end` | `message`, `usage` | Turn complete, no pending tools |
| `:text_delta` | `text` | Streaming text chunk |
| `:thinking_delta` | `text` | Streaming thinking chunk |
| `:usage_delta` | `delta`, `total` | Token usage from each LLM response |
| `:tool_start` | `id`, `name`, `args` | Tool execution begins |
| `:tool_end` | `id`, `name`, `result`, `error` | Tool finished |
| `:rewind` | `message_count` | History rewound |
| `:worker_exit` | `pid`, `reason` | Worker process exited (orchestrator only) |
| `:error` | `reason` | Stream error; agent returns to `:idle` |

```elixir
Agent.subscribe("agent-1")

receive do
  {:agent_event, :text_delta, %{text: chunk}} -> IO.write(chunk)
  {:agent_event, :tool_start, %{name: name}} -> IO.puts("→ #{name}")
  {:agent_event, :turn_end, %{usage: u}} -> IO.inspect(u)
end
```

Subscribe to the session topic to receive events from all agents in a session:

```elixir
Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "session:#{session_id}")
```

## Agent lifecycle

```
             prompt/2
idle ──────────────────► streaming ──► stream events
 ▲                             │       (text, thinking, tool calls)
 │                             ▼
 │                       stream done
 │                      /           \
 │             no tools              tool calls pending
 │                │                         │
 │◄──── turn_end ─┘                         ▼
 │                                   executing_tools
 │                                   (Task.async_stream)
 │                                         │
 │◄─── append tool_result ────────────────┘
       re-stream (loop)
```

`abort/1` cancels in-flight streaming from any state and returns the agent to
`:idle`. `stop/1` shuts it down cleanly.

## Roles

An agent's role is determined solely by its tool list at start time:

- **Orchestrator** — has a tool named `"spawn_agent"`. Owns a `team_id`; the
  entire team is terminated when the orchestrator exits.
- **Worker** — no `"spawn_agent"` tool. Receives tasks, executes them, reports
  back.

## Teams

Agents with the same `team_id` form a team. The orchestrator owns the team;
all workers are process-linked to it and exit when it does.

### Built-in inter-agent tools

These tools are wired up by the caller — see `Planck.Agent.OrchestratorTools`
and `Planck.Agent.WorkerTools` for the `Tool` structs to include.

**Available to all agents:**

| Tool | Behaviour |
|---|---|
| `ask_agent` | Blocking — sends a prompt to a team member and waits for `:turn_end` |
| `delegate_task` | Non-blocking — sends a task and returns immediately |
| `send_response` | Non-blocking — routes a result back to the delegator |
| `list_team` | Returns all agents in the team with type, name, status, and turn index |

**Orchestrator only:**

| Tool | Behaviour |
|---|---|
| `spawn_agent` | Spawns a new worker under the same `team_id` and `session_id` |
| `destroy_agent` | Terminates a worker permanently |
| `interrupt_agent` | Aborts a worker's current turn; worker stays alive |
| `list_models` | Returns the `available_models` list passed at start time |

### Built-in file and shell tools

`Planck.Agent.BuiltinTools` provides four ready-made `Tool` structs that cover
file-system access and shell execution:

```elixir
tools = [
  Planck.Agent.BuiltinTools.read(),
  Planck.Agent.BuiltinTools.write(),
  Planck.Agent.BuiltinTools.edit(),
  Planck.Agent.BuiltinTools.bash()
]
```

| Tool | Description |
|---|---|
| `read` | Read a file. Accepts optional `offset` (lines to skip) and `limit` (max lines). |
| `write` | Write content to a file, creating missing parent directories. |
| `edit` | Replace an exact unique string in a file. Errors if not found or ambiguous. |
| `bash` | Run a shell command. Optional `cwd` and `timeout` (ms) as runtime JSON args. |

`bash` captures both stdout and stderr; stderr is appended under a `STDERR:` header when non-empty. Shell execution is managed by `erlexec`, which cleans up process groups on timeout or termination.

### Granting tools to spawned workers

When building the orchestrator's tools, pass a `grantable_tools` list to
`Planck.Agent.Tools.orchestrator_tools/5`. The orchestrator can then grant any
subset of those tools to workers it spawns by including a `"tools"` key in the
`spawn_agent` call:

```json
{
  "type": "reviewer",
  "name": "Reviewer",
  "tools": ["read"]
}
```

Workers always receive the standard worker tools (`ask_agent`, `delegate_task`,
`send_response`, `list_team`). Granted tools are added on top. Names not in the
orchestrator's `grantable_tools` list are silently ignored — workers cannot
escalate beyond what the orchestrator was given.

### Spawning a team manually

```elixir
alias Planck.Agent.{Agent, AgentSpec, Compactor, TeamTemplate}

{:ok, model} = Planck.AI.get_model(:anthropic, "claude-sonnet-4-6")

team_id    = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
session_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
on_compact = Compactor.build(model)

orchestrator_opts = [
  id: "orch-#{team_id}",
  type: "orchestrator",
  model: model,
  system_prompt: "You coordinate a team of agents.",
  tools: orchestrator_tools,
  team_id: team_id,
  session_id: session_id,
  on_compact: on_compact,
  available_models: Planck.AI.list_models(:anthropic)
]

DynamicSupervisor.start_child(Planck.Agent.AgentSupervisor, {Agent, orchestrator_opts})
```

Workers are typically spawned by the orchestrator via `spawn_agent` at runtime,
or pre-spawned from a team template (see below).

## Session persistence

Start a session before starting any agents that should persist messages:

```elixir
alias Planck.Agent.Session

{:ok, _pid} = Session.start(session_id)
```

Agents with a matching `session_id` append every message automatically.
Messages are stored in a SQLite file at `sessions_dir/#{session_id}.db`.

### Retrieving messages

```elixir
# All messages in insertion order
{:ok, rows} = Session.messages(session_id)
{:ok, rows} = Session.messages(session_id, agent_id: "agent-1")

# Each row: %{agent_id: String.t(), message: Message.t(), inserted_at: integer()}
```

### Checkpoint-based pagination

Summary messages (role `{:custom, :summary}`) are stored as checkpoints,
enabling efficient "load recent / load more" pagination for long sessions:

```elixir
# Initial load — latest summary checkpoint + all messages after it
{:ok, rows, checkpoint_id} = Session.messages_from_latest_checkpoint(session_id)

# Load more — previous chapter
{:ok, rows, prev_id} = Session.messages_before_checkpoint(session_id, checkpoint_id)
# prev_id == nil → no more history to load
```

Pass `agent_id:` to either function to filter to a specific agent.

## Context compaction

`Planck.Agent.Compactor.build/2` returns an `on_compact` hook. When the
estimated token count of the message history exceeds the threshold, it calls
the LLM to produce a summary that preserves the active goal and recent context.

```elixir
on_compact = Compactor.build(model,
  ratio: 0.8,        # compact when history reaches 80% of context_window
  keep_recent: 10    # keep the last 10 messages verbatim
)
```

When compaction triggers, the summary is inserted as a `{:custom, :summary}`
message in the agent's history and persisted to the session. Future LLM calls
are built from the latest summary onward — the full history remains in the
session for audit and UI pagination.

Bring your own compaction strategy by implementing the `Planck.Agent.Compactor`
behaviour in a module and loading it from a `.exs` file:

```elixir
# my_compactor.exs
defmodule MyApp.Compactor do
  @behaviour Planck.Agent.Compactor

  @impl true
  def compact(messages) do
    case summarise(messages) do
      {:ok, text} ->
        summary_msg = Planck.Agent.Message.new({:custom, :summary}, [{:text, text}])
        kept = Enum.take(messages, -5)
        {:compact, summary_msg, kept}

      :error ->
        :skip
    end
  end

  defp summarise(messages), do: ...
end
```

```elixir
{:ok, on_compact} = Planck.Agent.Compactor.load("my_compactor.exs")
```

Or pass any `function/1` directly for inline use:

```elixir
on_compact = fn messages ->
  summary_msg = Planck.Agent.Message.new({:custom, :summary}, [{:text, "..."}])
  {:compact, summary_msg, Enum.take(messages, -5)}
end
```

The hook receives the messages since the last summary checkpoint and must
return either `{:compact, summary_msg, kept_messages}` or `:skip`.

## Team templates

Define a team in JSON and load it at runtime:

```json
[
  {
    "type":          "planner",
    "name":          "Planner",
    "description":   "Breaks tasks into steps",
    "provider":      "anthropic",
    "model_id":      "claude-sonnet-4-6",
    "system_prompt": "You are an expert planner.",
    "opts": { "temperature": 0.5 }
  },
  {
    "type":          "coder",
    "name":          "Coder",
    "description":   "Writes and edits code",
    "provider":      "ollama",
    "model_id":      "llama3.2",
    "system_prompt": "prompts/coder.md"
  }
]
```

`system_prompt` accepts an inline string or a `.md`/`.txt` path resolved
relative to the template file. Valid providers are `"anthropic"`, `"openai"`,
`"google"`, `"ollama"`, `"llama_cpp"`.

The optional `"tools"` array lists tool names the agent should receive. Names are
resolved at start time from the `tool_pool:` keyword passed to `AgentSpec.to_start_opts/2`:

```json
{ "type": "coder", "tools": ["read", "write", "bash"], ... }
```

```elixir
pool = Planck.Agent.BuiltinTools.all() ++ Planck.Agent.ExternalTool.load_all(dirs)

start_opts = AgentSpec.to_start_opts(spec,
  tool_pool:  pool,
  team_id:    team_id,
  session_id: session_id
)
```

Unknown names are silently ignored. When `spec.tools` is empty, `to_start_opts/2`
falls back to the `tools:` keyword — the behaviour before this feature was added.

```elixir
alias Planck.Agent.{Agent, AgentSpec, Compactor, TeamTemplate}

{:ok, specs} = TeamTemplate.load("config/team.json")

tools_by_type = %{
  "planner" => [list_team_tool, delegate_task_tool, spawn_agent_tool],
  "coder"   => [read_file_tool, write_file_tool, bash_tool, send_response_tool]
}

team_id    = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
session_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

Enum.each(specs, fn spec ->
  {:ok, model} = Planck.AI.get_model(spec.provider, spec.model_id)
  tools = Map.get(tools_by_type, spec.type, [])

  start_opts =
    AgentSpec.to_start_opts(spec,
      tools: tools,
      team_id: team_id,
      session_id: session_id,
      on_compact: Compactor.build(model)
    )

  DynamicSupervisor.start_child(Planck.Agent.AgentSupervisor, {Agent, start_opts})
end)
```

## Skills

Skills are reusable agent capabilities stored on the filesystem. Each skill is a
directory containing a `SKILL.md` with YAML-style frontmatter:

```
.planck/skills/
  code_review/
    SKILL.md
    resources/
      rubric.md
```

```markdown
---
name: code_review
description: Reviews code for correctness, style, and performance.
---

Review the provided code...
```

Load skills and inject them into an agent's system prompt:

```elixir
alias Planck.Agent.Skill

dirs   = Planck.Agent.Config.skills_dirs!()
skills = Skill.load_all(dirs)

system_prompt =
  [base_prompt, Skill.system_prompt_section(skills)]
  |> Enum.reject(&is_nil/1)
  |> Enum.join("\n\n")
```

`system_prompt_section/1` returns `nil` when there are no skills, so it composes
cleanly. Each skill entry includes the path to its `SKILL.md` file and its
`resources` directory.

## Dynamic tool management

Add and remove tools without restarting the agent:

```elixir
Agent.add_tool(agent, new_tool)
Agent.remove_tool(agent, "tool_name")
```

## Rewinding history

Remove the last `n` user turns from the agent's in-memory history. Ignored
while the agent is streaming. Syncs the session store when a `session_id` is
set.

```elixir
Agent.rewind(agent)       # remove last turn
Agent.rewind(agent, 3)    # remove last 3 turns
```

Subscribers receive `{:agent_event, :rewind, %{message_count: n}}`.

## Configuration

| Env var | Config key | Default | Description |
|---|---|---|---|
| `PLANCK_AGENT_SESSIONS_DIR` | `:sessions_dir` | `.planck/sessions` | Directory for SQLite session files |
| `PLANCK_AGENT_SKILLS_DIRS` | `:skills_dirs` | `.planck/skills:~/.planck/skills` | Colon-separated list of skill directories |
| `PLANCK_AGENT_TOOLS_DIRS` | `:tools_dirs` | `.planck/tools:~/.planck/tools` | Colon-separated list of external tool directories |
| `PLANCK_AGENT_COMPACTOR` | `:compactor` | `nil` | Path to a `.exs` file returning a custom `on_compact` function/1 |

```elixir
# config/runtime.exs
config :planck_agent, :sessions_dir, "/var/data/planck/sessions"
config :planck_agent, :skills_dirs, ["/app/skills", "~/.planck/skills"]
config :planck_agent, :tools_dirs, ["/app/tools", "~/.planck/tools"]
config :planck_agent, :compactor, "/app/config/compactor.exs"
```

## Supervision tree

```
Planck.Agent.Supervisor  (strategy: :one_for_all)
├── Phoenix.PubSub        (name: Planck.Agent.PubSub)
├── Registry              (keys: :duplicate, name: Planck.Agent.Registry)
├── Task.Supervisor       (name: Planck.Agent.TaskSupervisor)
├── DynamicSupervisor     (name: Planck.Agent.SessionSupervisor)
│   └── Planck.Agent.Session  (restart: :temporary)
└── DynamicSupervisor     (name: Planck.Agent.AgentSupervisor)
    ├── Planck.Agent (role: :orchestrator)
    └── Planck.Agent (role: :worker)
```

`:one_for_all` on the top-level supervisor ensures the Registry and PubSub
always restart together — a stale Registry after a crash would leave agents
unable to find each other.
