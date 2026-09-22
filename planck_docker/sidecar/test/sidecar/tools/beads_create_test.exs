defmodule Sidecar.Tools.BeadsCreateTest do
  use ExUnit.Case, async: true

  import Mox

  alias Planck.Agent
  alias Planck.Agent.MockAI
  alias Planck.AI.Model
  alias Sidecar.Tools.BeadsCreate

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
      tool = BeadsCreate.tool()
      assert tool.name == "bd_create"
      assert tool.parameters["required"] == ["title"]
    end
  end

  describe "execute_fn" do
    test "always sends issue_type: task, with the calling agent's identity as actor", %{
      bypass: bypass,
      client: client,
      instance: instance
    } do
      agent_id = start_agent()
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v0/beads/issues", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:body, Jason.decode!(raw)})
        json(conn, 201, %{"id" => "bd-2"})
      end)

      Bypass.stub(bypass, "GET", "/v0/beads/issues", &json(&1, 200, %{"items" => []}))

      Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "sidecar:widget:#{instance}")
      tool = BeadsCreate.tool(client: client, instance: instance)

      assert {:ok, "Created bd-2: Fix the thing", %{ui: _}} =
               tool.execute_fn.(agent_id, "tc1", %{"title" => "Fix the thing"})

      assert_receive {:body, body}

      assert body == %{
               "title" => "Fix the thing",
               "actor" => "deep-thought:orchestrator",
               "issue_type" => "task"
             }

      assert_receive {:widget_rendered, ^instance, _html}
    end

    test "returns an error tuple on failure", %{bypass: bypass, client: client} do
      agent_id = start_agent()
      Bypass.stub(bypass, "POST", "/v0/beads/issues", &json(&1, 500, %{"error" => "boom"}))

      tool = BeadsCreate.tool(client: client)
      assert {:error, message} = tool.execute_fn.(agent_id, "tc1", %{"title" => "x"})
      assert message =~ "Failed to create bead"
    end

    test "passes description and priority through when the model supplies them", %{
      bypass: bypass,
      client: client
    } do
      agent_id = start_agent()
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v0/beads/issues", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:body, Jason.decode!(raw)})
        json(conn, 201, %{"id" => "bd-2"})
      end)

      Bypass.stub(bypass, "GET", "/v0/beads/issues", &json(&1, 200, %{"items" => []}))

      tool = BeadsCreate.tool(client: client)

      args = %{"title" => "Fix the thing", "description" => "Full context.", "priority" => 0}
      assert {:ok, _, %{ui: _}} = tool.execute_fn.(agent_id, "tc1", args)

      assert_receive {:body, body}

      assert body == %{
               "title" => "Fix the thing",
               "actor" => "deep-thought:orchestrator",
               "issue_type" => "task",
               "description" => "Full context.",
               "priority" => 0
             }
    end

    # No Bypass expectation set up at all — if the tool tried to reach the
    # create endpoint anyway, Bypass itself would fail this test.
    test "errors out before ever calling the API when the caller can't be identified", %{
      client: client
    } do
      tool = BeadsCreate.tool(client: client)

      assert {:error, message} = tool.execute_fn.("ghost-agent-id", "tc1", %{"title" => "x"})
      assert message =~ "identity"
    end
  end
end
