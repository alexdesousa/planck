defmodule Planck.AITest do
  use ExUnit.Case, async: true

  import Mox

  alias Planck.AI
  alias Planck.AI.{Context, Message, Model}

  setup :verify_on_exit!

  @model %Model{
    id: "claude-sonnet-4-6",
    name: "Claude Sonnet 4.6",
    provider: :anthropic,
    context_window: 200_000,
    max_tokens: 8_096
  }

  @context %Context{
    system: "You are helpful.",
    messages: [%Message{role: :user, content: [{:text, "Hello"}]}]
  }

  defp mock_stream(chunks) do
    expect(Planck.AI.MockReqLLM, :stream_text, fn _model, _messages, _opts ->
      {:ok, %{stream: chunks}}
    end)
  end

  describe "stream/3" do
    test "emits StreamEvent tuples from req_llm chunks" do
      mock_stream([
        %{type: :content, text: "Hello", id: nil, name: nil, arguments: nil, metadata: %{}},
        %{
          type: :meta,
          metadata: %{finish_reason: :stop, usage: %{input_tokens: 5, output_tokens: 3}},
          text: nil,
          id: nil,
          name: nil,
          arguments: nil
        }
      ])

      events = AI.stream(@model, @context) |> Enum.to_list()
      assert {:text_delta, "Hello"} in events
      assert Enum.any?(events, &match?({:done, _}, &1))
    end

    test "returns [{:error, reason}] when req_llm fails" do
      expect(Planck.AI.MockReqLLM, :stream_text, fn _model, _messages, _opts ->
        {:error, :timeout}
      end)

      assert AI.stream(@model, @context) |> Enum.to_list() == [{:error, :timeout}]
    end

    test "forwards opts to req_llm" do
      expect(Planck.AI.MockReqLLM, :stream_text, fn _model, _messages, opts ->
        assert opts[:temperature] == 0.5
        {:ok, %{stream: []}}
      end)

      AI.stream(@model, @context, temperature: 0.5) |> Enum.to_list()
    end

    test "merges model default_opts with caller opts, caller wins" do
      model = %{@model | default_opts: [temperature: 0.3, top_p: 0.9]}

      expect(Planck.AI.MockReqLLM, :stream_text, fn _model, _messages, opts ->
        assert opts[:temperature] == 0.8
        assert opts[:top_p] == 0.9
        {:ok, %{stream: []}}
      end)

      AI.stream(model, @context, temperature: 0.8) |> Enum.to_list()
    end
  end

  describe "complete/3" do
    test "returns {:ok, %Message{}} assembling text from stream events" do
      mock_stream([
        %{type: :content, text: "World", id: nil, name: nil, arguments: nil, metadata: %{}},
        %{
          type: :meta,
          metadata: %{finish_reason: :stop, usage: %{input_tokens: 5, output_tokens: 1}},
          text: nil,
          id: nil,
          name: nil,
          arguments: nil
        }
      ])

      assert {:ok, %Message{role: :assistant, content: [{:text, "World"}]}} =
               AI.complete(@model, @context)
    end

    test "assembles tool calls from stream events" do
      mock_stream([
        %{
          type: :tool_call,
          name: "bash",
          text: nil,
          arguments: nil,
          metadata: %{id: "tc_1", index: 0}
        },
        %{
          type: :meta,
          metadata: %{tool_call_args: %{index: 0, fragment: "\"command\":\"ls\"}"}},
          text: nil,
          id: nil,
          name: nil,
          arguments: nil
        },
        %{
          type: :meta,
          metadata: %{finish_reason: :tool_calls, usage: %{input_tokens: 10, output_tokens: 5}},
          text: nil,
          id: nil,
          name: nil,
          arguments: nil
        }
      ])

      assert {:ok, %Message{content: [{:tool_call, "tc_1", "bash", %{"command" => "ls"}}]}} =
               AI.complete(@model, @context)
    end

    test "returns {:error, reason} when req_llm fails" do
      expect(Planck.AI.MockReqLLM, :stream_text, fn _model, _messages, _opts ->
        {:error, :unauthorized}
      end)

      assert {:error, :unauthorized} = AI.complete(@model, @context)
    end

    test "returns {:error, reason} on stream error event" do
      expect(Planck.AI.MockReqLLM, :stream_text, fn _model, _messages, _opts ->
        {:error, :stream_disconnected}
      end)

      assert {:error, :stream_disconnected} = AI.complete(@model, @context)
    end
  end
end
