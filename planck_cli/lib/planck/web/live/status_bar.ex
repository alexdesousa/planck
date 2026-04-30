defmodule Planck.Web.Live.StatusBar do
  @moduledoc """
  LiveComponent for the bottom status bar.

  Owns total session usage (input/output tokens, cost) and sidecar status,
  updated in real-time via `send_update/3`. `session_name` is passed as a
  plain template assign since it only changes on session switch.

  Parent loads via:

      send_update(StatusBar, id: "status-bar",
        action: :load,
        usage: %{input_tokens: 0, output_tokens: 0, cost: 0.0},
        sidecar: :idle)

  Parent pushes real-time events via:

      send_update(StatusBar, id: "status-bar",
        action: :event,
        event: {:agent_event, :usage_delta, payload})
  """

  use Planck.Web, :live_component

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:session_name, nil)
     |> assign(:usage, %{input_tokens: 0, output_tokens: 0, cost: 0.0})
     |> assign(:sidecar, :idle)}
  end

  @impl true
  def update(assigns, socket)

  def update(%{action: :load} = assigns, socket) do
    {:ok,
     socket
     |> assign(:usage, assigns[:usage] || %{input_tokens: 0, output_tokens: 0, cost: 0.0})
     |> assign(:sidecar, assigns[:sidecar] || :idle)}
  end

  def update(%{action: :event, event: event}, socket) do
    {:ok, handle_event(socket, event)}
  end

  def update(assigns, socket) do
    {:ok, assign(socket, :session_name, assigns[:session_name])}
  end

  # ---------------------------------------------------------------------------
  # Event handling
  # ---------------------------------------------------------------------------

  @spec handle_event(Phoenix.LiveView.Socket.t(), tuple()) :: Phoenix.LiveView.Socket.t()
  defp handle_event(socket, event)

  defp handle_event(socket, {:agent_event, :usage_delta, %{delta: delta}}) do
    update(socket, :usage, fn usage ->
      %{
        input_tokens: usage.input_tokens + delta.input_tokens,
        output_tokens: usage.output_tokens + delta.output_tokens,
        cost: usage.cost + Map.get(delta, :cost, 0.0)
      }
    end)
  end

  defp handle_event(socket, {sidecar_event, _})
       when sidecar_event in [:building, :starting, :connected, :disconnected, :exited] do
    assign(socket, :sidecar, sidecar_to_status(sidecar_event))
  end

  defp handle_event(socket, {:error, _step, _reason}) do
    assign(socket, :sidecar, :failed)
  end

  defp handle_event(socket, _event) do
    socket
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec sidecar_to_status(atom()) :: :idle | :building | :starting | :connected | :failed
  defp sidecar_to_status(status)
  defp sidecar_to_status(:connected), do: :connected
  defp sidecar_to_status(:building), do: :building
  defp sidecar_to_status(:starting), do: :starting
  defp sidecar_to_status(:disconnected), do: :idle
  defp sidecar_to_status(:exited), do: :failed
  defp sidecar_to_status(_), do: :idle
end
