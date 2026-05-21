defmodule Sidecar.SessionIndexer do
  @moduledoc """
  Indexes agent turns into the Typesense sessions collection for long-term recall.

  Subscribes to the `"planck:sessions"` PubSub topic and upserts one document
  per turn into the `sessions_collection` (default `"memory"`). Each document
  combines the user/trigger message and the agent's response, labelled by name:

      User: How do I add a new team?
      orchestrator: To add a new team, create a directory under .planck/teams/...

  Empty turns are skipped. The collection is created on startup if it does not exist.
  """

  use GenServer

  require Logger

  alias Planck.Agent.Message

  @retry_delay 2_000

  @doc "Starts the session indexer under its supervisor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{}, {:continue, :init_collection}}
  end

  @impl true
  def handle_continue(:init_collection, state) do
    if Sidecar.Typesense.ready?() do
      schema = %{
        name: Sidecar.Config.sessions_collection!(),
        fields: [
          %{name: "session_id", type: "string", facet: true},
          %{name: "agent_name", type: "string", facet: true},
          %{name: "content", type: "string"},
          %{name: "timestamp", type: "int64"}
        ],
        default_sorting_field: "timestamp"
      }

      Sidecar.Typesense.ensure_collection(schema)
      Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "planck:sessions")
      Logger.info("[Sidecar.SessionIndexer] subscribed to planck:sessions")
      {:noreply, state}
    else
      Logger.debug("[Sidecar.SessionIndexer] Typesense not ready — retrying in #{@retry_delay}ms")
      Process.send_after(self(), :retry_init, @retry_delay)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:retry_init, state) do
    {:noreply, state, {:continue, :init_collection}}
  end

  def handle_info(
        {:agent_event, :turn_end,
         %{
           message: assistant_msg,
           agent_name: agent_name,
           session_id: session_id,
           turn_messages: turn_messages
         }},
        state
      ) do
    content = format_turn(turn_messages, agent_name)

    if content != "" do
      doc = %{
        id: "#{session_id}:#{assistant_msg.id}",
        session_id: session_id,
        agent_name: agent_name,
        content: content,
        timestamp: DateTime.to_unix(assistant_msg.timestamp)
      }

      Sidecar.Typesense.upsert(Sidecar.Config.sessions_collection!(), doc)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private

  @spec format_turn([Message.t()], String.t()) :: String.t()
  defp format_turn(messages, agent_name) do
    messages
    |> Enum.map(&format_message(&1, agent_name))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  @spec format_message(Message.t(), String.t()) :: String.t()
  defp format_message(message, agent_name)

  defp format_message(%Message{role: :user, content: content}, _agent_name) do
    text = extract_text(content)
    if text == "", do: "", else: "User: #{text}"
  end

  defp format_message(%Message{role: :assistant, content: content}, agent_name) do
    text = extract_text(content)
    if text == "", do: "", else: "#{agent_name}: #{text}"
  end

  defp format_message(
         %Message{role: {:custom, :agent_response}, content: content, metadata: meta},
         _agent_name
       ) do
    text = extract_text(content)
    sender = Map.get(meta, :sender_name, "agent")
    if text == "", do: "", else: "#{sender}: #{text}"
  end

  defp format_message(_msg, _agent_name) do
    ""
  end

  @spec extract_text([Planck.AI.Message.content_part()]) :: String.t()
  defp extract_text(content) do
    content
    |> Enum.flat_map(fn
      {:text, text} -> [text]
      {:thinking, text} -> [text]
      _ -> []
    end)
    |> IO.iodata_to_binary()
    |> String.trim()
  end
end
