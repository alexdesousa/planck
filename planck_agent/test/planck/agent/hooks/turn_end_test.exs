defmodule Planck.Agent.Hooks.TurnEndTest do
  use ExUnit.Case, async: false

  import Mox

  alias Planck.Agent
  alias Planck.Agent.Hooks.TurnEnd
  alias Planck.Agent.{Message, MockAI, Tool}
  alias Planck.AI.Model

  setup :set_mox_global
  setup :verify_on_exit!

  @model %Model{
    id: "test-model",
    name: "Test",
    provider: :anthropic,
    context_window: 100_000,
    max_tokens: 1_024
  }

  # ---------------------------------------------------------------------------
  # Test hook modules
  # ---------------------------------------------------------------------------

  defmodule DefaultHook do
    use Planck.Agent.Hooks.TurnEnd
  end

  defmodule HighThresholdHook do
    use Planck.Agent.Hooks.TurnEnd

    @impl true
    def reflect_threshold, do: 100
  end

  defmodule CustomTimeoutHook do
    use Planck.Agent.Hooks.TurnEnd

    @impl true
    def reflect_timeout, do: 60_000
  end

  # ---------------------------------------------------------------------------
  # use Planck.Agent.Hooks.TurnEnd — behaviour defaults
  # ---------------------------------------------------------------------------

  describe "use Planck.Agent.Hooks.TurnEnd" do
    test "provides default reflect_threshold/0" do
      assert DefaultHook.reflect_threshold() == TurnEnd.default_threshold()
    end

    test "provides default reflect_timeout/0" do
      assert DefaultHook.reflect_timeout() == TurnEnd.default_timeout()
    end

    test "reflect/2 returns :ok by default" do
      assert DefaultHook.reflect("agent-1", []) == :ok
    end

    test "reflect_threshold/0 can be overridden" do
      assert HighThresholdHook.reflect_threshold() == 100
    end

    test "reflect_timeout/0 can be overridden" do
      assert CustomTimeoutHook.reflect_timeout() == 60_000
    end
  end

  # ---------------------------------------------------------------------------
  # reflect/4 — nil module
  # ---------------------------------------------------------------------------

  describe "reflect/4 with nil module" do
    test "returns :ok immediately" do
      assert TurnEnd.reflect(nil, "agent-1", [], nil) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # reflect/4 — local dispatch
  # ---------------------------------------------------------------------------

  defp tool_call_messages(count) do
    calls = Enum.map(1..count, fn i -> {:tool_call, "id-#{i}", "bash", %{}} end)
    result = Enum.map(1..count, fn i -> {:tool_result, "id-#{i}", "ok"} end)

    [
      Message.new(:assistant, calls),
      Message.new(:tool_result, result)
    ]
  end

  describe "reflect/4 local dispatch" do
    defmodule RecordingHook do
      use Planck.Agent.Hooks.TurnEnd

      @impl true
      def reflect_threshold, do: 2

      @impl true
      def reflect(agent_id, turn_messages) do
        counter = :persistent_term.get({__MODULE__, :counter}, nil)
        if counter, do: :counters.add(counter, 1, 1)
        parent = :persistent_term.get({__MODULE__, :parent}, nil)
        if parent, do: send(parent, {:reflected, agent_id, length(turn_messages)})
        :ok
      end
    end

    setup do
      counter = :counters.new(1, [])
      :persistent_term.put({RecordingHook, :counter}, counter)
      :persistent_term.put({RecordingHook, :parent}, self())

      on_exit(fn ->
        :persistent_term.erase({RecordingHook, :counter})
        :persistent_term.erase({RecordingHook, :parent})
      end)

      %{counter: counter}
    end

    test "does not call reflect/2 when below threshold" do
      messages = tool_call_messages(1)
      assert TurnEnd.reflect(RecordingHook, "a1", messages, nil) == :ok
      refute_received {:reflected, _, _}
    end

    test "calls reflect/2 when threshold is met", %{counter: counter} do
      messages = tool_call_messages(2)
      assert TurnEnd.reflect(RecordingHook, "a1", messages, nil) == :ok
      assert_receive {:reflected, "a1", _}
      assert :counters.get(counter, 1) == 1
    end

    test "calls reflect/2 when threshold is exceeded", %{counter: counter} do
      messages = tool_call_messages(5)
      assert TurnEnd.reflect(RecordingHook, "a1", messages, nil) == :ok
      assert_receive {:reflected, "a1", _}
      assert :counters.get(counter, 1) == 1
    end

    test "agent_id is forwarded to reflect/2" do
      messages = tool_call_messages(5)
      TurnEnd.reflect(RecordingHook, "specific-id", messages, nil)
      assert_receive {:reflected, "specific-id", _}
    end

    test "turn_messages are forwarded to reflect/2" do
      messages = tool_call_messages(5)
      TurnEnd.reflect(RecordingHook, "a1", messages, nil)
      assert_receive {:reflected, "a1", 2}
    end
  end

  # ---------------------------------------------------------------------------
  # reflect/4 — remote dispatch (same-node simulation)
  # ---------------------------------------------------------------------------

  defmodule RemoteHook do
    use Planck.Agent.Hooks.TurnEnd

    @impl true
    def reflect_threshold, do: 1

    @impl true
    def reflect(_agent_id, _turn_messages) do
      parent = :persistent_term.get({__MODULE__, :parent}, nil)
      if parent, do: send(parent, :remote_reflected)
      :ok
    end
  end

  describe "reflect/4 remote" do
    setup do
      :persistent_term.put({RemoteHook, :parent}, self())
      on_exit(fn -> :persistent_term.erase({RemoteHook, :parent}) end)
      :ok
    end

    test "sidecar_node: nil uses local dispatch" do
      messages = tool_call_messages(2)
      assert TurnEnd.reflect(RemoteHook, "a1", messages, nil) == :ok
      assert_receive :remote_reflected
    end

    test "dispatches via RPC on the same node" do
      messages = tool_call_messages(2)
      assert TurnEnd.reflect(RemoteHook, "a1", messages, Node.self()) == :ok
      assert_receive :remote_reflected
    end

    test "returns :ok when RPC fails (bad node)" do
      messages = tool_call_messages(2)
      assert TurnEnd.reflect(RemoteHook, "a1", messages, :nonexistent@localhost) == :ok
    end

    test "does not call reflect/2 below threshold even over RPC" do
      assert TurnEnd.reflect(RemoteHook, "a1", [], Node.self()) == :ok
      refute_received :remote_reflected
    end
  end

  # ---------------------------------------------------------------------------
  # Integration with Agent
  # ---------------------------------------------------------------------------

  defp unique_id, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

  # Fires on every turn (threshold 0) — no tools needed.
  defmodule AlwaysHook do
    use Planck.Agent.Hooks.TurnEnd

    @impl true
    def reflect_threshold, do: 0

    @impl true
    def reflect(agent_id, _turn_messages) do
      parent = :persistent_term.get({__MODULE__, :parent}, nil)
      if parent, do: send(parent, {:hook_fired, agent_id})
      :ok
    end
  end

  # Fires only when >= 1 tool call in the turn.
  defmodule ToolHook do
    use Planck.Agent.Hooks.TurnEnd

    @impl true
    def reflect_threshold, do: 1

    @impl true
    def reflect(agent_id, _turn_messages) do
      parent = :persistent_term.get({__MODULE__, :parent}, nil)
      if parent, do: send(parent, {:hook_fired, agent_id})
      :ok
    end
  end

  defp make_tool(name) do
    Tool.new(
      name: name,
      description: "test tool",
      parameters: %{"type" => "object", "properties" => %{}},
      execute_fn: fn _agent_id, _id, _args -> {:ok, "done"} end
    )
  end

  describe "integration with Agent" do
    setup do
      :persistent_term.put({AlwaysHook, :parent}, self())
      :persistent_term.put({ToolHook, :parent}, self())

      on_exit(fn ->
        :persistent_term.erase({AlwaysHook, :parent})
        :persistent_term.erase({ToolHook, :parent})
      end)

      :ok
    end

    test "turn_end_hook: nil fires nothing" do
      stub(MockAI, :stream, fn _model, _context, _opts ->
        [{:text_delta, "ok"}, {:done, %{}}]
      end)

      agent = start_supervised!({Agent, id: unique_id(), model: @model, system_prompt: "hi"})
      Agent.subscribe(agent)
      Agent.prompt(agent, "go")
      assert_receive {:agent_event, :turn_end, _}, 1_000
      refute_received {:hook_fired, _}
    end

    test "hook does not fire when below threshold" do
      stub(MockAI, :stream, fn _model, _context, _opts ->
        [{:text_delta, "ok"}, {:done, %{}}]
      end)

      # ToolHook threshold is 1; no tools → 0 calls → should not fire
      agent =
        start_supervised!(
          {Agent, id: unique_id(), model: @model, system_prompt: "hi", turn_end_hook: ToolHook}
        )

      Agent.subscribe(agent)
      Agent.prompt(agent, "go")
      assert_receive {:agent_event, :turn_end, _}, 1_000
      refute_received {:hook_fired, _}
    end

    test "hook fires after a turn with enough tool calls" do
      tool = make_tool("noop")
      call_count = :counters.new(1, [])

      stub(MockAI, :stream, fn _model, _context, _opts ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if rem(n, 2) == 0 do
          [{:tool_call_complete, %{id: "tc1", name: "noop", args: %{}}}, {:done, %{}}]
        else
          [{:text_delta, "done"}, {:done, %{}}]
        end
      end)

      agent_id = unique_id()

      agent =
        start_supervised!(
          {Agent,
           id: agent_id,
           model: @model,
           system_prompt: "hi",
           tools: [tool],
           turn_end_hook: ToolHook}
        )

      Agent.subscribe(agent)
      Agent.prompt(agent, "go")
      assert_receive {:agent_event, :turn_end, _}, 2_000
      assert_receive {:hook_fired, ^agent_id}, 1_000
    end

    test "hook is called on every turn" do
      stub(MockAI, :stream, fn _model, _context, _opts ->
        [{:text_delta, "ok"}, {:done, %{}}]
      end)

      agent_id = unique_id()

      agent =
        start_supervised!(
          {Agent, id: agent_id, model: @model, system_prompt: "hi", turn_end_hook: AlwaysHook}
        )

      Agent.subscribe(agent)

      Agent.prompt(agent, "turn 1")
      assert_receive {:agent_event, :turn_end, _}, 1_000
      assert_receive {:hook_fired, ^agent_id}, 1_000

      Agent.prompt(agent, "turn 2")
      assert_receive {:agent_event, :turn_end, _}, 1_000
      assert_receive {:hook_fired, ^agent_id}, 1_000
    end
  end
end
