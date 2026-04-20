# Team Templates

Team templates define a set of agents in a JSON file. They capture the
serializable fields (type, provider, model, system prompt, options) and leave
tool wiring to the caller — `execute_fn` cannot be serialized.

## JSON format

```json
[
  {
    "type":          "planner",
    "name":          "Planner",
    "description":   "Breaks tasks into steps and delegates work.",
    "provider":      "anthropic",
    "model_id":      "claude-sonnet-4-6",
    "system_prompt": "You are an expert planner.",
    "opts": { "temperature": 0.5 }
  },
  {
    "type":          "builder",
    "name":          "Builder",
    "description":   "Writes and edits code.",
    "provider":      "ollama",
    "model_id":      "llama3.2",
    "system_prompt": "prompts/builder.md"
  }
]
```

### Required fields

| Field       | Type     | Description                                      |
|-------------|----------|--------------------------------------------------|
| `type`      | string   | Role identifier; used for registry lookups       |
| `provider`  | string   | LLM provider — see valid values below            |
| `model_id`  | string   | Provider-specific model identifier               |

### Optional fields

| Field           | Type   | Description                                                    |
|-----------------|--------|----------------------------------------------------------------|
| `name`          | string | Human-readable label shown via `list_team`                     |
| `description`   | string | One-line purpose shown via `list_team`                         |
| `system_prompt` | string | Inline prompt text, or a `.md`/`.txt` path (see below)         |
| `opts`          | object | Provider-specific options forwarded to each LLM call           |
| `tools`         | array  | Tool names to assign to this agent (resolved from `tool_pool:` at start time) |

### Tools by name

The `"tools"` array lists names of tools the agent should receive. Names are
resolved at start time against the `tool_pool:` keyword passed to
`AgentSpec.to_start_opts/2`. Unknown names are silently ignored. Any tools
passed explicitly via `tools:` are appended after the resolved ones.

```json
{
  "type":    "builder",
  "tools":   ["read", "write", "bash", "check_complexity"],
  ...
}
```

```elixir
builtins = [
  Planck.Agent.BuiltinTools.read(),
  Planck.Agent.BuiltinTools.write(),
  Planck.Agent.BuiltinTools.edit(),
  Planck.Agent.BuiltinTools.bash()
]
pool = builtins ++ Planck.Agent.ExternalTool.load_all(dirs)

start_opts = AgentSpec.to_start_opts(spec,
  tool_pool:  pool,
  team_id:    team_id,
  session_id: session_id
)
```

When `spec.tools` is empty (or the `"tools"` key is absent from the JSON),
`to_start_opts/2` falls back to the `tools:` override — the behaviour before
this feature was added.

### `system_prompt` file paths

When `system_prompt` ends with `.md` or `.txt`, it is treated as a file path
resolved relative to the template file's directory:

```
config/
  team.json
  prompts/
    planner.md    ← "system_prompt": "prompts/planner.md" resolves here
```

### Valid providers

Derived from `Planck.AI.Model.providers/0`: `"anthropic"`, `"openai"`,
`"google"`, `"ollama"`, `"llama_cpp"`.

## Loading

```elixir
alias Planck.Agent
alias Planck.Agent.{AgentSpec, Compactor, TeamTemplate}

# From a JSON file
{:ok, specs} = TeamTemplate.load("config/team.json")

# From a pre-decoded list (e.g. loaded from another source)
{:ok, specs} = TeamTemplate.from_list(decoded_list)
```

Invalid entries are skipped with a warning; the rest are returned.

## Wiring tools

Tools are merged in programmatically after loading. Map `type` to a tool list:

```elixir
dirs     = Planck.Agent.Config.tools_dirs!()
ext      = Planck.Agent.ExternalTool.load_all(dirs)
builtin  = Planck.Agent.BuiltinTools

tools_by_type = %{
  "planner" => [
    Planck.Agent.Tools.spawn_agent(session_id, team_id, planner_id, builtin ++ ext)
    | Planck.Agent.Tools.worker_tools(team_id, nil)
  ],
  "builder" => Planck.Agent.Tools.worker_tools(team_id, planner_id) ++
               [builtin.read(), builtin.write(), builtin.edit(), builtin.bash()] ++
               ext
}

team_id    = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
session_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

Enum.each(specs, fn spec ->
  {:ok, model} = Planck.AI.get_model(spec.provider, spec.model_id)
  tools = Map.get(tools_by_type, spec.type, [])

  start_opts = AgentSpec.to_start_opts(spec,
    tools: tools,
    team_id: team_id,
    session_id: session_id,
    on_compact: Compactor.build(model)
  )

  DynamicSupervisor.start_child(Planck.Agent.AgentSupervisor, {Planck.Agent, start_opts})
end)
```

## API

```elixir
# Load agent specs from a JSON file.
@spec load(Path.t()) :: {:ok, [AgentSpec.t()]} | {:error, term()}

# Convert a pre-decoded list of maps into AgentSpec structs.
@spec from_list([map()], keyword()) :: [AgentSpec.t()]

# Convert a single map into an AgentSpec struct.
@spec from_map(map(), base_dir :: Path.t()) ::
        {:ok, AgentSpec.t()} | {:error, String.t()}
```

## `AgentSpec` struct

```elixir
%Planck.Agent.AgentSpec{
  type:          String.t(),
  name:          String.t() | nil,
  description:   String.t() | nil,
  provider:      atom(),
  model_id:      String.t(),
  system_prompt: String.t(),   # already resolved from file path if applicable
  opts:          keyword(),
  tools:         [String.t()]  # tool names resolved from tool_pool: at start time
}
```

`AgentSpec.to_start_opts/2` converts a spec into the keyword list accepted by
`Planck.Agent.start_link/1`, merging in `tool_pool:`, `tools:`, `team_id:`,
`session_id:`, `available_models:`, and `on_compact:` from the caller.
