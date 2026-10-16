defmodule Planck.Headless.SessionApprovalTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  import Mox
  setup :set_mox_global
  setup :verify_on_exit!

  alias Planck.Agent
  alias Planck.Agent.{MockAI, Session, Tool}
  alias Planck.AI.{Context, Model}
  alias Planck.Headless

  @model %Model{
    id: "llama3.2",
    name: "Llama 3.2",
    provider: :openai,
    context_window: 4_096,
    max_tokens: 2_048
  }

  defmodule ParkGate do
    use Planck.Agent.Hooks.ToolStart

    @impl true
    def proceed(_agent_id, "bash", _args), do: {:await_approval, "needs a human"}
    def proceed(_agent_id, _tool, _args), do: :ok
  end

  setup %{tmp_dir: dir} do
    sessions_dir = Path.join(dir, "sessions")
    File.mkdir_p!(sessions_dir)

    session_id = "sess-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"
    {:ok, _} = Session.start(session_id, name: "test", dir: sessions_dir)

    on_exit(fn ->
      Session.stop(session_id)
      File.rm_rf!(sessions_dir)
    end)

    %{session_id: session_id}
  end

  defp start_agent(opts) do
    id = "agent-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"
    defaults = [id: id, model: @model, system_prompt: "You are helpful."]
    start_supervised!({Agent, Keyword.merge(defaults, opts)})
    id
  end

  defp register_agent(session_id, name, agent_id) do
    :ok = Session.save_metadata(session_id, %{"agent_ids" => Jason.encode!(%{name => agent_id})})
  end

  defp bash_tool do
    Tool.new(
      name: "bash",
      description: "bash",
      parameters: %{},
      execute_fn: fn _, _, _ -> {:ok, "ran"} end
    )
  end

  describe inspect(&Headless.list_pending_approvals/2) do
    test "returns an empty list when nothing is parked", %{session_id: sid} do
      aid = start_agent(session_id: sid)
      register_agent(sid, "builder", aid)

      assert {:ok, []} = Headless.list_pending_approvals(sid, aid)
    end

    test "rejects agents outside the session", %{session_id: sid} do
      aid = start_agent(session_id: sid)
      register_agent(sid, "builder", aid)

      assert {:error, :agent_not_in_session} = Headless.list_pending_approvals(sid, "ghost")
      assert {:error, :agent_not_in_session} = Headless.approve_tool_call(sid, "ghost", "c1")
      assert {:error, :agent_not_in_session} = Headless.deny_tool_call(sid, "ghost", "c1")
    end

    test "returns :agent_not_found for unknown sessions" do
      assert {:error, :agent_not_found} = Headless.list_pending_approvals("nope", "ghost")
    end
  end

  describe inspect({&Headless.approve_tool_call/3, &Headless.deny_tool_call/4}) do
    test "unknown calls fail with :not_found", %{session_id: sid} do
      aid = start_agent(session_id: sid)
      register_agent(sid, "builder", aid)

      assert {:error, :not_found} = Headless.approve_tool_call(sid, aid, "c1")
      assert {:error, :not_found} = Headless.deny_tool_call(sid, aid, "c1")
      assert {:error, :not_found} = Headless.deny_tool_call(sid, aid, "c1", "reason")
    end

    test "approve through Headless runs the parked call", %{session_id: sid} do
      stub(MockAI, :stream, fn _model, %Context{messages: msgs}, _opts ->
        if Enum.any?(msgs, &match?(%{role: :tool_result}, &1)) do
          [{:done, %{}}]
        else
          [{:tool_call_complete, %{id: "c1", name: "bash", args: %{}}}, {:done, %{}}]
        end
      end)

      aid = start_agent(session_id: sid, tools: [bash_tool()], tool_start_hook: ParkGate)
      register_agent(sid, "builder", aid)

      {:ok, agent} = Agent.whereis(aid)
      Agent.subscribe(agent)
      Agent.prompt(agent, "run it")

      assert_receive {:agent_event, :tool_blocked, %{mode: :await_approval}}, 1_000

      assert {:ok, [%{call_id: "c1", tool_name: "bash", reason: "needs a human"}]} =
               Headless.list_pending_approvals(sid, aid)

      assert :ok = Headless.approve_tool_call(sid, aid, "c1")
      assert_receive {:agent_event, :tool_end, %{name: "bash", error: false}}, 1_000
      assert_receive {:agent_event, :turn_end, _}, 2_000
      assert {:ok, []} = Headless.list_pending_approvals(sid, aid)
      assert {:error, :not_found} = Headless.approve_tool_call(sid, aid, "c1")
    end

    test "deny through Headless completes the error", %{session_id: sid} do
      stub(MockAI, :stream, fn _model, %Context{messages: msgs}, _opts ->
        if Enum.any?(msgs, &match?(%{role: :tool_result}, &1)) do
          [{:done, %{}}]
        else
          [{:tool_call_complete, %{id: "c1", name: "bash", args: %{}}}, {:done, %{}}]
        end
      end)

      aid = start_agent(session_id: sid, tools: [bash_tool()], tool_start_hook: ParkGate)
      register_agent(sid, "builder", aid)

      {:ok, agent} = Agent.whereis(aid)
      Agent.subscribe(agent)
      Agent.prompt(agent, "run it")

      assert_receive {:agent_event, :tool_blocked, %{mode: :await_approval}}, 1_000
      assert :ok = Headless.deny_tool_call(sid, aid, "c1", "not now")
      assert_receive {:agent_event, :tool_end, %{name: "bash", error: true}}, 1_000
      assert_receive {:agent_event, :turn_end, _}, 2_000
    end
  end

  describe inspect(&Headless.list_all_pending_approvals/1) do
    test "aggregates parked calls across agents with agent ids", %{session_id: sid} do
      stub(MockAI, :stream, fn _model, %Context{messages: msgs}, _opts ->
        if Enum.any?(msgs, &match?(%{role: :tool_result}, &1)) do
          [{:done, %{}}]
        else
          [{:tool_call_complete, %{id: "c1", name: "bash", args: %{}}}, {:done, %{}}]
        end
      end)

      aid1 = start_agent(session_id: sid, tools: [bash_tool()], tool_start_hook: ParkGate)
      aid2 = start_agent(session_id: sid, tools: [bash_tool()], tool_start_hook: ParkGate)
      register_agent(sid, "builder", aid1)

      :ok =
        Session.save_metadata(
          sid,
          %{"agent_ids" => Jason.encode!(%{"builder" => aid1, "worker" => aid2})}
        )

      {:ok, agent1} = Agent.whereis(aid1)
      {:ok, agent2} = Agent.whereis(aid2)
      Agent.subscribe(agent1)
      Agent.subscribe(agent2)
      Agent.prompt(agent1, "run it")
      Agent.prompt(agent2, "run it")

      assert_receive {:agent_event, :tool_blocked, %{mode: :await_approval}}, 1_000
      assert_receive {:agent_event, :tool_blocked, %{mode: :await_approval}}, 1_000

      assert {:ok, approvals} = Headless.list_all_pending_approvals(sid)
      assert length(approvals) == 2
      assert Enum.all?(approvals, &(&1.call_id == "c1" and &1.tool_name == "bash"))

      assert Enum.map(approvals, & &1.agent_id) |> Enum.sort() ==
               Enum.sort([aid1, aid2])
    end

    test "returns an empty list when nothing is parked", %{session_id: sid} do
      aid = start_agent(session_id: sid)
      register_agent(sid, "builder", aid)

      assert {:ok, []} = Headless.list_all_pending_approvals(sid)
    end
  end
end
