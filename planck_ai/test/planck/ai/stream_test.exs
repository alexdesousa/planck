defmodule Planck.AI.StreamTest do
  use ExUnit.Case, async: true

  alias Planck.AI.Stream

  defp chunk(attrs), do: Map.merge(%{id: nil, name: nil, arguments: nil, metadata: %{}}, attrs)

  describe "from_req_llm/1" do
    test "normalizes :content chunks to :text_delta" do
      chunks = [chunk(%{type: :content, text: "Hello"})]
      assert Stream.from_req_llm(chunks) |> Enum.to_list() == [{:text_delta, "Hello"}]
    end

    test "normalizes :thinking chunks to :thinking_delta" do
      chunks = [chunk(%{type: :thinking, text: "Let me think..."})]

      assert Stream.from_req_llm(chunks) |> Enum.to_list() == [
               {:thinking_delta, "Let me think..."}
             ]
    end

    test "normalizes :tool_call chunks to :tool_call_complete" do
      chunks = [
        chunk(%{type: :tool_call, name: "bash", metadata: %{id: "tc_1", index: 0}}),
        chunk(%{
          type: :meta,
          metadata: %{tool_call_args: %{index: 0, fragment: "\"command\":\"ls\"}"}}
        }),
        chunk(%{
          type: :meta,
          metadata: %{finish_reason: :tool_calls, usage: %{input_tokens: 5, output_tokens: 3}}
        })
      ]

      assert [
               {:tool_call_complete, %{id: "tc_1", name: "bash", args: %{"command" => "ls"}}},
               {:done, _}
             ] = Stream.from_req_llm(chunks) |> Enum.to_list()
    end

    test "normalizes :meta chunks to :done" do
      chunks = [
        chunk(%{
          type: :meta,
          metadata: %{finish_reason: :stop, usage: %{input_tokens: 10, output_tokens: 5}}
        })
      ]

      assert [{:done, %{stop_reason: :stop, usage: %{input_tokens: 10, output_tokens: 5}}}] =
               Stream.from_req_llm(chunks) |> Enum.to_list()
    end

    test "emits :error for unknown chunk types" do
      chunks = [chunk(%{type: :unknown_type})]
      assert [{:error, {:unknown_chunk, _}}] = Stream.from_req_llm(chunks) |> Enum.to_list()
    end

    test "handles a full response sequence" do
      chunks = [
        chunk(%{type: :content, text: "The answer is "}),
        chunk(%{type: :content, text: "42."}),
        chunk(%{
          type: :meta,
          metadata: %{finish_reason: :stop, usage: %{input_tokens: 5, output_tokens: 3}}
        })
      ]

      events = Stream.from_req_llm(chunks) |> Enum.to_list()

      assert events == [
               {:text_delta, "The answer is "},
               {:text_delta, "42."},
               {:done, %{stop_reason: :stop, usage: %{input_tokens: 5, output_tokens: 3}}}
             ]
    end

    test "handles tool call argument fragment that already includes opening brace" do
      chunks = [
        chunk(%{type: :tool_call, name: "ls", metadata: %{id: "tc_1", index: 0}}),
        chunk(%{
          type: :meta,
          metadata: %{tool_call_args: %{index: 0, fragment: "{\"path\":\"/tmp\"}"}}
        }),
        chunk(%{
          type: :meta,
          metadata: %{finish_reason: :stop, usage: %{input_tokens: 1, output_tokens: 1}}
        })
      ]

      assert [{:tool_call_complete, %{args: %{"path" => "/tmp"}}}, {:done, _}] =
               Stream.from_req_llm(chunks) |> Enum.to_list()
    end

    test "returns empty args when tool call argument fragment is malformed JSON" do
      chunks = [
        chunk(%{type: :tool_call, name: "ls", metadata: %{id: "tc_1", index: 0}}),
        chunk(%{type: :meta, metadata: %{tool_call_args: %{index: 0, fragment: "not json"}}}),
        chunk(%{
          type: :meta,
          metadata: %{finish_reason: :stop, usage: %{input_tokens: 1, output_tokens: 1}}
        })
      ]

      assert [{:tool_call_complete, %{args: %{}}}, {:done, _}] =
               Stream.from_req_llm(chunks) |> Enum.to_list()
    end

    test "tool_call with nil arguments defaults to empty map" do
      chunks = [
        chunk(%{type: :tool_call, name: "read", metadata: %{id: "tc_1", index: 0}}),
        chunk(%{
          type: :meta,
          metadata: %{finish_reason: :stop, usage: %{input_tokens: 1, output_tokens: 1}}
        })
      ]

      assert [{:tool_call_complete, %{args: %{}}}, {:done, _}] =
               Stream.from_req_llm(chunks) |> Enum.to_list()
    end

    test "converts exceptions raised during stream enumeration to error events" do
      bad_stream = Elixir.Stream.map([:go], fn _ -> raise RuntimeError, "connection lost" end)

      assert [{:error, %RuntimeError{message: "connection lost"}}] =
               Stream.from_req_llm(bad_stream) |> Enum.to_list()
    end

    test "emits error event and halts when exception occurs mid-stream" do
      bad_stream =
        Elixir.Stream.resource(
          fn -> 0 end,
          fn
            0 -> {[chunk(%{type: :content, text: "partial"})], 1}
            1 -> raise RuntimeError, "disconnected"
          end,
          fn _ -> :ok end
        )

      events = Stream.from_req_llm(bad_stream) |> Enum.to_list()
      assert {:text_delta, "partial"} = hd(events)
      assert {:error, %RuntimeError{message: "disconnected"}} = List.last(events)
    end
  end
end
