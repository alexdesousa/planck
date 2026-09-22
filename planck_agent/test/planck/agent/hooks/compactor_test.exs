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

  defp build_state(opts) do
    %Agent{
      id: "test",
      model: Keyword.get(opts, :model, @model),
      compactor: Keyword.get(opts, :compactor),
      sidecar_node: Keyword.get(opts, :sidecar_node),
      messages: Keyword.get(opts, :messages, [])
    }
  end

  defp build_context(messages, opts \\ []) do
    %Context{
      system: Keyword.get(opts, :system),
      messages: Message.to_ai_messages(messages),
      tools: Keyword.get(opts, :tools, [])
    }
  end

  # ---------------------------------------------------------------------------
  # use Planck.Agent.Hooks.Compactor — behaviour defaults
  # ---------------------------------------------------------------------------

  describe "use Planck.Agent.Hooks.Compactor" do
    defmodule DefaultTimeoutCompactor do
      use Planck.Agent.Hooks.Compactor

      @impl true
      def compact?(_state, _context, _recent), do: true

      @impl true
      def compact(_state, _context, recent), do: {:compact, hd(recent), []}
    end

    defmodule CustomTimeoutCompactor do
      use Planck.Agent.Hooks.Compactor

      @impl true
      def compact?(_state, _context, _recent), do: true

      @impl true
      def compact(_state, _context, recent), do: {:compact, hd(recent), []}

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
  # compact/3 — local dispatch (compactor: nil)
  # ---------------------------------------------------------------------------

  describe "compact/3 local (compactor: nil)" do
    test "returns :skip when below threshold" do
      messages = make_messages(5, 10)
      state = build_state(messages: messages)
      context = build_context(messages)

      assert Compactor.compact(state, context, messages) == :skip
    end

    test "returns {:compact, summary_msg, kept} when tokens exceed threshold" do
      stub(MockAI, :stream, fn _model, _context, _opts ->
        [{:text_delta, "Summary of old messages."}, {:done, %{}}]
      end)

      messages = make_messages(12, 400)
      state = build_state(messages: messages)
      context = build_context(messages)

      assert {:compact, summary_msg, kept} = Compactor.compact(state, context, messages)
      assert summary_msg.role == {:custom, :summary}
      assert [{:text, "Summary of old messages."}] = summary_msg.content
      # keep_budget = trunc(1_000 * 0.1) = 100 tokens; each message costs ~100 tokens → 1 kept
      assert length(kept) == 1
    end

    test "returns :skip on LLM error" do
      stub(MockAI, :stream, fn _model, _context, _opts ->
        [{:error, :timeout}]
      end)

      messages = make_messages(12, 400)
      state = build_state(messages: messages)
      context = build_context(messages)

      assert Compactor.compact(state, context, messages) == :skip
    end

    test "returns :skip on empty LLM response" do
      stub(MockAI, :stream, fn _model, _context, _opts ->
        [{:done, %{}}]
      end)

      messages = make_messages(12, 400)
      state = build_state(messages: messages)
      context = build_context(messages)

      assert Compactor.compact(state, context, messages) == :skip
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
      state = build_state(messages: messages)
      context = build_context(messages)

      assert {:compact, _, _} = Compactor.compact(state, context, messages)

      assert_received {:summarize_input, history}
      refute history =~ "First summary."
      refute history =~ "Second summary."
    end

    # The context's system prompt and tool schemas count toward the
    # threshold too, not just the messages — that's the whole reason
    # do_local/3 estimates from `context` (the actual request shape)
    # instead of just the message list. Below, `messages` alone stays
    # under threshold; only a context with a sizeable system prompt pushes
    # the total over it.
    test "the context's system prompt contributes to the threshold — not just the messages" do
      # 12 messages x ~50 tokens each = ~600 tokens: under the 800-token
      # threshold (context_window 1_000 * 0.8) on messages alone, but
      # enough that once threshold IS crossed, some of them (over the
      # 100-token keep budget) actually get summarized rather than all
      # being cheap enough to keep — otherwise compact_local/2 would still
      # :skip with nothing old enough to summarize, threshold aside.
      messages = make_messages(12, 200)
      state = build_state(messages: messages)

      bare_context = build_context(messages)
      assert Compactor.compact(state, bare_context, messages) == :skip

      stub(MockAI, :stream, fn _model, _context, _opts ->
        [{:text_delta, "Summary."}, {:done, %{}}]
      end)

      # ~1_200 chars of system prompt ≈ 300 extra tokens, pushing ~600 + 300 over 800.
      padded_context = build_context(messages, system: String.duplicate("s", 1_200))
      assert {:compact, _summary, _kept} = Compactor.compact(state, padded_context, messages)
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
      state = build_state(messages: messages)
      context = build_context(messages)

      Compactor.compact(state, context, messages)

      assert_received {:summarize_input, history}
      refute history =~ "Internal reasoning"
      refute history =~ "More reasoning"
      assert history =~ "Visible reply"
    end
  end

  # ---------------------------------------------------------------------------
  # compact/3 — local module dispatch (compactor set, sidecar_node: nil)
  # ---------------------------------------------------------------------------

  describe "compact/3 local module dispatch" do
    defmodule LocalSkipCompactor do
      use Planck.Agent.Hooks.Compactor

      # compact?/3 must be true here — the point of this test is verifying
      # dispatch actually reaches compact/3 and returns whatever it decides,
      # not that compact/3 never gets called at all.
      @impl true
      def compact?(_state, _context, _recent), do: true

      @impl true
      def compact(_state, _context, _recent), do: :skip
    end

    defmodule LocalCompactCompactor do
      use Planck.Agent.Hooks.Compactor

      @impl true
      def compact?(_state, _context, _recent), do: true

      @impl true
      def compact(_state, _context, recent) do
        summary = Message.new({:custom, :summary}, [{:text, "Local compact."}])
        {:compact, summary, Enum.take(recent, -1)}
      end
    end

    test "calls module.compact/3 directly" do
      messages = make_messages(3, 10)
      state = build_state(messages: messages, compactor: LocalSkipCompactor)
      context = build_context(messages)

      assert Compactor.compact(state, context, messages) == :skip
    end

    test "returns module's compact result" do
      messages = make_messages(3, 10)
      state = build_state(messages: messages, compactor: LocalCompactCompactor)
      context = build_context(messages)

      assert {:compact, summary, kept} = Compactor.compact(state, context, messages)

      assert summary.role == {:custom, :summary}
      assert length(kept) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # compact/4 opts — on_compacting/on_compacted, called by the dispatcher
  # itself, never by a compact/3 implementation
  # ---------------------------------------------------------------------------

  describe "compact/4 opts (on_compacting/on_compacted)" do
    test "both fire, in order, bracketing compact/3, when compact?/3 is true" do
      parent = self()

      opts = [
        on_compacting: fn -> send(parent, :on_compacting) end,
        on_compacted: fn -> send(parent, :on_compacted) end
      ]

      messages = make_messages(3, 10)
      state = build_state(messages: messages, compactor: __MODULE__.LocalCompactCompactor)
      context = build_context(messages)

      assert {:compact, _summary, _kept} = Compactor.compact(state, context, messages, opts)

      assert_received :on_compacting
      assert_received :on_compacted
    end

    test "neither fires when compact?/3 is false" do
      parent = self()

      opts = [
        on_compacting: fn -> send(parent, :on_compacting) end,
        on_compacted: fn -> send(parent, :on_compacted) end
      ]

      messages = make_messages(5, 10)
      state = build_state(messages: messages)
      context = build_context(messages)

      assert Compactor.compact(state, context, messages, opts) == :skip
      refute_received :on_compacting
      refute_received :on_compacted
    end

    # compact?/3 said true, but compact/3 itself still decided :skip (e.g.
    # nothing old enough left worth summarizing) — on_compacting already
    # announced work was starting, so on_compacted must still fire to clear
    # that, even though nothing was actually compacted.
    test "on_compacted still fires when compact/3 internally :skips despite compact?/3 being true" do
      parent = self()

      opts = [
        on_compacting: fn -> send(parent, :on_compacting) end,
        on_compacted: fn -> send(parent, :on_compacted) end
      ]

      messages = make_messages(3, 10)
      state = build_state(messages: messages, compactor: __MODULE__.LocalSkipCompactor)
      context = build_context(messages)

      assert Compactor.compact(state, context, messages, opts) == :skip
      assert_received :on_compacting
      assert_received :on_compacted
    end

    test "omitting opts entirely does not raise" do
      messages = make_messages(3, 10)
      state = build_state(messages: messages, compactor: __MODULE__.LocalCompactCompactor)
      context = build_context(messages)

      assert {:compact, _summary, _kept} = Compactor.compact(state, context, messages)
    end
  end

  # ---------------------------------------------------------------------------
  # compact/3 — remote dispatch (same-node simulation)
  # ---------------------------------------------------------------------------

  defmodule RemoteSkipCompactor do
    use Planck.Agent.Hooks.Compactor

    # true so the RPC-dispatch tests below exercise the full two-call shape
    # (compact? then compact) rather than short-circuiting before compact/3
    # is ever reached.
    @impl true
    def compact?(_state, _context, _recent), do: true

    @impl true
    def compact(_state, _context, _recent), do: :skip

    @impl true
    def compact_timeout, do: 5_000
  end

  describe "compact/3 remote" do
    test "sidecar_node: nil uses local dispatch" do
      messages = make_messages(1, 10)
      state = build_state(messages: messages, compactor: RemoteSkipCompactor)
      context = build_context(messages)

      assert Compactor.compact(state, context, messages) == :skip
    end

    test "dispatches via RPC on the same node" do
      messages = make_messages(1, 10)

      state =
        build_state(messages: messages, compactor: RemoteSkipCompactor, sidecar_node: Node.self())

      context = build_context(messages)

      assert Compactor.compact(state, context, messages) == :skip
    end

    test "falls back to local LLM compactor when RPC fails" do
      stub(MockAI, :stream, fn _model, _context, _opts ->
        [{:text_delta, "fallback summary"}, {:done, %{}}]
      end)

      messages = make_messages(12, 400)

      state =
        build_state(
          messages: messages,
          compactor: RemoteSkipCompactor,
          sidecar_node: :nonexistent@localhost
        )

      context = build_context(messages)

      assert {:compact, summary, _kept} = Compactor.compact(state, context, messages)
      assert [{:text, "fallback summary"}] = summary.content
    end
  end

  # ---------------------------------------------------------------------------
  # Integration with Agent
  # ---------------------------------------------------------------------------

  defmodule IntegrationCompactor do
    use Planck.Agent.Hooks.Compactor

    @impl true
    def compact?(_state, _context, _recent), do: true

    @impl true
    def compact(_state, _context, recent) do
      summary = Message.new({:custom, :summary}, [{:text, "Compacted."}])
      {:compact, summary, Enum.take(recent, -1)}
    end
  end

  defmodule NeverCompactor do
    use Planck.Agent.Hooks.Compactor

    # false, not true+:skip — on_compacting/on_compacted fire whenever
    # compact?/3 says true, regardless of what compact/3 itself then
    # decides. This test asserts neither broadcast happens at all, which
    # requires compact?/3 itself to say no.
    @impl true
    def compact?(_state, _context, _recent), do: false

    @impl true
    def compact(_state, _context, _recent), do: :skip
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
