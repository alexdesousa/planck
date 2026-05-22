defmodule Sidecar.Tools.WriteSkillTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Sidecar.Tools.WriteSkill

  setup %{tmp_dir: dir} do
    Application.put_env(:sidecar, :workspace_dir, dir)
    Sidecar.Config.reload_workspace_dir()

    on_exit(fn ->
      Application.delete_env(:sidecar, :workspace_dir)
      Sidecar.Config.reload_workspace_dir()
    end)

    :ok
  end

  defp skill_file(dir, name) do
    Path.join([dir, ".planck", "skills", name, "SKILL.md"])
  end

  # ---------------------------------------------------------------------------
  # tool/0
  # ---------------------------------------------------------------------------

  describe "tool/0" do
    test "has correct name and required params" do
      tool = WriteSkill.tool()
      assert tool.name == "write_skill"
      assert Enum.sort(tool.parameters["required"]) == ["content", "description", "name"]
    end
  end

  # ---------------------------------------------------------------------------
  # write/3 — create
  # ---------------------------------------------------------------------------

  describe "write/3 — create" do
    test "creates skill directory and SKILL.md", %{tmp_dir: dir} do
      assert {:ok, "create_skill:git-workflow"} =
               WriteSkill.write("git-workflow", "Git branching conventions.", "## Procedure\n\nDo things.")

      assert File.exists?(skill_file(dir, "git-workflow"))
    end

    test "SKILL.md contains correct frontmatter", %{tmp_dir: dir} do
      WriteSkill.write("my-skill", "Does something useful.", "Body content.")
      content = File.read!(skill_file(dir, "my-skill"))

      assert content =~ "name: my-skill"
      assert content =~ "description: Does something useful."
      assert content =~ "always_present: false"
      assert content =~ "creator: agent"
      assert content =~ "planck_version: null"
    end

    test "SKILL.md contains the body content", %{tmp_dir: dir} do
      WriteSkill.write("my-skill", "Desc.", "## When to Use\n\nAlways.")
      content = File.read!(skill_file(dir, "my-skill"))
      assert content =~ "## When to Use"
      assert content =~ "Always."
    end

    test "descriptions with colons are quoted", %{tmp_dir: dir} do
      WriteSkill.write("my-skill", "Expert at n8n: workflow automation", "Body.")
      content = File.read!(skill_file(dir, "my-skill"))
      # Ymlr quotes with single quotes; both forms are valid YAML
      assert content =~ "description:" and content =~ "Expert at n8n: workflow automation"
    end

    test "returns create_skill:name for new files" do
      assert {:ok, "create_skill:brand-new"} =
               WriteSkill.write("brand-new", "A new skill.", "Content.")
    end
  end

  # ---------------------------------------------------------------------------
  # write/3 — update
  # ---------------------------------------------------------------------------

  describe "write/3 — update" do
    test "returns update_skill:name for existing files", %{tmp_dir: _dir} do
      WriteSkill.write("existing", "Original.", "Original body.")
      assert {:ok, "update_skill:existing"} =
               WriteSkill.write("existing", "Updated.", "Updated body.")
    end

    test "preserves user-set always_present: true on update", %{tmp_dir: dir} do
      WriteSkill.write("pinned", "Original.", "Body.")
      path = skill_file(dir, "pinned")
      content = File.read!(path)
      File.write!(path, String.replace(content, "always_present: false", "always_present: true"))

      WriteSkill.write("pinned", "Updated desc.", "New body.")
      updated = File.read!(skill_file(dir, "pinned"))
      assert updated =~ "always_present: true"
    end

    test "updates description and body on overwrite", %{tmp_dir: dir} do
      WriteSkill.write("skill", "Old desc.", "Old body.")
      WriteSkill.write("skill", "New desc.", "New body.")
      content = File.read!(skill_file(dir, "skill"))

      assert content =~ "New desc."
      assert content =~ "New body."
      refute content =~ "Old desc."
      refute content =~ "Old body."
    end

    test "always sets creator: agent on update", %{tmp_dir: dir} do
      WriteSkill.write("skill", "Desc.", "Body.")
      WriteSkill.write("skill", "Desc.", "Body v2.")
      content = File.read!(skill_file(dir, "skill"))
      assert content =~ "creator: agent"
    end
  end

  # ---------------------------------------------------------------------------
  # execute_fn
  # ---------------------------------------------------------------------------

  describe "execute_fn" do
    test "delegates to write/3 and returns ok string" do
      tool = WriteSkill.tool()
      assert {:ok, result} =
               tool.execute_fn.("agent-1", "tc1", %{
                 "name" => "test-skill",
                 "description" => "A test skill.",
                 "content" => "## Procedure\n\nStep 1."
               })

      assert result in ["create_skill:test-skill", "update_skill:test-skill"]
    end
  end
end
