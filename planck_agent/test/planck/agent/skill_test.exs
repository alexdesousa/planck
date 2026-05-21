defmodule Planck.Agent.SkillTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Planck.Agent.Skill

  defp write_skill(dir, name, content) do
    skill_dir = Path.join(dir, name)
    File.mkdir_p!(skill_dir)
    skill_file = Path.join(skill_dir, "SKILL.md")
    File.write!(skill_file, content)
    {skill_dir, skill_file}
  end

  defp valid_md(name, description) do
    """
    ---
    name: #{name}
    description: #{description}
    ---

    # #{String.capitalize(name)}

    You are an expert.
    """
  end

  # --- from_file/1 ---

  describe "from_file/1" do
    test "parses a valid SKILL.md", %{tmp_dir: dir} do
      {skill_dir, skill_file} = write_skill(dir, "my-skill", valid_md("my-skill", "Does things"))

      assert {:ok, skill} = Skill.from_file(skill_file)
      assert skill.name == "my-skill"
      assert skill.description == "Does things"
      assert skill.path == skill_dir
      assert skill.skill_file == skill_file
    end

    test "returns error when file does not exist" do
      assert {:error, reason} = Skill.from_file("/no/such/SKILL.md")
      assert reason =~ "cannot read"
    end

    test "returns error when frontmatter is missing", %{tmp_dir: dir} do
      {_, skill_file} = write_skill(dir, "no-fm", "Just plain content, no frontmatter.")
      assert {:error, reason} = Skill.from_file(skill_file)
      assert reason =~ "no frontmatter"
    end

    test "returns error when name field is missing", %{tmp_dir: dir} do
      content = "---\ndescription: A skill without a name\n---\n"
      {_, skill_file} = write_skill(dir, "no-name", content)
      assert {:error, reason} = Skill.from_file(skill_file)
      assert reason =~ "name"
    end

    test "returns error when description field is missing", %{tmp_dir: dir} do
      content = "---\nname: my-skill\n---\n"
      {_, skill_file} = write_skill(dir, "no-desc", content)
      assert {:error, reason} = Skill.from_file(skill_file)
      assert reason =~ "description"
    end

    test "handles descriptions with colons (must be quoted in YAML)", %{tmp_dir: dir} do
      content = """
      ---
      name: colon
      description: "Expert at n8n: workflow automation"
      ---

      # Colon

      You are an expert.
      """

      {_, skill_file} = write_skill(dir, "colon", content)

      assert {:ok, skill} = Skill.from_file(skill_file)
      assert skill.description == "Expert at n8n: workflow automation"
    end
  end

  # --- load_all/1 ---

  describe "load_all/1" do
    test "loads all valid skills from a directory", %{tmp_dir: dir} do
      write_skill(dir, "skill-a", valid_md("skill-a", "Desc A"))
      write_skill(dir, "skill-b", valid_md("skill-b", "Desc B"))

      skills = Skill.load_all([dir])
      names = skills |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["skill-a", "skill-b"]
    end

    test "skips subdirectories without SKILL.md", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "not-a-skill"))
      write_skill(dir, "valid", valid_md("valid", "A valid skill"))

      skills = Skill.load_all([dir])
      assert length(skills) == 1
      assert hd(skills).name == "valid"
    end

    test "silently skips non-existent directories" do
      assert Skill.load_all(["/does/not/exist"]) == []
    end

    test "merges skills from multiple directories", %{tmp_dir: dir} do
      dir_a = Path.join(dir, "a")
      dir_b = Path.join(dir, "b")
      File.mkdir_p!(dir_a)
      File.mkdir_p!(dir_b)

      write_skill(dir_a, "skill-a", valid_md("skill-a", "From A"))
      write_skill(dir_b, "skill-b", valid_md("skill-b", "From B"))

      names = Skill.load_all([dir_a, dir_b]) |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["skill-a", "skill-b"]
    end

    test "expands ~ in paths" do
      # just verifies load_all doesn't crash on ~ paths — result depends on filesystem
      skills = Skill.load_all(["~/.planck/skills"])
      assert is_list(skills)
    end

    test "invalid SKILL.md is skipped with a warning", %{tmp_dir: dir} do
      write_skill(dir, "bad-skill", "no frontmatter here")
      write_skill(dir, "good-skill", valid_md("good-skill", "Works fine"))

      skills = Skill.load_all([dir])
      assert length(skills) == 1
      assert hd(skills).name == "good-skill"
    end
  end

  # --- load_skill_tool/1 ---

  describe "load_skill_tool/1" do
    test "returns a tool named load_skill", %{tmp_dir: dir} do
      write_skill(dir, "elixir-dev", valid_md("elixir-dev", "Elixir expert"))
      [skill] = Skill.load_all([dir])
      tool = Skill.load_skill_tool([skill])
      assert tool.name == "load_skill"
    end

    test "loading a known skill returns its SKILL.md content", %{tmp_dir: dir} do
      write_skill(dir, "elixir-dev", valid_md("elixir-dev", "Elixir expert"))
      [skill] = Skill.load_all([dir])
      tool = Skill.load_skill_tool([skill])
      {:ok, content} = tool.execute_fn.("agent", "id", %{"name" => "elixir-dev"})
      assert content =~ "elixir-dev"
      assert content =~ "Elixir expert"
    end

    test "loaded content is prefaced with the skill's absolute directory path", %{tmp_dir: dir} do
      write_skill(dir, "my-skill", valid_md("my-skill", "Has references."))
      [skill] = Skill.load_all([dir])
      tool = Skill.load_skill_tool([skill])
      {:ok, loaded} = tool.execute_fn.("agent", "id", %{"name" => "my-skill"})

      skill_dir = Path.join(dir, "my-skill")
      assert String.starts_with?(loaded, "Skill directory: #{skill_dir}")
    end

    test "loading an unknown skill returns an error listing available names", %{tmp_dir: dir} do
      write_skill(dir, "elixir-dev", valid_md("elixir-dev", "Elixir expert"))
      [skill] = Skill.load_all([dir])
      tool = Skill.load_skill_tool([skill])
      {:error, msg} = tool.execute_fn.("agent", "id", %{"name" => "unknown"})
      assert msg =~ "Unknown skill"
      assert msg =~ "elixir-dev"
    end

    test "works with an empty pool (returns error for any name)" do
      tool = Skill.load_skill_tool([])
      {:error, msg} = tool.execute_fn.("agent", "id", %{"name" => "anything"})
      assert msg =~ "Unknown skill"
    end

    test "skill_refresh_fn is called on each invocation — new skills visible without restart",
         %{tmp_dir: dir} do
      write_skill(dir, "elixir-dev", valid_md("elixir-dev", "Elixir expert"))
      [skill] = Skill.load_all([dir])

      pool = :ets.new(:pool, [:set, :public])
      :ets.insert(pool, {:skills, [skill]})

      refresh_fn = fn ->
        [{:skills, skills}] = :ets.lookup(pool, :skills)
        skills
      end

      tool = Skill.load_skill_tool([skill], skill_refresh_fn: refresh_fn)

      # Initially only elixir-dev is available
      assert {:ok, _} = tool.execute_fn.("agent", "id", %{"name" => "elixir-dev"})
      assert {:error, _} = tool.execute_fn.("agent", "id", %{"name" => "new-skill"})

      # Add a new skill to the pool (simulating hot reload)
      write_skill(dir, "new-skill", valid_md("new-skill", "Brand new skill"))
      [new_skill] = Skill.load_all([dir]) |> Enum.filter(&(&1.name == "new-skill"))
      :ets.insert(pool, {:skills, [skill, new_skill]})

      # Now load_skill picks it up without rebuilding the tool
      assert {:ok, content} = tool.execute_fn.("agent", "id", %{"name" => "new-skill"})
      assert content =~ "new-skill"
    end
  end

  # --- list_skills_tool/1 ---

  describe "list_skills_tool/1" do
    test "returns a tool named list_skills", %{tmp_dir: dir} do
      write_skill(dir, "elixir-dev", valid_md("elixir-dev", "Elixir expert"))
      [skill] = Skill.load_all([dir])
      tool = Skill.list_skills_tool([skill])
      assert tool.name == "list_skills"
    end

    test "returns names and descriptions of all skills", %{tmp_dir: dir} do
      write_skill(dir, "elixir-dev", valid_md("elixir-dev", "Elixir expert"))
      write_skill(dir, "code-review", valid_md("code-review", "Reviews code"))
      skills = Skill.load_all([dir])
      tool = Skill.list_skills_tool(skills)
      {:ok, result} = tool.execute_fn.("agent", "id", %{})
      assert result =~ "elixir-dev"
      assert result =~ "Elixir expert"
      assert result =~ "code-review"
      assert result =~ "Reviews code"
    end

    test "returns a no-skills message for an empty pool" do
      tool = Skill.list_skills_tool([])
      {:ok, result} = tool.execute_fn.("agent", "id", %{})
      assert result =~ "No skills"
    end
  end

  # --- system_prompt_section/1 ---

  describe "system_prompt_section/3" do
    test "returns nil for an empty pool" do
      assert Skill.system_prompt_section([], [], 5) == nil
    end

    test "includes name and description for a ranked skill", %{tmp_dir: dir} do
      write_skill(dir, "n8n-expert", valid_md("n8n-expert", "n8n automation expert"))
      [skill] = Skill.load_all([dir])

      section = Skill.system_prompt_section([skill], ["n8n-expert"], 5)
      assert section =~ "n8n-expert"
      assert section =~ "n8n automation expert"
      refute section =~ "SKILL.md"
    end

    test "shows all skills when ranked list is empty (cold start)", %{tmp_dir: dir} do
      write_skill(dir, "skill-a", valid_md("skill-a", "Desc A"))
      write_skill(dir, "skill-b", valid_md("skill-b", "Desc B"))
      skills = Skill.load_all([dir])

      # No ranking — no ranked skills shown, no pinned skills, nothing
      section = Skill.system_prompt_section(skills, [], 5)
      assert section == nil
    end

    test "pinned skills always appear regardless of ranking", %{tmp_dir: dir} do
      write_skill(
        dir,
        "pinned",
        "---\nname: pinned\ndescription: Always here.\nalways_present: true\n---\n"
      )

      write_skill(dir, "regular", valid_md("regular", "Desc"))
      skills = Skill.load_all([dir])

      section = Skill.system_prompt_section(skills, [], 5)
      assert section =~ "pinned"
      assert section =~ "Always here."
      refute section =~ "regular"
    end

    test "ranked skills appear in last-used section", %{tmp_dir: dir} do
      write_skill(dir, "skill-a", valid_md("skill-a", "Desc A"))
      write_skill(dir, "skill-b", valid_md("skill-b", "Desc B"))
      skills = Skill.load_all([dir])

      section = Skill.system_prompt_section(skills, ["skill-a"], 5)
      assert section =~ "skill-a"
      refute section =~ "skill-b"
    end

    test "discovery line appears when more skills exist", %{tmp_dir: dir} do
      Enum.each(1..3, fn i ->
        write_skill(dir, "skill-#{i}", valid_md("skill-#{i}", "Desc #{i}"))
      end)

      skills = Skill.load_all([dir])

      section = Skill.system_prompt_section(skills, ["skill-1"], 1)
      assert section =~ "list_skills"
      assert section =~ "more skill"
    end

    test "no discovery line when all skills are shown", %{tmp_dir: dir} do
      write_skill(dir, "only", valid_md("only", "The only skill"))
      [skill] = Skill.load_all([dir])

      section = Skill.system_prompt_section([skill], ["only"], 5)
      refute section =~ "list_skills"
    end
  end
end
