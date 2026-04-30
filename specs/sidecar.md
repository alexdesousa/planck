# Sidecar

A **sidecar** is a separate Elixir/OTP application that extends planck_headless
over distributed Erlang. It replaces the old `TOOL.json`/`tools_dirs` and `.exs`
compactor mechanisms with a real OTP application: proper supervision trees,
stateful processes, arbitrary dependencies, and full test coverage.

The sidecar can be as minimal as a single module or as rich as a Phoenix application
with a database. The N8N integration example at the end of this spec shows a sidecar
exposing a webhook endpoint that sends prompts to planck and streams results back.

## What the sidecar replaces

| Old | New |
|---|---|
| `tools_dirs` + `TOOL.json` files | `Planck.Agent.Sidecar.list_tools/0` |
| `compactor` config key + `.exs` file | `Planck.Agent.Sidecar.compactor_for/1` |
| Global `on_compact` in ResourceStore | Per-agent `compactor:` field in AgentSpec / TEAM.json |

## Sidecar behaviour

Defined in `planck_agent` so any OTP application can implement it:

```elixir
defmodule Planck.Agent.Sidecar do
  @moduledoc """
  Behaviour for sidecar applications that extend planck_headless.

  The entry-point module of a sidecar must implement this behaviour. planck_headless
  discovers it via the convention `<AppName>.Planck` (e.g. `MySidecar.Planck`).
  """

  @doc "Return all tools provided by this sidecar."
  @callback list_tools() :: [Planck.Agent.Tool.t()]

  @doc """
  Return a compactor function for the given agent type, or `nil` to fall through
  to the default compactor. The returned function receives the model and the current
  message list and returns the compacted list.
  """
  @callback compactor_for(agent_type :: String.t()) ::
              (Planck.AI.Model.t(), [Planck.Agent.Message.t()] ->
                 [Planck.Agent.Message.t()])
              | nil
end
```

A minimal sidecar implementing both:

```elixir
defmodule MySidecar.Planck do
  @behaviour Planck.Agent.Sidecar

  @impl true
  def list_tools do
    [
      Planck.Agent.Tool.new(
        name: "run_tests",
        description: "Run the test suite and return output.",
        parameters: %{"type" => "object", "properties" => %{}},
        execute_fn: fn _id, _args ->
          {output, code} = System.cmd("mix", ["test"])
          if code == 0, do: {:ok, output}, else: {:error, output}
        end
      )
    ]
  end

  @impl true
  def compactor_for("summariser"), do: &MySidecar.Compactors.Summariser.compact/2
  def compactor_for(_), do: nil
end
```

## Startup sequence

planck_headless starts the sidecar as a separate OS process when `Config.sidecar!()` is
non-nil. The sidecar connects back to planck_headless over distributed Erlang.

### Environment variables injected by planck_headless

| Var | Value |
|---|---|
| `PLANCK_NODE` | planck_headless node name, e.g. `planck@localhost` |
| `PLANCK_COOKIE` | Erlang cookie shared between the nodes |
| `PLANCK_SIDECAR_NODE` | node name the sidecar should use, e.g. `planck_sidecar@localhost` |

planck_headless also ensures it is running as a named node before starting the sidecar
(calling `Node.start/2` if not already named, using `PLANCK_NODE` from config or
generating one).

### Sidecar Application.start/2 contract

The sidecar must connect back and register itself:

```elixir
def start(_type, _args) do
  planck_node = System.fetch_env!("PLANCK_NODE") |> String.to_atom()
  cookie      = System.fetch_env!("PLANCK_COOKIE") |> String.to_atom()
  self_node   = System.fetch_env!("PLANCK_SIDECAR_NODE") |> String.to_atom()

  Node.start(self_node, :shortnames)
  Node.set_cookie(cookie)
  Node.connect(planck_node)

  # Register with SidecarManager — planck_headless will call list_tools/0 etc.
  :rpc.call(planck_node, Planck.Headless.SidecarManager, :register,
            [Node.self(), MySidecar.Planck])

  children = [...]
  Supervisor.start_link(children, strategy: :one_for_one)
end
```

`planck_headless` may also use `:net_kernel.monitor_nodes/1` to detect the connection
and drive discovery itself, in which case the sidecar just needs to connect and
expose the behaviour module under a well-known registered name.

### planck_headless side

`Planck.Headless.SidecarManager`:

1. Reads `Config.sidecar!()` (path to the sidecar Mix project). If nil, skips.
2. Ensures planck_headless is a named node.
3. Spawns the sidecar process:
   ```
   cd <sidecar_path> && mix run --no-halt
   ```
   with the env vars above.
4. Waits for the node to connect (via `:net_kernel.monitor_nodes/1`).
5. Calls `list_tools/0` on the sidecar node; wraps each tool's `execute_fn` in an
   RPC call so agents can call sidecar tools transparently.
6. Stores the wrapped tools in `ResourceStore.sidecar_tools`.
7. Monitors the node — if the sidecar crashes, ResourceStore is updated and
   in-flight tool calls receive `{:error, :sidecar_unavailable}`.

### Remote `execute_fn` template

For each tool discovered from the sidecar:

```elixir
execute_fn: fn id, args ->
  :rpc.call(sidecar_node, SidecarModule, :execute_tool, [tool_name, id, args], 30_000)
end
```

The sidecar module must implement `execute_tool/3` for remote calls:

```elixir
def execute_tool(tool_name, id, args) do
  tool = Enum.find(list_tools(), &(&1.name == tool_name))
  tool.execute_fn.(id, args)
end
```

## Per-agent compactors

`AgentSpec` gains a `compactor` field:

```elixir
%Planck.Agent.AgentSpec{
  ...
  compactor: String.t() | nil  # module name in the sidecar, e.g. "MySidecar.Compactors.Builder"
}
```

In `AgentSpec.to_start_opts/2`, if `spec.compactor` is set:

```elixir
on_compact =
  if spec.compactor && sidecar_node do
    module = String.to_existing_atom(spec.compactor)
    fn model, messages ->
      :rpc.call(sidecar_node, module, :compact, [model, messages], 60_000)
    end
  else
    Keyword.get(overrides, :on_compact)  # fallback to ResourceStore default
  end
```

In TEAM.json:

```json
{
  "type":          "summariser",
  "provider":      "anthropic",
  "model_id":      "claude-haiku-4-5-20251001",
  "system_prompt": "members/summariser.md",
  "compactor":     "MySidecar.Compactors.Summariser"
}
```

The compactor module must implement:

```elixir
defmodule MySidecar.Compactors.Summariser do
  @spec compact(Planck.AI.Model.t(), [Planck.Agent.Message.t()]) ::
          [Planck.Agent.Message.t()]
  def compact(model, messages) do
    # custom summarisation logic
    messages
  end
end
```

## Config

A single new key in `.planck/config.json`:

```json
{
  "sidecar": ".planck/sidecar"
}
```

And in planck_headless config:

```elixir
app_env :sidecar, :planck, :sidecar,
  os_env: "PLANCK_SIDECAR",
  default: ".planck/sidecar",
  binding_order: @json
```

| Env var          | Config key  | Default            |
|------------------|-------------|-------------------|
| `PLANCK_SIDECAR` | `:sidecar`  | `.planck/sidecar` |

`PLANCK_SIDECAR` is useful for CI or when running the sidecar from a non-default
location without touching the config file. The value is `nil`-treated if the
resolved path does not exist on disk — planck_headless simply skips sidecar startup
if the directory is absent.

## `planck sidecar` CLI mode

```sh
planck sidecar
```

Starts planck_headless (which starts the sidecar from config), then blocks. No TUI or
Web UI — the sidecar owns all I/O. Useful when an external system drives planck:

**Example: N8N integration**

The sidecar is a Phoenix application. N8N sends workflow triggers via HTTP:

```
N8N Webhook → MySidecar.Web.PromptController
            → Planck.Headless.start_session() / prompt()
            → (waits for :turn_end via PubSub)
            → MySidecar.Web.PromptController replies to N8N webhook
```

The sidecar subscribes to session PubSub directly (cross-node subscription works
because `Phoenix.PubSub` uses `pg`, which is automatically distributed across
connected nodes):

```elixir
Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "session:#{session_id}")
```

Events arrive in the sidecar process's `handle_info/2` as normal.

## Multiple GenServers

The sidecar is not constrained to a single process. Common patterns:

- **ToolServer** — handles only tool execution; ignores all other events.
- **CompactorServer** — stateful compaction with cross-session context.
- **WebhookController** (Phoenix) — accepts external HTTP triggers, issues prompts.
- **MetricsCollector** — subscribes to all session events, records usage.

Each GenServer subscribes to only the PubSub topics it cares about.

## Sidecar template

`planck_headless` includes a `mix planck.gen.sidecar` Mix task that scaffolds a
minimal sidecar under `.planck/sidecar/`:

```
.planck/sidecar/
  mix.exs           # depends on planck_agent
  lib/
    my_sidecar/
      planck.ex     # implements Planck.Agent.Sidecar behaviour
      tools/        # individual tool modules
      compactors/   # optional custom compactors
  config/
    config.exs
```

## Impact on existing APIs

- `tools_dirs` / `ExternalTool` — removed.
- `compactor` config key / `Planck.Agent.Compactor.load/1` — removed.
- `ResourceStore.tools` — previously loaded from `ExternalTool.load_all/1`, now
  populated from `SidecarManager` (sidecar tools) + built-in tools only.
- `ResourceStore.on_compact` — removed; compactors are now per-agent via
  `AgentSpec.compactor`.
- `AgentSpec` gains `compactor: String.t() | nil`.
- The default compactor (`Planck.Agent.Compactor.build/2`) remains as the fallback
  when no per-agent compactor is set.

## Testing strategy

- `SidecarManager` — starts with no sidecar configured: no-op. Connects a fake
  sidecar node in tests via `:slave.start/3`; verifies tools appear in ResourceStore.
- `list_tools` remote wrapping — the wrapped `execute_fn` calls the fake sidecar node
  and returns the result.
- Per-agent compactor — `AgentSpec.to_start_opts/2` resolves the compactor RPC
  function when a sidecar node is active.
- Node disconnection — sidecar crash removes tools from ResourceStore; in-flight
  calls return `{:error, :sidecar_unavailable}`.
