defmodule Sidecar.Tools.BeadsReadyTest do
  use ExUnit.Case, async: false

  alias Sidecar.{Config, Tools.BeadsReady}

  setup do
    bypass = Bypass.open()
    Application.put_env(:sidecar, :beads_url, "http://localhost:#{bypass.port}")
    Application.put_env(:sidecar, :beads_token, "test-token")
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

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  describe "tool/0" do
    test "has correct name and no required params" do
      tool = BeadsReady.tool()
      assert tool.name == "bd_ready"
      assert tool.parameters["properties"] == %{}
      assert tool.widget == Sidecar.Widgets.Beads
    end
  end

  describe "execute_fn" do
    test "calls the dedicated ready endpoint, not /v0/beads/issues", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v0/beads/ready", fn conn ->
        json(conn, 200, %{
          "items" => [
            %{"id" => "bd-1", "title" => "Fix the thing", "issue_type" => "bug", "priority" => 1}
          ]
        })
      end)

      tool = BeadsReady.tool()
      assert {:ok, text, %{ui: ui}} = tool.execute_fn.("agent-1", "tc1", %{})
      assert text =~ "bd-1: Fix the thing (bug, priority 1)"
      assert ui == %{kind: :widget, label: "View kanban board", widget: "beads-board", data: nil}
    end

    test "includes each bead's description — an agent deciding what to claim needs more than the title",
         %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v0/beads/ready", fn conn ->
        json(conn, 200, %{
          "items" => [
            %{
              "id" => "bd-1",
              "title" => "Fix the thing",
              "issue_type" => "bug",
              "priority" => 1,
              "description" => "The thing breaks when you click it twice."
            },
            %{
              "id" => "bd-2",
              "title" => "No description here",
              "issue_type" => "task",
              "priority" => 3
            }
          ]
        })
      end)

      tool = BeadsReady.tool()
      assert {:ok, text, _ui} = tool.execute_fn.("agent-1", "tc1", %{})

      assert [with_description, without_description] = String.split(text, "\n\n")

      assert with_description ==
               "bd-1: Fix the thing (bug, priority 1)\nThe thing breaks when you click it twice."

      assert without_description == "bd-2: No description here (task, priority 3)"
    end

    test "renders a friendly message when nothing is ready", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v0/beads/ready", &json(&1, 200, %{"items" => []}))

      tool = BeadsReady.tool()

      assert {:ok, "No beads are ready right now.", %{ui: _}} =
               tool.execute_fn.("agent-1", "tc1", %{})
    end

    test "returns an error tuple on failure", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/v0/beads/ready", &json(&1, 500, %{"error" => "boom"}))

      tool = BeadsReady.tool()
      assert {:error, message} = tool.execute_fn.("agent-1", "tc1", %{})
      assert message =~ "Failed to list ready beads"
    end
  end
end
