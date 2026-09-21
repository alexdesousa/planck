defmodule Planck.AI.ContextTest do
  use ExUnit.Case, async: true

  alias Planck.AI.{Context, Message, Tool}

  describe "estimate_tokens/1" do
    test "counts the system prompt, not just the conversation" do
      with_system = %Context{system: String.duplicate("a", 400), messages: [], tools: []}
      without_system = %Context{system: nil, messages: [], tools: []}

      assert Context.estimate_tokens(with_system) == 100
      assert Context.estimate_tokens(without_system) == 0
    end

    test "counts text and thinking content in messages" do
      context = %Context{
        messages: [
          %Message{role: :user, content: [{:text, String.duplicate("a", 40)}]},
          %Message{role: :assistant, content: [{:thinking, String.duplicate("b", 40)}]}
        ]
      }

      assert Context.estimate_tokens(context) == 20
    end

    test "counts tool calls and tool results" do
      context = %Context{
        messages: [
          %Message{
            role: :assistant,
            content: [{:tool_call, "t1", "bash", %{"command" => "ls"}}]
          },
          %Message{role: :tool_result, content: [{:tool_result, "t1", "file1\nfile2"}]}
        ]
      }

      assert Context.estimate_tokens(context) > 0
    end

    test "counts tool schemas — a schema-heavy tool list is real payload" do
      tool = Tool.new(name: "bash", description: "Run a shell command", parameters: %{})
      without_tools = %Context{tools: []}
      with_tools = %Context{tools: [tool]}

      assert Context.estimate_tokens(with_tools) > Context.estimate_tokens(without_tools)
    end

    test "sums system, messages, and tools together" do
      tool = Tool.new(name: "bash", description: "Run a shell command", parameters: %{})

      context = %Context{
        system: String.duplicate("a", 40),
        messages: [%Message{role: :user, content: [{:text, String.duplicate("b", 40)}]}],
        tools: [tool]
      }

      system_only = Context.estimate_tokens(%Context{system: context.system})
      messages_only = Context.estimate_tokens(%Context{messages: context.messages})
      tools_only = Context.estimate_tokens(%Context{tools: context.tools})

      assert Context.estimate_tokens(context) == system_only + messages_only + tools_only
    end
  end
end
