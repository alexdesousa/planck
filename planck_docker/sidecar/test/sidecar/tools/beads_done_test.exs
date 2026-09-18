defmodule Sidecar.Tools.BeadsDoneTest do
  use ExUnit.Case, async: false

  import Mox

  alias Planck.Agent
  alias Planck.Agent.MockAI
  alias Planck.AI.Model
  alias Sidecar.{Config, Tools.BeadsDone}

  setup :set_mox_global
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
    test "closes with the calling agent's stable identity as actor", %{bypass: bypass} do
      agent_id = start_agent()
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v0/beads/issues/bd-1:close", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:body, Jason.decode!(raw)})
        json(conn, 200, %{"already_closed" => false})
      end)

      tool = BeadsDone.tool()

      assert {:ok, "Marked bd-1 as done.", %{ui: ui}} =
               tool.execute_fn.(agent_id, "tc1", %{"issue_id" => "bd-1"})

      assert ui == %{kind: :widget, label: "View kanban board", widget: "beads-board", data: nil}
      assert_receive {:body, %{"actor" => "deep-thought:worker-1"}}
    end

    test "reports an idempotent re-close distinctly", %{bypass: bypass} do
      agent_id = start_agent()

      Bypass.stub(
        bypass,
        "POST",
        "/v0/beads/issues/bd-1:close",
        &json(&1, 200, %{"already_closed" => true})
      )

      tool = BeadsDone.tool()

      assert {:ok, "bd-1 was already closed.", %{ui: _}} =
               tool.execute_fn.(agent_id, "tc1", %{"issue_id" => "bd-1"})
    end

    test "returns an error tuple on failure", %{bypass: bypass} do
      agent_id = start_agent()

      Bypass.stub(
        bypass,
        "POST",
        "/v0/beads/issues/bd-1:close",
        &json(&1, 500, %{"error" => "boom"})
      )

      tool = BeadsDone.tool()
      assert {:error, message} = tool.execute_fn.(agent_id, "tc1", %{"issue_id" => "bd-1"})
      assert message =~ "Failed to close bd-1"
    end
  end
end
