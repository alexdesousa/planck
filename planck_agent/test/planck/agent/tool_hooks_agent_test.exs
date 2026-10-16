defmodule Planck.Agent.ToolHooksAgentTest do
  use ExUnit.Case, async: false

  import Mox

  alias Planck.Agent
  alias Planck.Agent.{MockAI, Session, Tool}
  alias Planck.AI.{Context, Model}

  setup :set_mox_global
  setup :verify_on_exit!

  @model %Model{
    id: "llama3.2",
    name: "Llama 3.2",
    provider: :openai,
    context_window: 4_096,
    max_tokens: 2_048
  }

  defp unique_id, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

  defp start_agent(overrides) do
    defaults = [id: unique_id(), model: @model, system_prompt: "You are helpful."]
    start_supervised!({Agent, Keyword.merge(defaults, overrides)})
  end

  defp start_agent_with_session(overrides) do
    session_id = unique_id()
    dir = Path.join(System.tmp_dir!(), "planck_test_#{session_id}")
    {:ok, _} = Session.start(session_id, name: "test", dir: dir)

    on_exit(fn ->
      Session.stop(session_id)
      File.rm_rf!(dir)
    end)

    defaults = [id: unique_id(), model: @model, system_prompt: "helpful.", session_id: session_id]
    {start_supervised!({Agent, Keyword.merge(defaults, overrides)}), session_id}
  end

  defp stream_tool_once(call) do
    stub(MockAI, :stream, fn _model, %Context{messages: msgs}, _opts ->
      if Enum.any?(msgs, &match?(%{role: :tool_result}, &1)) do
        [{:done, %{}}]
      else
        [{:tool_call_complete, call}, {:done, %{}}]
      end
    end)
  end

  defmodule DenyBash do
    use Planck.Agent.Hooks.ToolStart

    @impl true
    def proceed(_agent_id, "bash", _args), do: {:deny, "destructive command"}
    def proceed(_agent_id, _tool, _args), do: :ok
  end

  defmodule ParkBash do
    use Planck.Agent.Hooks.ToolStart

    @impl true
    def proceed(_agent_id, "bash", _args), do: {:await_approval, "needs a human"}
    def proceed(_agent_id, _tool, _args), do: :ok
  end

  defmodule CountingParkGate do
    use Planck.Agent.Hooks.ToolStart

    @impl true
    def proceed(_agent_id, _tool, _args) do
      if counter = :persistent_term.get({__MODULE__, :counter}, nil) do
        :counters.add(counter, 1, 1)
      end

      {:await_approval, "needs a human"}
    end
  end

  defmodule OkUiTagger do
    use Planck.Agent.Hooks.ToolEnd

    @impl true
    def transform(_agent_id, _tool, _args, {:ok, text}) do
      {:ok, text, %{ui: %{kind: :text, text: "approved ui"}}}
    end

    def transform(_agent_id, _tool, _args, result), do: result
  end

  defmodule ErrorUiTagger do
    use Planck.Agent.Hooks.ToolEnd

    @impl true
    def transform(_agent_id, _tool, _args, {:error, reason}) do
      {:error, reason, %{ui: %{kind: :text, text: "side effect"}}}
    end

    def transform(_agent_id, _tool, _args, result), do: result
  end

  defmodule TurnObserver do
    use Planck.Agent.Hooks.TurnStart

    @impl true
    def notify(agent_id, session_id) do
      if parent = :persistent_term.get({__MODULE__, :parent}, nil) do
        send(parent, {:turn_started, agent_id, session_id})
      end

      :ok
    end
  end

  describe "ToolStart deny in a running agent" do
    test "execute_fn never runs, :tool_blocked broadcasts, and the turn completes" do
      parent = self()

      tool =
        Tool.new(
          name: "bash",
          description: "bash",
          parameters: %{},
          execute_fn: fn _agent_id, _id, _args ->
            send(parent, :executed)
            {:ok, "ran"}
          end
        )

      stream_tool_once(%{id: "c1", name: "bash", args: %{"command" => "rm -rf /"}})

      agent = start_agent(tools: [tool], tool_start_hook: DenyBash)
      Agent.subscribe(agent)
      Agent.prompt(agent, "wipe it")

      assert_receive {:agent_event, :tool_start, %{name: "bash"}}, 1_000

      assert_receive {:agent_event, :tool_blocked,
                      %{name: "bash", reason: "destructive command", mode: :deny}},
                     1_000

      assert_receive {:agent_event, :tool_end, %{name: "bash", error: true}}, 1_000
      assert_receive {:agent_event, :turn_end, _}, 2_000

      refute_received :executed

      state = Agent.get_state(agent)
      tool_result_msg = Enum.find(state.context.messages, &(&1.role == :tool_result))
      assert [{:tool_result, "c1", text}] = tool_result_msg.content
      assert text =~ "destructive command"
      assert text =~ "work around"
    end

    test "await_approval parks the call: :tool_blocked broadcasts and the turn pauses" do
      parent = self()

      tool =
        Tool.new(
          name: "bash",
          description: "bash",
          parameters: %{},
          execute_fn: fn _, _, _ ->
            send(parent, :executed)
            {:ok, "ran"}
          end
        )

      stream_tool_once(%{id: "c1", name: "bash", args: %{}})

      agent = start_agent(tools: [tool], tool_start_hook: ParkBash)
      Agent.subscribe(agent)
      Agent.prompt(agent, "run it")

      assert_receive {:agent_event, :tool_blocked, %{mode: :await_approval}}, 1_000
      refute_received :executed
      refute_received {:agent_event, :turn_end, _}

      assert Agent.get_state(agent).turn.status == :executing_tools

      assert [%{approved: false, tool_call: %{id: "c1", name: "bash"}}] =
               Agent.list_pending_approvals(agent)

      assert :ok = Agent.deny_tool_call(agent, "c1", "not now")

      assert_receive {:agent_event, :tool_end, %{name: "bash", error: true}}, 1_000
      assert_receive {:agent_event, :turn_end, _}, 2_000
      refute_received :executed
      assert [] = Agent.list_pending_approvals(agent)
    end
  end

  describe "ToolEnd error UI in a running agent" do
    test "an error triple persists a sibling {:custom, :ui} message" do
      ui = %{kind: :text, text: "side effect"}

      tool =
        Tool.new(
          name: "failer",
          description: "failer",
          parameters: %{},
          execute_fn: fn _agent_id, _id, _args -> {:error, "kaboom"} end
        )

      stream_tool_once(%{id: "c1", name: "failer", args: %{}})

      agent = start_agent(tools: [tool], tool_end_hook: ErrorUiTagger)
      Agent.subscribe(agent)
      Agent.prompt(agent, "fail please")

      assert_receive {:agent_event, :turn_end, _}, 2_000

      state = Agent.get_state(agent)

      tool_result_msg = Enum.find(state.context.messages, &(&1.role == :tool_result))
      assert [{:tool_result, "c1", text}] = tool_result_msg.content
      assert text =~ "kaboom"

      ui_msg = Enum.find(state.context.messages, &match?(%{role: {:custom, :ui}}, &1))
      assert ui_msg != nil
      assert ui_msg.metadata == %{tool_call_id: "c1", ui: ui}
    end
  end

  describe "TurnStart observer in a running agent" do
    test "notify fires in the background without affecting the turn" do
      :persistent_term.put({TurnObserver, :parent}, self())
      on_exit(fn -> :persistent_term.erase({TurnObserver, :parent}) end)

      stub(MockAI, :stream, fn _model, _ctx, _opts -> [{:text_delta, "ok"}, {:done, %{}}] end)

      agent = start_agent(turn_start_hook: TurnObserver)
      info = Agent.get_info(agent)
      Agent.subscribe(agent)
      Agent.prompt(agent, "hi")

      assert_receive {:agent_event, :turn_end, _}, 2_000
      assert_received {:turn_started, agent_id, _session}
      assert agent_id == info.id
    end
  end

  describe "approval loop" do
    setup do
      counter = :counters.new(1, [])
      :persistent_term.put({CountingParkGate, :counter}, counter)

      on_exit(fn -> :persistent_term.erase({CountingParkGate, :counter}) end)

      %{counter: counter}
    end

    test "approve runs the stored args, skips the gate, and completes the turn", %{
      counter: counter
    } do
      parent = self()

      tool =
        Tool.new(
          name: "bash",
          description: "bash",
          parameters: %{},
          execute_fn: fn _, _, args ->
            send(parent, {:args, args})
            {:ok, "ran"}
          end
        )

      stream_tool_once(%{id: "c1", name: "bash", args: %{"command" => "ls"}})

      agent = start_agent(tools: [tool], tool_start_hook: CountingParkGate)
      Agent.subscribe(agent)
      Agent.prompt(agent, "run it")

      assert_receive {:agent_event, :tool_blocked, %{mode: :await_approval}}, 1_000
      assert :counters.get(counter, 1) == 1

      assert :ok = Agent.approve_tool_call(agent, "c1")

      assert_receive {:args, %{"command" => "ls"}}, 1_000
      assert_receive {:agent_event, :tool_end, %{name: "bash", result: {:ok, "ran"}}}, 1_000
      assert_receive {:agent_event, :turn_end, _}, 2_000

      assert :counters.get(counter, 1) == 1
      assert [] = Agent.list_pending_approvals(agent)
      assert {:error, :not_found} = Agent.approve_tool_call(agent, "c1")
    end

    test "ToolEnd screens approved results" do
      tool =
        Tool.new(
          name: "bash",
          description: "bash",
          parameters: %{},
          execute_fn: fn _, _, _ -> {:ok, "ran"} end
        )

      stream_tool_once(%{id: "c1", name: "bash", args: %{}})

      agent = start_agent(tools: [tool], tool_start_hook: ParkBash, tool_end_hook: OkUiTagger)
      Agent.subscribe(agent)
      Agent.prompt(agent, "run it")

      assert_receive {:agent_event, :tool_blocked, %{mode: :await_approval}}, 1_000
      assert :ok = Agent.approve_tool_call(agent, "c1")
      assert_receive {:agent_event, :turn_end, _}, 2_000

      state = Agent.get_state(agent)

      ui_msg = Enum.find(state.context.messages, &match?(%{role: {:custom, :ui}}, &1))
      assert ui_msg != nil
      assert ui_msg.metadata == %{tool_call_id: "c1", ui: %{kind: :text, text: "approved ui"}}
    end

    test "deny completes a plain error with no UI and continues the turn" do
      tool =
        Tool.new(
          name: "bash",
          description: "bash",
          parameters: %{},
          execute_fn: fn _, _, _ -> {:ok, "ran"} end
        )

      stream_tool_once(%{id: "c1", name: "bash", args: %{}})

      agent = start_agent(tools: [tool], tool_start_hook: ParkBash)
      Agent.subscribe(agent)
      Agent.prompt(agent, "run it")

      assert_receive {:agent_event, :tool_blocked, %{mode: :await_approval}}, 1_000
      assert :ok = Agent.deny_tool_call(agent, "c1", "not now")

      assert_receive {:agent_event, :tool_end, %{name: "bash", error: true}}, 1_000
      assert_receive {:agent_event, :turn_end, _}, 2_000
      assert {:error, :not_found} = Agent.deny_tool_call(agent, "c1")

      state = Agent.get_state(agent)
      tool_result_msg = Enum.find(state.context.messages, &(&1.role == :tool_result))
      assert [{:tool_result, "c1", text}] = tool_result_msg.content
      assert text =~ "denied"
      assert text =~ "not now"

      assert Enum.all?(state.context.messages, &(not match?(%{role: {:custom, :ui}}, &1)))
    end

    test "deny with no reason reaches the model as the default denial" do
      tool =
        Tool.new(
          name: "bash",
          description: "bash",
          parameters: %{},
          execute_fn: fn _, _, _ -> {:ok, "ran"} end
        )

      stream_tool_once(%{id: "c1", name: "bash", args: %{}})

      agent = start_agent(tools: [tool], tool_start_hook: ParkBash)
      Agent.subscribe(agent)
      Agent.prompt(agent, "run it")

      assert_receive {:agent_event, :tool_blocked, %{mode: :await_approval}}, 1_000
      assert :ok = Agent.deny_tool_call(agent, "c1")

      assert_receive {:agent_event, :tool_end, %{name: "bash", error: true}}, 1_000
      assert_receive {:agent_event, :turn_end, _}, 2_000

      state = Agent.get_state(agent)
      tool_result_msg = Enum.find(state.context.messages, &(&1.role == :tool_result))
      assert [{:tool_result, "c1", text}] = tool_result_msg.content
      assert text =~ "Tool call denied."
    end

    test "unknown call ids fail with :not_found" do
      agent = start_agent(tools: [])

      assert {:error, :not_found} = Agent.approve_tool_call(agent, "nope")
      assert {:error, :not_found} = Agent.deny_tool_call(agent, "nope")
    end

    test "parallel parked calls resolve independently" do
      tool =
        Tool.new(
          name: "bash",
          description: "bash",
          parameters: %{},
          execute_fn: fn _, _, %{"command" => command} -> {:ok, "ran #{command}"} end
        )

      stub(MockAI, :stream, fn _model, %Context{messages: msgs}, _opts ->
        if Enum.any?(msgs, &match?(%{role: :tool_result}, &1)) do
          [{:done, %{}}]
        else
          [
            {:tool_call_complete, %{id: "c1", name: "bash", args: %{"command" => "one"}}},
            {:tool_call_complete, %{id: "c2", name: "bash", args: %{"command" => "two"}}},
            {:done, %{}}
          ]
        end
      end)

      agent = start_agent(tools: [tool], tool_start_hook: ParkBash)
      Agent.subscribe(agent)
      Agent.prompt(agent, "run both")

      assert_receive {:agent_event, :tool_blocked, %{id: "c1"}}, 1_000
      assert_receive {:agent_event, :tool_blocked, %{id: "c2"}}, 1_000
      assert length(Agent.list_pending_approvals(agent)) == 2

      assert :ok = Agent.approve_tool_call(agent, "c1")
      assert :ok = Agent.deny_tool_call(agent, "c2")

      assert_receive {:agent_event, :tool_end, %{id: "c1", result: {:ok, "ran one"}}}, 1_000
      assert_receive {:agent_event, :tool_end, %{id: "c2", error: true}}, 1_000
      assert_receive {:agent_event, :turn_end, _}, 2_000
      assert [] = Agent.list_pending_approvals(agent)
    end

    test "abort clears parked calls without executing" do
      parent = self()

      tool =
        Tool.new(
          name: "bash",
          description: "bash",
          parameters: %{},
          execute_fn: fn _, _, _ ->
            send(parent, :executed)
            {:ok, "ran"}
          end
        )

      stream_tool_once(%{id: "c1", name: "bash", args: %{}})

      agent = start_agent(tools: [tool], tool_start_hook: ParkBash)
      Agent.subscribe(agent)
      Agent.prompt(agent, "run it")

      assert_receive {:agent_event, :tool_blocked, %{mode: :await_approval}}, 1_000
      assert :ok = Agent.abort(agent)

      refute_received {:agent_event, :tool_end, _}
      refute_received :executed
      assert [] = Agent.list_pending_approvals(agent)
      assert Agent.get_state(agent).turn.status == :idle
      assert {:error, :not_found} = Agent.approve_tool_call(agent, "c1")
    end

    test "rewind clears parked calls without executing" do
      parent = self()

      tool =
        Tool.new(
          name: "bash",
          description: "bash",
          parameters: %{},
          execute_fn: fn _, _, _ ->
            send(parent, :executed)
            {:ok, "ran"}
          end
        )

      stream_tool_once(%{id: "c1", name: "bash", args: %{}})

      {agent, _session_id} = start_agent_with_session(tools: [tool], tool_start_hook: ParkBash)
      Agent.subscribe(agent)
      Agent.prompt(agent, "run it")

      assert_receive {:agent_event, :tool_blocked, %{mode: :await_approval}}, 1_000

      user_msg = Enum.find(Agent.get_state(agent).context.messages, &(&1.role == :user))
      assert is_integer(user_msg.id)

      Agent.rewind_to_message(agent, user_msg.id)

      assert [] = Agent.list_pending_approvals(agent)
      refute_received :executed
      assert {:error, :not_found} = Agent.approve_tool_call(agent, "c1")
    end
  end
end
