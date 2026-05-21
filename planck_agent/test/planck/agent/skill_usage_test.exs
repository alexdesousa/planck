defmodule Planck.Agent.SkillUsageTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Planck.Agent.SkillUsage

  # ---------------------------------------------------------------------------
  # record_use/5
  # ---------------------------------------------------------------------------

  describe "record_use/5" do
    test "creates the DB and table on first use", %{tmp_dir: dir} do
      assert :ok = SkillUsage.record_use(dir, "my-team", "Builder", "builder", "elixir-dev")
      assert File.exists?(Path.join([dir, ".planck", "skills.db"]))
    end

    test "upserts use_count and last_used on repeated calls", %{tmp_dir: dir} do
      :ok = SkillUsage.record_use(dir, "team", "Builder", "builder", "elixir-dev")
      :ok = SkillUsage.record_use(dir, "team", "Builder", "builder", "elixir-dev")
      :ok = SkillUsage.record_use(dir, "team", "Builder", "builder", "elixir-dev")

      # top_n returns the skill — verifies the row exists
      assert SkillUsage.top_n(dir, "team", "Builder", 5) == ["elixir-dev"]
    end

    test "records different skills independently", %{tmp_dir: dir} do
      :ok = SkillUsage.record_use(dir, "team", "Builder", "builder", "elixir-dev")
      :ok = SkillUsage.record_use(dir, "team", "Builder", "builder", "code-review")

      ranked = SkillUsage.top_n(dir, "team", "Builder", 5)
      assert "elixir-dev" in ranked
      assert "code-review" in ranked
    end

    test "records different agents independently", %{tmp_dir: dir} do
      :ok = SkillUsage.record_use(dir, "team", "Builder", "builder", "elixir-dev")
      :ok = SkillUsage.record_use(dir, "team", "Reviewer", "reviewer", "code-review")

      assert SkillUsage.top_n(dir, "team", "Builder", 5) == ["elixir-dev"]
      assert SkillUsage.top_n(dir, "team", "Reviewer", 5) == ["code-review"]
    end

    test "records different teams independently", %{tmp_dir: dir} do
      :ok = SkillUsage.record_use(dir, "team-a", "Builder", "builder", "skill-a")
      :ok = SkillUsage.record_use(dir, "team-b", "Builder", "builder", "skill-b")

      assert SkillUsage.top_n(dir, "team-a", "Builder", 5) == ["skill-a"]
      assert SkillUsage.top_n(dir, "team-b", "Builder", 5) == ["skill-b"]
    end
  end

  # ---------------------------------------------------------------------------
  # top_n/4
  # ---------------------------------------------------------------------------

  describe "top_n/4" do
    test "returns empty list when DB does not exist", %{tmp_dir: dir} do
      assert SkillUsage.top_n(dir, "team", "Builder", 5) == []
    end

    test "returns empty list for unknown agent", %{tmp_dir: dir} do
      :ok = SkillUsage.record_use(dir, "team", "Builder", "builder", "elixir-dev")
      assert SkillUsage.top_n(dir, "team", "Unknown", 5) == []
    end

    test "returns skills ordered by last_used DESC, use_count DESC", %{tmp_dir: dir} do
      :ok = SkillUsage.record_use(dir, "team", "Builder", "builder", "old-skill")
      :ok = SkillUsage.record_use(dir, "team", "Builder", "builder", "old-skill")
      :ok = SkillUsage.record_use(dir, "team", "Builder", "builder", "recent-skill")

      [first | _] = SkillUsage.top_n(dir, "team", "Builder", 5)
      assert first == "recent-skill"
    end

    test "respects the n limit", %{tmp_dir: dir} do
      Enum.each(1..5, fn i ->
        :ok = SkillUsage.record_use(dir, "team", "Builder", "builder", "skill-#{i}")
      end)

      assert length(SkillUsage.top_n(dir, "team", "Builder", 3)) == 3
    end

    test "returns all skills when n exceeds the row count", %{tmp_dir: dir} do
      :ok = SkillUsage.record_use(dir, "team", "Builder", "builder", "only-skill")
      assert SkillUsage.top_n(dir, "team", "Builder", 10) == ["only-skill"]
    end
  end

  # ---------------------------------------------------------------------------
  # ranked_names/5
  # ---------------------------------------------------------------------------

  describe "ranked_names/5" do
    defp make_skill(tmp_dir, name) do
      skill_dir = Path.join(tmp_dir, name)
      skill_file = Path.join(skill_dir, "SKILL.md")
      File.mkdir_p!(skill_dir)

      File.write!(skill_file, """
      ---
      name: #{name}
      description: Skill #{name}
      ---
      """)

      %Planck.Agent.Skill{
        name: name,
        description: "Skill #{name}",
        path: skill_dir,
        skill_file: skill_file
      }
    end

    test "returns SQLite ranking when history exists", %{tmp_dir: dir} do
      skill_dir = Path.join(dir, "skills")
      skill_a = make_skill(skill_dir, "skill-a")
      skill_b = make_skill(skill_dir, "skill-b")

      :ok = SkillUsage.record_use(dir, "team", "Builder", "builder", "skill-b")

      ranked = SkillUsage.ranked_names(dir, "team", "Builder", [skill_a, skill_b], 5)
      assert ranked == ["skill-b"]
    end

    test "falls back to mtime-sorted skills when no history", %{tmp_dir: dir} do
      skill_dir = Path.join(dir, "skills")
      skill_a = make_skill(skill_dir, "skill-a")
      skill_b = make_skill(skill_dir, "skill-b")

      ranked = SkillUsage.ranked_names(dir, "team", "Builder", [skill_a, skill_b], 5)
      assert Enum.sort(ranked) == ["skill-a", "skill-b"]
    end

    test "cold-start fallback respects the n limit", %{tmp_dir: dir} do
      skill_dir = Path.join(dir, "skills")
      skills = Enum.map(1..5, fn i -> make_skill(skill_dir, "skill-#{i}") end)

      ranked = SkillUsage.ranked_names(dir, "team", "Builder", skills, 3)
      assert length(ranked) == 3
    end

    test "returns empty list when no history and no skills", %{tmp_dir: dir} do
      assert SkillUsage.ranked_names(dir, "team", "Builder", [], 5) == []
    end
  end

  # ---------------------------------------------------------------------------
  # top_n_for_orchestrators/3
  # ---------------------------------------------------------------------------

  describe "top_n_for_orchestrators/3" do
    test "returns empty list when DB does not exist", %{tmp_dir: dir} do
      assert SkillUsage.top_n_for_orchestrators(dir, "team", 5) == []
    end

    test "returns empty list when no orchestrator rows exist", %{tmp_dir: dir} do
      :ok = SkillUsage.record_use(dir, "team", "Builder", "builder", "elixir-dev")
      assert SkillUsage.top_n_for_orchestrators(dir, "team", 5) == []
    end

    test "returns skills used by the orchestrator agent", %{tmp_dir: dir} do
      :ok = SkillUsage.record_use(dir, "team", "orchestrator", "orchestrator", "planning")
      :ok = SkillUsage.record_use(dir, "team", "orchestrator", "orchestrator", "delegation")

      ranked = SkillUsage.top_n_for_orchestrators(dir, "team", 5)
      assert "planning" in ranked
      assert "delegation" in ranked
    end

    test "does not include non-orchestrator agent skills", %{tmp_dir: dir} do
      :ok = SkillUsage.record_use(dir, "team", "orchestrator", "orchestrator", "orch-skill")
      :ok = SkillUsage.record_use(dir, "team", "Builder", "builder", "builder-skill")

      ranked = SkillUsage.top_n_for_orchestrators(dir, "team", 5)
      assert "orch-skill" in ranked
      refute "builder-skill" in ranked
    end

    test "aggregates across multiple orchestrators in the same team", %{tmp_dir: dir} do
      :ok = SkillUsage.record_use(dir, "team", "orchestrator", "orchestrator", "shared")
      :ok = SkillUsage.record_use(dir, "team", "Lead Orchestrator", "orchestrator", "shared")
      :ok = SkillUsage.record_use(dir, "team", "Lead Orchestrator", "orchestrator", "lead-only")

      ranked = SkillUsage.top_n_for_orchestrators(dir, "team", 5)
      assert "shared" in ranked
      assert "lead-only" in ranked
    end

    test "does not include orchestrator skills from a different team", %{tmp_dir: dir} do
      :ok = SkillUsage.record_use(dir, "team-a", "orchestrator", "orchestrator", "skill-a")
      :ok = SkillUsage.record_use(dir, "team-b", "orchestrator", "orchestrator", "skill-b")

      assert SkillUsage.top_n_for_orchestrators(dir, "team-a", 5) == ["skill-a"]
    end

    test "respects the n limit", %{tmp_dir: dir} do
      Enum.each(1..5, fn i ->
        :ok = SkillUsage.record_use(dir, "team", "orchestrator", "orchestrator", "skill-#{i}")
      end)

      assert length(SkillUsage.top_n_for_orchestrators(dir, "team", 3)) == 3
    end
  end
end
