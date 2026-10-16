defmodule Planck.Headless.AskTest do
  use ExUnit.Case, async: false

  import Mox
  setup :verify_on_exit!

  alias Planck.Agent.MockAI
  alias Planck.AI.Model
  alias Planck.Headless

  setup do
    previous = Application.get_env(:planck_agent, :ai_client)
    Application.put_env(:planck_agent, :ai_client, MockAI)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:planck_agent, :ai_client)
        value -> Application.put_env(:planck_agent, :ai_client, value)
      end
    end)
  end

  defp rlcd_model do
    %Model{
      id: "decider-2b-v11",
      model: "decider-2b-v11",
      name: "decider",
      provider: :typesafe,
      type: :rlcd
    }
  end

  defp llm_model do
    %Model{
      id: "llama3.2",
      model: "llama3.2",
      name: "Llama 3.2",
      provider: :openai,
      context_window: 4_096,
      max_tokens: 2_048
    }
  end

  describe "ask/3" do
    test "returns :no_rlcd_model when no RLCD model is available" do
      assert {:error, :no_rlcd_model} = Headless.ask(%{}, %{}, [])
      assert {:error, :no_rlcd_model} = Headless.ask(%{}, %{}, [llm_model()])
    end

    test "evaluates with the first RLCD model and returns the answers map" do
      answers = %{"effect" => %{"type" => "choice", "choice" => "read_only", "confidence" => 1.0}}

      expect(MockAI, :evaluate, fn model, state, questions, [] ->
        assert model.type == :rlcd
        assert state == %{"command" => "ls", "cwd" => "/workspace"}
        assert is_map(questions)
        {:ok, %{object: answers}}
      end)

      state = %{"command" => "ls", "cwd" => "/workspace"}
      assert {:ok, ^answers} = Headless.ask(state, %{}, [llm_model(), rlcd_model()])
    end

    test "propagates evaluation errors" do
      expect(MockAI, :evaluate, fn _model, _state, _qs, _opts -> {:error, :unauthorized} end)

      assert {:error, :unauthorized} = Headless.ask(%{}, %{}, [rlcd_model()])
    end
  end
end
