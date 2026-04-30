defmodule Planck.Web.Live.ChatComponent do
  @moduledoc """
  LiveComponent that renders a conversation from a single agent's perspective.

  Parent pushes updates via `send_update/3`:

      # Full reload (session switch, reconnect, first mount)
      send_update(ChatComponent, id: "chat-main",
        action: :load,
        session_id: sid,
        perspective_agent_id: aid_or_nil,
        agents: agents_map)

      # Real-time streaming event
      send_update(ChatComponent, id: "chat-main",
        action: :event,
        event: {:agent_event, type, payload})

  See `Planck.Web.Live.ChatEntries` for the pure classification logic.
  """

  use Planck.Web, :live_component

  alias Planck.Agent.Session
  alias Planck.Web.Live.ChatEntries

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:entries, [])
     |> assign(:session_id, nil)
     |> assign(:perspective_agent_id, nil)
     |> assign(:agents, %{})
     |> assign(:waiting, false)
     |> assign(:streaming, false)
     |> assign(:streaming_agent_id, nil)
     |> assign(:compacting, false)}
  end

  @impl true
  def update(%{action: :load} = assigns, socket) do
    {:ok,
     socket
     |> assign(:session_id, assigns.session_id)
     |> assign(:perspective_agent_id, assigns[:perspective_agent_id])
     |> assign(:agents, assigns[:agents] || %{})
     |> assign(:waiting, false)
     |> assign(:streaming, false)
     |> assign(:streaming_agent_id, nil)
     |> assign(:compacting, false)
     |> load_entries(assigns.session_id)}
  end

  def update(%{action: :event, event: event}, socket) do
    {:ok, handle_agent_event(socket, event)}
  end

  def update(%{action: :update_agents, agents: agents}, socket) do
    {:ok, assign(socket, :agents, agents)}
  end

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:session_id, assigns[:session_id])
     |> assign(:perspective_agent_id, assigns[:perspective_agent_id])
     |> assign(:agents, assigns[:agents] || %{})}
  end

  # ---------------------------------------------------------------------------
  # Local events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("open_edit", %{"db-id" => db_id, "text" => text}, socket) do
    send(self(), {:open_edit_message, %{db_id: String.to_integer(db_id), text: text}})
    {:noreply, socket}
  end

  def handle_event("toggle_entry", %{"id" => entry_id}, socket) do
    entries = ChatEntries.toggle_entry(socket.assigns.entries, entry_id)
    {:noreply, assign(socket, :entries, entries)}
  end

  # ---------------------------------------------------------------------------
  # Real-time event handling
  # ---------------------------------------------------------------------------

  defp handle_agent_event(socket, {:agent_event, :user_message, %{text: text}}) do
    entry = ChatEntries.new_user_entry(text)

    socket
    |> assign(:waiting, true)
    |> update(:entries, &(&1 ++ [entry]))
  end

  defp handle_agent_event(socket, {:agent_event, :turn_start, %{agent_id: aid}}) do
    socket
    |> assign(:waiting, false)
    |> assign(:streaming, true)
    |> assign(:streaming_agent_id, aid)
  end

  defp handle_agent_event(socket, {:agent_event, :turn_end, _}) do
    socket
    |> assign(:streaming, false)
    |> assign(:waiting, false)
    |> assign(:streaming_agent_id, nil)
    |> load_entries(socket.assigns.session_id)
  end

  defp handle_agent_event(socket, {:agent_event, :aborted, _}) do
    entries =
      Enum.map(socket.assigns.entries, fn
        %{streaming: true} = e -> %{e | streaming: false}
        e -> e
      end)

    socket
    |> assign(:entries, entries)
    |> assign(:streaming, false)
    |> assign(:waiting, false)
    |> assign(:streaming_agent_id, nil)
  end

  defp handle_agent_event(socket, {:agent_event, :text_delta, %{text: text, agent_id: aid}}) do
    author = make_agent_author(aid, socket.assigns.agents)

    append_or_update_streaming(socket, "stream-#{aid}", fn
      nil -> ChatEntries.new_text_entry(author, text, "stream-#{aid}")
      entry -> %{entry | text: entry.text <> text}
    end)
  end

  defp handle_agent_event(socket, {:agent_event, :thinking_delta, %{text: text, agent_id: aid}}) do
    author = make_agent_author(aid, socket.assigns.agents)

    append_or_update_streaming(socket, "think-#{aid}", fn
      nil -> ChatEntries.new_thinking_entry(author, text, "think-#{aid}")
      entry -> %{entry | text: entry.text <> text}
    end)
  end

  defp handle_agent_event(
         socket,
         {:agent_event, :tool_start, %{id: tool_id, name: name, args: args, agent_id: aid}}
       ) do
    author = make_agent_author(aid, socket.assigns.agents)

    # Finalize any in-progress text stream so that text arriving after this
    # tool call creates a new entry below the tool card, not above it.
    socket = finalize_streaming_text(socket, aid)

    entry = ChatEntries.new_tool_entry(author, tool_id, name, args)

    update(socket, :entries, &(&1 ++ [entry]))
  end

  defp handle_agent_event(
         socket,
         {:agent_event, :tool_end, %{id: tool_id, result: result, error: error}}
       ) do
    entries =
      Enum.map(socket.assigns.entries, fn
        %{tool_id: ^tool_id} = e ->
          %{e | tool_result: ChatEntries.format_tool_result(result), tool_error: error}

        e ->
          e
      end)

    assign(socket, :entries, entries)
  end

  defp handle_agent_event(
         socket,
         {:agent_event, :inter_agent_in,
          %{text: text, tool_name: name, agent_name: sender_name, agent_id: sender_id}}
       ) do
    entry =
      ChatEntries.new_inter_agent_in_entry(
        {:agent, sender_id, sender_name},
        text,
        name,
        "in-#{:erlang.unique_integer([:positive])}"
      )

    update(socket, :entries, &(&1 ++ [entry]))
  end

  defp handle_agent_event(socket, {:agent_event, :error, %{reason: reason, agent_id: aid}}) do
    author = make_agent_author(aid, socket.assigns.agents)

    entry =
      ChatEntries.new_error_entry(
        author,
        format_error(reason),
        "error-#{:erlang.unique_integer([:positive])}"
      )

    update(socket, :entries, &(&1 ++ [entry]))
  end

  defp handle_agent_event(socket, {:agent_event, :compacting, _}) do
    assign(socket, :compacting, true)
  end

  defp handle_agent_event(socket, {:agent_event, :compacted, _}) do
    socket
    |> assign(:compacting, false)
    |> load_entries(socket.assigns.session_id)
  end

  defp handle_agent_event(socket, {:agent_event, :waiting, _}) do
    assign(socket, :waiting, true)
  end

  defp handle_agent_event(socket, _event), do: socket

  # ---------------------------------------------------------------------------
  # History loading
  # ---------------------------------------------------------------------------

  @spec load_entries(Phoenix.LiveView.Socket.t(), String.t() | nil) :: Phoenix.LiveView.Socket.t()
  defp load_entries(socket, nil), do: assign(socket, :entries, [])

  defp load_entries(socket, session_id) do
    entries =
      case Session.messages(session_id) do
        {:ok, rows} ->
          ChatEntries.build(rows, socket.assigns.perspective_agent_id, socket.assigns.agents)

        _ ->
          []
      end

    assign(socket, :entries, entries)
  end

  # ---------------------------------------------------------------------------
  # Streaming helpers
  # ---------------------------------------------------------------------------

  defp finalize_streaming_text(socket, agent_id) do
    id = "stream-#{agent_id}"

    update(socket, :entries, fn entries ->
      Enum.map(entries, fn
        %{id: ^id, streaming: true} = e -> %{e | streaming: false}
        e -> e
      end)
    end)
  end

  defp append_or_update_streaming(socket, streaming_id, build_or_update) do
    entries = socket.assigns.entries
    idx = Enum.find_index(entries, &(&1[:id] == streaming_id and &1[:streaming]))

    if idx do
      assign(socket, :entries, List.update_at(entries, idx, &build_or_update.(&1)))
    else
      update(socket, :entries, &(&1 ++ [build_or_update.(nil)]))
    end
  end

  defp make_agent_author(agent_id, agents) do
    name =
      case Map.get(agents, agent_id) do
        nil -> agent_id || "agent"
        agent -> agent[:name] || agent[:type] || "agent"
      end

    {:agent, agent_id, name}
  end

  # ---------------------------------------------------------------------------
  # Formatting helpers
  # ---------------------------------------------------------------------------

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason, pretty: true)

  @doc false
  def time_label(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def time_label(_), do: nil

  # ---------------------------------------------------------------------------
  # Template helpers (called from HEEx)
  # ---------------------------------------------------------------------------

  @doc false
  def author_label(author), do: ChatEntries.author_label(author)

  @doc false
  def agent_label(agents, agent_id) do
    case Map.get(agents, agent_id) do
      nil -> agent_id || "agent"
      agent -> agent[:name] || agent[:type] || "agent"
    end
  end

  @doc false
  def render_markdown(text) when is_binary(text) do
    case Earmark.as_html(text, escape: true, breaks: true) do
      {:ok, html, _} -> Phoenix.HTML.raw(html)
      _ -> Phoenix.HTML.html_escape(text)
    end
  end

  def render_markdown(_), do: Phoenix.HTML.raw("")

  @doc false
  def format_args("bash", %{"command" => cmd}), do: cmd
  def format_args("read", args), do: "path: #{args["path"]}"

  def format_args("write", %{"path" => path, "content" => content}) do
    "path: #{path}\n\n#{String.slice(content, 0, 300)}#{if String.length(content) > 300, do: "…", else: ""}"
  end

  def format_args("edit", %{"path" => path, "old_string" => old, "new_string" => new}) do
    first_line = fn t -> t |> String.split("\n") |> List.first("") |> String.trim() end
    "path: #{path}\n\n- #{first_line.(old)}\n+ #{first_line.(new)}"
  end

  def format_args(_, args), do: Jason.encode!(args, pretty: true)
end
