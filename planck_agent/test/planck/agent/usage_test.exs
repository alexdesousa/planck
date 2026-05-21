defmodule Planck.Agent.UsageTest do
  use ExUnit.Case, async: true

  alias Planck.Agent.Usage

  describe "new/0" do
    test "returns zeroed struct" do
      u = Usage.new()
      assert u.input_tokens == 0
      assert u.output_tokens == 0
      assert u.cost == 0.0
    end
  end

  describe "from_opts/1" do
    test "returns zeroed struct when no opts given" do
      u = Usage.from_opts([])
      assert u.input_tokens == 0
      assert u.output_tokens == 0
      assert u.cost == 0.0
    end

    test "seeds token counts from :usage map" do
      u = Usage.from_opts(usage: %{input_tokens: 100, output_tokens: 50})
      assert u.input_tokens == 100
      assert u.output_tokens == 50
    end

    test "seeds cost from :cost opt" do
      u = Usage.from_opts(cost: 1.5)
      assert u.cost == 1.5
    end

    test "handles nil :usage opt" do
      u = Usage.from_opts(usage: nil)
      assert u.input_tokens == 0
    end
  end

  describe "add_turn/4" do
    test "accumulates token counts" do
      u = Usage.new() |> Usage.add_turn(100, 50, nil)
      assert u.input_tokens == 100
      assert u.output_tokens == 50
    end

    test "accumulates across multiple turns" do
      u =
        Usage.new()
        |> Usage.add_turn(100, 50, nil)
        |> Usage.add_turn(200, 75, nil)

      assert u.input_tokens == 300
      assert u.output_tokens == 125
    end

    test "computes cost from model rates" do
      model = %{cost: %{input: 3.0, output: 15.0}}
      u = Usage.new() |> Usage.add_turn(1_000_000, 1_000_000, model)
      assert_in_delta u.cost, 18.0, 0.001
    end

    test "leaves cost unchanged when model has no rates" do
      u = Usage.new() |> Usage.add_turn(100, 50, nil)
      assert u.cost == 0.0

      u2 = Usage.new() |> Usage.add_turn(100, 50, %{})
      assert u2.cost == 0.0
    end

    test "accumulates cost across turns" do
      model = %{cost: %{input: 1.0, output: 2.0}}

      u =
        Usage.new()
        |> Usage.add_turn(1_000_000, 0, model)
        |> Usage.add_turn(0, 1_000_000, model)

      assert_in_delta u.cost, 3.0, 0.001
    end
  end
end
