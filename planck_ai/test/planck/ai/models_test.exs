defmodule Planck.AI.ModelsTest do
  use ExUnit.Case, async: true

  import Mox

  setup :verify_on_exit!

  alias Planck.AI
  alias Planck.AI.Model
  alias Planck.AI.Models.{Anthropic, Google, OpenAI}

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
    test "returns models with :openai provider from LLMDB when no base_url" do
      models = OpenAI.all()
      assert is_list(models)
      assert Enum.all?(models, &(&1.provider == :openai))
    end

    test "all LLMDB models have required fields" do
      for m <- OpenAI.all() do
        assert is_binary(m.id) and m.id != ""
        assert is_integer(m.context_window) and m.context_window > 0
        assert is_integer(m.max_tokens) and m.max_tokens > 0
      end
    end

    test "queries /models endpoint when base_url is provided" do
      expect(Planck.AI.MockHTTPClient, :get, fn _url, _opts ->
        body = %{
          "data" => [
            %{"id" => "meta/llama-3.3-70b-instruct", "object" => "model"},
            %{"id" => "mistralai/mixtral-8x7b", "object" => "model"}
          ]
        }

        {:ok, %{status: 200, body: body}}
      end)

      models = OpenAI.all(base_url: "https://integrate.api.nvidia.com/v1", identifier: "NVIDIA")
      assert length(models) == 2
      assert Enum.all?(models, &(&1.provider == :openai))
      assert Enum.all?(models, &(&1.identifier == "NVIDIA"))
      assert Enum.any?(models, &(&1.id == "meta/llama-3.3-70b-instruct"))
    end

    test "hits the /models path on the base_url" do
      expect(Planck.AI.MockHTTPClient, :get, fn url, _opts ->
        assert url == "https://integrate.api.nvidia.com/v1/models"
        {:ok, %{status: 200, body: %{"data" => []}}}
      end)

      OpenAI.all(base_url: "https://integrate.api.nvidia.com/v1")
    end

    test "passes api_key as bearer token using identifier env var" do
      System.put_env("NVIDIA_API_KEY", "test-key")
      on_exit(fn -> System.delete_env("NVIDIA_API_KEY") end)

      expect(Planck.AI.MockHTTPClient, :get, fn _url, opts ->
        assert opts[:auth] == {:bearer, "test-key"}
        {:ok, %{status: 200, body: %{"data" => []}}}
      end)

      OpenAI.all(base_url: "https://integrate.api.nvidia.com/v1", identifier: "NVIDIA")
    end

    test "returns [] on HTTP error" do
      expect(Planck.AI.MockHTTPClient, :get, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      assert OpenAI.all(base_url: "http://localhost:9999") == []
    end

    test "returns [] on non-200 status" do
      expect(Planck.AI.MockHTTPClient, :get, fn _url, _opts ->
        {:ok, %{status: 401, body: "unauthorized"}}
      end)

      assert OpenAI.all(base_url: "http://localhost:9999") == []
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

  describe "Planck.AI.list_providers/0" do
    test "returns three providers" do
      providers = AI.list_providers()
      assert providers == [:anthropic, :openai, :google]
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
