defmodule Planck.Web.Live.SetupModal.ChooseStep do
  @moduledoc """
  The :choose step — returning-user action picker.

  Lets the user select what they want to configure: a provider, a model, or
  manage stored API keys. Stateless LiveComponent; all actions are reported
  to the parent via `send_update/2`.
  """

  use Planck.Web, :live_component

  alias Phoenix.LiveView.Socket

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  @spec update(map(), Socket.t()) :: {:ok, Socket.t()}
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(:parent_id, assigns[:parent_id])
     |> assign(:first_run, assigns[:first_run] || false)
     |> assign(:configured_providers, assigns[:configured_providers] || [])}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("choose_action", %{"action" => action}, socket) do
    send_update(Planck.Web.Live.SetupModal,
      id: socket.assigns.parent_id,
      action: :choose,
      value: action
    )

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Template
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-3">
      <button
        class="w-full border-2 border-black px-4 py-3 font-mono text-left
               shadow-[2px_2px_0px_#000] hover:shadow-[4px_4px_0px_#000]
               hover:-translate-x-0.5 hover:-translate-y-0.5 transition-all bg-card"
        phx-click={JS.push("choose_action", value: %{action: "provider"}, target: @myself)}
      >
        <p class="font-bold text-sm"><%= pgettext("setup action", "Configure a provider") %></p>
        <p class="text-xs text-muted-foreground mt-0.5">
          <%= pgettext("setup action", "Add or update an API provider and its credentials.") %>
        </p>
      </button>

      <button
        class="w-full border-2 border-black px-4 py-3 font-mono text-left
               shadow-[2px_2px_0px_#000] hover:shadow-[4px_4px_0px_#000]
               hover:-translate-x-0.5 hover:-translate-y-0.5 transition-all bg-card"
        phx-click={JS.push("choose_action", value: %{action: "model"}, target: @myself)}
      >
        <p class="font-bold text-sm"><%= pgettext("setup action", "Configure a model") %></p>
        <p class="text-xs text-muted-foreground mt-0.5">
          <%= pgettext("setup action", "Add a model alias from an existing provider.") %>
        </p>
      </button>

      <button
        class="w-full border-2 border-black px-4 py-3 font-mono text-left
               shadow-[2px_2px_0px_#000] hover:shadow-[4px_4px_0px_#000]
               hover:-translate-x-0.5 hover:-translate-y-0.5 transition-all bg-card"
        phx-click={JS.push("choose_action", value: %{action: "keys"}, target: @myself)}
      >
        <p class="font-bold text-sm"><%= pgettext("setup action", "Manage secrets") %></p>
        <p class="text-xs text-muted-foreground mt-0.5">
          <%= pgettext("setup action", "View, edit, or delete stored secrets.") %>
        </p>
      </button>

      <button
        class="w-full border-2 border-black px-4 py-3 font-mono text-left
               shadow-[2px_2px_0px_#000] hover:shadow-[4px_4px_0px_#000]
               hover:-translate-x-0.5 hover:-translate-y-0.5 transition-all bg-card"
        phx-click={JS.push("choose_action", value: %{action: "service"}, target: @myself)}
      >
        <p class="font-bold text-sm"><%= pgettext("setup action", "Configure a service rule") %></p>
        <p class="text-xs text-muted-foreground mt-0.5">
          <%= pgettext("setup action", "Route outbound requests through the credential proxy.") %>
        </p>
      </button>
    </div>
    """
  end
end
