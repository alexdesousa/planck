defmodule Planck.Web.Live.PromptInput do
  @moduledoc """
  LiveComponent for the prompt input area. Handles text submission and
  Stop/Stop All controls. History navigation has been removed in favour of
  the edit-message feature on individual chat entries.
  """

  use Planck.Web, :live_component

  @impl true
  def mount(socket) do
    {:ok, assign(socket, :text, "")}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:streaming, assigns[:streaming] || false)
     |> assign(:waiting, assigns[:waiting] || false)}
  end

  @impl true
  def handle_event("submit", %{"prompt" => text}, socket) when byte_size(text) > 0 do
    send(self(), {:prompt_submit, text})
    {:noreply, assign(socket, :text, "")}
  end

  def handle_event("submit", _params, socket), do: {:noreply, socket}

  def handle_event("change", %{"prompt" => text}, socket) do
    {:noreply, assign(socket, :text, text)}
  end

  def handle_event("abort", _params, socket) do
    send(self(), :prompt_abort)
    {:noreply, socket}
  end

  def handle_event("abort_all", _params, socket) do
    send(self(), :prompt_abort_all)
    {:noreply, socket}
  end
end
