defmodule Planck.AI.ConfigTest do
  use ExUnit.Case, async: true

  alias Planck.AI.Config
  alias Planck.AI.Model

  describe "from_map/1" do
    test "returns {:ok, model} with all fields" do
      entry = %{
        "id" => "my-llama",
        "provider" => "llama_cpp",
        "name" => "My Llama",
        "base_url" => "http://localhost:8080",
        "context_window" => 32_768,
        "max_tokens" => 4_096,
        "supports_thinking" => true,
        "input_types" => ["text", "image", "image_url", "file", "video_url"],
        "default_opts" => %{"temperature" => 0.8, "top_p" => 0.95}
      }

      assert {:ok, %Model{} = model} = Config.from_map(entry)
      assert model.id == "my-llama"
      assert model.name == "My Llama"
      assert model.provider == :llama_cpp
      assert model.base_url == "http://localhost:8080"
      assert model.context_window == 32_768
      assert model.max_tokens == 4_096
      assert model.supports_thinking == true
      assert model.input_types == [:text, :image, :image_url, :file, :video_url]
      assert model.default_opts == [temperature: 0.8, top_p: 0.95]
    end

    test "applies defaults for optional fields" do
      entry = %{"id" => "qwen3", "provider" => "ollama"}
      assert {:ok, model} = Config.from_map(entry)
      assert model.name == "qwen3"
      assert model.base_url == nil
      assert model.context_window == 4_096
      assert model.max_tokens == 2_048
      assert model.supports_thinking == false
      assert model.input_types == [:text]
      assert model.default_opts == []
    end

    test "accepts all five providers" do
      for provider <- ~w(anthropic openai google ollama llama_cpp) do
        assert {:ok, model} = Config.from_map(%{"id" => "m", "provider" => provider})
        assert model.provider == String.to_existing_atom(provider)
      end
    end

    test "returns {:error, _} for unknown provider" do
      assert {:error, reason} = Config.from_map(%{"id" => "m", "provider" => "fake"})
      assert reason =~ "unknown provider"
    end

    test "returns {:error, _} when id is missing" do
      assert {:error, reason} = Config.from_map(%{"provider" => "ollama"})
      assert reason =~ "id"
    end

    test "returns {:error, _} when id is empty" do
      assert {:error, reason} = Config.from_map(%{"id" => "", "provider" => "ollama"})
      assert reason =~ "id"
    end

    test "returns {:error, _} when provider is missing" do
      assert {:error, reason} = Config.from_map(%{"id" => "m"})
      assert reason =~ "provider"
    end

    test "falls back to [:text] when input_types is empty" do
      entry = %{"id" => "m", "provider" => "ollama", "input_types" => []}
      assert {:ok, model} = Config.from_map(entry)
      assert model.input_types == [:text]
    end

    test "ignores unknown input_types" do
      entry = %{"id" => "m", "provider" => "ollama", "input_types" => ["text", "hologram"]}
      assert {:ok, model} = Config.from_map(entry)
      assert model.input_types == [:text]
    end

    test "accepts all valid input_types" do
      entry = %{
        "id" => "m",
        "provider" => "google",
        "input_types" => ["text", "image", "image_url", "file", "video_url"]
      }

      assert {:ok, model} = Config.from_map(entry)
      assert model.input_types == [:text, :image, :image_url, :file, :video_url]
    end

    test "drops unknown default_opt keys" do
      entry = %{
        "id" => "m",
        "provider" => "ollama",
        "default_opts" => %{"temperature" => 1.0, "not_a_real_param_xyz123" => 99}
      }

      assert {:ok, model} = Config.from_map(entry)
      assert model.default_opts == [temperature: 1.0]
    end
  end

  describe "from_list/1" do
    test "converts valid entries and skips invalid ones" do
      entries = [
        %{"id" => "a", "provider" => "ollama"},
        %{"id" => "b", "provider" => "bad_provider"},
        %{"id" => "c", "provider" => "llama_cpp"}
      ]

      models = Config.from_list(entries)
      assert length(models) == 2
      assert Enum.map(models, & &1.id) == ["a", "c"]
    end

    test "returns [] for empty list" do
      assert Config.from_list([]) == []
    end
  end

  describe "load/1" do
    test "loads and parses a JSON file" do
      json =
        Jason.encode!([
          %{
            "id" => "my-model",
            "provider" => "llama_cpp",
            "context_window" => 16_384,
            "default_opts" => %{"temperature" => 0.7}
          }
        ])

      path =
        System.tmp_dir!() |> Path.join("planck_ai_config_test_#{System.unique_integer()}.json")

      File.write!(path, json)

      assert {:ok, [model]} = Config.load(path)
      assert model.id == "my-model"
      assert model.provider == :llama_cpp
      assert model.context_window == 16_384
      assert model.default_opts == [temperature: 0.7]

      File.rm!(path)
    end

    test "returns {:error, _} for missing file" do
      assert {:error, _} = Config.load("/does/not/exist.json")
    end

    test "returns {:error, _} for invalid JSON" do
      path = System.tmp_dir!() |> Path.join("planck_ai_bad_#{System.unique_integer()}.json")
      File.write!(path, "not json {{{")

      assert {:error, _} = Config.load(path)

      File.rm!(path)
    end
  end
end
