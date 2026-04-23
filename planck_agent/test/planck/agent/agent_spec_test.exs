defmodule Planck.Agent.AgentSpecTest do
  use ExUnit.Case, async: true

  import Mox

  alias Planck.Agent.{AgentSpec, MockAI}
  alias Planck.AI.Model

  setup :verify_on_exit!

  @model %Model{
    id: "llama3.2",
    name: "Llama 3.2",
    provider: :ollama,
    context_window: 4_096,
    max_tokens: 2_048
  }

  @base_spec %AgentSpec{
    type: "builder",
    name: "builder",
    provider: :ollama,
    model_id: "llama3.2",
    system_prompt: "You are a builder.",
    opts: [],
    skills: []
  }

  # --- to_start_opts/2 ---

  describe "to_start_opts/2" do
    test "returns keyword list with required fields" do
      expect(MockAI, :get_model, fn :ollama, "llama3.2" -> {:ok, @model} end)

      opts = AgentSpec.to_start_opts(@base_spec)

      assert is_binary(opts[:id])
      assert opts[:type] == "builder"
      assert opts[:system_prompt] == "You are a builder."
      assert opts[:model] == @model
      assert opts[:opts] == []
    end

    test "generates a unique id each call" do
      expect(MockAI, :get_model, 2, fn :ollama, "llama3.2" -> {:ok, @model} end)

      id1 = AgentSpec.to_start_opts(@base_spec)[:id]
      id2 = AgentSpec.to_start_opts(@base_spec)[:id]
      refute id1 == id2
    end

    test "includes name when set" do
      expect(MockAI, :get_model, fn :ollama, "llama3.2" -> {:ok, @model} end)
      spec = %{@base_spec | name: "Builder Joe"}
      opts = AgentSpec.to_start_opts(spec)
      assert opts[:name] == "Builder Joe"
    end

    test "passes spec name through" do
      expect(MockAI, :get_model, fn :ollama, "llama3.2" -> {:ok, @model} end)
      opts = AgentSpec.to_start_opts(@base_spec)
      assert opts[:name] == "builder"
    end

    test "applies tools override" do
      expect(MockAI, :get_model, fn :ollama, "llama3.2" -> {:ok, @model} end)

      fake_tool = %Planck.Agent.Tool{
        name: "t",
        description: "d",
        parameters: %{},
        execute_fn: fn _, _ -> :ok end
      }

      opts = AgentSpec.to_start_opts(@base_spec, tools: [fake_tool])
      assert opts[:tools] == [fake_tool]
    end

    test "defaults tools to empty list" do
      expect(MockAI, :get_model, fn :ollama, "llama3.2" -> {:ok, @model} end)
      opts = AgentSpec.to_start_opts(@base_spec)
      assert opts[:tools] == []
    end

    test "applies team_id override" do
      expect(MockAI, :get_model, fn :ollama, "llama3.2" -> {:ok, @model} end)
      opts = AgentSpec.to_start_opts(@base_spec, team_id: "team-abc")
      assert opts[:team_id] == "team-abc"
    end

    test "team_id defaults to nil" do
      expect(MockAI, :get_model, fn :ollama, "llama3.2" -> {:ok, @model} end)
      opts = AgentSpec.to_start_opts(@base_spec)
      assert opts[:team_id] == nil
    end

    test "applies available_models override" do
      expect(MockAI, :get_model, fn :ollama, "llama3.2" -> {:ok, @model} end)
      opts = AgentSpec.to_start_opts(@base_spec, available_models: [@model])
      assert opts[:available_models] == [@model]
    end

    test "applies on_compact override" do
      expect(MockAI, :get_model, fn :ollama, "llama3.2" -> {:ok, @model} end)
      fun = fn msgs -> msgs end
      opts = AgentSpec.to_start_opts(@base_spec, on_compact: fun)
      assert opts[:on_compact] == fun
    end

    test "resolves tools by name from tool_pool when spec.tools is set" do
      expect(MockAI, :get_model, fn :ollama, "llama3.2" -> {:ok, @model} end)

      read = %Planck.Agent.Tool{
        name: "read",
        description: "r",
        parameters: %{},
        execute_fn: fn _, _ -> :ok end
      }

      bash = %Planck.Agent.Tool{
        name: "bash",
        description: "b",
        parameters: %{},
        execute_fn: fn _, _ -> :ok end
      }

      spec = %{@base_spec | tools: ["read"]}
      opts = AgentSpec.to_start_opts(spec, tool_pool: [read, bash])
      assert opts[:tools] == [read]
    end

    test "ignores unknown tool names in spec.tools" do
      expect(MockAI, :get_model, fn :ollama, "llama3.2" -> {:ok, @model} end)
      spec = %{@base_spec | tools: ["unknown"]}
      opts = AgentSpec.to_start_opts(spec, tool_pool: [])
      assert opts[:tools] == []
    end

    test "appends explicit tools: after resolved ones when spec.tools is set" do
      expect(MockAI, :get_model, fn :ollama, "llama3.2" -> {:ok, @model} end)

      read = %Planck.Agent.Tool{
        name: "read",
        description: "r",
        parameters: %{},
        execute_fn: fn _, _ -> :ok end
      }

      extra = %Planck.Agent.Tool{
        name: "extra",
        description: "e",
        parameters: %{},
        execute_fn: fn _, _ -> :ok end
      }

      spec = %{@base_spec | tools: ["read"]}
      opts = AgentSpec.to_start_opts(spec, tool_pool: [read], tools: [extra])
      assert opts[:tools] == [read, extra]
    end

    test "falls back to tools: override when spec.tools is empty" do
      expect(MockAI, :get_model, fn :ollama, "llama3.2" -> {:ok, @model} end)

      read = %Planck.Agent.Tool{
        name: "read",
        description: "r",
        parameters: %{},
        execute_fn: fn _, _ -> :ok end
      }

      opts = AgentSpec.to_start_opts(@base_spec, tools: [read])
      assert opts[:tools] == [read]
    end

    test "raises when model not found" do
      expect(MockAI, :get_model, fn :ollama, "llama3.2" -> {:error, :not_found} end)

      assert_raise ArgumentError, ~r/model not found/, fn ->
        AgentSpec.to_start_opts(@base_spec)
      end
    end

    test "passes spec opts through" do
      expect(MockAI, :get_model, fn :ollama, "llama3.2" -> {:ok, @model} end)
      spec = %{@base_spec | opts: [temperature: 0.5]}
      opts = AgentSpec.to_start_opts(spec)
      assert opts[:opts] == [temperature: 0.5]
    end

    test "system_prompt passes through unchanged when skills is empty" do
      expect(MockAI, :get_model, fn :ollama, "llama3.2" -> {:ok, @model} end)
      opts = AgentSpec.to_start_opts(@base_spec)
      assert opts[:system_prompt] == "You are a builder."
    end

    test "appends resolved skill section to system_prompt when skills is non-empty" do
      expect(MockAI, :get_model, fn :ollama, "llama3.2" -> {:ok, @model} end)

      skill = %Planck.Agent.Skill{
        name: "code_review",
        description: "Reviews code for correctness.",
        path: "/tmp/skills/code_review",
        skill_file: "/tmp/skills/code_review/SKILL.md"
      }

      spec = %{@base_spec | skills: ["code_review"]}
      opts = AgentSpec.to_start_opts(spec, skill_pool: [skill])

      assert opts[:system_prompt] =~ "You are a builder."
      assert opts[:system_prompt] =~ "code_review"
      assert opts[:system_prompt] =~ "Reviews code for correctness."
    end

    test "ignores unknown skill names" do
      expect(MockAI, :get_model, fn :ollama, "llama3.2" -> {:ok, @model} end)

      spec = %{@base_spec | skills: ["unknown"]}
      opts = AgentSpec.to_start_opts(spec, skill_pool: [])

      assert opts[:system_prompt] == "You are a builder."
    end
  end

  # --- from_map/1, from_map/2 ---

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

  describe "from_map/1" do
    test "returns {:ok, spec} with required fields" do
      assert {:ok, %AgentSpec{} = spec} = AgentSpec.from_map(valid_entry())
      assert spec.type == "builder"
      assert spec.provider == :ollama
      assert spec.model_id == "llama3.2"
      assert spec.system_prompt == "You are a builder."
    end

    test "sets optional name when present" do
      assert {:ok, spec} = AgentSpec.from_map(valid_entry(%{"name" => "Builder Joe"}))
      assert spec.name == "Builder Joe"
    end

    test "name defaults to type when absent" do
      assert {:ok, spec} = AgentSpec.from_map(valid_entry())
      assert spec.name == "builder"
    end

    test "name defaults to type when empty string" do
      assert {:ok, spec} = AgentSpec.from_map(valid_entry(%{"name" => ""}))
      assert spec.name == "builder"
    end

    test "parses opts map into keyword list" do
      entry = valid_entry(%{"opts" => %{"temperature" => 0.7, "top_p" => 0.95}})
      assert {:ok, spec} = AgentSpec.from_map(entry)
      assert spec.opts[:temperature] == 0.7
      assert spec.opts[:top_p] == 0.95
    end

    test "accepts all five providers" do
      for provider <- ~w(anthropic openai google ollama llama_cpp) do
        assert {:ok, spec} = AgentSpec.from_map(valid_entry(%{"provider" => provider}))
        assert spec.provider == String.to_existing_atom(provider)
      end
    end

    test "returns {:error, _} for unknown provider" do
      assert {:error, reason} = AgentSpec.from_map(valid_entry(%{"provider" => "fake"}))
      assert reason =~ "unknown provider"
    end

    test "returns {:error, _} when type is missing" do
      entry = Map.delete(valid_entry(), "type")
      assert {:error, reason} = AgentSpec.from_map(entry)
      assert reason =~ "type"
    end

    test "returns {:error, _} when type is empty string" do
      assert {:error, reason} = AgentSpec.from_map(valid_entry(%{"type" => ""}))
      assert reason =~ "type"
    end

    test "returns {:error, _} when model_id is missing" do
      entry = Map.delete(valid_entry(), "model_id")
      assert {:error, reason} = AgentSpec.from_map(entry)
      assert reason =~ "provider or model_id"
    end

    test "returns {:error, _} when provider is missing" do
      entry = Map.delete(valid_entry(), "provider")
      assert {:error, reason} = AgentSpec.from_map(entry)
      assert reason =~ "provider or model_id"
    end

    test "inline system_prompt is kept as-is" do
      assert {:ok, spec} = AgentSpec.from_map(valid_entry())
      assert spec.system_prompt == "You are a builder."
    end

    test "nil system_prompt defaults to empty string" do
      entry = Map.put(valid_entry(), "system_prompt", nil)
      assert {:ok, spec} = AgentSpec.from_map(entry)
      assert spec.system_prompt == ""
    end

    test "parses tools array into spec.tools" do
      entry = valid_entry(%{"tools" => ["read", "bash"]})
      assert {:ok, spec} = AgentSpec.from_map(entry)
      assert spec.tools == ["read", "bash"]
    end

    test "tools defaults to empty list when absent" do
      assert {:ok, spec} = AgentSpec.from_map(valid_entry())
      assert spec.tools == []
    end

    test "tools filters out non-string entries" do
      entry = valid_entry(%{"tools" => ["read", 42, nil, "bash"]})
      assert {:ok, spec} = AgentSpec.from_map(entry)
      assert spec.tools == ["read", "bash"]
    end

    test "parses skills array into spec.skills" do
      entry = valid_entry(%{"skills" => ["code_review", "refactor"]})
      assert {:ok, spec} = AgentSpec.from_map(entry)
      assert spec.skills == ["code_review", "refactor"]
    end

    test "skills defaults to empty list when absent" do
      assert {:ok, spec} = AgentSpec.from_map(valid_entry())
      assert spec.skills == []
    end

    test "skills filters out non-string entries" do
      entry = valid_entry(%{"skills" => ["ok", 42, nil, "good"]})
      assert {:ok, spec} = AgentSpec.from_map(entry)
      assert spec.skills == ["ok", "good"]
    end
  end

  describe "from_map/2 with file path system_prompt" do
    test "reads .md file relative to base_dir" do
      dir = System.tmp_dir!()
      path = Path.join(dir, "builder.md")
      File.write!(path, "  You are a builder.  ")

      entry = valid_entry(%{"system_prompt" => "builder.md"})
      assert {:ok, spec} = AgentSpec.from_map(entry, dir)
      assert spec.system_prompt == "You are a builder."

      File.rm!(path)
    end

    test "returns {:error, _} when file does not exist" do
      entry = valid_entry(%{"system_prompt" => "missing.md"})
      assert {:error, reason} = AgentSpec.from_map(entry, "/nonexistent")
      assert reason =~ "could not read"
    end
  end

  # --- from_list/1, from_list/2 ---

  describe "from_list/1" do
    test "converts a list of valid entries" do
      entries = [valid_entry(), valid_entry(%{"type" => "tester"})]
      result = AgentSpec.from_list(entries)
      assert length(result) == 2
    end

    test "skips invalid entries with a warning" do
      entries = [valid_entry(), %{"bad" => "entry"}]
      result = AgentSpec.from_list(entries)
      assert length(result) == 1
      assert hd(result).type == "builder"
    end

    test "returns empty list for all-invalid entries" do
      assert [] = AgentSpec.from_list([%{}, %{"x" => 1}])
    end
  end
end
