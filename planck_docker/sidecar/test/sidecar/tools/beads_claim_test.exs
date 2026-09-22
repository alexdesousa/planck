defmodule Sidecar.Tools.BeadsClaimTest do
  use ExUnit.Case, async: true

  import Mox

  alias Planck.Agent
  alias Planck.Agent.MockAI
  alias Planck.AI.Model
  alias Sidecar.Tools.BeadsClaim

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
      tool = BeadsClaim.tool()
      assert tool.name == "bd_claim"
      assert tool.parameters["required"] == ["issue_id"]
    end
  end

  describe "execute_fn" do
    test "claims with the calling agent's stable identity as actor, no assignee field", %{
      bypass: bypass,
      client: client,
      instance: instance
    } do
      agent_id = start_agent()
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v0/beads/issues/bd-1:claim", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:body, Jason.decode!(raw)})
        json(conn, 200, %{"already_claimed" => false})
      end)

      Bypass.stub(bypass, "GET", "/v0/beads/issues", &json(&1, 200, %{"items" => []}))

      Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "sidecar:widget:#{instance}")
      tool = BeadsClaim.tool(client: client, instance: instance)

      assert {:ok, "Claimed bd-1.", %{ui: _}} =
               tool.execute_fn.(agent_id, "tc1", %{"issue_id" => "bd-1"})

      assert_receive {:body, body}
      assert body == %{"actor" => "deep-thought:orchestrator"}
      assert_receive {:widget_rendered, ^instance, _html}
    end

    test "includes the issue's description from ClaimResponse — bd_ready only showed the title",
         %{bypass: bypass, client: client} do
      agent_id = start_agent()

      Bypass.stub(bypass, "POST", "/v0/beads/issues/bd-1:claim", fn conn ->
        json(conn, 200, %{
          "already_claimed" => false,
          "issue" => %{
            "id" => "bd-1",
            "title" => "Fix the thing",
            "description" => "Full context here."
          }
        })
      end)

      Bypass.stub(bypass, "GET", "/v0/beads/issues", &json(&1, 200, %{"items" => []}))

      tool = BeadsClaim.tool(client: client)

      assert {:ok, "Claimed bd-1.\n\nFull context here.", %{ui: _}} =
               tool.execute_fn.(agent_id, "tc1", %{"issue_id" => "bd-1"})
    end

    test "reports an idempotent re-claim by the same actor distinctly", %{
      bypass: bypass,
      client: client
    } do
      agent_id = start_agent()

      Bypass.stub(
        bypass,
        "POST",
        "/v0/beads/issues/bd-1:claim",
        &json(&1, 200, %{"already_claimed" => true})
      )

      Bypass.stub(bypass, "GET", "/v0/beads/issues", &json(&1, 200, %{"items" => []}))

      tool = BeadsClaim.tool(client: client)

      assert {:ok, "You already have bd-1 claimed.", %{ui: _}} =
               tool.execute_fn.(agent_id, "tc1", %{"issue_id" => "bd-1"})
    end

    test "reports a conflicting claim by someone else with their identity", %{
      bypass: bypass,
      client: client
    } do
      agent_id = start_agent()

      Bypass.stub(bypass, "POST", "/v0/beads/issues/bd-1:claim", fn conn ->
        json(conn, 409, %{"already_claimed" => true, "assignee" => "deep-thought:other-worker"})
      end)

      tool = BeadsClaim.tool(client: client)

      assert {:error, "bd-1 is already claimed by deep-thought:other-worker."} =
               tool.execute_fn.(agent_id, "tc1", %{"issue_id" => "bd-1"})
    end

    test "reports a not-claimable issue with its status", %{bypass: bypass, client: client} do
      agent_id = start_agent()

      Bypass.stub(bypass, "POST", "/v0/beads/issues/bd-1:claim", fn conn ->
        json(conn, 409, %{"not_claimable" => true, "issue_status" => "closed"})
      end)

      tool = BeadsClaim.tool(client: client)

      assert {:error, "bd-1 is not claimable (status: closed)."} =
               tool.execute_fn.(agent_id, "tc1", %{"issue_id" => "bd-1"})
    end

    # No Bypass expectation set up at all — if the tool tried to reach the
    # claim endpoint anyway, Bypass itself would fail this test.
    test "errors out before ever calling the API when the caller can't be identified", %{
      client: client
    } do
      tool = BeadsClaim.tool(client: client)

      assert {:error, message} =
               tool.execute_fn.("ghost-agent-id", "tc1", %{"issue_id" => "bd-1"})

      assert message =~ "identity"
    end
  end
end
