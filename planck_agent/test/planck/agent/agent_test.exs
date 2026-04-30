defmodule Planck.Agent.AgentTest do
  use ExUnit.Case, async: false

  import Mox

  alias Planck.Agent
  alias Planck.Agent.{Message, MockAI, Session, Tool}
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

  defp start_agent_with_session(overrides \\ []) do
    session_id = unique_id()
    dir = Path.join(System.tmp_dir!(), "planck_test_#{session_id}")
    {:ok, _} = Session.start(session_id, name: "test", dir: dir)

    on_exit(fn ->
      Session.stop(session_id)
      File.rm_rf!(dir)
    end)

    defaults = [id: unique_id(), model: @model, system_prompt: "helpful.", session_id: session_id]
    opts = Keyword.merge(defaults, overrides)
    {start_supervised!({Agent, opts}), session_id}
  end

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

  # --- get_info ---

  describe "get_info/1" do
    test "includes cost field" do
      agent = start_agent()
      info = Agent.get_info(agent)
      assert Map.has_key?(info, :cost)
      assert info.cost == 0.0
    end

    test "includes usage field" do
      agent = start_agent()
      info = Agent.get_info(agent)
      assert info.usage == %{input_tokens: 0, output_tokens: 0}
    end
  end

  # --- estimate_tokens ---

  describe "estimate_tokens/1" do
    test "returns 0 for an agent with no messages" do
      agent = start_agent()
      assert Agent.estimate_tokens(agent) == 0
    end

    test "returns token estimate after a turn" do
      stream_events([{:text_delta, "hello"}, {:done, %{}}])
      agent = start_agent()
      Agent.subscribe(agent)
      Agent.prompt(agent, "ping")
      assert_receive {:agent_event, :turn_end, _}, 1_000

      # messages: user("ping") + assistant("hello")
      # "ping" = 4 chars → 1 token; "hello" = 5 chars → 1 token
      assert Agent.estimate_tokens(agent) > 0
    end

    test "estimate grows after each turn" do
      stream_events([{:text_delta, String.duplicate("a", 400)}, {:done, %{}}])
      agent = start_agent()
      Agent.subscribe(agent)
      Agent.prompt(agent, String.duplicate("b", 400))
      assert_receive {:agent_event, :turn_end, _}, 1_000

      first = Agent.estimate_tokens(agent)

      stream_events([{:text_delta, String.duplicate("c", 400)}, {:done, %{}}])
      Agent.prompt(agent, String.duplicate("d", 400))
      assert_receive {:agent_event, :turn_end, _}, 1_000

      assert Agent.estimate_tokens(agent) > first
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

    test "usage_delta includes context_tokens" do
      stream_events([
        {:text_delta, "hi"},
        {:done, %{usage: %{input_tokens: 5, output_tokens: 3}}}
      ])

      agent = start_agent()
      Agent.subscribe(agent)
      Agent.prompt(agent, "hello")

      assert_receive {:agent_event, :usage_delta, %{context_tokens: ct}}, 1_000
      assert is_integer(ct)
      assert ct >= 0
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
    test "returns agent to idle while streaming" do
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

    test "returns agent to idle while executing tools" do
      parent = self()
      call = %{id: "t1", name: "slow", args: %{}}

      tool =
        Tool.new(
          name: "slow",
          description: "slow tool",
          parameters: %{},
          execute_fn: fn _id, _args ->
            send(parent, :tool_started)
            Process.sleep(5_000)
            {:ok, "done"}
          end
        )

      stub(MockAI, :stream, fn _model, %Context{messages: msgs}, _opts ->
        if Enum.any?(msgs, &match?(%{role: :tool_result}, &1)) do
          [{:done, %{}}]
        else
          [{:tool_call_complete, call}, {:done, %{}}]
        end
      end)

      agent = start_agent(tools: [tool])
      Agent.subscribe(agent)
      Agent.prompt(agent, "use slow tool")

      # Wait until the tool is actually running
      assert_receive :tool_started, 2_000

      # Abort while tool is mid-execution — must return immediately
      Agent.abort(agent)

      assert Agent.get_state(agent).status == :idle
      # No turn_end should arrive after abort
      refute_receive {:agent_event, :turn_end, _}, 300
    end

    test "abort after tool execution completes is a no-op" do
      call = %{id: "t2", name: "fast", args: %{}}

      tool =
        Tool.new(
          name: "fast",
          description: "fast tool",
          parameters: %{},
          execute_fn: fn _id, _args -> {:ok, "done"} end
        )

      stub(MockAI, :stream, fn _model, %Context{messages: msgs}, _opts ->
        if Enum.any?(msgs, &match?(%{role: :tool_result}, &1)) do
          [{:done, %{}}]
        else
          [{:tool_call_complete, call}, {:done, %{}}]
        end
      end)

      agent = start_agent(tools: [tool])
      Agent.subscribe(agent)
      Agent.prompt(agent, "use fast tool")
      assert_receive {:agent_event, :turn_end, _}, 2_000

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

  # --- rewind_to_message ---

  describe "rewind_to_message/2" do
    test "truncates history to strictly before the given message id (reloads from session)" do
      # Requires a session so truncate_after + reload works
      {agent, _session_id} = start_agent_with_session()
      stream_events([{:text_delta, "ok"}, {:done, %{}}])
      Agent.subscribe(agent)

      Agent.prompt(agent, "first prompt")
      assert_receive {:agent_event, :turn_end, _}, 1_000

      stream_events([{:text_delta, "ok"}, {:done, %{}}])
      Agent.prompt(agent, "second prompt")
      assert_receive {:agent_event, :turn_end, _}, 1_000

      messages = Agent.get_state(agent).messages
      first_user_msg = Enum.find(messages, &(&1.role == :user))

      Agent.rewind_to_message(agent, first_user_msg.id)
      Process.sleep(50)

      assert Agent.get_state(agent).messages == []
    end

    test "is a no-op for ephemeral agents (no session_id)" do
      stream_events([{:text_delta, "ok"}, {:done, %{}}])
      agent = start_agent()
      Agent.subscribe(agent)

      Agent.prompt(agent, "hello")
      assert_receive {:agent_event, :turn_end, _}, 1_000

      messages_before = Agent.get_state(agent).messages
      first_user_msg = Enum.find(messages_before, &(&1.role == :user))

      Agent.rewind_to_message(agent, first_user_msg.id)
      Process.sleep(50)

      assert Agent.get_state(agent).messages == messages_before
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

  # --- persistence ordering ---

  describe "message persistence ordering" do
    test "queued user message is persisted after the current assistant response" do
      stub(MockAI, :stream, fn _model, _ctx, _opts ->
        Process.sleep(100)
        [{:text_delta, "response"}, {:done, %{}}]
      end)

      {agent, session_id} = start_agent_with_session()
      Agent.subscribe(agent)

      Agent.prompt(agent, "first")
      Process.sleep(30)
      assert Agent.get_state(agent).status == :streaming

      # Queue while streaming — must NOT be persisted until after the current turn
      Agent.prompt(agent, "second")

      # first
      assert_receive {:agent_event, :turn_start, _}, 2_000
      # first ends, re-triggers
      assert_receive {:agent_event, :turn_end, _}, 2_000
      # second turn
      assert_receive {:agent_event, :turn_start, _}, 2_000
      # second ends
      assert_receive {:agent_event, :turn_end, _}, 2_000

      {:ok, rows} = Session.messages(session_id)
      db_ids = Enum.map(rows, & &1.db_id)
      roles = Enum.map(rows, & &1.message.role)

      # Must be strictly ascending (no ordering violations)
      assert db_ids == Enum.sort(db_ids)

      # assistant response to "first" must come before the queued "second"
      assistant_idx = Enum.find_index(roles, &(&1 == :assistant))

      second_user_idx =
        roles
        |> Enum.with_index()
        |> Enum.filter(fn {r, _} -> r == :user end)
        |> Enum.at(1)
        |> elem(1)

      assert assistant_idx < second_user_idx
    end

    test "queued message id is a UUID (not yet a db_id) while streaming" do
      stub(MockAI, :stream, fn _model, _ctx, _opts ->
        Process.sleep(200)
        [{:text_delta, "ok"}, {:done, %{}}]
      end)

      {agent, _session_id} = start_agent_with_session()
      Agent.prompt(agent, "first")
      Process.sleep(30)

      Agent.prompt(agent, "second")
      messages = Agent.get_state(agent).messages
      queued = List.last(messages)

      # Still a UUID (binary), not yet assigned a db_id integer
      assert is_binary(queued.id)
    end

    test "queued message has an integer db_id after its turn completes" do
      stub(MockAI, :stream, fn _model, _ctx, _opts ->
        Process.sleep(100)
        [{:text_delta, "ok"}, {:done, %{}}]
      end)

      {agent, _session_id} = start_agent_with_session()
      Agent.subscribe(agent)

      Agent.prompt(agent, "first")
      Process.sleep(30)
      Agent.prompt(agent, "second")

      # Wait for both turns to complete
      assert_receive {:agent_event, :turn_start, _}, 2_000
      assert_receive {:agent_event, :turn_end, _}, 2_000
      assert_receive {:agent_event, :turn_start, _}, 2_000
      assert_receive {:agent_event, :turn_end, _}, 2_000

      messages = Agent.get_state(agent).messages
      second_user = messages |> Enum.filter(&(&1.role == :user)) |> Enum.at(1)

      assert is_integer(second_user.id)
    end

    test "agent_response message is persisted and gets a db_id" do
      stub(MockAI, :stream, fn _model, _ctx, _opts ->
        Process.sleep(50)
        [{:text_delta, "ok"}, {:done, %{}}]
      end)

      {agent, session_id} = start_agent_with_session()
      Agent.subscribe(agent)

      Agent.prompt(agent, "go")
      Process.sleep(10)
      send(agent, {:agent_response, "worker done", nil})

      assert_receive {:agent_event, :turn_start, _}, 2_000
      assert_receive {:agent_event, :turn_end, _}, 2_000
      assert_receive {:agent_event, :turn_start, _}, 1_000
      assert_receive {:agent_event, :turn_end, _}, 2_000

      {:ok, rows} = Session.messages(session_id)
      agent_response_row = Enum.find(rows, &(&1.message.role == {:custom, :agent_response}))

      assert agent_response_row != nil
      assert is_integer(agent_response_row.db_id)

      # db_id ordering: agent_response must come after assistant, before next assistant
      db_ids = Enum.map(rows, & &1.db_id)
      assert db_ids == Enum.sort(db_ids)
    end
  end

  # --- whereis ---

  describe "agent_response re-trigger" do
    test "agent_response arriving during streaming triggers exactly one follow-up turn" do
      # An agent_response that arrives while the LLM is streaming was not seen
      # by the LLM. It should trigger one re-run. After that run processes the
      # response, no further turns should fire.
      parent = self()

      stub(MockAI, :stream, fn _model, %Context{messages: msgs}, _opts ->
        has_response =
          Enum.any?(msgs, fn msg ->
            msg.role == :user and
              Enum.any?(msg.content, &match?({:text, "worker done"}, &1))
          end)

        if has_response do
          send(parent, :second_turn)
          [{:text_delta, "acknowledged"}, {:done, %{}}]
        else
          Process.sleep(100)
          [{:text_delta, "working"}, {:done, %{}}]
        end
      end)

      agent = start_agent()
      Agent.subscribe(agent)
      Agent.prompt(agent, "go")

      # Inject while the first LLM call is sleeping (at 30ms, LLM finishes at 100ms)
      Process.sleep(30)
      send(agent, {:agent_response, "worker done", nil})

      # initial turn
      assert_receive {:agent_event, :turn_start, _}, 1_000
      # first turn ends
      assert_receive {:agent_event, :turn_end, _}, 2_000
      # re-triggered by response
      assert_receive {:agent_event, :turn_start, _}, 1_000
      assert_receive :second_turn, 1_000
      assert_receive {:agent_event, :turn_end, _}, 2_000

      # No third turn — the response is in stream_start context for the second call
      refute_receive {:agent_event, :turn_start, _}, 300
    end

    test "agent_responses already in LLM context do not cause infinite re-triggers" do
      # Both responses arrive during the FIRST stream. The re-triggered second turn
      # sees both in its context. After it completes, no further turn must fire.
      stub(MockAI, :stream, fn _model, _ctx, _opts ->
        Process.sleep(50)
        [{:text_delta, "summary"}, {:done, %{}}]
      end)

      agent = start_agent()
      Agent.subscribe(agent)
      Agent.prompt(agent, "go")

      # Inject both while the first LLM is sleeping
      Process.sleep(10)
      send(agent, {:agent_response, "response A", nil})
      send(agent, {:agent_response, "response B", nil})

      # initial turn
      assert_receive {:agent_event, :turn_start, _}, 1_000
      # first turn ends, re-triggers
      assert_receive {:agent_event, :turn_end, _}, 2_000
      # second turn sees both responses
      assert_receive {:agent_event, :turn_start, _}, 1_000
      # second turn ends
      assert_receive {:agent_event, :turn_end, _}, 2_000

      # No third turn — both responses were in the LLM context for the second call
      refute_receive {:agent_event, :turn_start, _}, 300
    end
  end

  describe "flush_unpersisted_messages ordering" do
    test "queued user message appears after the current turn's assistant response in state.messages" do
      stub(MockAI, :stream, fn _model, _ctx, _opts ->
        Process.sleep(100)
        [{:text_delta, "first response"}, {:done, %{}}]
      end)

      {agent, _session_id} = start_agent_with_session()
      Agent.subscribe(agent)

      Agent.prompt(agent, "first")
      Process.sleep(30)

      # Queue while streaming
      Agent.prompt(agent, "second")

      # Both turns complete
      assert_receive {:agent_event, :turn_start, _}, 2_000
      assert_receive {:agent_event, :turn_end, _}, 2_000
      assert_receive {:agent_event, :turn_start, _}, 2_000
      assert_receive {:agent_event, :turn_end, _}, 2_000

      roles =
        Agent.get_state(agent).messages
        |> Enum.map(fn msg ->
          case msg.role do
            :user -> :user
            :assistant -> :assistant
            _ -> :other
          end
        end)

      # Correct order: user("first"), assistant, user("second"), assistant
      assert roles == [:user, :assistant, :user, :assistant]
    end

    test "db_ids in state.messages are strictly ascending after queuing" do
      stub(MockAI, :stream, fn _model, _ctx, _opts ->
        Process.sleep(100)
        [{:text_delta, "ok"}, {:done, %{}}]
      end)

      {agent, _session_id} = start_agent_with_session()
      Agent.subscribe(agent)

      Agent.prompt(agent, "first")
      Process.sleep(30)
      Agent.prompt(agent, "second")

      assert_receive {:agent_event, :turn_start, _}, 2_000
      assert_receive {:agent_event, :turn_end, _}, 2_000
      assert_receive {:agent_event, :turn_start, _}, 2_000
      assert_receive {:agent_event, :turn_end, _}, 2_000

      ids = Agent.get_state(agent).messages |> Enum.map(& &1.id)
      assert ids == Enum.sort(ids)
    end

    test "turn_checkpoints covers all user messages after queuing" do
      stub(MockAI, :stream, fn _model, _ctx, _opts ->
        Process.sleep(100)
        [{:text_delta, "ok"}, {:done, %{}}]
      end)

      {agent, _session_id} = start_agent_with_session()
      Agent.subscribe(agent)

      Agent.prompt(agent, "first")
      Process.sleep(30)
      Agent.prompt(agent, "second")

      assert_receive {:agent_event, :turn_start, _}, 2_000
      assert_receive {:agent_event, :turn_end, _}, 2_000
      assert_receive {:agent_event, :turn_start, _}, 2_000
      assert_receive {:agent_event, :turn_end, _}, 2_000

      state = Agent.get_state(agent)

      user_indices =
        state.messages
        |> Enum.with_index()
        |> Enum.filter(fn {msg, _} -> msg.role == :user end)
        |> Enum.map(fn {_, idx} -> idx end)

      # Every user message must have a corresponding checkpoint
      assert length(state.turn_checkpoints) == length(user_indices)
    end
  end

  # --- cost tracking ---

  describe "cost tracking" do
    @model_with_cost %Model{
      id: "gpt-4o",
      name: "GPT-4o",
      provider: :openai,
      context_window: 128_000,
      max_tokens: 4_096,
      cost: %{input: 2.5, output: 10.0}
    }

    test "cost starts at zero" do
      agent = start_agent()
      assert Agent.get_state(agent).cost == 0.0
    end

    test "cost is zero when model has no cost rates" do
      stream_events([{:done, %{usage: %{input_tokens: 100, output_tokens: 50}}}])
      agent = start_agent()
      Agent.subscribe(agent)
      Agent.prompt(agent, "hello")
      assert_receive {:agent_event, :turn_end, _}, 1_000
      assert Agent.get_state(agent).cost == 0.0
    end

    test "cost is calculated correctly from model rates" do
      # (100 * 2.5 + 50 * 10.0) / 1_000_000 = 750 / 1_000_000 = 0.00075
      stream_events([{:done, %{usage: %{input_tokens: 100, output_tokens: 50}}}])
      agent = start_agent(model: @model_with_cost)
      Agent.subscribe(agent)
      Agent.prompt(agent, "hello")
      assert_receive {:agent_event, :turn_end, _}, 1_000
      assert_in_delta Agent.get_state(agent).cost, 0.00075, 1.0e-10
    end

    test "cost accumulates across turns" do
      # Turn 1: (100 * 2.5 + 50 * 10.0) / 1M = 0.00075
      # Turn 2: (60 * 2.5 + 20 * 10.0) / 1M = 0.00035
      # Total: 0.00110
      stream_events([{:done, %{usage: %{input_tokens: 100, output_tokens: 50}}}])
      agent = start_agent(model: @model_with_cost)
      Agent.subscribe(agent)

      Agent.prompt(agent, "first")
      assert_receive {:agent_event, :turn_end, _}, 1_000

      stream_events([{:done, %{usage: %{input_tokens: 60, output_tokens: 20}}}])
      Agent.prompt(agent, "second")
      assert_receive {:agent_event, :turn_end, _}, 1_000

      assert_in_delta Agent.get_state(agent).cost, 0.00110, 1.0e-10
    end

    test "usage_delta includes cost in delta and total" do
      # (100 * 2.5 + 50 * 10.0) / 1M = 0.00075
      stream_events([{:done, %{usage: %{input_tokens: 100, output_tokens: 50}}}])
      agent = start_agent(model: @model_with_cost)
      Agent.subscribe(agent)
      Agent.prompt(agent, "hello")

      assert_receive {:agent_event, :usage_delta,
                      %{
                        delta: %{input_tokens: 100, output_tokens: 50, cost: delta_cost},
                        total: %{input_tokens: 100, output_tokens: 50, cost: total_cost}
                      }},
                     1_000

      assert_in_delta delta_cost, 0.00075, 1.0e-10
      assert_in_delta total_cost, 0.00075, 1.0e-10
    end

    test "usage_delta total reflects accumulated cost across multiple :done events" do
      # Turn 1 :done: delta = 0.00075, total = 0.00075
      # Turn 2 :done: delta = 0.00035, total = 0.00110
      stream_events([{:done, %{usage: %{input_tokens: 100, output_tokens: 50}}}])
      agent = start_agent(model: @model_with_cost)
      Agent.subscribe(agent)

      Agent.prompt(agent, "first")
      assert_receive {:agent_event, :usage_delta, %{total: %{cost: total1}}}, 1_000
      assert_receive {:agent_event, :turn_end, _}, 1_000
      assert_in_delta total1, 0.00075, 1.0e-10

      stream_events([{:done, %{usage: %{input_tokens: 60, output_tokens: 20}}}])
      Agent.prompt(agent, "second")

      assert_receive {:agent_event, :usage_delta,
                      %{delta: %{cost: delta2}, total: %{cost: total2}}},
                     1_000

      assert_in_delta delta2, 0.00035, 1.0e-10
      assert_in_delta total2, 0.00110, 1.0e-10
    end

    test "agent initializes with provided usage and cost" do
      agent =
        start_agent(usage: %{input_tokens: 500, output_tokens: 200}, cost: 0.005)

      state = Agent.get_state(agent)
      assert state.usage == %{input_tokens: 500, output_tokens: 200}
      assert state.cost == 0.005
    end

    test "new cost adds on top of initial cost" do
      # initial cost: 0.001, new turn: (100 * 2.5 + 50 * 10.0) / 1M = 0.00075
      # total: 0.00175
      stream_events([{:done, %{usage: %{input_tokens: 100, output_tokens: 50}}}])
      agent = start_agent(model: @model_with_cost, cost: 0.001)
      Agent.subscribe(agent)
      Agent.prompt(agent, "hello")
      assert_receive {:agent_event, :turn_end, _}, 1_000
      assert_in_delta Agent.get_state(agent).cost, 0.00175, 1.0e-10
    end

    test "usage and cost are persisted to session metadata on :done" do
      stream_events([{:done, %{usage: %{input_tokens: 100, output_tokens: 50}}}])
      {agent, session_id} = start_agent_with_session(model: @model_with_cost)
      Agent.subscribe(agent)
      Agent.prompt(agent, "hello")
      assert_receive {:agent_event, :turn_end, _}, 1_000

      agent_id = Agent.get_state(agent).id
      {:ok, metadata} = Session.get_metadata(session_id)
      json = Map.get(metadata, "agent_usage:#{agent_id}")
      assert json != nil

      {:ok, stored} = Jason.decode(json)
      assert stored["input_tokens"] == 100
      assert stored["output_tokens"] == 50
      assert_in_delta stored["cost"], 0.00075, 1.0e-10
    end
  end

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
