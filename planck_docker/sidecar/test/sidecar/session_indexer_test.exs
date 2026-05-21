defmodule Sidecar.SessionIndexerTest do
  use ExUnit.Case, async: false

  alias Planck.Agent.Message
  alias Sidecar.{Config, SessionIndexer}

  setup do
    bypass = Bypass.open()
    Application.put_env(:sidecar, :typesense_url, "http://localhost:#{bypass.port}")
    Application.put_env(:sidecar, :typesense_api_key, "test-key")
    Application.put_env(:sidecar, :sessions_collection, "test_sessions")
    Config.reload_typesense_url()
    Config.reload_typesense_api_key()
    Config.reload_sessions_collection()

    on_exit(fn ->
      Application.delete_env(:sidecar, :typesense_url)
      Application.delete_env(:sidecar, :typesense_api_key)
      Application.delete_env(:sidecar, :sessions_collection)
      Config.reload_typesense_url()
      Config.reload_typesense_api_key()
      Config.reload_sessions_collection()
    end)

    {:ok, bypass: bypass}
  end

  # Stubs health + collection creation so the indexer initialises cleanly,
  # then returns the started pid.
  defp start_indexer(bypass) do
    Bypass.stub(bypass, "GET", "/health", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"ok":true}))
    end)

    Bypass.stub(bypass, "POST", "/collections", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(409, "{}")
    end)

    pid = start_supervised!(SessionIndexer)
    # Synchronise with the GenServer so handle_continue has completed
    # before we start sending events.
    :sys.get_state(pid)
    pid
  end

  defp make_message(role, text, metadata \\ %{}) do
    Message.new(role, [{:text, text}], metadata)
  end

  defp turn_end_event(opts) do
    session_id = Keyword.get(opts, :session_id, "sess-1")
    agent_name = Keyword.get(opts, :agent_name, "orchestrator")
    turn_messages = Keyword.get(opts, :turn_messages, [])
    assistant_msg = Keyword.get(opts, :message, make_message(:assistant, "response"))

    {:agent_event, :turn_end,
     %{
       message: assistant_msg,
       agent_name: agent_name,
       session_id: session_id,
       turn_messages: turn_messages,
       usage: %{}
     }}
  end

  # ---------------------------------------------------------------------------
  # Turn indexing
  # ---------------------------------------------------------------------------

  describe "turn indexing" do
    test "upserts a document combining user and assistant messages", %{bypass: bypass} do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/collections/test_sessions/documents", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:upserted, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, "{}")
      end)

      indexer = start_indexer(bypass)

      user_msg = make_message(:user, "How do I configure the provider?")

      assistant_msg =
        make_message(:assistant, "Open .planck/config.json and add a provider entry.")

      send(
        indexer,
        turn_end_event(
          session_id: "sess-1",
          agent_name: "orchestrator",
          turn_messages: [user_msg, assistant_msg],
          message: assistant_msg
        )
      )

      assert_receive {:upserted, doc}, 1_000
      assert doc["content"] =~ "User: How do I configure the provider?"
      assert doc["content"] =~ "orchestrator: Open .planck/config.json"
      assert doc["session_id"] == "sess-1"
      assert doc["agent_name"] == "orchestrator"
    end

    test "uses sender_name for agent_response messages", %{bypass: bypass} do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/collections/test_sessions/documents", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:upserted, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, "{}")
      end)

      indexer = start_indexer(bypass)

      trigger =
        make_message({:custom, :agent_response}, "Done, here are the results.", %{
          sender_name: "Builder"
        })

      assistant_msg = make_message(:assistant, "Great, I'll present the results to the user.")

      send(
        indexer,
        turn_end_event(
          turn_messages: [trigger, assistant_msg],
          message: assistant_msg
        )
      )

      assert_receive {:upserted, doc}, 1_000
      assert doc["content"] =~ "Builder: Done, here are the results."
      assert doc["content"] =~ "orchestrator: Great, I'll present"
    end

    test "document id is session_id:message_id", %{bypass: bypass} do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/collections/test_sessions/documents", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:upserted, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, "{}")
      end)

      indexer = start_indexer(bypass)

      assistant_msg = make_message(:assistant, "Here is my answer to your question.")
      user_msg = make_message(:user, "What is the answer?")

      send(
        indexer,
        turn_end_event(
          session_id: "my-session",
          turn_messages: [user_msg, assistant_msg],
          message: assistant_msg
        )
      )

      assert_receive {:upserted, doc}, 1_000
      assert doc["id"] == "my-session:#{assistant_msg.id}"
    end

    test "skips upsert when formatted content is empty", %{bypass: bypass} do
      indexer = start_indexer(bypass)

      # Tool-result-only messages produce no formatted content
      tool_result = Message.new(:tool_result, [{:tool_result, "id1", "output"}])
      assistant_msg = make_message(:assistant, "")

      # No POST /documents should happen — Bypass would error on unexpected calls
      send(
        indexer,
        turn_end_event(
          turn_messages: [tool_result],
          message: assistant_msg
        )
      )

      # Give the GenServer time to process
      :sys.get_state(indexer)
    end
  end

  # ---------------------------------------------------------------------------
  # Collection creation
  # ---------------------------------------------------------------------------

  describe "collection creation" do
    test "creates the collection on startup when Typesense is ready", %{bypass: bypass} do
      parent = self()

      Bypass.stub(bypass, "GET", "/health", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"ok":true}))
      end)

      Bypass.expect_once(bypass, "POST", "/collections", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:collection_created, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, "{}")
      end)

      start_supervised!(SessionIndexer)
      assert_receive {:collection_created, schema}, 1_000
      assert schema["name"] == "test_sessions"
      assert Enum.any?(schema["fields"], &(&1["name"] == "content"))
      assert Enum.any?(schema["fields"], &(&1["name"] == "session_id"))
      assert Enum.any?(schema["fields"], &(&1["name"] == "agent_name"))
    end
  end
end
