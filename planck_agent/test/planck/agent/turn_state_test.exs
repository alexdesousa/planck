defmodule Planck.Agent.TurnStateTest do
  use ExUnit.Case, async: true

  alias Planck.Agent.{Message, TurnState}

  describe "new/0" do
    test "returns zeroed struct" do
      ts = TurnState.new()
      assert ts.index == 0
      assert ts.checkpoints == []
    end
  end

  describe "advance/1" do
    test "increments the index" do
      ts = TurnState.new() |> TurnState.advance() |> TurnState.advance()
      assert ts.index == 2
    end

    test "does not affect checkpoints" do
      ts = TurnState.new() |> TurnState.push_checkpoint(5) |> TurnState.advance()
      assert ts.checkpoints == [5]
    end
  end

  describe "push_checkpoint/2" do
    test "prepends to checkpoints stack" do
      ts =
        TurnState.new()
        |> TurnState.push_checkpoint(0)
        |> TurnState.push_checkpoint(3)

      assert ts.checkpoints == [3, 0]
    end
  end

  describe "rebuild_checkpoints/2" do
    test "builds checkpoints from user message indices" do
      msgs = [
        Message.new(:user, [{:text, "hi"}]),
        Message.new(:assistant, [{:text, "ok"}]),
        Message.new(:user, [{:text, "again"}])
      ]

      ts = TurnState.new() |> TurnState.advance() |> TurnState.rebuild_checkpoints(msgs)
      assert ts.checkpoints == [2, 0]
      assert ts.index == 1
    end

    test "returns empty checkpoints for message list with no user messages" do
      msgs = [Message.new(:assistant, [{:text, "ok"}])]
      ts = TurnState.rebuild_checkpoints(TurnState.new(), msgs)
      assert ts.checkpoints == []
    end
  end
end
