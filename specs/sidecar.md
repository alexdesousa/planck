# Sidecar

A **sidecar** is a separate Elixir/OTP application that extends planck_headless
over distributed Erlang. It replaces the old `TOOL.json`/`tools_dirs` and `.exs`
compactor mechanisms with a real OTP application: proper supervision trees,
stateful processes, arbitrary dependencies, and full test coverage.

The sidecar can be as minimal as a single module or as rich as a Phoenix application
with a database.

## What the sidecar replaces

| Old | New |
|---|---|
| `tools_dirs` + `TOOL.json` files | `tools/0` callback + `Planck.Agent.Sidecar.list_tools/0` |
| `compactor` config key + `.exs` file | `AgentSpec.compactor` module name + `Planck.Agent.Hooks.Compactor.compact/4` remote dispatch |
| Global `on_compact` in ResourceStore | Per-agent `compactor:` field in AgentSpec / TEAM.json |

## Sidecar behaviour

The `Planck.Agent.Sidecar` behaviour is **optional**. A sidecar that only
provides compactors (via `AgentSpec.compactor`) does not need to implement it —
the compactor module is loaded directly via `:code.ensure_loaded` RPC,
independently of `discover/0`. If no module in the sidecar implements the
behaviour, `list_tools/0` returns `[]` and the sidecar is still marked as
`:connected`; it just contributes no tools to `ResourceStore`.

When tools are needed, the entry-point module implements one callback:

```elixir
defmodule MySidecar.Planck do
  use Planck.Agent.Sidecar

  @impl true
  def tools do
    [
      Planck.Agent.Tool.new(
        name: "run_tests",
        description: "Run the test suite. Pass timeout_ms to override the default.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "timeout_ms" => %{
              "type" => "integer",
              "description" => "Max ms to wait (default 300000)"
            }
          }
        },
        execute_fn: fn _agent_id, _id, args ->
          timeout = Map.get(args, "timeout_ms", 300_000)
          case System.cmd("mix", ["test"], timeout: timeout) do
            {output, 0} -> {:ok, output}
            {output, _} -> {:error, output}
          end
        end
      )
    ]
  end
end
```

`use Planck.Agent.Sidecar` injects `@behaviour Planck.Agent.Sidecar` and a
default no-op `tools/0`. Override `tools/0` to provide tools.

### Module-level RPC entry points

`Planck.Agent.Sidecar` itself provides functions that planck_headless calls
on the sidecar node via `:rpc.call/5`. Because `planck_agent` is a dependency
of both nodes, these are available everywhere:

| Function | Description |
|---|---|
| `discover/0` | Scans loaded OTP apps for a module implementing this behaviour; caches the result in `:persistent_term` (nil not cached — retried on next call). |
| `list_tools/0` | Calls `discover/0` then `list_tools/1`. Returns `[]` if no module found. |
| `list_tools/1` | Converts an explicit module's `tools/0` to `[Planck.AI.Tool.t()]` — no closures, serialisable. Intended for tests. |
| `execute_tool/3` | Calls `discover/0` then dispatches to the matching tool's `execute_fn`. |
| `execute_tool/4` | Same but with an explicit module. Intended for tests. |

planck_headless calls:

```elixir
:rpc.call(sidecar_node, Planck.Agent.Sidecar, :list_tools, [])
:rpc.call(sidecar_node, Planck.Agent.Sidecar, :execute_tool,
          [tool_name, agent_id, args], timeout)
```

No configuration is needed — `list_tools/0` discovers the entry module automatically.

## Startup sequence

`Planck.Headless.SidecarManager` manages the sidecar lifecycle. It starts when
`Config.sidecar!()` points to an existing directory on disk.

### Steps

1. Runs `mix deps.get` then `mix compile` in the sidecar directory (blocking,
   fast-fail on error). Uses erlexec's `:sync` mode.
2. Spawns `elixir --sname planck_sidecar --cookie <cookie> -S mix run --no-halt`
   via erlexec. The following env vars are injected:
   - `PLANCK_HEADLESS_NODE` — `Node.self()` stringified so the sidecar knows where
     to connect.
   - `PATH`, `MIX_ENV`, `PLANCK_LOCAL` — forwarded from the headless process.
3. Calls `:net_kernel.monitor_nodes(true)` and waits for `{:nodeup, sidecar_node}`.
4. On nodeup: calls `Planck.Agent.Sidecar.list_tools/0` via RPC, wraps each
   `Planck.AI.Tool.t()` with an RPC `execute_fn`, stores in `ResourceStore`.
5. On nodedown or OS process exit: clears tools from `ResourceStore`.

### Sidecar Application.start/2

The sidecar connects back to the headless node. The simplest implementation:

```elixir
defmodule MySidecar.Application do
  use Application

  @impl true
  def start(_type, _args) do
    headless_node = System.get_env("PLANCK_HEADLESS_NODE") |> String.to_atom()

    children = [
      {Task, fn -> Node.connect(headless_node) end}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MySidecar.Supervisor)
  end
end
```

The `Task` child connects after the supervisor has started, ensuring the
application is in `loaded_applications/0` before `discover/0` can scan for
the entry module.

### Progress events

`SidecarManager` broadcasts on `Planck.Agent.PubSub` topic `"planck:sidecar"`.
Subscribe with `Planck.Headless.SidecarManager.subscribe/0`.

| Event | When |
|---|---|
| `{:building, sidecar_dir}` | Running `mix deps.get` / `mix compile` |
| `{:starting, sidecar_dir}` | OS process spawned, waiting for node |
| `{:connected, node}` | Sidecar node up, tools loaded |
| `{:disconnected, node}` | Sidecar node went down, tools cleared |
| `{:exited, reason}` | OS process exited unexpectedly |
| `{:error, step, reason}` | Build or spawn step failed |

### Remote execute_fn

For each tool discovered from the sidecar, `SidecarManager` builds a wrapper
that reads the AI-supplied `timeout_ms` from the tool arguments:

```elixir
execute_fn: fn agent_id, tool_call_id, args ->
  timeout = Map.get(args, "timeout_ms", 300_000)
  case :rpc.call(sidecar_node, Planck.Agent.Sidecar, :execute_tool,
                 [tool_name, agent_id, tool_call_id, args], timeout) do
    {:badrpc, reason} -> {:error, reason}
    result -> result
  end
end
```

`timeout_ms` is automatically injected into every sidecar tool's JSON schema
when not already present, so the AI can always set it.

## Per-agent compactors

`AgentSpec` has a `compactor` field:

```elixir
%Planck.Agent.AgentSpec{
  compactor: String.t() | nil  # module name in the sidecar, e.g. "MySidecar.Compactors.Builder"
}
```

In TEAM.json:

```json
{
  "type":          "summariser",
  "provider":      "anthropic",
  "model_id":      "claude-haiku-4-5-20251001",
  "system_prompt": "members/summariser.md",
  "compactor":     "MySidecar.Compactors.Builder"
}
```

planck_headless resolves the `"compactor"` string from TEAM.json to a module atom
and passes it as `compactor:` in the agent start opts. No builder function is
involved — the module is dispatched directly via `Planck.Agent.Hooks.Compactor.compact/4`.

For example, given the TEAM.json entry above, headless starts the agent as:

```elixir
Planck.Agent.start_link(agent_spec,
  compactor: MySidecar.Compactors.Builder,
  sidecar_node: SidecarManager.node()
)
```

The `compactor:` value is the resolved atom (`:"Elixir.MySidecar.Compactors.Builder"`);
planck_headless performs the `String.to_existing_atom/1` conversion after ensuring the
module is loaded via `:rpc.call(sidecar_node, :code, :ensure_loaded, [module])`.

The module must implement `Planck.Agent.Hooks.Compactor`:

```elixir
defmodule MySidecar.Compactors.Builder do
  use Planck.Agent.Hooks.Compactor

  @impl true
  def compact(model, messages) do
    summary = Planck.Agent.Message.new({:custom, :summary}, [{:text, summarise(messages)}])
    kept    = Enum.take(messages, -5)
    {:compact, summary, kept}
  end

  @impl true
  def compact_timeout, do: 60_000
end
```

If the sidecar node is unavailable, `Hooks.Compactor.compact/4` falls back to
the local LLM-based compactor automatically.

## Unified Typesense client

`Sidecar.Typesense` is a shared HTTP client module used by all five sidecar
modules (`Watcher`, `SessionIndexer`, `Memory`, `SearchWorkspace`, `SessionSearch`).
It replaces the per-module private HTTP helpers that existed in earlier versions.

Public API:

| Function | Description |
|---|---|
| `ready?/0` | Health-check; returns `true` when Typesense is reachable |
| `ensure_collection/1` | Create collection if it does not exist |
| `upsert/2` | Insert or replace a document in a collection |
| `get/2` | Fetch a document by id from a collection |
| `delete/2` | Delete a document by id from a collection |
| `search/2` | Full-text search in a collection |
| `url/1` | Build a full URL for a Typesense path |
| `headers/0` | Return auth headers for all requests |

## Per-agent memory

Agent memory is implemented in the sidecar via the `Planck.Agent.Hooks.Prompt`
behaviour. `Sidecar.Memory` is the concrete GenServer that implements this for
the planck_docker bundled sidecar. Declare it in TEAM.json:

```json
{
  "type":        "builder",
  "provider":    "anthropic",
  "model_id":    "claude-sonnet-4-6",
  "prompt_hook": "Sidecar.Memory"
}
```

planck_headless passes `prompt_hook: Sidecar.Memory` (a module atom) directly
at agent start time. Before every LLM turn, the agent calls
`Hooks.Prompt.before_prompt(module, session_id, sidecar_node)` via RPC.

### `Sidecar.Memory` design

`Sidecar.Memory` is an ETS-backed GenServer. Memory is stored in the
`short_term_memory` Typesense collection keyed by `"#{team_name}:#{agent_name}"` —
one record per agent, replaced on each write.

| Callback / function | Behaviour |
|---|---|
| `before_prompt(session_id)` | Reads from ETS (`:sidecar_memory` table keyed by `session_id`); returns memory text or `nil` — fast, non-blocking, no RPC |
| `:turn_end` event handler | Lazy load: if ETS miss, fetches from `short_term_memory` by `agent_key` and populates ETS |
| `:compacted` event handler | Refreshes ETS from Typesense with the latest persisted memory |
| `write/3` | Upserts to `short_term_memory` Typesense and updates ETS |
| `current/1` | Reads current memory from Typesense by `agent_key` |
| `flush/0` | Synchronization helper for tests |

The `:turn_end` lazy-load means cold-start sessions populate their ETS entry on
the first event rather than blocking the prompt path. The `:compacted` refresh
ensures memory is re-consolidated after context compaction — the cheapest point
to do so since compaction already busts the LLM prefix cache.

### `update_memory` tool

`Sidecar.Tools.UpdateMemory` provides the `update_memory` sidecar tool, added to
`Sidecar.Planck.tools/0`. The agent calls this tool to record new facts.

Two actions:

- `"append"` (default) — loads existing memory, concatenates the new fact,
  checks total `memory_size` (chars per line summed) against the 2 200-char limit.
  If over limit, returns the full combined content with an instruction to
  summarise and call again with `"overwrite"`.
- `"overwrite"` — replaces memory entirely, no size check. Used after the agent
  has produced a condensed summary.

### Collection naming

| Collection | Purpose |
|---|---|
| `long_term_memory` | Indexed turn history (append-only, queried by `session_search`) |
| `short_term_memory` | Condensed agent memory keyed by `"team_name:agent_name"` (one record per agent, replace-on-write, injected via `before_prompt`) |

## Per-agent turn-end hook

Post-turn reflection is implemented in the sidecar via the
`Planck.Agent.Hooks.TurnEnd` behaviour. Declare the hook module in TEAM.json:

```json
{
  "type":           "builder",
  "provider":       "anthropic",
  "model_id":       "claude-sonnet-4-6",
  "turn_end_hook":  "MySidecar.Hooks.SkillReflector"
}
```

planck_headless passes `turn_end_hook: MySidecar.Hooks.SkillReflector` (a module
atom) at agent start time. After every LLM turn ends, the agent fires
`Hooks.TurnEnd.reflect/4` in a background `Task` — non-blocking, the agent
returns to idle immediately.

### Threshold check

`Hooks.TurnEnd.reflect/4` derives the tool call count from `turn_messages` and
checks it against `module.reflect_threshold/0` **before dispatching**. The RPC
call only happens when the threshold is met. On all other turns the cost is one
local integer comparison.

Default threshold: 5. Override `reflect_threshold/0` to tune sensitivity.

### Behaviour

```elixir
@callback reflect(
            agent_id :: String.t(),
            turn_messages :: [Planck.Agent.Message.t()]
          ) :: :ok

@callback reflect_threshold() :: non_neg_integer()
@callback reflect_timeout()   :: pos_integer()
```

### Example — SkillReflector

```elixir
defmodule MySidecar.Hooks.SkillReflector do
  use Planck.Agent.Hooks.TurnEnd

  @impl true
  def reflect_threshold, do: 5

  @impl true
  def reflect(agent_id, turn_messages) do
    tool_call_count =
      turn_messages
      |> Enum.flat_map(& &1.content)
      |> Enum.count(&match?({:tool_call, _, _, _}, &1))

    # Query existing skills, decide: new skill / update / skip.
    case decide(turn_messages, tool_call_count) do
      :skip ->
        :ok

      {:write, name, description, content} ->
        write_skill(name, description, content)
        # Signal back via a synthetic tool result visible to the LLM next turn.
        Planck.Agent.inject_tool_result(agent_id, "skill_reflector",
          "Skill '#{name}' written: #{description}")
        :ok
    end
  end

  defp decide(_messages, _count), do: :skip  # implement your logic here
  defp write_skill(_name, _description, _content), do: :ok
end
```

The synthetic tool name (`"skill_reflector"`) does **not** appear in the agent's
callable tool list — it exists only as a history entry the LLM sees passively on
the next turn.

## Config

```elixir
app_env :sidecar, :planck, :sidecar,
  os_env: "PLANCK_SIDECAR",
  default: ".planck/sidecar",
  binding_order: @json
```

| Env var | Config key | Default |
|---|---|---|
| `PLANCK_SIDECAR` | `:sidecar` | `.planck/sidecar` |
| `TYPESENSE_SESSIONS_COLLECTION` | `:sessions_collection` | `"long_term_memory"` |
| `TYPESENSE_MEMORY_COLLECTION` | `:memory_collection` | `"short_term_memory"` |

`PLANCK_SIDECAR` points to a Mix project directory. If the path does not exist
on disk, `SidecarManager` skips startup entirely.

**Elixir/Mix requirement:** the sidecar is built via `mix deps.get` / `mix compile`
and run via `mix run --no-halt`. When using the Planck Burrito binary, Elixir
and Mix must be installed on the system for sidecar support.

## Impact on existing APIs

- `tools_dirs` / `ExternalTool` — removed.
- `compactor` config key / `.exs` file mechanism — removed.
- `ResourceStore.tools` — now populated by `SidecarManager` from sidecar tools.
- `ResourceStore.on_compact` — removed; compactors are per-agent via
  `AgentSpec.compactor` (module name string in TEAM.json).
- `AgentSpec` gains `compactor: String.t() | nil`, `prompt_hook: String.t() | nil`,
  and `turn_end_hook: String.t() | nil`.
- The built-in LLM-based compactor (`Hooks.Compactor.compact/4` with `module: nil`)
  remains as the fallback when no sidecar compactor is configured.
