defmodule Planck.Agent.CompactorTest do
  use ExUnit.Case, async: false

  import Mox

  alias Planck.Agent.{Compactor, Message, MockAI}
  alias Planck.AI.Model

  setup :set_mox_global
  setup :verify_on_exit!

  @model %Model{
    id: "llama3.2",
    name: "Llama 3.2",
    provider: :ollama,
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

  # --- __using__ and compact_timeout/0 ---

  describe "use Planck.Agent.Compactor" do
    defmodule DefaultTimeoutCompactor do
      use Planck.Agent.Compactor

      @impl true
      def compact(_model, messages), do: {:compact, hd(messages), []}
    end

    defmodule CustomTimeoutCompactor do
      use Planck.Agent.Compactor

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

  # --- build/2 (local) ---

  describe "build/2 local" do
    test "returns a function" do
      compact_fn = Compactor.build(@model)
      assert is_function(compact_fn, 1)
    end

    test "returns :skip when below threshold" do
      compact_fn = Compactor.build(@model)
      messages = make_messages(5, 10)
      assert compact_fn.(messages) == :skip
    end

    test "returns {:compact, summary_msg, kept} when tokens exceed threshold" do
      stub(MockAI, :stream, fn _model, _context, _opts ->
        [{:text_delta, "Summary of old messages."}, {:done, %{}}]
      end)

      compact_fn = Compactor.build(@model, keep_recent: 1)
      messages = make_messages(3, 4_000)

      assert {:compact, summary_msg, kept} = compact_fn.(messages)
      assert summary_msg.role == {:custom, :summary}
      assert [{:text, "Summary of old messages."}] = summary_msg.content
      assert length(kept) == 1
    end

    test "keeps the last keep_recent messages verbatim" do
      stub(MockAI, :stream, fn _model, _context, _opts ->
        [{:text_delta, "Summary."}, {:done, %{}}]
      end)

      compact_fn = Compactor.build(@model, keep_recent: 2)
      messages = make_messages(5, 4_000)
      [_a, _b, _c, d, e] = messages

      assert {:compact, _summary, kept} = compact_fn.(messages)
      assert d in kept
      assert e in kept
    end

    test "respects custom ratio" do
      stub(MockAI, :stream, fn _model, _context, _opts ->
        [{:text_delta, "Compact."}, {:done, %{}}]
      end)

      compact_fn = Compactor.build(@model, ratio: 0.01, keep_recent: 1)
      messages = make_messages(3, 100)

      assert {:compact, _summary, _kept} = compact_fn.(messages)
    end

    test "returns :skip on LLM error" do
      stub(MockAI, :stream, fn _model, _context, _opts ->
        [{:error, :timeout}]
      end)

      compact_fn = Compactor.build(@model, ratio: 0.01)
      messages = make_messages(3, 100)

      assert compact_fn.(messages) == :skip
    end

    test "returns :skip on empty LLM response" do
      stub(MockAI, :stream, fn _model, _context, _opts ->
        [{:done, %{}}]
      end)

      compact_fn = Compactor.build(@model, ratio: 0.01)
      messages = make_messages(3, 100)

      assert compact_fn.(messages) == :skip
    end
  end

  # --- build/2 (remote, same-node simulation) ---

  defmodule FakeCompactor do
    use Planck.Agent.Compactor

    @impl true
    def compact(_model, _messages), do: :skip

    @impl true
    def compact_timeout, do: 5_000
  end

  defmodule FailingCompactor do
    use Planck.Agent.Compactor

    @impl true
    def compact(_model, _messages), do: raise("boom")
  end

  describe "build/2 remote" do
    test "sidecar_node: nil falls through to local" do
      fun = Compactor.build(@model, sidecar_node: nil, compactor: "Some.Module")
      assert is_function(fun, 1)
      # local: below threshold so :skip
      assert fun.(make_messages(1, 10)) == :skip
    end

    test "compactor: nil falls through to local" do
      fun = Compactor.build(@model, sidecar_node: Node.self(), compactor: nil)
      assert fun.(make_messages(1, 10)) == :skip
    end

    test "calls compact/2 on the remote module (same-node)" do
      fun =
        Compactor.build(@model,
          sidecar_node: Node.self(),
          compactor: "Planck.Agent.CompactorTest.FakeCompactor"
        )

      assert :skip = fun.(make_messages(1, 10))
    end

    test "falls back to local compactor when RPC fails" do
      stub(MockAI, :stream, fn _model, _context, _opts ->
        [{:text_delta, "fallback summary"}, {:done, %{}}]
      end)

      # Use an atom node that doesn't exist — RPC will return {:badrpc, _}.
      fun =
        Compactor.build(@model,
          sidecar_node: :nonexistent_node@localhost,
          compactor: "Some.Remote.Compactor",
          ratio: 0.01,
          keep_recent: 1
        )

      # Should fall back to local, which triggers LLM summary (not :skip).
      assert {:compact, _summary, _kept} = fun.(make_messages(3, 100))
    end
  end

  # --- integration with Agent ---

  describe "integration with Agent" do
    alias Planck.Agent
    alias Planck.AI.Context

    defp unique_id, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    test "compact hook is called and compacted messages are sent to LLM" do
      parent = self()

      compact_fn = fn messages ->
        send(parent, {:compacted, length(messages)})
        summary_msg = text_message({:custom, :summary}, "Compacted history.")
        kept = Enum.take(messages, -1)
        {:compact, summary_msg, kept}
      end

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
           on_compact: compact_fn}
        )

      Agent.subscribe(agent)

      messages =
        Enum.map(1..5, fn i ->
          Message.new(:user, [{:text, "message #{i}"}])
        end)

      :sys.replace_state(agent, fn s -> %{s | messages: messages} end)

      Agent.prompt(agent, "go")
      assert_receive {:compacted, 6}, 1_000
      assert_receive {:llm_called_with, _}, 1_000
      assert_receive {:agent_event, :turn_end, _}, 1_000
    end
  end
end
