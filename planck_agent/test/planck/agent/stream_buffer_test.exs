defmodule Planck.Agent.StreamBufferTest do
  use ExUnit.Case, async: true

  alias Planck.Agent.StreamBuffer

  describe "new/0" do
    test "returns an empty buffer" do
      buf = StreamBuffer.new()
      assert buf.text == ""
      assert buf.thinking == ""
      assert buf.calls == []
    end
  end

  describe "append_text/2" do
    test "accumulates text deltas in order" do
      buf =
        StreamBuffer.new()
        |> StreamBuffer.append_text("hello ")
        |> StreamBuffer.append_text("world")

      assert buf.text == "hello world"
    end

    test "does not affect other fields" do
      buf = StreamBuffer.new() |> StreamBuffer.append_text("hi")
      assert buf.thinking == ""
      assert buf.calls == []
    end
  end

  describe "append_thinking/2" do
    test "accumulates thinking deltas in order" do
      buf =
        StreamBuffer.new()
        |> StreamBuffer.append_thinking("step 1 ")
        |> StreamBuffer.append_thinking("step 2")

      assert buf.thinking == "step 1 step 2"
    end

    test "does not affect other fields" do
      buf = StreamBuffer.new() |> StreamBuffer.append_thinking("think")
      assert buf.text == ""
      assert buf.calls == []
    end
  end

  describe "add_call/2" do
    test "appends tool calls in order" do
      call1 = %{id: "c1", name: "bash", args: %{}}
      call2 = %{id: "c2", name: "read", args: %{}}

      buf =
        StreamBuffer.new()
        |> StreamBuffer.add_call(call1)
        |> StreamBuffer.add_call(call2)

      assert buf.calls == [call1, call2]
    end

    test "does not affect other fields" do
      buf = StreamBuffer.new() |> StreamBuffer.add_call(%{id: "c1", name: "bash", args: %{}})
      assert buf.text == ""
      assert buf.thinking == ""
    end
  end
end
