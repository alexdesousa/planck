defmodule Sidecar.Tools.BeadsListTest do
  use ExUnit.Case, async: true

  alias Sidecar.Tools.BeadsList

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
    test "has correct name and no required params" do
      tool = BeadsList.tool()
      assert tool.name == "bd_list"
      assert tool.parameters["properties"] == %{}
    end
  end

  describe "execute_fn" do
    test "passes all: true, so closed beads are included in the overview", %{
      bypass: bypass,
      client: client
    } do
      parent = self()

      Bypass.expect_once(bypass, "GET", "/v0/beads/issues", fn conn ->
        send(parent, {:query, conn.query_params})
        json(conn, 200, %{"items" => []})
      end)

      tool = BeadsList.tool(client: client)
      assert {:ok, _text, %{ui: _}} = tool.execute_fn.("agent-1", "tc1", %{})
      assert_receive {:query, %{"all" => "true"}}
    end

    test "groups items by status, in a fixed open/in_progress/blocked/closed order",
         %{bypass: bypass, client: client} do
      Bypass.expect_once(bypass, "GET", "/v0/beads/issues", fn conn ->
        json(conn, 200, %{
          "items" => [
            %{"id" => "bd-3", "title" => "Closed one", "status" => "closed"},
            %{"id" => "bd-1", "title" => "Open one", "status" => "open"},
            %{
              "id" => "bd-2",
              "title" => "Doing this",
              "status" => "in_progress",
              "assignee" => "team:worker-1"
            }
          ]
        })
      end)

      tool = BeadsList.tool(client: client)
      assert {:ok, text, _ui} = tool.execute_fn.("agent-1", "tc1", %{})

      assert text == """
             open (1):
               bd-1: Open one

             in_progress (1):
               bd-2: Doing this [team:worker-1]

             closed (1):
               bd-3: Closed one\
             """
    end

    test "sorts unrecognized custom statuses after the known ones, alphabetically",
         %{bypass: bypass, client: client} do
      Bypass.expect_once(bypass, "GET", "/v0/beads/issues", fn conn ->
        json(conn, 200, %{
          "items" => [
            %{"id" => "bd-2", "title" => "Zeta", "status" => "zzz-custom"},
            %{"id" => "bd-1", "title" => "Fresh", "status" => "open"},
            %{"id" => "bd-3", "title" => "Aye", "status" => "aaa-custom"}
          ]
        })
      end)

      tool = BeadsList.tool(client: client)
      assert {:ok, text, _ui} = tool.execute_fn.("agent-1", "tc1", %{})

      assert text == """
             open (1):
               bd-1: Fresh

             aaa-custom (1):
               bd-3: Aye

             zzz-custom (1):
               bd-2: Zeta\
             """
    end

    test "renders a friendly message when no beads exist yet", %{bypass: bypass, client: client} do
      Bypass.expect_once(bypass, "GET", "/v0/beads/issues", &json(&1, 200, %{"items" => []}))

      tool = BeadsList.tool(client: client)
      assert {:ok, "No beads exist yet.", %{ui: _}} = tool.execute_fn.("agent-1", "tc1", %{})
    end

    test "returns an error tuple on failure", %{bypass: bypass, client: client} do
      Bypass.stub(bypass, "GET", "/v0/beads/issues", &json(&1, 500, %{"error" => "boom"}))

      tool = BeadsList.tool(client: client)
      assert {:error, message} = tool.execute_fn.("agent-1", "tc1", %{})
      assert message =~ "Failed to list beads"
    end
  end
end
