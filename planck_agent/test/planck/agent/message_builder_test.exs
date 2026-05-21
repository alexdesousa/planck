defmodule Planck.Agent.MessageBuilderTest do
  use ExUnit.Case, async: true

  alias Planck.Agent.{MessageBuilder, StreamBuffer}

  describe "normalize_content/1" do
    test "wraps a string in a text tuple" do
      assert MessageBuilder.normalize_content("hello") == [{:text, "hello"}]
    end

    test "passes a list through unchanged" do
      parts = [{:text, "a"}, {:text, "b"}]
      assert MessageBuilder.normalize_content(parts) == parts
    end
  end

  describe "build_assistant/1" do
    test "produces text-only message" do
      buf = %StreamBuffer{text: "hello"}
      msg = MessageBuilder.build_assistant(buf)
      assert msg.role == :assistant
      assert msg.content == [{:text, "hello"}]
    end

    test "produces thinking + text message" do
      buf = %StreamBuffer{text: "reply", thinking: "chain of thought"}
      msg = MessageBuilder.build_assistant(buf)
      assert msg.role == :assistant
      assert {:thinking, "chain of thought"} in msg.content
      assert {:text, "reply"} in msg.content
    end

    test "produces tool-call-only message" do
      buf = %StreamBuffer{calls: [%{id: "c1", name: "bash", args: %{"command" => "ls"}}]}
      msg = MessageBuilder.build_assistant(buf)
      assert msg.role == :assistant
      assert {:tool_call, "c1", "bash", %{"command" => "ls"}} in msg.content
      refute Enum.any?(msg.content, &match?({:text, _}, &1))
    end

    test "orders content: thinking, text, tool calls" do
      buf = %StreamBuffer{
        text: "text",
        thinking: "think",
        calls: [%{id: "c1", name: "bash", args: %{}}]
      }

      msg = MessageBuilder.build_assistant(buf)
      assert [{:thinking, _}, {:text, _}, {:tool_call, _, _, _}] = msg.content
    end
  end

  describe "build_tool_result/1" do
    test "builds message from ok results" do
      results = [{"c1", {:ok, "output"}}]
      msg = MessageBuilder.build_tool_result(results)
      assert msg.role == :tool_result
      assert {:tool_result, "c1", "output"} in msg.content
    end

    test "formats error results" do
      results = [{"c1", {:error, "boom"}}]
      msg = MessageBuilder.build_tool_result(results)
      [{:tool_result, "c1", value}] = msg.content
      assert value =~ "Error: boom"
    end

    test "inspects non-string ok values" do
      results = [{"c1", {:ok, 42}}]
      msg = MessageBuilder.build_tool_result(results)
      [{:tool_result, "c1", value}] = msg.content
      assert value =~ "42"
    end

    test "preserves order of multiple results" do
      results = [{"c1", {:ok, "first"}}, {"c2", {:ok, "second"}}]
      msg = MessageBuilder.build_tool_result(results)
      [{:tool_result, "c1", _}, {:tool_result, "c2", _}] = msg.content
    end
  end

  describe "build_tool_result/1 — truncation" do
    defp tool_value(output),
      do: hd(MessageBuilder.build_tool_result([{"c1", {:ok, output}}]).content) |> elem(2)

    test "passes short strings through unchanged" do
      assert tool_value("hello") == "hello"
    end

    test "truncates by line count" do
      lines = Enum.map_join(1..2_001, "\n", &Integer.to_string/1)
      result = tool_value(lines)
      assert result =~ "[output truncated]"
      assert length(String.split(result, "\n")) <= 2_002
    end

    test "truncates by byte size" do
      large = String.duplicate("a", 51_000)
      result = tool_value(large)
      assert result =~ "[output truncated]"
      assert byte_size(result) < 55_000
    end

    test "handles non-UTF-8 binary" do
      binary = <<0xFF, 0xFE, 0x00>>
      result = tool_value(binary)
      assert result =~ "binary file"
      assert result =~ "bytes"
    end
  end
end
