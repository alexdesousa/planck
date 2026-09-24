defmodule Planck.Agent.SystemPromptTest do
  use ExUnit.Case, async: true

  alias Planck.Agent.{Skill, SystemPrompt}

  defp tools(names), do: Map.new(names, &{&1, %{}})

  defp base_opts(overrides \\ %{}) do
    %{
      system_prompt: "base prompt",
      name: nil,
      type: nil,
      tools: %{},
      skill_pool: [],
      ranked_skill_names: [],
      top_skills: 3,
      prompt_hook: nil,
      session_id: nil,
      sidecar_node: nil
    }
    |> Map.merge(overrides)
  end

  defp with_tools(tool_names), do: base_opts(%{tools: tools(tool_names)})

  defp skill(name, opts \\ []) do
    %Skill{
      name: name,
      description: "Description of #{name}.",
      path: "/skills/#{name}",
      skill_file: "/skills/#{name}/SKILL.md",
      always_present: Keyword.get(opts, :always_present, false)
    }
  end

  defmodule NilHook do
    use Planck.Agent.Hooks.Prompt
  end

  defmodule BeforePromptHook do
    use Planck.Agent.Hooks.Prompt

    @impl true
    def before_prompt(_session_id), do: "Injected before."
  end

  defmodule AfterPromptHook do
    use Planck.Agent.Hooks.Prompt

    @impl true
    def after_prompt(_session_id), do: "Injected after."
  end

  defmodule EmptyStringHook do
    use Planck.Agent.Hooks.Prompt

    @impl true
    def before_prompt(_session_id), do: ""

    @impl true
    def after_prompt(_session_id), do: ""
  end

  # --- identity line ---

  describe "identity line" do
    test "no name and no type leaves the prompt unchanged" do
      prompt = base_opts() |> SystemPrompt.build()
      assert prompt == "base prompt"
    end

    test "type only produces \"You are a <type>.\"" do
      prompt = base_opts(%{type: "coding agent"}) |> SystemPrompt.build()
      assert String.starts_with?(prompt, "You are a coding agent.\n\n")
    end

    test "name and different type produces \"You are <name>, a <type>.\"" do
      prompt = base_opts(%{name: "Marvin", type: "orchestrator"}) |> SystemPrompt.build()
      assert String.starts_with?(prompt, "You are Marvin, a orchestrator.\n\n")
    end

    test "name equal to type is treated as type-only" do
      prompt = base_opts(%{name: "orchestrator", type: "orchestrator"}) |> SystemPrompt.build()
      assert String.starts_with?(prompt, "You are a orchestrator.\n\n")
    end

    test "name only (no type) produces \"You are <name>.\"" do
      prompt = base_opts(%{name: "Marvin"}) |> SystemPrompt.build()
      assert String.starts_with?(prompt, "You are Marvin.\n\n")
    end
  end

  # --- tool sections: presence, ordering, content ---

  describe "tool sections" do
    test "no tools means no inter-agent section at all" do
      prompt = base_opts() |> SystemPrompt.build()
      assert prompt == "base prompt"
      refute prompt =~ "## Inter-agent tools"
    end

    test "unrecognized tool names are ignored" do
      prompt = with_tools(~w(read write bash)) |> SystemPrompt.build()
      assert prompt == "base prompt"
    end

    test "each known tool renders its own section" do
      for tool <-
            ~w(list_team list_skills load_skill list_models classify spawn_agent call_agent send_agent respond_agent interrupt_agent destroy_agent) do
        prompt = with_tools([tool]) |> SystemPrompt.build()
        assert prompt =~ "### #{tool}", "expected a section for #{tool}"
      end
    end

    test "sections appear in @ordered_tools order regardless of map insertion order" do
      prompt =
        with_tools(~w(destroy_agent list_team spawn_agent list_models))
        |> SystemPrompt.build()

      positions =
        ~w(list_team list_models spawn_agent destroy_agent)
        |> Enum.map(&(:binary.match(prompt, "### #{&1}") |> elem(0)))

      assert positions == Enum.sort(positions)
    end

    test "classify's section only appears when classify is in the agent's tools" do
      without_classify = with_tools(~w(list_models)) |> SystemPrompt.build()
      with_classify = with_tools(~w(list_models classify)) |> SystemPrompt.build()

      refute without_classify =~ "### classify"
      assert with_classify =~ "### classify"
    end

    test "classify's section teaches the discriminated question types" do
      prompt = with_tools(~w(classify)) |> SystemPrompt.build() |> String.downcase()

      assert prompt =~ "choice"
      assert prompt =~ "score"
      assert prompt =~ "boolean"
      assert prompt =~ "rlcd"
    end

    test "classify's section has an H4 subsection per question type with when-to-use guidance" do
      prompt = with_tools(~w(classify)) |> SystemPrompt.build()

      assert prompt =~ "#### Choice"
      assert prompt =~ "#### Score"
      assert prompt =~ "#### Boolean"

      choice_at = :binary.match(prompt, "#### Choice") |> elem(0)
      score_at = :binary.match(prompt, "#### Score") |> elem(0)
      boolean_at = :binary.match(prompt, "#### Boolean") |> elem(0)

      assert choice_at < score_at
      assert score_at < boolean_at
    end

    test "list_models' section mentions type guidance" do
      prompt = with_tools(~w(list_models)) |> SystemPrompt.build()

      assert prompt =~ "`type`"
      assert prompt =~ "\"llm\""
      assert prompt =~ "\"rlcd\""
    end

    test "section ordering places classify immediately after list_models and before spawn_agent" do
      prompt = with_tools(~w(list_models classify spawn_agent)) |> SystemPrompt.build()

      list_models_at = :binary.match(prompt, "### list_models") |> elem(0)
      classify_at = :binary.match(prompt, "### classify") |> elem(0)
      spawn_agent_at = :binary.match(prompt, "### spawn_agent") |> elem(0)

      assert list_models_at < classify_at
      assert classify_at < spawn_agent_at
    end
  end

  # --- inter-agent tools intro ---

  describe "inter-agent tools intro" do
    test "call_agent and send_agent both present explains how to choose between them" do
      prompt = with_tools(~w(call_agent send_agent)) |> SystemPrompt.build()

      assert prompt =~ "## Inter-agent tools"
      assert prompt =~ "To choose between the two delegation patterns"
      assert prompt =~ "call_agent` (blocks until the target responds)"
      assert prompt =~ "send_agent` (async"
    end

    test "call_agent alone explains it blocks" do
      prompt = with_tools(~w(call_agent)) |> SystemPrompt.build()

      assert prompt =~ "`call_agent` blocks until the target responds"
      refute prompt =~ "To choose between"
      refute prompt =~ "send_agent` is async"
    end

    test "send_agent alone explains it's async" do
      prompt = with_tools(~w(send_agent)) |> SystemPrompt.build()

      assert prompt =~ "`send_agent` is async"
      refute prompt =~ "To choose between"
      refute prompt =~ "`call_agent` blocks"
    end

    test "neither call_agent nor send_agent present still shows the header with no pattern text" do
      prompt = with_tools(~w(list_team)) |> SystemPrompt.build()

      assert prompt =~ "## Inter-agent tools"
      refute prompt =~ "To choose between"
      refute prompt =~ "blocks until the target responds — your turn"
      refute prompt =~ "is async — end your turn"
    end

    test "always target a different agent warning is always present alongside any tool section" do
      prompt = with_tools(~w(list_team)) |> SystemPrompt.build()
      assert prompt =~ "Always target a **different** agent — never ask or delegate to yourself."
    end
  end

  # --- skills section ---

  describe "skills section" do
    test "empty skill pool leaves the prompt unchanged" do
      prompt = base_opts(%{skill_pool: []}) |> SystemPrompt.build()
      assert prompt == "base prompt"
    end

    test "non-empty skill pool appends the skills section" do
      prompt =
        base_opts(%{skill_pool: [skill("elixir-dev", always_present: true)]})
        |> SystemPrompt.build()

      assert prompt =~ "## Skills"
      assert prompt =~ "elixir-dev"
    end

    test "ranked skills appear under the last-used heading" do
      prompt =
        base_opts(%{
          skill_pool: [skill("elixir-dev"), skill("go-dev")],
          ranked_skill_names: ["go-dev"],
          top_skills: 3
        })
        |> SystemPrompt.build()

      assert prompt =~ "## Last used skills"
      assert prompt =~ "go-dev"
    end

    test "skills section is appended after tool sections" do
      prompt =
        base_opts(%{
          tools: tools(~w(list_team)),
          skill_pool: [skill("elixir-dev", always_present: true)]
        })
        |> SystemPrompt.build()

      inter_agent_at = :binary.match(prompt, "## Inter-agent tools") |> elem(0)
      skills_at = :binary.match(prompt, "## Skills") |> elem(0)

      assert inter_agent_at < skills_at
    end
  end

  # --- prompt hooks ---

  describe "prompt hooks" do
    test "nil hook module leaves the prompt unchanged" do
      prompt = base_opts(%{prompt_hook: nil}) |> SystemPrompt.build()
      assert prompt == "base prompt"
    end

    test "hook module with default (nil) callbacks leaves the prompt unchanged" do
      prompt = base_opts(%{prompt_hook: NilHook}) |> SystemPrompt.build()
      assert prompt == "base prompt"
    end

    test "before_prompt is prepended ahead of the base prompt" do
      prompt = base_opts(%{prompt_hook: BeforePromptHook}) |> SystemPrompt.build()
      assert String.starts_with?(prompt, "Injected before.\n\nbase prompt")
    end

    test "after_prompt is appended after everything else" do
      prompt =
        base_opts(%{prompt_hook: AfterPromptHook, tools: tools(~w(list_team))})
        |> SystemPrompt.build()

      assert String.ends_with?(prompt, "Injected after.")
    end

    test "empty string from a hook is treated the same as nil" do
      prompt = base_opts(%{prompt_hook: EmptyStringHook}) |> SystemPrompt.build()
      assert prompt == "base prompt"
    end
  end
end
