defmodule Sidecar.Tools.UpdateMemoryTest do
  use ExUnit.Case, async: false

  alias Sidecar.{Config, Memory, Tools.UpdateMemory}

  setup do
    bypass = Bypass.open()
    Application.put_env(:sidecar, :typesense_url, "http://localhost:#{bypass.port}")
    Application.put_env(:sidecar, :typesense_api_key, "test-key")
    Application.put_env(:sidecar, :memory_collection, "test_memory")
    Config.reload_typesense_url()
    Config.reload_typesense_api_key()
    Config.reload_memory_collection()

    Bypass.stub(bypass, "GET", "/health", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"ok":true}))
    end)

    Bypass.stub(bypass, "POST", "/collections", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(409, "{}")
    end)

    memory = start_supervised!(Memory)
    :sys.get_state(memory)

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

  # ---------------------------------------------------------------------------
  # tool/0 — definition
  # ---------------------------------------------------------------------------

  describe "tool/0" do
    test "has correct name and required/optional params" do
      tool = UpdateMemory.tool()
      assert tool.name == "update_memory"
      assert tool.parameters["required"] == ["content"]
      assert Map.has_key?(tool.parameters["properties"], "content")
      assert Map.has_key?(tool.parameters["properties"], "action")
      assert tool.parameters["properties"]["action"]["enum"] == ["append", "overwrite"]
    end
  end

  # ---------------------------------------------------------------------------
  # append (default)
  # ---------------------------------------------------------------------------

  describe "append action" do
    test "writes new fact when no existing memory", %{bypass: bypass} do
      parent = self()

      Bypass.stub(bypass, "GET", "/collections/test_memory/documents/no-memory", fn conn ->
        Plug.Conn.resp(conn, 404, "{}")
      end)

      Bypass.expect_once(bypass, "POST", "/collections/test_memory/documents", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:upserted, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, "{}")
      end)

      tool = UpdateMemory.tool()

      assert {:ok, "Memory replaced."} =
               tool.execute_fn.("no-memory", "tc1", %{"content" => "First fact."})

      assert_receive {:upserted, doc}, 1_000
      assert doc["content"] == "First fact."
    end

    test "appends to existing memory", %{bypass: bypass} do
      parent = self()

      Bypass.stub(bypass, "GET", "/collections/test_memory/documents/has-memory", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"content" => "Fact one."}))
      end)

      Bypass.expect_once(bypass, "POST", "/collections/test_memory/documents", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:upserted, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, "{}")
      end)

      tool = UpdateMemory.tool()

      assert {:ok, "Memory replaced."} =
               tool.execute_fn.("has-memory", "tc1", %{"content" => "Fact two."})

      assert_receive {:upserted, doc}, 1_000
      assert doc["content"] =~ "Fact one."
      assert doc["content"] =~ "Fact two."
    end

    test "returns full combined content when size limit exceeded", %{bypass: bypass} do
      # memory_size counts chars per line — build content that exceeds 2200 per-line chars
      line = String.duplicate("x", 1_200)
      existing = Enum.join([line, line], "\n")

      Bypass.stub(bypass, "GET", "/collections/test_memory/documents/big-memory", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"content" => existing}))
      end)

      tool = UpdateMemory.tool()

      assert {:error, reason} =
               tool.execute_fn.("big-memory", "tc1", %{"content" => "New fact."})

      assert reason =~ "Memory is full"
      assert reason =~ "overwrite"
      assert reason =~ "New fact."
      # Existing content is included so the agent can summarize everything
      assert reason =~ line
    end

    test "explicit action: \"append\" behaves the same as default", %{bypass: bypass} do
      parent = self()

      Bypass.stub(bypass, "GET", "/collections/test_memory/documents/explicit-append", fn conn ->
        Plug.Conn.resp(conn, 404, "{}")
      end)

      Bypass.expect_once(bypass, "POST", "/collections/test_memory/documents", fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)
        send(parent, :upserted)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, "{}")
      end)

      tool = UpdateMemory.tool()

      assert {:ok, _} =
               tool.execute_fn.("explicit-append", "tc1", %{
                 "content" => "Fact.",
                 "action" => "append"
               })

      assert_receive :upserted, 1_000
    end

    test "returns error when write fails", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/collections/test_memory/documents/write-fail", fn conn ->
        Plug.Conn.resp(conn, 404, "{}")
      end)

      Bypass.stub(bypass, "POST", "/collections/test_memory/documents", fn conn ->
        Plug.Conn.resp(conn, 404, "not found")
      end)

      tool = UpdateMemory.tool()

      assert {:error, reason} =
               tool.execute_fn.("write-fail", "tc1", %{"content" => "fact"})

      assert reason =~ "Failed to update memory"
    end
  end

  # ---------------------------------------------------------------------------
  # overwrite
  # ---------------------------------------------------------------------------

  describe "overwrite action" do
    test "replaces memory without loading existing content", %{bypass: bypass} do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/collections/test_memory/documents", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:upserted, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, "{}")
      end)

      tool = UpdateMemory.tool()

      assert {:ok, "Memory replaced."} =
               tool.execute_fn.("any-key", "tc1", %{
                 "content" => "Consolidated summary.",
                 "action" => "overwrite"
               })

      assert_receive {:upserted, doc}, 1_000
      assert doc["content"] == "Consolidated summary."
    end

    test "overwrite is not subject to size limit", %{bypass: bypass} do
      parent = self()
      large = String.duplicate("y", 3_000)

      Bypass.expect_once(bypass, "POST", "/collections/test_memory/documents", fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)
        send(parent, :upserted)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, "{}")
      end)

      tool = UpdateMemory.tool()

      assert {:ok, "Memory replaced."} =
               tool.execute_fn.("any-key", "tc1", %{
                 "content" => large,
                 "action" => "overwrite"
               })

      assert_receive :upserted, 1_000
    end

    test "returns error when write fails", %{bypass: bypass} do
      Bypass.stub(bypass, "POST", "/collections/test_memory/documents", fn conn ->
        Plug.Conn.resp(conn, 404, "not found")
      end)

      tool = UpdateMemory.tool()

      assert {:error, reason} =
               tool.execute_fn.("any-key", "tc1", %{
                 "content" => "summary",
                 "action" => "overwrite"
               })

      assert reason =~ "Failed to update memory"
    end
  end
end
