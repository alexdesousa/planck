defmodule Sidecar.Tools.ListSkillsTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Sidecar.Tools.{ListSkills, WriteSkill}

  setup %{tmp_dir: dir} do
    Application.put_env(:sidecar, :workspace_dir, dir)
    Sidecar.Config.reload_workspace_dir()

    on_exit(fn ->
      Application.delete_env(:sidecar, :workspace_dir)
      Sidecar.Config.reload_workspace_dir()
    end)

    :ok
  end

  describe "tool/0" do
    test "tool name is list_skills" do
      assert ListAgentSkills.tool().name == "list_skills"
    end
  end

  describe "list/0" do
    test "returns no-skills message when workspace has no agent skills" do
      assert {:ok, msg} = ListAgentSkills.list()
      assert msg =~ "No agent-created skills"
    end

    test "returns agent-created skills" do
      WriteSkill.write("git-workflow", "Git branching conventions.", "Body.")
      assert {:ok, result} = ListAgentSkills.list()
      assert result =~ "git-workflow"
      assert result =~ "Git branching conventions."
    end

    test "excludes user-created skills (no creator field)" do
      # Write a skill manually without creator: agent
      dir = Sidecar.Config.workspace_dir!()
      skill_dir = Path.join([dir, ".planck", "skills", "user-skill"])
      File.mkdir_p!(skill_dir)

      File.write!(Path.join(skill_dir, "SKILL.md"), """
      ---
      name: user-skill
      description: A user-curated skill.
      always_present: false
      ---

      Body.
      """)

      assert {:ok, result} = ListAgentSkills.list()
      refute result =~ "user-skill"
    end

    test "excludes user-created skills even if always_present is true" do
      dir = Sidecar.Config.workspace_dir!()
      skill_dir = Path.join([dir, ".planck", "skills", "pinned-user"])
      File.mkdir_p!(skill_dir)

      File.write!(Path.join(skill_dir, "SKILL.md"), """
      ---
      name: pinned-user
      description: User pinned skill.
      always_present: true
      ---

      Body.
      """)

      assert {:ok, result} = ListAgentSkills.list()
      refute result =~ "pinned-user"
    end

    test "returns both agent skills when multiple exist" do
      WriteSkill.write("skill-a", "Skill A.", "Body A.")
      WriteSkill.write("skill-b", "Skill B.", "Body B.")

      assert {:ok, result} = ListAgentSkills.list()
      assert result =~ "skill-a"
      assert result =~ "skill-b"
    end

    test "works when skills directory does not exist" do
      assert {:ok, msg} = ListAgentSkills.list()
      assert msg =~ "No agent-created skills"
    end
  end

  describe "execute_fn" do
    test "calls list/0 and returns result" do
      tool = ListAgentSkills.tool()
      assert {:ok, _} = tool.execute_fn.("agent-1", "tc1", %{})
    end
  end
end
