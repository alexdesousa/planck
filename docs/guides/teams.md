# Planck Teams

A team is a directory containing a `TEAM.json` file that declares the agents,
their roles, models, and prompts. Teams live in `.planck/teams/<alias>/`.

## TEAM.json structure

```json
{
  "name":    "my-team",
  "members": [ <agent specs> ]
}
```

Exactly one member must have `"type": "orchestrator"`. All others are workers.

## Agent spec fields

| Field | Required | Description |
|---|---|---|
| `type` | ✅ | Role string — `"orchestrator"` or any worker type (e.g. `"planner"`, `"builder"`) |
| `name` | | Display name; defaults to `type` if omitted; must be unique within the team |
| `description` | | One-line description shown to the orchestrator in `list_team` |
| `provider` | ✅ | LLM provider: `anthropic`, `openai`, `google`, `ollama`, `llama_cpp` |
| `model_id` | ✅ | Model identifier (e.g. `"claude-sonnet-4-6"`, `"llama3.2"`) |
| `system_prompt` | | Inline string or path to a `.md` file (relative to the team directory) |
| `tools` | | List of tool names available to this agent (e.g. `["read", "write", "bash"]`) |
| `skills` | | List of skill names to inject into the system prompt |
| `compactor` | | Fully-qualified sidecar compactor module name (e.g. `"MySidecar.Compactors.Summary"`) |
| `opts` | | Provider-specific opts, e.g. `{"temperature": 0.7}` |

## Built-in tools

| Name | Description |
|---|---|
| `read` | Read a file (with optional offset/limit) |
| `write` | Write a file |
| `edit` | Replace an exact string in a file |
| `bash` | Run a shell command |

Sidecar tools are added automatically when a sidecar is connected.

## Example — multi-agent team

```json
{
  "name": "build-team",
  "members": [
    {
      "type":          "orchestrator",
      "provider":      "anthropic",
      "model_id":      "claude-sonnet-4-6",
      "system_prompt": "prompts/orchestrator.md",
      "tools":         ["read", "bash"]
    },
    {
      "type":          "planner",
      "name":          "Planner",
      "description":   "Breaks a phase into concrete tasks for the builder",
      "provider":      "anthropic",
      "model_id":      "claude-sonnet-4-6",
      "system_prompt": "prompts/planner.md",
      "tools":         ["read"]
    },
    {
      "type":          "builder",
      "name":          "Builder",
      "description":   "Implements tasks produced by the planner",
      "provider":      "anthropic",
      "model_id":      "claude-sonnet-4-5",
      "system_prompt": "prompts/builder.md",
      "tools":         ["read", "write", "edit", "bash"]
    },
    {
      "type":          "reviewer",
      "name":          "Reviewer",
      "description":   "Reviews builder output against planner tasks and phase objective",
      "provider":      "openai",
      "model_id":      "gpt-4o",
      "system_prompt": "prompts/reviewer.md",
      "tools":         ["read", "bash"]
    },
    {
      "type":          "documenter",
      "name":          "Documenter",
      "description":   "Documents completed phase work",
      "provider":      "anthropic",
      "model_id":      "claude-haiku-4-5-20251001",
      "system_prompt": "prompts/documenter.md",
      "tools":         ["read", "write"]
    }
  ]
}
```

## File layout

```
.planck/teams/build-team/
  TEAM.json
  prompts/
    orchestrator.md
    planner.md
    builder.md
    reviewer.md
    documenter.md
```

## Using the team

```sh
# Start a session with this team
planck --team build-team

# Or set it as default in .planck/config.json
{ "default_team": "build-team" }
```

## How the orchestrator delegates

The orchestrator can use these inter-agent tools at runtime:

| Tool | Behaviour |
|---|---|
| `spawn_agent` | Spawn a new worker of a given type |
| `ask_agent` | Send a prompt and wait for the response (blocking) |
| `delegate_task` | Send a task without waiting (non-blocking) |
| `interrupt_agent` | Abort a worker's current turn |
| `list_team` | List all agents with their type, name, and status |
