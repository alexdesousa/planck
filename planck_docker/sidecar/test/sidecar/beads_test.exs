defmodule Sidecar.BeadsTest do
  use ExUnit.Case, async: false

  alias Sidecar.{Beads, Config}

  @token "test-beads-token"

  setup do
    bypass = Bypass.open()
    Application.put_env(:sidecar, :beads_url, "http://localhost:#{bypass.port}")
    Application.put_env(:sidecar, :beads_token, @token)
    Config.reload_beads_url()
    Config.reload_beads_token()

    on_exit(fn ->
      Application.delete_env(:sidecar, :beads_url)
      Application.delete_env(:sidecar, :beads_token)
      Config.reload_beads_url()
      Config.reload_beads_token()
    end)

    {:ok, bypass: bypass}
  end

  defp assert_auth(conn) do
    assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{@token}"]
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  defp decoded_body(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(raw), conn}
  end

  # ---------------------------------------------------------------------------
  # list/1
  # ---------------------------------------------------------------------------

  describe "list/1" do
    test "GETs /v0/beads/issues with params as query string", %{bypass: bypass} do
      parent = self()

      Bypass.expect_once(bypass, "GET", "/v0/beads/issues", fn conn ->
        assert_auth(conn)
        send(parent, {:query, conn.query_params})
        json(conn, 200, %{"items" => []})
      end)

      assert {:ok, %{"items" => []}} = Beads.list(status: "open")
      assert_receive {:query, %{"status" => "open"}}
    end

    test "returns an error tuple on a non-2xx status", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/v0/beads/issues", &json(&1, 500, %{"error" => "boom"}))
      assert {:error, {500, %{"error" => "boom"}}} = Beads.list()
    end
  end

  # ---------------------------------------------------------------------------
  # ready/1
  # ---------------------------------------------------------------------------

  describe "ready/1" do
    test "GETs the dedicated /v0/beads/ready endpoint, not /v0/beads/issues", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v0/beads/ready", fn conn ->
        assert_auth(conn)
        json(conn, 200, %{"items" => [%{"id" => "b1"}]})
      end)

      assert {:ok, %{"items" => [%{"id" => "b1"}]}} = Beads.ready()
    end
  end

  # ---------------------------------------------------------------------------
  # fetch/1
  # ---------------------------------------------------------------------------

  describe "fetch/1" do
    test "GETs the single-issue endpoint by exact id", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v0/beads/issues/bd-1", fn conn ->
        assert_auth(conn)
        json(conn, 200, %{"id" => "bd-1", "title" => "Fix the thing"})
      end)

      assert {:ok, %{"id" => "bd-1"}} = Beads.fetch("bd-1")
    end

    test "returns an error tuple for a missing issue", %{bypass: bypass} do
      Bypass.stub(
        bypass,
        "GET",
        "/v0/beads/issues/ghost",
        &json(&1, 404, %{"error" => "not_found"})
      )

      assert {:error, {404, %{"error" => "not_found"}}} = Beads.fetch("ghost")
    end
  end

  # ---------------------------------------------------------------------------
  # create/2
  # ---------------------------------------------------------------------------

  describe "create/2" do
    test "always sends issue_type, even though the schema marks it optional", %{bypass: bypass} do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v0/beads/issues", fn conn ->
        assert_auth(conn)
        {body, conn} = decoded_body(conn)
        send(parent, {:body, body})
        json(conn, 201, %{"id" => "b1"})
      end)

      assert {:ok, %{"id" => "b1"}} = Beads.create("Fix the thing", "agent-1")
      assert_receive {:body, body}
      assert body == %{"title" => "Fix the thing", "actor" => "agent-1", "issue_type" => "task"}
    end

    test "includes description/priority when given, omits them entirely otherwise", %{
      bypass: bypass
    } do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v0/beads/issues", fn conn ->
        {body, conn} = decoded_body(conn)
        send(parent, {:body, body})
        json(conn, 201, %{"id" => "b1"})
      end)

      assert {:ok, _} =
               Beads.create("Fix the thing", "agent-1", description: "Full context.", priority: 0)

      assert_receive {:body, body}

      assert body == %{
               "title" => "Fix the thing",
               "actor" => "agent-1",
               "issue_type" => "task",
               "description" => "Full context.",
               "priority" => 0
             }
    end

    test "omits description/priority keys entirely when not given — not the same as null", %{
      bypass: bypass
    } do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v0/beads/issues", fn conn ->
        {body, conn} = decoded_body(conn)
        send(parent, {:body, body})
        json(conn, 201, %{"id" => "b1"})
      end)

      assert {:ok, _} = Beads.create("Fix the thing", "agent-1")
      assert_receive {:body, body}
      refute Map.has_key?(body, "description")
      refute Map.has_key?(body, "priority")
    end
  end

  # ---------------------------------------------------------------------------
  # claim/2
  # ---------------------------------------------------------------------------

  describe "claim/2" do
    test "body is {actor} only — no assignee field", %{bypass: bypass} do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v0/beads/issues/b1:claim", fn conn ->
        assert_auth(conn)
        {body, conn} = decoded_body(conn)
        send(parent, {:body, body})
        json(conn, 200, %{"already_claimed" => false})
      end)

      assert {:ok, %{"already_claimed" => false}} = Beads.claim("b1", "agent-1")
      assert_receive {:body, body}
      assert body == %{"actor" => "agent-1"}
    end

    test "surfaces a 409 conflict as an error tuple", %{bypass: bypass} do
      Bypass.stub(bypass, "POST", "/v0/beads/issues/b1:claim", fn conn ->
        json(conn, 409, %{"already_claimed" => true, "assignee" => "someone-else"})
      end)

      assert {:error, {409, %{"already_claimed" => true, "assignee" => "someone-else"}}} =
               Beads.claim("b1", "agent-1")
    end
  end

  # ---------------------------------------------------------------------------
  # close/3
  # ---------------------------------------------------------------------------

  describe "close/3" do
    test "posts actor and reason", %{bypass: bypass} do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v0/beads/issues/b1:close", fn conn ->
        {body, conn} = decoded_body(conn)
        send(parent, {:body, body})
        json(conn, 200, %{"already_closed" => false})
      end)

      assert {:ok, _} = Beads.close("b1", "agent-1", reason: "done")
      assert_receive {:body, body}
      assert body == %{"actor" => "agent-1", "reason" => "done"}
    end

    test "reason defaults to nil when omitted", %{bypass: bypass} do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v0/beads/issues/b1:close", fn conn ->
        {body, conn} = decoded_body(conn)
        send(parent, {:body, body})
        json(conn, 200, %{"already_closed" => false})
      end)

      assert {:ok, _} = Beads.close("b1", "agent-1")
      assert_receive {:body, body}
      assert body == %{"actor" => "agent-1", "reason" => nil}
    end
  end

  # ---------------------------------------------------------------------------
  # delete/2
  # ---------------------------------------------------------------------------

  describe "delete/2" do
    test "POSTs to the collection-level :delete method, not DELETE /issues/{id}", %{
      bypass: bypass
    } do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v0/beads/issues:delete", fn conn ->
        assert_auth(conn)
        {body, conn} = decoded_body(conn)
        send(parent, {:body, body})
        json(conn, 200, %{"deleted" => ["b1", "b2"]})
      end)

      assert {:ok, %{"deleted" => ["b1", "b2"]}} = Beads.delete(["b1", "b2"], "agent-1")
      assert_receive {:body, body}
      assert body == %{"ids" => ["b1", "b2"], "actor" => "agent-1"}
    end
  end

  # ---------------------------------------------------------------------------
  # Connection failure
  # ---------------------------------------------------------------------------

  describe "connection failure" do
    test "returns {:error, reason} when beads is unreachable", %{bypass: bypass} do
      Bypass.down(bypass)
      assert {:error, _reason} = Beads.list()
    end
  end

  # ---------------------------------------------------------------------------
  # :client override
  # ---------------------------------------------------------------------------

  describe ":client override" do
    test "an explicit :client is used instead of Sidecar.Config, and never reaches it" do
      other_bypass = Bypass.open()

      Bypass.expect_once(other_bypass, "GET", "/v0/beads/issues", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer other-token"]
        json(conn, 200, %{"items" => []})
      end)

      client = %{url: "http://localhost:#{other_bypass.port}", token: "other-token"}
      assert {:ok, %{"items" => []}} = Beads.list(client: client)
    end

    test "extracting :client does not leak it into the query string", %{bypass: bypass} do
      parent = self()

      Bypass.expect_once(bypass, "GET", "/v0/beads/issues", fn conn ->
        send(parent, {:query, conn.query_params})
        json(conn, 200, %{"items" => []})
      end)

      client = %{url: "http://localhost:#{bypass.port}", token: @token}
      assert {:ok, _} = Beads.list(status: "open", client: client)
      assert_receive {:query, query}
      refute Map.has_key?(query, "client")
    end
  end

  # ---------------------------------------------------------------------------
  # broadcast_refresh/1
  # ---------------------------------------------------------------------------

  describe "broadcast_refresh/1" do
    test "broadcasts {:widget_rendered, id, html} on \"sidecar:widget:beads-board\" by default",
         %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/v0/beads/issues", &json(&1, 200, %{"items" => []}))
      Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "sidecar:widget:beads-board")

      assert :ok = Beads.broadcast_refresh()
      assert_receive {:widget_rendered, "beads-board", html}
      assert is_binary(html)
    end

    test ":instance overrides the topic and the id in the broadcast payload", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/v0/beads/issues", &json(&1, 200, %{"items" => []}))
      Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "sidecar:widget:test-xyz")

      assert :ok = Beads.broadcast_refresh(instance: "test-xyz")
      assert_receive {:widget_rendered, "test-xyz", _html}
    end

    test "a subscriber on the default topic does not see a differently-instanced broadcast", %{
      bypass: bypass
    } do
      Bypass.stub(bypass, "GET", "/v0/beads/issues", &json(&1, 200, %{"items" => []}))
      Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "sidecar:widget:beads-board")

      assert :ok = Beads.broadcast_refresh(instance: "test-xyz")
      refute_receive {:widget_rendered, _id, _html}
    end

    test ":client reaches the board's own re-fetch, not just a triggering write" do
      other_bypass = Bypass.open()

      Bypass.expect_once(other_bypass, "GET", "/v0/beads/issues", fn conn ->
        json(conn, 200, %{"items" => []})
      end)

      client = %{url: "http://localhost:#{other_bypass.port}", token: "other-token"}
      Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "sidecar:widget:beads-board")

      assert :ok = Beads.broadcast_refresh(client: client)
      assert_receive {:widget_rendered, "beads-board", _html}
    end
  end
end
