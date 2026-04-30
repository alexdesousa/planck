defmodule Planck.Agent.TeamTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Planck.Agent.{AgentSpec, Team}

  defp orchestrator_entry(overrides \\ %{}) do
    Map.merge(
      %{
        "type" => "orchestrator",
        "provider" => "ollama",
        "model_id" => "llama3.2",
        "system_prompt" => "You are the orchestrator."
      },
      overrides
    )
  end

  defp builder_entry(overrides \\ %{}) do
    Map.merge(
      %{
        "type" => "builder",
        "provider" => "ollama",
        "model_id" => "llama3.2",
        "system_prompt" => "You are a builder."
      },
      overrides
    )
  end

  defp write_team(dir, team_json) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "TEAM.json"), Jason.encode!(team_json))
  end

  # --- load/1 ---

  describe "load/1" do
    test "loads a minimal valid team", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "my-team")
      write_team(dir, %{"members" => [orchestrator_entry()]})

      assert {:ok, %Team{} = team} = Team.load(dir)
      assert team.alias == "my-team"
      assert team.source == :filesystem
      assert team.dir == Path.expand(dir)
      assert team.id == nil
      assert [%AgentSpec{type: "orchestrator"}] = team.members
    end

    test "preserves name and description from TEAM.json", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "named-team")

      write_team(dir, %{
        "name" => "Named Team",
        "description" => "A team with a name.",
        "members" => [orchestrator_entry()]
      })

      assert {:ok, team} = Team.load(dir)
      assert team.name == "Named Team"
      assert team.description == "A team with a name."
    end

    test "name and description default to nil when absent", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "no-meta")
      write_team(dir, %{"members" => [orchestrator_entry()]})

      assert {:ok, team} = Team.load(dir)
      assert team.name == nil
      assert team.description == nil
    end

    test "loads a multi-member team", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "multi")

      write_team(dir, %{
        "members" => [
          orchestrator_entry(),
          builder_entry(),
          builder_entry(%{"type" => "tester"})
        ]
      })

      assert {:ok, team} = Team.load(dir)
      assert length(team.members) == 3
      assert Enum.map(team.members, & &1.type) == ["orchestrator", "builder", "tester"]
    end

    test "resolves system_prompt paths relative to team dir", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "with-prompts")
      File.mkdir_p!(Path.join([dir, "members", "orchestrator"]))
      File.write!(Path.join([dir, "members", "orchestrator", "prompt.md"]), "  Orchestrate.  ")

      write_team(dir, %{
        "members" => [orchestrator_entry(%{"system_prompt" => "members/orchestrator/prompt.md"})]
      })

      assert {:ok, team} = Team.load(dir)
      assert [%AgentSpec{system_prompt: "Orchestrate."}] = team.members
    end

    test "returns error when directory does not exist" do
      assert {:error, reason} = Team.load("/nonexistent/team")
      assert reason =~ "team directory not found"
    end

    test "returns error when TEAM.json is missing", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "no-json")
      File.mkdir_p!(dir)

      assert {:error, reason} = Team.load(dir)
      assert reason =~ "cannot read"
    end

    test "returns error for invalid JSON", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "bad-json")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "TEAM.json"), "not json {{{")

      assert {:error, reason} = Team.load(dir)
      assert reason =~ "invalid JSON"
    end

    test "returns error when members field is missing", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "no-members")
      write_team(dir, %{"name" => "x"})

      assert {:error, reason} = Team.load(dir)
      assert reason =~ "missing required field 'members'"
    end

    test "returns error when members is empty", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "empty-members")
      write_team(dir, %{"members" => []})

      assert {:error, reason} = Team.load(dir)
      assert reason =~ "members must not be empty"
    end

    test "returns error when members is not an array", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "bad-members")
      write_team(dir, %{"members" => %{"x" => "y"}})

      assert {:error, reason} = Team.load(dir)
      assert reason =~ "members must be an array"
    end

    test "returns error when all member entries are invalid", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "invalid-only")
      write_team(dir, %{"members" => [%{"junk" => true}]})

      assert {:error, reason} = Team.load(dir)
      assert reason =~ "no valid members"
    end

    test "returns error when no orchestrator is present", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "no-orch")
      write_team(dir, %{"members" => [builder_entry()]})

      assert {:error, reason} = Team.load(dir)
      assert reason =~ "exactly one member with type \"orchestrator\""
    end

    test "returns error when multiple orchestrators are present", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "two-orch")

      write_team(dir, %{
        "members" => [orchestrator_entry(%{"name" => "A"}), orchestrator_entry(%{"name" => "B"})]
      })

      assert {:error, reason} = Team.load(dir)
      assert reason =~ "exactly one orchestrator, found 2"
    end

    test "allows repeated member types when names differ", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "repeated-types")

      write_team(dir, %{
        "members" => [
          orchestrator_entry(),
          builder_entry(%{"name" => "Bob"}),
          builder_entry(%{"name" => "Charlie"})
        ]
      })

      assert {:ok, team} = Team.load(dir)
      assert Enum.map(team.members, & &1.type) == ["orchestrator", "builder", "builder"]
      assert Enum.map(team.members, & &1.name) == ["orchestrator", "Bob", "Charlie"]
    end

    test "defaults member name to type when absent", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "default-names")

      write_team(dir, %{
        "members" => [orchestrator_entry(), builder_entry()]
      })

      assert {:ok, team} = Team.load(dir)
      assert Enum.map(team.members, & &1.name) == ["orchestrator", "builder"]
    end

    test "returns error on duplicate member names", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "dup-names")

      write_team(dir, %{
        "members" => [
          orchestrator_entry(),
          builder_entry(%{"name" => "Bob"}),
          builder_entry(%{"type" => "tester", "name" => "Bob"})
        ]
      })

      assert {:error, reason} = Team.load(dir)
      assert reason =~ "duplicate member name \"Bob\""
    end

    test "rejects multiple unnamed members with the same type", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "unnamed-repeats")

      write_team(dir, %{
        "members" => [orchestrator_entry(), builder_entry(), builder_entry()]
      })

      assert {:error, reason} = Team.load(dir)
      assert reason =~ "duplicate member name \"builder\""
      assert reason =~ "explicit names"
    end

    test "parses member skills field", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "with-skills")

      write_team(dir, %{
        "members" => [
          orchestrator_entry(%{"skills" => ["code_review", "refactor"]})
        ]
      })

      assert {:ok, team} = Team.load(dir)
      assert [%AgentSpec{skills: ["code_review", "refactor"]}] = team.members
    end

    test "member skills defaults to empty list when absent", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "no-skills")
      write_team(dir, %{"members" => [orchestrator_entry()]})

      assert {:ok, team} = Team.load(dir)
      assert [%AgentSpec{skills: []}] = team.members
    end
  end

  # --- dynamic/1 ---

  describe "dynamic/1" do
    test "builds a dynamic team from an orchestrator spec" do
      orchestrator =
        AgentSpec.new(
          type: "orchestrator",
          provider: :ollama,
          model_id: "llama3.2",
          system_prompt: "Coordinate."
        )

      team = Team.dynamic(orchestrator)

      assert team.source == :dynamic
      assert team.alias == nil
      assert team.dir == nil
      assert team.members == [orchestrator]
    end

    test "raises when spec is not an orchestrator" do
      spec =
        AgentSpec.new(
          type: "builder",
          provider: :ollama,
          model_id: "llama3.2",
          system_prompt: "Build."
        )

      assert_raise FunctionClauseError, fn -> Team.dynamic(spec) end
    end
  end
end
