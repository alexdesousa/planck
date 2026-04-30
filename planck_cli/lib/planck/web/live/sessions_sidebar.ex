defmodule Planck.Web.Live.SessionsSidebar do
  @moduledoc """
  LiveComponent for the left sessions sidebar.

  Owns UI state for delete confirmation and the new session modal.
  Business events (switch, delete, create) are forwarded to the parent
  LiveView via `send(self(), ...)`.
  """

  use Planck.Web, :live_component

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:pending_delete, nil)
     |> assign(:show_new_session, false)
     |> assign(:sessions, [])
     |> assign(:active_session, nil)
     |> assign(:left_open, false)
     |> assign(:teams, [])}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(:sessions, assigns[:sessions] || [])
     |> assign(:active_session, assigns[:active_session])
     |> assign(:left_open, assigns[:left_open] || false)
     |> assign(:teams, assigns[:teams] || [])}
  end

  @impl true
  def handle_event(event, params, socket)

  def handle_event("switch_session", %{"id" => id}, socket) do
    send(self(), {:switch_session, id})
    {:noreply, socket}
  end

  def handle_event("delete_session", %{"id" => id}, socket) do
    {:noreply, assign(socket, :pending_delete, id)}
  end

  def handle_event("confirm_delete", _params, socket) do
    send(self(), {:delete_session, socket.assigns.pending_delete})
    {:noreply, assign(socket, :pending_delete, nil)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :pending_delete, nil)}
  end

  def handle_event("new_session", _params, socket) do
    {:noreply, assign(socket, :show_new_session, true)}
  end

  def handle_event("close_new_session", _params, socket) do
    {:noreply, assign(socket, :show_new_session, false)}
  end

  def handle_event("create_session", %{"team" => team, "name" => name}, socket) do
    send(self(), {:create_session, team, name})
    {:noreply, assign(socket, :show_new_session, false)}
  end
end
