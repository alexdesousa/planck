defmodule Planck.Web.Live.SetupModal.ServiceStep do
  @moduledoc """
  The :service step — configure a service rule for the credential proxy.

  Lets the user associate a stored secret with a host so the proxy injects
  the credential automatically for all outbound requests to that host.

  The step loads existing service rules on mount and lets the user:
  - Pick a secret key
  - Pick a service template (prefills host / auth type / header)
  - Override any field manually
  - Save (upsert) or delete the rule
  """

  use Planck.Web, :live_component

  alias Phoenix.LiveView.Socket
  alias Planck.Headless.Secrets

  # Known service templates: {display_name, host, auth_type, header | nil}
  @templates [
    {"Anthropic", "api.anthropic.com", "api-key", "x-api-key"},
    {"OpenAI", "api.openai.com", "bearer", nil},
    {"Google", "generativelanguage.googleapis.com", "bearer", nil},
    {"GitHub", "api.github.com", "bearer", nil},
    {"Linear", "api.linear.app", "bearer", nil},
    {"Slack", "slack.com", "bearer", nil}
  ]

  # Credential key → default template name for auto-selection
  @key_defaults %{
    "ANTHROPIC_API_KEY" => "Anthropic",
    "OPENAI_API_KEY" => "OpenAI",
    "GOOGLE_API_KEY" => "Google",
    "GITHUB_TOKEN" => "GitHub",
    "LINEAR_API_KEY" => "Linear",
    "SLACK_BOT_TOKEN" => "Slack"
  }

  @template_options [{"Custom", "Custom"} | Enum.map(@templates, fn {n, _, _, _} -> {n, n} end)]

  @auth_type_options [
    {"bearer", "Bearer token (Authorization header)"},
    {"api-key", "API key (custom header)"}
  ]

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  @spec update(map(), Socket.t()) :: {:ok, Socket.t()}
  def update(%{action: _}, socket), do: {:ok, socket}

  def update(assigns, socket) do
    keys =
      case Secrets.list() do
        {:ok, k} -> k
        _ -> []
      end

    services =
      case Secrets.list_services() do
        {:ok, s} -> s
        _ -> []
      end

    {:ok,
     socket
     |> assign(:parent_id, assigns[:parent_id])
     |> assign(:secret_keys, Enum.sort(keys))
     |> assign(:services, services)
     |> assign(:selected_key, nil)
     |> assign(:template, "Custom")
     |> assign(:host, "")
     |> assign(:auth_type, "bearer")
     |> assign(:header, "")
     |> assign(:existing_host, nil)
     |> assign(:error, nil)
     |> assign(:saved, false)}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event(event, params, socket)

  def handle_event("select_key", %{"value" => key}, socket) do
    {:noreply, apply_key_selection(socket, key)}
  end

  def handle_event("select_template", %{"value" => name}, socket) do
    {:noreply, apply_template(socket, name)}
  end

  def handle_event("select_auth_type", %{"value" => auth_type}, socket) do
    {:noreply, socket |> assign(:auth_type, auth_type) |> assign(:saved, false)}
  end

  def handle_event("update_fields", params, socket) do
    {:noreply,
     socket
     |> maybe_assign(:host, params, "host")
     |> maybe_assign(:header, params, "header")
     |> assign(:saved, false)}
  end

  def handle_event("save", _params, socket) do
    {:noreply, do_save(socket)}
  end

  def handle_event("delete", _params, socket) do
    {:noreply, do_delete(socket)}
  end

  # ---------------------------------------------------------------------------
  # Business logic
  # ---------------------------------------------------------------------------

  @spec apply_key_selection(Socket.t(), String.t()) :: Socket.t()
  defp apply_key_selection(socket, key) do
    existing = find_existing_rule(socket.assigns.services, key)
    template_name = Map.get(@key_defaults, key, "Custom")

    socket =
      if existing do
        socket
        |> assign(:template, template_name)
        |> assign(:host, existing.host)
        |> assign(:auth_type, existing.auth_type)
        |> assign(:header, existing.header || "")
        |> assign(:existing_host, existing.host)
      else
        socket
        |> assign(:existing_host, nil)
        |> apply_template(template_name)
      end

    socket
    |> assign(:selected_key, key)
    |> assign(:error, nil)
    |> assign(:saved, false)
  end

  @spec apply_template(Socket.t(), String.t()) :: Socket.t()
  defp apply_template(socket, "Custom") do
    socket
    |> assign(:template, "Custom")
    |> assign(:host, "")
    |> assign(:auth_type, "bearer")
    |> assign(:header, "")
  end

  defp apply_template(socket, name) do
    case Enum.find(@templates, fn {n, _, _, _} -> n == name end) do
      {_, host, auth_type, header} ->
        socket
        |> assign(:template, name)
        |> assign(:host, host)
        |> assign(:auth_type, auth_type)
        |> assign(:header, header || "")

      nil ->
        apply_template(socket, "Custom")
    end
  end

  @spec find_existing_rule([Planck.Agent.Secrets.service()], String.t()) ::
          Planck.Agent.Secrets.service() | nil
  defp find_existing_rule(services, key) do
    Enum.find(services, &(&1.credential_key == key))
  end

  @spec do_save(Socket.t()) :: Socket.t()
  defp do_save(%{assigns: %{selected_key: nil}} = socket) do
    assign(socket, :error, pgettext("setup service", "Select a secret key first."))
  end

  defp do_save(%{assigns: %{host: ""}} = socket) do
    assign(socket, :error, pgettext("setup service", "Host is required."))
  end

  defp do_save(%{assigns: assigns} = socket) do
    opts =
      if assigns.auth_type == "api-key" and assigns.header != "",
        do: [header: assigns.header],
        else: []

    case Secrets.store_service(assigns.host, assigns.auth_type, assigns.selected_key, opts) do
      :ok ->
        services =
          case Secrets.list_services() do
            {:ok, s} -> s
            _ -> socket.assigns.services
          end

        socket
        |> assign(:services, services)
        |> assign(:existing_host, assigns.host)
        |> assign(:error, nil)
        |> assign(:saved, true)

      {:error, reason} ->
        assign(
          socket,
          :error,
          "#{pgettext("setup service", "Failed to save:")} #{inspect(reason)}"
        )
    end
  end

  @spec do_delete(Socket.t()) :: Socket.t()
  defp do_delete(%{assigns: %{existing_host: nil}} = socket), do: socket

  defp do_delete(%{assigns: %{existing_host: host}} = socket) do
    case Secrets.delete_service(host) do
      :ok ->
        services =
          case Secrets.list_services() do
            {:ok, s} -> s
            _ -> []
          end

        socket
        |> assign(:services, services)
        |> assign(:selected_key, nil)
        |> assign(:existing_host, nil)
        |> assign(:host, "")
        |> assign(:auth_type, "bearer")
        |> assign(:header, "")
        |> assign(:template, "Custom")
        |> assign(:error, nil)
        |> assign(:saved, false)

      {:error, reason} ->
        assign(
          socket,
          :error,
          "#{pgettext("setup service", "Failed to delete:")} #{inspect(reason)}"
        )
    end
  end

  @spec maybe_assign(Socket.t(), atom(), map(), String.t()) :: Socket.t()
  defp maybe_assign(socket, key, params, field) do
    case Map.fetch(params, field) do
      {:ok, value} -> assign(socket, key, value)
      :error -> socket
    end
  end

  # ---------------------------------------------------------------------------
  # Template
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    key_options = Enum.map(assigns.secret_keys, fn k -> {k, k} end)

    assigns =
      assigns
      |> assign(:key_options, key_options)
      |> assign(:template_options, @template_options)
      |> assign(:auth_type_options, @auth_type_options)

    ~H"""
    <div class="space-y-4">

      <%!-- Secret key --%>
      <div class="space-y-1">
        <label class="font-mono text-xs font-bold">
          <%= pgettext("setup service", "Secret key") %>
        </label>
        <%= if @secret_keys == [] do %>
          <p class="font-mono text-xs text-muted-foreground">
            <%= pgettext("setup service", "No secrets stored yet. Add one in Manage secrets first.") %>
          </p>
        <% else %>
          <.dropdown
            id="service-key-dropdown"
            name="key"
            options={[{"", pgettext("setup service", "— select a key —")} | @key_options]}
            selected={@selected_key || ""}
            on_select="select_key"
            target={@myself}
          />
        <% end %>
      </div>

      <%= if @selected_key do %>

        <%!-- Service template --%>
        <div class="space-y-1">
          <label class="font-mono text-xs font-bold">
            <%= pgettext("setup service", "Service template") %>
          </label>
          <.dropdown
            id="service-template-dropdown"
            name="template"
            options={@template_options}
            selected={@template}
            on_select="select_template"
            target={@myself}
          />
        </div>

        <%!-- Host + header fields --%>
        <form phx-change="update_fields" phx-target={@myself} class="space-y-3">

          <div class="space-y-1">
            <label class="font-mono text-xs font-bold">
              <%= pgettext("setup service", "Host") %>
            </label>
            <input
              type="text" name="host" value={@host}
              placeholder="api.example.com"
              class="w-full border-2 border-black px-2 py-1.5 font-mono text-sm bg-background focus:outline-none shadow-[2px_2px_0px_#000]"
            />
          </div>

          <div class="space-y-1">
            <label class="font-mono text-xs font-bold">
              <%= pgettext("setup service", "Auth type") %>
            </label>
            <.dropdown
              id="service-auth-type-dropdown"
              name="auth_type"
              options={@auth_type_options}
              selected={@auth_type}
              on_select="select_auth_type"
              target={@myself}
            />
          </div>

          <%= if @auth_type == "api-key" do %>
            <div class="space-y-1">
              <label class="font-mono text-xs font-bold">
                <%= pgettext("setup service", "Header name") %>
              </label>
              <input
                type="text" name="header" value={@header}
                placeholder="x-api-key"
                class="w-full border-2 border-black px-2 py-1.5 font-mono text-sm bg-background focus:outline-none shadow-[2px_2px_0px_#000]"
              />
            </div>
          <% end %>

        </form>

        <%!-- Feedback --%>
        <%= if @error do %>
          <p class="font-mono text-xs text-destructive"><%= @error %></p>
        <% end %>
        <%= if @saved do %>
          <p class="font-mono text-xs text-green-600">
            <%= pgettext("setup service", "Saved.") %>
          </p>
        <% end %>

        <%!-- Actions --%>
        <div class="flex gap-2 pt-1">
          <button
            type="button"
            class="flex-1 border-2 border-black px-3 py-1.5 font-mono text-sm font-bold
                   bg-primary text-primary-foreground shadow-[2px_2px_0px_#000]
                   hover:shadow-[4px_4px_0px_#000] hover:-translate-x-0.5 hover:-translate-y-0.5 transition-all"
            phx-click={JS.push("save", target: @myself)}
          >
            <%= pgettext("setup service", "Save rule") %>
          </button>
          <%= if @existing_host do %>
            <button
              type="button"
              class="border-2 border-destructive px-3 py-1.5 font-mono text-sm font-bold
                     text-destructive shadow-[2px_2px_0px_#000]
                     hover:bg-destructive hover:text-destructive-foreground transition-all"
              phx-click={JS.push("delete", target: @myself)}
              data-confirm={pgettext("confirmation", "Delete rule for %{host}?", host: @existing_host)}
            >
              <%= pgettext("setup service", "Delete") %>
            </button>
          <% end %>
        </div>

      <% end %>
    </div>
    """
  end
end
