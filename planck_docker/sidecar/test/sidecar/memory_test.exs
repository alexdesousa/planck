defmodule Sidecar.MemoryTest do
  use ExUnit.Case, async: false

  alias Sidecar.{Config, Memory}

  setup do
    bypass = Bypass.open()
    Application.put_env(:sidecar, :typesense_url, "http://localhost:#{bypass.port}")
    Application.put_env(:sidecar, :typesense_api_key, "test-key")
    Application.put_env(:sidecar, :memory_collection, "test_memory")
    Config.reload_typesense_url()
    Config.reload_typesense_api_key()
    Config.reload_memory_collection()

    on_exit(fn ->
      Application.delete_env(:sidecar, :typesense_url)
      Application.delete_env(:sidecar, :typesense_api_key)
      Application.delete_env(:sidecar, :memory_collection)
      Config.reload_typesense_url()
      Config.reload_typesense_api_key()
      Config.reload_memory_collection()
    end)

    {:ok, bypass: bypass}
  end

  defp start_memory(bypass) do
    Bypass.stub(bypass, "GET", "/health", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"ok":true}))
    end)

    Bypass.stub(bypass, "POST", "/collections", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(409, "{}")
    end)

    pid = start_supervised!(Memory)
    :sys.get_state(pid)
    pid
  end

  # ---------------------------------------------------------------------------
  # Hooks.Prompt callback
  # ---------------------------------------------------------------------------

  describe "before_prompt/1" do
    test "returns nil when no memory is cached for session", %{bypass: bypass} do
      start_memory(bypass)
      assert Memory.before_prompt("unknown-session") == nil
    end

    test "returns cached content when ETS is populated", %{bypass: bypass} do
      start_memory(bypass)
      :ets.insert(:sidecar_memory, {"sess-1", "User prefers Elixir."})
      assert Memory.before_prompt("sess-1") == "User prefers Elixir."
    end
  end

  # ---------------------------------------------------------------------------
  # write/3
  # ---------------------------------------------------------------------------

  describe "write/3" do
    test "upserts to Typesense and updates ETS", %{bypass: bypass} do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/collections/test_memory/documents", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:upserted, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, "{}")
      end)

      start_memory(bypass)
      assert :ok = Memory.write("my-team:orchestrator", "sess-1", "Prefers short summaries.")

      assert_receive {:upserted, doc}, 1_000
      assert doc["id"] == "my-team:orchestrator"
      assert doc["content"] == "Prefers short summaries."
      assert Memory.before_prompt("sess-1") == "Prefers short summaries."
    end

    test "returns error when Typesense upsert fails", %{bypass: bypass} do
      Bypass.stub(bypass, "POST", "/collections/test_memory/documents", fn conn ->
        Plug.Conn.resp(conn, 404, "not found")
      end)

      start_memory(bypass)
      assert {:error, _} = Memory.write("team:agent", "sess-1", "content")
    end

    test "does not update ETS when session_id is nil", %{bypass: bypass} do
      Bypass.stub(bypass, "POST", "/collections/test_memory/documents", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, "{}")
      end)

      start_memory(bypass)
      assert :ok = Memory.write("team:agent", nil, "content")
      assert Memory.before_prompt(nil) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # :compacted event — refresh from Typesense
  # ---------------------------------------------------------------------------

  describe ":compacted event" do
    test "refreshes ETS from Typesense when memory exists", %{bypass: bypass} do
      parent = self()
      pid = start_memory(bypass)

      Bypass.expect_once(
        bypass,
        "GET",
        "/collections/test_memory/documents/my-team:orchestrator",
        fn conn ->
          body = Jason.encode!(%{"content" => "Refreshed memory."})
          send(parent, :fetch_done)

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, body)
        end
      )

      send(
        pid,
        {:agent_event, :compacted,
         %{session_id: "sess-1", agent_name: "orchestrator", team_name: "my-team"}}
      )

      assert_receive :fetch_done, 1_000
      Memory.flush()
      assert Memory.before_prompt("sess-1") == "Refreshed memory."
    end

    test "does nothing when memory document not found", %{bypass: bypass} do
      pid = start_memory(bypass)
      parent = self()

      Bypass.stub(bypass, "GET", "/collections/test_memory/documents/no-team:nobody", fn conn ->
        send(parent, :fetch_done)
        Plug.Conn.resp(conn, 404, "{}")
      end)

      send(
        pid,
        {:agent_event, :compacted,
         %{session_id: "sess-2", agent_name: "nobody", team_name: "no-team"}}
      )

      assert_receive :fetch_done, 1_000
      Memory.flush()
      assert Memory.before_prompt("sess-2") == nil
    end
  end

  # ---------------------------------------------------------------------------
  # :turn_end event — lazy load
  # ---------------------------------------------------------------------------

  describe ":turn_end event" do
    test "loads memory from Typesense on first turn (cache miss)", %{bypass: bypass} do
      parent = self()
      pid = start_memory(bypass)

      Bypass.expect_once(
        bypass,
        "GET",
        "/collections/test_memory/documents/my-team:builder",
        fn conn ->
          body = Jason.encode!(%{"content" => "Lazy loaded memory."})
          send(parent, :fetch_done)

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, body)
        end
      )

      send(
        pid,
        {:agent_event, :turn_end,
         %{session_id: "sess-3", agent_name: "builder", team_name: "my-team"}}
      )

      assert_receive :fetch_done, 1_000
      Memory.flush()
      assert Memory.before_prompt("sess-3") == "Lazy loaded memory."
    end

    test "skips Typesense fetch when ETS already has the session", %{bypass: bypass} do
      pid = start_memory(bypass)
      :ets.insert(:sidecar_memory, {"sess-4", "Already cached."})

      send(
        pid,
        {:agent_event, :turn_end,
         %{session_id: "sess-4", agent_name: "orchestrator", team_name: "my-team"}}
      )

      Memory.flush()
      assert Memory.before_prompt("sess-4") == "Already cached."
    end
  end

  # ---------------------------------------------------------------------------
  # Collection creation
  # ---------------------------------------------------------------------------

  describe "collection creation" do
    test "creates the collection on startup", %{bypass: bypass} do
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

      start_supervised!(Memory)
      assert_receive {:collection_created, schema}, 1_000
      assert schema["name"] == "test_memory"
      assert Enum.any?(schema["fields"], &(&1["name"] == "content"))
      assert Enum.any?(schema["fields"], &(&1["name"] == "agent_key"))
    end
  end
end
