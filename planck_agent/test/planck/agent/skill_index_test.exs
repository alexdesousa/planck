defmodule Planck.Agent.SkillIndexTest do
  use ExUnit.Case, async: true

  alias Planck.Agent.{Skill, SkillIndex}

  defp make_skill(name, description \\ "Desc") do
    %Skill{
      name: name,
      description: description,
      path: "/tmp/skills/#{name}",
      skill_file: "/tmp/skills/#{name}/SKILL.md"
    }
  end

  # ---------------------------------------------------------------------------
  # new/0
  # ---------------------------------------------------------------------------

  describe "new/0" do
    test "returns an empty skill index with defaults" do
      index = SkillIndex.new()
      assert index.pool == []
      assert index.ranked == []
      assert index.top_n == 5
      assert index.names == []
      assert index.refresh_fn == nil
    end
  end

  # ---------------------------------------------------------------------------
  # from_opts/1
  # ---------------------------------------------------------------------------

  describe "from_opts/1" do
    test "returns defaults when no skill opts are present" do
      index = SkillIndex.from_opts([])
      assert index == SkillIndex.new()
    end

    test "reads skill_pool into pool" do
      skills = [make_skill("elixir-dev")]
      index = SkillIndex.from_opts(skill_pool: skills)
      assert index.pool == skills
    end

    test "reads ranked_skill_names into ranked" do
      index = SkillIndex.from_opts(ranked_skill_names: ["elixir-dev", "git-workflow"])
      assert index.ranked == ["elixir-dev", "git-workflow"]
    end

    test "reads top_skills into top_n" do
      index = SkillIndex.from_opts(top_skills: 10)
      assert index.top_n == 10
    end

    test "reads skill_names into names" do
      index = SkillIndex.from_opts(skill_names: ["elixir-dev"])
      assert index.names == ["elixir-dev"]
    end

    test "reads skill_refresh_fn into refresh_fn" do
      fun = fn -> [] end
      index = SkillIndex.from_opts(skill_refresh_fn: fun)
      assert index.refresh_fn == fun
    end

    test "all opts together" do
      skills = [make_skill("elixir-dev")]
      fun = fn -> skills end

      index =
        SkillIndex.from_opts(
          skill_pool: skills,
          ranked_skill_names: ["elixir-dev"],
          top_skills: 3,
          skill_names: ["elixir-dev"],
          skill_refresh_fn: fun
        )

      assert index.pool == skills
      assert index.ranked == ["elixir-dev"]
      assert index.top_n == 3
      assert index.names == ["elixir-dev"]
      assert index.refresh_fn == fun
    end

    test "ignores unrelated opts" do
      index = SkillIndex.from_opts(id: "abc", model: :something)
      assert index == SkillIndex.new()
    end
  end
end
