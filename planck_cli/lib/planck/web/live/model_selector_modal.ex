defmodule Planck.Web.Live.ModelSelectorModal do
  @moduledoc """
  Lightweight modal for switching an agent's model at runtime.

  Shows a dropdown of all available models, pre-selected to the agent's
  current model. On save sends `{:model_changed, agent_id, model_id}` to
  the parent LiveView.
  """

  use Planck.Web, :live_component

  @impl true
  def mount(socket) do
    {:ok, assign(socket, :selected_model, "")}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(:agent_id, assigns.agent_id)
     |> assign(:agent_name, assigns.agent_name)
     |> assign(:selected_model, assigns.current_model || "")
     |> assign(
       :models,
       Enum.map(assigns.available_models, &{&1.id, if(&1.name != "", do: &1.name, else: &1.id)})
     )}
  end

  @impl true
  def handle_event(event, params, socket)

  def handle_event("select_model", %{"value" => value}, socket) do
    {:noreply, assign(socket, :selected_model, value)}
  end

  def handle_event("save", _params, socket) do
    send(self(), {:model_changed, socket.assigns.agent_id, socket.assigns.selected_model})
    {:noreply, socket}
  end
end
