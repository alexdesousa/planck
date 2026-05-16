# Context Reset — `reset_previous_context`

## Overview

`checkpoint_agent` was removed in v0.1.2. Context reset is now an optional
parameter on `call_agent` and `send_agent`:

```json
{ "agent_id": "abc123", "task": "Build the auth module.", "reset_previous_context": true }
```

When `reset_previous_context: true`, the target agent's prior conversation
history is archived before the new message is sent. The new message becomes
the first thing the worker sees on its next turn.

## Design rationale

The standalone `checkpoint_agent` tool required two calls (checkpoint + delegate)
for the common case of "reset context and assign a new task". Merging it into
`call_agent`/`send_agent` reduces that to one.

Workers have automatic compaction for in-task context growth. `reset_previous_context`
is for deliberate redirection across meaningfully different tasks — a different
codebase area, problem domain, or reasoning style. It also helps with MoE models:
clearing context removes the bias toward experts activated by the previous task.

## Implementation

When `reset_previous_context: true`:
1. `Agent.checkpoint(pid, "Starting new task.")` is called on the target — this
   inserts a `{:custom, :summary}` message that becomes the start of the new
   context window.
2. `Agent.prompt(pid, task_or_question)` is called normally.

The worker sees: `[checkpoint_marker, new_task]`. Prior history is preserved in
the session DB and visible in the UI, but invisible to the LLM.

## Note on `Planck.Agent.checkpoint/2`

The underlying `Planck.Agent.checkpoint/2` public API still exists and can be
called directly for advanced use cases (e.g. from sidecar code or custom tools).
