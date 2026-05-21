defmodule Planck.Agent.TurnContextTest do
  use ExUnit.Case, async: true

  alias Planck.Agent.{Message, TurnContext}

  defp msg(role), do: Message.new(role, [{:text, "content"}])

  describe "messages_since_last_summary/1" do
    test "returns all messages when no summary exists" do
      msgs = [msg(:user), msg(:assistant)]
      assert TurnContext.messages_since_last_summary(msgs) == msgs
    end

    test "returns summary and tail when one summary exists" do
      summary = msg({:custom, :summary})
      msgs = [msg(:user), summary, msg(:assistant), msg(:user)]
      result = TurnContext.messages_since_last_summary(msgs)
      assert hd(result) == summary
      assert length(result) == 3
    end

    test "uses the latest summary when multiple exist" do
      s1 = msg({:custom, :summary})
      s2 = msg({:custom, :summary})
      after_s2 = msg(:user)
      msgs = [msg(:user), s1, msg(:assistant), s2, after_s2]
      result = TurnContext.messages_since_last_summary(msgs)
      assert hd(result) == s2
      assert length(result) == 2
    end

    test "returns empty list for empty input" do
      assert TurnContext.messages_since_last_summary([]) == []
    end
  end

  describe "has_pending_input?/2" do
    test "returns false when no messages after stream_start" do
      msgs = [msg(:user), msg(:assistant)]
      refute TurnContext.has_pending_input?(msgs, 2)
    end

    test "returns true for user message after stream_start" do
      msgs = [msg(:assistant), msg(:user)]
      assert TurnContext.has_pending_input?(msgs, 1)
    end

    test "returns true for agent_response after stream_start" do
      msgs = [msg(:assistant), msg({:custom, :agent_response})]
      assert TurnContext.has_pending_input?(msgs, 1)
    end

    test "returns false for assistant message after stream_start" do
      msgs = [msg(:user), msg(:assistant)]
      refute TurnContext.has_pending_input?(msgs, 1)
    end

    test "returns false for empty messages" do
      refute TurnContext.has_pending_input?([], 0)
    end
  end
end
