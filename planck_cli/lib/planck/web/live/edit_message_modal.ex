defmodule Planck.Web.Live.EditMessageModal do
  @moduledoc """
  Modal for editing a previous user message. Truncates the session at the
  selected message and re-prompts with the (possibly modified) text.
  """

  use Planck.Web, :live_component

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:db_id, assigns.db_id)
     |> assign(:text, assigns.text)}
  end

  @impl true
  def handle_event("update_text", %{"text" => text}, socket) do
    {:noreply, assign(socket, :text, text)}
  end

  def handle_event("cancel", _params, socket) do
    send(self(), :close_edit_modal)
    {:noreply, socket}
  end

  def handle_event("resend", _params, socket) do
    send(self(), {:resend_message, %{db_id: socket.assigns.db_id, text: socket.assigns.text}})

    {:noreply, socket}
  end
end
