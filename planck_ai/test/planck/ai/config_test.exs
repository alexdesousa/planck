defmodule Planck.AI.ConfigTest do
  use ExUnit.Case, async: true

  alias Planck.AI.Config

  @providers %{
    "anthropic" => %{"type" => "anthropic"},
    "nvidia" => %{
      "type" => "openai",
      "base_url" => "https://integrate.api.nvidia.com/v1",
      "identifier" => "NVIDIA"
    },
    "local" => %{
      "type" => "openai",
      "base_url" => "http://localhost:11434",
      "has_api_key" => false
    }
  }

  describe "from_config/2" do
    test "builds Model structs from providers + models" do
      models = [%{"id" => "sonnet", "model" => "claude-sonnet-4-6", "provider" => "anthropic"}]
      [m] = Config.from_config(@providers, models)
      assert m.id == "sonnet"
      assert m.model == "claude-sonnet-4-6"
      assert m.provider == :anthropic
      assert m.base_url == nil
    end

    test "resolves base_url and identifier from provider entry" do
      models = [
        %{"id" => "llama70b", "model" => "meta/llama-3.3-70b-instruct", "provider" => "nvidia"}
      ]

      [m] = Config.from_config(@providers, models)
      assert m.provider == :openai
      assert m.base_url == "https://integrate.api.nvidia.com/v1"
      assert m.identifier == "NVIDIA"
    end

    test "has_api_key: false is carried into the model struct" do
      models = [%{"id" => "llama3.2", "model" => "llama3.2", "provider" => "local"}]
      [m] = Config.from_config(@providers, models)
      assert m.has_api_key == false
    end

    test "params are parsed as default_opts" do
      models = [
        %{
          "id" => "llama70b",
          "model" => "meta/llama-3.3-70b-instruct",
          "provider" => "nvidia",
          "params" => %{"temperature" => 0.6}
        }
      ]

      [m] = Config.from_config(@providers, models)
      assert m.default_opts == [temperature: 0.6]
    end

    test "applies defaults for optional model fields" do
      models = [%{"id" => "llama3.2", "model" => "llama3.2", "provider" => "local"}]
      [m] = Config.from_config(@providers, models)
      assert m.name == "llama3.2"
      assert m.context_window == 4_096
      assert m.max_tokens == 2_048
      assert m.supports_thinking == false
      assert m.input_types == [:text]
      assert m.default_opts == []
    end

    test "accepts all valid input_types" do
      models = [
        %{
          "id" => "sonnet",
          "model" => "claude-sonnet-4-6",
          "provider" => "anthropic",
          "input_types" => ["text", "image", "image_url", "file", "video_url"]
        }
      ]

      [m] = Config.from_config(@providers, models)
      assert m.input_types == [:text, :image, :image_url, :file, :video_url]
    end

    test "falls back to [:text] when input_types is empty" do
      models = [
        %{
          "id" => "sonnet",
          "model" => "claude-sonnet-4-6",
          "provider" => "anthropic",
          "input_types" => []
        }
      ]

      [m] = Config.from_config(@providers, models)
      assert m.input_types == [:text]
    end

    test "ignores unknown input_types" do
      models = [
        %{
          "id" => "sonnet",
          "model" => "claude-sonnet-4-6",
          "provider" => "anthropic",
          "input_types" => ["text", "hologram"]
        }
      ]

      [m] = Config.from_config(@providers, models)
      assert m.input_types == [:text]
    end

    test "drops unknown default_opt keys" do
      models = [
        %{
          "id" => "sonnet",
          "model" => "claude-sonnet-4-6",
          "provider" => "anthropic",
          "params" => %{"temperature" => 1.0, "not_a_real_param_xyz123" => 99}
        }
      ]

      [m] = Config.from_config(@providers, models)
      assert m.default_opts == [temperature: 1.0]
    end

    test "accepts all three provider types" do
      providers = %{
        "a" => %{"type" => "anthropic"},
        "o" => %{"type" => "openai"},
        "g" => %{"type" => "google"}
      }

      models = [
        %{"id" => "m1", "model" => "m", "provider" => "a"},
        %{"id" => "m2", "model" => "m", "provider" => "o"},
        %{"id" => "m3", "model" => "m", "provider" => "g"}
      ]

      result = Config.from_config(providers, models)
      assert Enum.map(result, & &1.provider) == [:anthropic, :openai, :google]
    end

    test "identifier is upcased from provider entry" do
      providers = %{
        "nvidia" => %{
          "type" => "openai",
          "base_url" => "https://api.nvidia.com/v1",
          "identifier" => "nvidia"
        }
      }

      models = [%{"id" => "m", "model" => "m", "provider" => "nvidia"}]
      [m] = Config.from_config(providers, models)
      assert m.identifier == "NVIDIA"
    end

    test "skips entries with unknown provider key" do
      models = [%{"id" => "x", "model" => "x", "provider" => "no-such-provider"}]

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Config.from_config(@providers, models) == []
        end)

      assert log =~ "unknown provider key"
    end

    test "skips entries with unknown provider type" do
      providers = %{"bad" => %{"type" => "fakeprovider"}}
      models = [%{"id" => "x", "model" => "x", "provider" => "bad"}]

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Config.from_config(providers, models) == []
        end)

      assert log =~ "unknown provider"
    end

    test "skips entry when id is empty" do
      models = [%{"id" => "", "model" => "m", "provider" => "anthropic"}]

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Config.from_config(@providers, models) == []
        end)

      assert log =~ "id"
    end

    test "skips entry when model field is missing" do
      models = [%{"id" => "m", "provider" => "anthropic"}]

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Config.from_config(@providers, models) == []
        end)

      assert log =~ "missing"
    end

    test "valid entries are kept when mixed with invalid ones" do
      models = [
        %{"id" => "good", "model" => "claude-sonnet-4-6", "provider" => "anthropic"},
        %{"id" => "bad", "model" => "x", "provider" => "no-such-key"}
      ]

      result = Config.from_config(@providers, models)
      assert length(result) == 1
      assert hd(result).id == "good"
    end

    test "returns [] for empty models list" do
      assert Config.from_config(@providers, []) == []
    end
  end
end
