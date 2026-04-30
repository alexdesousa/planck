defmodule Planck.Web.API.EventController do
  use Planck.Web, :controller

  alias OpenApiSpex.Operation
  alias Planck.Web.API.Schemas

  @keepalive_ms 25_000

  def open_api_operation(:stream),
    do: %Operation{
      tags: ["Sessions"],
      summary: "Event stream (SSE)",
      description: """
      Server-Sent Events stream for a session or a single agent.

      - Omit `agent_id` to receive events from all agents in the session
        (subscribed to `session:<id>`).
      - Pass `?agent_id=<id>` to receive events from one agent only
        (subscribed to `agent:<id>`). The `agent_id` field is injected into
        every frame so the payload shape is identical in both modes.

      Each frame has an `event` name and a JSON `data` payload. The connection
      stays open until the client disconnects. A `: keepalive` comment is sent
      every 25 seconds.
      """,
      operationId: "EventController.stream",
      parameters: [
        Operation.parameter(:id, :path, :string, "Session ID", required: true),
        Operation.parameter(:agent_id, :query, :string, "Filter to a single agent")
      ],
      responses: %{
        200 =>
          Operation.response("SSE stream", "text/event-stream", %OpenApiSpex.Schema{
            type: :string,
            description: "Newline-delimited SSE frames",
            example: Schemas.sse_example()
          })
      }
    }

  @doc "SSE stream of agent events. Scoped to a single agent when `agent_id` is given."
  @spec stream(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def stream(conn, %{"id" => session_id} = params) do
    case resolve_topic(session_id, Map.get(params, "agent_id")) do
      {:ok, topic, inject_id} ->
        conn =
          conn
          |> put_resp_content_type("text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("x-accel-buffering", "no")
          |> send_chunked(200)

        Phoenix.PubSub.subscribe(Planck.Agent.PubSub, topic)
        event_loop(conn, topic, inject_id)

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "Agent not found in session"})
    end
  end

  # ---------------------------------------------------------------------------

  @spec resolve_topic(String.t(), String.t() | nil) ::
          {:ok, String.t(), String.t() | nil} | {:error, :not_found}
  defp resolve_topic(session_id, nil), do: {:ok, "session:#{session_id}", nil}

  defp resolve_topic(session_id, agent_id) do
    with {:ok, meta} <- Planck.Agent.Session.get_metadata(session_id),
         {:ok, pid} <- Planck.Agent.whereis(agent_id),
         true <- agent_in_session?(pid, meta["team_id"]) do
      {:ok, "agent:#{agent_id}", agent_id}
    else
      _ -> {:error, :not_found}
    end
  end

  @spec agent_in_session?(pid(), String.t() | nil) :: boolean()
  defp agent_in_session?(_pid, nil), do: false

  defp agent_in_session?(pid, team_id) do
    Registry.lookup(Planck.Agent.Registry, {team_id, :member})
    |> Enum.any?(fn {p, _} -> p == pid end)
  end

  @spec event_loop(Plug.Conn.t(), String.t(), String.t() | nil) :: Plug.Conn.t()
  defp event_loop(conn, topic, inject_id) do
    receive do
      {:agent_event, type, payload} ->
        payload = if inject_id, do: Map.put(payload, :agent_id, inject_id), else: payload

        case send_event(conn, type, payload) do
          {:ok, conn} -> event_loop(conn, topic, inject_id)
          {:error, _} -> cleanup(conn, topic)
        end

      :stop ->
        cleanup(conn, topic)
    after
      @keepalive_ms ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> event_loop(conn, topic, inject_id)
          {:error, _} -> cleanup(conn, topic)
        end
    end
  end

  @spec send_event(Plug.Conn.t(), atom(), map()) :: {:ok, Plug.Conn.t()} | {:error, term()}
  defp send_event(conn, type, payload) do
    data = payload |> sanitize() |> Jason.encode!()
    chunk(conn, "event: #{type}\ndata: #{data}\n\n")
  end

  # Recursively convert values that Jason cannot encode (tuples, pids, refs,
  # unknown structs) to their inspect string so all payloads are serializable.
  @spec sanitize(term()) :: term()
  defp sanitize(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {k, sanitize(v)} end)
  end

  defp sanitize(list) when is_list(list), do: Enum.map(list, &sanitize/1)
  defp sanitize(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp sanitize(v) when is_atom(v), do: Atom.to_string(v)
  defp sanitize(v), do: inspect(v)

  @spec cleanup(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  defp cleanup(conn, topic) do
    Phoenix.PubSub.unsubscribe(Planck.Agent.PubSub, topic)
    conn
  end
end
