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
  Return a `{module, timeout_ms}` tuple for the given agent type, or `nil` to
  fall through to the default compactor. `timeout_ms` is used for the RPC call
  to the sidecar — the compactor module knows its own latency better than any
  hardcoded default.
  """
  @callback compactor_for(agent_type :: String.t()) ::
              {module(), timeout_ms :: pos_integer()} | nil
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
        description: "Run the test suite and return output. Pass timeout_ms to override the default.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "timeout_ms" => %{"type" => "integer",
                              "description" => "Max ms to wait for the test suite (default 120000)"}
          }
        },
        execute_fn: fn _id, _args ->
          {output, code} = System.cmd("mix", ["test"])
          if code == 0, do: {:ok, output}, else: {:error, output}
        end
      )
    ]
  end

  @impl true
  def compactor_for("summariser"), do: {MySidecar.Compactors.Summariser, 120_000}
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

1. Reads `Config.sidecar!()` (path to the sidecar Mix project). If the path does
   not exist on disk, skips entirely.
2. Ensures planck_headless is a named node (`Node.start/2` if not already named).
3. Runs the dependency pipeline using `System.cmd` (blocking — these must complete
   before the sidecar starts):
   ```
   mix deps.get   # fetch dependencies, forwards PLANCK_LOCAL if set
   mix compile    # compile sidecar and deps
   ```
   Emits progress events (see *Startup progress events* below) at each step.
4. Spawns `mix run --no-halt` as a long-running OS process via **erlexec**
   (already a dep of `planck_agent`). erlexec is used — not `Port` — because it
   manages process groups so all children of `mix` are killed when the sidecar
   crashes, not just the top-level process. If running as a Burrito binary,
   Elixir and Mix must be installed on the system for sidecar support.
5. Subscribes to node events via `:net_kernel.monitor_nodes(true)`.
6. On `{:nodeup, sidecar_node}`: calls `list_tools/0` via RPC, wraps each tool's
   `execute_fn` in a remote-call closure, stores `{sidecar_node, module, tools}`
   in state. Emits `{:sidecar_event, :ready, %{node: node, tool_count: n}}`.
7. Monitors the node — on `{:nodedown, sidecar_node}`: clears sidecar tools from
   ResourceStore, emits `{:sidecar_event, :disconnected, %{node: node}}`.
   In-flight tool calls receive `{:error, :sidecar_unavailable}`.

### Startup progress events

`SidecarManager` broadcasts on `Phoenix.PubSub` topic `"planck:sidecar"` so TUI
and Web UI clients can show startup progress without blocking:

```elixir
{:sidecar_event, :deps_fetching,  %{path: path}}
{:sidecar_event, :deps_compiling, %{path: path}}
{:sidecar_event, :starting,       %{path: path}}
{:sidecar_event, :ready,          %{node: node, tool_count: n}}
{:sidecar_event, :error,          %{stage: :deps_get | :compile | :start, reason: reason}}
{:sidecar_event, :disconnected,   %{node: node}}
```

Clients subscribe with:

```elixir
Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "planck:sidecar")
```

### Remote `execute_fn` template

For each tool discovered from the sidecar, `SidecarManager` builds a wrapper that
reads the AI-supplied `timeout_ms` from the tool arguments. The AI can estimate the
appropriate timeout from context (file sizes, task complexity) better than any
hardcoded default.

```elixir
@default_tool_timeout_ms 120_000

execute_fn: fn id, args ->
  timeout = Map.get(args, "timeout_ms", @default_tool_timeout_ms)
  :rpc.call(sidecar_node, SidecarModule, :execute_tool, [tool_name, id, args], timeout)
end
```

Every sidecar tool's JSON schema **should** include `timeout_ms` as an optional
integer parameter so the AI can set it when calling the tool. The sidecar scaffold
template generates this automatically.

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

In `AgentSpec.to_start_opts/2`, if `spec.compactor` is set and a sidecar node is
active, `SidecarManager` is asked for the `{module, timeout_ms}` pair and an RPC
closure is built. The timeout comes from the compactor module itself (via
`compactor_for/1`) — the module knows its own expected latency:

```elixir
on_compact =
  with true <- not is_nil(spec.compactor),
       {:ok, sidecar_node} <- SidecarManager.active_node(),
       {module, timeout_ms} <- SidecarManager.compactor_for(spec.compactor, sidecar_node) do
    fn model, messages ->
      :rpc.call(sidecar_node, module, :compact, [model, messages], timeout_ms)
    end
  else
    _ -> Keyword.get(overrides, :on_compact)  # fallback to default compactor
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

The compactor module implements `compact/2`. Its timeout is declared in the
sidecar's `compactor_for/1` callback — not here:

```elixir
defmodule MySidecar.Compactors.Summariser do
  @spec compact(Planck.AI.Model.t(), [Planck.Agent.Message.t()]) ::
          [Planck.Agent.Message.t()]
  def compact(model, messages) do
    # custom summarisation logic — declared timeout: 120_000 ms in compactor_for/1
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

**Elixir/Mix requirement:** the sidecar is started via `mix deps.get`, `mix compile`,
and `mix run --no-halt`. When using the Planck Burrito binary, Elixir and Mix must
be installed on the system if sidecar support is needed. Users without Elixir
installed can still use planck; they just cannot use a sidecar.

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
- `list_tools` remote wrapping — the wrapped `execute_fn` reads `timeout_ms` from
  args, calls the fake sidecar node, and returns the result.
- Progress events — `SidecarManager` emits startup events on `"planck:sidecar"`;
  subscriber receives them in order: `deps_fetching` → `deps_compiling` → `starting`
  → `ready`.
- Per-agent compactor — `AgentSpec.to_start_opts/2` resolves `{module, timeout_ms}`
  from `compactor_for/1` and builds the RPC closure with the declared timeout.
- Node disconnection — sidecar crash removes tools from ResourceStore, emits
  `{:sidecar_event, :disconnected, ...}`; in-flight calls return
  `{:error, :sidecar_unavailable}`.
