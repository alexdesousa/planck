# Creating a New Planck Team

This guide walks through scaffolding a new team from scratch. A team is a
directory containing a `TEAM.json` and optional prompt files.

## 1. Choose available models

Use the `list_models` tool to see which models are configured and available.
Note the `provider`, `id`, and `base_url` for each model you plan to use.

## 2. Scaffold the directory

```sh
mkdir -p .planck/teams/my-team/prompts
```

## 3. Write TEAM.json

Exactly one member must have `"type": "orchestrator"`. All others are workers.

```json
{
  "name": "my-team",
  "members": [
    {
      "type":          "orchestrator",
      "provider":      "anthropic",
      "model_id":      "claude-sonnet-4-6",
      "system_prompt": "prompts/orchestrator.md",
      "tools":         ["read", "bash"]
    },
    {
      "type":          "builder",
      "name":          "Builder",
      "description":   "Implements tasks assigned by the orchestrator",
      "provider":      "anthropic",
      "model_id":      "claude-sonnet-4-5",
      "system_prompt": "prompts/builder.md",
      "tools":         ["read", "write", "edit", "bash"]
    }
  ]
}
```

Key fields:

| Field | Required | Notes |
|---|---|---|
| `type` | ✅ | `"orchestrator"` or any worker role name |
| `provider` | ✅ | `anthropic`, `openai`, `google`, `ollama`, `llama_cpp` |
| `model_id` | ✅ | From `list_models` tool |
| `system_prompt` | | Inline string or path to `.md` file (relative to team dir) |
| `tools` | | `["read", "write", "edit", "bash"]` + any sidecar tools |
| `name` | | Display name — defaults to `type` |
| `description` | | Shown to the orchestrator via `list_team` |
| `base_url` | | Required for local/multi-server setups |
| `skills` | | Skill names to inject into the system prompt |

## 4. Write system prompt files

Use the `write` tool to create the prompt files:

```
.planck/teams/my-team/prompts/orchestrator.md
.planck/teams/my-team/prompts/builder.md
```

Orchestrator prompt tips:
- Describe its role: coordinate tasks, delegate to workers, aggregate results
- List available workers and when to use each
- Set expectations for how to report back to the user

Worker prompt tips:
- Be specific about the task domain
- List any conventions to follow (coding style, test requirements)
- Instruct it to use `send_response` when the task is complete

## 5. Register and start the team

Place the team directory under one of the configured `teams_dirs`
(default: `.planck/teams/` or `~/.planck/teams/`). Use `spawn_agent` or
ask the user to restart Planck to pick it up. On next startup, the team
will be available by its alias.

To start a session with the new team, ask the user to select it from the
new session dialog in the Web UI, or tell them the alias so they can start
it with `{"template": "my-team"}` via the HTTP API.

## 6. Saving a dynamic team

If you built a team dynamically during a session (via `spawn_agent`) and the
user wants to reuse it, write a `TEAM.json` from the same agent types, models,
and system prompts you used. The format is identical to the one above.

---

For the full agent spec reference, see:
https://raw.githubusercontent.com/alexdesousa/planck/main/docs/guides/teams.md

For skill assignment, see:
https://raw.githubusercontent.com/alexdesousa/planck/main/docs/guides/skills.md
