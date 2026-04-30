defmodule Planck.Web.Live.AgentsSidebar do
  @moduledoc """
  LiveComponent for the right-hand agents sidebar.

  Owns agent state (status, usage, cost) and sidecar status, updated in
  real-time via `send_update/3`. `open_agent` click events bubble up to the
  parent LiveView which owns the overlay state.

  Parent loads via:

      send_update(AgentsSidebar, id: "agents-sidebar",
        action: :load,
        agents: agents_map,
        agent_order: agent_id_list,
        sidecar: :connected)

  Parent pushes real-time events via:

      send_update(AgentsSidebar, id: "agents-sidebar",
        action: :event,
        event: {:agent_event, type, payload})
  """

  use Planck.Web, :live_component

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:open, false)
     |> assign(:agents, %{})
     |> assign(:agent_order, [])
     |> assign(:sidecar, :idle)}
  end

  @impl true
  def update(assigns, socket)

  def update(%{action: :load} = assigns, socket) do
    {:ok,
     socket
     |> assign(:agents, assigns[:agents] || %{})
     |> assign(:agent_order, assigns[:agent_order] || [])
     |> assign(:sidecar, assigns[:sidecar] || :idle)}
  end

  def update(%{action: :event, event: event}, socket) do
    {:ok, handle_agent_event(socket, event)}
  end

  def update(%{action: :refresh_agents} = assigns, socket) do
    {:ok,
     socket
     |> assign(:agents, assigns.agents)
     |> assign(:agent_order, assigns.agent_order)}
  end

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(:open, assigns[:open] || false)
     |> assign_if_present(:agents, assigns)
     |> assign_if_present(:agent_order, assigns)}
  end

  defp assign_if_present(socket, key, assigns) do
    case Map.fetch(assigns, key) do
      {:ok, value} -> assign(socket, key, value)
      :error -> socket
    end
  end

  # ---------------------------------------------------------------------------
  # Event handling
  # ---------------------------------------------------------------------------

  @spec handle_agent_event(Phoenix.LiveView.Socket.t(), tuple()) :: Phoenix.LiveView.Socket.t()
  defp handle_agent_event(socket, event)

  defp handle_agent_event(socket, {:agent_event, :turn_start, %{agent_id: agent_id}}) do
    update_agent(socket, agent_id, &Map.put(&1, :status, :streaming))
  end

  defp handle_agent_event(socket, {:agent_event, :turn_end, %{agent_id: agent_id}}) do
    update_agent(socket, agent_id, &Map.put(&1, :status, :idle))
  end

  defp handle_agent_event(
         socket,
         {:agent_event, :usage_delta, %{agent_id: agent_id, total: total} = event}
       ) do
    update_agent(socket, agent_id, fn agent ->
      %{
        agent
        | usage: %{input_tokens: total.input_tokens, output_tokens: total.output_tokens},
          cost: Map.get(total, :cost, 0.0),
          context_tokens: Map.get(event, :context_tokens, agent[:context_tokens] || 0)
      }
    end)
  end

  defp handle_agent_event(socket, {sidecar_event, _})
       when sidecar_event in [:building, :starting, :connected, :disconnected, :exited] do
    assign(socket, :sidecar, sidecar_to_status(sidecar_event))
  end

  defp handle_agent_event(socket, {:error, _step, _reason}) do
    assign(socket, :sidecar, :failed)
  end

  defp handle_agent_event(socket, _event) do
    socket
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec update_agent(Phoenix.LiveView.Socket.t(), String.t(), (map() -> map())) ::
          Phoenix.LiveView.Socket.t()
  defp update_agent(socket, agent_id, fun) do
    update(socket, :agents, fn agents ->
      case Map.fetch(agents, agent_id) do
        {:ok, agent} -> Map.put(agents, agent_id, fun.(agent))
        :error -> agents
      end
    end)
  end

  @spec sidecar_to_status(:building | :starting | :connected | :disconnected | :exited) ::
          :idle | :building | :starting | :connected | :failed
  defp sidecar_to_status(status)
  defp sidecar_to_status(:connected), do: :connected
  defp sidecar_to_status(:building), do: :building
  defp sidecar_to_status(:starting), do: :starting
  defp sidecar_to_status(:disconnected), do: :idle
  defp sidecar_to_status(:exited), do: :failed
end
