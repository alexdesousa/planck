defmodule Planck.Agent.AgentTest do
  use ExUnit.Case, async: false

  import Mox

  alias Planck.Agent
  alias Planck.Agent.{Message, MockAI, Tool}
  alias Planck.AI.{Context, Model}

  setup :set_mox_global
  setup :verify_on_exit!

  @model %Model{
    id: "llama3.2",
    name: "Llama 3.2",
    provider: :ollama,
    context_window: 4_096,
    max_tokens: 2_048
  }

  defp start_agent(overrides \\ []) do
    defaults = [id: unique_id(), model: @model, system_prompt: "You are helpful."]
    opts = Keyword.merge(defaults, overrides)
    start_supervised!({Agent, opts})
  end

  defp unique_id, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

  defp stream_events(events) do
    stub(MockAI, :stream, fn _model, _context, _opts ->
      events
    end)
  end

  # --- init / get_state ---

  describe "init" do
    test "starts idle" do
      agent = start_agent()
      assert Agent.get_state(agent).status == :idle
    end

    test "role is :worker without spawn_agent tool" do
      agent = start_agent()
      assert Agent.get_state(agent).role == :worker
    end

    test "role is :orchestrator with spawn_agent tool" do
      spawn_tool =
        Tool.new(
          name: "spawn_agent",
          description: "spawn",
          parameters: %{},
          execute_fn: fn _, _ -> {:ok, :ok} end
        )

      agent = start_agent(tools: [spawn_tool])
      assert Agent.get_state(agent).role == :orchestrator
    end

    test "stores id, model, system_prompt" do
      id = unique_id()
      agent = start_agent(id: id, system_prompt: "test prompt")
      state = Agent.get_state(agent)
      assert state.id == id
      assert state.model == @model
      assert state.system_prompt == "test prompt"
    end
  end

  # --- subscribe / broadcast ---

  describe "subscribe/1" do
    test "subscriber receives turn_start on prompt" do
      stream_events([{:text_delta, "hi"}, {:done, %{}}])
      agent = start_agent()
      Agent.subscribe(agent)
      Agent.prompt(agent, "hello")
      assert_receive {:agent_event, :turn_start, _}, 1_000
    end

    test "subscriber receives text_delta events" do
      stream_events([{:text_delta, "hel"}, {:text_delta, "lo"}, {:done, %{}}])
      agent = start_agent()
      Agent.subscribe(agent)
      Agent.prompt(agent, "hi")
      assert_receive {:agent_event, :text_delta, %{text: "hel"}}, 1_000
      assert_receive {:agent_event, :text_delta, %{text: "lo"}}, 1_000
    end

    test "subscriber receives turn_end with assembled message" do
      stream_events([{:text_delta, "hello"}, {:done, %{}}])
      agent = start_agent()
      Agent.subscribe(agent)
      Agent.prompt(agent, "hi")
      assert_receive {:agent_event, :turn_end, %{message: msg}}, 1_000
      assert {:text, "hello"} in msg.content
    end

    test "broadcasts usage_delta with delta and running total on each done event" do
      stream_events([
        {:text_delta, "hi"},
        {:done, %{usage: %{input_tokens: 5, output_tokens: 10}}}
      ])

      agent = start_agent()
      Agent.subscribe(agent)
      Agent.prompt(agent, "hello")

      assert_receive {:agent_event, :usage_delta,
                      %{
                        delta: %{input_tokens: 5, output_tokens: 10},
                        total: %{input_tokens: 5, output_tokens: 10}
                      }},
                     1_000
    end

    test "turn_end includes accumulated token usage" do
      stream_events([
        {:text_delta, "hi"},
        {:done, %{usage: %{input_tokens: 5, output_tokens: 10}}}
      ])

      agent = start_agent()
      Agent.subscribe(agent)
      Agent.prompt(agent, "hello")

      assert_receive {:agent_event, :turn_end, %{usage: %{input_tokens: 5, output_tokens: 10}}},
                     1_000
    end

    test "subscriber receives error event on stream error" do
      stream_events([{:error, :connection_refused}])
      agent = start_agent()
      Agent.subscribe(agent)
      Agent.prompt(agent, "hi")
      assert_receive {:agent_event, :error, %{reason: :connection_refused}}, 1_000
    end
  end

  # --- prompt / status transitions ---

  describe "prompt/2" do
    test "appends user message and returns to idle after turn" do
      stream_events([{:text_delta, "done"}, {:done, %{}}])
      agent = start_agent()
      Agent.subscribe(agent)
      Agent.prompt(agent, "go")
      assert_receive {:agent_event, :turn_end, _}, 1_000
      state = Agent.get_state(agent)
      assert state.status == :idle
      assert length(state.messages) == 2
    end

    test "increments turn_index each prompt" do
      stream_events([{:text_delta, "ok"}, {:done, %{}}])
      stream_events([{:text_delta, "ok"}, {:done, %{}}])
      agent = start_agent()
      Agent.subscribe(agent)

      Agent.prompt(agent, "first")
      assert_receive {:agent_event, :turn_end, _}, 1_000

      Agent.prompt(agent, "second")
      assert_receive {:agent_event, :turn_end, _}, 1_000

      assert Agent.get_state(agent).turn_index == 2
    end

    test "content list is passed through" do
      stream_events([{:done, %{}}])
      agent = start_agent()
      Agent.subscribe(agent)
      Agent.prompt(agent, [{:text, "hello"}, {:image_url, "http://x.com/img.png"}])
      assert_receive {:agent_event, :turn_end, _}, 1_000
      [user_msg | _] = Agent.get_state(agent).messages
      assert user_msg.content == [{:text, "hello"}, {:image_url, "http://x.com/img.png"}]
    end
  end

  # --- tool calls ---

  describe "tool call round-trip" do
    test "executes tool and appends result message" do
      tool =
        Tool.new(
          name: "echo",
          description: "echo",
          parameters: %{},
          execute_fn: fn _id, %{"msg" => m} -> {:ok, m} end
        )

      call = %{id: "c1", name: "echo", args: %{"msg" => "ping"}}

      stub(MockAI, :stream, fn _model, %Context{messages: msgs}, _opts ->
        if Enum.any?(msgs, &match?(%{role: :tool_result}, &1)) do
          [{:done, %{}}]
        else
          [{:tool_call_complete, call}, {:done, %{}}]
        end
      end)

      agent = start_agent(tools: [tool])
      Agent.subscribe(agent)
      Agent.prompt(agent, "use echo")

      assert_receive {:agent_event, :tool_start, %{name: "echo"}}, 1_000
      assert_receive {:agent_event, :tool_end, %{name: "echo", result: {:ok, "ping"}}}, 1_000
      assert_receive {:agent_event, :turn_end, _}, 2_000

      state = Agent.get_state(agent)
      tool_result_msg = Enum.find(state.messages, &(&1.role == :tool_result))
      assert tool_result_msg != nil
    end

    test "unknown tool returns error result" do
      call = %{id: "c2", name: "ghost", args: %{}}

      stub(MockAI, :stream, fn _model, %Context{messages: msgs}, _opts ->
        if Enum.any?(msgs, &match?(%{role: :tool_result}, &1)) do
          [{:done, %{}}]
        else
          [{:tool_call_complete, call}, {:done, %{}}]
        end
      end)

      agent = start_agent()
      Agent.subscribe(agent)
      Agent.prompt(agent, "go")

      assert_receive {:agent_event, :tool_end, %{name: "ghost", error: true}}, 1_000
      assert_receive {:agent_event, :turn_end, _}, 2_000
    end
  end

  # --- abort ---

  describe "abort/1" do
    test "returns agent to idle" do
      stub(MockAI, :stream, fn _model, _ctx, _opts ->
        Process.sleep(5_000)
        []
      end)

      agent = start_agent()
      Agent.prompt(agent, "slow task")
      Process.sleep(50)
      Agent.abort(agent)
      assert Agent.get_state(agent).status == :idle
    end
  end

  # --- add_tool / remove_tool ---

  describe "add_tool/2 and remove_tool/2" do
    test "adds a tool at runtime" do
      agent = start_agent()

      tool =
        Tool.new(name: "t", description: "d", parameters: %{}, execute_fn: fn _, _ -> :ok end)

      Agent.add_tool(agent, tool)
      assert Map.has_key?(Agent.get_state(agent).tools, "t")
    end

    test "removes a tool at runtime" do
      tool =
        Tool.new(name: "t", description: "d", parameters: %{}, execute_fn: fn _, _ -> :ok end)

      agent = start_agent(tools: [tool])
      Agent.remove_tool(agent, "t")
      refute Map.has_key?(Agent.get_state(agent).tools, "t")
    end
  end

  # --- on_compact ---

  describe "on_compact hook" do
    test "compact function is called before LLM turn" do
      parent = self()

      compact_fn = fn messages ->
        send(parent, {:compacted, length(messages)})
        :skip
      end

      stream_events([{:text_delta, "ok"}, {:done, %{}}])
      agent = start_agent(on_compact: compact_fn)
      Agent.subscribe(agent)
      Agent.prompt(agent, "hello")
      assert_receive {:compacted, 1}, 1_000
      assert_receive {:agent_event, :turn_end, _}, 1_000
    end

    test "compacted summary is inserted into messages and sent to LLM" do
      summary_msg = Message.new({:custom, :summary}, [{:text, "Past summary."}])

      compact_fn = fn messages ->
        kept = Enum.take(messages, -1)
        {:compact, summary_msg, kept}
      end

      stream_events([{:text_delta, "ok"}, {:done, %{}}])
      agent = start_agent(on_compact: compact_fn)
      Agent.subscribe(agent)
      Agent.prompt(agent, "hello")
      assert_receive {:agent_event, :turn_end, _}, 1_000

      state = Agent.get_state(agent)
      assert Enum.any?(state.messages, &match?(%{role: {:custom, :summary}}, &1))
    end
  end

  # --- rewind ---

  describe "rewind/2" do
    test "removes messages from the last turn" do
      stream_events([{:text_delta, "ok"}, {:done, %{}}])
      agent = start_agent()
      Agent.subscribe(agent)
      Agent.prompt(agent, "hello")
      assert_receive {:agent_event, :turn_end, _}, 1_000

      assert length(Agent.get_state(agent).messages) == 2

      Agent.rewind(agent)
      assert Agent.get_state(agent).messages == []
    end

    test "rewinds n turns" do
      stream_events([{:text_delta, "ok"}, {:done, %{}}])
      agent = start_agent()
      Agent.subscribe(agent)

      Agent.prompt(agent, "first")
      assert_receive {:agent_event, :turn_end, _}, 1_000
      Agent.prompt(agent, "second")
      assert_receive {:agent_event, :turn_end, _}, 1_000

      assert length(Agent.get_state(agent).messages) == 4

      Agent.rewind(agent, 2)
      assert Agent.get_state(agent).messages == []
    end

    test "rewind beyond available turns is a no-op" do
      stream_events([{:text_delta, "ok"}, {:done, %{}}])
      agent = start_agent()
      Agent.subscribe(agent)
      Agent.prompt(agent, "hello")
      assert_receive {:agent_event, :turn_end, _}, 1_000

      Agent.rewind(agent, 99)
      assert length(Agent.get_state(agent).messages) == 2
    end

    test "broadcasts :rewind event with message_count" do
      stream_events([{:text_delta, "ok"}, {:done, %{}}])
      agent = start_agent()
      Agent.subscribe(agent)
      Agent.prompt(agent, "hello")
      assert_receive {:agent_event, :turn_end, _}, 1_000

      Agent.rewind(agent)
      assert_receive {:agent_event, :rewind, %{message_count: 0}}
    end

    test "rewind is ignored while streaming" do
      stub(MockAI, :stream, fn _model, _ctx, _opts ->
        Process.sleep(5_000)
        []
      end)

      agent = start_agent()
      Agent.prompt(agent, "slow")
      Process.sleep(50)

      Agent.rewind(agent)
      assert Agent.get_state(agent).status == :streaming
      Agent.abort(agent)
    end
  end

  # --- prompt queuing while busy ---

  describe "prompt/2 queuing while busy" do
    test "queued message is appended to history and triggers a second turn" do
      # Use a slow stream so the GenServer is genuinely :streaming when the
      # second prompt arrives, ensuring the busy queue-path is exercised.
      stub(MockAI, :stream, fn _model, _ctx, _opts ->
        Process.sleep(200)
        [{:text_delta, "response"}, {:done, %{}}]
      end)

      agent = start_agent()
      Agent.subscribe(agent)

      Agent.prompt(agent, "first")
      # Give the task time to start so the agent is in :streaming status
      Process.sleep(50)

      assert Agent.get_state(agent).status == :streaming

      # Queue a second message while the agent is busy — this hits the
      # handle_call busy clause and appends without starting a new turn
      Agent.prompt(agent, "second")

      # Message must be in history immediately (not dropped)
      user_messages =
        Agent.get_state(agent).messages
        |> Enum.filter(&(&1.role == :user))

      assert length(user_messages) == 2

      # First turn ends; the queued message re-triggers a second turn automatically
      assert_receive {:agent_event, :turn_end, _}, 2_000
      assert_receive {:agent_event, :turn_start, _}, 2_000
      assert_receive {:agent_event, :turn_end, _}, 2_000
    end

    test "abort with pending queued message re-triggers a new turn" do
      stub(MockAI, :stream, fn _model, _ctx, _opts ->
        Process.sleep(5_000)
        []
      end)

      agent = start_agent()
      Agent.subscribe(agent)

      Agent.prompt(agent, "slow task")
      # Give the stream task time to start so the agent is :streaming
      Process.sleep(50)

      # Queue a message while streaming
      Agent.prompt(agent, "queued message")

      # Switch to a fast stub so the re-triggered turn completes quickly
      stub(MockAI, :stream, fn _model, _ctx, _opts ->
        [{:text_delta, "recovered"}, {:done, %{}}]
      end)

      # Abort — cancel_stream + reset_streaming, then maybe_turn_start detects
      # the queued message and immediately starts a new turn
      Agent.abort(agent)

      # A fresh turn_start and turn_end must arrive after the abort
      assert_receive {:agent_event, :turn_start, _}, 2_000
      assert_receive {:agent_event, :turn_end, _}, 2_000
    end
  end

  # --- whereis ---

  describe "whereis/1" do
    test "returns {:ok, pid} for a running agent" do
      id = unique_id()
      agent = start_agent(id: id)
      assert {:ok, ^agent} = Agent.whereis(id)
    end

    test "returns {:error, :not_found} for unknown id" do
      assert {:error, :not_found} = Agent.whereis("no-such-agent")
    end
  end
end
