# checkpoint_agent Tool

## Overview

`checkpoint_agent` is an orchestrator-only inter-agent tool that inserts a
`{:custom, :summary}` message into a target agent's conversation at the
current position. From that point on, the target agent's `do_run_llm` only
sends messages after the checkpoint to the LLM — the previous history is
preserved in the session DB and visible to the user, but invisible to the
model.

This gives the orchestrator explicit control over a worker's context window:
it can compact a worker's context mid-task and hand it a curated summary of
prior work rather than waiting for the automatic compaction threshold.

## Tool schema

```json
{
  "name": "checkpoint_agent",
  "description": "Insert a context checkpoint into a worker's conversation. Messages before the checkpoint are archived — the worker's next LLM call will only see the checkpoint summary and any messages after it.",
  "parameters": {
    "type": "object",
    "properties": {
      "identifier":      { "type": "string", "description": "Value that identifies the target agent" },
      "identifier_type": { "type": "string", "enum": ["type", "name", "id"], "description": "How to resolve the identifier" },
      "summary":         { "type": "string", "description": "Summary text to insert as the checkpoint. Should describe completed work and current state so the agent can continue without needing prior history." }
    },
    "required": ["identifier", "identifier_type", "summary"]
  }
}
```

## Behaviour

1. Resolve the target agent via `identifier`/`identifier_type` (same as
   `ask_agent`/`delegate_task`).
2. The tool is self-targeting safe — targeting the calling agent returns an
   error.
3. Call `Agent.checkpoint(pid, summary_text)`:
   - Builds a `Message.new({:custom, :summary}, [{:text, summary_text}])`
   - Persists it to the session via `Session.append`
   - Appends it to `state.messages`
4. The target agent's next `do_run_llm` will call
   `messages_since_last_summary` which returns only `[checkpoint | later_messages]`.
5. Returns `{:ok, "Checkpoint inserted."}` on success.

## Agent.checkpoint/2

New public API:

```elixir
@spec checkpoint(agent(), String.t()) :: :ok | {:error, term()}
def checkpoint(agent, summary_text) do
  GenServer.call(agent, {:checkpoint, summary_text})
end
```

`handle_call({:checkpoint, summary_text}, ...)`:
- Builds and persists the summary message
- Appends to `state.messages`
- Returns `:ok`

Works regardless of the agent's current status (idle, streaming, or
executing tools) — the checkpoint is appended to the message list and takes
effect on the next `do_run_llm` call.

## Placement

`checkpoint_agent` is added to `orchestrator_tools/6` alongside
`spawn_agent`, `destroy_agent`, and `interrupt_agent`. Workers do not
receive it.

## Notes

- The summary is written by the orchestrator, not auto-generated. This is
  intentional — the orchestrator has the full picture of what the worker has
  done and can produce a more accurate summary than the worker itself.
- An empty summary is allowed — it creates a hard cut with no context, which
  may cause the worker to behave as if the conversation just started.
- Unlike automatic compaction, `checkpoint_agent` does not trim `state.messages`
  permanently — it inserts a new message. The prefix before the checkpoint
  remains in memory and in the DB. `messages_since_last_summary` handles
  the filtering at LLM call time.

## Package ownership

- `Planck.Agent` — `Agent.checkpoint/2` and the `handle_call` implementation
- `Planck.Agent.Tools` — `checkpoint_agent/1` tool factory, added to `orchestrator_tools`
