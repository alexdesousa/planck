defmodule Planck.Web.API.TeamControllerTest do
  use Planck.Web.ConnCase, async: false

  @moduletag :tmp_dir

  alias Planck.Headless
  alias Planck.Headless.Config

  setup %{tmp_dir: dir} do
    teams_dir = Path.join(dir, "teams")
    File.mkdir_p!(teams_dir)

    original = Application.get_env(:planck, :teams_dirs)
    Application.put_env(:planck, :teams_dirs, [teams_dir])
    Config.reload_teams_dirs()
    Headless.reload_resources()

    on_exit(fn ->
      Application.delete_env(:planck, :teams_dirs)
      if original, do: Application.put_env(:planck, :teams_dirs, original)
      Config.reload_teams_dirs()
      Headless.reload_resources()
    end)

    {:ok, teams_dir: teams_dir}
  end

  # ---------------------------------------------------------------------------
  # GET /api/teams
  # ---------------------------------------------------------------------------

  describe "index/2" do
    test "returns empty list when no teams are registered", %{conn: conn} do
      conn = get(conn, "/api/teams")
      body = json_response(conn, 200)

      assert body == []
      assert_schema(body, "TeamList", api_spec())
    end

    test "lists registered teams", %{conn: conn, teams_dir: teams_dir} do
      write_team(teams_dir, "alpha")
      write_team(teams_dir, "beta")
      Config.reload_teams_dirs()
      Headless.reload_resources()

      conn = get(conn, "/api/teams")
      body = json_response(conn, 200)

      assert_schema(body, "TeamList", api_spec())
      aliases = Enum.map(body, & &1["alias"])
      assert "alpha" in aliases
      assert "beta" in aliases
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/teams/:alias
  # ---------------------------------------------------------------------------

  describe "show/2" do
    test "returns team detail with members", %{conn: conn, teams_dir: teams_dir} do
      write_team(teams_dir, "my-team")
      Config.reload_teams_dirs()
      Headless.reload_resources()

      conn = get(conn, "/api/teams/my-team")
      body = json_response(conn, 200)

      assert_schema(body, "TeamDetail", api_spec())
      assert body["alias"] == "my-team"
      assert body["name"] == "my-team"
      assert [member] = body["members"]
      assert member["type"] == "orchestrator"
    end

    test "returns 404 for unknown team", %{conn: conn} do
      conn = get(conn, "/api/teams/nonexistent")

      body = json_response(conn, 404)
      assert_schema(body, "Error", api_spec())
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp write_team(teams_dir, alias_name) do
    team_dir = Path.join(teams_dir, alias_name)
    File.mkdir_p!(team_dir)

    File.write!(
      Path.join(team_dir, "TEAM.json"),
      Jason.encode!(%{
        "name" => alias_name,
        "members" => [
          %{
            "type" => "orchestrator",
            "provider" => "ollama",
            "model_id" => "llama3.2",
            "system_prompt" => "You coordinate."
          }
        ]
      })
    )
  end
end
