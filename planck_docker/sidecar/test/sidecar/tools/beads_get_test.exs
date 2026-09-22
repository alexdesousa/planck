defmodule Sidecar.Tools.BeadsGetTest do
  use ExUnit.Case, async: true

  alias Sidecar.Tools.BeadsGet

  setup do
    bypass = Bypass.open()
    client = %{url: "http://localhost:#{bypass.port}", token: "test-token"}
    {:ok, bypass: bypass, client: client}
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  describe "tool/1" do
    test "has correct name and required params" do
      tool = BeadsGet.tool()
      assert tool.name == "bd_get"
      assert tool.parameters["required"] == ["issue_id"]
    end
  end

  describe "execute_fn" do
    test "fetches current details, including a description edited since claim time", %{
      bypass: bypass,
      client: client
    } do
      Bypass.expect_once(bypass, "GET", "/v0/beads/issues/bd-1", fn conn ->
        json(conn, 200, %{
          "id" => "bd-1",
          "title" => "Fix the thing",
          "status" => "in_progress",
          "issue_type" => "bug",
          "priority" => 1,
          "description" => "Updated by a human after claim."
        })
      end)

      tool = BeadsGet.tool(client: client)
      assert {:ok, text, %{ui: ui}} = tool.execute_fn.("agent-1", "tc1", %{"issue_id" => "bd-1"})

      assert text ==
               "bd-1: Fix the thing (in_progress, bug, priority 1)\nUpdated by a human after claim."

      assert ui == %{kind: :widget, label: "View kanban board", widget: "beads-board", data: nil}
    end

    test "reports a missing issue distinctly", %{bypass: bypass, client: client} do
      Bypass.stub(
        bypass,
        "GET",
        "/v0/beads/issues/ghost",
        &json(&1, 404, %{"error" => "not_found"})
      )

      tool = BeadsGet.tool(client: client)

      assert {:error, "ghost was not found."} =
               tool.execute_fn.("agent-1", "tc1", %{"issue_id" => "ghost"})
    end

    test "returns a generic error tuple on other failures", %{bypass: bypass, client: client} do
      Bypass.stub(bypass, "GET", "/v0/beads/issues/bd-1", &json(&1, 500, %{"error" => "boom"}))

      tool = BeadsGet.tool(client: client)
      assert {:error, message} = tool.execute_fn.("agent-1", "tc1", %{"issue_id" => "bd-1"})
      assert message =~ "Failed to fetch bd-1"
    end
  end
end
