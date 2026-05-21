defmodule Sidecar.Tools.SessionSearchTest do
  use ExUnit.Case, async: false

  alias Sidecar.{Config, Tools.SessionSearch}

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

  defp hits_response(docs) do
    Jason.encode!(%{"hits" => Enum.map(docs, &%{"document" => &1})})
  end

  # ---------------------------------------------------------------------------

  describe "search/2" do
    test "returns formatted results with agent name and role", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/collections/test_sessions/documents/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          hits_response([
            %{
              "agent_name" => "orchestrator",
              "role" => "assistant",
              "content" => "Open config.json and add your provider."
            }
          ])
        )
      end)

      assert {:ok, result} = SessionSearch.search("configure provider")
      assert result =~ "orchestrator"
      assert result =~ "Open config.json"
    end

    test "returns multiple results separated by dividers", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/collections/test_sessions/documents/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          hits_response([
            %{
              "agent_name" => "orchestrator",
              "role" => "assistant",
              "content" => "First answer."
            },
            %{"agent_name" => "Builder", "role" => "assistant", "content" => "Second answer."}
          ])
        )
      end)

      assert {:ok, result} = SessionSearch.search("answer")
      assert result =~ "First answer."
      assert result =~ "Second answer."
      assert result =~ "---"
    end

    test "filters by agent_name when provided", %{bypass: bypass} do
      parent = self()

      Bypass.expect_once(bypass, "GET", "/collections/test_sessions/documents/search", fn conn ->
        send(parent, {:params, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, hits_response([]))
      end)

      SessionSearch.search("something", "orchestrator")

      assert_receive {:params, query_string}, 1_000
      assert query_string =~ "filter_by=agent_name%3A%3Dorchestrator"
    end

    test "does not include filter_by when agent_name is nil", %{bypass: bypass} do
      parent = self()

      Bypass.expect_once(bypass, "GET", "/collections/test_sessions/documents/search", fn conn ->
        send(parent, {:params, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, hits_response([]))
      end)

      SessionSearch.search("something", nil)

      assert_receive {:params, query_string}, 1_000
      refute query_string =~ "filter_by"
    end

    test "returns no results message when hits are empty", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/collections/test_sessions/documents/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, hits_response([]))
      end)

      assert {:ok, "No results found."} = SessionSearch.search("nothing here")
    end

    test "returns error on Typesense failure", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/collections/test_sessions/documents/search", fn conn ->
        Plug.Conn.resp(conn, 404, "not found")
      end)

      assert {:error, reason} = SessionSearch.search("query")
      assert reason =~ "404"
    end

    test "tool definition has correct name and required query param" do
      tool = SessionSearch.tool()
      assert tool.name == "session_search"
      assert tool.parameters["required"] == ["query"]
      assert Map.has_key?(tool.parameters["properties"], "query")
      assert Map.has_key?(tool.parameters["properties"], "agent_name")
    end
  end
end
