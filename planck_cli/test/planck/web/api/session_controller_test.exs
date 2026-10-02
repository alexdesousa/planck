defmodule Planck.Web.API.SessionControllerTest do
  use Planck.Web.ConnCase, async: false

  @moduletag :tmp_dir

  import Mox
  setup :set_mox_global
  setup :verify_on_exit!

  alias Planck.Agent.{MockAI, Session}
  alias Planck.AI.Model
  alias Planck.Headless
  alias Planck.Headless.Config

  @model %Model{
    id: "llama3.2",
    provider: :openai,
    context_window: 32_768,
    max_tokens: 2_048
  }

  setup %{conn: conn, tmp_dir: dir} do
    sessions_dir = Path.join(dir, "sessions")
    File.mkdir_p!(sessions_dir)

    original = Application.get_env(:planck, :sessions_dir)
    Application.put_env(:planck, :sessions_dir, sessions_dir)
    Config.reload_sessions_dir()

    on_exit(fn ->
      Headless.list_sessions()
      |> Enum.filter(& &1.active)
      |> Enum.each(fn %{session_id: sid} -> Headless.close_session(sid) end)

      Application.delete_env(:planck, :sessions_dir)
      if original, do: Application.put_env(:planck, :sessions_dir, original)
      Config.reload_sessions_dir()
    end)

    stub(MockAI, :get_model, fn _provider, _model_id, _opts -> {:ok, @model} end)

    team_dir = write_team(dir, "test-team")

    # All API endpoints that send a body require content-type: application/json
    # because OpenApiSpex.Plug.CastAndValidate validates the request.
    json_conn = put_req_header(conn, "content-type", "application/json")

    {:ok, conn: json_conn, team_dir: team_dir, sessions_dir: sessions_dir}
  end

  # ---------------------------------------------------------------------------
  # GET /api/sessions
  # ---------------------------------------------------------------------------

  describe "index/2" do
    test "returns empty list when no sessions exist", %{conn: conn} do
      conn = get(conn, "/api/sessions")

      body = json_response(conn, 200)
      assert body == []
      assert_schema(body, "SessionList", api_spec())
    end

    test "lists active and closed sessions", %{conn: conn, team_dir: team_dir} do
      {:ok, sid1} = Headless.start_session(template: team_dir)
      Headless.close_session(sid1)
      {:ok, _sid2} = Headless.start_session(template: team_dir)

      conn = get(conn, "/api/sessions")
      body = json_response(conn, 200)

      assert_schema(body, "SessionList", api_spec())
      assert length(body) == 2
      statuses = Enum.map(body, & &1["status"])
      assert "active" in statuses
      assert "closed" in statuses
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/sessions
  # ---------------------------------------------------------------------------

  describe "create/2" do
    test "starts a session with a team template", %{conn: conn, team_dir: team_dir} do
      conn = post(conn, "/api/sessions", %{template: team_dir})

      body = json_response(conn, 201)
      assert_schema(body, "Session", api_spec())
      assert body["status"] == "active"
      assert is_binary(body["id"])
      assert is_binary(body["name"])
    end

    test "starts a session with an explicit name", %{conn: conn, team_dir: team_dir} do
      conn = post(conn, "/api/sessions", %{template: team_dir, name: "my-session"})

      body = json_response(conn, 201)
      assert_schema(body, "Session", api_spec())
      assert body["name"] == "my-session"
    end

    test "returns 422 when template does not exist", %{conn: conn} do
      conn = post(conn, "/api/sessions", %{template: "nonexistent-team"})

      body = json_response(conn, 422)
      assert_schema(body, "Error", api_spec())
      assert is_binary(body["error"])
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/sessions/:id
  # ---------------------------------------------------------------------------

  describe "show/2" do
    test "returns session detail with agent list for active session",
         %{conn: conn, team_dir: team_dir} do
      {:ok, sid} = Headless.start_session(template: team_dir)

      conn = get(conn, "/api/sessions/#{sid}")
      body = json_response(conn, 200)

      assert_schema(body, "SessionDetail", api_spec())
      assert body["id"] == sid
      assert body["status"] == "active"
      assert body["agents"] != []
    end

    test "returns session detail with empty agents for closed session",
         %{conn: conn, team_dir: team_dir} do
      {:ok, sid} = Headless.start_session(template: team_dir)
      Headless.close_session(sid)

      conn = get(conn, "/api/sessions/#{sid}")
      body = json_response(conn, 200)

      assert_schema(body, "SessionDetail", api_spec())
      assert body["status"] == "closed"
      assert body["agents"] == []
    end

    test "returns 404 for unknown session", %{conn: conn} do
      conn = get(conn, "/api/sessions/nonexistent")

      body = json_response(conn, 404)
      assert_schema(body, "Error", api_spec())
    end
  end

  # ---------------------------------------------------------------------------
  # DELETE /api/sessions/:id
  # ---------------------------------------------------------------------------

  describe "close/2" do
    test "closes an active session", %{conn: conn, team_dir: team_dir} do
      {:ok, sid} = Headless.start_session(template: team_dir)

      conn = delete(conn, "/api/sessions/#{sid}")
      body = json_response(conn, 200)

      assert_schema(body, "Ok", api_spec())
      assert body["ok"] == true
      assert {:error, :not_found} = Session.whereis(sid)
    end

    test "returns 422 for unknown session", %{conn: conn} do
      conn = delete(conn, "/api/sessions/nonexistent")

      body = json_response(conn, 422)
      assert_schema(body, "Error", api_spec())
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/sessions/:id/prompt
  # ---------------------------------------------------------------------------

  describe "prompt/2" do
    test "queues a prompt to an active session", %{conn: conn, team_dir: team_dir} do
      stub(MockAI, :stream, fn _model, _messages, _opts ->
        {:ok, Stream.map([], & &1)}
      end)

      {:ok, sid} = Headless.start_session(template: team_dir)

      conn = post(conn, "/api/sessions/#{sid}/prompt", %{text: "hello"})
      body = json_response(conn, 200)

      assert_schema(body, "Ok", api_spec())
      assert body["ok"] == true
    end

    test "auto-resumes a closed session before prompting", %{conn: conn, team_dir: team_dir} do
      stub(MockAI, :stream, fn _model, _messages, _opts ->
        {:ok, Stream.map([], & &1)}
      end)

      {:ok, sid} = Headless.start_session(template: team_dir)
      Headless.close_session(sid)

      conn = post(conn, "/api/sessions/#{sid}/prompt", %{text: "hello"})
      body = json_response(conn, 200)

      assert_schema(body, "Ok", api_spec())
      assert body["ok"] == true
    end

    test "returns 422 for unknown session", %{conn: conn} do
      conn = post(conn, "/api/sessions/nonexistent/prompt", %{text: "hello"})

      body = json_response(conn, 422)
      assert_schema(body, "Error", api_spec())
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/sessions/:id/abort
  # ---------------------------------------------------------------------------

  describe "abort/2" do
    test "aborts an active session", %{conn: conn, team_dir: team_dir} do
      {:ok, sid} = Headless.start_session(template: team_dir)

      conn = post(conn, "/api/sessions/#{sid}/abort")
      body = json_response(conn, 200)

      assert_schema(body, "Ok", api_spec())
      assert body["ok"] == true
    end

    test "returns 404 for unknown session", %{conn: conn} do
      conn = post(conn, "/api/sessions/nonexistent/abort")

      body = json_response(conn, 404)
      assert_schema(body, "Error", api_spec())
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/sessions/:id/cancel_queued
  # ---------------------------------------------------------------------------

  describe "cancel_queued/2" do
    test "cancels a queued message while the agent is busy", %{conn: conn, team_dir: team_dir} do
      # A stream that blocks until the gate is set, keeping the agent busy so a
      # queued prompt stays unpersisted and cancellable.
      gate = :atomics.new(1, signed: true)
      :atomics.put(gate, 1, 0)

      stub(MockAI, :stream, fn _model, _messages, _opts ->
        Stream.concat(
          [{:text_delta, "hi"}],
          Stream.resource(
            fn -> gate end,
            fn g ->
              if :atomics.get(g, 1) == 1 do
                {:halt, :done}
              else
                Process.sleep(10)
                {[], gate}
              end
            end,
            fn _ -> :ok end
          )
        )
      end)

      {:ok, sid} = Headless.start_session(template: team_dir)

      # First prompt starts the turn (agent is now streaming).
      post(conn, "/api/sessions/#{sid}/prompt", %{text: "first"})

      # Subscribe to capture the message_queued event for the second prompt.
      Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "session:#{sid}")
      post(conn, "/api/sessions/#{sid}/prompt", %{text: "second"})

      assert_receive {:agent_event, :message_queued, %{id: queued_id}}, 1_000

      conn2 = post(conn, "/api/sessions/#{sid}/cancel_queued", %{message_id: queued_id})
      body = json_response(conn2, 200)

      assert_schema(body, "Ok", api_spec())
      assert body["ok"] == true

      :atomics.put(gate, 1, 1)
    end

    test "returns 404 for an unknown message id", %{conn: conn, team_dir: team_dir} do
      stub(MockAI, :stream, fn _model, _messages, _opts ->
        {:ok, Stream.map([], & &1)}
      end)

      {:ok, sid} = Headless.start_session(template: team_dir)

      conn2 = post(conn, "/api/sessions/#{sid}/cancel_queued", %{message_id: "nonexistent"})

      body = json_response(conn2, 404)
      assert_schema(body, "Error", api_spec())
      assert body["error"] == "Message not found"
    end

    test "returns 404 for an already-flushed message", %{conn: conn, team_dir: team_dir} do
      gate = :atomics.new(1, signed: true)
      :atomics.put(gate, 1, 0)

      stub(MockAI, :stream, fn _model, _messages, _opts ->
        Stream.concat(
          [{:text_delta, "hi"}],
          Stream.resource(
            fn -> gate end,
            fn g ->
              if :atomics.get(g, 1) == 1 do
                {:halt, :done}
              else
                Process.sleep(10)
                {[], gate}
              end
            end,
            fn _ -> :ok end
          )
        )
      end)

      {:ok, sid} = Headless.start_session(template: team_dir)

      Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "session:#{sid}")

      # First prompt starts the turn (agent is busy streaming).
      post(conn, "/api/sessions/#{sid}/prompt", %{text: "first"})
      assert_receive {:agent_event, :turn_start, _}, 1_000

      # Second prompt is queued while the agent is busy.
      post(conn, "/api/sessions/#{sid}/prompt", %{text: "second"})
      assert_receive {:agent_event, :message_queued, %{id: queued_id}}, 1_000

      # Release the gate — the turn finishes and flushes the queued message
      # (its string id is replaced by a db id).
      :atomics.put(gate, 1, 1)
      assert_receive {:agent_event, :turn_end, _}, 2_000

      # Cancelling the old string id now returns :not_found (the message is
      # persisted with a db id; the string id is gone).
      conn2 = post(conn, "/api/sessions/#{sid}/cancel_queued", %{message_id: queued_id})

      body = json_response(conn2, 404)
      assert_schema(body, "Error", api_spec())
      assert body["error"] == "Message not found"
    end

    test "returns 404 for an unknown session", %{conn: conn} do
      conn2 = post(conn, "/api/sessions/nonexistent/cancel_queued", %{message_id: "abc"})

      body = json_response(conn2, 404)
      assert_schema(body, "Error", api_spec())
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp write_team(dir, alias_name) do
    team_dir = Path.join(dir, alias_name)
    File.mkdir_p!(team_dir)

    File.write!(
      Path.join(team_dir, "TEAM.json"),
      Jason.encode!(%{
        "name" => alias_name,
        "members" => [
          %{
            "type" => "orchestrator",
            "provider" => "openai",
            "model_id" => "llama3.2",
            "system_prompt" => "You coordinate."
          }
        ]
      })
    )

    team_dir
  end
end
