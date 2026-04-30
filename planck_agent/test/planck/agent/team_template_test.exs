defmodule Planck.Agent.TeamTemplateTest do
  use ExUnit.Case, async: true

  alias Planck.Agent.{AgentSpec, TeamTemplate}

  defp valid_entry(overrides \\ %{}) do
    Map.merge(
      %{
        "type" => "builder",
        "provider" => "ollama",
        "model_id" => "llama3.2",
        "system_prompt" => "You are a builder."
      },
      overrides
    )
  end

  # --- from_map/1 ---

  describe "from_map/1" do
    test "returns {:ok, spec} with required fields" do
      assert {:ok, %AgentSpec{} = spec} = TeamTemplate.from_map(valid_entry())
      assert spec.type == "builder"
      assert spec.provider == :ollama
      assert spec.model_id == "llama3.2"
      assert spec.system_prompt == "You are a builder."
    end

    test "sets optional name when present" do
      assert {:ok, spec} = TeamTemplate.from_map(valid_entry(%{"name" => "Builder Joe"}))
      assert spec.name == "Builder Joe"
    end

    test "name defaults to nil when absent" do
      assert {:ok, spec} = TeamTemplate.from_map(valid_entry())
      assert spec.name == nil
    end

    test "parses opts map into keyword list" do
      entry = valid_entry(%{"opts" => %{"temperature" => 0.7, "top_p" => 0.95}})
      assert {:ok, spec} = TeamTemplate.from_map(entry)
      assert spec.opts[:temperature] == 0.7
      assert spec.opts[:top_p] == 0.95
    end

    test "accepts all five providers" do
      for provider <- ~w(anthropic openai google ollama llama_cpp) do
        assert {:ok, spec} = TeamTemplate.from_map(valid_entry(%{"provider" => provider}))
        assert spec.provider == String.to_existing_atom(provider)
      end
    end

    test "returns {:error, _} for unknown provider" do
      assert {:error, reason} = TeamTemplate.from_map(valid_entry(%{"provider" => "fake"}))
      assert reason =~ "unknown provider"
    end

    test "returns {:error, _} when type is missing" do
      entry = Map.delete(valid_entry(), "type")
      assert {:error, reason} = TeamTemplate.from_map(entry)
      assert reason =~ "type"
    end

    test "returns {:error, _} when type is empty string" do
      assert {:error, reason} = TeamTemplate.from_map(valid_entry(%{"type" => ""}))
      assert reason =~ "type"
    end

    test "returns {:error, _} when model_id is missing" do
      entry = Map.delete(valid_entry(), "model_id")
      assert {:error, reason} = TeamTemplate.from_map(entry)
      assert reason =~ "provider or model_id"
    end

    test "returns {:error, _} when provider is missing" do
      entry = Map.delete(valid_entry(), "provider")
      assert {:error, reason} = TeamTemplate.from_map(entry)
      assert reason =~ "provider or model_id"
    end

    test "inline system_prompt is kept as-is" do
      assert {:ok, spec} = TeamTemplate.from_map(valid_entry())
      assert spec.system_prompt == "You are a builder."
    end

    test "nil system_prompt defaults to empty string" do
      entry = Map.put(valid_entry(), "system_prompt", nil)
      assert {:ok, spec} = TeamTemplate.from_map(entry)
      assert spec.system_prompt == ""
    end
  end

  # --- file path resolution ---

  describe "from_map/2 with file path system_prompt" do
    test "reads .md file relative to base_dir" do
      dir = System.tmp_dir!()
      path = Path.join(dir, "builder.md")
      File.write!(path, "  You are a builder.  ")

      entry = valid_entry(%{"system_prompt" => "builder.md"})
      assert {:ok, spec} = TeamTemplate.from_map(entry, dir)
      assert spec.system_prompt == "You are a builder."

      File.rm!(path)
    end

    test "returns {:error, _} when file does not exist" do
      entry = valid_entry(%{"system_prompt" => "missing.md"})
      assert {:error, reason} = TeamTemplate.from_map(entry, "/nonexistent")
      assert reason =~ "could not read"
    end
  end

  # --- from_list/1 ---

  describe "from_list/1" do
    test "converts a list of valid entries" do
      entries = [valid_entry(), valid_entry(%{"type" => "tester"})]
      result = TeamTemplate.from_list(entries)
      assert length(result) == 2
    end

    test "skips invalid entries with a warning" do
      entries = [valid_entry(), %{"bad" => "entry"}]
      result = TeamTemplate.from_list(entries)
      assert length(result) == 1
      assert hd(result).type == "builder"
    end

    test "returns empty list for all-invalid entries" do
      assert [] = TeamTemplate.from_list([%{}, %{"x" => 1}])
    end
  end

  # --- load/1 ---

  describe "load/1" do
    test "loads and parses a valid JSON file" do
      dir = System.tmp_dir!()
      path = Path.join(dir, "team.json")

      entries = [
        %{
          "type" => "builder",
          "provider" => "ollama",
          "model_id" => "llama3.2",
          "system_prompt" => "Build things."
        }
      ]

      File.write!(path, Jason.encode!(entries))
      assert {:ok, [spec]} = TeamTemplate.load(path)
      assert spec.type == "builder"

      File.rm!(path)
    end

    test "returns {:error, _} for missing file" do
      assert {:error, _} = TeamTemplate.load("/nonexistent/team.json")
    end

    test "returns {:error, _} for invalid JSON" do
      path = Path.join(System.tmp_dir!(), "bad.json")
      File.write!(path, "not json {{{")
      assert {:error, _} = TeamTemplate.load(path)
      File.rm!(path)
    end

    test "resolves system_prompt file paths relative to template dir" do
      dir = System.tmp_dir!()
      prompt_path = Path.join(dir, "builder.md")
      template_path = Path.join(dir, "team.json")

      File.write!(prompt_path, "You are a builder.")

      entries = [valid_entry(%{"system_prompt" => "builder.md"})]
      File.write!(template_path, Jason.encode!(entries))

      assert {:ok, [spec]} = TeamTemplate.load(template_path)
      assert spec.system_prompt == "You are a builder."

      File.rm!(prompt_path)
      File.rm!(template_path)
    end
  end
end
