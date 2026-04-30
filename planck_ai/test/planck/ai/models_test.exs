defmodule Planck.AI.ModelsTest do
  use ExUnit.Case, async: true

  import Mox

  setup :verify_on_exit!

  alias Planck.AI
  alias Planck.AI.Model
  alias Planck.AI.Models.{Anthropic, Google, LlamaCpp, Ollama, OpenAI}

  describe "Anthropic.all/1" do
    test "returns models with :anthropic provider" do
      models = Anthropic.all()
      assert is_list(models)
      assert Enum.all?(models, &(&1.provider == :anthropic))
    end

    test "all models have required fields" do
      for m <- Anthropic.all() do
        assert is_binary(m.id) and m.id != ""
        assert is_integer(m.context_window) and m.context_window > 0
        assert is_integer(m.max_tokens) and m.max_tokens > 0
      end
    end
  end

  describe "OpenAI.all/1" do
    test "returns models with :openai provider" do
      models = OpenAI.all()
      assert is_list(models)
      assert Enum.all?(models, &(&1.provider == :openai))
    end

    test "all models have required fields" do
      for m <- OpenAI.all() do
        assert is_binary(m.id) and m.id != ""
        assert is_integer(m.context_window) and m.context_window > 0
        assert is_integer(m.max_tokens) and m.max_tokens > 0
      end
    end
  end

  describe "Google.all/1" do
    test "returns models with :google provider" do
      models = Google.all()
      assert is_list(models)
      assert Enum.all?(models, &(&1.provider == :google))
    end

    test "all models have required fields" do
      for m <- Google.all() do
        assert is_binary(m.id) and m.id != ""
        assert is_integer(m.context_window) and m.context_window > 0
        assert is_integer(m.max_tokens) and m.max_tokens > 0
      end
    end
  end

  describe "Ollama.model/2" do
    test "builds a model with defaults" do
      model = Ollama.model("llama3.2")
      assert %Model{} = model
      assert model.id == "llama3.2"
      assert model.provider == :ollama
      assert model.base_url == "http://localhost:11434"
      assert model.context_window == 4_096
      assert model.max_tokens == 2_048
      refute model.supports_thinking
    end

    test "accepts custom base_url" do
      model = Ollama.model("mistral", base_url: "http://10.0.0.5:11434")
      assert model.base_url == "http://10.0.0.5:11434"
    end

    test "accepts custom context_window and max_tokens" do
      model = Ollama.model("deepseek-r1", context_window: 64_000, max_tokens: 8_192)
      assert model.context_window == 64_000
      assert model.max_tokens == 8_192
    end
  end

  describe "Ollama.all/1" do
    test "returns models parsed from /api/tags response" do
      expect(Planck.AI.MockHTTPClient, :get, fn _url, _opts ->
        body = %{
          "models" => [
            %{"name" => "llama3.2:latest", "details" => %{"parameter_size" => "3.2B"}},
            %{"name" => "mistral:7b", "details" => %{}}
          ]
        }

        {:ok, %{status: 200, body: body}}
      end)

      models = Ollama.all()
      assert length(models) == 2
      assert Enum.all?(models, &(&1.provider == :ollama))
      assert Enum.any?(models, &(&1.id == "llama3.2:latest"))
      llama = Enum.find(models, &(&1.id == "llama3.2:latest"))
      assert llama.name == "llama3.2 (3.2B)"
    end

    test "returns [] and logs on HTTP error" do
      expect(Planck.AI.MockHTTPClient, :get, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      assert Ollama.all() == []
    end

    test "returns [] and logs on non-200 status" do
      expect(Planck.AI.MockHTTPClient, :get, fn _url, _opts ->
        {:ok, %{status: 503, body: "unavailable"}}
      end)

      assert Ollama.all() == []
    end

    test "respects custom base_url" do
      expect(Planck.AI.MockHTTPClient, :get, fn url, _opts ->
        assert String.starts_with?(url, "http://10.0.0.5:11434")
        {:ok, %{status: 200, body: %{"models" => []}}}
      end)

      assert Ollama.all(base_url: "http://10.0.0.5:11434") == []
    end
  end

  describe "LlamaCpp.model/2" do
    test "builds a model with defaults" do
      model = LlamaCpp.model("llama3.2")
      assert %Model{} = model
      assert model.id == "llama3.2"
      assert model.name == "llama3.2"
      assert model.provider == :llama_cpp
      assert model.base_url == "http://localhost:8080"
      assert model.context_window == 4_096
      assert model.max_tokens == 2_048
      assert model.default_opts == []
      refute model.supports_thinking
    end

    test "accepts custom base_url" do
      model = LlamaCpp.model("mistral", base_url: "http://10.0.0.5:8080")
      assert model.base_url == "http://10.0.0.5:8080"
    end

    test "accepts custom context_window and max_tokens" do
      model = LlamaCpp.model("custom", context_window: 32_768, max_tokens: 4_096)
      assert model.context_window == 32_768
      assert model.max_tokens == 4_096
    end

    test "accepts a custom name" do
      model = LlamaCpp.model("Qwen3-Coder-Next-UD-Q4_K_XL", name: "Qwen3 Coder Next")
      assert model.name == "Qwen3 Coder Next"
    end

    test "accepts default_opts" do
      model =
        LlamaCpp.model("gemma-4-26B",
          default_opts: [temperature: 1.0, top_p: 0.95, top_k: 64]
        )

      assert model.default_opts == [temperature: 1.0, top_p: 0.95, top_k: 64]
    end
  end

  describe "LlamaCpp.all/1" do
    test "returns models parsed from /v1/models response" do
      expect(Planck.AI.MockHTTPClient, :get, fn _url, _opts ->
        body = %{
          "data" => [
            %{"id" => "gemma-4-26B", "object" => "model"},
            %{"id" => "qwen3-coder", "object" => "model"}
          ]
        }

        {:ok, %{status: 200, body: body}}
      end)

      models = LlamaCpp.all(base_url: "http://localhost:8080")
      assert length(models) == 2
      assert Enum.all?(models, &(&1.provider == :llama_cpp))
      assert Enum.any?(models, &(&1.id == "gemma-4-26B"))
    end

    test "returns [] on HTTP error" do
      expect(Planck.AI.MockHTTPClient, :get, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      assert LlamaCpp.all() == []
    end

    test "passes api_key as bearer token in request opts" do
      expect(Planck.AI.MockHTTPClient, :get, fn _url, opts ->
        assert opts[:auth] == {:bearer, "my-key"}
        {:ok, %{status: 200, body: %{"data" => []}}}
      end)

      LlamaCpp.all(base_url: "http://localhost:8080", api_key: "my-key")
    end
  end

  describe "Planck.AI.list_providers/0" do
    test "returns all five providers" do
      providers = AI.list_providers()
      assert :anthropic in providers
      assert :openai in providers
      assert :google in providers
      assert :ollama in providers
      assert :llama_cpp in providers
    end
  end

  describe "Planck.AI.list_models/1" do
    test "returns models for catalog providers" do
      assert is_list(AI.list_models(:anthropic))
      assert is_list(AI.list_models(:openai))
      assert is_list(AI.list_models(:google))
    end

    test "returns empty list for unknown provider" do
      assert AI.list_models(:unknown) == []
    end
  end

  describe "Planck.AI.get_model/2" do
    test "returns {:ok, model} for a known anthropic model" do
      [first | _] = AI.list_models(:anthropic)
      assert {:ok, %Model{id: id, provider: :anthropic}} = AI.get_model(:anthropic, first.id)
      assert id == first.id
    end

    test "returns {:error, :not_found} for unknown id" do
      assert {:error, :not_found} = AI.get_model(:anthropic, "does-not-exist")
    end

    test "returns {:error, :not_found} for unknown provider" do
      assert {:error, :not_found} = AI.get_model(:unknown, "any-id")
    end
  end
end
