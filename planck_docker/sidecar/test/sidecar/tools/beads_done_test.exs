defmodule Sidecar.Tools.BeadsDoneTest do
  use ExUnit.Case, async: true

  import Mox

  alias Planck.Agent
  alias Planck.Agent.MockAI
  alias Planck.AI.Model
  alias Sidecar.Tools.BeadsDone

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
       id: id, model: @model, system_prompt: "hi", name: "worker-1", team_name: "deep-thought"},
      id: id
    )

    id
  end

  describe "tool/0" do
    test "has correct name and required params" do
      tool = BeadsDone.tool()
      assert tool.name == "bd_done"
      assert tool.parameters["required"] == ["issue_id"]
    end
  end

  describe "execute_fn" do
    test "closes with the calling agent's stable identity as actor", %{
      bypass: bypass,
      client: client,
      instance: instance
    } do
      agent_id = start_agent()
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v0/beads/issues/bd-1:close", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:body, Jason.decode!(raw)})
        json(conn, 200, %{"already_closed" => false})
      end)

      Bypass.stub(bypass, "GET", "/v0/beads/issues", &json(&1, 200, %{"items" => []}))

      Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "sidecar:widget:#{instance}")
      tool = BeadsDone.tool(client: client, instance: instance)

      assert {:ok, "Marked bd-1 as done.", %{ui: ui}} =
               tool.execute_fn.(agent_id, "tc1", %{"issue_id" => "bd-1"})

      assert ui == %{kind: :widget, label: "View kanban board", widget: "beads-board", data: nil}
      assert_receive {:body, %{"actor" => "deep-thought:worker-1"}}
      assert_receive {:widget_rendered, ^instance, _html}
    end

    test "reports an idempotent re-close distinctly", %{bypass: bypass, client: client} do
      agent_id = start_agent()

      Bypass.stub(
        bypass,
        "POST",
        "/v0/beads/issues/bd-1:close",
        &json(&1, 200, %{"already_closed" => true})
      )

      tool = BeadsDone.tool(client: client)

      assert {:ok, "bd-1 was already closed.", %{ui: _}} =
               tool.execute_fn.(agent_id, "tc1", %{"issue_id" => "bd-1"})
    end

    test "returns an error tuple on failure", %{bypass: bypass, client: client} do
      agent_id = start_agent()

      Bypass.stub(
        bypass,
        "POST",
        "/v0/beads/issues/bd-1:close",
        &json(&1, 500, %{"error" => "boom"})
      )

      tool = BeadsDone.tool(client: client)
      assert {:error, message} = tool.execute_fn.(agent_id, "tc1", %{"issue_id" => "bd-1"})
      assert message =~ "Failed to close bd-1"
    end

    # No Bypass expectation set up at all — if the tool tried to reach the
    # close endpoint anyway, Bypass itself would fail this test.
    test "errors out before ever calling the API when the caller can't be identified", %{
      client: client
    } do
      tool = BeadsDone.tool(client: client)

      assert {:error, message} =
               tool.execute_fn.("ghost-agent-id", "tc1", %{"issue_id" => "bd-1"})

      assert message =~ "identity"
    end
  end
end
