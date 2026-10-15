defmodule Planck.Web.Live.AgentOverlay do
  @moduledoc """
  Worker chat overlay — a centered modal showing one worker agent's
  conversation, its model switcher, a stop action, and a sliding details pane.

  The parent (`SessionLive`) owns *which* agent is open and forwards the
  worker's turn transitions via:

      send_update(AgentOverlay, id: "agent-overlay",
        action: :worker_active, active: boolean())

  The nested `ChatComponent` keeps the id `"chat-overlay"` so the parent can
  stream events straight to it without going through this component.
  """

  use Planck.Web, :live_component

  alias Planck.Agent
  alias Planck.Web.AgentInfo
  alias Planck.Web.Live.{AgentDetails, AgentsSidebar, ChatComponent}

  @impl true
  def update(%{action: :worker_active, active: active}, socket) do
    {:ok, assign(socket, :active?, active)}
  end

  def update(assigns, socket) do
    reinit = assigns[:agent_id] != socket.assigns[:agent_id]

    socket =
      socket
      |> assign(:agent_id, assigns[:agent_id])
      |> assign(:agents, assigns[:agents] || %{})
      |> assign(:model_options, assigns[:model_options] || [])
      |> assign(:session_id, assigns[:session_id])

    if reinit do
      {:ok, init_agent_state(socket)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("close", _params, socket) do
    # Escape closes the details pane first; the overlay only closes when the
    # pane is not covering it.
    case socket.assigns.details do
      %{open: true} = details ->
        {:noreply, assign(socket, :details, Map.put(details, :open, false))}

      _ ->
        send(self(), :close_overlay)
        {:noreply, socket}
    end
  end

  def handle_event("open_details", _params, socket) do
    case AgentInfo.build(socket.assigns.agent_id) do
      {:ok, details} -> {:noreply, assign(socket, :details, Map.put(details, :open, true))}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("close_details", _params, socket) do
    case socket.assigns.details do
      %{open: true} = details ->
        {:noreply, assign(socket, :details, Map.put(details, :open, false))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("abort_worker", _params, socket) do
    agent_id = socket.assigns.agent_id
    abort_agent(agent_id)

    send_update(ChatComponent,
      id: "chat-overlay",
      action: :event,
      event: {:agent_event, :aborted, %{}}
    )

    send_update(AgentsSidebar,
      id: "agents-sidebar",
      action: :event,
      event: {:agent_event, :aborted, %{agent_id: agent_id}}
    )

    {:noreply, assign(socket, :active?, false)}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Details are built eagerly (but only once per agent) so the pane DOM node
  # exists hidden and the slide-up/slide-down transition can run.
  @spec init_agent_state(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp init_agent_state(socket) do
    agent_id = socket.assigns.agent_id
    active = agent_active?(agent_id)

    send_update(ChatComponent,
      id: "chat-overlay",
      action: :load,
      session_id: socket.assigns.session_id,
      perspective_agent_id: agent_id,
      agents: socket.assigns.agents,
      streaming: active,
      streaming_agent_id: if(active, do: agent_id)
    )

    details =
      case AgentInfo.build(agent_id) do
        {:ok, details} -> Map.put(details, :open, false)
        {:error, _} -> nil
      end

    socket
    |> assign(:active?, active)
    |> assign(:details, details)
  end

  @spec agent_active?(String.t()) :: boolean()
  defp agent_active?(agent_id) do
    case Agent.whereis(agent_id) do
      {:ok, pid} -> Agent.get_state(pid).turn.status in [:streaming, :executing_tools]
      _ -> false
    end
  end

  @spec abort_agent(String.t()) :: :ok
  defp abort_agent(agent_id) do
    case Agent.whereis(agent_id) do
      {:ok, pid} -> Agent.abort(pid)
      _ -> :ok
    end
  end
end
