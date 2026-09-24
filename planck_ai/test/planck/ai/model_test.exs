defmodule Planck.AI.ModelTest do
  use ExUnit.Case, async: true

  alias Planck.AI.Model

  describe "struct defaults" do
    test "supports_thinking defaults to false" do
      model = %Model{id: "x", name: "x", provider: :openai, context_window: 1, max_tokens: 1}
      refute model.supports_thinking
    end

    test "input_types defaults to [:text]" do
      model = %Model{id: "x", name: "x", provider: :openai, context_window: 1, max_tokens: 1}
      assert model.input_types == [:text]
    end

    test "base_url defaults to nil" do
      model = %Model{id: "x", name: "x", provider: :openai, context_window: 1, max_tokens: 1}
      assert is_nil(model.base_url)
    end

    test "cost defaults to zero map" do
      model = %Model{id: "x", name: "x", provider: :openai, context_window: 1, max_tokens: 1}
      assert model.cost == %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0}
    end

    test "type defaults to :llm" do
      model = %Model{id: "x", name: "x", provider: :openai, context_window: 1, max_tokens: 1}
      assert model.type == :llm
    end

    test "type: :rlcd round-trips" do
      model = %Model{
        id: "x",
        name: "x",
        provider: :typesafe,
        type: :rlcd,
        context_window: 1,
        max_tokens: 1
      }

      assert model.type == :rlcd
    end
  end

  describe "providers/0" do
    test "includes :typesafe" do
      assert :typesafe in Model.providers()
    end
  end

  describe "types/0" do
    test "returns :llm and :rlcd" do
      assert Model.types() == [:llm, :rlcd]
    end
  end
end
