defmodule Sidecar.SkillReflector.PromptTest do
  use ExUnit.Case, async: true

  alias Planck.Agent.Message
  alias Sidecar.SkillReflector.Prompt

  defp msg(role, text, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})
    Message.new(role, [{:text, text}], metadata)
  end

  defp tool_call_msg(name, args) do
    Message.new(:assistant, [{:tool_call, "id1", name, args}])
  end

  defp tool_result_msg(value) do
    Message.new(:tool_result, [{:tool_result, "id1", value}])
  end

  describe "build/2" do
    test "contains mandatory list_skills instruction" do
      prompt = Prompt.build([], "orchestrator")
      assert prompt =~ "list_skills"
      assert prompt =~ "Always call"
    end

    test "contains all required skill sections" do
      prompt = Prompt.build([], "orchestrator")
      assert prompt =~ "When to Use"
      assert prompt =~ "Quick Reference"
      assert prompt =~ "Procedure"
      assert prompt =~ "Pitfalls"
      assert prompt =~ "Verification"
    end

    test "contains write_skill and load_skill tool descriptions" do
      prompt = Prompt.build([], "orchestrator")
      assert prompt =~ "write_skill"
      assert prompt =~ "load_skill"
    end

    test "includes user message in turn summary" do
      messages = [msg(:user, "How do I run the tests?")]
      prompt = Prompt.build(messages, "orchestrator")
      assert prompt =~ "How do I run the tests?"
      assert prompt =~ "User:"
    end

    test "includes assistant text labelled with agent name" do
      messages = [msg(:assistant, "Run mix test to execute the suite.")]
      prompt = Prompt.build(messages, "Builder")
      assert prompt =~ "Builder:"
      assert prompt =~ "Run mix test"
    end

    test "includes tool call name in summary" do
      messages = [tool_call_msg("bash", %{"command" => "mix test"})]
      prompt = Prompt.build(messages, "orchestrator")
      assert prompt =~ "bash"
      assert prompt =~ "Tool:"
    end

    test "includes tool result truncated to 300 chars" do
      long_result = String.duplicate("x", 400)
      messages = [tool_result_msg(long_result)]
      prompt = Prompt.build(messages, "orchestrator")
      assert prompt =~ "Result:"
      assert prompt =~ "…"
      refute prompt =~ String.duplicate("x", 301)
    end

    test "includes agent_response with sender name" do
      messages = [msg({:custom, :agent_response}, "Task done.", metadata: %{sender_name: "Builder"})]
      prompt = Prompt.build(messages, "orchestrator")
      assert prompt =~ "Builder:"
      assert prompt =~ "Task done."
    end

    test "ignores tool_result and tool_call-only messages that produce no text" do
      messages = [
        msg(:user, "do something"),
        msg(:assistant, "")
      ]
      prompt = Prompt.build(messages, "orchestrator")
      assert prompt =~ "do something"
    end
  end
end
