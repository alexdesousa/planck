# Planck HTTP API

The Planck Web UI exposes a REST API at `http://localhost:4000/api`. Use it to
manage sessions and send prompts from external agents, scripts, or CI pipelines.

All request and response bodies are JSON. The API requires no authentication by
default (it is local-only). An optional API key can be configured via
`PLANCK_API_KEY` — when set, every request must include
`Authorization: Bearer <key>`.

---

## Sessions

### List sessions

```sh
curl http://localhost:4000/api/sessions
```

```json
[
  {
    "id":       "a1b2c3d4",
    "name":     "liquid-kiwi",
    "status":   "active",
    "team":     "build-team",
    "created_at": "2025-05-01T12:00:00Z"
  },
  {
    "id":       "e5f6a7b8",
    "name":     "crispy-mango",
    "status":   "closed",
    "team":     null,
    "created_at": "2025-04-30T09:00:00Z"
  }
]
```

`status` is `"active"` when the session's agents are running, `"closed"` when
the session file exists on disk but agents have been stopped.

---

### Start a session

```sh
curl -X POST http://localhost:4000/api/sessions \
  -H "Content-Type: application/json" \
  -d '{"template": "build-team", "name": "my-session"}'
```

| Field | Required | Description |
|---|---|---|
| `template` | | Team alias or path. Omit for the default dynamic team. |
| `name` | | Session name. Auto-generated if omitted. |

```json
{
  "id":   "a1b2c3d4",
  "name": "my-session",
  "status": "active",
  "team": "build-team"
}
```

---

### Get session info

```sh
curl http://localhost:4000/api/sessions/a1b2c3d4
```

```json
{
  "id":     "a1b2c3d4",
  "name":   "my-session",
  "status": "active",
  "team":   "build-team",
  "agents": [
    {"id": "orch-id", "name": "orchestrator", "type": "orchestrator", "status": "idle"},
    {"id": "work-id", "name": "Builder",      "type": "builder",      "status": "idle"}
  ]
}
```

---

### Send a prompt

Sends a user message to the session's orchestrator. If the session is closed,
it is automatically resumed first.

```sh
curl -X POST http://localhost:4000/api/sessions/a1b2c3d4/prompt \
  -H "Content-Type: application/json" \
  -d '{"text": "Refactor lib/app.ex to use a GenServer"}'
```

```json
{"ok": true}
```

The response returns as soon as the prompt is queued. Stream
`GET /api/sessions/:id/events` to follow progress.

---

### Abort

Aborts the current turn for all agents in the session.

```sh
curl -X POST http://localhost:4000/api/sessions/a1b2c3d4/abort
```

```json
{"ok": true}
```

---

### Close a session

Stops all agents. The session file is retained on disk and can be resumed.

```sh
curl -X DELETE http://localhost:4000/api/sessions/a1b2c3d4
```

```json
{"ok": true}
```

---

## Event stream (SSE)

Subscribe to real-time events for a session. The connection stays open until
the client disconnects or the server closes it.

```sh
# All agents in the session
curl -N http://localhost:4000/api/sessions/a1b2c3d4/events

# Single agent only
curl -N http://localhost:4000/api/sessions/a1b2c3d4/events?agent_id=orch-id
```

When `agent_id` is provided, only events from that agent are streamed. The
`agent_id` field is present in the payload in both modes so the frame shape
is identical.

Each event is a standard SSE frame:

```
event: text_delta
data: {"agent_id":"orch-id","text":"I'll start by reading the file."}

event: tool_start
data: {"agent_id":"orch-id","id":"t1","name":"read","args":{"path":"lib/app.ex"}}

event: tool_end
data: {"agent_id":"orch-id","id":"t1","name":"read","result":"defmodule App do\n...","error":false}

event: worker_spawned
data: {"agent_id":"work-id","name":"Builder","type":"builder"}

event: turn_end
data: {"agent_id":"orch-id"}

event: usage_delta
data: {"agent_id":"orch-id","total":{"input_tokens":1200,"output_tokens":340,"cost":0.003}}
```

### Event types

| Event | Payload fields | Description |
|---|---|---|
| `turn_start` | `agent_id` | Agent began a new LLM turn |
| `turn_end` | `agent_id` | Agent finished its turn |
| `text_delta` | `agent_id`, `text` | Streaming text chunk |
| `thinking_delta` | `agent_id`, `text` | Streaming thinking/reasoning chunk |
| `tool_start` | `agent_id`, `id`, `name`, `args` | Tool call began |
| `tool_end` | `agent_id`, `id`, `name`, `result`, `error` | Tool call finished |
| `worker_spawned` | `agent_id`, `name`, `type` | New worker agent started |
| `usage_delta` | `agent_id`, `total` (`input_tokens`, `output_tokens`, `cost`) | Usage update |
| `compacting` | `agent_id` | Context compaction in progress |
| `compacted` | `agent_id` | Context compaction complete |
| `error` | `agent_id`, `reason` | Agent error |

---

## Resources

### List available teams

```sh
curl http://localhost:4000/api/teams
```

```json
[
  {"alias": "build-team",  "name": "Build Team",  "description": "Plan, build, and review changes"},
  {"alias": "elixir-dev",  "name": "Elixir Dev",  "description": null}
]
```

### Get a team

```sh
curl http://localhost:4000/api/teams/build-team
```

```json
{
  "alias": "build-team",
  "name":  "Build Team",
  "members": [
    {"type": "orchestrator", "name": "orchestrator", "model_id": "claude-sonnet-4-6"},
    {"type": "builder",      "name": "Builder",      "model_id": "claude-sonnet-4-5"}
  ]
}
```

### List available models

```sh
curl http://localhost:4000/api/models
```

```json
[
  {"provider": "anthropic", "id": "claude-sonnet-4-6", "context_window": 200000, "base_url": null},
  {"provider": "ollama",    "id": "llama3.2",          "context_window": 128000, "base_url": "http://localhost:11434"}
]
```

---

## Workflow example — prompt and wait for completion

```sh
# 1. Start a session
SESSION=$(curl -s -X POST http://localhost:4000/api/sessions \
  -H "Content-Type: application/json" \
  -d '{"template": "build-team"}' | jq -r .id)

# 2. Send a prompt
curl -s -X POST http://localhost:4000/api/sessions/$SESSION/prompt \
  -H "Content-Type: application/json" \
  -d '{"text": "Add a caching layer to the UserService"}'

# 3. Stream events until turn_end on the orchestrator
curl -sN http://localhost:4000/api/sessions/$SESSION/events | \
  while IFS= read -r line; do
    echo "$line"
    if echo "$line" | grep -q '"turn_end"'; then break; fi
  done

# 4. Close when done
curl -s -X DELETE http://localhost:4000/api/sessions/$SESSION
```

---

## Building a Planck skill for this API

To let a Planck agent manage sessions via the API, create a skill that describes
the endpoints. The agent uses its `bash` tool to call `curl`.

```
.planck/skills/planck-api/
  SKILL.md
```

```markdown
---
name: planck-api
description: Manage Planck multi-agent sessions via the local HTTP API.
---

Use bash + curl to interact with the running Planck instance at
http://localhost:4000/api. Key operations:

- List sessions:   GET  /api/sessions
- Start session:   POST /api/sessions   {"template": "<alias>", "name": "<name>"}
- Send prompt:     POST /api/sessions/:id/prompt   {"text": "..."}
- Stream events:   GET  /api/sessions/:id/events   (SSE — listen for turn_end)
- Close session:   DELETE /api/sessions/:id
- List teams:      GET  /api/teams
- List models:     GET  /api/models
```

For full team and skill configuration, see:
https://raw.githubusercontent.com/alexdesousa/planck/main/docs/guides/teams.md
https://raw.githubusercontent.com/alexdesousa/planck/main/docs/guides/skills.md
