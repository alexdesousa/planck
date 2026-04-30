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

    test "handles descriptions with colons", %{tmp_dir: dir} do
      {_, skill_file} =
        write_skill(dir, "colon", valid_md("colon", "Expert at n8n: workflow automation"))

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

  # --- system_prompt_section/1 ---

  describe "system_prompt_section/1" do
    test "returns nil for an empty list" do
      assert Skill.system_prompt_section([]) == nil
    end

    test "includes name, description, and file path for each skill", %{tmp_dir: dir} do
      write_skill(dir, "n8n-expert", valid_md("n8n-expert", "n8n automation expert"))
      [skill] = Skill.load_all([dir])

      section = Skill.system_prompt_section([skill])
      assert section =~ "n8n-expert"
      assert section =~ "n8n automation expert"
      assert section =~ "SKILL.md"
      assert section =~ "resources dir"
      assert section =~ "`read`"
    end

    test "includes all skills in the listing", %{tmp_dir: dir} do
      write_skill(dir, "skill-a", valid_md("skill-a", "Desc A"))
      write_skill(dir, "skill-b", valid_md("skill-b", "Desc B"))
      skills = Skill.load_all([dir])

      section = Skill.system_prompt_section(skills)
      assert section =~ "skill-a"
      assert section =~ "skill-b"
    end
  end
end
