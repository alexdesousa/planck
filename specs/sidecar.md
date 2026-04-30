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
| `compactor` config key + `.exs` file | `AgentSpec.compactor` string + `Planck.Agent.Compactor.build/2` remote opts |
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
        execute_fn: fn _id, args ->
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
execute_fn: fn agent_id, args ->
  timeout = Map.get(args, "timeout_ms", 300_000)
  case :rpc.call(sidecar_node, Planck.Agent.Sidecar, :execute_tool,
                 [tool_name, agent_id, args], timeout) do
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

`Compactor.build/2` accepts `sidecar_node:` and `compactor:` opts:

```elixir
on_compact = Compactor.build(model,
  sidecar_node: SidecarManager.node(),
  compactor: "MySidecar.Compactors.Builder"
)
```

The `compactor:` string is the bare Elixir module name; it is converted to
`:"Elixir.MySidecar.Compactors.Builder"` internally before the RPC call.
The module must implement `Planck.Agent.Compactor`:

```elixir
defmodule MySidecar.Compactors.Builder do
  use Planck.Agent.Compactor

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

If the sidecar node is unavailable, `Compactor.build/2` falls back to the
local LLM-based compactor automatically.

## Config

```elixir
app_env :sidecar, :planck, :sidecar,
  os_env: "PLANCK_SIDECAR",
  default: ".planck/sidecar",
  binding_order: @json
```

| Env var          | Config key  | Default            |
|------------------|-------------|-------------------|
| `PLANCK_SIDECAR` | `:sidecar`  | `.planck/sidecar` |

`PLANCK_SIDECAR` points to a Mix project directory. If the path does not exist
on disk, `SidecarManager` skips startup entirely.

**Elixir/Mix requirement:** the sidecar is built via `mix deps.get` / `mix compile`
and run via `mix run --no-halt`. When using the Planck Burrito binary, Elixir
and Mix must be installed on the system for sidecar support.

## Impact on existing APIs

- `tools_dirs` / `ExternalTool` — removed.
- `compactor` config key / `Planck.Agent.Compactor.load/1` — removed.
- `ResourceStore.tools` — now populated by `SidecarManager` from sidecar tools.
- `ResourceStore.on_compact` — removed; compactors are per-agent via
  `AgentSpec.compactor`.
- `AgentSpec` gains `compactor: String.t() | nil`.
- The default compactor (`Planck.Agent.Compactor.build/2`) remains as the
  fallback when no sidecar compactor is configured.
