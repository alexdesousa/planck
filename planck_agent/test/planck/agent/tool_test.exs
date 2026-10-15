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

  describe "validate_args/2 with oneOf schemas (ask's questions)" do
    setup do
      %{tool: Tools.ask([])}
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

  describe "Tools.ask/1" do
    test "resolves model_id against available_models and forwards state/questions unchanged" do
      questions = %{urgent: %{type: :boolean, instructions: "Is this urgent?"}}

      expect(MockAI, :evaluate, fn model, state, qs, _opts ->
        assert model.id == "jev-latest"
        assert state == "Please help ASAP"
        assert qs == questions
        {:ok, %{object: %{"urgent" => %{"type" => "boolean", "probability" => 0.9}}}}
      end)

      tool = Tools.ask([@rlcd_model])

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

      tool = Tools.ask([@rlcd_model])

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

      tool = Tools.ask([@llm_model])

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

      tool = Tools.ask([])

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

      tool = Tools.ask([])

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

      tool = Tools.ask([@rlcd_model])

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

  describe "Tools.ask_files/2" do
    @tag :tmp_dir
    test "rlcd_tools/1 returns ask and ask_files together iff an :rlcd model is present" do
      assert [%{name: "ask"}, %{name: "ask_files"}] = Tools.rlcd_tools([@rlcd_model])
      assert [] = Tools.rlcd_tools([@llm_model])
      assert [] = Tools.rlcd_tools([])
    end

    test "orchestrator_tools/6 includes ask_files exactly when ask is included" do
      with_rlcd = Tools.orchestrator_tools("s", "t", [@llm_model, @rlcd_model])
      without_rlcd = Tools.orchestrator_tools("s", "t", [@llm_model])

      assert Enum.any?(with_rlcd, &(&1.name == "ask_files"))
      assert Enum.any?(with_rlcd, &(&1.name == "ask"))
      refute Enum.any?(without_rlcd, &(&1.name == "ask_files"))
    end

    test "questions schema is identical to ask's" do
      assert Tools.ask_files([@rlcd_model]).parameters["questions"] ==
               Tools.ask([@rlcd_model]).parameters["questions"]
    end

    test "ask and ask_files schemas contain no nil property values" do
      for tool <- [Tools.ask([@rlcd_model]), Tools.ask_files([@rlcd_model])] do
        props = tool.parameters["properties"]
        assert is_map(props)
        refute Enum.any?(props, fn {_k, v} -> is_nil(v) end)
        questions = props["questions"]
        assert is_map(questions)
        assert length(questions["additionalProperties"]["oneOf"]) == 3
      end
    end

    test "invalid tool schema returns error instead of raising" do
      bad =
        Tool.new(
          name: "ask",
          description: "bad",
          parameters: %{"type" => "object", "properties" => %{"questions" => nil}},
          execute_fn: fn _, _, _ -> {:ok, "x"} end
        )

      assert {:error, message} = Tool.validate_args(bad, %{"questions" => %{}})
      assert message =~ "misconfigured"
    end

    test "user repro ask/ask_files payloads validate" do
      ask_tool = Tools.ask([@rlcd_model])
      files_tool = Tools.ask_files([@rlcd_model])

      ask_args = %{
        "provider" => "typesafe",
        "model_id" => "Decider 2b",
        "base_url" => "https://decider.coroto.net",
        "state" => "NullPointerException in PaymentService.process()",
        "questions" => %{
          "is_reproducible" => %{
            "type" => "boolean",
            "instructions" => "Reproducible?",
            "criteria" => %{"true" => "yes", "false" => "no"}
          },
          "route_to" => %{
            "type" => "choice",
            "instructions" => "Who handles it?",
            "criteria" => %{"backend" => "Server-side", "frontend" => "UI"}
          },
          "severity" => %{
            "type" => "score",
            "instructions" => "Severity?",
            "criteria" => ["trivial", "minor", "blocking"]
          }
        }
      }

      assert :ok = Tool.validate_args(ask_tool, ask_args)

      assert :ok =
               Tool.validate_args(files_tool, %{
                 "provider" => "typesafe",
                 "model_id" => "Decider 2b",
                 "base_url" => "https://decider.coroto.net",
                 "paths" => ["a.txt"],
                 "questions" => %{
                   "bug_related" => %{"type" => "boolean", "instructions" => "Related?"}
                 }
               })
    end

    test "mixed ok/skipped envelope with injected reader" do
      questions = %{"related" => %{"type" => "boolean", "instructions" => "Related to the bug?"}}

      reader = fn
        "a.ex" -> {:ok, "content a"}
        "b.ex" -> {:ok, "content b"}
        _path -> {:error, "not found"}
      end

      stub(MockAI, :evaluate, fn _model, _state, qs, _opts ->
        assert qs == questions
        {:ok, %{object: %{"related" => %{"type" => "boolean", "probability" => 0.9}}}}
      end)

      tool = Tools.ask_files([@rlcd_model], reader: reader)

      assert {:ok, json} =
               tool.execute_fn.("agent-1", "tc-1", %{
                 "provider" => "typesafe",
                 "model_id" => "jev-latest",
                 "base_url" => "",
                 "paths" => ["a.ex", "b.ex", "missing.ex"],
                 "questions" => questions
               })

      assert %{
               "results" => [
                 %{"path" => "a.ex", "answers" => %{"related" => _}},
                 %{"path" => "b.ex", "answers" => %{"related" => _}}
               ],
               "skipped" => [%{"path" => "missing.ex", "reason" => "not found"}],
               "calls" => 2
             } = Jason.decode!(json)
    end

    test "per-file state carries path and content" do
      reader = fn _path -> {:ok, "hello"} end

      expect(MockAI, :evaluate, fn _model, state, _qs, _opts ->
        assert state == %{path: "a.ex", content: "hello"}
        {:ok, %{object: %{}}}
      end)

      tool = Tools.ask_files([@rlcd_model], reader: reader)

      assert {:ok, _} =
               tool.execute_fn.("agent-1", "tc-1", %{
                 "provider" => "typesafe",
                 "model_id" => "jev-latest",
                 "base_url" => "",
                 "paths" => ["a.ex"],
                 "questions" => %{}
               })
    end

    test "oversize and binary files are skipped without consuming RLCD calls" do
      reader = fn
        "big.ex" -> {:ok, String.duplicate("x", 240_001)}
        "bin.ex" -> {:ok, <<137, 80, 78, 71, 0, 1, 2, 3>>}
        "empty.ex" -> {:ok, ""}
      end

      expect(MockAI, :evaluate, 0, fn _m, _s, _q, _o -> {:ok, %{object: %{}}} end)

      tool = Tools.ask_files([@rlcd_model], reader: reader)

      assert {:ok, json} =
               tool.execute_fn.("agent-1", "tc-1", %{
                 "provider" => "typesafe",
                 "model_id" => "jev-latest",
                 "base_url" => "",
                 "paths" => ["big.ex", "bin.ex", "empty.ex"],
                 "questions" => %{}
               })

      assert %{"results" => [], "skipped" => skipped, "calls" => 0} = Jason.decode!(json)
      reasons = Map.new(skipped, &{&1["path"], &1["reason"]})
      assert reasons["big.ex"] =~ "too large"
      assert reasons["bin.ex"] == "binary"
      assert reasons["empty.ex"] == "empty"
    end

    test "over the file cap returns an error before reading any file" do
      reader = fn _path -> raise "must not read" end

      stub(MockAI, :get_model, fn _provider, _model_id -> {:ok, @rlcd_model} end)

      tool = Tools.ask_files([@rlcd_model], reader: reader)
      paths = Enum.map(1..256, &"file-#{&1}.ex")

      assert {:error, message} =
               tool.execute_fn.("agent-1", "tc-1", %{
                 "provider" => "typesafe",
                 "model_id" => "jev-latest",
                 "base_url" => "",
                 "paths" => paths,
                 "questions" => %{}
               })

      assert message =~ "255"
    end

    @tag :tmp_dir
    test "glob patterns expand to matching files", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "a.ex"), "aaa")
      File.write!(Path.join(dir, "b.ex"), "bbb")
      File.write!(Path.join(dir, "c.txt"), "ccc")

      reader = fn path -> {:ok, "content of #{path}"} end

      stub(MockAI, :evaluate, fn _model, %{path: path}, _qs, _opts ->
        {:ok, %{object: %{"echo" => path}}}
      end)

      tool = Tools.ask_files([@rlcd_model], reader: reader)

      assert {:ok, json} =
               File.cd!(dir, fn ->
                 tool.execute_fn.("agent-1", "tc-1", %{
                   "provider" => "typesafe",
                   "model_id" => "jev-latest",
                   "base_url" => "",
                   "paths" => ["*.ex"],
                   "questions" => %{}
                 })
               end)

      assert %{"results" => results, "skipped" => [], "calls" => 2} = Jason.decode!(json)
      assert Enum.map(results, & &1["path"]) == ["a.ex", "b.ex"]
    end

    @tag :tmp_dir
    test "globs with no matches fail the call with a clear reason", %{tmp_dir: dir} do
      reader = fn _path -> raise "must not read" end
      expect(MockAI, :evaluate, 0, fn _m, _s, _q, _o -> {:ok, %{object: %{}}} end)

      tool = Tools.ask_files([@rlcd_model], reader: reader)

      assert {:error, message} =
               File.cd!(dir, fn ->
                 tool.execute_fn.("agent-1", "tc-1", %{
                   "provider" => "typesafe",
                   "model_id" => "jev-latest",
                   "base_url" => "",
                   "paths" => ["nothing-*.ex"],
                   "questions" => %{}
                 })
               end)

      assert message =~ "no matches"
    end

    @tag :tmp_dir
    test "a literal already covered by a glob is not evaluated twice", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "a.ex"), "aaa")

      reader = fn path -> {:ok, "content of #{path}"} end

      stub(MockAI, :evaluate, fn _model, %{path: path}, _qs, _opts ->
        {:ok, %{object: %{"echo" => path}}}
      end)

      tool = Tools.ask_files([@rlcd_model], reader: reader)

      assert {:ok, json} =
               File.cd!(dir, fn ->
                 tool.execute_fn.("agent-1", "tc-1", %{
                   "provider" => "typesafe",
                   "model_id" => "jev-latest",
                   "base_url" => "",
                   "paths" => ["a.ex", "*.ex"],
                   "questions" => %{}
                 })
               end)

      assert %{"results" => results, "calls" => 1} = Jason.decode!(json)
      assert Enum.map(results, & &1["path"]) == ["a.ex"]
    end

    @tag :tmp_dir
    test "glob expansion over the cap errors before any file is read", %{tmp_dir: dir} do
      for n <- 1..256, do: File.write!(Path.join(dir, "file-#{n}.ex"), "x")

      reader = fn _path -> raise "must not read" end
      stub(MockAI, :get_model, fn _provider, _model_id -> {:ok, @rlcd_model} end)

      tool = Tools.ask_files([@rlcd_model], reader: reader)

      assert {:error, message} =
               File.cd!(dir, fn ->
                 tool.execute_fn.("agent-1", "tc-1", %{
                   "provider" => "typesafe",
                   "model_id" => "jev-latest",
                   "base_url" => "",
                   "paths" => ["*.ex"],
                   "questions" => %{}
                 })
               end)

      assert message =~ "255"
      assert message =~ "glob expansion"
    end

    test "results keep input order despite uneven latency" do
      reader = fn path -> {:ok, "content of #{path}"} end

      stub(MockAI, :evaluate, fn _model, %{path: path}, _qs, _opts ->
        if path == "first.ex", do: Process.sleep(50)
        {:ok, %{object: %{"echo" => path}}}
      end)

      tool = Tools.ask_files([@rlcd_model], reader: reader)

      assert {:ok, json} =
               tool.execute_fn.("agent-1", "tc-1", %{
                 "provider" => "typesafe",
                 "model_id" => "jev-latest",
                 "base_url" => "",
                 "paths" => ["first.ex", "second.ex", "third.ex"],
                 "questions" => %{}
               })

      assert %{"results" => results, "calls" => 3} = Jason.decode!(json)
      assert Enum.map(results, & &1["path"]) == ["first.ex", "second.ex", "third.ex"]
    end

    test "per-file RLCD failure lands in skipped, not a whole-call failure" do
      reader = fn path -> {:ok, "content of #{path}"} end

      stub(MockAI, :evaluate, fn
        _model, %{path: "bad.ex"}, _qs, _opts -> {:error, :boom}
        _model, _state, _qs, _opts -> {:ok, %{object: %{}}}
      end)

      tool = Tools.ask_files([@rlcd_model], reader: reader)

      assert {:ok, json} =
               tool.execute_fn.("agent-1", "tc-1", %{
                 "provider" => "typesafe",
                 "model_id" => "jev-latest",
                 "base_url" => "",
                 "paths" => ["good.ex", "bad.ex"],
                 "questions" => %{}
               })

      assert %{
               "results" => [%{"path" => "good.ex"}],
               "skipped" => [%{"path" => "bad.ex", "reason" => reason}],
               "calls" => 1
             } = Jason.decode!(json)

      assert reason =~ "boom"
    end

    test "rejects a non-RLCD model like ask does" do
      stub(MockAI, :get_model, fn _provider, _model_id -> {:ok, @llm_model} end)

      tool = Tools.ask_files([@llm_model], reader: fn _ -> {:ok, "x"} end)

      assert {:error, _message} =
               tool.execute_fn.("agent-1", "tc-1", %{
                 "provider" => "openai",
                 "model_id" => @llm_model.id,
                 "base_url" => "",
                 "paths" => ["a.ex"],
                 "questions" => %{}
               })
    end

    @tag :tmp_dir
    test "builtin fallback reads real files with read-compatible path semantics", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "a.ex"), "aaa")
      File.write!(Path.join(dir, "b.ex"), "bbb")

      stub(MockAI, :evaluate, fn _model, %{path: _p, content: c}, _qs, _opts ->
        {:ok, %{object: %{"len" => String.length(c)}}}
      end)

      tool = Tools.ask_files([@rlcd_model])

      assert {:ok, json} =
               File.cd!(dir, fn ->
                 tool.execute_fn.("agent-1", "tc-1", %{
                   "provider" => "typesafe",
                   "model_id" => "jev-latest",
                   "base_url" => "",
                   "paths" => ["a.ex", "b.ex", "missing.ex", dir],
                   "questions" => %{}
                 })
               end)

      assert %{"results" => results, "skipped" => skipped, "calls" => 2} =
               Jason.decode!(json)

      assert Enum.map(results, & &1["path"]) == ["a.ex", "b.ex"]
      reasons = Map.new(skipped, &{&1["path"], &1["reason"]})
      assert reasons["missing.ex"] =~ "no such file"
      assert reasons[dir] =~ "directory"
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
