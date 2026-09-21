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

  So subscribe/unsubscribe lifecycle belongs entirely to the owning LiveView
  (`Planck.Web.Live.SessionLive`), tied to its own explicit open/close
  actions (which it *does* control directly), not to this component's
  mount/unmount:

      # Forwarded via send(self(), {:open_widget, ...}) from
      # Planck.Web.Live.ChatComponent — the button lives inside that nested
      # component, which needs to resolve widget_id/data from its own
      # `entries` assign first.
      def handle_info({:open_widget, %{widget_id: id}}, socket) do
        Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "sidecar:widget:\#{id}")
        {:noreply, assign(socket, :open_widget_id, id)}
      end

      # No phx-target — the close button (rendered inside this component's
      # own chrome, at the SessionLive template level) bubbles directly to
      # the owning LiveView, matching how every other modal's close button
      # in this codebase works (e.g. ModelSelectorModal's close_model_selector).
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
  receives that forwarded push.

  ## Modal chrome lives here, not in the host template

  This component renders its own backdrop/box/close-button chrome (mirroring
  `Planck.Web.Live.ModelSelectorModal`'s), rather than `SessionLive`'s
  template wrapping an otherwise-bare content component. `:modal` is the
  only container kind actually implemented as of this version — see
  `specs/widgets.md`'s "Container type" section — so there is no dispatch on
  it here yet; a future `:drawer`/`:fullscreen` container would need its own
  differently-chromed render, decided by the host before mounting, not a
  branch inside this one.
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
      case Planck.Headless.Widgets.render(id, target_selector(id)) do
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

  # Passed to the widget module as `myself` (see c:Planck.Agent.Widget.render/1)
  # for it to bake into its own action controls' phx-target — a plain CSS
  # selector for the wrapper div below, not this component's own numeric CID
  # (`socket.assigns.myself`, which used to be passed here directly).
  #
  # A real CID only identifies *this browser session's* mounted component
  # instance. A widget with mutating actions re-renders by broadcasting one
  # HTML string to every subscriber at once (Sidecar.Beads.broadcast_refresh/1
  # is the concrete case) — a CID baked into that shared string is correct for
  # at most one of them and wrong, or already-stale-and-crashing, for the
  # rest, since Elixir/OTP terms don't survive being serialized into a
  # PubSub-broadcast HTML string, then rendered somewhere else, then acted on
  # as if they still meant something. A selector is just a string: the same
  # one for every subscriber, resolved by each one's own browser against
  # their own DOM, which is the actual point of using a selector for
  # phx-target at all — Phoenix supports both forms for exactly this reason.
  # This is why a first click through a widget's controls worked but a second
  # one (after the first action's own broadcast re-render replaced the HTML)
  # crashed the parent LiveView instead of reaching this component's
  # handle_event/2 at all — confirmed by reproducing it against the beads
  # board specifically before this fix.
  @doc false
  @spec target_selector(String.t()) :: String.t()
  def target_selector(widget_id), do: "#widget-#{widget_id}"

  @impl true
  def handle_event(event, params, socket)

  def handle_event("widget_action", params, socket) do
    # Toast feedback only — the widget's own re-render (broadcast by the
    # sidecar after the action mutates state) is what actually updates what
    # the user sees; this is purely "did it work" confirmation.
    #
    # LiveToast.send_toast/3 takes no socket argument (unlike put_toast/4,
    # a different function for controller/non-LiveView use) — confirmed by
    # reading its source: it dispatches via Phoenix.LiveView.send_update/3
    # to the LiveToast.LiveComponent mounted in the root layout, which works
    # from any process already inside the LiveView's own connection,
    # including a LiveComponent's own handle_event/3.
    case Planck.Headless.Widgets.dispatch_action(
           socket.assigns.widget_id,
           params["action"],
           params["args"]
         ) do
      :ok ->
        LiveToast.send_toast(:info, gettext("%{action} succeeded", action: params["action"]))

      {:error, reason} ->
        LiveToast.send_toast(
          :error,
          gettext("%{action} failed: %{reason}",
            action: params["action"],
            reason: inspect(reason)
          )
        )
    end

    {:noreply, socket}
  end

  @impl true
  def render(assigns)

  def render(%{error: :sidecar_not_connected} = assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
      phx-window-keydown="close_widget"
      phx-key="Escape"
    >
      <div class="border-2 border-black bg-card shadow-[8px_8px_0px_#000] w-full max-w-2xl">
        <div class="border-b-2 border-border px-4 py-3 flex items-center justify-end bg-card">
          <button
            class="border-2 border-black px-3 py-1 font-mono text-xs font-bold
                   shadow-[2px_2px_0px_#000] hover:shadow-[4px_4px_0px_#000]
                   hover:-translate-x-0.5 hover:-translate-y-0.5 transition-all bg-card"
            phx-click="close_widget"
          >✕</button>
        </div>
        <div id={"widget-#{@widget_id}"} class="p-4 text-muted-foreground text-xs">
          <%= pgettext("widget status", "Sidecar not connected — this widget will reload once it reconnects.") %>
        </div>
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
      phx-window-keydown="close_widget"
      phx-key="Escape"
    >
      <div class="border-2 border-black bg-card shadow-[8px_8px_0px_#000] w-full max-w-2xl">
        <div class="border-b-2 border-border px-4 py-3 flex items-center justify-end bg-card">
          <button
            class="border-2 border-black px-3 py-1 font-mono text-xs font-bold
                   shadow-[2px_2px_0px_#000] hover:shadow-[4px_4px_0px_#000]
                   hover:-translate-x-0.5 hover:-translate-y-0.5 transition-all bg-card"
            phx-click="close_widget"
          >✕</button>
        </div>
        <div id={"widget-#{@widget_id}"} class="p-4">
          <%= Phoenix.HTML.raw(@html) %>
        </div>
      </div>
    </div>
    """
  end
end
