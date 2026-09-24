defmodule Planck.Agent.ToolTest do
  use ExUnit.Case, async: true

  import Mox

  alias Planck.Agent.{MockAI, Tool, Tools}
  alias Planck.AI.Model

  setup :verify_on_exit!

  defp params,
    do: %{
      "type" => "object",
      "properties" => %{"path" => %{"type" => "string"}},
      "required" => ["path"]
    }

  defp execute_fn, do: fn _id, _args -> {:ok, :done} end

  @rlcd_model %Model{
    id: "jev-latest",
    name: "Jev",
    provider: :typesafe,
    type: :rlcd,
    context_window: 32_768,
    max_tokens: 2_048
  }

  @llm_model %Model{
    id: "qwen",
    name: "Qwen",
    provider: :openai,
    context_window: 200_000,
    max_tokens: 8_096
  }

  describe "new/1" do
    test "builds a %Tool{} struct" do
      assert %Tool{} =
               Tool.new(
                 name: "read",
                 description: "Read a file",
                 parameters: params(),
                 execute_fn: execute_fn()
               )
    end

    test "sets all fields" do
      fun = execute_fn()

      tool =
        Tool.new(
          name: "read",
          description: "Read a file",
          parameters: params(),
          execute_fn: fun
        )

      assert tool.name == "read"
      assert tool.description == "Read a file"
      assert tool.parameters == params()
      assert tool.execute_fn == fun
    end

    test "defaults :widget to nil when not given" do
      tool =
        Tool.new(
          name: "read",
          description: "Read a file",
          parameters: params(),
          execute_fn: execute_fn()
        )

      assert tool.widget == nil
    end

    test "sets :widget when given" do
      tool =
        Tool.new(
          name: "tool_with_widget",
          description: "A tool with a widget",
          parameters: params(),
          execute_fn: execute_fn(),
          widget: MyWidgetModule
        )

      assert tool.widget == MyWidgetModule
    end
  end

  describe "to_ai_tool/1" do
    test "returns a Planck.AI.Tool with matching name, description, parameters" do
      tool =
        Tool.new(
          name: "read",
          description: "Read a file",
          parameters: params(),
          execute_fn: execute_fn()
        )

      ai_tool = Tool.to_ai_tool(tool)

      assert %Planck.AI.Tool{} = ai_tool
      assert ai_tool.name == tool.name
      assert ai_tool.description == tool.description
      assert ai_tool.parameters == tool.parameters
    end

    test "drops execute_fn" do
      tool =
        Tool.new(
          name: "read",
          description: "Read a file",
          parameters: params(),
          execute_fn: execute_fn()
        )

      ai_tool = Tool.to_ai_tool(tool)
      refute Map.has_key?(ai_tool, :execute_fn)
    end
  end

  describe "Tools.prepend_agents_md/2" do
    @tag :tmp_dir
    test "prepends AGENTS.md content to system prompt", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "AGENTS.md"), "Project rules.")
      result = Tools.prepend_agents_md("You implement.", dir)
      assert result == "Project rules.\n\nYou implement."
    end

    @tag :tmp_dir
    test "returns AGENTS.md content when system prompt is empty", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "AGENTS.md"), "Project rules.")
      assert Tools.prepend_agents_md("", dir) == "Project rules."
      assert Tools.prepend_agents_md(nil, dir) == "Project rules."
    end

    @tag :tmp_dir
    test "returns system prompt unchanged when no AGENTS.md found", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, ".git"))
      assert Tools.prepend_agents_md("You implement.", dir) == "You implement."
    end

    @tag :tmp_dir
    test "walks up to find AGENTS.md", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, ".git"))
      subdir = Path.join(dir, "src/lib")
      File.mkdir_p!(subdir)
      File.write!(Path.join(dir, "AGENTS.md"), "Root rules.")
      assert Tools.prepend_agents_md("prompt", subdir) == "Root rules.\n\nprompt"
    end

    @tag :tmp_dir
    test "stops at .git boundary and does not load AGENTS.md above it", %{tmp_dir: dir} do
      project = Path.join(dir, "project")
      File.mkdir_p!(Path.join(project, ".git"))
      File.write!(Path.join(dir, "AGENTS.md"), "Should not be loaded.")
      assert Tools.prepend_agents_md("prompt", project) == "prompt"
    end

    test "returns empty string when both cwd is empty and system prompt is nil" do
      assert Tools.prepend_agents_md(nil, "") == ""
    end
  end

  describe "validate_args/2 with oneOf schemas (classify's questions)" do
    setup do
      %{tool: Tools.classify([])}
    end

    test "valid choice question passes", %{tool: tool} do
      args = %{
        "provider" => "typesafe",
        "model_id" => "jev-latest",
        "base_url" => "",
        "state" => "Please refund me",
        "questions" => %{
          "department" => %{
            "type" => "choice",
            "instructions" => "Which team should handle this?",
            "criteria" => %{"billing" => "Payments and refunds", "technical" => "Bugs"}
          }
        }
      }

      assert :ok = Tool.validate_args(tool, args)
    end

    test "valid score question passes", %{tool: tool} do
      args = %{
        "provider" => "typesafe",
        "model_id" => "jev-latest",
        "base_url" => "",
        "state" => "Please refund me",
        "questions" => %{
          "frustration" => %{
            "type" => "score",
            "instructions" => "How frustrated is the customer?",
            "criteria" => ["calm", "frustrated", "very angry"]
          }
        }
      }

      assert :ok = Tool.validate_args(tool, args)
    end

    test "valid boolean question passes without criteria (optional)", %{tool: tool} do
      args = %{
        "provider" => "typesafe",
        "model_id" => "jev-latest",
        "base_url" => "",
        "state" => "Please refund me",
        "questions" => %{
          "urgent" => %{"type" => "boolean", "instructions" => "Is this urgent?"}
        }
      }

      assert :ok = Tool.validate_args(tool, args)
    end

    test "valid boolean question passes with optional criteria", %{tool: tool} do
      args = %{
        "provider" => "typesafe",
        "model_id" => "jev-latest",
        "base_url" => "",
        "state" => "Please refund me",
        "questions" => %{
          "urgent" => %{
            "type" => "boolean",
            "instructions" => "Is this urgent?",
            "criteria" => %{"true" => "time-sensitive", "false" => "no urgency"}
          }
        }
      }

      assert :ok = Tool.validate_args(tool, args)
    end

    test "a choice question missing criteria is rejected with an actionable message", %{
      tool: tool
    } do
      args = %{
        "provider" => "typesafe",
        "model_id" => "jev-latest",
        "base_url" => "",
        "state" => "Please refund me",
        "questions" => %{
          "department" => %{"type" => "choice", "instructions" => "Which team?"}
        }
      }

      assert {:error, message} = Tool.validate_args(tool, args)
      assert message =~ "does not match any of the allowed shapes"
      refute message =~ "oneOf schemas"
    end

    test "an unrecognized question type is rejected", %{tool: tool} do
      args = %{
        "provider" => "typesafe",
        "model_id" => "jev-latest",
        "base_url" => "",
        "state" => "Please refund me",
        "questions" => %{
          "x" => %{"type" => "essay", "instructions" => "Write one"}
        }
      }

      assert {:error, _message} = Tool.validate_args(tool, args)
    end

    test "rejects when a required top-level field is missing", %{tool: tool} do
      args = %{
        # no "provider"
        "model_id" => "jev-latest",
        "base_url" => "",
        "state" => "Please refund me",
        "questions" => %{}
      }

      assert {:error, message} = Tool.validate_args(tool, args)
      assert message =~ "provider"
    end

    test "rejects a provider value outside the enum", %{tool: tool} do
      args = %{
        "provider" => "openai",
        "model_id" => "jev-latest",
        "base_url" => "",
        "state" => "Please refund me",
        "questions" => %{}
      }

      assert {:error, message} = Tool.validate_args(tool, args)
      assert message =~ "Must be one of"
    end
  end

  describe "Tools.classify/1" do
    test "resolves model_id against available_models and forwards state/questions unchanged" do
      questions = %{urgent: %{type: :boolean, instructions: "Is this urgent?"}}

      expect(MockAI, :evaluate, fn model, state, qs, _opts ->
        assert model.id == "jev-latest"
        assert state == "Please help ASAP"
        assert qs == questions
        {:ok, %{object: %{"urgent" => %{"type" => "boolean", "probability" => 0.9}}}}
      end)

      tool = Tools.classify([@rlcd_model])

      assert {:ok, json} =
               tool.execute_fn.("agent-1", "tc-1", %{
                 "provider" => "typesafe",
                 "model_id" => "jev-latest",
                 "base_url" => "",
                 "state" => "Please help ASAP",
                 "questions" => questions
               })

      assert Jason.decode!(json) == %{
               "urgent" => %{"type" => "boolean", "probability" => 0.9}
             }
    end

    test "returns an error when model_id doesn't match any available model" do
      # Not found in available_models -> falls to the live lookup, which
      # also doesn't find it.
      stub(MockAI, :get_model, fn _provider, _model_id -> {:error, :not_found} end)

      tool = Tools.classify([@rlcd_model])

      assert {:error, message} =
               tool.execute_fn.("agent-1", "tc-1", %{
                 "provider" => "typesafe",
                 "model_id" => "does-not-exist",
                 "base_url" => "",
                 "state" => "x",
                 "questions" => %{}
               })

      assert message =~ "not found"
    end

    test "returns an error when model_id matches an :llm-type model by id" do
      # Found in available_models by id and provider, but excluded by the
      # :rlcd filter -> falls to the live lookup, which (realistically)
      # finds the same :llm-typed model again, still not :rlcd. Provider
      # must match @llm_model's own (:openai) — otherwise a provider
      # mismatch alone would explain the rejection, and the test wouldn't
      # actually prove the :rlcd filter is what's doing the work.
      stub(MockAI, :get_model, fn _provider, _model_id -> {:ok, @llm_model} end)

      tool = Tools.classify([@llm_model])

      assert {:error, _message} =
               tool.execute_fn.("agent-1", "tc-1", %{
                 "provider" => "openai",
                 "model_id" => @llm_model.id,
                 "base_url" => "",
                 "state" => "x",
                 "questions" => %{}
               })
    end

    test "resolves via a live lookup with no base_url and proceeds to evaluate" do
      stub(MockAI, :get_model, fn _provider, _model_id -> {:ok, @rlcd_model} end)

      expect(MockAI, :evaluate, fn model, _state, _qs, _opts ->
        assert model.id == @rlcd_model.id
        {:ok, %{object: %{}}}
      end)

      tool = Tools.classify([])

      assert {:ok, _json} =
               tool.execute_fn.("agent-1", "tc-1", %{
                 "provider" => "typesafe",
                 "model_id" => @rlcd_model.id,
                 "base_url" => "",
                 "state" => "x",
                 "questions" => %{}
               })
    end

    test "resolves via a live lookup with a real base_url and proceeds to evaluate" do
      live_model = %{@rlcd_model | id: "decider-1", base_url: "http://localhost:8377"}
      stub(MockAI, :get_model, fn _provider, _model_id, _opts -> {:ok, live_model} end)

      expect(MockAI, :evaluate, fn model, _state, _qs, _opts ->
        assert model.id == "decider-1"
        {:ok, %{object: %{}}}
      end)

      tool = Tools.classify([])

      assert {:ok, _json} =
               tool.execute_fn.("agent-1", "tc-1", %{
                 "provider" => "typesafe",
                 "model_id" => "decider-1",
                 "base_url" => "http://localhost:8377",
                 "state" => "x",
                 "questions" => %{}
               })
    end

    test "propagates an error from evaluate/4" do
      expect(MockAI, :evaluate, fn _model, _state, _qs, _opts -> {:error, :unauthorized} end)

      tool = Tools.classify([@rlcd_model])

      assert {:error, :unauthorized} =
               tool.execute_fn.("agent-1", "tc-1", %{
                 "provider" => "typesafe",
                 "model_id" => "jev-latest",
                 "base_url" => "",
                 "state" => "x",
                 "questions" => %{}
               })
    end
  end

  describe "validate_args/2 rejects a spawn_agent provider outside its enum" do
    test "rejects a provider value not in the enum" do
      tool = Tools.spawn_agent("session-1", "team-1", [])

      args = %{
        "type" => "reviewer",
        "name" => "Reviewer",
        "description" => "Reviews code",
        "system_prompt" => "You are a reviewer.",
        "provider" => "typesafe",
        "model_id" => "jev-latest",
        "base_url" => ""
      }

      assert {:error, message} = Tool.validate_args(tool, args)
      assert message =~ "Must be one of"
    end
  end

  describe "Tools.list_models/1" do
    test "includes each model's type" do
      tool = Tools.list_models([@llm_model, @rlcd_model])
      {:ok, json} = tool.execute_fn.("agent-1", "tc-1", %{})
      models = Jason.decode!(json)

      assert Enum.find(models, &(&1["id"] == @llm_model.id))["type"] == "llm"
      assert Enum.find(models, &(&1["id"] == @rlcd_model.id))["type"] == "rlcd"
    end
  end
end
