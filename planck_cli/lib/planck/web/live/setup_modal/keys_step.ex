defmodule Planck.Web.Live.SetupModal.KeysStep do
  @moduledoc """
  The :keys step — view, edit, and delete stored secrets.
  """

  use Planck.Web, :live_component

  alias Phoenix.LiveView.Socket

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  @spec update(map(), Socket.t()) :: {:ok, Socket.t()}
  def update(%{action: _} = _msg, socket), do: {:ok, socket}

  def update(assigns, socket) do
    {:ok, keys} = Planck.Headless.Secrets.list()

    {:ok,
     socket
     |> assign(:parent_id, assigns[:parent_id])
     |> assign(:secrets, Enum.sort(keys))
     |> assign(:editing_key, nil)
     |> assign(:edit_value, "")
     |> assign(:new_key, "")
     |> assign(:new_value, "")}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event(event, params, socket)

  def handle_event("edit_key", %{"key" => key}, socket) do
    value =
      case Planck.Headless.Secrets.fetch(key) do
        {:ok, v} -> v
        _ -> ""
      end

    {:noreply, socket |> assign(:editing_key, key) |> assign(:edit_value, value)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, socket |> assign(:editing_key, nil) |> assign(:edit_value, "")}
  end

  def handle_event("update_key_fields", params, socket) do
    {:noreply,
     socket
     |> maybe_assign(:edit_value, params, "edit_value")
     |> maybe_assign(:new_key, params, "new_key")
     |> maybe_assign(:new_value, params, "new_value")}
  end

  def handle_event("save_key", _params, socket) do
    {:noreply, do_save_key(socket)}
  end

  def handle_event("delete_key", %{"key" => key}, socket) do
    {:noreply, do_delete_key(socket, key)}
  end

  def handle_event("add_key", _params, socket) do
    {:noreply, do_add_key(socket)}
  end

  # ---------------------------------------------------------------------------
  # Business logic
  # ---------------------------------------------------------------------------

  @spec do_save_key(Socket.t()) :: Socket.t()
  defp do_save_key(%{assigns: %{editing_key: key, edit_value: value}} = socket)
       when is_binary(key) and key != "" do
    case Planck.Headless.Secrets.store(key, value) do
      :ok ->
        socket
        |> assign(:editing_key, nil)
        |> assign(:edit_value, "")
        |> assign(:error, nil)

      {:error, reason} ->
        assign(socket, :error, "Failed to save: #{inspect(reason)}")
    end
  end

  defp do_save_key(socket), do: socket

  @spec do_delete_key(Socket.t(), String.t()) :: Socket.t()
  defp do_delete_key(socket, key) do
    case Planck.Headless.Secrets.delete(key) do
      :ok ->
        socket
        |> update(:secrets, &List.delete(&1, key))
        |> assign(:error, nil)

      {:error, reason} ->
        assign(socket, :error, "Failed to delete: #{inspect(reason)}")
    end
  end

  @spec do_add_key(Socket.t()) :: Socket.t()
  defp do_add_key(%{assigns: %{new_key: key, new_value: value}} = socket)
       when is_binary(key) and key != "" and is_binary(value) and value != "" do
    case Planck.Headless.Secrets.store(key, value) do
      :ok ->
        socket
        |> update(:secrets, fn keys -> Enum.sort([key | List.delete(keys, key)]) end)
        |> assign(:new_key, "")
        |> assign(:new_value, "")
        |> assign(:error, nil)

      {:error, reason} ->
        assign(socket, :error, "Failed to add: #{inspect(reason)}")
    end
  end

  defp do_add_key(socket) do
    assign(socket, :error, pgettext("setup error", "Key and value are required."))
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
    ~H"""
    <form phx-change="update_key_fields" phx-target={@myself} class="space-y-2">

      <%!-- Existing keys --%>
      <%= if @secrets == [] do %>
        <p class="font-mono text-xs text-muted-foreground py-2">
          <%= pgettext("setup keys", "No secrets stored yet.") %>
        </p>
      <% end %>

      <%= for key <- @secrets do %>
        <div class="border-2 border-border p-2 space-y-2">
          <div class="flex items-center justify-between gap-2">
            <span class="font-mono text-xs font-bold truncate"><%= key %></span>
            <%= if @editing_key != key do %>
              <div class="flex gap-1 flex-shrink-0">
                <button type="button"
                  class="font-mono text-xs border border-black px-2 py-0.5 hover:bg-muted"
                  phx-click={JS.push("edit_key", value: %{key: key}, target: @myself)}>
                  <%= pgettext("setup keys", "edit") %>
                </button>
                <button type="button"
                  class="font-mono text-xs border border-destructive px-2 py-0.5 text-destructive hover:bg-destructive hover:text-destructive-foreground"
                  phx-click={JS.push("delete_key", value: %{key: key}, target: @myself)}
                  data-confirm={pgettext("confirmation", "Delete %{key}?", key: key)}>
                  <%= pgettext("setup keys", "delete") %>
                </button>
              </div>
            <% end %>
          </div>

          <%!-- Inline edit — always shows value in plain text --%>
          <%= if @editing_key == key do %>
            <div class="flex gap-2">
              <input type="text" name="edit_value" value={@edit_value}
                class="flex-1 border-2 border-black px-2 py-1 font-mono text-xs bg-background focus:outline-none"
                placeholder={pgettext("setup keys", "new value")} />
              <button type="button"
                class="font-mono text-xs border-2 border-black px-2 py-1 bg-primary text-primary-foreground"
                phx-click={JS.push("save_key", target: @myself)}>
                <%= pgettext("setup keys", "save") %>
              </button>
              <button type="button"
                class="font-mono text-xs border-2 border-black px-2 py-1 bg-card"
                phx-click={JS.push("cancel_edit", target: @myself)}>
                <%= pgettext("setup keys", "cancel") %>
              </button>
            </div>
          <% end %>
        </div>
      <% end %>

      <%!-- Add new key --%>
      <div class="border-t-2 border-border pt-3 mt-3 space-y-2">
        <p class="font-mono text-xs text-muted-foreground font-bold">
          <%= pgettext("setup keys", "Add a secret") %>
        </p>
        <input type="text" name="new_key" value={@new_key}
          class="w-full border-2 border-black px-2 py-1.5 font-mono text-sm bg-background focus:outline-none shadow-[2px_2px_0px_#000]"
          placeholder="KEY_NAME" />
        <input type="text" name="new_value" value={@new_value}
          class="w-full border-2 border-black px-2 py-1.5 font-mono text-sm bg-background focus:outline-none shadow-[2px_2px_0px_#000]"
          placeholder={pgettext("setup keys", "value")} />
        <button type="button"
          class="w-full border-2 border-black px-3 py-1.5 font-mono text-sm font-bold
                 bg-primary text-primary-foreground shadow-[2px_2px_0px_#000]
                 hover:shadow-[4px_4px_0px_#000] hover:-translate-x-0.5 hover:-translate-y-0.5 transition-all"
          phx-click={JS.push("add_key", target: @myself)}>
          <%= pgettext("setup keys", "Add") %>
        </button>
      </div>
    </form>
    """
  end
end
