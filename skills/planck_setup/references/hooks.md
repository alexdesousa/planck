# Planck Hooks

Hooks are sidecar behaviours that extend per-agent behaviour at well-defined
points in the agent loop. Each hook is declared in `TEAM.json` as a
fully-qualified module name; planck_headless resolves it to a module atom at
session start and dispatches to the sidecar node via RPC.

There are three hook behaviours:

| Behaviour | TEAM.json field | Fires |
|---|---|---|
| `Planck.Agent.Hooks.Compactor` | `compactor` | Before every LLM turn — compact the message history when the context window is full |
| `Planck.Agent.Hooks.Prompt` | `prompt_hook` | Before every LLM turn — inject dynamic content into the system prompt |
| `Planck.Agent.Hooks.TurnEnd` | `turn_end_hook` | After every LLM turn ends — inspect the turn and act |

All three follow the same pattern:

1. Implement the behaviour in your sidecar with `use Planck.Agent.Hooks.<Name>`.
2. Declare the module name in `TEAM.json`.
3. planck_headless resolves the string to an atom and passes it to the agent at
   start time; no builder function or closure is involved.

When the sidecar node is unavailable, each hook fails gracefully — the
compactor falls back to the built-in LLM-based strategy; the prompt and
turn-end hooks return `nil` / `:ok` without raising.

---

## Compactor — `Planck.Agent.Hooks.Compactor`

Compacts the agent's message history when the context window approaches
capacity. Called before every LLM turn.

### Callbacks

```elixir
@callback compact(model :: Planck.AI.Model.t(), messages :: [Planck.Agent.Message.t()]) ::
            {:compact, summary :: Planck.Agent.Message.t(), kept :: [Planck.Agent.Message.t()]}
            | :skip

@callback compact_timeout() :: pos_integer()   # default: 120_000 ms
```

Return `{:compact, summary_msg, kept}` to replace older messages with a
summary checkpoint, or `:skip` to leave the history unchanged.

When `compactor` is not declared, Planck uses a built-in LLM-based strategy
that triggers at 80% of `model.context_window` and keeps the 10 most recent
messages verbatim.

### Example

```elixir
defmodule MySidecar.Compactors.Summary do
  use Planck.Agent.Hooks.Compactor

  @impl true
  def compact(_model, messages) do
    text    = summarise(messages)
    summary = Planck.Agent.Message.new({:custom, :summary}, [{:text, text}])
    kept    = Enum.take(messages, -5)
    {:compact, summary, kept}
  end

  @impl true
  def compact_timeout, do: 60_000
end
```

### TEAM.json

```json
{
  "type":      "builder",
  "compactor": "MySidecar.Compactors.Summary"
}
```

---

## Prompt hook — `Planck.Agent.Hooks.Prompt`

Injects dynamic content into the system prompt before every LLM turn. Useful
for per-session memory, project state, or any context that changes between
turns.

### Callbacks

```elixir
@callback before_prompt(session_id :: String.t() | nil) :: String.t() | nil
@callback after_prompt(session_id :: String.t() | nil)  :: String.t() | nil
@callback hook_timeout() :: pos_integer()   # default: 5_000 ms
```

`before_prompt/1` returns text prepended before the base system prompt.
`after_prompt/1` returns text appended after all other sections. Either can
return `nil` for no injection. Both receive the `session_id` so a single
module instance can serve all sessions.

### ETS-backed design

An ETS table keyed by `session_id` gives non-blocking reads on every turn. The
GenServer refreshes the cache lazily on `:turn_end` (first access) and eagerly
on `:compacted` events — the cheapest point to reconsolidate memory since
compaction already busts the LLM prefix cache.

The planck_docker bundled sidecar ships `Sidecar.Memory` as a concrete,
production-ready implementation of this pattern. It stores condensed agent
memory in a `short_term_memory` Typesense collection keyed by
`"team_name:agent_name"` (one record per agent, replaced on each write) and
injects it via `before_prompt/1`.

```elixir
defmodule Sidecar.Memory do
  use GenServer
  use Planck.Agent.Hooks.Prompt

  @table :sidecar_memory

  def start_link(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "planck:sessions")
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  # Called by Planck before every LLM turn — fast ETS read, no blocking.
  @impl Planck.Agent.Hooks.Prompt
  def before_prompt(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, content}] -> content
      [] -> nil
    end
  end

  # Lazy load on first turn_end for this session.
  def handle_info({:agent_event, :turn_end,
                   %{session_id: sid, agent_name: name, team_name: team}}, state) do
    if :ets.lookup(@table, sid) == [] do
      memory = Sidecar.Memory.current("#{team}:#{name}")
      :ets.insert(@table, {sid, memory})
    end
    {:noreply, state}
  end

  # Refresh ETS after compaction — cheapest point to reconsolidate.
  def handle_info({:agent_event, :compacted,
                   %{session_id: sid, agent_name: name, team_name: team}}, state) do
    memory = Sidecar.Memory.current("#{team}:#{name}")
    :ets.insert(@table, {sid, memory})
    {:noreply, state}
  end

  def handle_info(_event, state), do: {:noreply, state}
end
```

Agents write new facts with the `update_memory` sidecar tool, which calls
`Sidecar.Memory.write/3`. The tool enforces a 2 200-char limit and guides the
agent to summarise when the limit is exceeded.

### TEAM.json

```json
{
  "type":        "builder",
  "prompt_hook": "Sidecar.Memory"
}
```

---

## Turn-end hook — `Planck.Agent.Hooks.TurnEnd`

Called after every LLM turn in a background task (non-blocking). The primary
use case is skill reflection: after a complex turn with many tool calls, decide
whether the workflow is worth capturing as a reusable skill.

### Callbacks

```elixir
@callback reflect(
            agent_id    :: String.t(),
            turn_messages :: [Planck.Agent.Message.t()]
          ) :: :ok

@callback reflect_threshold() :: non_neg_integer()   # default: 5
@callback reflect_timeout()   :: pos_integer()        # default: 30_000 ms
```

`reflect/2` is only called when the tool call count derived from
`turn_messages` meets or exceeds `reflect_threshold/0`. On all other turns the
hook is a single integer comparison — effectively free.

The tool call count can be derived when needed:

```elixir
tool_call_count =
  turn_messages
  |> Enum.flat_map(& &1.content)
  |> Enum.count(&match?({:tool_call, _, _, _}, &1))
```

### Signalling back to the agent

When the hook writes a skill or takes a notable action, call
`Planck.Agent.inject_tool_result/3` to append a synthetic tool use + result
pair to the parent agent's history. The tool name (`"skill_reflector"` in the
example below) does **not** need to be in the agent's callable tool list — it
appears as a read-only history entry the LLM sees passively on the next turn.

### Example — SkillReflector

```elixir
defmodule MySidecar.Hooks.SkillReflector do
  use Planck.Agent.Hooks.TurnEnd

  @impl true
  def reflect_threshold, do: 5

  @impl true
  def reflect(agent_id, turn_messages) do
    case analyse(turn_messages) do
      :skip ->
        :ok

      {:write, name, description, content} ->
        write_skill(name, description, content)

        Planck.Agent.inject_tool_result(
          agent_id,
          "skill_reflector",
          "Skill '#{name}' written: #{description}"
        )

        :ok
    end
  end

  defp analyse(_turn_messages), do: :skip
  defp write_skill(_name, _description, _content), do: :ok
end
```

### TEAM.json

```json
{
  "type":           "builder",
  "turn_end_hook":  "MySidecar.Hooks.SkillReflector"
}
```

---

## Combining hooks

All three hooks are independent and can be declared together:

```json
{
  "type":          "builder",
  "compactor":     "MySidecar.Compactors.Summary",
  "prompt_hook":   "MySidecar.Hooks.Memory",
  "turn_end_hook": "MySidecar.Hooks.SkillReflector"
}
```

Each is resolved and dispatched independently. They share the same
`sidecar_node` stored in agent state.

## RPC and timeouts

All hooks are dispatched via `:rpc.call/5` when the sidecar node is set.
Override the timeout callback (`compact_timeout/0`, `hook_timeout/0`,
`reflect_timeout/0`) when your implementation needs more time than the default.
The module is consulted for its own timeout — it knows its latency better than
any caller default.

On `:badrpc` the compactor falls back to the local LLM strategy; the prompt
hook returns `nil` (no injection); the turn-end hook logs a warning and returns
`:ok`. No hook raises or crashes the agent.
