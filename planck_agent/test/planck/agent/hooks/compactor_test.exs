defmodule Planck.Agent.Hooks.CompactorTest do
  use ExUnit.Case, async: false

  import Mox

  alias Planck.Agent
  alias Planck.Agent.Hooks.Compactor
  alias Planck.Agent.{Message, MockAI}
  alias Planck.AI.{Context, Model}

  setup :set_mox_global
  setup :verify_on_exit!

  @model %Model{
    id: "llama3.2",
    name: "Llama 3.2",
    provider: :openai,
    context_window: 1_000,
    max_tokens: 512
  }

  defp text_message(role, text) do
    Message.new(role, [{:text, text}])
  end

  defp make_messages(count, chars_each) do
    text = String.duplicate("a", chars_each)
    Enum.map(1..count, fn _ -> text_message(:user, text) end)
  end

  # ---------------------------------------------------------------------------
  # use Planck.Agent.Hooks.Compactor — behaviour defaults
  # ---------------------------------------------------------------------------

  describe "use Planck.Agent.Hooks.Compactor" do
    defmodule DefaultTimeoutCompactor do
      use Planck.Agent.Hooks.Compactor

      @impl true
      def compact(_model, messages), do: {:compact, hd(messages), []}
    end

    defmodule CustomTimeoutCompactor do
      use Planck.Agent.Hooks.Compactor

      @impl true
      def compact(_model, messages), do: {:compact, hd(messages), []}

      @impl true
      def compact_timeout, do: 60_000
    end

    test "provides default compact_timeout/0" do
      assert DefaultTimeoutCompactor.compact_timeout() == Compactor.default_compact_timeout()
    end

    test "compact_timeout/0 can be overridden" do
      assert CustomTimeoutCompactor.compact_timeout() == 60_000
    end
  end

  # ---------------------------------------------------------------------------
  # compact/4 — local dispatch (module: nil)
  # ---------------------------------------------------------------------------

  describe "compact/4 local (module: nil)" do
    test "returns :skip when below threshold" do
      messages = make_messages(5, 10)
      assert Compactor.compact(nil, @model, messages, nil) == :skip
    end

    test "returns {:compact, summary_msg, kept} when tokens exceed threshold" do
      stub(MockAI, :stream, fn _model, _context, _opts ->
        [{:text_delta, "Summary of old messages."}, {:done, %{}}]
      end)

      messages = make_messages(12, 400)
      assert {:compact, summary_msg, kept} = Compactor.compact(nil, @model, messages, nil)
      assert summary_msg.role == {:custom, :summary}
      assert [{:text, "Summary of old messages."}] = summary_msg.content
      assert length(kept) == 10
    end

    test "returns :skip on LLM error" do
      stub(MockAI, :stream, fn _model, _context, _opts ->
        [{:error, :timeout}]
      end)

      messages = make_messages(12, 400)
      assert Compactor.compact(nil, @model, messages, nil) == :skip
    end

    test "returns :skip on empty LLM response" do
      stub(MockAI, :stream, fn _model, _context, _opts ->
        [{:done, %{}}]
      end)

      messages = make_messages(12, 400)
      assert Compactor.compact(nil, @model, messages, nil) == :skip
    end

    test "filters summary checkpoints from messages sent to LLM" do
      parent = self()

      stub(MockAI, :stream, fn _model,
                               %Context{messages: [%{content: [{:text, history}]}]},
                               _opts ->
        send(parent, {:summarize_input, history})
        [{:text_delta, "New summary."}, {:done, %{}}]
      end)

      summary1 = Message.new({:custom, :summary}, [{:text, "First summary."}])
      summary2 = Message.new({:custom, :summary}, [{:text, "Second summary."}])
      large = make_messages(12, 400)
      messages = [summary1 | large] ++ [summary2]

      assert {:compact, _, _} = Compactor.compact(nil, @model, messages, nil)

      assert_received {:summarize_input, history}
      refute history =~ "First summary."
      refute history =~ "Second summary."
    end

    test "thinking blocks are excluded from the summarization input" do
      parent = self()

      stub(MockAI, :stream, fn _model,
                               %Context{messages: [%{content: [{:text, history}]}]},
                               _opts ->
        send(parent, {:summarize_input, history})
        [{:text_delta, "Summary."}, {:done, %{}}]
      end)

      thinking_msg = Message.new(:assistant, [{:thinking, "Internal reasoning, lots of it."}])

      mixed_msg =
        Message.new(:assistant, [{:thinking, "More reasoning."}, {:text, "Visible reply."}])

      messages = [thinking_msg, mixed_msg] ++ make_messages(12, 400)

      Compactor.compact(nil, @model, messages, nil)

      assert_received {:summarize_input, history}
      refute history =~ "Internal reasoning"
      refute history =~ "More reasoning"
      assert history =~ "Visible reply"
    end
  end

  # ---------------------------------------------------------------------------
  # compact/4 — local module dispatch (module set, sidecar_node: nil)
  # ---------------------------------------------------------------------------

  describe "compact/4 local module dispatch" do
    defmodule LocalSkipCompactor do
      use Planck.Agent.Hooks.Compactor

      @impl true
      def compact(_model, _messages), do: :skip
    end

    defmodule LocalCompactCompactor do
      use Planck.Agent.Hooks.Compactor

      @impl true
      def compact(_model, messages) do
        summary = Message.new({:custom, :summary}, [{:text, "Local compact."}])
        {:compact, summary, Enum.take(messages, -1)}
      end
    end

    test "calls module.compact/2 directly" do
      result = Compactor.compact(LocalSkipCompactor, @model, make_messages(3, 10), nil)
      assert result == :skip
    end

    test "returns module's compact result" do
      messages = make_messages(3, 10)

      assert {:compact, summary, kept} =
               Compactor.compact(LocalCompactCompactor, @model, messages, nil)

      assert summary.role == {:custom, :summary}
      assert length(kept) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # compact/4 — remote dispatch (same-node simulation)
  # ---------------------------------------------------------------------------

  defmodule RemoteSkipCompactor do
    use Planck.Agent.Hooks.Compactor

    @impl true
    def compact(_model, _messages), do: :skip

    @impl true
    def compact_timeout, do: 5_000
  end

  describe "compact/4 remote" do
    test "sidecar_node: nil uses local dispatch" do
      result = Compactor.compact(RemoteSkipCompactor, @model, make_messages(1, 10), nil)
      assert result == :skip
    end

    test "dispatches via RPC on the same node" do
      result =
        Compactor.compact(RemoteSkipCompactor, @model, make_messages(1, 10), Node.self())

      assert result == :skip
    end

    test "falls back to local LLM compactor when RPC fails" do
      stub(MockAI, :stream, fn _model, _context, _opts ->
        [{:text_delta, "fallback summary"}, {:done, %{}}]
      end)

      messages = make_messages(12, 400)

      assert {:compact, summary, _kept} =
               Compactor.compact(RemoteSkipCompactor, @model, messages, :nonexistent@localhost)

      assert [{:text, "fallback summary"}] = summary.content
    end
  end

  # ---------------------------------------------------------------------------
  # Integration with Agent
  # ---------------------------------------------------------------------------

  defmodule IntegrationCompactor do
    use Planck.Agent.Hooks.Compactor

    @impl true
    def compact(_model, messages) do
      summary = Message.new({:custom, :summary}, [{:text, "Compacted."}])
      {:compact, summary, Enum.take(messages, -1)}
    end
  end

  defmodule NeverCompactor do
    use Planck.Agent.Hooks.Compactor

    @impl true
    def compact(_model, _messages), do: :skip
  end

  defp unique_id, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

  defp compacting_agent do
    stub(MockAI, :stream, fn _model, _context, _opts ->
      [{:text_delta, "ok"}, {:done, %{}}]
    end)

    agent =
      start_supervised!(
        {Agent,
         id: unique_id(),
         model: @model,
         system_prompt: "You are helpful.",
         compactor: IntegrationCompactor}
      )

    messages = Enum.map(1..5, fn i -> text_message(:user, "message #{i}") end)
    :sys.replace_state(agent, fn s -> %{s | messages: messages} end)
    agent
  end

  describe "integration with Agent" do
    test "broadcasts :compacting before compaction runs" do
      agent = compacting_agent()
      Agent.subscribe(agent)
      Agent.prompt(agent, "go")
      assert_receive {:agent_event, :compacting, _}, 1_000
    end

    test "broadcasts :compacted after compaction completes" do
      agent = compacting_agent()
      Agent.subscribe(agent)
      Agent.prompt(agent, "go")
      assert_receive {:agent_event, :compacted, _}, 1_000
    end

    test ":compacting is broadcast before :compacted" do
      agent = compacting_agent()
      Agent.subscribe(agent)
      Agent.prompt(agent, "go")
      assert_receive {:agent_event, :compacting, _}, 1_000
      assert_receive {:agent_event, :compacted, _}, 1_000
    end

    test "no :compacting or :compacted broadcast when compaction is skipped" do
      stub(MockAI, :stream, fn _model, _context, _opts ->
        [{:text_delta, "ok"}, {:done, %{}}]
      end)

      agent =
        start_supervised!(
          {Agent,
           id: unique_id(),
           model: @model,
           system_prompt: "You are helpful.",
           compactor: NeverCompactor}
        )

      Agent.subscribe(agent)
      Agent.prompt(agent, "go")

      assert_receive {:agent_event, :turn_end, _}, 1_000
      refute_received {:agent_event, :compacting, _}
      refute_received {:agent_event, :compacted, _}
    end

    test "compacted messages are sent to the LLM (fewer than original)" do
      parent = self()

      stub(MockAI, :stream, fn _model, %Context{messages: msgs}, _opts ->
        send(parent, {:llm_called_with, length(msgs)})
        [{:text_delta, "ok"}, {:done, %{}}]
      end)

      agent =
        start_supervised!(
          {Agent,
           id: unique_id(),
           model: @model,
           system_prompt: "You are helpful.",
           compactor: IntegrationCompactor}
        )

      Agent.subscribe(agent)

      messages = Enum.map(1..5, fn i -> Message.new(:user, [{:text, "message #{i}"}]) end)
      :sys.replace_state(agent, fn s -> %{s | messages: messages} end)

      Agent.prompt(agent, "go")
      # IntegrationCompactor keeps last 1 message + summary → LLM sees 2 messages
      assert_receive {:llm_called_with, n}, 1_000
      assert n < 6
      assert_receive {:agent_event, :turn_end, _}, 1_000
    end
  end
end
