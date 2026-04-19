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

    test "drops {:custom, _} role messages" do
      messages = [
        Message.new(:user, [{:text, "hello"}]),
        Message.new({:custom, :compaction}, [{:text, "summary"}]),
        Message.new({:custom, :agent_response}, [{:text, "response"}]),
        Message.new(:assistant, [{:text, "hi"}])
      ]

      result = Message.to_ai_messages(messages)
      assert length(result) == 2
      assert Enum.all?(result, fn m -> m.role in [:user, :assistant, :tool_result] end)
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
