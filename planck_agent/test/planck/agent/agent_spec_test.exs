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
    provider: :ollama,
    model_id: "llama3.2",
    system_prompt: "You are a builder.",
    opts: []
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

    test "name is nil when absent" do
      expect(MockAI, :get_model, fn :ollama, "llama3.2" -> {:ok, @model} end)
      opts = AgentSpec.to_start_opts(@base_spec)
      assert opts[:name] == nil
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
  end
end
