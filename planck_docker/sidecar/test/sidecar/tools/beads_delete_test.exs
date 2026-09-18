defmodule Sidecar.Tools.BeadsDeleteTest do
  use ExUnit.Case, async: true

  import Mox

  alias Planck.Agent
  alias Planck.Agent.MockAI
  alias Planck.AI.Model
  alias Sidecar.Tools.BeadsDelete

  setup :verify_on_exit!

  @model %Model{
    id: "test",
    name: "Test",
    provider: :anthropic,
    context_window: 100_000,
    max_tokens: 1_024
  }

  setup do
    bypass = Bypass.open()
    client = %{url: "http://localhost:#{bypass.port}", token: "test-token"}
    {:ok, bypass: bypass, client: client, instance: unique_id()}
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  defp unique_id, do: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

  defp start_agent do
    stub(MockAI, :stream, fn _m, _c, _o -> [{:text_delta, "ok"}, {:done, %{}}] end)
    id = unique_id()

    start_supervised!(
      {Agent,
       id: id, model: @model, system_prompt: "hi", name: "orchestrator", team_name: "deep-thought"},
      id: id
    )

    id
  end

  describe "tool/0" do
    test "has correct name and required params" do
      tool = BeadsDelete.tool()
      assert tool.name == "bd_delete"
      assert tool.parameters["required"] == ["issue_id"]
    end
  end

  describe "execute_fn" do
    test "POSTs to the collection-level :delete method with a single-id array", %{
      bypass: bypass,
      client: client,
      instance: instance
    } do
      agent_id = start_agent()
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v0/beads/issues:delete", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:body, Jason.decode!(raw)})
        json(conn, 200, %{"deleted" => ["bd-1"]})
      end)

      Bypass.stub(bypass, "GET", "/v0/beads/issues", &json(&1, 200, %{"items" => []}))

      Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "sidecar:widget:#{instance}")
      tool = BeadsDelete.tool(client: client, instance: instance)

      assert {:ok, "Deleted bd-1.", %{ui: _}} =
               tool.execute_fn.(agent_id, "tc1", %{"issue_id" => "bd-1"})

      assert_receive {:body, body}
      assert body == %{"ids" => ["bd-1"], "actor" => "deep-thought:orchestrator"}
      assert_receive {:widget_rendered, ^instance, _html}
    end

    test "returns an error tuple on failure", %{bypass: bypass, client: client} do
      agent_id = start_agent()
      Bypass.stub(bypass, "POST", "/v0/beads/issues:delete", &json(&1, 500, %{"error" => "boom"}))

      tool = BeadsDelete.tool(client: client)
      assert {:error, message} = tool.execute_fn.(agent_id, "tc1", %{"issue_id" => "bd-1"})
      assert message =~ "Failed to delete bd-1"
    end
  end
end
