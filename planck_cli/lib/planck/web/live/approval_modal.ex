defmodule Planck.Web.Live.ApprovalModal do
  @moduledoc """
  Modal listing parked tool calls awaiting human approval.

  Fed by `:tool_blocked` events and `list_all_pending_approvals/1` on refresh.
  Each entry shows the tool name, reason, and a collapsible fixed-height
  scrollable markdown code block with the command/args. Per-item Approve
  and Deny buttons call Headless passthroughs. Deny carries an optional
  custom reason; empty means the default denial message.
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
     |> assign(:approvals, assigns[:approvals] || [])
     |> assign(:agent_id, assigns[:agent_id])}
  end

  @impl true
  def handle_event("approve", %{"call_id" => call_id} = params, socket) do
    agent_id = params["agent_id"] || socket.assigns.agent_id
    send(self(), {:approve_tool_call, call_id, agent_id})
    {:noreply, socket}
  end

  def handle_event("deny", %{"call_id" => call_id} = params, socket) do
    agent_id = params["agent_id"] || socket.assigns.agent_id
    reason = Map.get(params, "reason", "")
    send(self(), {:deny_tool_call, call_id, agent_id, reason})
    {:noreply, socket}
  end

  def handle_event("toggle_collapse", %{"call_id" => call_id}, socket) do
    key = String.to_atom("expanded_#{call_id}")
    {:noreply, assign(socket, key, !socket.assigns[key])}
  end
end
