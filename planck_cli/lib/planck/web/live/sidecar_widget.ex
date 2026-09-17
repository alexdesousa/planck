defmodule Planck.Web.Live.SidecarWidget do
  @moduledoc """
  Generic LiveComponent that renders a sidecar-streamed widget.

  Pulls once via RPC for the first paint, then lives off a PubSub broadcast
  for every update after that — see `specs/widgets.md`. This is the one place
  that decides the opaque term `Planck.Headless.Widgets.render/2` returns is
  an HTML string; that assumption belongs here, not upstream in
  `planck_agent`/`planck_headless`.

  ## Owning LiveView responsibility — subscribing and forwarding

  This component never touches `Phoenix.PubSub` itself. Two independent
  reasons, both compiler/runtime-confirmed rather than assumed:

  - `Phoenix.LiveComponent` has no `handle_info/2` — a component has no
    process of its own, so a broadcast can never arrive here directly.
  - `Phoenix.LiveComponent` also has no termination callback (no
    `terminate/2`, checked via `Phoenix.LiveComponent.behaviour_info(:callbacks)`).
    Even if subscribing from `update/2` "worked" for receiving messages via
    the parent's process, there would be no hook to unsubscribe when the
    widget closes — the modal's `:if` unmounting fires no callback at all.

  So subscribe/unsubscribe lifecycle belongs entirely to the owning LiveView,
  tied to its own explicit open/close actions (which it *does* control
  directly), not to this component's mount/unmount:

      def handle_event("open_widget", %{"widget_id" => id}, socket) do
        Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "sidecar:widget:\#{id}")
        {:noreply, assign(socket, :open_widget_id, id)}
      end

      def handle_event("close_widget", _params, socket) do
        if id = socket.assigns.open_widget_id do
          Phoenix.PubSub.unsubscribe(Planck.Agent.PubSub, "sidecar:widget:\#{id}")
        end
        {:noreply, assign(socket, :open_widget_id, nil)}
      end

      def handle_info({:widget_rendered, id, html}, socket) do
        send_update(Planck.Web.Live.SidecarWidget, id: "sidecar-widget-modal", html: html)
        {:noreply, socket}
      end

  This component's own `update(%{html: html}, socket)` clause below is what
  receives that forwarded push. No owning LiveView exists yet as of this
  phase — this is the contract a future one needs to implement.
  """

  use Planck.Web, :live_component

  @impl true
  def update(assigns, socket)

  # The parent template re-passes widget_id on every one of its own
  # re-renders, not just the first mount (Phoenix re-invokes update/2 for a
  # stateful component whenever its parent renders, regardless of whether the
  # assign changed) — confirmed empirically earlier in this design. Once
  # already initialized for this id, later changes arrive only via the
  # owning LiveView's send_update/3 (the %{html: html} clause below), so this
  # clause is a no-op guard against re-issuing the RPC pull on every parent
  # render pass.
  def update(%{widget_id: id}, %{assigns: %{widget_id: id}} = socket) when is_binary(id) do
    {:ok, socket}
  end

  def update(%{widget_id: id}, socket) when is_binary(id) do
    socket =
      case Planck.Headless.Widgets.render(id, socket.assigns.myself) do
        {:ok, html} -> assign(socket, html: html, error: nil)
        {:error, reason} -> assign(socket, html: nil, error: reason)
      end

    {:ok, assign(socket, :widget_id, id)}
  end

  # Forwarded by the owning LiveView via send_update/3 — see the moduledoc.
  def update(%{html: html}, socket) do
    {:ok, assign(socket, html: html, error: nil)}
  end

  def update(_assigns, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_event(event, params, socket)

  def handle_event("widget_action", params, socket) do
    # Result feedback (toast on success/failure) lands in a later phase, once
    # the live_toast dependency is added — see specs/drafts/v0.1.14-spec.md
    # Phase 14. For now this just dispatches; the widget's own re-render
    # (broadcast by the sidecar after the action mutates state) is what the
    # user actually sees.
    Planck.Headless.Widgets.dispatch_action(
      socket.assigns.widget_id,
      params["action"],
      params["args"]
    )

    {:noreply, socket}
  end

  @impl true
  def render(assigns)

  def render(%{error: :sidecar_not_connected} = assigns) do
    ~H"""
    <div id={"widget-#{@widget_id}"} class="text-muted-foreground text-xs">
      <%= pgettext("widget status", "Sidecar not connected — this widget will reload once it reconnects.") %>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div id={"widget-#{@widget_id}"}>
      <%= Phoenix.HTML.raw(@html) %>
    </div>
    """
  end
end
