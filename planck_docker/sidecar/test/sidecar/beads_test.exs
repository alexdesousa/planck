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

      assert {:ok, _} = Beads.close("b1", "agent-1", "done")
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
end
