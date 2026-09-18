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

**Subscribing (and unsubscribing) is entirely the *owning LiveView*'s job —
`SidecarWidget` itself never touches `Phoenix.PubSub`. Confirmed by the
compiler, twice.** `Phoenix.LiveComponent` has no `handle_info/2`: a
component has no process of its own, so a broadcast can never arrive at a
component directly. It also has no termination callback — no `terminate/2`
(checked directly: `Phoenix.LiveComponent.behaviour_info(:callbacks)` lists
only `update_many/1, update/2, mount/1, render/1, handle_event/3,
handle_async/3`). That second fact rules out the first design that comes to
mind (subscribe from `update/2`, unsubscribe from `terminate/2`) — there's no
hook to unsubscribe from when the widget's container unmounts (e.g. a
modal's `:if` turning false fires nothing at all), so a naive
subscribe-on-mount leaks the subscription on every close.

The fix: don't tie the subscription to the component's mount/unmount at all.
Tie it to the *LiveView's own* explicit open/close actions instead — a
LiveView is a real process with real lifecycle control, unlike a component:

```elixir
def handle_event("open_widget", %{"widget_id" => id}, socket) do
  Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "sidecar:widget:#{id}")
  {:noreply, assign(socket, :open_widget_id, id)}
end

def handle_event("close_widget", _params, socket) do
  if id = socket.assigns.open_widget_id do
    Phoenix.PubSub.unsubscribe(Planck.Agent.PubSub, "sidecar:widget:#{id}")
  end
  {:noreply, assign(socket, :open_widget_id, nil)}
end

def handle_info({:widget_rendered, id, html}, socket) do
  send_update(Planck.Web.Live.SidecarWidget, id: "sidecar-widget-modal", html: html)
  {:noreply, socket}
end
```

Note the broadcast payload carries `id` — the LiveView hosts one fixed
component id regardless of which widget is currently open (see "One modal,
not a registry" below), so routing the push correctly depends on the
broadcast naming the widget, not on the component id doing it.

`SidecarWidget` itself only implements the receiving half — a second
`update/2` clause matching `%{html: html}`. Every LiveView that mounts a
`SidecarWidget` has to implement the forwarding *and* the subscribe/unsubscribe
lifecycle itself; there's nothing generic that does it automatically.
Skipping the forwarding half doesn't error — the widget just paints once on
open and silently never updates again. Skipping the unsubscribe half doesn't
error either — it just leaks a subscription per open/close cycle.

## One modal, not a registry

`planck_cli` has no compile-time knowledge of widget ids — sidecars
(including future custom ones) define their own. Rather than a dynamic
component registry keyed by widget id, the WebUI hosts a single, fixed-id
`SidecarWidget` instance (mirroring `Planck.Web.Live.SetupModal`'s existing
pattern) that gets re-targeted at whichever `widget_id` is currently open.
Opening a *different* widget while one is already open just reassigns
`open_widget_id` and re-runs the pull — there is never more than one
instance mounted at a time.

## Container type: widgets declare their own chrome

`use Planck.Agent.Widget` (rather than a bare `@behaviour Planck.Agent.Widget`)
injects `@behaviour Planck.Agent.Widget` and a default `c:container/0`
returning `:modal`, `overridable` via `defoverridable`:

```elixir
defmodule MySidecar.Widgets.Counter do
  use Planck.Agent.Widget

  def id, do: "counter"
  def render(_myself), do: "<div>count: #{count()}</div>"
  def handle_action("increment", _args), do: increment()
end

Counter.container()  # => :modal — no code written for it
```

This is a real function on the widget module, not something dispatch code
resolves on the caller's side (a `Planck.Headless.Widgets.container/1`-style
helper doing a `function_exported?/3` check was considered and rejected —
calling `container/0` directly should behave identically to calling it
through RPC). The tradeoff: a widget that implements the behaviour by hand
(`@behaviour Planck.Agent.Widget`, no `use`) gets no default at all — calling
its `container/0` raises `UndefinedFunctionError` unless it also defines one
itself. `use` is the sanctioned way to get the default; skipping it means
opting out of it too, not silently reverting to `:modal`.

`:drawer` and `:fullscreen` are reserved names, not built — `planck_cli`
only renders modal chrome as of this version. The host LiveView fetches the
container type once per widget (`Planck.Headless.Widgets.container/1`,
mirroring `render/1`'s RPC shape) when deciding how to open it, separately
from the widget's own markup — this is metadata about presentation, not
part of `render/1`'s opaque HTML.

## Opening a widget from a tool call

A tool can attach a UI side effect to its own result, invisible to the LLM,
via the `{:custom, :ui}` message mechanism: `execute_fn` returns a 3-element
form instead of the plain 2-element one, with the third element a **map**
(not a keyword list):

```elixir
{:ok, text}                                                                # unchanged
{:ok, text, %{ui: %{kind: :text, text: note}}}                             # a UI-only note, no widget
{:ok, text, %{ui: %{kind: :widget, label: label, widget: widget_id, data: term()}}}  # a widget-opening button
```

`Planck.Agent.Tool.ui_content/0` is deliberately not just "the widget to
open." That shape would conflate two different things: what the widget
itself contains (`c:Planck.Agent.Widget.render/1`, above) and what shows up
*in the chat transcript* to represent the tool's UI side effect — and not
every such side effect involves a widget at all (a plain confirmation note,
e.g. "Marked 3 beads as done.", has nothing to open). The `kind`-tagged map
keeps those separate:

- `%{kind: :text, text: "..."}` — rendered as plain UI-only text in the chat.
  No widget.
- `%{kind: :widget, label: "...", widget: widget_id, data: initial_snapshot}`
  — rendered as a button labeled `label`. `label` is sidecar-authored and
  human-readable (e.g. `"View kanban board"`, not a generic "Open widget") —
  the tool decides what invites the click, the widget decides what's inside
  once opened. `data` is optional/opaque, same rationale as `render/1`'s
  pull-then-push model above: avoids a round-trip through `render/1` for the
  very first paint, nothing more.

`Planck.Agent.finish_tool_execution/2` strips the `%{ui: ...}` wrapper before
the tool result reaches the LLM, then persists a sibling `{:custom, :ui}`
message per tool call that carried one — `metadata: %{tool_call_id: id, ui:
content}`, not `content`, matching the existing `{:custom, :summary}` /
`{:custom, :agent_response}` convention of keeping `content` within
`Planck.AI.Message.content_part()`'s closed type and putting custom
structured extras in `metadata` instead.

A widget is equally openable independent of any tool call ever having run —
e.g. from a persistent list of available widgets in the WebUI — since
`list_widgets/0` doesn't depend on invocation history.

## Trust model

Widgets assume the sidecar shipping markup is first-party and bundled with
Planck — the same trust level as `planck_agent` itself. If a sidecar can ever
register widgets from an arbitrary external source (e.g. a future
`connect_mcp(url)`-style mechanism), shipping raw HTML from it becomes an XSS
vector, and that path needs a data-only/fixed-catalog renderer instead of the
markup-shipping design described here.

See `specs/sidecar.md` for the sidecar mechanism widgets extend.
