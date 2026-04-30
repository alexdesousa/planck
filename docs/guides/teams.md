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
| `description` | | One-line description shown to the orchestrator via `list_team` |
| `provider` | ✅ | LLM provider: `anthropic`, `openai`, `google`, `ollama`, `llama_cpp` |
| `model_id` | ✅ | Model identifier (e.g. `"claude-sonnet-4-6"`, `"llama3.2"`) |
| `base_url` | | Base URL for local/custom model servers (e.g. `"http://localhost:11434"`). Required when multiple servers of the same provider type are configured. |
| `system_prompt` | | Inline string or path to a `.md` file (relative to the team directory) |
| `tools` | | List of tool names available to this agent (e.g. `["read", "write", "bash"]`) |
| `skills` | | List of skill names whose content is appended to the system prompt at session start |
| `compactor` | | Fully-qualified sidecar compactor module name (e.g. `"MySidecar.Compactors.Summary"`) |
| `opts` | | Provider-specific opts, e.g. `{"temperature": 0.7}` |

## Built-in tools

| Name | Description |
|---|---|
| `read` | Read a file (with optional offset/limit) |
| `write` | Write a file |
| `edit` | Replace an exact string in a file |
| `bash` | Run a shell command (accepts `cwd` and `timeout` as runtime args) |

Sidecar tools are added automatically when a sidecar is connected.

## AGENTS.md — project context for all agents

If an `AGENTS.md` file exists in the working directory (or any parent up to the
nearest `.git` root), its content is automatically prepended to the system prompt
of **every** agent at session start — orchestrator, static workers, and workers
dynamically spawned at runtime. No configuration is required.

Use `AGENTS.md` for project-level conventions that all agents should follow:
coding standards, commit format, build instructions, testing conventions.

```
my-project/
  .git/
  AGENTS.md          ← prepended to all agents in every session
  .planck/
    teams/
    skills/
```

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
      "description":   "Reviews builder output against planner tasks",
      "provider":      "openai",
      "model_id":      "gpt-4o",
      "system_prompt": "prompts/reviewer.md",
      "tools":         ["read", "bash"]
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
```

## Inter-agent tools

The orchestrator receives these tools automatically. Workers receive the
response/communication subset.

### Orchestrator-only tools

| Tool | Description |
|---|---|
| `spawn_agent` | Spawn a new worker agent in the team |
| `destroy_agent` | Permanently terminate a worker |
| `interrupt_agent` | Abort a worker's current turn without terminating it |
| `list_models` | List available models (provider, id, base_url, context_window) |

### All-agent tools

| Tool | Description |
|---|---|
| `ask_agent` | Send a prompt to another agent and block until it responds |
| `delegate_task` | Send a task without waiting (non-blocking) |
| `send_response` | Send a response back to the delegating agent |
| `list_team` | List all agents with type, name, status, and optionally tools and model |
| `load_skill` | Load a skill by name and return its content (auto-injected when skills exist) |
| `list_skills` | List available skill names and descriptions (opt-in — see Skills below) |

### `spawn_agent` parameters

| Parameter | Required | Description |
|---|---|---|
| `type` | ✅ | Role type for the new agent |
| `name` | ✅ | Human-readable name |
| `description` | ✅ | One-line purpose shown via `list_team` |
| `system_prompt` | ✅ | System prompt (AGENTS.md is prepended automatically) |
| `provider` | ✅ | LLM provider |
| `model_id` | ✅ | Model id — use `list_models` to discover available models |
| `base_url` | | Base URL for local/custom servers; required when multiple servers of the same provider are configured |
| `tools` | | Built-in tool names to grant (subset of the orchestrator's own tools) |
| `skills` | | Skill names to attach; their content is appended to the system prompt |

Use `list_models` before calling `spawn_agent` to get the correct `model_id`
and `base_url` for the target provider.

### `list_team` verbose mode

`list_team` accepts a `verbose` boolean parameter. When `true`, the output
includes each agent's tool names and model in addition to type, name, and status.

## Skills at runtime

`load_skill` is injected automatically into every agent when skills are available.
Agents call it to pull a skill's content into their context on demand — useful
when a skill is too large to pre-inject or only needed for specific tasks.

`list_skills` is opt-in. Add `"list_skills"` to an agent's `tools` array to
enable autonomous skill discovery:

```json
{ "type": "builder", "tools": ["read", "write", "edit", "bash", "list_skills"] }
```

Skills can also be granted to dynamically spawned workers via `spawn_agent`'s
`"skills"` parameter — their content is appended to the worker's system prompt
at spawn time.

## Using a team

```sh
# Start a session with this team
planck --team build-team

# Or set it as default in .planck/config.json
{ "default_team": "build-team" }
```

For full configuration options, see:
https://raw.githubusercontent.com/alexdesousa/planck/main/docs/guides/configuration.md
