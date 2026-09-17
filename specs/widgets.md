# Widgets

A **widget** lets a sidecar render its own UI in the WebUI, instead of being
limited to plain-text tool results. A sidecar tool's only output is otherwise
a string in a tool-result bubble (`Planck.Agent.Sidecar.execute_tool/4`) — for
sidecar-owned state that's inherently visual or long-lived (a task board, a
dependency graph, a live log), there's nothing between "plain text" and
"write your own Phoenix app," and no existing abstraction to build on the way
`Planck.Agent.Secrets` covers credentials.

## Declared on a tool, not independently

A widget is paired with a `Planck.Agent.Tool` via that tool's `:widget` field
— there is no separate, independently-declared widget list:

```elixir
Planck.Agent.Tool.new(
  name: "bd_ready",
  description: "List beads with no open blockers.",
  parameters: %{"type" => "object", "properties" => %{}},
  execute_fn: fn _agent_id, _id, _args -> {:ok, format_ready_beads()} end,
  widget: MySidecar.Widgets.Beads
)
```

`Planck.Agent.Sidecar.list_widgets/0` derives the sidecar's full widget list
by filtering `tools/0` for tools that set `:widget` — one thing to declare per
pairing, not two. This also means a widget is discoverable independently of
whether its owning tool has ever actually been called: a UI can list every
available widget up front (e.g. in a sidebar) by asking for the sidecar's
tools and checking which ones have one.

## The `Planck.Agent.Widget` behaviour

```elixir
@callback id() :: String.t()
@callback render(myself :: term()) :: term()
@callback handle_action(action :: String.t(), args :: map()) :: :ok | {:error, term()}
```

- `id/0` — a stable identifier for the widget, unique within the sidecar.
- `render/1` — render the widget's current state. `myself` is passed through
  opaquely from the caller (in practice, a LiveComponent's CID) so the widget
  can bake it into any action controls it renders — the widget has no
  socket/component context of its own to resolve one from.
- `handle_action/2` — handle an action dispatched from the UI (e.g. a button
  click). Not gated by the LLM's tool-calling permissions; this is a
  human-facing path.

### `render/1`'s return value is opaque to `planck_agent`

`planck_agent` never inspects or interprets what `render/1` returns — it only
RPCs it through to whichever caller asked. `planck_agent` has no Phoenix
dependency (only `phoenix_pubsub`) and no opinion about markup: a widget
module is free to `use Phoenix.Component` and build real HEEx, flattened to a
plain string before it crosses the RPC boundary. The WebUI's own
widget-rendering component is the one place that assumes the returned term is
an HTML string — that assumption belongs there, not upstream in
`planck_agent`.

**Never send a `%Phoenix.LiveView.Rendered{}` (or any closure) across the RPC
boundary.** It embeds anonymous functions for diff-tracking; funs sent between
distributed Erlang nodes only execute correctly if the receiving node has
byte-identical compiled code for that module, which defeats independent
sidecar versioning. A widget flattens its own render with
`Phoenix.HTML.Safe.to_iodata/1 |> IO.iodata_to_binary/1` first — only ever a
`binary()` should cross the wire.

This was weighed against making the contract carry structured *data* instead
of markup (fully renderer-portable across UI surfaces) and decided against for
now: a data-only contract would mean a brand-new widget *kind* needs a
`planck_cli` release to add its renderer, the exact cost that shipping markup
avoids. If a second UI surface (e.g. a TUI) is ever built, a widget targeting
it needs its own separate module producing whatever that surface expects,
reusing the same `Planck.Agent.Widget` behaviour and the same `:widget` field
— not automatic portability from a `planck_cli`-targeting widget.

### Dispatch is separate from `execute_tool/4`

A widget's `render/1`/`handle_action/2` calls never go through the LLM
tool-execution path, via dedicated RPC entry points instead:

```elixir
:rpc.call(sidecar_node, Planck.Agent.Sidecar, :list_widgets, [])
:rpc.call(sidecar_node, Planck.Agent.Sidecar, :widget_render, [widget_id, myself])
:rpc.call(sidecar_node, Planck.Agent.Sidecar, :widget_action, [widget_id, action, args])
```

Two reasons:

1. `execute_tool/4`'s result flows into `Planck.Agent`'s `finish_tool_execution/2`,
   which appends to the agent's actual message history sent back to the LLM. A
   human clicking a widget button has no corresponding assistant-issued tool
   call to attach that to, and faking one to satisfy that invariant is worse
   than just having separate RPC entry points.
2. `execute_fn`'s `{:ok, string} | {:error, string}` contract is meant for the
   model's context; a widget's output is meant for a UI surface to render — a
   different kind of value entirely.

A widget's own actions are correspondingly **unrestricted** by `TEAM.json` —
that mechanism only governs what an *agent* can invoke as a tool call. A human
interacting with a widget directly isn't subject to it.

## Live updates: pull for the first paint, push after that

Opening a widget does one RPC call (`widget_render/2`) for a first snapshot.
After that, the sidecar broadcasts fresh output over `Phoenix.PubSub` on a
topic scoped to the widget's id (e.g. `"sidecar:widget:#{id}"`) whenever its
underlying state changes — mirroring the pattern `sidecar/lib/sidecar/session_indexer.ex`
already uses (subscribing to a topic on `Planck.Agent.PubSub` from the sidecar
node; cross-node PubSub on a shared topic name is existing infrastructure, not
new). Actions round-trip through the same broadcast rather than a synchronous
reply: dispatching an action mutates the widget's state and re-broadcasts:
every open viewer, including the one that acted, updates from that broadcast.
Nothing special-cases "my own click," which matters once more than one viewer
can have the same widget open at once.

## Opening a widget from a tool call

A tool can attach "open this widget" as a UI-only side effect of its own
result, invisible to the LLM — see the `{:custom, :ui}` message mechanism
(tool `execute_fn` returns `{:ok, text, ui: %{widget: widget_id, data: term()}}`
instead of the plain 2-element form). A widget is equally openable independent
of any tool call ever having run — e.g. from a persistent list of available
widgets in the WebUI — since `list_widgets/0` doesn't depend on invocation
history.

## Trust model

Widgets assume the sidecar shipping markup is first-party and bundled with
Planck — the same trust level as `planck_agent` itself. If a sidecar can ever
register widgets from an arbitrary external source (e.g. a future
`connect_mcp(url)`-style mechanism), shipping raw HTML from it becomes an XSS
vector, and that path needs a data-only/fixed-catalog renderer instead of the
markup-shipping design described here.

See `specs/sidecar.md` for the sidecar mechanism widgets extend.
