defmodule Planck.Agent.MessageTest do
  use ExUnit.Case, async: true

  alias Planck.Agent.Message

  describe "new/3" do
    test "builds a message with generated id and timestamp" do
      msg = Message.new(:user, [{:text, "hello"}])
      assert msg.role == :user
      assert msg.content == [{:text, "hello"}]
      assert is_binary(msg.id)
      assert %DateTime{} = msg.timestamp
      assert msg.metadata == %{}
    end

    test "accepts metadata" do
      msg = Message.new(:user, [{:text, "hi"}], %{source: :cli})
      assert msg.metadata == %{source: :cli}
    end

    test "accepts custom roles" do
      msg = Message.new({:custom, :agent_response}, [{:text, "done"}])
      assert msg.role == {:custom, :agent_response}
    end

    test "generates unique ids" do
      ids = for _ <- 1..10, do: Message.new(:user, []).id
      assert length(Enum.uniq(ids)) == 10
    end
  end

  describe "estimate_tokens/1" do
    test "returns 0 for empty list" do
      assert Message.estimate_tokens([]) == 0
    end

    test "counts text content as chars / 4" do
      msg = Message.new(:user, [{:text, "abcd"}])
      assert Message.estimate_tokens([msg]) == 1
    end

    test "counts thinking content" do
      msg = Message.new(:assistant, [{:thinking, "abcdefgh"}])
      assert Message.estimate_tokens([msg]) == 2
    end

    test "counts tool_result content" do
      msg = Message.new(:tool_result, [{:tool_result, "id1", "abcd"}])
      assert Message.estimate_tokens([msg]) == 1
    end

    test "ignores other content parts (tool_call, image_url)" do
      msg = Message.new(:assistant, [{:tool_call, "id1", "bash", %{}}, {:image_url, "http://x"}])
      assert Message.estimate_tokens([msg]) == 0
    end

    test "sums across all messages and all content parts" do
      msgs = [
        Message.new(:user, [{:text, "aaaabbbb"}]),
        Message.new(:assistant, [{:text, "cccc"}, {:thinking, "dddddddd"}])
      ]

      # "aaaabbbb" = 8 chars → 2 tokens
      # "cccc" = 4 chars → 1 token
      # "dddddddd" = 8 chars → 2 tokens
      # total = 5
      assert Message.estimate_tokens(msgs) == 5
    end

    test "truncates division remainder" do
      # 5 chars → div(5, 4) = 1
      msg = Message.new(:user, [{:text, "abcde"}])
      assert Message.estimate_tokens([msg]) == 1
    end
  end

  describe "to_ai_messages/1" do
    test "converts user and assistant messages" do
      messages = [
        Message.new(:user, [{:text, "hello"}]),
        Message.new(:assistant, [{:text, "hi"}])
      ]

      result = Message.to_ai_messages(messages)
      assert length(result) == 2
      assert Enum.all?(result, &match?(%Planck.AI.Message{}, &1))
    end

    test "drops unknown {:custom, _} role messages" do
      messages = [
        Message.new(:user, [{:text, "hello"}]),
        Message.new({:custom, :compaction}, [{:text, "dropped"}]),
        Message.new(:assistant, [{:text, "hi"}])
      ]

      result = Message.to_ai_messages(messages)
      assert length(result) == 2
      assert Enum.all?(result, fn m -> m.role in [:user, :assistant, :tool_result] end)
    end

    test "converts {:custom, :agent_response} to :user so the orchestrator sees worker replies" do
      messages = [
        Message.new(:user, [{:text, "hello"}]),
        Message.new({:custom, :agent_response}, [{:text, "Feature built."}]),
        Message.new(:assistant, [{:text, "hi"}])
      ]

      result = Message.to_ai_messages(messages)
      assert length(result) == 3
      assert Enum.at(result, 1).role == :user
      assert Enum.at(result, 1).content == [{:text, "Feature built."}]
    end

    test "{:custom, :agent_response} with sender metadata formats as 'Response from <name>: ...'" do
      messages = [
        Message.new({:custom, :agent_response}, [{:text, "Done!"}], %{
          sender_id: "abc",
          sender_name: "builder"
        })
      ]

      [ai_msg] = Message.to_ai_messages(messages)
      assert ai_msg.role == :user
      assert ai_msg.content == [{:text, "Response from builder: Done!"}]
    end

    test "{:custom, :agent_response} without sender metadata passes text through unchanged" do
      messages = [
        Message.new({:custom, :agent_response}, [{:text, "Done!"}])
      ]

      [ai_msg] = Message.to_ai_messages(messages)
      assert ai_msg.role == :user
      assert ai_msg.content == [{:text, "Done!"}]
    end

    test "preserves content parts" do
      messages = [
        Message.new(:user, [{:text, "hello"}, {:image_url, "http://example.com/img.png"}])
      ]

      [ai_msg] = Message.to_ai_messages(messages)
      assert ai_msg.content == [{:text, "hello"}, {:image_url, "http://example.com/img.png"}]
    end

    test "returns empty list for all-custom messages" do
      messages = [
        Message.new({:custom, :compaction}, [{:text, "summary"}])
      ]

      assert Message.to_ai_messages(messages) == []
    end
  end
end
