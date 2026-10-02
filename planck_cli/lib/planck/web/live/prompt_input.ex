defmodule Planck.Web.Live.PromptInput do
  @moduledoc """
  LiveComponent for the prompt input area. Handles text submission and
  Stop/Stop All controls. History navigation has been removed in favour of
  the edit-message feature on individual chat entries.
  """

  use Planck.Web, :live_component

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:text, "")
     |> assign(:commands, [])
     |> assign(:dropdown_open, false)
     |> assign(:command_matches, [])
     |> assign(:selected_index, 0)
     |> assign(:suppress_dropdown, false)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:streaming, assigns[:streaming] || false)
     |> assign(:waiting, assigns[:waiting] || false)
     |> assign(:commands, assigns[:commands] || [])
     |> maybe_assign(:text, assigns[:text])
     |> maybe_assign(:dropdown_open, assigns[:dropdown_open])
     |> maybe_assign(:command_matches, assigns[:command_matches])
     |> maybe_assign(:selected_index, assigns[:selected_index])
     |> maybe_assign(:suppress_dropdown, assigns[:suppress_dropdown])}
  end

  defp maybe_assign(socket, _key, nil), do: socket
  defp maybe_assign(socket, key, value), do: assign(socket, key, value)

  @impl true
  def handle_event(event, params, socket)

  def handle_event("submit", %{"prompt" => text}, socket) when byte_size(text) > 0 do
    send(self(), {:prompt_submit, text})
    {:noreply, assign(socket, :text, "")}
  end

  def handle_event("submit", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("change", %{"prompt" => text}, socket) do
    socket = assign(socket, :text, text)
    {:noreply, update_dropdown(socket, text)}
  end

  def handle_event("select_command", %{"name" => name}, socket) do
    text = "/#{name} "
    socket = assign(socket, :text, text)

    {:noreply,
     close_dropdown(socket, text)
     |> push_event("select-textarea", %{text: text}, dispatch: :before)}
  end

  def handle_event("navigate", %{"index" => index}, socket) do
    {:noreply, assign(socket, :selected_index, index)}
  end

  def handle_event("close_dropdown", _params, socket) do
    {:noreply, assign(socket, :dropdown_open, false)}
  end

  def handle_event("abort", _params, socket) do
    send(self(), :prompt_abort)
    {:noreply, socket}
  end

  def handle_event("abort_all", _params, socket) do
    send(self(), :prompt_abort_all)
    {:noreply, socket}
  end

  @spec update_dropdown(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  defp update_dropdown(socket, text) do
    if String.starts_with?(text, "/") do
      partial =
        text |> String.slice(1..-1//1) |> String.split(" ", parts: 2) |> List.first() || ""

      matches = filter_commands(socket.assigns.commands, partial)

      if socket.assigns.suppress_dropdown do
        assign(socket, :dropdown_open, false)
      else
        socket
        |> assign(:dropdown_open, matches != [])
        |> assign(:command_matches, matches)
        |> assign(:selected_index, 0)
      end
    else
      socket
      |> assign(:dropdown_open, false)
      |> assign(:command_matches, [])
      |> assign(:suppress_dropdown, false)
    end
  end

  @spec filter_commands([map()], String.t()) :: [map()]
  defp filter_commands(commands, partial) do
    prefix = String.downcase(partial)

    Enum.filter(commands, fn cmd ->
      String.downcase(cmd.name) |> String.starts_with?(prefix)
    end)
  end

  @spec close_dropdown(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  defp close_dropdown(socket, _text) do
    socket
    |> assign(:dropdown_open, false)
    |> assign(:command_matches, [])
    |> assign(:selected_index, 0)
    |> assign(:suppress_dropdown, true)
  end

  @doc false
  def command_subtitle(%{help: help}) when is_binary(help) and help != "", do: help
  def command_subtitle(%{description: desc}), do: desc
end
